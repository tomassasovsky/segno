SUMMARY = "Segno floor-console Plymouth boot splash (segno mark, determinate progress)"
DESCRIPTION = "A script-based Plymouth theme: the segno mark — the Bravura glyph \
(SMuFL U+E047), pre-rendered from smooth vectors; the wordmark was cut as \
unreadable at splash size — centred on the console's near-black (#08080A) with \
a determinate progress bar driven by the real boot progress. No text banners, \
no Raspberry Pi rainbow. Shown from early boot until the app takes the \
display (segno.service waits for plymouth-quit-wait)."
LICENSE = "CLOSED"

SRC_URI = "file://segno.plymouth \
           file://segno.script \
           file://segno-lockup.png \
           file://segno-bar-pixel.png"

RDEPENDS:${PN} = "plymouth"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/plymouth/themes/segno
    install -m 0644 ${UNPACKDIR}/segno.plymouth ${D}${datadir}/plymouth/themes/segno/segno.plymouth
    install -m 0644 ${UNPACKDIR}/segno.script   ${D}${datadir}/plymouth/themes/segno/segno.script
    install -m 0644 ${UNPACKDIR}/segno-lockup.png    ${D}${datadir}/plymouth/themes/segno/segno-lockup.png
    install -m 0644 ${UNPACKDIR}/segno-bar-pixel.png ${D}${datadir}/plymouth/themes/segno/segno-bar-pixel.png

    # Select segno as the active theme via the default.plymouth symlink (plymouth's
    # own plymouthd.conf leaves Theme= commented, so the symlink wins). Relative so
    # it resolves on-target.
    ln -sf segno/segno.plymouth ${D}${datadir}/plymouth/themes/default.plymouth
}

FILES:${PN} = "${datadir}/plymouth/themes/segno \
               ${datadir}/plymouth/themes/default.plymouth"
