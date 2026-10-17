SUMMARY = "Segno floor-console kiosk image: the prebuilt Flutter bundle on ivi-homescreen"
LICENSE = "MIT"

# A plain core image with no compositor: ivi-homescreen (segno-bundle's
# RDEPENDS) drives both HDMI outputs itself over DRM/KMS, one Flutter engine
# per screen (#1318, #1330). The features are the ones the image had when it
# was based on core-image-weston, less weston, and less `splash`, which only
# installs psplash (excluded below: plymouth owns the splash).
#
# Note what is NOT here: meta-rauc's rauc-mark-good. Its unit is condition-gated
# on a `rauc.slot` kernel argument that the Pi tryboot backend never sets, so it
# was skipped on every boot and every update silently rolled back. segno-bundle
# ships segno-mark-good.service in its place, behind a health gate (#307).
inherit core-image
IMAGE_FEATURES += "package-management ssh-server-dropbear hwcodecs"

# segno-console-board carries the console board's firmware and the boot-time
# check that applies it: the board is a second computer, and the image owns
# what runs on it (#989). No comments inside the list below — BitBake treats a
# '#' in a line-continued value as part of the value, not as a comment.
#
# segno-profiling ships segno-prof (the stack sampler) on every image; its
# recorder service only runs on experimental ones (#1299).
IMAGE_INSTALL:append = " \
    segno-bundle \
    mesa \
    alsa-lib \
    alsa-utils \
    alsa-plugins \
    util-linux-chrt \
    xdg-user-dirs \
    plymouth \
    plymouth-segno-theme \
    rauc \
    rauc-conf \
    rauc-rpi-backend \
    raspi-utils \
    segno-console-board \
    segno-profiling \
    dtc \
    ddcutil \
    networkmanager-nmcli \
    networkmanager-wifi \
    "
# tryboot-cmdline.bbclass edits cmdline.txt inside the .wic (mtools) and regenerates
# the bmap (bmaptool) — both are native build tools its task needs.
do_update_tryboot_cmdline[depends] += "mtools-native:do_populate_sysroot bmaptool-native:do_populate_sysroot"
# plymouth boot splash (segno mark, static, determinate progress) covers the black screen from
# power-on until the app takes the display. plymouth-segno-theme sets itself active.
# Keep psplash (the other splash, pulled in by the base image) out so the two don't
# fight over the framebuffer — plymouth owns the splash.
IMAGE_INSTALL:remove = "psplash psplash-raspberrypi"
BAD_RECOMMENDATIONS += "psplash psplash-raspberrypi"
PACKAGE_EXCLUDE += "psplash psplash-raspberrypi"
# Bluetooth was retired (#1199): no BlueZ, so nothing powers the controller,
# advertises or reconnects a paired device. kas-segno-common.yml removes the
# `bluetooth` distro feature, which is what keeps packagegroup-base from
# pulling bluez5 in; this exclusion is the guard that fails the build if any
# package hard-depends on it again. The pairings an earlier image kept stay
# on /data/bluetooth, where a fallback to the previous slot finds them again,
# until the next update overwrites that slot.
PACKAGE_EXCLUDE += "bluez5"
# Audio: DIRECT ALSA, no PipeWire/JACK/Pulse. This is a single-app appliance that
# owns the sound card, so the engine drives ALSA directly (SEGNO_ALSA_ONLY, set by
# segno-kiosk-launch) for the lowest latency and zero IPC — the textbook mono-app
# embedded-audio path. The ALSA-duplex reconfigure deadlock that originally pushed
# us to PipeWire is fixed in the engine (ma_device_stop before uninit), so runtime
# sample-rate / buffer changes work on raw ALSA. No pipewire/wireplumber packages,
# no session daemons, no plugin clutter in the device list. Low-latency tuning is
# system-level (performance governor + threadirqs via CMDLINE, PREEMPT_RT kernel
# on 6.12, SCHED_FIFO audio thread + rtirq) rather than a sound server.

# RAUC A/B (tryboot) disk layout: boot selector + bootA/bootB + rootA/rootB +
# data (Phase 1, #303). See wic/segno-tryboot.wks.in — a template, because the
# boot device is per board (NVMe on the Pi 5, #799). `wic` = the
# flashable image; `ext4` = the bare rootfs the .raucb packages (RAUC_SLOT_rootfs).
WKS_FILE = "segno-tryboot.wks.in"
IMAGE_FSTYPES = "wic ext4"

# Rewrite each boot slot's cmdline.txt root= inside the .wic after do_image_wic
# (bootA->rootA p5, bootB->rootB p6) — see classes/tryboot-cmdline.bbclass.
# NOTE: recipe-level `inherit` (lowercase); `INHERIT +=` only works at conf level.
inherit tryboot-cmdline

# Headroom for the kernel & modules on the rootfs. User/session data lives on /data.
IMAGE_ROOTFS_EXTRA_SPACE = "1048576"
# xdg-user-dirs provides the `xdg-user-dir` binary. Flutter's path_provider shells
# out to it for getApplicationDocumentsDirectory; without it the app throws
# MissingPlatformDirectoryException on startup. The launcher seeds a user-dirs.dirs
# so it resolves ~/Documents (see segno-kiosk-launch). Validated on device.
# alsa-plugins provides the dmix/dsnoop slaves the bare ALSA config references.

# NetworkManager owns eth0 + wlan*. Mask systemd-networkd so the two managers
# never fight over the same interfaces (SSH still comes up via NM DHCP).
segno_mask_networkd() {
    # Mask into /etc so it wins over /lib unit files without deleting packages.
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.service
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.socket
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service
}
ROOTFS_POSTPROCESS_COMMAND += "segno_mask_networkd; "

# Spike convenience: root login (empty password) + SSH for bring-up debugging.
# walnascar dropped the `debug-tweaks` umbrella feature, so name its parts. Drop
# all of this for anything resembling production.
IMAGE_FEATURES:append = " allow-empty-password allow-root-login empty-root-password post-install-logging ssh-server-dropbear"
