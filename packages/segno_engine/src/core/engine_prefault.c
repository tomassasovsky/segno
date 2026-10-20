/*
 * engine_prefault.c — the background prefaulter (engine_prefault.h).
 *
 * One thread per engine, started by the first job. It runs at the default
 * time-sharing policy: it only ever has to outrun a write head moving at one
 * second of audio per second. Jobs sit in a fixed table under one mutex,
 * which the thread holds while it faults a bounded chunk in, so a control
 * thread that forgets a buffer before freeing it waits at most one chunk.
 */
#include "engine_prefault.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "engine_private.h"
#include "rt_alloc.h"

#define LE_PREFAULT_JOBS (LE_MAX_TRACKS * LE_MAX_LANES * 4)
/* At most this much per job per pass, so a forget never waits long. */
#define LE_PREFAULT_CHUNK_BYTES ((size_t)4 << 20)
/* A follow job outlives its capture by this many idle passes (2 s), so a
 * quantized or sound-triggered arm that has not fired yet keeps its job. */
#define LE_PREFAULT_IDLE_PASSES 100
#define LE_PREFAULT_PERIOD_NS 20000000L

typedef struct le_prefault_job {
  uint64_t id;
  float* buf;
  int32_t channel; /* -1: fault the whole buffer in, no track to follow */
  int32_t cap;     /* frames */
  int32_t done;    /* frames faulted in from the start */
  int32_t idle;    /* passes without a capture, for follow jobs */
  _Atomic int32_t* ready;
} le_prefault_job;

struct le_prefaulter {
  pthread_t thread;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int running;
  int stop;
  int njobs;
  uint64_t next_id;
  le_prefault_job jobs[LE_PREFAULT_JOBS];
};

typedef struct le_prefault_work {
  uint64_t id;
  float* buf;
  int32_t from;
  int32_t frames;
} le_prefault_work;

static int le_track_capturing(le_track* t) {
  const int32_t st = load_i32(&t->a_state);
  return st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
         load_i32(&t->a_pending) || load_i32(&t->a_pending_launch);
}

/* How far a follow job must be faulted in now: LE_PREFAULT_AHEAD_SECONDS past
 * the furthest frame the capture may write next. That is its write head
 * (a_len is the take's record_pos while it records), or for a capture still
 * waiting to start over an existing loop, anywhere up to that loop's length
 * (a sound-triggered start fires wherever the signal crosses). */
static int32_t le_follow_target(le_engine* e, const le_prefault_job* j) {
  le_track* t = &e->tracks[j->channel];
  int64_t at = load_i32(&t->lanes[0].a_len);
  const int64_t master = load_i32(&e->a_master_len);
  if (master > at) at = master;
  const int64_t rate = e->sample_rate > 0 ? e->sample_rate : 48000;
  const int64_t target = at + (int64_t)LE_PREFAULT_AHEAD_SECONDS * rate;
  return target < j->cap ? (int32_t)target : j->cap;
}

/* One pass, entered and left with the mutex held. The faulting itself runs
 * with the mutex released, so a control thread adding or forgetting a job
 * never waits for it (a buffer freed meanwhile costs nothing: the faulting
 * is kernel-side, le_rt_prefault_can_run_concurrently). Returns 1 when some
 * job still has work. */
static int le_prefault_pass(le_engine* e, struct le_prefaulter* p) {
  le_prefault_work work[LE_PREFAULT_JOBS];
  int nwork = 0;
  int more = 0;
  for (int i = 0; i < p->njobs; ++i) {
    le_prefault_job* j = &p->jobs[i];
    int32_t target = j->cap;
    if (j->channel >= 0) {
      target = le_follow_target(e, j);
      j->idle = le_track_capturing(&e->tracks[j->channel]) ? 0 : j->idle + 1;
    }
    if (target <= j->done) continue;
    int32_t frames = target - j->done;
    const int32_t max = (int32_t)(LE_PREFAULT_CHUNK_BYTES / sizeof(float));
    if (frames > max) {
      frames = max;
      more = 1;
    }
    work[nwork++] = (le_prefault_work){j->id, j->buf, j->done, frames};
  }
  pthread_mutex_unlock(&p->mu);
  for (int k = 0; k < nwork; ++k) {
    le_rt_prefault(work[k].buf + work[k].from,
                   (size_t)work[k].frames * sizeof(float));
  }
  pthread_mutex_lock(&p->mu);
  for (int k = 0; k < nwork; ++k) {
    for (int i = 0; i < p->njobs; ++i) {
      le_prefault_job* j = &p->jobs[i];
      if (j->id == work[k].id && j->done == work[k].from) {
        j->done += work[k].frames;
      }
    }
  }
  for (int i = 0; i < p->njobs;) {
    le_prefault_job* j = &p->jobs[i];
    const int full = j->done >= j->cap;
    if (full || (j->channel >= 0 && j->idle > LE_PREFAULT_IDLE_PASSES)) {
      if (full && j->ready != NULL) {
        atomic_store_explicit(j->ready, 1, memory_order_release);
      }
      p->jobs[i] = p->jobs[--p->njobs];
      continue;
    }
    ++i;
  }
  return more;
}

static void* le_prefault_main(void* arg) {
  le_engine* e = (le_engine*)arg;
  struct le_prefaulter* p = e->prefaulter;
  pthread_mutex_lock(&p->mu);
  while (!p->stop) {
    /* Woken only by shutdown: adding a job never signals, so a take start
     * pays no wakeup. The 20 ms period is far inside the head and lead a
     * job is given (engine_prefault.h). */
    if (p->njobs > 0 && le_prefault_pass(e, p)) continue; /* behind: again */
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += LE_PREFAULT_PERIOD_NS;
    if (ts.tv_nsec >= 1000000000L) {
      ts.tv_sec += 1;
      ts.tv_nsec -= 1000000000L;
    }
    pthread_cond_timedwait(&p->cv, &p->mu, &ts);
  }
  pthread_mutex_unlock(&p->mu);
  return NULL;
}

/* The table, created with the first job. NULL when it cannot be. */
static struct le_prefaulter* le_prefaulter_get(le_engine* e) {
  if (e->prefaulter != NULL) return e->prefaulter;
  struct le_prefaulter* p =
      (struct le_prefaulter*)calloc(1, sizeof(struct le_prefaulter));
  if (p == NULL) return NULL;
  pthread_mutex_init(&p->mu, NULL);
  pthread_cond_init(&p->cv, NULL);
  e->prefaulter = p;
  return p;
}

static void le_prefault_add(le_engine* e, le_prefault_job job) {
  struct le_prefaulter* p = le_prefaulter_get(e);
  if (p == NULL) { /* no table: do it now */
    le_rt_prefault(job.buf + job.done,
                   (size_t)(job.cap - job.done) * sizeof(float));
    if (job.ready != NULL) atomic_store_explicit(job.ready, 1, memory_order_release);
    return;
  }
  pthread_mutex_lock(&p->mu);
  int slot = -1;
  for (int i = 0; i < p->njobs; ++i) {
    if (p->jobs[i].buf != job.buf) continue;
    if (p->jobs[i].cap == job.cap && p->jobs[i].channel == job.channel) {
      pthread_mutex_unlock(&p->mu); /* already queued: keep its progress */
      return;
    }
    slot = i; /* the same buffer, a new shape: replace */
  }
  if (slot < 0 && p->njobs < LE_PREFAULT_JOBS) slot = p->njobs++;
  if (slot < 0) {
    pthread_mutex_unlock(&p->mu);
    le_rt_prefault(job.buf + job.done,
                   (size_t)(job.cap - job.done) * sizeof(float));
    if (job.ready != NULL) atomic_store_explicit(job.ready, 1, memory_order_release);
    return;
  }
  job.id = ++p->next_id;
  p->jobs[slot] = job;
  if (!p->running) {
    p->running = pthread_create(&p->thread, NULL, le_prefault_main, e) == 0;
  }
  const int running = p->running;
  pthread_mutex_unlock(&p->mu);
  if (!running) le_prefault_tick(e); /* no thread: one synchronous pass */
}

void le_prefault_follow(le_engine* e, int32_t channel, float* buf,
                        int32_t cap_frames, int32_t done_frames) {
  if (e == NULL || buf == NULL || cap_frames <= 0) return;
  if (done_frames < 0) done_frames = 0;
  if (done_frames >= cap_frames) return;
  if (!le_rt_prefault_can_run_concurrently()) {
    le_rt_prefault(buf + done_frames,
                   (size_t)(cap_frames - done_frames) * sizeof(float));
    return;
  }
  le_prefault_add(e, (le_prefault_job){0, buf, channel, cap_frames,
                                       done_frames, 0, NULL});
}

void le_prefault_buffer(le_engine* e, float* buf, int32_t frames,
                        _Atomic int32_t* ready) {
  if (e == NULL || buf == NULL || frames <= 0) return;
  if (!le_rt_prefault_can_run_concurrently()) {
    le_rt_prefault(buf, (size_t)frames * sizeof(float));
    if (ready != NULL) atomic_store_explicit(ready, 1, memory_order_release);
    return;
  }
  le_prefault_add(e, (le_prefault_job){0, buf, -1, frames, 0, 0, ready});
}

void le_prefault_start(le_engine* e) {
  if (e == NULL || !le_rt_prefault_can_run_concurrently()) return;
  struct le_prefaulter* p = le_prefaulter_get(e);
  if (p == NULL) return;
  pthread_mutex_lock(&p->mu);
  if (!p->running) {
    p->running = pthread_create(&p->thread, NULL, le_prefault_main, e) == 0;
  }
  pthread_mutex_unlock(&p->mu);
}

void le_prefault_tick(le_engine* e) {
  if (e == NULL || e->prefaulter == NULL) return;
  struct le_prefaulter* p = e->prefaulter;
  pthread_mutex_lock(&p->mu);
  while (le_prefault_pass(e, p)) {
  }
  pthread_mutex_unlock(&p->mu);
}

void le_prefault_forget(le_engine* e, const float* buf) {
  if (e == NULL || e->prefaulter == NULL || buf == NULL) return;
  struct le_prefaulter* p = e->prefaulter;
  pthread_mutex_lock(&p->mu);
  for (int i = 0; i < p->njobs;) {
    if (p->jobs[i].buf == buf) {
      p->jobs[i] = p->jobs[--p->njobs];
    } else {
      ++i;
    }
  }
  pthread_mutex_unlock(&p->mu);
}

void le_prefault_clear(le_engine* e) {
  if (e == NULL || e->prefaulter == NULL) return;
  pthread_mutex_lock(&e->prefaulter->mu);
  e->prefaulter->njobs = 0;
  pthread_mutex_unlock(&e->prefaulter->mu);
}

void le_prefault_shutdown(le_engine* e) {
  if (e == NULL || e->prefaulter == NULL) return;
  struct le_prefaulter* p = e->prefaulter;
  pthread_mutex_lock(&p->mu);
  p->stop = 1;
  p->njobs = 0;
  pthread_cond_signal(&p->cv);
  const int running = p->running;
  pthread_mutex_unlock(&p->mu);
  if (running) pthread_join(p->thread, NULL);
  pthread_mutex_destroy(&p->mu);
  pthread_cond_destroy(&p->cv);
  free(p);
  e->prefaulter = NULL;
}
