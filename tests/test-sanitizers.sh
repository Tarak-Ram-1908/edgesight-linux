#!/usr/bin/env bash
# Memory-safety check of edgesightd: build it with AddressSanitizer + UndefinedBehaviorSanitizer
# against the dev image's sysroot, run it inside the dev VM in place of the service, drive it
# with the normal workload + tests/fuzz.py, and fail on any sanitizer report.
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
OUT="$WORK/output-dev"
B="$WORK/asan-build"
export RUN_NAME=test-sanitizers
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }

c_info "building edgesightd with -fsanitize=address,undefined"
rm -rf "$B" && mkdir -p "$B"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined -g -O1"
cmake -S "$WORK/src/app/edgesightd" -B "$B" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$OUT/host/share/buildroot/toolchainfile.cmake" \
    -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="$SAN" -DCMAKE_EXE_LINKER_FLAGS="$SAN" >/dev/null || exit 1
cmake --build "$B" >/dev/null || { c_bad "sanitizer build failed"; exit 1; }
TC="$OUT/host/opt/ext-toolchain/x86_64-buildroot-linux-gnu/lib64"

vm_stop dev
trap 'vm_stop dev' EXIT
vm_start dev --fresh
wait_log dev "marked good" 120 >/dev/null && wait_ssh 150 || { c_bad "dev VM did not come up"; exit 1; }
dev_ssh 'touch /run/edgesight-hold; killall edgesightd; sleep 1; mount -o remount,exec /tmp; mkdir -p /tmp/asan' </dev/null
# Dropbear has no SFTP subsystem (OpenSSH's scp needs it): stream the files over ssh instead
for f in "$B/edgesightd" "$TC/libasan.so.8" "$TC/libubsan.so.1"; do
    dev_ssh "cat > /tmp/asan/$(basename "$f") && chmod 755 /tmp/asan/$(basename "$f")" < "$f"
done
dev_ssh 'ls -la /tmp/asan' </dev/null | sed 's/^/    /'
c_info "running sanitized daemon in the VM (camera + HTTP + MQTT, sample loop flat out)"
dev_ssh 'cd /tmp/asan && (ASAN_OPTIONS=detect_leaks=1:abort_on_error=0:log_path=/tmp/asan/report UBSAN_OPTIONS=print_stacktrace=1:log_path=/tmp/asan/report \
    LD_LIBRARY_PATH=/tmp/asan nohup ./edgesightd --runtime ort --model /usr/share/edgesight/models/ssd_mobilenet_v1_int8.onnx \
    --source dir:/usr/share/edgesight/samples --camera-port 5000 --fps 0 --http-port 8080 --mqtt 127.0.0.1:1883 \
    --selftest /usr/share/edgesight/samples/000000039769.jpg --sandbox off > /tmp/asan/stderr.log 2>&1 &)' </dev/null
for _ in $(seq 1 60); do curl -sf -m 1 http://127.0.0.1:${HTTP_FWD:-8080}/healthz >/dev/null && break; sleep 1; done
python3 "$REPO/tests/fuzz.py" "$WORK/output-dev/target/usr/share/edgesight/samples" "${HTTP_FWD:-8080}" "${CAM_FWD:-5000}"
fz=$?
frames=$(curl -sf -m 3 http://127.0.0.1:${HTTP_FWD:-8080}/metrics | python3 -c 'import json,sys; print(json.load(sys.stdin)["frames"])')
# clean shutdown so LeakSanitizer runs its end-of-process check, then the other backends
dev_ssh 'killall -TERM edgesightd; sleep 4
  cd /tmp/asan; M=/usr/share/edgesight/models
  for args in "--runtime tflite --model $M/ssd_mobilenet_v1_uint8.tflite" "--runtime tflite --no-xnnpack --model $M/ssd_mobilenet_v1_uint8.tflite" \
              "--runtime ort --model $M/ssd_mobilenet_v1_fp32.onnx"; do
    ASAN_OPTIONS=detect_leaks=1:log_path=/tmp/asan/report UBSAN_OPTIONS=print_stacktrace=1:log_path=/tmp/asan/report \
      LD_LIBRARY_PATH=/tmp/asan ./edgesightd --bench 60 --warmup 5 --sandbox off $args 2>/dev/null \
      | sed -n "s/.*\"engine\":\"\([^\"]*\)\".*\"frames\":\([0-9]*\).*/  bench under ASan: \1, \2 frames OK/p"
  done
  ls /tmp/asan/; cat /tmp/asan/report* 2>/dev/null | head -60; tail -3 /tmp/asan/stderr.log' </dev/null | tee "$REPO/bench/results/sanitizer-output.txt"
echo "  frames processed under ASan/UBSan: $frames"
check "fuzz phases survived under ASan/UBSan" '[ $fz -eq 0 ]'
check "no AddressSanitizer report"            '! grep -q "ERROR: AddressSanitizer" "$REPO/bench/results/sanitizer-output.txt"'
check "no LeakSanitizer report"               '! grep -q "ERROR: LeakSanitizer" "$REPO/bench/results/sanitizer-output.txt"'
check "no UndefinedBehaviorSanitizer report"  '! grep -q "runtime error:" "$REPO/bench/results/sanitizer-output.txt"'
[ $fails -eq 0 ] && c_ok "test-sanitizers: all checks passed" || c_bad "test-sanitizers: $fails failed"
exit $fails
