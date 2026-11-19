#!/bin/sh
# EdgeSight post-build: runs on the staged target tree before the rootfs image is made.
#   $1 = TARGET_DIR   $2 = variant (prod|dev)
set -eu

TARGET="$1"
VARIANT="${2:-prod}"
BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$BOARD_DIR/../../.." && pwd)"
VERSION="${EDGESIGHT_VERSION:-1.0.0}"
GIT_REV="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u -d "@${SOURCE_DATE_EPOCH:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# 1. We ship our own init (rcS + inittab): drop every SysV script packages installed
rm -f "$TARGET"/etc/init.d/S[0-9]*

# 2. Identity
cat > "$TARGET/etc/os-release" <<EOF
NAME="EdgeSight Linux"
ID=edgesight
VERSION_ID=$VERSION
VERSION="$VERSION ($VARIANT)"
PRETTY_NAME="EdgeSight Linux $VERSION ($VARIANT)"
BUILD_ID=$GIT_REV
VARIANT_ID=$VARIANT
HOME_URL="https://github.com/"
EOF
echo "$VERSION" > "$TARGET/etc/edgesight-version"
mkdir -p "$TARGET/usr/share/edgesight"
printf 'version=%s\nvariant=%s\ngit=%s\nsource_date=%s\n' \
    "$VERSION" "$VARIANT" "$GIT_REV" "$BUILD_DATE" > "$TARGET/usr/share/edgesight/build-info"

# 3. Mount points for the read-only root
mkdir -p "$TARGET/boot/efi" "$TARGET/data" "$TARGET/sys/fs/cgroup"

# 4. Update trust anchor: only bundles signed by this CA are installable
if [ -f "$REPO_DIR/keys/ca.cert.pem" ]; then
    install -D -m 0644 "$REPO_DIR/keys/ca.cert.pem" "$TARGET/etc/rauc/ca.cert.pem"
else
    echo "post-build: WARNING keys/ca.cert.pem missing - run scripts/gen-keys.sh" >&2
fi

# 5. Fault-injection build used by the rollback demo (tests/test-ota.sh)
if [ "${EDGESIGHT_BREAK:-0}" = "1" ]; then
    sed -i 's#^MODEL=.*#MODEL=/usr/share/edgesight/models/does-not-exist.onnx#' \
        "$TARGET/etc/edgesight/edgesight.conf"
    echo "post-build: *** BROKEN build (EDGESIGHT_BREAK=1) for rollback testing ***"
fi
if [ -n "${EDGESIGHT_DEFAULT_MODEL:-}" ]; then
    sed -i "s#^MODEL=.*#MODEL=$EDGESIGHT_DEFAULT_MODEL#" "$TARGET/etc/edgesight/edgesight.conf"
fi

# 6. Offline graph optimisation of the ONNX models (ORT "extended" level), done once here
#    instead of on every boot: ~halves model load time, same inference speed, deterministic.
#    The just-built target edgesightd is run on the build host through the target's own
#    dynamic loader (host must be x86-64-v3, like the target).
SRC_MODELS="${STAGING_DIR:-}/usr/share/edgesight/models-src"
if [ -x "$TARGET/usr/bin/edgesightd" ] && [ -d "$SRC_MODELS" ]; then
    for m in "$SRC_MODELS"/*.onnx; do
        out="$TARGET/usr/share/edgesight/models/$(basename "$m")"
        "$TARGET/lib/ld-linux-x86-64.so.2" --library-path "$TARGET/lib:$TARGET/usr/lib" \
            "$TARGET/usr/bin/edgesightd" --model "$m" --optimize-model "$out.tmp" 2>/dev/null \
            && mv "$out.tmp" "$out" \
            || { rm -f "$out.tmp"; echo "post-build: WARNING offline optimisation of $(basename "$m") failed, shipping original" >&2; }
    done
fi

# 7. Trim: things no package should have left behind on a headless appliance
rm -rf "$TARGET/usr/share/man" "$TARGET/usr/share/doc" "$TARGET/usr/share/info" \
       "$TARGET/usr/lib/pkgconfig" "$TARGET/usr/share/pkgconfig" \
       "$TARGET/usr/lib/cmake" "$TARGET/usr/share/aclocal"
find "$TARGET" -name '*.a' -delete
# Build-time tools that packages install but an appliance never runs (~18 MB):
#  - GRUB "install tools": RAUC only needs grub-editenv; grub-install/mkrescue/modules are
#    also exactly what an attacker would want to re-flash the bootloader
for f in "$TARGET"/bin/grub-* "$TARGET"/sbin/grub-* "$TARGET"/usr/bin/grub-* "$TARGET"/usr/sbin/grub-*; do
    [ -e "$f" ] && [ "$(basename "$f")" != grub-editenv ] && rm -f "$f"
done
rm -rf "$TARGET/lib/grub" "$TARGET/usr/lib/grub" "$TARGET/usr/share/grub" "$TARGET/etc/grub.d"
#  - FlatBuffers schema compiler, GLib/GIO CLIs, cpuinfo debug tools
rm -f "$TARGET"/usr/bin/flatc "$TARGET"/usr/bin/gapplication "$TARGET"/usr/bin/gdbus \
      "$TARGET"/usr/bin/gio "$TARGET"/usr/bin/gio-querymodules "$TARGET"/usr/bin/gresource \
      "$TARGET"/usr/bin/gsettings "$TARGET"/usr/bin/gi-* "$TARGET"/usr/bin/glib-* \
      "$TARGET"/usr/bin/gobject-query "$TARGET"/usr/bin/cache-info "$TARGET"/usr/bin/cpu-info \
      "$TARGET"/usr/bin/cpuid-dump "$TARGET"/usr/bin/isa-info
# mosquitto ships passwd/ctrl helpers we never use on the device
rm -f "$TARGET/usr/bin/mosquitto_passwd" "$TARGET/usr/bin/mosquitto_ctrl"
if [ "$VARIANT" = "prod" ]; then
    rm -f "$TARGET/usr/bin/mosquitto_pub" "$TARGET/usr/bin/mosquitto_sub" "$TARGET/usr/bin/mosquitto_rr"
fi

if [ "$VARIANT" = "dev" ] && [ -f "$REPO_DIR/keys/ssh_ed25519.pub" ]; then
    install -D -m 0600 "$REPO_DIR/keys/ssh_ed25519.pub" "$TARGET/root/.ssh/authorized_keys"
    chmod 0700 "$TARGET/root/.ssh"
fi

chmod 0700 "$TARGET/root"
