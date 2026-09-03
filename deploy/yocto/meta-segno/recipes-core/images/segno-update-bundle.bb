SUMMARY = "RAUC update bundle (.raucb) for the Segno appliance — boot + rootfs slots"
# Builds a signed, verity-format RAUC bundle carrying segno-kiosk-image's rootfs.
# `rauc install` writes it to the inactive A/B slot. CI publishes it per channel.
inherit bundle

RAUC_BUNDLE_FORMAT     = "verity"
# MUST byte-match [system] compatible in the installed system.conf — both are
# rendered from SEGNO_RAUC_COMPATIBLE (set per board in the kas project), so the
# bundle can only ever declare itself compatible with the board it was built for.
SEGNO_RAUC_COMPATIBLE ?= ""
RAUC_BUNDLE_COMPATIBLE = "${SEGNO_RAUC_COMPATIBLE}"

# The build number (CI sets it), same value stamped into /etc/segno/build-version.
# Deterministic — using ${DATETIME} makes the task basehash non-reproducible.
SEGNO_BUILD_VERSION   ?= "0"
RAUC_BUNDLE_VERSION    = "${SEGNO_BUILD_VERSION}"

# Signing material. RAUC_KEYDIR holds development-1.{key,cert}.pem. Default is a
# gitignored dir INSIDE meta-segno so it's visible inside the kas container (which
# only mounts the repo). The PRIVATE key is never committed — populate this dir on
# the build host (and from a secret in CI). Layer-relative so it works under any mount.
RAUC_KEYDIR   ?= "${THISDIR}/../../.rauc-keys"
RAUC_KEY_FILE  = "${RAUC_KEYDIR}/development-1.key.pem"
RAUC_CERT_FILE = "${RAUC_KEYDIR}/development-1.cert.pem"

python __anonymous() {
    import os

    if not d.getVar("SEGNO_RAUC_COMPATIBLE"):
        raise bb.parse.SkipRecipe(
            "SEGNO_RAUC_COMPATIBLE is unset — set it in the board's kas project "
            "(deploy/yocto/kas-segno-rpi{4,5}.yml). An empty compatible string "
            "builds a bundle no device will accept.")

    keyfile = d.getVar("RAUC_KEY_FILE")
    if not keyfile or not os.path.exists(keyfile):
        raise bb.parse.SkipRecipe(
            "RAUC signing key not found at %s. Put development-1.{key,cert}.pem in "
            "RAUC_KEYDIR (default meta-segno/.rauc-keys, gitignored) to build the "
            "update bundle." % keyfile)
}

# Two slots, updated together. The rootfs alone is not a whole update: the
# kernel lives in the boot slot, and so does config.txt — so with rootfs-only
# bundles nothing about how the console STARTS could ever change on a unit in
# the field. A device-tree overlay is exactly what the console board's link
# needs, and it could only ever arrive by re-imaging by hand (#989).
#
# system.conf already declares firmware.0/.1 parented to rootfs.0/.1, and the Pi
# firmware tryboot path already rolls back a slot that fails to boot, so this
# adds an artifact to a mechanism that was built for it rather than a new one.
RAUC_BUNDLE_SLOTS = "rootfs firmware"

RAUC_SLOT_rootfs  = "segno-kiosk-image"
RAUC_SLOT_rootfs[fstype] = "ext4"

# A deployed FILE, not an image recipe: the boot slot's contents are assembled
# from IMAGE_BOOT_FILES rather than built as a rootfs, so there is no
# do_image_complete for the bundle to wait on — it waits on the deploy instead.
RAUC_SLOT_firmware = "segno-bootfs"
RAUC_SLOT_firmware[type] = "file"
RAUC_SLOT_firmware[file] = "segno-bootfs-${MACHINE}.tar.bz2"
RAUC_SLOT_firmware[depends] = "segno-bootfs:do_deploy"
# A tar into the mounted slot, not an image dd'd over it: the boot partitions
# are sized by the WIC layout, and a raw image would tie the bundle to that size
# forever.
RAUC_SLOT_firmware[hooks] = "post-install"

# The boot slot arrives with cmdline.txt's root=XXX placeholder intact; the hook
# points each slot at its own rootfs, the way the image build does per slot.
# Only the file: the hook is per-SLOT (declared above), not a bundle-wide one.
RAUC_BUNDLE_HOOKS[file] = "segno-bundle-hook.sh"
SRC_URI += "file://segno-bundle-hook.sh"
