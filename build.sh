#!/usr/bin/env bash
# EdgeSight Linux - one-command reproducible build.
#
#   ./build.sh [prod|dev] [buildroot-targets...]      default: prod all
#
# Environment knobs:
#   EDGESIGHT_WORK      work area on a native Linux fs   (default ~/edgesight-work)
#   EDGESIGHT_VERSION   version stamped into image/bundle (default: ./VERSION)
#   EDGESIGHT_BREAK=1   build a deliberately broken image (rollback demo)
#   EDGESIGHT_DEFAULT_MODEL=<path>  change the model the service starts with
#   OUT_SUFFIX          build into output-<variant><suffix> (parallel versions)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WSL appends the Windows PATH (spaces, /mnt/c/...): Buildroot refuses it, and it is
# a reproducibility hazard anyway - build with a clean Linux PATH only.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e ' ' -e '^/mnt/' | paste -sd: -)"
export PATH
VARIANT="${1:-prod}"; [ $# -gt 0 ] && shift
case "$VARIANT" in prod|dev) ;; *) echo "variant must be prod or dev" >&2; exit 2;; esac

BR_VERSION=2026.02.3
BR_URL=https://gitlab.com/buildroot.org/buildroot.git
KERNEL_VERSION=6.12.47
WORK="${EDGESIGHT_WORK:-$HOME/edgesight-work}"
SRC="$WORK/src"                       # space-free mirror of the repo (Buildroot rejects spaces in paths)
BR="$WORK/buildroot"
OUT="$WORK/output-$VARIANT${OUT_SUFFIX:-}"
export BR2_DL_DIR="${BR2_DL_DIR:-$WORK/dl}"
export BR2_CCACHE_DIR="${BR2_CCACHE_DIR:-$WORK/ccache}"
export EDGESIGHT_VERSION="${EDGESIGHT_VERSION:-$(tr -d '[:space:]' < "$REPO/VERSION")}"
# Fixed timestamp => bit-identical images (date of the last commit, else a constant)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || echo 1767225600)}"

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }

# ---- 1. pinned Buildroot -------------------------------------------------------
mkdir -p "$WORK" "$BR2_DL_DIR"
if [ ! -d "$BR/.git" ]; then
    log "cloning Buildroot $BR_VERSION"
    git clone -q --depth 1 -b "$BR_VERSION" "$BR_URL" "$BR"
fi
have=$(git -C "$BR" describe --tags --exact-match 2>/dev/null || echo "?")
[ "$have" = "$BR_VERSION" ] || { echo "Buildroot at $have, expected $BR_VERSION" >&2; exit 1; }

# ---- 2. update-signing keys (dev PKI) --------------------------------------------
[ -f "$REPO/keys/dev.key.pem" ] || "$REPO/scripts/gen-keys.sh"
# SSH key for the DEV image only (test/bench automation); prod has no sshd at all
[ -f "$REPO/keys/ssh_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C edgesight-dev -f "$REPO/keys/ssh_ed25519"

# ---- 3. mirror the repo onto the native fs with sane permissions -----------------
log "syncing sources -> $SRC"
mkdir -p "$SRC"
rsync -a --delete --exclude .git --exclude /out "$REPO/" "$SRC/"
find "$SRC" -type d -exec chmod 0755 {} +
find "$SRC" -type f -exec chmod 0644 {} +
find "$SRC/keys" \( -name '*.key.pem' -o -name ssh_ed25519 \) -exec chmod 0600 {} + 2>/dev/null || true
chmod 0755 "$SRC"/*.sh "$SRC"/scripts/* "$SRC"/tests/*.sh "$SRC"/bench/*.sh 2>/dev/null || true
chmod 0755 "$SRC"/br2-external/board/edgesight/*.sh \
           "$SRC"/br2-external/board/edgesight/rootfs-overlay/etc/init.d/* \
           "$SRC"/br2-external/board/edgesight/rootfs-overlay/usr/libexec/edgesight/*

# ---- 4. configure --------------------------------------------------------------
mkdir -p "$OUT"
DEFCONFIG="$OUT/edgesight_defconfig"
cp "$SRC/br2-external/configs/edgesight_prod_defconfig" "$DEFCONFIG"
[ "$VARIANT" = "dev" ] && cat "$SRC/br2-external/configs/edgesight_dev.fragment" >> "$DEFCONFIG"
BRMAKE=(make -C "$BR" O="$OUT" BR2_EXTERNAL="$SRC/br2-external")
"${BRMAKE[@]}" BR2_DEFCONFIG="$DEFCONFIG" defconfig > /dev/null

# ---- 5. kernel base config = upstream tinyconfig (generated once, committed) ------
TINY="br2-external/board/edgesight/linux/tinyconfig-6.12.config"
if [ ! -f "$REPO/$TINY" ]; then
    log "generating $TINY from linux-$KERNEL_VERSION 'make tinyconfig'"
    "${BRMAKE[@]}" host-flex host-bison linux-extract
    KSRC="$OUT/build/linux-$KERNEL_VERSION"
    TMPO="$(mktemp -d)"
    PATH="$OUT/host/bin:$PATH" make -s -C "$KSRC" O="$TMPO" ARCH=x86_64 tinyconfig
    cp "$TMPO/.config" "$REPO/$TINY"
    cp "$TMPO/.config" "$SRC/$TINY"
    rm -rf "$TMPO"
fi

# ---- 6. build -------------------------------------------------------------------
# Buildroot does not notice edits to (a) a SITE_METHOD=local package's source tree or
# (b) kernel config fragments once those packages are built - an incremental build would
# silently ship the old binary / old kernel. Fingerprint both and force a rebuild on change.
fp() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-16; }
APP_FP=$(fp "$SRC/app/edgesightd")
KCFG_FP=$( { fp "$SRC/br2-external/board/edgesight/linux"; grep -E '^BR2_LINUX' "$DEFCONFIG"; } | sha256sum | cut -c1-16)
if [ -d "$OUT/build/edgesightd-1.0" ] && [ "$(cat "$OUT/.fp-edgesightd" 2>/dev/null)" != "$APP_FP" ]; then
    log "edgesightd sources changed -> clean rebuild of the app"
    "${BRMAKE[@]}" edgesightd-dirclean > /dev/null
fi
if [ -d "$OUT/build/linux-$KERNEL_VERSION" ] && [ -f "$OUT/.fp-kernel" ] && [ "$(cat "$OUT/.fp-kernel")" != "$KCFG_FP" ]; then
    log "kernel config fragments changed -> linux-reconfigure"
    "${BRMAKE[@]}" linux-reconfigure > /dev/null
fi

log "building EdgeSight $EDGESIGHT_VERSION ($VARIANT) in $OUT"
start=$(date +%s)
"${BRMAKE[@]}" "$@"
log "build finished in $(( $(date +%s) - start ))s"
echo "$APP_FP" > "$OUT/.fp-edgesightd"
echo "$KCFG_FP" > "$OUT/.fp-kernel"

# ---- 7. collect small deliverables back into the repo -----------------------------
if [ $# -eq 0 ] || [[ " $* " == *" all "* ]]; then
    D="$REPO/out/$VARIANT"
    mkdir -p "$D"
    cp "$OUT/build/linux-$KERNEL_VERSION/.config" "$D/kernel.config"
    cp "$OUT/images/size-report.txt" "$D/"
    cp "$OUT/images/verity.cfg" "$D/"
    cp "$OUT/.config" "$D/buildroot.config"
    # target packages only (host-* build tools never reach the device)
    "${BRMAKE[@]}" -s printvars VARS=PACKAGES 2>/dev/null | tr ' ' '\n' | sed 's/^PACKAGES=//' \
        | grep -E '^[a-z0-9]' | grep -v '^host-' | sort -u > "$D/packages.txt" || true
    [ -f "$OUT/build/packages-file-list.txt" ] && cp "$OUT/build/packages-file-list.txt" "$D/"
    # Licence compliance: package manifest + licence texts (Buildroot legal-info)
    # (a failure here must be visible: a partial manifest silently drops packages)
    if ! "${BRMAKE[@]}" -s legal-info > "$OUT/legal-info.log" 2>&1; then
        log "WARNING: make legal-info failed - see $OUT/legal-info.log"
        tail -5 "$OUT/legal-info.log" >&2
    fi
    if [ -f "$OUT/legal-info/manifest.csv" ]; then
        cp "$OUT/legal-info/manifest.csv" "$D/manifest.csv"
        cp "$OUT/legal-info/host-manifest.csv" "$D/host-manifest.csv" 2>/dev/null || true
    fi
    log "deliverables copied to out/$VARIANT/ ; image: $OUT/images/disk.img"
fi
