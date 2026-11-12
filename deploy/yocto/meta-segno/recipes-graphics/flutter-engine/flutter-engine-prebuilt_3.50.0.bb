SUMMARY = "Prebuilt Flutter engine for embedders (libflutter_engine.so, release, arm64)"
DESCRIPTION = "The Flutter engine's embedder library, as published prebuilt by \
meta-flutter (github.com/meta-flutter/flutter-engine releases), for \
ivi-homescreen on the appliance image (#1318). Installed rather than \
built: meta-flutter's engine recipe compiles it from a 14 GB+ checkout and does \
not support walnascar."
HOMEPAGE = "https://github.com/meta-flutter/flutter-engine"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/BSD-3-Clause;md5=550794465ba0ec5312d6919e203a55f9"

require flutter-engine-version.inc

# Only the release arm64 engine exists for this image.
COMPATIBLE_HOST = "aarch64.*-linux"

ENGINE_SDK = "linux-engine-sdk-release-arm64-${FLUTTER_ENGINE_COMMIT}"
SRC_URI = "https://github.com/meta-flutter/flutter-engine/releases/download/${ENGINE_SDK}/${ENGINE_SDK}.tar.gz;subdir=engine-sdk"
# PROVISIONAL until meta-flutter publishes this engine (PR #1781): the digest of
# a build of meta-flutter's own workflow on our runner, whose Yocto downloads
# directory holds that tarball. Replace it with meta-flutter's before merging;
# anywhere else this fetch 404s.
SRC_URI[sha256sum] = "ac11dbe391c80e84fe88b07ccb7bf2435eaae56ae17df50f90244a68101a059f"
S = "${UNPACKDIR}/engine-sdk/flutter/engine/src/out/linux_release_arm64/engine-sdk"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

# libflutter_engine.so goes on the loader path, where ivi-homescreen dlopens it
# by name; icudtl.dat where ivi-homescreen looks when a bundle carries none.
do_install() {
    install -d ${D}${libdir} ${D}${datadir}/flutter
    install -m 0755 ${S}/lib/libflutter_engine.so ${D}${libdir}/libflutter_engine.so
    install -m 0644 ${S}/data/icudtl.dat ${D}${datadir}/flutter/icudtl.dat
}

# An unversioned library loaded by name at runtime belongs in the main package,
# not -dev; and it is a prebuilt, already stripped, built with its own flags.
FILES_SOLIBSDEV = ""
FILES:${PN} += "${libdir}/libflutter_engine.so ${datadir}/flutter"
INSANE_SKIP:${PN} += "dev-so already-stripped ldflags"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
