#include "sandbox.h"

#include <fcntl.h>
#include <grp.h>
#include <linux/prctl.h>
#include <pwd.h>
#include <seccomp.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <ucontext.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>

#include "common.h"

// ---- Landlock UAPI (defined locally: the toolchain's kernel headers predate 5.13) ----
#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#define __NR_landlock_add_rule 445
#define __NR_landlock_restrict_self 446
#endif
namespace {
struct ll_ruleset_attr { uint64_t handled_access_fs; };
struct __attribute__((packed)) ll_path_beneath_attr { uint64_t allowed_access; int32_t parent_fd; };
constexpr uint32_t LL_CREATE_RULESET_VERSION = 1u << 0;
constexpr int LL_RULE_PATH_BENEATH = 1;
constexpr uint64_t LL_EXECUTE = 1ull << 0, LL_WRITE_FILE = 1ull << 1, LL_READ_FILE = 1ull << 2,
                   LL_READ_DIR = 1ull << 3;
constexpr uint64_t LL_ABI1_ALL = (1ull << 13) - 1;  // EXECUTE .. MAKE_SYM
constexpr uint64_t LL_REFER = 1ull << 13, LL_TRUNCATE = 1ull << 14;
}  // namespace

namespace sandbox {

Mode parseMode(const std::string& s) {
    if (s == "off" || s == "none") return Mode::Off;
    if (s == "trap") return Mode::Trap;
    return Mode::Strict;
}
const char* modeName(Mode m) { return m == Mode::Off ? "off" : m == Mode::Trap ? "trap" : "strict"; }

bool dropPrivileges(const std::string& user) {
    if (geteuid() != 0) return true;  // already unprivileged
    struct passwd* pw = getpwnam(user.c_str());
    if (!pw) {
        logf("sandbox: user '%s' not found", user.c_str());
        return false;
    }
    if (setgroups(0, nullptr) != 0 || setresgid(pw->pw_gid, pw->pw_gid, pw->pw_gid) != 0 ||
        setresuid(pw->pw_uid, pw->pw_uid, pw->pw_uid) != 0) {
        logf("sandbox: privilege drop failed: %s", strerror(errno));
        return false;
    }
    if (setuid(0) == 0) {  // must be irreversible
        logf("sandbox: regained root after drop - aborting");
        return false;
    }
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    logf("sandbox: running as %s (uid=%d gid=%d), all capabilities dropped", user.c_str(), pw->pw_uid, pw->pw_gid);
    return true;
}

bool noNewPrivs() { return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0; }

int landlock(const std::vector<std::string>& readPaths) {
    int abi = (int)syscall(__NR_landlock_create_ruleset, nullptr, 0, LL_CREATE_RULESET_VERSION);
    if (abi < 0) {
        logf("sandbox: landlock unavailable (%s) - continuing without it", strerror(errno));
        return -1;
    }
    ll_ruleset_attr ra{LL_ABI1_ALL};
    if (abi >= 2) ra.handled_access_fs |= LL_REFER;
    if (abi >= 3) ra.handled_access_fs |= LL_TRUNCATE;
    int rs = (int)syscall(__NR_landlock_create_ruleset, &ra, sizeof ra, 0);
    if (rs < 0) {
        logf("sandbox: landlock_create_ruleset: %s", strerror(errno));
        return -1;
    }
    auto allow = [&](const std::string& path, uint64_t access) {
        int fd = open(path.c_str(), O_PATH | O_CLOEXEC);
        if (fd < 0) return;
        struct stat st;
        if (fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode)) access &= (LL_EXECUTE | LL_WRITE_FILE | LL_READ_FILE | LL_TRUNCATE);
        ll_path_beneath_attr pb{access & ra.handled_access_fs, fd};
        if (syscall(__NR_landlock_add_rule, rs, LL_RULE_PATH_BENEATH, &pb, 0) != 0)
            logf("sandbox: landlock rule %s: %s", path.c_str(), strerror(errno));
        close(fd);
    };
    for (const auto& p : readPaths) allow(p, LL_READ_FILE | LL_READ_DIR);
    allow("/dev/null", LL_READ_FILE | LL_WRITE_FILE);
    allow("/dev/urandom", LL_READ_FILE);
    if (syscall(__NR_landlock_restrict_self, rs, 0) != 0) {
        logf("sandbox: landlock_restrict_self: %s", strerror(errno));
        close(rs);
        return -1;
    }
    close(rs);
    logf("sandbox: landlock ABI v%d active - filesystem read-only, exec denied", abi);
    return abi;
}

static void sigsysHandler(int, siginfo_t* si, void* ctx) {
    char msg[160];
    char comm[17] = {0};
    prctl(PR_GET_NAME, comm, 0, 0, 0);
    const ucontext_t* uc = static_cast<const ucontext_t*>(ctx);
    long a0 = (long)uc->uc_mcontext.gregs[REG_RDI], a1 = (long)uc->uc_mcontext.gregs[REG_RSI];
    int n = std::snprintf(msg, sizeof msg, "edgesightd: seccomp TRAP - forbidden syscall %d (arg0=%ld arg1=%ld) in thread '%s'\n",
                          si->si_syscall, a0, a1, comm);
    if (n > 0) (void)!write(2, msg, (size_t)n);
    _exit(159);
}

bool seccomp(Mode m) {
    if (m == Mode::Off) return true;
    if (m == Mode::Trap) {
        struct sigaction sa{};
        sa.sa_sigaction = sigsysHandler;
        sa.sa_flags = SA_SIGINFO;
        sigaction(SIGSYS, &sa, nullptr);
    }
    scmp_filter_ctx ctx = seccomp_init(m == Mode::Trap ? SCMP_ACT_TRAP : SCMP_ACT_KILL_PROCESS);
    if (!ctx) return false;
    seccomp_attr_set(ctx, SCMP_FLTATR_CTL_TSYNC, 1);
    // Steady-state syscalls of: inference thread pool, libjpeg, HTTP server,
    // MQTT client, camera ingest, glibc runtime. Derived with `strace -f -c`.
    static const char* allow[] = {
        "read", "write", "readv", "writev", "pread64", "pwrite64", "close", "fstat", "newfstatat", "statx",
        "lseek", "mmap", "munmap", "mprotect", "madvise", "mremap", "brk", "futex", "futex_waitv",
        "clock_gettime", "clock_getres", "clock_nanosleep", "nanosleep", "gettimeofday", "time",
        "sched_yield", "sched_getaffinity", "sched_setaffinity", "sched_getparam", "sched_getscheduler",
        "sched_get_priority_min", "sched_get_priority_max", "getpriority", "setpriority",
        "getpid", "gettid", "getppid", "getuid", "geteuid", "getgid", "getegid", "getgroups",
        "tgkill", "tkill", "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "sigaltstack",
        "exit", "exit_group", "restart_syscall", "poll", "ppoll", "select", "pselect6",
        "epoll_create1", "epoll_ctl", "epoll_wait", "epoll_pwait", "eventfd2", "pipe", "pipe2",
        "connect", "accept", "accept4", "sendto", "recvfrom", "sendmsg", "recvmsg", "sendmmsg",
        "recvmmsg", "setsockopt", "getsockopt", "getsockname", "getpeername", "shutdown", "bind",
        "listen", "fcntl", "ioctl", "openat", "open", "getdents64", "readlink", "readlinkat",
        "access", "faccessat", "faccessat2", "getcwd", "dup", "dup2", "dup3",
        "clone", "clone3", "set_robust_list", "get_robust_list", "rseq", "set_tid_address",
        "prlimit64", "getrlimit", "getrusage", "times", "getrandom", "uname", "sysinfo",
        "membarrier", "mlock", "munlock", "mincore", "prctl", "arch_prctl", "wait4",
    };
    int added = 0;
    for (const char* name : allow) {
        int nr = seccomp_syscall_resolve_name(name);
        if (nr == __NR_SCMP_ERROR) continue;
        if (seccomp_rule_add(ctx, SCMP_ACT_ALLOW, nr, 0) == 0) ++added;
    }
    // socket(): only IPv4, UNIX and NETLINK (glibc getaddrinfo) - no raw/packet sockets
    for (int dom : {AF_INET, AF_UNIX, AF_NETLINK})
        seccomp_rule_add(ctx, SCMP_ACT_ALLOW, SCMP_SYS(socket), 1, SCMP_A0(SCMP_CMP_EQ, (scmp_datum_t)dom));
    // IPv6 is compiled out of this kernel: answer like the kernel would instead of killing
    // (glibc's resolver probes AF_INET6/UDP during getaddrinfo, e.g. ORT's telemetry client)
    seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EAFNOSUPPORT), SCMP_SYS(socket), 1, SCMP_A0(SCMP_CMP_EQ, (scmp_datum_t)AF_INET6));
    int rc = seccomp_load(ctx);
    seccomp_release(ctx);
    if (rc != 0) {
        logf("sandbox: seccomp_load failed: %s", strerror(-rc));
        return false;
    }
    logf("sandbox: seccomp-bpf %s, %d syscalls allowed (default: %s)", modeName(m), added + 1,
         m == Mode::Trap ? "SIGSYS" : "kill process");
    return true;
}

// Each probe runs in a forked child so a seccomp kill does not take the daemon down.
int selfTest() {
    struct Probe { const char* what; int (*fn)(); };
    static const Probe probes[] = {
        {"write a file under /data", [] { int fd = open("/data/pwned", O_CREAT | O_WRONLY, 0644); return fd >= 0 ? 0 : errno; }},
        {"modify /etc/passwd", [] { int fd = open("/etc/passwd", O_WRONLY | O_APPEND); return fd >= 0 ? 0 : errno; }},
        {"execve /bin/sh", [] { char* a[] = {(char*)"/bin/sh", (char*)"-c", (char*)"id", nullptr}; execv("/bin/sh", a); return errno; }},
        {"open raw packet socket", [] { int s = socket(AF_PACKET, SOCK_RAW, 0); return s >= 0 ? 0 : errno; }},
        {"ptrace a process", [] { long r = syscall(SYS_ptrace, 16 /*PTRACE_ATTACH*/, 1, 0, 0); return r == 0 ? 0 : errno; }},
        {"mount a filesystem", [] { long r = syscall(SYS_mount, "none", "/tmp", "tmpfs", 0, nullptr); return r == 0 ? 0 : errno; }},
        {"regain root (setuid 0)", [] { return setuid(0) == 0 ? 0 : errno; }},
    };
    int blocked = 0, n = 0;
    for (const auto& p : probes) {
        ++n;
        fflush(stderr);
        pid_t pid = fork();
        if (pid == 0) _exit(p.fn() == 0 ? 0 : 1);
        int st = 0;
        waitpid(pid, &st, 0);
        const char* res;
        char buf[64];
        if (WIFSIGNALED(st)) {
            std::snprintf(buf, sizeof buf, "BLOCKED (killed by signal %d - seccomp)", WTERMSIG(st));
            res = buf;
            ++blocked;
        } else if (WEXITSTATUS(st) != 0) {
            res = "BLOCKED (permission denied - privileges/landlock)";
            ++blocked;
        } else {
            res = "ALLOWED  <-- not contained!";
        }
        std::fprintf(stderr, "  sandbox probe %-28s %s\n", p.what, res);
    }
    std::fprintf(stderr, "  sandbox self-test: %d/%d forbidden operations blocked\n", blocked, n);
    return blocked == n ? 0 : 1;
}

}  // namespace sandbox
