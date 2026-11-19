#!/bin/sh
# Runs inside fakeroot AFTER Buildroot applied package permission tables, right before
# the squashfs is created. Buildroot's BusyBox package installs /bin/busybox setuid-root
# (for su/passwd/ping as a normal user); this appliance has no interactive users, so no
# binary on the image may carry setuid/setgid bits.
set -eu
TARGET="$1"
find "$TARGET" -xdev -type f \( -perm -4000 -o -perm -2000 \) -print -exec chmod u-s,g-s {} + \
    | sed 's/^/post-fakeroot: stripped setuid\/setgid from /'
