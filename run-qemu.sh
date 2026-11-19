#!/usr/bin/env bash
# Boot an EdgeSight image in QEMU (UEFI/OVMF, q35, KVM).
#
#   ./run-qemu.sh [prod|dev] [--fresh|--fresh-disk] [--headless] [--tcg]
#
#   --fresh       pristine copy of the built disk.img AND empty UEFI NVRAM (first-ever power-on)
#   --fresh-disk  pristine disk.img but keep the UEFI NVRAM (like re-flashing a deployed box)
#   --headless  serial -> $RUN/serial.log, monitor -> $RUN/monitor.sock, runs in background
#   --tcg       no KVM (pure emulation; ~10x slower, for machines without VT-x)
#
# Host ports:  8080 dashboard | 11883 MQTT | 5000 camera ingest | 2222 ssh (dev)
# Env: SMP (2) MEM (1024) HTTP_FWD MQTT_FWD CAM_FWD SSH_FWD  OUT_SUFFIX  RUN_NAME
set -euo pipefail
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e ' ' -e '^/mnt/' | paste -sd: -)"

VARIANT=prod; FRESH=0; HEADLESS=0; ACCEL=kvm
for a in "$@"; do
    case "$a" in
        prod|dev) VARIANT=$a ;;
        --fresh) FRESH=1 ;;
        --fresh-disk) FRESH=2 ;;
        --headless) HEADLESS=1 ;;
        --tcg) ACCEL=tcg ;;
        *) echo "unknown arg $a" >&2; exit 2 ;;
    esac
done
[ -w /dev/kvm ] || ACCEL=tcg

WORK="${EDGESIGHT_WORK:-$HOME/edgesight-work}"
IMG="$WORK/output-$VARIANT${OUT_SUFFIX:-}/images/disk.img"
RUN="$WORK/run/${RUN_NAME:-$VARIANT}"
mkdir -p "$RUN"
[ -f "$IMG" ] || { echo "no image at $IMG - run ./build.sh $VARIANT first" >&2; exit 1; }

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
if [ $FRESH != 0 ] || [ ! -f "$RUN/disk.img" ]; then
    cp --sparse=always "$IMG" "$RUN/disk.img"
fi
if [ $FRESH = 1 ] || [ ! -f "$RUN/OVMF_VARS.fd" ]; then
    cp "$OVMF_VARS" "$RUN/OVMF_VARS.fd"
fi

CPU=host; [ "$ACCEL" = tcg ] && CPU=max
ARGS=(
    -name "edgesight-$VARIANT"
    -machine q35,accel="$ACCEL" -cpu "$CPU" -smp "${SMP:-2}" -m "${MEM:-1024}"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$RUN/OVMF_VARS.fd"
    -drive file="$RUN/disk.img",format=raw,if=virtio,cache=writeback
    -netdev "user,id=n0,hostfwd=tcp::${HTTP_FWD:-8080}-:8080,hostfwd=tcp::${MQTT_FWD:-11883}-:1883,hostfwd=tcp::${CAM_FWD:-5000}-:5000,hostfwd=tcp::${SSH_FWD:-2222}-:22"
    -device virtio-net-pci,netdev=n0,romfile=
    -device virtio-rng-pci
    -nodefaults -no-user-config
)

if [ $HEADLESS = 1 ]; then
    rm -f "$RUN/serial.log" "$RUN/monitor.sock"
    date +%s.%N > "$RUN/launch.ts"
    qemu-system-x86_64 "${ARGS[@]}" -display none \
        -serial file:"$RUN/serial.log" \
        -monitor unix:"$RUN/monitor.sock",server,nowait \
        -pidfile "$RUN/qemu.pid" -daemonize
    echo "started headless (pid $(cat "$RUN/qemu.pid")), serial log: $RUN/serial.log"
else
    echo "EdgeSight $VARIANT - dashboard http://localhost:${HTTP_FWD:-8080}  (Ctrl-A X to quit)"
    exec qemu-system-x86_64 "${ARGS[@]}" -nographic -serial mon:stdio
fi
