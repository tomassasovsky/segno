# A/B tryboot: ship cmdline.txt with a "root=XXX" placeholder in BOTH boot slots.
# tryboot-cmdline.bbclass rewrites it per-slot inside the .wic after do_image_wic
# (bootA -> root=/dev/${SEGNO_BOOT_DISK}p5, bootB -> ...p6; mmcblk0 on the Pi 4,
# nvme0n1 on the Pi 5).
CMDLINE_ROOT_PARTITION = "XXX"
