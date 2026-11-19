#!/usr/bin/env bash
# Inference benchmark matrix inside the EdgeSight dev image (identical kernel config
# except dev.cfg, identical userland + app). The live service is paused first.
#   bench/run-bench.sh            runtime x precision x threads matrix
#   bench/run-bench.sh isolation  CPU-isolation jitter ablation (reboots with isolcpus)
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
RES="$REPO/bench/results"; mkdir -p "$RES"
export RUN_NAME=bench
N=${N:-300}; WARM=${WARM:-30}
M=/usr/share/edgesight/models
MODE=${1:-matrix}

boot() {
    vm_stop dev
    vm_start dev "$@"
    wait_log dev EDGESIGHT_READY 120 >/dev/null || { c_bad "dev VM did not boot"; exit 1; }
    # Pausing the service before RAUC confirmed the slot would (correctly!) trigger the
    # health-check rollback -> wait for "marked good" first.
    wait_log dev "marked good" 90 >/dev/null || { c_bad "slot not confirmed"; exit 1; }
    wait_ssh 150 || exit 1
    dev_ssh 'touch /run/edgesight-hold; killall edgesightd; sleep 1; killall -9 edgesightd 2>/dev/null; true'
}
run() {  # run <label> <args...>
    local label=$1; shift
    local j
    # one retry: about 1 in 25 SSH connections to Dropbear drops right after a CPU-saturating run
    # (ssh exit 255, the benchmark itself never failed - verified separately)
    j=$(dev_ssh "$* 2>/dev/null" </dev/null | grep '^{') || j=$(sleep 2; dev_ssh "$* 2>/dev/null" </dev/null | grep '^{') \
        || { c_bad "  $label failed"; return; }
    jq -c --arg l "$label" '. + {label:$l}' <<<"$j" | tee -a "$OUTF" | jq -r '"  \(.label|.[0:34]|. + " " * (34-length))  \(.fps|tostring|.[0:6]) fps  infer p50 \(.latency_ms.infer.p50) ms  p99 \(.latency_ms.infer.p99) ms  rss \(.peak_rss_mib) MiB"'
}
B="/usr/bin/edgesightd --bench $N --warmup $WARM --sandbox off --score 0.5"

if [ "$MODE" = matrix ]; then
    OUTF="$RES/bench-edgesight.jsonl"; : > "$OUTF"
    boot --fresh
    # The host is a hybrid-core laptop: single runs swing by +/-40 %. Every configuration is
    # therefore run once per round, rounds interleaved, and report.py takes the median.
    ROUNDS=${ROUNDS:-5}
    c_info "== inference matrix (N=$N, SMP=${SMP:-2}, $ROUNDS interleaved rounds) =="
    for r in $(seq 1 "$ROUNDS"); do
        c_info "-- round $r/$ROUNDS"
        for t in 1 2; do
            run "ort fp32 t$t"             "$B --runtime ort --model $M/ssd_mobilenet_v1_fp32.onnx --threads $t"
            run "ort int8 t$t"             "$B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads $t"
            run "tflite uint8+xnnpack t$t" "$B --runtime tflite --model $M/ssd_mobilenet_v1_uint8.tflite --threads $t"
            run "tflite uint8 ref t$t"     "$B --runtime tflite --no-xnnpack --model $M/ssd_mobilenet_v1_uint8.tflite --threads $t"
        done
        run "ort int8 t2 sandbox=strict" "$B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads 2 --sandbox strict --user edgesight"
        run "ort int8 t2 no-spin"        "EDGESIGHT_ORT_SPIN=0 $B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads 2"
    done
    vm_stop dev
elif [ "$MODE" = isolation ]; then
    OUTF="$RES/bench-isolation.jsonl"; : > "$OUTF"
    HOG='P=; for i in 1 2 3; do (while :; do :; done) & P="$P $!"; done'
    c_info "== baseline: no isolation, 3 CPU hogs =="
    boot --fresh
    run "shared cpu + hogs"      "$HOG; $B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads 1; kill \$P"
    run "shared cpu idle"        "$B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads 1"
    c_info "== isolcpus=1 nohz_full=1, service pinned to cpu1, same hogs =="
    n=$(log_lines dev)
    dev_ssh 'grub-editenv /boot/efi/EFI/BOOT/grubenv set "extra_cmdline=isolcpus=1 nohz_full=1 rcu_nocbs=1"; sync; reboot' || true
    wait_log dev "marked good" 150 "$n" >/dev/null || { c_bad "isolated boot not confirmed"; exit 1; }
    wait_ssh 150
    dev_ssh 'touch /run/edgesight-hold; killall edgesightd; true'
    dev_ssh 'cat /sys/devices/system/cpu/isolated' | sed 's/^/  isolated cpus: /'
    PIN='mkdir -p /sys/fs/cgroup/rt && echo 1 > /sys/fs/cgroup/rt/cpuset.cpus && echo $$ > /sys/fs/cgroup/rt/cgroup.procs'
    run "isolated cpu1 + hogs"   "$HOG; $PIN; $B --runtime ort --model $M/ssd_mobilenet_v1_int8.onnx --threads 1; kill \$P"
    vm_stop dev
fi
c_ok "results: $OUTF"
