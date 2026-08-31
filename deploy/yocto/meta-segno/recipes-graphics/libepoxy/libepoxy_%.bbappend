# Wayland-only kiosk: stock PACKAGECONFIG enables GLX whenever DISTRO_FEATURES
# has x11 (mesa pulls it). With GLX compiled in, epoxy_get_proc_address aborts
# when called without a current EGL context — the desktop_multi_window second
# engine hits that race on segno start (#970). Without GLX the same path returns
# NULL and Flutter logs a warning instead of core-dumping the console.
# GTK+3/GTK4 X11 backends are dropped in meta-segno gtk+ bbappends so nothing
# in the image needs epoxy/glx.h at compile time.
PACKAGECONFIG = "egl"
