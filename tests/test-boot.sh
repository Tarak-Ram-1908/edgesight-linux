#!/usr/bin/env bash
# End-to-end acceptance test: fresh image -> boot -> service ready -> dashboard,
# metrics, MQTT detections, RAUC slot confirmation, closed ports.
# Also records boot timing (host wall clock and guest kernel uptime).
#   tests/test-boot.sh [prod|dev] [runs]
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
V=${1:-prod}; RUNS=${2:-1}
export RUN_NAME="test-boot-$V"
RES="$REPO/bench/results"; mkdir -p "$RES"
OUTF="$RES/boot-$V.jsonl"; : > "$OUTF"
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }

for run in $(seq 1 "$RUNS"); do
    c_info "== boot run $run/$RUNS ($V) =="
    vm_stop "$V"
    t0=$(date +%s.%N)
    vm_start "$V" --fresh
    if ! line=$(wait_log "$V" 'EDGESIGHT_READY' 120); then
        c_bad "service never became ready"; tail -40 "$(vm_dir "$V")/serial.log"; vm_stop "$V"; exit 1
    fi
    t_ready=$(date +%s.%N)
    grub_line=$(grep -a -m1 'EdgeSight: booting slot' "$(vm_dir "$V")/serial.log" || true)
    up=$(sed -n 's/.*uptime=\([0-9.]*\).*/\1/p' <<<"$line")
    wall=$(echo "$t_ready - $t0" | bc -l)
    fw=$(echo "$wall - $up" | bc -l)
    printf '  launch->ready %.2fs   (firmware+GRUB+kernel decompress %.2fs, kernel start->app ready %.2fs)\n' "$wall" "$fw" "$up"

    # healthz may lag READY by one frame
    for _ in $(seq 1 20); do curl -sf -m 2 "http://127.0.0.1:${HTTP_FWD:-8080}/healthz" >/dev/null && break; sleep 0.5; done
    metrics=$(curl -sf -m 3 "http://127.0.0.1:${HTTP_FWD:-8080}/metrics")
    if [ "$run" = 1 ]; then
        check "/healthz returns 200"          'curl -sf -m 3 http://127.0.0.1:${HTTP_FWD:-8080}/healthz >/dev/null'
        check "dashboard served"              'curl -sf -m 3 -o /tmp/es-index.html http://127.0.0.1:${HTTP_FWD:-8080}/ && grep -q EdgeSight /tmp/es-index.html'
        check "metrics report healthy"        'jq -e .healthy <<<"$metrics" >/dev/null'
        check "MJPEG stream delivers a frame" 'curl -s -m 4 http://127.0.0.1:${HTTP_FWD:-8080}/stream.mjpg -o /tmp/es-stream.bin; grep -aq "image/jpeg" /tmp/es-stream.bin'
        check "MQTT detection received"       'mosquitto_sub -h 127.0.0.1 -p ${MQTT_FWD:-11883} -t edgesight/detections -C 1 -W 15 | jq -e ".detections|length>0" >/dev/null'
        check "RAUC confirmed the boot slot"  'wait_log "$V" "marked good" 60 >/dev/null'
        if [ "$V" = prod ]; then
            check "no SSH service in prod"    '! timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SSH_FWD:-2222}; head -c 4 <&3 | grep -q SSH" 2>/dev/null'
            check "no login prompt on console" '! grep -aq "login:" "$(vm_dir "$V")/serial.log"'
        fi
        sleep 8   # let the sliding latency window fill
        metrics=$(curl -sf -m 3 "http://127.0.0.1:${HTTP_FWD:-8080}/metrics")
        jq '{fps, infer_p50: .latency_ms.infer.p50, infer_p99: .latency_ms.infer.p99, rss_mib, sys_mem_used_mib, sys_mem_total_mib, sandbox, engine, slot}' <<<"$metrics"
    fi
    jq -c --arg wall "$wall" --arg fw "$fw" --arg up "$up" --arg v "$V" \
        '{variant:$v, launch_to_ready_s:($wall|tonumber), firmware_grub_s:($fw|tonumber), kernel_to_ready_s:($up|tonumber),
          sys_mem_used_mib, rss_mib, model_load_ms, engine}' <<<"$metrics" >> "$OUTF"
    vm_stop "$V"
done
[ "$RUNS" -gt 1 ] && jq -s '{runs:length, launch_to_ready_mean:(map(.launch_to_ready_s)|add/length), kernel_to_ready_mean:(map(.kernel_to_ready_s)|add/length), firmware_grub_mean:(map(.firmware_grub_s)|add/length), mem_used_mean:(map(.sys_mem_used_mib)|add/length)}' "$OUTF"
[ $fails -eq 0 ] && c_ok "test-boot: all checks passed" || c_bad "test-boot: $fails check(s) failed"
exit $fails
