#!/usr/bin/env bash
# Full validation of the deliverable: rebuild both variants, then every test suite.
# Logs go to bench/results/test-*.log; a summary to bench/results/summary.txt.
#   scripts/run-all-tests.sh            (~45 min with warm caches)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
R="$REPO/bench/results"; mkdir -p "$R"
SUM="$R/summary.txt"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
step() {  # step <name> <command...>
    local name=$1; shift
    c_info ">> $name"
    local t0=$(date +%s)
    "$@" < /dev/null 2>&1 | strip > "$R/test-$name.log"
    local rc=${PIPESTATUS[0]}
    local pass=$(grep -cE '^\s+PASS' "$R/test-$name.log"); local fail=$(grep -cE '^\s+FAIL' "$R/test-$name.log")
    printf '%-11s rc=%d  pass=%-3d fail=%-3d  %4ds\n' "$name" "$rc" "$pass" "$fail" $(( $(date +%s) - t0 )) | tee -a "$SUM"
}
echo "EdgeSight validation $(date -u +%FT%TZ)" > "$SUM"
step build-prod  "$REPO/build.sh" prod
step build-dev   "$REPO/build.sh" dev
step kconfig     "$REPO/scripts/check-kernel-config.sh" prod
step boot        "$REPO/tests/test-boot.sh" prod 5
step tamper      "$REPO/tests/test-tamper.sh"
step security    "$REPO/tests/test-security.sh"
step robustness  "$REPO/tests/test-robustness.sh"
step sanitizers  "$REPO/tests/test-sanitizers.sh"
step bundles     "$REPO/scripts/make-ota-bundles.sh"
step ota         "$REPO/tests/test-ota.sh"
cat "$SUM"
