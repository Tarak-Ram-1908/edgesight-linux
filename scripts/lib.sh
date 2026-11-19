# Shared helpers for tests/ and bench/ (source this file).
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e ' ' -e '^/mnt/' | paste -sd: -)"
export PATH
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${EDGESIGHT_WORK:-$HOME/edgesight-work}"

c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_bad()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m%s\033[0m\n' "$*"; }

# vm_start <variant> [extra run-qemu args]   (RUN_NAME selects the state dir)
vm_start() {
    local v=$1; shift
    "$REPO/run-qemu.sh" "$v" --headless "$@" >/dev/null
}
vm_dir() { echo "$WORK/run/${RUN_NAME:-$1}"; }
# vm_monitor <variant> <hmp command>   e.g. vm_monitor prod "system_reset"
vm_monitor() {
    local d; d=$(vm_dir "$1")
    python3 - "$d/monitor.sock" "$2" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(1)
try: s.recv(4096)
except Exception: pass
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.3)
try: print(s.recv(65536).decode(errors="replace"))
except Exception: pass
EOF
}
vm_stop() {
    local d; d=$(vm_dir "$1")
    if [ -S "$d/monitor.sock" ]; then vm_monitor "$1" quit >/dev/null 2>&1 || true; fi
    if [ -f "$d/qemu.pid" ]; then kill "$(cat "$d/qemu.pid")" 2>/dev/null || true; sleep 0.5; fi
    rm -f "$d/qemu.pid"
}
# wait_log <variant> <regex> <timeout-s> [from-line]  -> prints matching line, rc!=0 on timeout
wait_log() {
    local d; d=$(vm_dir "$1"); local re=$2 to=$3 from=${4:-1} t=0
    while [ "$t" -lt $((to * 10)) ]; do
        if [ -f "$d/serial.log" ] && tail -n +"$from" "$d/serial.log" | grep -a -m1 -E "$re"; then return 0; fi
        sleep 0.1; t=$((t + 1))
    done
    return 1
}
# SSH into a DEV guest (key installed by post-build.sh, mirrored with 0600 by build.sh)
SSH_KEY="$WORK/src/keys/ssh_ed25519"
SSH_OPTS=(-q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
dev_ssh() { ssh "${SSH_OPTS[@]}" -p "${SSH_FWD:-2222}" root@127.0.0.1 "$@"; }
dev_scp() { scp "${SSH_OPTS[@]}" -P "${SSH_FWD:-2222}" "$@"; }
# (explicit return 0: a loop's status is that of the last command in its body)
wait_ssh() { local t=0; while ! dev_ssh true </dev/null 2>/dev/null; do sleep 1; t=$((t+1)); [ $t -gt "${1:-120}" ] && return 1; done; return 0; }
log_lines() { local d; d=$(vm_dir "$1"); wc -l < "$d/serial.log" 2>/dev/null || echo 0; }
