#!/usr/bin/env bash
# Where do the bytes of the prod root filesystem go? (uncompressed, from the staged target)
#   scripts/size-breakdown.sh [prod|dev]  -> out/<v>/size-breakdown.txt
set -uo pipefail
. "$(dirname "$0")/lib.sh"
V=${1:-prod}
T="$WORK/output-$V/target"
OUTF="$REPO/out/$V/size-breakdown.txt"
sz() { du -cb "$@" 2>/dev/null | tail -1 | cut -f1; }
total=$(du -sb "$T" | cut -f1)
{
printf '%-44s %10s %6s\n' component bytes share
row() { printf '%-44s %10d %5.1f%%\n' "$1" "$2" "$(echo "100*$2/$total" | bc -l)"; }
row "models (ONNX fp32+int8, TFLite uint8)"  "$(sz "$T"/usr/share/edgesight/models)"
row "sample frames"                          "$(sz "$T"/usr/share/edgesight/samples)"
row "libonnxruntime"                         "$(sz "$T"/usr/lib/libonnxruntime.so*)"
row "TFLite + XNNPACK + abseil + deps"       "$(sz "$T"/usr/lib/libtensorflow-lite* "$T"/usr/lib/libXNNPACK* "$T"/usr/lib/libabsl* "$T"/usr/lib/libcpuinfo* "$T"/usr/lib/libfarmhash* "$T"/usr/lib/libfft2d* "$T"/usr/lib/libflatbuffers* "$T"/usr/lib/libpthreadpool* "$T"/usr/lib/libruy*)"
row "glibc + libstdc++ + libgcc"             "$(sz "$T"/lib/libc.so* "$T"/lib/libm.so* "$T"/lib/ld-linux* "$T"/lib/libpthread* "$T"/lib/libdl* "$T"/lib/librt* "$T"/lib/libresolv* "$T"/lib/libnss* "$T"/usr/lib/libstdc++* "$T"/lib/libgcc_s* "$T"/lib/libatomic*)"
row "RAUC + glib + OpenSSL (update stack)"   "$(sz "$T"/usr/bin/rauc "$T"/usr/lib/libglib* "$T"/usr/lib/libgio* "$T"/usr/lib/libgobject* "$T"/usr/lib/libgmodule* "$T"/usr/lib/libffi* "$T"/usr/lib/libpcre2* "$T"/usr/lib/libcrypto* "$T"/usr/lib/libssl* "$T"/usr/lib/libz.so*)"
row "GRUB tools (grub-editenv etc.)"         "$(sz "$T"/bin/grub-* "$T"/sbin/grub-* "$T"/usr/bin/grub-* "$T"/usr/sbin/grub-* "$T"/lib/grub "$T"/usr/lib/grub)"
row "nftables + libmnl/nftnl/gmp/jansson"    "$(sz "$T"/usr/sbin/nft "$T"/usr/lib/libnft* "$T"/usr/lib/libmnl* "$T"/usr/lib/libgmp* "$T"/usr/lib/libjansson* "$T"/usr/lib/libedit* "$T"/usr/lib/libncurses*)"
row "mosquitto broker + lib"                 "$(sz "$T"/usr/sbin/mosquitto "$T"/usr/lib/libmosquitto*)"
row "edgesightd + libjpeg-turbo + libseccomp" "$(sz "$T"/usr/bin/edgesightd "$T"/usr/lib/libjpeg* "$T"/usr/lib/libturbojpeg* "$T"/usr/lib/libseccomp*)"
row "BusyBox"                                "$(sz "$T"/bin/busybox)"
row "TOTAL (uncompressed)"                   "$total"
echo
echo "largest 15 files:"
find "$T" -type f -printf '%s %P\n' | sort -rn | head -15 | awk '{printf "  %10d  %s\n", $1, $2}'
} | tee "$OUTF"
