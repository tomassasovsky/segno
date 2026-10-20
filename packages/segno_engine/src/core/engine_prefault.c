/*
 * engine_prefault.c — the background prefaulter (engine_prefault.h).
 *
 * One thread per engine, started at configure. It runs at the default
 * time-sharing policy: it only ever has to outrun a write head moving at one
 * second of audio per second. Jobs sit in a fixed table under one mutex; the
 * thread releases it while it faults a chunk in, and names the buffer it is
 * faulting meanwhile (busy_buf). le_prefault_forget drops a buffer's jobs and
 * then waits until that buffer is not the one being faulted, so once it
 * returns nothing faults that range again, and the caller may unmap it: the
 * wait is at most one chunk. A new job wakes the thread at once.
 */
#include "engine_prefault.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "engine_private.h"
#include "rt_alloc.h"

#define LE_PREFAULT_JOBS (LE_MAX_TRACKS * LE_MAX_LANES * 4)
/* At most this much per job per pass. Each chunk holds mmap_lock for read
 * while it populates, and a control thread's mmap or munmap (a press mapping
 * its shadow slots) queues behind it for write, so the chunk bounds that
 * wait, once per mapping: with 1 MB chunks a punch-in that mapped 16 shadow
 * buffers while the thread filled a take waited about 5 ms in all. 64 KB is
 * 16 pages, tens of microseconds, at a few percent of syscall overhead. */
#define LE_PREFAULT_CHUNK_BYTES ((size_t)64 << 10)
/* A follow job outlives its capture by this long, so a quantized or
 * sound-triggered arm that has not fired yet keeps its job. */
#define LE_PREFAULT_IDLE_NS 2000000000LL
#define LE_PREFAULT_PERIOD_NS 20000000L

/* A job faults [start, cap) in, ascending from start, or with [desc]
 * descending from cap; [done] is the edge reached so far (ascending: the
 * first frame not yet in; descending: the last frame in, so cap until the
 * first chunk). A follow job (channel >= 0) is ascending, and its end moves
 * with the capture (le_follow_target), bounded by cap. */
typedef struct le_prefault_job {
  uint64_t id;
  float* buf;
  int32_t channel; /* -1: a fixed range, no track to follow */
  int32_t start;   /* frames */
  int32_t cap;     /* frames */
  int32_t done;    /* frames */
  int32_t desc;
  int64_t idle_since; /* CLOCK_MONOTONIC ns its track stopped capturing, 0 */
  _Atomic int32_t* ready;
} le_prefault_job;

struct le_prefaulter {
  pthread_t thread;
  pthread_mutex_t mu;
  pthread_cond_t cv;      /* wakes the thread: a new job, or shutdown */
  pthread_cond_t idle_cv; /* busy_buf cleared, for le_prefault_forget */
  const float* busy_buf;  /* the buffer being faulted, mutex released */
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

static le_prefault_job* le_prefault_find(struct le_prefaulter* p,
                                         uint64_t id) {
  for (int i = 0; i < p->njobs; ++i) {
    if (p->jobs[i].id == id) return &p->jobs[i];
  }
  return NULL;
}

static int64_t le_prefault_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int le_job_full(const le_prefault_job* j) {
  return j->desc ? j->done <= j->start : j->done >= j->cap;
}

/* One pass, entered and left with the mutex held: one chunk per job. Each
 * chunk is faulted with the mutex released and its buffer named in busy_buf,
 * and only if its job is still queued when its turn comes, so a buffer
 * forgotten meanwhile is never touched again (le_prefault_forget). Returns 1
 * when some job still has work. */
static int le_prefault_pass(le_engine* e, struct le_prefaulter* p) {
  le_prefault_work work[LE_PREFAULT_JOBS];
  int nwork = 0;
  int more = 0;
  const int32_t max = (int32_t)(LE_PREFAULT_CHUNK_BYTES / sizeof(float));
  const int64_t now = le_prefault_now_ns();
  for (int i = 0; i < p->njobs; ++i) {
    le_prefault_job* j = &p->jobs[i];
    if (j->desc) {
      if (j->done <= j->start) continue;
      int32_t frames = j->done - j->start;
      if (frames > max) {
        frames = max;
        more = 1;
      }
      work[nwork++] =
          (le_prefault_work){j->id, j->buf, j->done - frames, frames};
      continue;
    }
    int32_t target = j->cap;
    if (j->channel >= 0) {
      target = le_follow_target(e, j);
      if (le_track_capturing(&e->tracks[j->channel])) {
        j->idle_since = 0;
      } else if (j->idle_since == 0) {
        j->idle_since = now;
      }
    }
    if (target <= j->done) continue;
    int32_t frames = target - j->done;
    if (frames > max) {
      frames = max;
      more = 1;
    }
    work[nwork++] = (le_prefault_work){j->id, j->buf, j->done, frames};
  }
  for (int k = 0; k < nwork; ++k) {
    if (le_prefault_find(p, work[k].id) == NULL) continue; /* forgotten */
    p->busy_buf = work[k].buf;
    pthread_mutex_unlock(&p->mu);
    le_rt_prefault(work[k].buf + work[k].from,
                   (size_t)work[k].frames * sizeof(float));
    pthread_mutex_lock(&p->mu);
    p->busy_buf = NULL;
    pthread_cond_broadcast(&p->idle_cv);
    le_prefault_job* j = le_prefault_find(p, work[k].id);
    if (j == NULL) continue;
    if (j->desc) {
      j->done = work[k].from;
    } else if (j->done == work[k].from) {
      j->done += work[k].frames;
    }
  }
  for (int i = 0; i < p->njobs;) {
    le_prefault_job* j = &p->jobs[i];
    const int full = le_job_full(j);
    if (full || (j->channel >= 0 && j->idle_since != 0 &&
                 now - j->idle_since > LE_PREFAULT_IDLE_NS)) {
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
    /* Woken by a new job or by shutdown, else every 20 ms: a follow job's
     * target moves with its capture, and nothing signals that. */
    if (p->njobs > 0 && le_prefault_pass(e, p)) continue; /* behind: again */
#if defined(__APPLE__)
    /* Darwin has no pthread_condattr_setclock; its relative wait is measured
     * on a monotonic clock already. */
    const struct timespec rel = {0, LE_PREFAULT_PERIOD_NS};
    pthread_cond_timedwait_relative_np(&p->cv, &p->mu, &rel);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts); /* the condvar's clock */
    ts.tv_nsec += LE_PREFAULT_PERIOD_NS;
    if (ts.tv_nsec >= 1000000000L) {
      ts.tv_sec += 1;
      ts.tv_nsec -= 1000000000L;
    }
    pthread_cond_timedwait(&p->cv, &p->mu, &ts);
#endif
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
  pthread_cond_init(&p->idle_cv, NULL);
  /* Timed waits on the monotonic clock, so a wall-clock step (NTP at boot)
   * never stretches or skips the 20 ms period. */
#if defined(__APPLE__)
  pthread_cond_init(&p->cv, NULL); /* le_prefault_main waits relative */
#else
  pthread_condattr_t ca;
  pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
  pthread_cond_init(&p->cv, &ca);
  pthread_condattr_destroy(&ca);
#endif
  e->prefaulter = p;
  return p;
}

/* The whole of [job]'s range now, on the calling thread. */
static void le_prefault_job_now(const le_prefault_job* job) {
  le_rt_prefault(job->buf + job->start,
                 (size_t)(job->cap - job->start) * sizeof(float));
  if (job->ready != NULL) {
    atomic_store_explicit(job->ready, 1, memory_order_release);
  }
}

static void le_prefault_add(le_engine* e, le_prefault_job job) {
  if (job.start >= job.cap) {
    if (job.ready != NULL) {
      atomic_store_explicit(job.ready, 1, memory_order_release);
    }
    return;
  }
  if (!le_rt_prefault_can_run_concurrently()) {
    le_prefault_job_now(&job); /* no kernel-side faulting: here and now */
    return;
  }
  struct le_prefaulter* p = le_prefaulter_get(e);
  if (p == NULL) { /* no table: do it now */
    le_prefault_job_now(&job);
    return;
  }
  job.done = job.desc ? job.cap : job.start;
  pthread_mutex_lock(&p->mu);
  /* The same range of the same buffer queued twice keeps the first one's
   * progress. Different ranges of one buffer are separate jobs: a take over
   * a loop gives its slot a follow job (from the playhead on) and a fill job
   * (the part before it). A freed buffer's jobs are gone before it is
   * unmapped (le_prefault_forget), so an address reused by a new buffer
   * never inherits them. */
  for (int i = 0; i < p->njobs; ++i) {
    const le_prefault_job* q = &p->jobs[i];
    if (q->buf == job.buf && q->channel == job.channel &&
        q->start == job.start && q->cap == job.cap && q->desc == job.desc) {
      pthread_mutex_unlock(&p->mu);
      return;
    }
  }
  if (p->njobs == LE_PREFAULT_JOBS) {
    pthread_mutex_unlock(&p->mu);
    le_prefault_job_now(&job);
    return;
  }
  job.id = ++p->next_id;
  p->jobs[p->njobs++] = job;
  if (!p->running) {
    p->running = pthread_create(&p->thread, NULL, le_prefault_main, e) == 0;
  }
  const int running = p->running;
  pthread_cond_signal(&p->cv); /* start on it now, not at the next period */
  pthread_mutex_unlock(&p->mu);
  if (!running) le_prefault_tick(e); /* no thread: one synchronous pass */
}

void le_prefault_follow(le_engine* e, int32_t channel, float* buf,
                        int32_t cap_frames, int32_t done_frames) {
  if (e == NULL || buf == NULL || cap_frames <= 0) return;
  if (done_frames < 0) done_frames = 0;
  le_prefault_add(e, (le_prefault_job){0, buf, channel, done_frames,
                                       cap_frames, 0, 0, 0, NULL});
}

void le_prefault_range(le_engine* e, float* buf, int32_t from, int32_t to,
                       int descending) {
  if (e == NULL || buf == NULL) return;
  if (from < 0) from = 0;
  if (to <= from) return;
  le_prefault_add(e, (le_prefault_job){0, buf, -1, from, to, 0,
                                       descending != 0, 0, NULL});
}

void le_prefault_buffer(le_engine* e, float* buf, int32_t frames,
                        _Atomic int32_t* ready) {
  if (e == NULL || buf == NULL || frames <= 0) return;
  le_prefault_add(e, (le_prefault_job){0, buf, -1, 0, frames, 0, 0, 0, ready});
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

void le_prefault_pass_for_test(le_engine* e) {
  if (e == NULL || e->prefaulter == NULL) return;
  pthread_mutex_lock(&e->prefaulter->mu);
  (void)le_prefault_pass(e, e->prefaulter);
  pthread_mutex_unlock(&e->prefaulter->mu);
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
  /* A chunk of it may be being faulted right now, with the mutex released:
   * wait that one out (le_prefault_pass checks its job is still queued
   * before every chunk, so it starts no other). */
  while (p->busy_buf == buf) pthread_cond_wait(&p->idle_cv, &p->mu);
  pthread_mutex_unlock(&p->mu);
}

void le_prefault_clear(le_engine* e) {
  if (e == NULL || e->prefaulter == NULL) return;
  struct le_prefaulter* p = e->prefaulter;
  pthread_mutex_lock(&p->mu);
  p->njobs = 0;
  while (p->busy_buf != NULL) pthread_cond_wait(&p->idle_cv, &p->mu);
  pthread_mutex_unlock(&p->mu);
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
  pthread_cond_destroy(&p->idle_cv);
  free(p);
  e->prefaulter = NULL;
}
