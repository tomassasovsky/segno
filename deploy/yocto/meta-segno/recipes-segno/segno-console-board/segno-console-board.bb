SUMMARY = "The console board's firmware, and the boot-time check that applies it"
DESCRIPTION = "Ships the RP2350 firmware built from this same commit, the SWD \
config that reaches it through the Pi's GPIO, and a marker naming the firmware \
version and link protocol the app expects. A oneshot before segno.service \
flashes the board when it is not already running them, so the two halves of a \
build cannot ship out of step and a field unit needs no laptop to be repaired."
LICENSE = "CLOSED"

# The compiled firmware, handed over by CI the way the app bundle is; override
# for a local build. Kept out of the recipe's own SRC_URI because it is a build
# artifact of firmware/console_board, not a source file.
SEGNO_CONSOLE_FW_DIR ?= "${THISDIR}/../../../prebuilt/console-board"

# Bitbake must be TOLD these files are inputs. do_install reads them from a
# directory outside SRC_URI, so without this the task's signature never
# changes when the firmware does, and shared state hands back the first
# package it ever built: 0.1.0-experimental.132 shipped an app speaking link
# protocol 4 next to a board image still on protocol 3, and every console
# that installed it went dark. The path and the contents both count.
do_install[file-checksums] += "${SEGNO_CONSOLE_FW_DIR}/console_board.elf:True \
                               ${SEGNO_CONSOLE_FW_DIR}/version:True"

SRC_URI = "file://segno-console-flash \
           file://segno-console-flash.service \
           file://pi5-swd.cfg"

inherit systemd

SYSTEMD_SERVICE:${PN} = "segno-console-flash.service"
SYSTEMD_AUTO_ENABLE = "enable"

# segno-openocd does the flashing; raspi-utils' pinctrl sets the SWDIO pull-up
# the Pi firmware otherwise leaves down; the rest is busybox.
RDEPENDS:${PN} = "segno-openocd raspi-utils"

# The firmware is a 32-bit Cortex-M33 image for a different processor, carried
# as data. Yocto's QA reads every ELF as a host binary, so it must be told this
# one is foreign — and told not to strip it or split its debug symbols, because
# what gets flashed has to be the bytes the compiler produced.
INSANE_SKIP:${PN} += "arch"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"

python () {
    fw = d.getVar('SEGNO_CONSOLE_FW_DIR')
    if not fw:
        bb.fatal("SEGNO_CONSOLE_FW_DIR is unset. Point it at the directory "
                 "holding console_board.elf built from firmware/console_board.")
}

do_install() {
    fw="${SEGNO_CONSOLE_FW_DIR}"
    if [ ! -f "$fw/console_board.elf" ]; then
        bbfatal "No console_board.elf under SEGNO_CONSOLE_FW_DIR=$fw"
    fi

    install -d ${D}${libdir}/segno/console-board
    install -m 0644 "$fw/console_board.elf" ${D}${libdir}/segno/console-board/console_board.elf
    install -m 0644 ${UNPACKDIR}/pi5-swd.cfg ${D}${libdir}/segno/console-board/pi5-swd.cfg

    # What the app expects of the board, recorded where the flasher can read it.
    # Both come from the firmware source in this same commit; see
    # firmware/console_board/pedal_link.h.
    install -m 0644 "$fw/version" ${D}${libdir}/segno/console-board/version

    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/segno-console-flash ${D}${bindir}/segno-console-flash

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/segno-console-flash.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${libdir}/segno/console-board ${bindir}/segno-console-flash"
