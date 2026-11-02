SUMMARY = "Reboots the console warm when exec or storage stops working"
DESCRIPTION = "A small daemon that every 5 s execs a trivial program and reads \
a file on / and one on /data past the page cache. When the probes keep failing \
for 90 s it dumps the blocked tasks and CPU backtraces into the kernel log and \
panics through sysrq, so ramoops keeps the record and the board resets warm. \
It covers the freeze where PID 1 lives on and keeps feeding the hardware \
watchdog while nothing can be started (#1527)."
LICENSE = "CLOSED"

SRC_URI = "file://segno-freeze-watchdog.c \
           file://freeze_watchdog.c \
           file://freeze_watchdog.h \
           file://segno-freeze-watchdog.service"

# Local files only: they unpack straight into UNPACKDIR.
S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "segno-freeze-watchdog.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -std=gnu11 -Wall -Wextra -pthread \
        -o ${B}/segno-freeze-watchdog ${S}/segno-freeze-watchdog.c ${S}/freeze_watchdog.c
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/segno-freeze-watchdog ${D}${bindir}/segno-freeze-watchdog
    # The block the / probe reads with O_DIRECT. A file of its own, because
    # the daemon's binary is mapped and locked, and must never be sparse.
    install -d ${D}${libdir}/segno
    yes "segno-freeze-watchdog reads this block past the page cache" | head -c 4096 \
        > ${D}${libdir}/segno/freeze-watchdog-probe
    chmod 0644 ${D}${libdir}/segno/freeze-watchdog-probe
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/segno-freeze-watchdog.service ${D}${systemd_system_unitdir}/segno-freeze-watchdog.service
}

FILES:${PN} += "${libdir}/segno/freeze-watchdog-probe"
