# Wayland-only kiosk (GDK_BACKEND=wayland in segno-kiosk-launch). meta-segno
# builds libepoxy with PACKAGECONFIG = "egl" only — no epoxy/glx.h — so the
# stock X11 backend cannot compile on the target (#970). Drop it; keep Wayland.
# class-native still needs x11 (the only backend upstream enables for native).
PACKAGECONFIG:remove:class-target = "x11"
