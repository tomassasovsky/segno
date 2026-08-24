
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


def update_cmdline(partition, root):
    import subprocess

    cmdline_data = subprocess.check_output([
        "mtype", "-i", partition, "::cmdline.txt"
    ], text=True)

    new_cmdline = cmdline_data.replace("root=XXX", f"root={root}")

    subprocess.run([
        "mcopy", "-Do", "-i", partition, "-", "::cmdline.txt"
    ], input=new_cmdline, text=True, check=True)

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

addtask do_update_tryboot_cmdline after do_image_wic before do_image_complete

