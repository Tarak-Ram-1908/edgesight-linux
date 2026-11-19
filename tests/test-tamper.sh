#!/usr/bin/env bash
# Offline tampering of the ACTIVE root filesystem slot must be detected by dm-verity
# on first read; the kernel panics (panic_on_corruption), GRUB sees the slot was tried
# but never confirmed, and boots the other slot, which RAUC then confirms.
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
V=prod
export RUN_NAME=test-tamper
D=$(vm_dir $V)
IMG="$WORK/output-$V/images/disk.img"
fails=0
check() { if eval "$2"; then c_ok "  PASS  $1"; else c_bad "  FAIL  $1"; fails=$((fails+1)); fi; }

vm_stop $V
mkdir -p "$D"
cp --sparse=always "$IMG" "$D/disk.img"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"

START=$(sfdisk -J "$D/disk.img" | jq '.partitiontable.partitions[3].start')
OFF=$((START * 512 + 64))
c_info "corrupting 16 bytes of rootA (partition 4) at byte offset $OFF (squashfs superblock)"
printf 'EVIL-MAID-WAS-HERE' | dd of="$D/disk.img" bs=1 seek=$OFF count=16 conv=notrunc status=none

vm_start $V
check "dm-verity detects the modified block" 'wait_log $V "verity.*(corrupt|mismatch)|data block.*corrupt" 60 >/dev/null'
check "kernel refuses to continue (panic)"  'wait_log $V "Kernel panic" 20 >/dev/null'
check "GRUB falls back to slot B"           'wait_log $V "booting slot B" 60 >/dev/null'
check "service comes up from slot B"        'wait_log $V "EDGESIGHT_READY" 90 >/dev/null'
check "slot B confirmed by health check"    'wait_log $V "slot B .* marked good" 60 >/dev/null'
grep -a -E "verity|panic|booting slot|EDGESIGHT_READY|marked good" "$D/serial.log" | head -12 | sed 's/^/    | /'
vm_stop $V
[ $fails -eq 0 ] && c_ok "test-tamper: all checks passed" || c_bad "test-tamper: $fails failed"
exit $fails
