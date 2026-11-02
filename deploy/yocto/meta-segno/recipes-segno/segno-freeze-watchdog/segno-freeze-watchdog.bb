SUMMARY = "Reboots the console warm when exec or storage stops working"
DESCRIPTION = "A small daemon that every 5 s execs a trivial program and reads \
a file on / and one on /data past the page cache. When the probes keep failing \
for 60 s it dumps the blocked tasks and CPU backtraces into the kernel log and \
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
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/segno-freeze-watchdog.service ${D}${systemd_system_unitdir}/segno-freeze-watchdog.service
}
