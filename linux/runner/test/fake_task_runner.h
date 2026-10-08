// See fake_task_runner.cc.

#ifndef RUNNER_TEST_FAKE_TASK_RUNNER_H_
#define RUNNER_TEST_FAKE_TASK_RUNNER_H_

#include <glib.h>
#include <stdint.h>

typedef struct _FakeTaskRunner FakeTaskRunner;

FakeTaskRunner* fake_task_runner_new();

// Same contract as fl_task_runner_post_flutter_task: run a task at
// target_time_nanos on the g_get_monotonic_time clock.
void fake_task_runner_post(FakeTaskRunner* runner, uint64_t target_time_nanos);

guint64 fake_task_runner_tasks_run(FakeTaskRunner* runner);

#endif  // RUNNER_TEST_FAKE_TASK_RUNNER_H_
