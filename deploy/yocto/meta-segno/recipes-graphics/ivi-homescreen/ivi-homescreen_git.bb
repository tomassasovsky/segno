SUMMARY = "ivi-homescreen: Flutter embedder for embedded Linux (DRM/KMS backend)"
DESCRIPTION = "Toyota Connected's Flutter embedder, built with only its \
compositor-less drm-kms-egl backend and no plugins: the embedder the \
appliance image runs Segno on (#1318, #1330). It loads libflutter_engine.so \
at runtime (flutter-engine-prebuilt) and runs one engine per configured view."
HOMEPAGE = "https://github.com/toyota-connected/ivi-homescreen"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=39ae29158ce710399736340c60147314"

# Pinned like every other source in this image (see kas-segno-common.yml). The
# v3.0 branch head the #1318 spike was validated against; bump deliberately.
# gitsm: the build needs every submodule (drm-cxx and its own, fmt,
# tomlplusplus, cxxopts, asio, rapidjson, Vulkan-Headers, sanitizers-cmake),
# and fetches nothing at configure or build time once they are present.
SRCREV = "80f9ea426825ada81825e6e06c4361bb2dee441c"
SRC_URI = "gitsm://github.com/toyota-connected/ivi-homescreen.git;protocol=https;branch=v3.0 \
           file://0001-drm-apply-the-configured-pixel-ratio-to-window-metrics.patch \
           file://0002-engine-keep-the-AOT-snapshot-mapped-after-engine-shutdown.patch"
PV = "3.0+git${SRCPV}"
S = "${WORKDIR}/git"

inherit cmake pkgconfig

# libseat is required at build time even though the Segno config bypasses the
# seat at runtime (no_seat): drm-cxx's session support is forced on.
# libdisplay-info must be >= 0.2.0 (walnascar's poky carries 0.2.0).
DEPENDS = "libdrm virtual/libgbm virtual/egl virtual/libgles2 libinput udev \
           libxkbcommon libdisplay-info seatd"

# The minimal binary: drm-kms-egl plus the compositor it is meant to run with,
# and nothing else. Plain GCC/libstdc++ (C++17) builds it; clang is not needed.
EXTRA_OECMAKE = " \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_BACKEND_DRM_KMS_EGL=ON -DBUILD_COMPOSITOR=ON \
    -DBUILD_BACKEND_WAYLAND_EGL=OFF -DBUILD_BACKEND_WAYLAND_VULKAN=OFF \
    -DBUILD_BACKEND_WAYLAND_LEASED_DRM=OFF -DBUILD_BACKEND_DRM_KMS_VULKAN=OFF \
    -DBUILD_DRM_KMS_VULKAN_PROBE=OFF -DBUILD_VULKAN_VALIDATION=OFF \
    -DBUILD_BACKEND_SOFTWARE=OFF -DBUILD_BACKEND_HEADLESS_EGL=OFF \
    -DBUILD_BACKEND_HEADLESS_VULKAN=OFF \
    -DBUILD_HUD=OFF -DBUILD_ACCESSIBILITY=OFF -DBUILD_MCP=OFF -DBUILD_ACCESSKIT=OFF \
    -DENABLE_OSGI=OFF -DBUILD_WATCHDOG=OFF -DBUILD_SYSTEMD_WATCHDOG=OFF \
    -DBUILD_CRASH_HANDLER=OFF -DENABLE_DLT=OFF \
    -DBUILD_UNIT_TESTS=OFF -DBUILD_FUZZERS=OFF -DBUILD_DOCS=OFF \
    -DDISABLE_PLUGINS=ON \
"

# The engine is dlopened, so the shlib scan cannot see it. xkbcommon reads its
# keymaps from xkeyboard-config at runtime.
RDEPENDS:${PN} += "flutter-engine-prebuilt xkeyboard-config"

FILES:${PN}-dev += "${libdir}/cmake"

# Installed as /usr/bin/segno: this process is the Segno app, and the name is
# not cosmetic. With no GApplication in the process, path_provider_linux names
# the app's support directory, where shared_preferences keeps every setting,
# after the executable. As `homescreen` the app looked in
# $XDG_DATA_HOME/homescreen and started as a fresh install; every unit's
# settings are in $XDG_DATA_HOME/segno, where the earlier GTK runner kept them.
# The name is also what `pidof segno` (segno-profile-recorder) and the core
# dump names use.
do_install:append() {
    mv ${D}${bindir}/homescreen ${D}${bindir}/segno
}
