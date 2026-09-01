SUMMARY = "gdk_x11_* load-time stubs for the prebuilt Flutter GTK bundle"
DESCRIPTION = "The Ubuntu-built libflutter_linux_gtk.so resolves four gdk_x11_* \
symbols at load time, but this image builds GTK3 without its X11 backend (a hard \
consequence of the EGL-only libepoxy that fixes the #970 epoxy abort), so the app \
dies before first frame. This library provides those symbols safely: dummy GTypes \
so every GDK_IS_X11_DISPLAY / GDK_IS_X11_SCREEN guard in the embedder answers no \
and the X11 paths never run. Preloaded by segno-kiosk-launch; the symbol contract \
lives in files/exported-symbols.txt and is enforced at bundle-build time by \
deploy/rpi/build/check-gdk-x11-symbols.sh. See #975."
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-3.0-only;md5=c79ff39f19dfec6d293b95dea7b07891"

SRC_URI = "file://gdk_x11_shim.c"

DEPENDS = "glib-2.0"
inherit pkgconfig

S = "${UNPACKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -shared -fPIC \
        `pkg-config --cflags glib-2.0` \
        ${UNPACKDIR}/gdk_x11_shim.c \
        -o libsegno-gdk-x11-shim.so \
        `pkg-config --libs gobject-2.0`
}

do_install() {
    install -d ${D}${libdir}
    install -m 0644 ${B}/libsegno-gdk-x11-shim.so ${D}${libdir}/
}

# A bare unversioned .so: it is LD_PRELOADed by path, never linked against, so
# it belongs in the runtime package — keep it out of ${PN}-dev and silence the
# matching QA check.
FILES_SOLIBSDEV = ""
FILES:${PN} += "${libdir}/libsegno-gdk-x11-shim.so"
INSANE_SKIP:${PN} += "dev-so"
