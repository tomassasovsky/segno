SUMMARY = "OpenOCD, built for one job: flashing the console board's RP2350 over the Pi's own GPIO"
DESCRIPTION = "Upstream OpenOCD with only the Linux GPIO character-device adapter \
enabled. That adapter is what drives SWD from the Pi 5's own header, and it needs \
neither libftdi nor hidapi, so this carries none of the USB probe machinery. \
meta-oe's openocd cannot do this job: it pins a 2023 commit, which predates the \
RP2350 by a year and has neither tcl/target/rp2350.cfg nor \
tcl/interface/raspberrypi5-gpiod.cfg. Both are upstream now, which is why this \
builds upstream rather than vendoring Raspberry Pi's fork."
HOMEPAGE = "https://openocd.org"
LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://COPYING;md5=599d2d1ee7fc84c0467b3d19801db870"

# Pinned, not floating: the firmware this flashes ships in the same image, and a
# tool that reprograms an MCU must not change under the appliance without a
# commit saying so.
SRCREV = "43648fedd39440b06662ec16a0643b3081b1de53"
SRC_URI = "gitsm://github.com/openocd-org/openocd.git;protocol=https;branch=master"

PV = "0.12+git${SRCPV}"
S = "${WORKDIR}/git"

DEPENDS = "libgpiod"

inherit autotools pkgconfig

# Only the adapter the appliance has. Every other driver is an extra dependency
# and another way for the build to fail on a machine that will never use it.
# jimtcl is OpenOCD's script engine. It is still a git submodule (which gitsm
# fetches, autosetup `configure` and all), but upstream flipped the default to
# an external one, so it must be asked for. Marked deprecated upstream; when it
# goes, this needs a jimtcl recipe of its own — meta-oe has none, which is why
# meta-oe's own openocd fetches it by hand.
EXTRA_OECONF = " \
    --enable-internal-jimtcl \
    --enable-linuxgpiod \
    --disable-doxygen-html \
    --disable-doxygen-pdf \
    --disable-werror \
    --disable-ftdi \
    --disable-stlink \
    --disable-ti-icdi \
    --disable-ulink \
    --disable-usb-blaster-2 \
    --disable-ft232r \
    --disable-vsllink \
    --disable-xds110 \
    --disable-cmsis-dap \
    --disable-cmsis-dap-v2 \
    --disable-jlink \
    --disable-kitprog \
    --disable-opendous \
    --disable-aice \
    --disable-usbprog \
    --disable-rlink \
    --disable-armjtagew \
    --disable-osbdm \
    --disable-remote-bitbang \
"

# Named apart from meta-oe's openocd so the two can never be confused for one
# another; nothing else in the image wants a debug probe.
do_install:append() {
    if [ -e "${D}${bindir}/openocd" ]; then
        mv "${D}${bindir}/openocd" "${D}${bindir}/segno-openocd"
    fi
}

FILES:${PN} += "${datadir}/openocd"
