#!/usr/bin/env bash
# Produces the update bundles used by tests/test-ota.sh and the demo:
#   1.1.0           good update: service switches to the INT8 model
#   1.2.0           signed but broken (model path wrong) -> must roll back
#   1.1.1-tampered  1.1.0 with one payload byte flipped -> must be rejected
#   6.6.6           valid bundle re-signed with a key NOT issued by our CA -> rejected
# then rebuilds 1.0.0 so output-prod/images/disk.img is the baseline image again.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
B="$WORK/bundles"; mkdir -p "$B"
IMGS="$WORK/output-prod/images"
RAUC="$WORK/output-prod/host/bin/rauc"
KEYS="$WORK/src/keys"

c_info "[1/4] building 1.1.0 (INT8 model)"
EDGESIGHT_VERSION=1.1.0 EDGESIGHT_DEFAULT_MODEL=/usr/share/edgesight/models/ssd_mobilenet_v1_int8.onnx \
    "$REPO/build.sh" prod > "$B/build-1.1.0.log" 2>&1
cp "$IMGS/edgesight-1.1.0.raucb" "$B/"

c_info "[2/4] building 1.2.0 (deliberately broken)"
EDGESIGHT_VERSION=1.2.0 EDGESIGHT_BREAK=1 "$REPO/build.sh" prod > "$B/build-1.2.0.log" 2>&1
cp "$IMGS/edgesight-1.2.0.raucb" "$B/"

c_info "[3/4] forging bundles"
cp "$B/edgesight-1.1.0.raucb" "$B/edgesight-1.1.1-tampered.raucb"
SZ=$(stat -c %s "$B/edgesight-1.1.1-tampered.raucb")
printf '\xff' | dd of="$B/edgesight-1.1.1-tampered.raucb" bs=1 seek=$((SZ / 3)) count=1 conv=notrunc status=none
# host-side verification with the same trust policy as the device (codeSigning EKU required)
cat > "$B/host-rauc.conf" <<EOF
[system]
compatible=edgesight-x86_64
bootloader=noop
[keyring]
path=$KEYS/ca.cert.pem
check-purpose=codesign
EOF
rm -rf "$B/x" && "$RAUC" --conf="$B/host-rauc.conf" extract "$B/edgesight-1.1.0.raucb" "$B/x" >/dev/null
sed -i 's/^version=.*/version=6.6.6/; /^sha256=/d; /^size=/d; /^verity-/d' "$B/x/manifest.raucm"
rm -f "$B/edgesight-6.6.6-rogue.raucb"
"$RAUC" bundle --cert="$KEYS/attacker.cert.pem" --key="$KEYS/attacker.key.pem" "$B/x" "$B/edgesight-6.6.6-rogue.raucb" >/dev/null
rm -rf "$B/x"

c_info "[4/4] rebuilding baseline 1.0.0"
EDGESIGHT_VERSION=1.0.0 "$REPO/build.sh" prod > "$B/build-1.0.0.log" 2>&1
cp "$IMGS/edgesight-1.0.0.raucb" "$B/"
ls -la "$B"/*.raucb
