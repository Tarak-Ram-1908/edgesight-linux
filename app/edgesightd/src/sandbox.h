#pragma once
#include <string>
#include <vector>

// Defence in depth for the network-facing inference daemon. Stages, in order:
//  1. dropPrivileges   root -> dedicated user, no supplementary groups, not dumpable
//  2. no_new_privs     setuid binaries / file caps can never raise privileges again
//  3. Landlock         filesystem becomes read-only + no execute, outside a small allow-list
//  4. seccomp-bpf      syscall allow-list (TSYNC: applied to every thread at once)
namespace sandbox {
enum class Mode { Off, Strict, Trap };
Mode parseMode(const std::string& s);
const char* modeName(Mode m);

bool dropPrivileges(const std::string& user);
bool noNewPrivs();
// readPaths: directories/files that stay readable. Returns ABI version or -1.
int landlock(const std::vector<std::string>& readPaths);
bool seccomp(Mode m);
// Forks probes that try forbidden operations; prints what was blocked.
int selfTest();
}  // namespace sandbox
