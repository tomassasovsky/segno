/*
 * gdk_x11_shim.c — satisfy the prebuilt Flutter GTK embedder's gdk_x11_*
 * references on a Wayland-only image (#975).
 *
 * The Ubuntu-built libflutter_linux_gtk.so resolves four gdk_x11_* symbols at
 * load time. Our image builds GTK3 without its X11 backend (a hard consequence
 * of the EGL-only libepoxy that fixes the #970 epoxy abort), so libgdk no
 * longer exports them and the app dies before first frame:
 *
 *   symbol lookup error: libflutter_linux_gtk.so:
 *   undefined symbol: gdk_x11_screen_get_type
 *
 * Every use in the embedder sits behind a GDK_IS_X11_DISPLAY /
 * GDK_IS_X11_SCREEN runtime check. Those macros expand to
 * G_TYPE_CHECK_INSTANCE_TYPE against the GType returned by the get_type
 * functions below — so registering fresh, unrelated GTypes makes every check
 * answer "no" for the real Wayland display/screen objects, and the guarded
 * X11 paths never run.
 *
 * Parameters are opaque pointers on purpose: the real GdkScreen/GdkDisplay
 * types live in headers this shim must not need, and the ABI is identical.
 */

#include <glib-object.h>

GType gdk_x11_display_get_type(void) {
  static gsize once = 0;
  if (g_once_init_enter(&once)) {
    GType type = g_type_register_static_simple(
        G_TYPE_OBJECT, g_intern_static_string("SegnoGdkX11DisplayShim"),
        sizeof(GObjectClass), NULL, sizeof(GObject), NULL, 0);
    g_once_init_leave(&once, type);
  }
  return (GType)once;
}

GType gdk_x11_screen_get_type(void) {
  static gsize once = 0;
  if (g_once_init_enter(&once)) {
    GType type = g_type_register_static_simple(
        G_TYPE_OBJECT, g_intern_static_string("SegnoGdkX11ScreenShim"),
        sizeof(GObjectClass), NULL, sizeof(GObject), NULL, 0);
    g_once_init_leave(&once, type);
  }
  return (GType)once;
}

/* Only reachable if a caller skips its IS_X11 guard. Refuse loudly (this logs
 * a critical) rather than hand back a fake Display*. */
void* gdk_x11_display_get_xdisplay(void* display) {
  (void)display;
  g_return_val_if_reached(NULL);
}

/* Real GDK returns "unknown" when it cannot tell — mirror that. */
const char* gdk_x11_screen_get_window_manager_name(void* screen) {
  (void)screen;
  return "unknown";
}
