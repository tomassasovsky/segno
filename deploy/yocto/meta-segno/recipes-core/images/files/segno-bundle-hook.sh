#!/bin/sh
# RAUC install hook — points a freshly written boot slot at its own rootfs.
#
# The bundle carries ONE boot filesystem, with cmdline.txt still holding the
# root=XXX placeholder the image build ships. Which rootfs a boot slot boots is
# a property of the SLOT, not of the build: bootA must boot rootA and bootB
# rootB, or an update turns the console into a unit that boots the slot it just
# replaced. The image build does this substitution inside the .wic
# (tryboot-cmdline.bbclass); this does the same on the device.
#
# Layout, from meta-segno/wic/segno-tryboot.wks.in — the boot slot and its
# rootfs are three partitions apart:
#   p2 bootA -> p5 rootA
#   p3 bootB -> p6 rootB
set -eu

log() { echo "segno-bundle-hook: $*" >&2; }

case "$1" in
    slot-post-install) ;;
    *) exit 0 ;;
esac

[ "${RAUC_SLOT_CLASS:-}" = "firmware" ] || exit 0

device="${RAUC_SLOT_DEVICE:?RAUC_SLOT_DEVICE unset}"

# /dev/nvme0n1p3 -> disk=/dev/nvme0n1, part=3 ; /dev/mmcblk0p3 likewise.
part="${device##*p}"
disk="${device%p*}"
case "$part" in
    ''|*[!0-9]*) log "cannot read a partition number from $device"; exit 1 ;;
esac

root_part=$((part + 3))
root_device="${disk}p${root_part}"

mount_point=$(mktemp -d)
cleanup() { umount "$mount_point" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true; }
trap cleanup EXIT

mount -t vfat "$device" "$mount_point" || { log "cannot mount $device"; exit 1; }

cmdline="$mount_point/cmdline.txt"
[ -f "$cmdline" ] || { log "no cmdline.txt in $device"; exit 1; }

# Demand the placeholder. A plain substitution on a file that does not have it
# reports success and leaves a slot that panics with no rootfs, saying nothing
# about why — the same reasoning as the image-build rewrite.
if ! grep -q 'root=XXX' "$cmdline"; then
    log "no root=XXX placeholder in $device's cmdline.txt; refusing to guess"
    exit 1
fi

# Not `sed -i`: busybox and BSD disagree about whether it takes a suffix, and
# this script is edited on a Mac and run on the appliance. Rewrite through a
# temp file and copy the contents back, so the FAT directory entry stays put.
rewritten=$(mktemp)
sed "s|root=XXX|root=$root_device|" "$cmdline" > "$rewritten"
cat "$rewritten" > "$cmdline"
rm -f "$rewritten"

# Read it back rather than trusting the write.
if ! grep -q "root=$root_device" "$cmdline" || grep -q 'root=XXX' "$cmdline"; then
    log "cmdline.txt in $device did not take root=$root_device"
    exit 1
fi

sync
log "$RAUC_SLOT_NAME ($device) now boots $root_device"
