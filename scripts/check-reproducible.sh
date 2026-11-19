#!/usr/bin/env bash
# Reproducibility proof: rebuild the prod image FROM SCRATCH (fresh host tools and target
# build; only the download cache and ccache are shared) at the SAME output path, then
# compare every artefact byte for byte with the previous build.
#
# Same path matters: Buildroot sanitises RPATHs by padding them with 'X' to the length of
# the build directory, so builds in directories of different length differ in exactly those
# bytes (verified: a first attempt with output-prod vs output-prod-repro differed only there).
#   scripts/check-reproducible.sh     -> bench/results/reproducibility.txt
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OUT="$WORK/output-prod"
REF="$WORK/output-prod-ref"
REPORT="$REPO/bench/results/reproducibility.txt"
FILES="bzImage rootfs.squashfs rootfs.verity esp.vfat boot.vfat data.ext4 disk.img"

c_info "build A (current tree)"
"$REPO/build.sh" prod > "$WORK/repro-A.log" 2>&1 || { c_bad "build A failed"; exit 1; }
rm -rf "$REF"; mv "$OUT" "$REF"
c_info "build B (from scratch, same path)"
start=$(date +%s)
"$REPO/build.sh" prod > "$WORK/repro-B.log" 2>&1 || { c_bad "build B failed"; exit 1; }
dur=$(( $(date +%s) - start ))

conf="$WORK/repro-rauc.conf"
printf '[system]\ncompatible=edgesight-x86_64\nbootloader=noop\n[keyring]\npath=%s\ncheck-purpose=codesign\n' \
    "$WORK/src/keys/ca.cert.pem" > "$conf"
payload() { "$OUT/host/bin/rauc" --conf="$conf" info --output-format=shell "$1" 2>/dev/null \
            | grep -E "^RAUC_IMAGE_DIGEST|^RAUC_BUNDLE_VERITY_HASH|^RAUC_MF_VERSION"; }

{
    echo "EdgeSight reproducibility check - $(date -u +%FT%TZ)"
    echo "build B: complete rebuild from scratch at the same path (${dur}s, shared dl/ + ccache only)"
    echo
    ok=0; n=0
    for f in $FILES; do
        n=$((n+1))
        ha=$(sha256sum "$REF/images/$f" | cut -c1-64); hb=$(sha256sum "$OUT/images/$f" | cut -c1-64)
        if [ "$ha" = "$hb" ]; then r=IDENTICAL; ok=$((ok+1)); else r="DIFFERENT (B: ${hb:0:16})"; fi
        printf '%-16s %s  %s\n' "$f" "$ha" "$r"
    done
    pa=$(payload "$REF/images/edgesight-1.0.0.raucb"); pb=$(payload "$OUT/images/edgesight-1.0.0.raucb")
    echo
    echo "signed bundle payload (manifest image digests + bundle verity root hash):"
    echo "$pa" | sed 's/^/  A: /'
    if [ -n "$pa" ] && [ "$pa" = "$pb" ]; then echo "  -> IDENTICAL payload; .raucb files differ only in the CMS signing time"
    else echo "  -> DIFFERENT or unreadable"; echo "$pb" | sed 's/^/  B: /'; fi
    echo
    echo "RESULT: $ok/$n image artefacts bit-identical"
} | tee "$REPORT"
