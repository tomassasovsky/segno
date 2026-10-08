// Drives the embedder's task-runner scheduling (fake_task_runner.cc) the way
// the appliance does: the main thread runs the GLib loop while other threads
// post tasks. Then it counts the timeouts left attached to the main context.
//
//   --expect-orphans  built WITHOUT the guard: the upstream race must leave
//                     orphaned timeouts behind, or this harness proves nothing.
//   --expect-guarded  built WITH task_runner_timeout_guard.cc: at most the one
//                     tracked timeout may remain, and every task must have run.
//
// run_task_runner_guard_test.sh builds and runs both.

#include <glib.h>
#include <stdio.h>
#include <string.h>

#include <atomic>

#include "fake_task_runner.h"

namespace {

constexpr int kPosterThreads = 4;
constexpr gint64 kPostingMicros = G_GINT64_CONSTANT(3) * G_USEC_PER_SEC;
constexpr gint64 kDrainMicros = 500 * 1000;
// A task far in the future keeps the runner's queue non-empty, as the engine's
// does in practice, so orphans keep rescheduling instead of dying out.
constexpr gint64 kFarFutureMicros = G_GINT64_CONSTANT(3600) * G_USEC_PER_SEC;

std::atomic<bool> posting{true};
std::atomic<guint64> near_tasks_posted{0};

guint64 nanos_from_now(gint64 micros) {
  return static_cast<guint64>(g_get_monotonic_time() + micros) * 1000;
}

gpointer poster(gpointer data) {
  FakeTaskRunner* runner = static_cast<FakeTaskRunner*>(data);
  GRand* rand = g_rand_new();
  while (posting.load()) {
    fake_task_runner_post(runner, nanos_from_now(g_rand_int_range(rand, 0, 2000)));
    near_tasks_posted++;
    g_usleep(g_rand_int_range(rand, 0, 200));
  }
  g_rand_free(rand);
  return nullptr;
}

void run_loop_for(gint64 micros) {
  const gint64 end = g_get_monotonic_time() + micros;
  while (g_get_monotonic_time() < end) {
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(50);
  }
}

// GLib hands out source ids sequentially, so scanning up to a fresh id visits
// every source that could still be attached.
guint count_attached_timeouts() {
  const guint newest = g_idle_add([](gpointer) { return G_SOURCE_REMOVE; },
                                  nullptr);
  g_source_remove(newest);
  guint count = 0;
  for (guint id = 1; id < newest; id++) {
    GSource* source = g_main_context_find_source_by_id(nullptr, id);
    if (source != nullptr && source->source_funcs == &g_timeout_funcs &&
        !g_source_is_destroyed(source)) {
      count++;
    }
  }
  return count;
}

}  // namespace

int main(int argc, char** argv) {
  const bool expect_guarded =
      argc == 2 && strcmp(argv[1], "--expect-guarded") == 0;
  const bool expect_orphans =
      argc == 2 && strcmp(argv[1], "--expect-orphans") == 0;
  if (!expect_guarded && !expect_orphans) {
    fprintf(stderr, "usage: %s --expect-guarded | --expect-orphans\n", argv[0]);
    return 2;
  }

  FakeTaskRunner* runner = fake_task_runner_new();
  fake_task_runner_post(runner, nanos_from_now(kFarFutureMicros));

  GThread* threads[kPosterThreads];
  for (GThread*& thread : threads) {
    thread = g_thread_new("poster", poster, runner);
  }
  run_loop_for(kPostingMicros);
  posting = false;
  for (GThread* thread : threads) {
    g_thread_join(thread);
  }
  run_loop_for(kDrainMicros);

  const guint attached = count_attached_timeouts();
  const guint64 posted = near_tasks_posted.load();
  const guint64 run = fake_task_runner_tasks_run(runner);
  printf("posted %" G_GUINT64_FORMAT " near tasks, ran %" G_GUINT64_FORMAT
         ", %u timeouts still attached\n",
         posted, run, attached);

  if (expect_orphans) {
    if (attached <= 1) {
      fprintf(stderr, "FAIL: the unguarded runner left no orphans; the race "
                      "was not reproduced\n");
      return 1;
    }
    printf("PASS: unguarded runner leaks timeouts\n");
    return 0;
  }
  if (attached > 1) {
    fprintf(stderr, "FAIL: %u timeouts attached with the guard (want <= 1)\n",
            attached);
    return 1;
  }
  if (run != posted) {
    fprintf(stderr, "FAIL: %" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT
                    " tasks never ran\n",
            posted - run, posted);
    return 1;
  }
  printf("PASS: guard keeps one timeout and every task runs\n");
  return 0;
}
