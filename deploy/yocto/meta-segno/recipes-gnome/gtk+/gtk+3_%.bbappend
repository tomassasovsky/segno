# Same as gtk4_%.bbappend: EGL-only libepoxy and no X11 use on the appliance.
# Leave class-native alone — it builds x11-only for build-time tools.
#
# Consequence: libgdk stops exporting gdk_x11_*, which the prebuilt Flutter
# bundle resolves at load time — segno-gdk-x11-shim provides those symbols
# (preloaded by segno-kiosk-launch). Removing that shim re-breaks the app with
# `undefined symbol: gdk_x11_screen_get_type` (#975).
PACKAGECONFIG:remove:class-target = "x11"
