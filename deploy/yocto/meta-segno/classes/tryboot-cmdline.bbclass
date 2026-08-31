
def get_wic_image(d):
    import os

    work_dir = d.getVar("WORKDIR")
    image_link_name = d.getVar("IMAGE_NAME")
    wic_image = os.path.join(work_dir, "deploy-" + d.getVar("PN") + "-image-complete", f"{image_link_name}.wic")

    if not os.path.exists(wic_image):
        bb.fatal(f"No WIC image found! {wic_image}")

    return wic_image


def get_partitions(wic_image):
    import subprocess

    fdisk_output = subprocess.check_output(["fdisk", "-l", "-o", "Start,Type", wic_image], text=True)
    vfat_partitions = []

    for line in fdisk_output.splitlines():
        if "FAT" in line:
            offset_blocks = int(line.split()[0])
            offset_bytes = offset_blocks * 512
            partition = f"{wic_image}@@{offset_bytes}"
            vfat_partitions.append(partition)

    return vfat_partitions


def read_cmdline(partition):
    import subprocess

    return subprocess.check_output(
        ["mtype", "-i", partition, "::cmdline.txt"], text=True)


def update_cmdline(partition, root):
    import subprocess

    cmdline_data = read_cmdline(partition)

    # A plain str.replace on a missing placeholder writes the file back
    # unchanged and reports success — the image then boots to a kernel panic
    # with no rootfs and nothing anywhere saying why. Demand the placeholder.
    if "root=XXX" not in cmdline_data:
        bb.fatal(f"no root=XXX placeholder in {partition}'s cmdline.txt — "
                 f"CMDLINE_ROOT_PARTITION should be XXX (see "
                 f"recipes-bsp/bootfiles/rpi-cmdline.bbappend). Got: "
                 f"{cmdline_data.strip()!r}")

    new_cmdline = cmdline_data.replace("root=XXX", f"root={root}")

    subprocess.run([
        "mcopy", "-Do", "-i", partition, "-", "::cmdline.txt"
    ], input=new_cmdline, text=True, check=True)

    # Read the slot back rather than trusting the write. mcopy reports success
    # on a FAT it did not actually update in place, and every failure mode here
    # is invisible until the board is on the bench refusing to boot.
    written = read_cmdline(partition)
    if f"root={root}" not in written or "root=XXX" in written:
        bb.fatal(f"cmdline.txt in {partition} did not take root={root} — "
                 f"reads back as {written.strip()!r}")

def update_bmap(wic_image):
    import subprocess

    bmap_file = f"{wic_image}.bmap"

    subprocess.run(["bmaptool", "create", "-o", bmap_file, wic_image], check=True)
    bb.note(f"Updated BMAP file created: {bmap_file}")

python do_update_tryboot_cmdline() {
    wic_image = get_wic_image(d)
    vfat_partitions = get_partitions(wic_image)

    # Same variable the WIC layout and the RAUC slot table are built from, so a
    # board change cannot leave root= pointing at the other board's device. Both
    # supported disks partition as <disk>pN (mmcblk0p5, nvme0n1p5) — a device
    # that numbers as <disk>N (sdaN) would need the separator parameterised too.
    disk = d.getVar("SEGNO_BOOT_DISK")
    if not disk:
        bb.fatal("SEGNO_BOOT_DISK is unset — set it in the board's kas project "
                 "(deploy/yocto/kas-segno-rpi{4,5}.yml).")

    update_cmdline(vfat_partitions[1], f"/dev/{disk}p5")
    update_cmdline(vfat_partitions[2], f"/dev/{disk}p6")

    update_bmap(wic_image)
}

# The task bakes SEGNO_BOOT_DISK into the image, so a board switch must re-run it.
do_update_tryboot_cmdline[vardeps] += "SEGNO_BOOT_DISK"

def extract_vfat_partition(wic_image, vfat_index, dest):
    import subprocess

    output = subprocess.check_output(
        ["fdisk", "-l", "-o", "Start,Sectors,Type", wic_image], text=True)
    seen = 0
    for line in output.splitlines():
        if "FAT" not in line:
            continue
        if seen == vfat_index:
            start, sectors = line.split()[:2]
            subprocess.run([
                "dd", f"if={wic_image}", f"of={dest}",
                "bs=512", f"skip={start}", f"count={sectors}",
                "status=none",
            ], check=True)
            return
        seen += 1

    bb.fatal(f"vfat partition index {vfat_index} not found in {wic_image}")


python do_deploy_rauc_boot_firmware() {
    import os

    wic_image = get_wic_image(d)
    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    out = os.path.join(deploy_dir, d.expand("${PN}-${MACHINE}.boot-firmware.vfat"))
    bb.utils.mkdirhier(deploy_dir)
    extract_vfat_partition(wic_image, 1, out)
    bb.note("RAUC boot firmware artifact (bootA, root=XXX): %s" % out)
}

do_deploy_rauc_boot_firmware[vardeps] += "SEGNO_BOOT_DISK"
addtask do_deploy_rauc_boot_firmware after do_image_wic before do_update_tryboot_cmdline

