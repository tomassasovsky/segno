// Keeps the Flutter GTK embedder's platform task runner to one live timeout.
//
// The embedder's FlTaskRunner (shell/platform/linux/fl_task_runner.cc, Flutter
// 3.44.4 and master as of 2026-10) tracks a single GLib timeout in
// `timeout_source_id`. Every posted task removes that timeout and adds a new
// one. The timeout's own callback starts by setting `timeout_source_id = 0`
// without checking that the timeout being dispatched is still the tracked one.
// So when another thread posts a task between the timeout becoming ready and
// its callback taking the runner's mutex, the replacement timeout is orphaned:
// nothing will ever remove it. An orphan that fires does the same thing again
// (it zeroes whichever timeout is tracked and adds a new one), so orphans never
// die out while any task is pending, and every lost race adds one for good.
//
// On the appliance this grew to ~3,400 live timeouts after 14 hours (#1299).
// GLib walks every attached source on each main-loop iteration and they all
// fire every millisecond or so, which pinned the main thread (where the Dart UI
// isolate also runs) at ~90% of a core and starved idle callbacks for seconds.
//
// The fix belongs in the engine, which this app takes prebuilt. Until the
// engine carries it, this file interposes g_timeout_add: the executable's
// definition wins symbol lookup over libglib's, so libflutter_linux_gtk.so's
// calls land here. fl_task_runner.cc is the only g_timeout_add caller in the
// embedder, so a callback that lives in libflutter_linux_gtk.so identifies the
// task runner. For those calls we keep a reference to the newest timeout per
// runner and destroy the previous one. The embedder means exactly that
// invariant: the previous timeout is either already removed (the normal path)
// or orphaned (the race). Every other caller goes straight to GLib.

#include <dlfcn.h>
#include <glib.h>

#include <atomic>
#include <mutex>
#include <unordered_map>

namespace {

constexpr char kEmbedderLibrary[] = "/libflutter_linux_gtk.so";

std::atomic<GSourceFunc> task_runner_callback{nullptr};

std::mutex latest_mutex;
// Task runner -> its newest timeout, referenced so the pointer stays valid
// after GLib destroys the source.
std::unordered_map<gpointer, GSource*> latest_timeouts;

std::atomic<guint64> orphans_destroyed{0};

bool is_task_runner_callback(GSourceFunc function) {
  if (function == task_runner_callback.load(std::memory_order_relaxed)) {
    return true;
  }
  Dl_info info;
  if (dladdr(reinterpret_cast<void*>(function), &info) == 0 ||
      info.dli_fname == nullptr ||
      !g_str_has_suffix(info.dli_fname, kEmbedderLibrary)) {
    return false;
  }
  task_runner_callback.store(function, std::memory_order_relaxed);
  return true;
}

// Logs the first orphan and then every power of two, so the log shows the race
// happening without one line per occurrence.
void note_orphan_destroyed() {
  const guint64 count = orphans_destroyed.fetch_add(1) + 1;
  if ((count & (count - 1)) == 0) {
    g_message("task runner guard: destroyed %" G_GUINT64_FORMAT
              " orphaned embedder timeouts (#1299)",
              count);
  }
}

}  // namespace

extern "C" __attribute__((visibility("default"))) guint g_timeout_add(
    guint interval,
    GSourceFunc function,
    gpointer data) {
  // g_timeout_add is g_timeout_add_full at the default priority, which does
  // not route back through this symbol.
  if (!is_task_runner_callback(function)) {
    return g_timeout_add_full(G_PRIORITY_DEFAULT, interval, function, data,
                              nullptr);
  }

  GSource* source = g_timeout_source_new(interval);
  g_source_set_callback(source, function, data, nullptr);
  const guint id = g_source_attach(source, nullptr);

  GSource* previous = nullptr;
  {
    std::lock_guard<std::mutex> lock(latest_mutex);
    GSource*& slot = latest_timeouts[data];
    previous = slot;
    slot = source;  // Keeps the attach reference.
  }

  // A previous timeout that is mid-dispatch is not an orphan: its callback
  // zeroed timeout_source_id and is rescheduling, and returning
  // G_SOURCE_REMOVE ends it. GLib sets G_HOOK_FLAG_IN_CALL for the duration of
  // the callback.
  if (previous != nullptr) {
    if (!g_source_is_destroyed(previous) &&
        (previous->flags & G_HOOK_FLAG_IN_CALL) == 0) {
      g_source_destroy(previous);
      note_orphan_destroyed();
    }
    g_source_unref(previous);
  }
  return id;
}
