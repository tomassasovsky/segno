#!/bin/sh
# Post-install hook for the RAUC firmware (boot FAT) slot. The bundled vfat is
# captured before tryboot-cmdline rewrites cmdline.txt per slot inside the .wic,
# so it still carries root=XXX. RAUC writes it to the inactive firmware slot
# paired with the inactive rootfs; this hook sets root= to the matching
# rootfs partition (p5 for slot A, p6 for slot B).
set -eu

case "${RAUC_SLOT_BOOTNAME:-}" in
    A) root_part=5 ;;
    B) root_part=6 ;;
    *)
        echo "firmware-post-install: unknown RAUC_SLOT_BOOTNAME=${RAUC_SLOT_BOOTNAME:-}" >&2
        exit 1
        ;;
esac

boot_disk=$(sed -n 's|^device=/dev/\(.*\)p[0-9]\+$|\1|p' /usr/lib/rauc/system.conf | head -1)
if [ -z "$boot_disk" ]; then
    echo "firmware-post-install: could not parse boot disk from system.conf" >&2
    exit 1
fi

mountpoint=$(mktemp -d)
trap 'umount "$mountpoint" 2>/dev/null; rmdir "$mountpoint" 2>/dev/null' EXIT INT TERM

mount "$RAUC_MOUNT_PREFIX$RAUC_SLOT_DEVICE" "$mountpoint"
sed -i "s/root=XXX/root=\\/dev\\/${boot_disk}p${root_part}/" "$mountpoint/cmdline.txt"
grep -q "root=/dev/${boot_disk}p${root_part}" "$mountpoint/cmdline.txt"
