SUMMARY = "On-device profiling for the Segno app"
DESCRIPTION = "segno-prof samples the app's main-thread stack and counts the \
GSources on its GLib main loop without stopping the app; segno-profile-recorder \
logs CPU, memory, main-loop load and periodic stack profiles to /data/perf on \
experimental images, so slow degradation shows up as a trend (#1299)."
LICENSE = "CLOSED"

SRC_URI = "file://segno-prof.c \
           file://segno-profile-recorder \
           file://segno-profile.service"

# Local files only: they unpack straight into UNPACKDIR.
S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "segno-profile.service"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -std=gnu11 -Wall -Wextra \
        -o ${B}/segno-prof ${S}/segno-prof.c
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/segno-prof ${D}${bindir}/segno-prof
    install -m 0755 ${S}/segno-profile-recorder ${D}${bindir}/segno-profile-recorder
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/segno-profile.service ${D}${systemd_system_unitdir}/segno-profile.service
}
