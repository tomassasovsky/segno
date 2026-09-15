SUMMARY = "The boot partition's contents, as an artifact the update bundle can carry"
DESCRIPTION = "Everything that lands in a boot slot — the kernel, device trees, \
overlays, the Pi firmware blobs, config.txt and cmdline.txt — packed as a tar so \
RAUC can write it into the inactive boot slot. Without this the bundle carries \
only the rootfs, and nothing about how the console STARTS can ever be updated: \
not the kernel, which lives here, and not a device-tree overlay, which is what \
the console board's link needs (#989). \
\
The file list is IMAGE_BOOT_FILES — the same variable the WIC layout builds the \
boot partitions from — so the partition a unit is imaged with and the partition \
an update writes cannot drift apart."
LICENSE = "CLOSED"

inherit deploy nopackages

# The files below are produced by these; deploy after they have deployed.
do_deploy[depends] += "rpi-bootfiles:do_deploy rpi-config:do_deploy rpi-cmdline:do_deploy virtual/kernel:do_deploy"

# cmdline.txt keeps its root=XXX placeholder here, exactly as the WIC image does
# before tryboot-cmdline rewrites it per slot. The install hook does the same
# rewrite on the device, because which rootfs a boot slot points at is a
# property of the SLOT, not of the build.
# Uncompressed on purpose. RAUC splices the archive into `tar -x` without a
# decompression flag, and the appliance's busybox tar cannot sniff the format —
# it supports -z and -j only when told, so a compressed archive arrives as
# "invalid tar magic" and the install fails after the slot has already been
# formatted. A few tens of megabytes in the bundle is the price of an install
# that cannot fail on a detail of how tar was compiled.
BOOTFS_TARBALL = "${PN}-${MACHINE}.tar"

python do_compile() {
    import os
    import shutil

    deploy_dir = d.getVar("DEPLOY_DIR_IMAGE")
    staging = os.path.join(d.getVar("B"), "bootfs")
    bb.utils.remove(staging, recurse=True)
    os.makedirs(staging)

    boot_files = (d.getVar("IMAGE_BOOT_FILES") or "").split()
    if not boot_files:
        bb.fatal("IMAGE_BOOT_FILES is empty — nothing would reach the boot slot, "
                 "and an update would silently blank it.")

    for entry in boot_files:
        # Entries follow wic's bootimg-partition: "src" lands at the root under
        # its own name, "src;dst" is renamed, "src;dir/" lands inside dir. A src
        # may be a glob — meta-raspberrypi's default starts with "bootfiles/*",
        # which is every firmware blob plus config.txt and cmdline.txt.
        src, _, dst = entry.partition(";")
        matches = sorted(__import__("glob").glob(os.path.join(deploy_dir, src)))
        if not matches:
            bb.fatal("IMAGE_BOOT_FILES names %r but nothing in %s matches it. The "
                     "boot slot would be written incomplete, which is worse than "
                     "not writing it at all." % (src, deploy_dir))
        for match in matches:
            # The destination name comes from the MATCH, never from the pattern.
            # Taking basename(src) for a bare glob gave every file in bootfiles/
            # the name "*": they overwrote each other into one 3.7 MB file
            # literally called "*", which vfat then refused to create on the
            # device, and config.txt and cmdline.txt were not in the slot at all
            # (0.1.0-experimental.128 and .129 both failed to install this way).
            if not dst:
                target = os.path.join(staging, os.path.basename(match))
            elif dst.endswith("/"):
                target = os.path.join(staging, dst, os.path.basename(match))
            else:
                target = os.path.join(staging, dst)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.isdir(match):
                shutil.copytree(match, target, dirs_exist_ok=True)
            else:
                shutil.copy2(match, target)

    # Prove the tree is a boot slot before it is packed. Every check here is
    # something the device would otherwise discover mid-install, after the
    # inactive slot has already been formatted.
    staged = []
    for root, _dirs, files in os.walk(staging):
        for name in files:
            staged.append(os.path.relpath(os.path.join(root, name), staging))
    odd = sorted(p for p in staged if any(c in p for c in "*?[]"))
    if odd:
        bb.fatal("boot slot would contain glob characters in a file name: %s — "
                 "an IMAGE_BOOT_FILES pattern was copied instead of expanded."
                 % ", ".join(odd))
    for required in ("config.txt", "cmdline.txt"):
        if required not in staged:
            bb.fatal("boot slot is missing %s. Present: %s"
                     % (required, ", ".join(sorted(staged)) or "nothing"))
    with open(os.path.join(staging, "cmdline.txt")) as f:
        cmdline = f.read()
    if "root=XXX" not in cmdline:
        bb.fatal("cmdline.txt has no root=XXX placeholder; the install hook "
                 "cannot point the slot at its rootfs. Got: %r" % cmdline.strip())
    kernel = d.getVar("SDIMG_KERNELIMAGE")
    if kernel and kernel not in staged:
        bb.fatal("boot slot is missing the kernel image %s. Present: %s"
                 % (kernel, ", ".join(sorted(staged))))
}

do_compile[cleandirs] = "${B}"

do_deploy() {
    tar -C ${B}/bootfs -cf ${DEPLOYDIR}/${BOOTFS_TARBALL} .
}

addtask deploy after do_compile before do_build
