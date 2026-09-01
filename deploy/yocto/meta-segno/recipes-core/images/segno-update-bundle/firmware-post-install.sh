#!/bin/sh
# Post-install hook for the RAUC firmware (boot FAT) slot. The bundled vfat is
# captured before tryboot-cmdline rewrites cmdline.txt per slot inside the .wic,
# so it still carries root=XXX. RAUC writes it to the inactive firmware slot
# paired with the inactive rootfs; this hook sets root= to the matching
# rootfs partition (p5 for slot A, p6 for slot B).
#
# Boot disk comes from RAUC_SLOT_DEVICE (e.g. /dev/nvme0n1p2), not system.conf:
# the hook runs on the *currently booted* rootfs during OTA, and meta-rauc
# moved system.conf between releases (/etc/rauc vs /usr/lib/rauc) — a bundle
# built against one policy installing onto a unit with the other would look
# in the wrong place.
#
# The slot is already mounted by RAUC for post-install — edit via
# RAUC_SLOT_MOUNT_POINT (do not remount RAUC_MOUNT_PREFIX$RAUC_SLOT_DEVICE).
set -eu

# The firmware slot has no bootname of its own — modern rauc fills
# RAUC_SLOT_BOOTNAME from the parent rootfs slot (observed on 1.15), but that
# is version-dependent behavior. Fall back to the slot name, which rauc has
# always set, so the mapping cannot silently depend on the running rauc.
slot_id="${RAUC_SLOT_BOOTNAME:-}"
if [ -z "$slot_id" ]; then
    case "${RAUC_SLOT_NAME:-}" in
        firmware.0) slot_id=A ;;
        firmware.1) slot_id=B ;;
    esac
fi
case "$slot_id" in
    A) root_part=5 ;;
    B) root_part=6 ;;
    *)
        echo "firmware-post-install: cannot resolve slot (RAUC_SLOT_BOOTNAME=${RAUC_SLOT_BOOTNAME:-} RAUC_SLOT_NAME=${RAUC_SLOT_NAME:-})" >&2
        exit 1
        ;;
esac

boot_disk=$(printf '%s\n' "${RAUC_SLOT_DEVICE:-}" | sed -n 's|^/dev/\(.*\)p[0-9]\+$|\1|p')
if [ -z "$boot_disk" ]; then
    echo "firmware-post-install: could not parse boot disk from RAUC_SLOT_DEVICE=${RAUC_SLOT_DEVICE:-}" >&2
    exit 1
fi

if [ -z "${RAUC_SLOT_MOUNT_POINT:-}" ] || [ ! -d "$RAUC_SLOT_MOUNT_POINT" ]; then
    echo "firmware-post-install: RAUC_SLOT_MOUNT_POINT unset or missing (${RAUC_SLOT_MOUNT_POINT:-})" >&2
    exit 1
fi

sed -i "s/root=XXX/root=\\/dev\\/${boot_disk}p${root_part}/" "$RAUC_SLOT_MOUNT_POINT/cmdline.txt"
grep -q "root=/dev/${boot_disk}p${root_part}" "$RAUC_SLOT_MOUNT_POINT/cmdline.txt"
