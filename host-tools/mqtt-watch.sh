#!/usr/bin/env bash
# Subscribe to the device's MQTT feed from the host (QEMU forwards host:11883 -> guest:1883).
#   host-tools/mqtt-watch.sh            pretty detections
#   host-tools/mqtt-watch.sh metrics    retained metrics document
set -euo pipefail
PORT="${MQTT_FWD:-11883}"
if [ "${1:-}" = "metrics" ]; then
    mosquitto_sub -h 127.0.0.1 -p "$PORT" -t edgesight/metrics -C 1 | python3 -m json.tool
else
    mosquitto_sub -h 127.0.0.1 -p "$PORT" -t edgesight/detections | python3 -u -c '
import json, sys
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    objs = ", ".join(f"{d[\"label\"]} {d[\"score\"]*100:.0f}%" for d in m["detections"]) or "-"
    print(f"#{m[\"seq\"]:>6} {m[\"source\"]:<8} {m[\"infer_ms\"]:6.1f} ms  {objs}")
'
fi
