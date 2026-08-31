# Same as gtk4_%.bbappend: EGL-only libepoxy and no X11 use on the appliance.
# Leave class-native alone — it builds x11-only for build-time tools.
PACKAGECONFIG:remove:class-target = "x11"
