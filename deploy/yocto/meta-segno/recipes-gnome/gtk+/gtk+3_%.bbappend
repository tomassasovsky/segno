# Same as gtk4_%.bbappend: EGL-only libepoxy and no X11 use on the appliance.
PACKAGECONFIG:remove = "x11"
