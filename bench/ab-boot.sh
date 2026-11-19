#!/usr/bin/env bash
# Interleaved boot-time comparison: EdgeSight prod vs Ubuntu 24.04 (+ the same detector as a
# systemd service), alternating E, U, E, U ... so both see the same host conditions.
#   power-on -> detecting : host wall clock from QEMU launch until /healthz answers
#   kernel   -> detecting : guest uptime printed by edgesightd's EDGESIGHT_READY line
#   bench/ab-boot.sh [rounds]     (needs baseline/ubuntu/run-baseline.sh done once)
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
ROUNDS=${1:-5}
RES="$REPO/bench/results"; OUTF="$RES/ab-boot.jsonl"; : > "$OUTF"
UB="$WORK/baseline"
U_SSH=(ssh "${SSH_OPTS[@]}" -p 2223 ubuntu@127.0.0.1)
export RUN_NAME=ab-boot
now() { date +%s.%N; }

boot_es() {
    vm_stop prod
    local t0; t0=$(now)
    vm_start prod --fresh-disk   # keep NVRAM, like the Ubuntu VM (fair firmware phase)
    until curl -sf -m 1 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do sleep 0.05; done
    local t1; t1=$(now)
    local up; up=$(wait_log prod EDGESIGHT_READY 30 | sed -n 's/.*uptime=\([0-9.]*\).*/\1/p')
    local mem; mem=$(curl -sf -m 2 http://127.0.0.1:8080/metrics | jq .sys_mem_used_mib)
    vm_stop prod
    echo "{\"system\":\"edgesight\",\"round\":$1,\"launch_to_ready_s\":$(echo "$t1 - $t0" | bc -l),\"kernel_to_ready_s\":$up,\"sys_mem_used_mib\":$mem}" >> "$OUTF"
}
boot_ub() {
    pkill -f "[q]emu-system-x86_64 -name ubuntu-baseline" 2>/dev/null; sleep 0.5
    local t0; t0=$(now)
    qemu-system-x86_64 -name ubuntu-baseline -machine q35,accel=kvm -cpu host -smp 2 -m 1024 \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,file="$UB/vars.fd" \
        -drive file="$UB/work.qcow2",format=qcow2,if=virtio,cache=writeback \
        -drive file="$UB/seed.img",format=raw,if=virtio,readonly=on \
        -netdev "user,id=n0,hostfwd=tcp::2223-:22,hostfwd=tcp::8081-:8080" -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci -nodefaults -no-user-config -display none \
        -serial file:"$UB/serial-abboot.log" -pidfile "$UB/qemu-abboot.pid" -daemonize
    until curl -sf -m 1 http://127.0.0.1:8081/healthz >/dev/null 2>&1; do sleep 0.05; done
    local t1; t1=$(now)
    local t=0; until "${U_SSH[@]}" true </dev/null 2>/dev/null; do sleep 0.5; t=$((t+1)); [ $t -gt 240 ] && break; done
    local up; up=$("${U_SSH[@]}" "journalctl -b -u edgesight -o cat | grep -m1 EDGESIGHT_READY | sed 's/.*uptime=\([0-9.]*\).*/\1/'" </dev/null)
    local mem; mem=$("${U_SSH[@]}" "awk '/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{printf \"%.1f\",(t-a)/1024}' /proc/meminfo" </dev/null)
    "${U_SSH[@]}" 'sudo poweroff' </dev/null >/dev/null 2>&1 || true
    sleep 4; kill "$(cat "$UB/qemu-abboot.pid")" 2>/dev/null || true
    echo "{\"system\":\"ubuntu\",\"round\":$1,\"launch_to_ready_s\":$(echo "$t1 - $t0" | bc -l),\"kernel_to_ready_s\":${up:-null},\"sys_mem_used_mib\":${mem:-null}}" >> "$OUTF"
}

for r in $(seq 1 "$ROUNDS"); do
    c_info "round $r/$ROUNDS"
    boot_es "$r"; tail -1 "$OUTF"
    boot_ub "$r"; tail -1 "$OUTF"
done
jq -s -r 'def med: sort | .[(length/2|floor)];
  group_by(.system)[] | "\(.[0].system): power-on->ready median \(map(.launch_to_ready_s)|med*100|round/100) s, kernel->ready median \(map(.kernel_to_ready_s)|med*100|round/100) s, mem \(map(.sys_mem_used_mib)|med) MiB"' "$OUTF" \
  | tee "$RES/ab-boot-summary.txt"
