# Wayland-only kiosk (GDK_BACKEND=wayland in segno-kiosk-launch). meta-segno
# builds libepoxy with PACKAGECONFIG = "egl" only — no epoxy/glx.h — so the
# stock X11 backend cannot compile (#970). Drop it; keep the Wayland backend.
PACKAGECONFIG:remove = "x11"
