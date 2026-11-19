#!/usr/bin/env bash
# Hostile-input robustness of the production image (strict sandbox, release binary):
# tests/fuzz.py attacks the camera ingest and HTTP server; afterwards the service must be
# healthy and must NOT have crashed or restarted (no "exited", no seccomp "Bad system call").
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
V=prod
export RUN_NAME=test-robustness
SAMPLES="$WORK/output-$V/target/usr/share/edgesight/samples"
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }

vm_stop $V
trap 'vm_stop $V' EXIT
vm_start $V --fresh
wait_log $V "marked good" 120 >/dev/null || { c_bad "image did not come up"; exit 1; }
python3 "$REPO/tests/fuzz.py" "$SAMPLES" "${HTTP_FWD:-8080}" "${CAM_FWD:-5000}"
fz=$?
LOG="$(vm_dir $V)/serial.log"
check "all fuzz phases survived"            '[ $fz -eq 0 ]'
check "daemon never crashed or restarted"   '! grep -a -qE "edgesightd exited|Bad system call|Segmentation|Aborted" "$LOG"'
check "still the first daemon instance"     '[ "$(grep -a -c "EdgeSight .* starting" "$LOG")" -eq 1 ]'
check "service healthy at the end"          'curl -sf -m 3 http://127.0.0.1:${HTTP_FWD:-8080}/healthz >/dev/null'
grep -a -E "dropping undecodable|camera (dis)?connected" "$LOG" | sort | uniq -c | sort -rn | head -5 | sed 's/^/    | /'
[ $fails -eq 0 ] && c_ok "test-robustness: all checks passed" || c_bad "test-robustness: $fails failed"
exit $fails
