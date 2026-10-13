// See fake_task_runner.cc.

#ifndef RUNNER_TEST_FAKE_TASK_RUNNER_H_
#define RUNNER_TEST_FAKE_TASK_RUNNER_H_

#include <glib.h>
#include <stdint.h>

typedef struct _FakeTaskRunner FakeTaskRunner;

typedef void (*FakeTaskRunnerHook)(FakeTaskRunner* runner);

FakeTaskRunner* fake_task_runner_new();

// Same contract as fl_task_runner_post_flutter_task: run a task at
// target_time_nanos on the g_get_monotonic_time clock.
void fake_task_runner_post(FakeTaskRunner* runner, uint64_t target_time_nanos);

// Runs [hook] at the start of every timeout callback, before it takes the
// runner's mutex: the window the upstream race needs another thread to post
// in. Lets the test land a post there every time instead of by chance.
void fake_task_runner_set_before_timeout(FakeTaskRunner* runner,
                                         FakeTaskRunnerHook hook);

guint64 fake_task_runner_tasks_run(FakeTaskRunner* runner);

#endif  // RUNNER_TEST_FAKE_TASK_RUNNER_H_
