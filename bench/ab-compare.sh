#!/usr/bin/env bash
# Interleaved A/B inference comparison: EdgeSight (dev image) vs stock Ubuntu 24.04 running the
# SAME edgesightd binary + libs (and the stock Python/pip pipeline).
#
# Why interleaved: the host is a hybrid CPU (P/E/LP-E cores) under Windows, which migrates
# QEMU's vCPU threads between core types; runs taken minutes apart differ by up to 40 %.
# Both VMs stay booted (idle) and the benchmark alternates A, B, A, B ... so every pair
# sees the same host conditions. Reported value = median over rounds.
#   bench/ab-compare.sh [rounds]        (needs baseline/ubuntu/run-baseline.sh done once)
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
ROUNDS=${1:-5}; N=${N:-300}
RES="$REPO/bench/results"; mkdir -p "$RES"
OUTF="$RES/ab-compare.jsonl"; : > "$OUTF"
UB="$WORK/baseline"
U_SSH=(ssh "${SSH_OPTS[@]}" -p 2223 ubuntu@127.0.0.1)
export RUN_NAME=ab

c_info "booting EdgeSight dev + Ubuntu baseline side by side"
vm_stop dev
pkill -f "[q]emu-system-x86_64 -name ubuntu-baseline" 2>/dev/null; sleep 1
vm_start dev --fresh
qemu-system-x86_64 -name ubuntu-baseline -machine q35,accel=kvm -cpu host -smp 2 -m 1024 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$UB/vars.fd" \
    -drive file="$UB/work.qcow2",format=qcow2,if=virtio,cache=writeback \
    -drive file="$UB/seed.img",format=raw,if=virtio,readonly=on \
    -netdev "user,id=n0,hostfwd=tcp::2223-:22" -device virtio-net-pci,netdev=n0,romfile= \
    -device virtio-rng-pci -nodefaults -no-user-config -display none \
    -serial file:"$UB/serial-ab.log" -pidfile "$UB/qemu-ab.pid" -daemonize
trap 'vm_stop dev; kill $(cat "$UB/qemu-ab.pid") 2>/dev/null' EXIT
wait_log dev "marked good" 120 >/dev/null; wait_ssh 150 || exit 1
t=0; until "${U_SSH[@]}" true </dev/null 2>/dev/null; do sleep 1; t=$((t+1)); [ $t -gt 300 ] && exit 1; done
dev_ssh 'touch /run/edgesight-hold; killall edgesightd; true' </dev/null
"${U_SSH[@]}" 'sudo systemctl stop edgesight' </dev/null
# Ubuntu must run exactly the binary, libraries and (build-time optimised) models of this build
T="$WORK/output-dev/target"
tar -C "$T" -czf - usr/bin/edgesightd usr/lib lib usr/share/edgesight \
    | "${U_SSH[@]}" 'sudo rm -rf /opt/edgesight && sudo mkdir -p /opt/edgesight && sudo tar -C /opt/edgesight -xzf -'
"${U_SSH[@]}" 'sha256sum /opt/edgesight/usr/bin/edgesightd /opt/edgesight/usr/share/edgesight/models/*.onnx | cut -c1-16' </dev/null | tr '\n' ' '
echo " <- Ubuntu copy"; sha256sum "$T/usr/bin/edgesightd" "$T"/usr/share/edgesight/models/*.onnx | cut -c1-16 | tr '\n' ' '; echo " <- EdgeSight"
sleep 20   # let both guests settle (cloud-init / snapd timers on Ubuntu, nothing on EdgeSight)

EM=/usr/share/edgesight/models; ES_S=/usr/share/edgesight/samples
UM=/opt/edgesight/usr/share/edgesight/models; US=/opt/edgesight/usr/share/edgesight/samples
ESRUN='/opt/edgesight/lib/ld-linux-x86-64.so.2 --library-path /opt/edgesight/lib:/opt/edgesight/usr/lib /opt/edgesight/usr/bin/edgesightd'
one() {  # one <system> <label> <cmd> <via>
    local j
    local try
    for try in 1 2; do  # one retry on a dropped SSH connection
        if [ "$4" = es ]; then j=$(dev_ssh "$3 2>/dev/null" </dev/null | grep '^{'); else j=$("${U_SSH[@]}" "$3 2>/dev/null" </dev/null | grep '^{'); fi
        [ -n "$j" ] && break; sleep 2
    done
    [ -n "$j" ] && jq -c --arg s "$1" --arg l "$2" --argjson r "$r" '. + {system:$s, label:$l, round:$r}' <<<"$j" >> "$OUTF"
}
for r in $(seq 1 "$ROUNDS"); do
    c_info "round $r/$ROUNDS"
    for cfg in "int8 1" "int8 2" "fp32 1" "fp32 2"; do
        set -- $cfg; m=$1; th=$2
        one edgesight "ort $m t$th" "/usr/bin/edgesightd --bench $N --warmup 30 --sandbox off --runtime ort --model $EM/ssd_mobilenet_v1_$m.onnx --threads $th --source dir:$ES_S" es
        one ubuntu    "ort $m t$th" "$ESRUN --bench $N --warmup 30 --runtime ort --model $UM/ssd_mobilenet_v1_$m.onnx --threads $th --source dir:$US" ub
        one ubuntu-python "ort $m t$th" "~/ml/bin/python stock_pipeline.py --model $UM/ssd_mobilenet_v1_$m.onnx --samples $US --threads $th --bench $N" ub
    done
done

c_info "medians over $ROUNDS rounds (infer p50 / p99 ms, end-to-end FPS)"
jq -s -r '
  def med: sort | if length == 0 then null else .[(length/2|floor)] end;
  group_by(.label) | .[] | . as $g | ($g[0].label) as $l |
  ($g | group_by(.system) | map({s: .[0].system, p50: (map(.latency_ms.infer.p50)|med), p99: (map(.latency_ms.infer.p99)|med),
        fps: (map(.fps)|med), rss: (map(.peak_rss_mib)|med), cpu: (map(.cpu_ms_per_frame)|med)})) |
  map("\($l)  \(.s|.+"              "|.[0:14])  p50 \(.p50*10|round/10)  p99 \(.p99*10|round/10)  fps \(.fps*10|round/10)  rss \(.rss|round)  cpu/frame \(.cpu*10|round/10)") | .[]' "$OUTF" \
  | tee "$RES/ab-compare-summary.txt"
