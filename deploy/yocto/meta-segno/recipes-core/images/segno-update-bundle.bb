SUMMARY = "RAUC update bundle (.raucb) for the Segno appliance — rootfs + boot FAT"
# Builds a signed, verity-format RAUC bundle carrying segno-kiosk-image's
# rootfs and boot-firmware vfat. `rauc install` writes both to the inactive A/B
# pair so kernel/modules stay matched across walnascar -> wrynose OTAs.
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

SRC_URI += "file://firmware-post-install.sh"
RAUC_BUNDLE_HOOKS[file] = "firmware-post-install.sh"
RAUC_SLOT_firmware[hooks] = "post-install"

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

# Rootfs + parented vfat firmware slot (see files/system.conf). The firmware
# artifact is extracted from the .wic before per-slot cmdline rewrites; the
# post-install hook sets root= for whichever inactive slot RAUC targets.
RAUC_BUNDLE_SLOTS = "rootfs firmware"
RAUC_SLOT_rootfs  = "segno-kiosk-image"
RAUC_SLOT_rootfs[fstype] = "ext4"
RAUC_SLOT_firmware = "segno-kiosk-image"
RAUC_SLOT_firmware[fstype] = "vfat"
RAUC_SLOT_firmware[file] = "${RAUC_SLOT_firmware}-${MACHINE}.boot-firmware.vfat"
RAUC_SLOT_firmware[depends] = "segno-kiosk-image:do_deploy_rauc_boot_firmware"
