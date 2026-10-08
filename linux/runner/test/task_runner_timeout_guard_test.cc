// Drives the embedder's task-runner scheduling (fake_task_runner.cc) through
// the race behind #1299, then counts the timeouts left attached to the main
// context.
//
// The race needs a task posted between GLib dispatching the runner's timeout
// and the callback taking the runner's mutex. On the appliance another thread
// lands there now and then; a CI runner may never do it in a few seconds. So
// the fake runner calls a hook in exactly that window, and the hook posts the
// task, on every dispatch: the race happens every time, on any machine.
//
//   --expect-orphans  built WITHOUT the guard: the race must leave orphaned
//                     timeouts behind, or this harness proves nothing.
//   --expect-guarded  built WITH task_runner_timeout_guard.cc: at most the one
//                     tracked timeout may remain, and every task must have run.
//
// run_task_runner_guard_test.sh builds and runs both.

#include <glib.h>
#include <stdio.h>
#include <string.h>

#include "fake_task_runner.h"

namespace {

// How many dispatches get a post in the race window.
constexpr int kRacedDispatches = 50;
constexpr gint64 kNearMicros = 1000;
// A task far in the future keeps the runner's queue non-empty, as the engine's
// does in practice, so orphans keep rescheduling instead of dying out.
constexpr gint64 kFarFutureMicros = G_GINT64_CONSTANT(3600) * G_USEC_PER_SEC;
constexpr gint64 kDeadlineMicros = 5 * G_USEC_PER_SEC;

int raced = 0;
guint64 near_tasks_posted = 0;

guint64 nanos_from_now(gint64 micros) {
  return static_cast<guint64>(g_get_monotonic_time() + micros) * 1000;
}

void post_near(FakeTaskRunner* runner) {
  fake_task_runner_post(runner, nanos_from_now(kNearMicros));
  near_tasks_posted++;
}

// Runs inside the race window: a post here orphans the replacement timeout.
void post_in_race_window(FakeTaskRunner* runner) {
  if (raced < kRacedDispatches) {
    raced++;
    post_near(runner);
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
  fake_task_runner_set_before_timeout(runner, post_in_race_window);
  post_near(runner);

  // Until every raced post has happened and every near task has run, then a
  // little longer so any orphan due soon fires and shows its hand.
  const gint64 deadline = g_get_monotonic_time() + kDeadlineMicros;
  while (g_get_monotonic_time() < deadline &&
         (raced < kRacedDispatches ||
          fake_task_runner_tasks_run(runner) < near_tasks_posted)) {
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(100);
  }
  const gint64 settle = g_get_monotonic_time() + 50 * 1000;
  while (g_get_monotonic_time() < settle) {
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(100);
  }

  const guint attached = count_attached_timeouts();
  const guint64 run = fake_task_runner_tasks_run(runner);
  printf("raced %d dispatches, posted %" G_GUINT64_FORMAT
         " near tasks, ran %" G_GUINT64_FORMAT ", %u timeouts attached\n",
         raced, near_tasks_posted, run, attached);

  if (raced < kRacedDispatches) {
    fprintf(stderr, "FAIL: only %d of %d dispatches happened\n", raced,
            kRacedDispatches);
    return 1;
  }
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
  if (run != near_tasks_posted) {
    fprintf(stderr, "FAIL: %" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT
                    " tasks never ran\n",
            near_tasks_posted - run, near_tasks_posted);
    return 1;
  }
  printf("PASS: guard keeps one timeout and every task runs\n");
  return 0;
}
