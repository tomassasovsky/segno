// The scheduling half of the Flutter GTK embedder's FlTaskRunner, built into a
// stand-in libflutter_linux_gtk.so so task_runner_timeout_guard.cc treats its
// timeouts exactly as it treats the real embedder's.
//
// The logic below is fl_task_runner.cc from Flutter 3.44.4
// (engine/src/flutter/shell/platform/linux/fl_task_runner.cc), with the GObject
// wrapper and FlEngine calls removed and a counter standing in for running a
// task. Keep the locking and the timeout handling identical: they are the bug.
//
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file at https://github.com/flutter/flutter.

#include "fake_task_runner.h"

static constexpr int kMicrosecondsPerNanosecond = 1000;
static constexpr int kMillisecondsPerMicrosecond = 1000;

struct _FakeTaskRunner {
  GMutex mutex;
  guint timeout_source_id;
  GList* pending_tasks;
  guint64 tasks_run;
};

typedef struct {
  gint64 task_time_micros;
} FakeTask;

static void tasks_did_change_locked(FakeTaskRunner* self);

static void process_expired_tasks_locked(FakeTaskRunner* self) {
  GList* expired_tasks = nullptr;
  gint64 current_time = g_get_monotonic_time();

  GList* l = self->pending_tasks;
  while (l != nullptr) {
    FakeTask* task = static_cast<FakeTask*>(l->data);
    if (task->task_time_micros <= current_time) {
      GList* link = l;
      l = l->next;
      self->pending_tasks = g_list_remove_link(self->pending_tasks, link);
      expired_tasks = g_list_concat(expired_tasks, link);
    } else {
      l = l->next;
    }
  }

  g_mutex_unlock(&self->mutex);
  for (l = expired_tasks; l != nullptr; l = l->next) {
    self->tasks_run++;
  }
  g_list_free_full(expired_tasks, g_free);
  g_mutex_lock(&self->mutex);
}

static gboolean on_expired_timeout(gpointer data) {
  FakeTaskRunner* self = static_cast<FakeTaskRunner*>(data);
  g_mutex_lock(&self->mutex);
  self->timeout_source_id = 0;
  process_expired_tasks_locked(self);
  tasks_did_change_locked(self);
  g_mutex_unlock(&self->mutex);
  return G_SOURCE_REMOVE;
}

static gint64 next_task_expiration_time_locked(FakeTaskRunner* self) {
  gint64 min_time = G_MAXINT64;
  for (GList* l = self->pending_tasks; l != nullptr; l = l->next) {
    FakeTask* task = static_cast<FakeTask*>(l->data);
    min_time = MIN(min_time, task->task_time_micros);
  }
  return min_time;
}

static void tasks_did_change_locked(FakeTaskRunner* self) {
  if (self->timeout_source_id != 0) {
    g_source_remove(self->timeout_source_id);
    self->timeout_source_id = 0;
  }
  gint64 min_time = next_task_expiration_time_locked(self);
  if (min_time != G_MAXINT64) {
    gint64 remaining = MAX(min_time - g_get_monotonic_time(), 0);
    self->timeout_source_id = g_timeout_add(
        remaining / kMillisecondsPerMicrosecond + 1, on_expired_timeout, self);
  }
}

FakeTaskRunner* fake_task_runner_new() {
  FakeTaskRunner* self = g_new0(FakeTaskRunner, 1);
  g_mutex_init(&self->mutex);
  return self;
}

void fake_task_runner_post(FakeTaskRunner* self, uint64_t target_time_nanos) {
  g_mutex_lock(&self->mutex);
  FakeTask* task = g_new0(FakeTask, 1);
  task->task_time_micros = target_time_nanos / kMicrosecondsPerNanosecond;
  self->pending_tasks = g_list_append(self->pending_tasks, task);
  tasks_did_change_locked(self);
  g_mutex_unlock(&self->mutex);
}

guint64 fake_task_runner_tasks_run(FakeTaskRunner* self) {
  g_mutex_lock(&self->mutex);
  guint64 count = self->tasks_run;
  g_mutex_unlock(&self->mutex);
  return count;
}
