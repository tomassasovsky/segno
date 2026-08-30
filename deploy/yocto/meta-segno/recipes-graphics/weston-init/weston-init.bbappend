# Override the stock weston.ini with a kiosk-shell + dual-HDMI config for the
# floor console (Tier 3a spike). Our layer's higher BBFILE_PRIORITY makes this
# weston.ini win over the default.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://weston.ini \
            file://20-segno-weston.conf"

do_install:append() {
    # walnascar: SRC_URI files land in ${UNPACKDIR}, not ${WORKDIR}.
    install -Dm 0644 ${UNPACKDIR}/weston.ini ${D}${sysconfdir}/xdg/weston/weston.ini
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/20-segno-weston.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/20-segno-weston.conf
}

FILES:${PN} += "${systemd_system_unitdir}/weston.service.d/20-segno-weston.conf"
