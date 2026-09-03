#!/bin/sh
# RAUC install hook — writes a boot slot the way this appliance needs it.
#
# RAUC's own vfat handler cannot do this job on this image:
#
#   * it drives GNU tar (--numeric-owner, --xattrs, --selinux) and the rootfs
#     ships busybox tar, which fails the extraction outright;
#   * it labels the filesystem after the SLOT (FIRMWARE_0), while the disk
#     layout labels these partitions bootA / bootB and mounts by label.
#
# So this hook replaces the write: format with the label the layout expects,
# extract the boot files, and point cmdline.txt at this slot's own rootfs.
#
# That last part is not a detail. Which rootfs a boot slot boots is a property
# of the SLOT, not of the build, so the bundle ships one boot filesystem with a
# root=XXX placeholder and each slot is pointed at its own — exactly what the
# image build does per slot inside the .wic (tryboot-cmdline.bbclass). Get it
# wrong and the console boots the slot the update just replaced, or panics with
# no rootfs, after a reboot, with nobody watching.
#
# Layout, from meta-segno/wic/segno-tryboot.wks.in — a boot slot and its rootfs
# are three partitions apart:
#   p2 bootA -> p5 rootA
#   p3 bootB -> p6 rootB
set -eu

log() { echo "segno-bundle-hook: $*" >&2; }

case "$1" in
    slot-install) ;;
    *) exit 0 ;;
esac

# Declared only for the boot slots; RAUC writes the rootfs itself.
[ "${RAUC_SLOT_CLASS:-}" = "firmware" ] || {
    log "not a firmware slot (${RAUC_SLOT_CLASS:-unset}); nothing to do"
    exit 0
}

device="${RAUC_SLOT_DEVICE:?RAUC_SLOT_DEVICE unset}"
image="${RAUC_IMAGE_NAME:?RAUC_IMAGE_NAME unset}"

[ -f "$image" ] || { log "no image at $image"; exit 1; }

# /dev/nvme0n1p3 -> disk=/dev/nvme0n1, part=3 ; /dev/mmcblk0p3 likewise.
part="${device##*p}"
disk="${device%p*}"
case "$part" in
    ''|*[!0-9]*) log "cannot read a partition number from $device"; exit 1 ;;
esac

case "$part" in
    2) label=bootA ;;
    3) label=bootB ;;
    *) log "$device is not one of the boot slots this layout defines"; exit 1 ;;
esac
root_device="${disk}p$((part + 3))"

mkfs=$(command -v mkfs.vfat || command -v mkfs.fat) || {
    log "no mkfs.vfat on this image"
    exit 1
}

log "formatting $device as $label"
"$mkfs" -n "$label" "$device" >/dev/null || { log "mkfs failed on $device"; exit 1; }

mount_point=$(mktemp -d)
cleanup() { umount "$mount_point" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true; }
trap cleanup EXIT

mount -t vfat "$device" "$mount_point" || { log "cannot mount $device"; exit 1; }

# Plain `tar -xf`: no flags this rootfs's tar may not have, and the archive is
# uncompressed so nothing has to sniff a format.
tar -xf "$image" -C "$mount_point" || { log "extracting $image into $device failed"; exit 1; }

cmdline="$mount_point/cmdline.txt"
[ -f "$cmdline" ] || { log "no cmdline.txt in the extracted boot files"; exit 1; }

# Demand the placeholder. Substituting into a file that does not have it
# reports success and leaves a slot that panics with no rootfs, saying nothing
# about why — the same reasoning as the image-build rewrite.
if ! grep -q 'root=XXX' "$cmdline"; then
    log "no root=XXX placeholder in the boot files; refusing to guess"
    exit 1
fi

# Not `sed -i`: busybox and BSD disagree about whether it takes a suffix, and
# this script is edited on a Mac and runs on the appliance.
rewritten=$(mktemp)
sed "s|root=XXX|root=$root_device|" "$cmdline" > "$rewritten"
cat "$rewritten" > "$cmdline"
rm -f "$rewritten"

# Read it back rather than trusting the write.
if ! grep -q "root=$root_device" "$cmdline" || grep -q 'root=XXX' "$cmdline"; then
    log "cmdline.txt did not take root=$root_device"
    exit 1
fi

sync
log "${RAUC_SLOT_NAME:-$device} written as $label, booting $root_device"
