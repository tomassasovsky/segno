#include "my_application.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "sub_window_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // Set once the main window has been added; every window added after it is a
  // desktop_multi_window sub-window (the waveform window).
  gboolean main_window_added;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// --- Wayland app-ids ---------------------------------------------------------
// GTK3's Wayland backend derives every xdg_toplevel's app_id from
// g_get_prgname() when the toplevel is created — which happens at *map* time,
// not realize (gdk_wayland_window_create_xdg_toplevel in gtk-3-24
// gdk/wayland/gdkwindow-wayland.c). With the single prgname set in
// my_application_new() both windows would share one app_id, and weston's
// kiosk-shell — which places surfaces per output by app_id
// (`[output] app-ids=` in deploy/yocto's weston.ini) — could not tell the
// waveform window apart from the main UI: both landed on the first output and
// the 7" stayed black (issue #689).
//
// The fix is a scoped prgname swap: from the moment a sub-window is added to
// the GtkApplication (window-added fires synchronously inside
// gtk_application_window_new, before the desktop_multi_window plugin realizes
// or shows it) until it is mapped, prgname is the waveform id, so the map-time
// app_id derivation reads it; the sub-window's own "map" handler (which GTK
// runs *after* the class handler that created the xdg_toplevel) restores it.
// A "hide" re-arms the waveform id, because GTK destroys the xdg_toplevel on
// unmap and re-creates it — re-reading prgname — on the next map. This is
// plain GTK3 and works on any 3.24 (the per-window
// gdk_wayland_window_set_application_id() API only exists since 3.24.22 and
// only applies to an already-created toplevel, i.e. too late for placement).
//
// The app-ids, which deploy/yocto/.../weston-init/files/weston.ini must match:
//   main window:     APPLICATION_ID              ("dev.aquiles.segno")
//   waveform window: APPLICATION_ID ".waveform"  ("dev.aquiles.segno.waveform")
#define WAVEFORM_APPLICATION_ID APPLICATION_ID ".waveform"

// The sub-window just mapped: its xdg_toplevel now exists and carries
// WAVEFORM_APPLICATION_ID. Restore prgname so any toplevel the *main* window
// spawns later (dialogs) keeps the application's own id.
static void sub_window_map_cb(GtkWidget* widget, gpointer user_data) {
  g_set_prgname(APPLICATION_ID);
}

// The sub-window was hidden: its next map re-creates the xdg_toplevel from
// prgname, so arm the waveform id again.
static void sub_window_hide_cb(GtkWidget* widget, gpointer user_data) {
  g_set_prgname(WAVEFORM_APPLICATION_ID);
}

// Implements GtkApplication::window_added.
static void my_application_window_added(GtkApplication* application,
                                        GtkWindow* window) {
  GTK_APPLICATION_CLASS(my_application_parent_class)
      ->window_added(application, window);

  MyApplication* self = MY_APPLICATION(application);
  if (!self->main_window_added) {
    // The first window is the main window created in activate; it keeps
    // APPLICATION_ID.
    self->main_window_added = TRUE;
    return;
  }

  // A desktop_multi_window sub-window — the waveform window. It is created
  // hidden (hiddenAtLaunch) and mapped later on `window_show`, so prgname must
  // hold the waveform id from now until that map.
  g_set_prgname(WAVEFORM_APPLICATION_ID);
  g_signal_connect(window, "map", G_CALLBACK(sub_window_map_cb), nullptr);
  g_signal_connect(window, "hide", G_CALLBACK(sub_window_hide_cb), nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Registers non-multi-window plugins on secondary engines. Sub-windows already
// register `desktop_multi_window` internally; calling fl_register_plugins here
// re-attaches the main window and can break inter-window messaging.
static void register_plugins_for_window(FlPluginRegistry* registry) {
  register_sub_window_plugins(registry);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Segno");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Segno");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Register the generated plugins for every secondary window's engine too.
  desktop_multi_window_plugin_set_window_created_callback(
      register_plugins_for_window);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  GTK_APPLICATION_CLASS(klass)->window_added = my_application_window_added;
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
