#!/usr/bin/env bash
# Signed A/B OTA end to end (needs scripts/make-ota-bundles.sh first):
#   1.0.0 (slot A) -> 1.1.0 installed into B, confirmed
#   tampered bundle -> rejected (verity/signature)
#   bundle signed by a foreign key -> rejected (not chained to the CA)
#   1.2.0 broken -> installed into A, fails health check -> automatic rollback to B (1.1.0)
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
V=prod
export RUN_NAME=test-ota
B="$WORK/bundles"
OTA="$REPO/host-tools/ota-server.sh"
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }
since() { log_lines $V; }
metric() { curl -sf -m 3 "http://127.0.0.1:${HTTP_FWD:-8080}/metrics" | jq -r "$1"; }

for f in 1.1.0 1.2.0 1.1.1-tampered 6.6.6-rogue; do
    [ -f "$B/edgesight-$f.raucb" ] || { c_bad "missing $B/edgesight-$f.raucb - run scripts/make-ota-bundles.sh"; exit 1; }
done

vm_stop $V
"$OTA" withdraw >/dev/null
pkill -f "http.server 8000" 2>/dev/null || true
"$OTA" serve 8000 > "$WORK/ota-server.log" 2>&1 &
OTA_PID=$!
trap 'kill $OTA_PID 2>/dev/null; vm_stop $V' EXIT

c_info "== boot 1.0.0 =="
vm_start $V --fresh
check "1.0.0 ready in slot A"         'wait_log $V "EDGESIGHT_READY" 120 >/dev/null && wait_log $V "slot A v1.0.0 healthy" 60 >/dev/null'

c_info "== good update 1.1.0 =="
n=$(since); "$OTA" publish "$B/edgesight-1.1.0.raucb" 1.1.0
check "agent installs 1.1.0"          'wait_log $V "installed 1.1.0" 180 $n >/dev/null'
check "reboots into slot B"           'wait_log $V "booting slot B" 120 $n >/dev/null'
check "1.1.0 confirmed by health check" 'wait_log $V "update 1.1.0 confirmed" 120 $n >/dev/null'
check "running version is 1.1.0 / INT8" '[ "$(metric .version)" = 1.1.0 ] && metric .model | grep -q int8'

c_info "== tampered bundle =="
n=$(since); "$OTA" publish "$B/edgesight-1.1.1-tampered.raucb" 1.1.1-tampered
check "tampered bundle rejected"      'wait_log $V "REJECTED 1.1.1-tampered" 120 $n'
check "  ...by bundle dm-verity (payload hash)" 'wait_log $V "verity: 7:[0-9]+: data block [0-9]+ is corrupted" 20 $n >/dev/null'
check "  ...while 1.1.0 keeps running"  '[ "$(metric .version)" = 1.1.0 ]'

c_info "== bundle signed by an untrusted key =="
n=$(since); "$OTA" publish "$B/edgesight-6.6.6-rogue.raucb" 6.6.6
check "rogue-signed bundle rejected"  'wait_log $V "REJECTED 6.6.6" 120 $n'
check "  ...by signature check (signer not in keyring)" 'wait_log $V "signature verification failed" 20 $n >/dev/null'

c_info "== broken update 1.2.0 =="
n=$(since); "$OTA" publish "$B/edgesight-1.2.0.raucb" 1.2.0
check "agent installs 1.2.0 into A"   'wait_log $V "installed 1.2.0" 180 $n >/dev/null'
check "1.2.0 fails its health check"  'wait_log $V "FAILED health check" 200 $n'
check "automatic rollback to slot B"  'wait_log $V "update 1.2.0 did not survive" 240 $n'
check "1.1.0 serving again"           '[ "$(metric .version)" = 1.1.0 ] && [ "$(metric .slot)" = B ]'
check "1.2.0 is not retried"          '! wait_log $V "update available: 1.1.0 -> 1.2.0" 40 "$(since)" >/dev/null'

grep -a -E "edgesight-(ota|health)|booting slot" "$(vm_dir $V)/serial.log" | sed 's/^/    | /'
"$OTA" withdraw >/dev/null
[ $fails -eq 0 ] && c_ok "test-ota: all checks passed" || c_bad "test-ota: $fails failed"
exit $fails
