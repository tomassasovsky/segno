#include <glib.h>
#include <stdlib.h>
#include <unistd.h>

#include "my_application.h"

// Impeller is the default renderer on Linux/GTK as of Flutter 3.44, but it
// mis-rasterizes the bundled Material icon font there — icons render as empty
// "tofu" boxes. Until Linux Impeller matures, force the Skia backend.
//
// The GTK embedder reads engine switches from the FLUTTER_ENGINE_SWITCHES /
// FLUTTER_ENGINE_SWITCH_<N> environment variables, which is also how the
// `flutter` tool passes its own switches for `flutter run`. We therefore
// *append* our switch to whatever is already set rather than overwrite it, so
// debug-run switches keep working.
static void force_skia_renderer() {
  const gchar* count_str = g_getenv("FLUTTER_ENGINE_SWITCHES");
  int count = count_str != nullptr ? atoi(count_str) : 0;
  count += 1;

  g_autofree gchar* switch_key = g_strdup_printf("FLUTTER_ENGINE_SWITCH_%d", count);
  g_setenv(switch_key, "enable-impeller=false", TRUE);

  g_autofree gchar* count_value = g_strdup_printf("%d", count);
  g_setenv("FLUTTER_ENGINE_SWITCHES", count_value, TRUE);
}

// segno-prof gsources (deploy/yocto, #1299) reads the main loop's sources from
// outside the process, which works even while the loop is wedged. GLib keeps
// the default context in a private static, so say where it is. Only the
// appliance image creates /run/segno; elsewhere this does nothing.
static void publish_main_context() {
  if (!g_file_test("/run/segno", G_FILE_TEST_IS_DIR)) {
    return;
  }
  g_autofree gchar* contents = g_strdup_printf(
      "%d %u.%u.%u %p\n", getpid(), glib_major_version, glib_minor_version,
      glib_micro_version, static_cast<void*>(g_main_context_default()));
  g_autoptr(GError) error = nullptr;
  if (!g_file_set_contents("/run/segno/main-context", contents, -1, &error)) {
    g_warning("cannot publish the main context: %s", error->message);
  }
}

int main(int argc, char** argv) {
  force_skia_renderer();
  publish_main_context();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
