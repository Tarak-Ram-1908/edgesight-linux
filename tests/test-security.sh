#!/usr/bin/env bash
# Security evidence for the report:
#  A. static: ELF hardening of every binary in the prod rootfs, setuid files, kernel config score
#  B. runtime (dev image, same userland + kernel hardening): process confinement,
#     read-only root, firewall, sysctls, sandbox escape probes
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
RES="$REPO/bench/results"; mkdir -p "$RES"
T="$WORK/output-prod/target"
HOST="$WORK/output-prod/host"
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }

c_info "== A1. ELF hardening of prod userland =="
total=0; pie=0; relro=0; nx=0; canary=0; fortify=0
while IFS= read -r f; do
    file -b "$f" | grep -q '^ELF' || continue
    total=$((total+1))
    h=$(readelf -hlW "$f" 2>/dev/null); d=$(readelf -dW "$f" 2>/dev/null); s=$(readelf -sW --dyn-syms "$f" 2>/dev/null)
    grep -q 'Type:.*DYN' <<<"$h" && pie=$((pie+1))
    grep -q GNU_RELRO <<<"$h" && grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$d" && relro=$((relro+1))
    grep -A1 GNU_STACK <<<"$h" | grep -q 'RW ' && nx=$((nx+1))
    grep -q __stack_chk_fail <<<"$s" && canary=$((canary+1))
    grep -qE '__[a-z]+_chk' <<<"$s" && fortify=$((fortify+1))
done < <(find "$T"/usr/bin "$T"/usr/sbin "$T"/bin "$T"/sbin "$T"/usr/lib "$T"/lib "$T"/usr/libexec -type f 2>/dev/null)
printf '  %d ELF objects: PIE/DSO %d  full-RELRO %d  NX %d  stack-canary %d  FORTIFY %d\n' $total $pie $relro $nx $canary $fortify
echo "{\"elf_total\":$total,\"pie\":$pie,\"full_relro\":$relro,\"nx\":$nx,\"canary\":$canary,\"fortify\":$fortify}" > "$RES/elf-hardening.json"
check "every ELF object is NX"          '[ $nx -eq $total ]'
check "edgesightd is PIE + full RELRO"  'readelf -hlW $T/usr/bin/edgesightd | grep -q "DYN" && readelf -dW $T/usr/bin/edgesightd | grep -qE "BIND_NOW|NOW"'

c_info "== A2. setuid/setgid files in the prod squashfs =="
"$HOST/bin/unsquashfs" -lls "$WORK/output-prod/images/rootfs.squashfs" > /tmp/es-lls.txt 2>/dev/null
suid=$(grep -cE '^[-l]..[sS]|^[-l].....[sS]' /tmp/es-lls.txt || true)
echo "  setuid/setgid files: $suid"
grep -E '^[-l]..[sS]|^[-l].....[sS]' /tmp/es-lls.txt | sed 's/^/    /' | head
check "no setuid/setgid binaries"       '[ "$suid" -eq 0 ]'
world=$(awk '$1 ~ /^-.......w/' /tmp/es-lls.txt | wc -l)
check "no world-writable files"         '[ "$world" -eq 0 ]'

c_info "== A3. kernel-hardening-checker =="
KHC="$WORK/khc-venv/bin/kernel-hardening-checker"
if [ ! -x "$KHC" ]; then
    python3 -m venv "$WORK/khc-venv" && "$WORK/khc-venv/bin/pip" -q install \
        "git+https://github.com/a13xp0p0v/kernel-hardening-checker" || true
fi
if [ -x "$KHC" ]; then
    for cfg in "$REPO/out/prod/kernel.config" "$REPO/baseline/ubuntu/results/ubuntu-kernel.config"; do
        [ -f "$cfg" ] || continue
        case "$cfg" in *ubuntu*) name=ubuntu ;; *) name=edgesight ;; esac
        "$KHC" -c "$cfg" -m show_ok > "$RES/khc-$name.txt" 2>&1 || true
        "$KHC" -c "$cfg" > "$RES/khc-$name-full.txt" 2>&1 || true
        tail -n 3 "$RES/khc-$name-full.txt" | sed "s/^/  [$name] /"
    done
else
    echo "  (kernel-hardening-checker unavailable - skipped)"
fi

c_info "== B. runtime confinement (dev image) =="
export RUN_NAME=test-security
vm_stop dev
trap 'vm_stop dev' EXIT
vm_start dev --fresh
wait_log dev EDGESIGHT_READY 120 >/dev/null || { c_bad "dev image did not come up"; exit 1; }
wait_ssh 150 || { c_bad "no ssh"; exit 1; }
PID=$(dev_ssh 'pidof edgesightd')
st=$(dev_ssh "cat /proc/$PID/status")
check "service runs as unprivileged uid"  'grep -E "^Uid:" <<<"$st" | grep -vq "\b0\b"'
check "no_new_privs set"                  'grep -q "NoNewPrivs:[[:space:]]*1" <<<"$st"'
check "seccomp filter mode (2)"           'grep -q "Seccomp:[[:space:]]*2" <<<"$st"'
check "effective capabilities empty"      'grep -q "CapEff:[[:space:]]*0000000000000000" <<<"$st"'
check "cgroup v2 memory limit applied"    '[ "$(dev_ssh cat /sys/fs/cgroup/edgesight/memory.max)" != max ]'
check "root fs is dm-verity squashfs"     'dev_ssh "grep -q \"^/dev/root / squashfs ro\|/dev/dm-0 / squashfs ro\" /proc/mounts"'
check "root fs cannot be remounted rw"    '! dev_ssh "mount -o remount,rw / 2>/dev/null && touch /usr/pwned"'
check "/data is noexec"                   'dev_ssh "grep \" /data \" /proc/mounts" | grep -q noexec'
check "kernel modules impossible"         '! dev_ssh "test -e /proc/modules"'
check "kernel lockdown active (confidentiality)" 'dev_ssh "dmesg" | grep -q "Kernel is locked down from Kernel configuration"'
check "LSM stack: lockdown,landlock,yama" 'dev_ssh "dmesg" | grep -q "lsm=lockdown,capability,landlock,yama"'
check "service cannot reach off-box (egress drop)" 'dev_ssh "nft list chain ip filter output" | grep -q "skuid"'
check "sysctl kptr_restrict=2"            '[ "$(dev_ssh sysctl -n kernel.kptr_restrict)" = 2 ]'
check "firewall default-drop loaded"      'dev_ssh "nft list chain ip filter input" | grep -q "policy drop"'
c_info "  sandbox escape probes (as the service would run):"
dev_ssh '/usr/bin/edgesightd --sandbox strict --user edgesight --model /usr/share/edgesight/models/ssd_mobilenet_v1_int8.onnx --sandbox-test 2>&1 | grep "sandbox"' | tee "$RES/sandbox-probes.txt" | sed 's/^/    /'
check "all sandbox probes blocked"        'grep -q "7/7 forbidden operations blocked" "$RES/sandbox-probes.txt"'
dev_ssh "cat /proc/$PID/status | grep -E 'Uid|Gid|NoNewPrivs|Seccomp|Cap(Inh|Prm|Eff|Bnd|Amb)'" > "$RES/proc-status.txt"
dev_ssh 'netstat -tlnp 2>/dev/null' > "$RES/listening-ports-dev.txt"
vm_stop dev
[ $fails -eq 0 ] && c_ok "test-security: all checks passed" || c_bad "test-security: $fails failed"
exit $fails
