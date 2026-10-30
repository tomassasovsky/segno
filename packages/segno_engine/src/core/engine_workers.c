/*
 * engine_workers.c — effects on more than one core (#1515, part 1).
 *
 * A job is one monitor input's whole chain over one block of the callback's
 * frame loop (le_fx_par). The callback runs the first frame loop, releases the
 * block's jobs, claims them alongside the workers, waits until every one is
 * done, then runs the second loop, which mixes the jobs' outputs in input
 * order. Fork-join inside the period: no latency is added, and the output is
 * bit-identical with any number of workers, because every job sees the clock,
 * the tempo and the input it saw when it ran inside the one frame loop
 * (docs/plan/2026-10-29-feat-multicore-effects-plan.md, sections 5 and 6).
 *
 * THE HANDOFF. a_claim holds the round's epoch, its job count and the next
 * job: a thread claims a job with a compare-and-swap, so it can never take a
 * job of another round, and it reads nothing of the round until it holds a
 * job, which the callback waits for. The callback publishes the round with a
 * release store of a_claim, bumps the futex word a_gen and wakes the workers
 * once (FUTEX_WAKE_PRIVATE); each job ends with a release increment of
 * a_done, which the callback's join reads with acquire. The workers sleep
 * through the first loop: they are woken only once the round's jobs exist.
 *
 * A LATE WORKER is waited for. A job a worker has not claimed yet is claimed
 * by the callback, so a worker that never wakes costs only time; a job a
 * worker has started cannot be taken over (its chain state is half
 * advanced), so the join waits for it. There is no dry or silent fallback.
 *
 * REAL-TIME SAFETY (#710). Nothing on the job path allocates, locks or makes a
 * syscall but the one wake. Everything a job touches is engine memory, which
 * is locked and fork-shielded (rt_alloc.h); so are the workers' stacks. The
 * futex is private, so its key never walks the page tables, and its word is
 * in that same memory.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1 /* pthread_setname_np */
#endif
#include "engine_workers.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "engine_fx.h"          /* fx_apply_chain, le_flush_denormals */
#include "engine_instruments.h" /* le_instrument_source_sample */
#include "engine_platform.h"    /* the worker setup, wait and wake */
#include "rt_alloc.h"

/* One worker thread. Control-thread memory: the worker reads it only while
 * it starts. */
typedef struct le_fx_worker {
  le_engine* e;
  int32_t index;
  int32_t core;
  int rt; /* SCHED_FIFO (le_platform_rt_audio, asked once at the start) */
  pthread_t thread;
  int created;
  void* stack_block; /* le_rt_alloc'd; the stack is page-aligned inside it */
  /* 0 while starting, 1 running, -1 refused its core or its priority. */
  _Atomic int32_t a_state;
} le_fx_worker;

struct le_fx_pool {
  le_fx_worker w[LE_FX_WORKERS_MAX];
};

/* The claim word (le_fx_par.a_claim): the epoch, the round's jobs, the next
 * job. LE_MAX_MONITORED_INPUTS bounds the jobs well below 16 bits. */
static inline uint64_t le_fx_claim_word(uint32_t epoch, uint32_t jobs,
                                        uint32_t next) {
  return ((uint64_t)epoch << 32) | ((uint64_t)(jobs & 0xFFFFu) << 16) |
         (uint64_t)(next & 0xFFFFu);
}

static inline void le_fx_cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ __volatile__("yield" ::: "memory");
#elif defined(__x86_64__) || defined(__i386__)
  __asm__ __volatile__("pause" ::: "memory");
#endif
}

/* One monitor input's chain over the block (D2): exactly what the one frame
 * loop ran for it before, frame by frame, with its own clock and the block's
 * tempo anchors replayed at the frames the first loop set them. Writes only
 * the monitor's rows of le_fx_par and its own chain state. */
static void le_fx_monitor_job(le_engine* e, int32_t c) {
  le_fx_par* p = &e->fx_par;
  le_monitor_input* m = &e->monitors[c];
  le_fx_time* t = &m->fx_time;
  const le_fx_snapshot* snap = &e->fx_snap;
  const int instrument = c >= LE_INSTRUMENT_SOURCE_BASE;
  float* ol = p->mon_l[c];
  float* orr = p->mon_r[c];
  int32_t tev = 0;
  t->tempo = p->tempo0;
  for (uint32_t i = 0; i < p->n; ++i) {
    while (tev < p->tev_n && p->tev_at[tev] <= (int32_t)i) {
      t->tempo = p->tev[tev++];
    }
    if (p->owned[i]) continue; /* the latency harness's frame: no monitors */
    const uint32_t f = p->f0 + i;
    atomic_store_explicit(&t->a_frame, p->clock + i, memory_order_relaxed);
    const float clean =
        instrument ? le_instrument_source_sample(e, c, f)
                   : p->in[f * (uint32_t)p->ch_in + (uint32_t)c];
    float l = clean;
    float r = clean;
    fx_apply_chain(&m->fx, p->sr, p->fx_cap, &l, &r, snap->mon_count[c],
                   snap->mon_type[c], snap->mon_params[c],
                   snap->mon_enabled[c]);
    ol[i] = l;
    orr[i] = r;
  }
  while (tev < p->tev_n) t->tempo = p->tev[tev++];
  atomic_store_explicit(&t->a_frame, p->clock + p->n, memory_order_relaxed);
}

static inline void le_fx_max_u32(_Atomic uint32_t* slot, uint64_t v) {
  const uint32_t x = v > UINT32_MAX ? UINT32_MAX : (uint32_t)v;
  /* Single writer (the worker or the callback that owns the slot). */
  if (x > atomic_load_explicit(slot, memory_order_relaxed)) {
    atomic_store_explicit(slot, x, memory_order_relaxed);
  }
}

/* Claims and runs jobs of round [epoch] until none is left; returns how many
 * this thread ran. [tm] is the worker's telemetry, NULL on the callback. */
static uint32_t le_fx_claim(le_engine* e, uint32_t epoch, le_fx_worker_tm* tm) {
  le_fx_par* p = &e->fx_par;
  uint32_t ran = 0;
  uint64_t c = atomic_load_explicit(&p->a_claim, memory_order_acquire);
  for (;;) {
    if ((uint32_t)(c >> 32) != epoch) return ran;
    const uint32_t jobs = (uint32_t)(c >> 16) & 0xFFFFu;
    const uint32_t next = (uint32_t)c & 0xFFFFu;
    if (next >= jobs) return ran;
    if (!atomic_compare_exchange_weak_explicit(&p->a_claim, &c, c + 1u,
                                               memory_order_acq_rel,
                                               memory_order_acquire)) {
      continue;
    }
#if LE_CALLBACK_TELEMETRY
    const uint64_t t0 = tm != NULL ? le_now_ns() : 0u;
#endif
    le_fx_monitor_job(e, p->job_mon[next]);
#if LE_CALLBACK_TELEMETRY
    if (tm != NULL) {
      const uint64_t dt = le_now_ns() - t0;
      atomic_fetch_add_explicit(&tm->a_jobs, 1u, memory_order_relaxed);
      atomic_fetch_add_explicit(&tm->a_job_ns_total, dt, memory_order_relaxed);
      le_fx_max_u32(&tm->a_job_ns_max, dt);
    }
#else
    (void)tm;
#endif
    ++ran;
    atomic_fetch_add_explicit(&p->a_done, 1u, memory_order_release);
    c = atomic_load_explicit(&p->a_claim, memory_order_acquire);
  }
}

void le_fx_jobs_run(le_engine* e) {
  le_fx_par* p = &e->fx_par;
  const uint32_t jobs = (uint32_t)p->jobs;
  const int32_t workers = atomic_load_explicit(&p->a_workers,
                                               memory_order_relaxed);
  /* One job gains nothing from a worker: the callback would wait for it
   * instead of running it. */
  if (workers <= 0 || jobs < 2u) {
    for (uint32_t k = 0; k < jobs; ++k) le_fx_monitor_job(e, p->job_mon[k]);
    return;
  }
  /* The callback is the only writer of a_gen while it runs (the pool's start
   * and stop write it only while no callback can). */
  const uint32_t epoch =
      atomic_load_explicit(&p->a_gen, memory_order_relaxed) + 1u;
  atomic_store_explicit(&p->a_done, 0u, memory_order_relaxed);
  atomic_store_explicit(&p->a_claim, le_fx_claim_word(epoch, jobs, 0u),
                        memory_order_release);
#if LE_CALLBACK_TELEMETRY
  atomic_store_explicit(&p->a_wake_ns, le_now_ns(), memory_order_relaxed);
#endif
  atomic_store_explicit(&p->a_gen, epoch, memory_order_release);
  const uint32_t wake = jobs - 1u < (uint32_t)workers ? jobs - 1u
                                                      : (uint32_t)workers;
  le_platform_fx_wake(&p->a_gen, (int)wake);
  const uint32_t ran = le_fx_claim(e, epoch, NULL);
  /* The join: a spin, no syscall. Every job left is one a worker started. */
  le_fx_round_tm* rt = &e->fx_round_tm;
  if (atomic_load_explicit(&p->a_done, memory_order_acquire) < jobs) {
#if LE_CALLBACK_TELEMETRY
    const uint64_t t0 = le_now_ns();
#endif
    while (atomic_load_explicit(&p->a_done, memory_order_acquire) < jobs) {
      le_fx_cpu_relax();
    }
#if LE_CALLBACK_TELEMETRY
    const uint64_t dt = le_now_ns() - t0;
    atomic_fetch_add_explicit(&rt->a_join_waits, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&rt->a_join_ns_total, dt, memory_order_relaxed);
    le_fx_max_u32(&rt->a_join_ns_max, dt);
#endif
  }
  atomic_fetch_add_explicit(&rt->a_rounds, 1u, memory_order_relaxed);
  atomic_fetch_add_explicit(&rt->a_callback_jobs, ran, memory_order_relaxed);
}

static void le_fx_sleep_us(long us) {
  struct timespec ts = {us / 1000000, (us % 1000000) * 1000};
  nanosleep(&ts, NULL);
}

static void* le_fx_worker_main(void* arg) {
  le_fx_worker* w = (le_fx_worker*)arg;
  le_engine* e = w->e;
  le_fx_par* p = &e->fx_par;
  le_fx_worker_tm* tm = &e->fx_worker_tm[w->index];
  /* Named, so top -H, the profiler and the benches can tell the workers
   * apart (segno-fx-0 ..). */
  char name[16];
  snprintf(name, sizeof(name), "segno-fx-%d", (int)w->index);
#if defined(__APPLE__)
  (void)pthread_setname_np(name);
#else
  (void)pthread_setname_np(pthread_self(), name);
#endif
  if (!le_platform_fx_worker_setup(w->core, w->rt)) {
    atomic_store_explicit(&w->a_state, -1, memory_order_release);
    return NULL;
  }
  le_flush_denormals();
  uint32_t seen = atomic_load_explicit(&p->a_gen, memory_order_acquire);
  atomic_store_explicit(&w->a_state, 1, memory_order_release);
  for (;;) {
    const uint32_t g = atomic_load_explicit(&p->a_gen, memory_order_acquire);
    if (atomic_load_explicit(&p->a_quit, memory_order_acquire)) break;
    if (g == seen) {
      le_platform_fx_wait(&p->a_gen, seen);
      continue;
    }
    seen = g;
#if LE_CALLBACK_TELEMETRY
    {
      const uint64_t at =
          atomic_load_explicit(&p->a_wake_ns, memory_order_relaxed);
      const uint64_t now = le_now_ns();
      const uint64_t dt = now > at ? now - at : 0u;
      uint64_t b = dt / LE_FX_WAKE_BUCKET_NS;
      if (b >= LE_FX_WAKE_BUCKETS) b = LE_FX_WAKE_BUCKETS - 1;
      atomic_fetch_add_explicit(&tm->a_wakes, 1u, memory_order_relaxed);
      atomic_fetch_add_explicit(&tm->a_wake_ns_total, dt,
                                memory_order_relaxed);
      le_fx_max_u32(&tm->a_wake_ns_max, dt);
      atomic_fetch_add_explicit(&tm->a_wake_hist[b], 1u, memory_order_relaxed);
    }
#endif
    /* The test hook (le_engine_hold_fx_worker_for_test): a worker that does
     * not get to run. Never set outside the tests. */
    while (atomic_load_explicit(&tm->a_hold, memory_order_acquire) &&
           !atomic_load_explicit(&p->a_quit, memory_order_acquire)) {
      le_fx_sleep_us(100);
    }
    le_flush_denormals(); /* per thread; cheap to reassert at every wake */
    (void)le_fx_claim(e, g, tm);
  }
  return NULL;
}

static void le_fx_telemetry_reset(le_engine* e) {
  for (int k = 0; k < LE_FX_WORKERS_MAX; ++k) {
    le_fx_worker_tm* tm = &e->fx_worker_tm[k];
    atomic_store_explicit(&tm->a_wakes, 0u, memory_order_relaxed);
    atomic_store_explicit(&tm->a_wake_ns_total, 0u, memory_order_relaxed);
    atomic_store_explicit(&tm->a_wake_ns_max, 0u, memory_order_relaxed);
    for (int b = 0; b < LE_FX_WAKE_BUCKETS; ++b) {
      atomic_store_explicit(&tm->a_wake_hist[b], 0u, memory_order_relaxed);
    }
    atomic_store_explicit(&tm->a_jobs, 0u, memory_order_relaxed);
    atomic_store_explicit(&tm->a_job_ns_total, 0u, memory_order_relaxed);
    atomic_store_explicit(&tm->a_job_ns_max, 0u, memory_order_relaxed);
  }
  le_fx_round_tm* rt = &e->fx_round_tm;
  atomic_store_explicit(&rt->a_rounds, 0u, memory_order_relaxed);
  atomic_store_explicit(&rt->a_callback_jobs, 0u, memory_order_relaxed);
  atomic_store_explicit(&rt->a_join_waits, 0u, memory_order_relaxed);
  atomic_store_explicit(&rt->a_join_ns_total, 0u, memory_order_relaxed);
  atomic_store_explicit(&rt->a_join_ns_max, 0u, memory_order_relaxed);
}

/* Joins worker [w] if it was created, and frees its stack. */
static void le_fx_worker_release(le_fx_worker* w) {
  if (w->created) pthread_join(w->thread, NULL);
  w->created = 0;
  le_rt_free(w->stack_block);
  w->stack_block = NULL;
}

/* Creates worker [w] on a locked, fork-shielded stack (rt_alloc.h): a page
 * fault on an untouched stack page would take the mm lock (#710). Returns 0
 * when it could not be created. */
static int le_fx_worker_create(le_fx_worker* w) {
  const long ps = sysconf(_SC_PAGESIZE);
  const size_t page = ps > 0 ? (size_t)ps : 4096u;
  w->stack_block = le_rt_alloc_prefaulted(LE_FX_WORKER_STACK_BYTES + page);
  if (w->stack_block == NULL) return 0;
  const uintptr_t lo = ((uintptr_t)w->stack_block + page - 1u) &
                       ~(uintptr_t)(page - 1u);
  pthread_attr_t attr;
  if (pthread_attr_init(&attr) != 0) return 0;
  int ok = pthread_attr_setstack(&attr, (void*)lo, LE_FX_WORKER_STACK_BYTES) ==
           0;
  ok = ok && pthread_create(&w->thread, &attr, le_fx_worker_main, w) == 0;
  pthread_attr_destroy(&attr);
  w->created = ok;
  return ok;
}

void le_fx_pool_start(le_engine* e) {
  if (e->fx_pool != NULL) return;
  le_fx_par* p = &e->fx_par;
  le_fx_telemetry_reset(e);
  atomic_store_explicit(&p->a_workers, 0, memory_order_relaxed);
  atomic_store_explicit(&p->a_quit, 0, memory_order_relaxed);
  atomic_store_explicit(&p->a_claim, 0u, memory_order_relaxed);
  atomic_store_explicit(&p->a_done, 0u, memory_order_relaxed);
  const int32_t want = e->fx_workers_req;
  if (want <= 0) return;
  struct le_fx_pool* pool =
      (struct le_fx_pool*)calloc(1, sizeof(struct le_fx_pool));
  if (pool == NULL) return;
  const int rt = le_platform_rt_audio();
  for (int32_t k = 0; k < want; ++k) {
    le_fx_worker* w = &pool->w[k];
    w->e = e;
    w->index = k;
    w->core = e->fx_cores[1 + k];
    w->rt = rt;
    atomic_store_explicit(&w->a_state, 0, memory_order_relaxed);
    if (!le_fx_worker_create(w)) {
      atomic_store_explicit(&w->a_state, -1, memory_order_relaxed);
    }
  }
  /* Each worker says whether the kernel gave it its core and priority; that
   * takes microseconds, and two seconds is far past any healthy start. */
  int32_t running = 0;
  for (int32_t k = 0; k < want; ++k) {
    le_fx_worker* w = &pool->w[k];
    int32_t s = 0;
    for (int tries = 0; tries < 20000; ++tries) {
      s = atomic_load_explicit(&w->a_state, memory_order_acquire);
      if (s != 0) break;
      le_fx_sleep_us(100);
    }
    if (s == 1) {
      ++running;
    } else {
      fprintf(stderr,
              "segno/fx: effects worker %d not started (core %d%s); the "
              "engine runs %s\n",
              (int)k, (int)w->core,
              s == 0 ? ", no answer" : ", core or real-time priority refused",
              "with fewer workers");
      /* A worker that never answered is still waiting to; it sees the quit
       * at le_fx_pool_stop like the others. A refused one has returned. */
      if (s == -1) le_fx_worker_release(w);
    }
  }
  e->fx_pool = pool;
  atomic_store_explicit(&p->a_workers, running, memory_order_relaxed);
}

void le_fx_pool_stop(le_engine* e) {
  struct le_fx_pool* pool = e->fx_pool;
  if (pool == NULL) return;
  le_fx_par* p = &e->fx_par;
  atomic_store_explicit(&p->a_workers, 0, memory_order_relaxed);
  atomic_store_explicit(&p->a_quit, 1, memory_order_release);
  for (int k = 0; k < LE_FX_WORKERS_MAX; ++k) {
    atomic_store_explicit(&e->fx_worker_tm[k].a_hold, 0, memory_order_release);
  }
  atomic_fetch_add_explicit(&p->a_gen, 1u, memory_order_release);
  le_platform_fx_wake(&p->a_gen, LE_FX_WORKERS_MAX);
  for (int k = 0; k < LE_FX_WORKERS_MAX; ++k) {
    le_fx_worker_release(&pool->w[k]);
  }
  free(pool);
  e->fx_pool = NULL;
  atomic_store_explicit(&p->a_quit, 0, memory_order_relaxed);
}

int32_t le_engine_set_fx_workers(le_engine* engine, int32_t count,
                                 const int32_t* cores) {
  if (engine == NULL || count < 0 || count > LE_FX_WORKERS_MAX) {
    return LE_ERR_INVALID;
  }
  int32_t want[1 + LE_FX_WORKERS_MAX];
  for (int k = 0; k <= LE_FX_WORKERS_MAX; ++k) {
    want[k] = cores != NULL && k <= count ? cores[k] : -1;
    if (want[k] < -1 || want[k] > 1023) return LE_ERR_INVALID;
  }
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  if (count == engine->fx_workers_req &&
      memcmp(want, engine->fx_cores, sizeof(want)) == 0) {
    return LE_OK;
  }
  le_fx_pool_stop(engine);
  engine->fx_workers_req = count;
  memcpy(engine->fx_cores, want, sizeof(want));
  /* A configured engine (the device-free one the tests pump) starts them
   * now; otherwise the next configure or start does. */
  if (atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    le_fx_pool_start(engine);
  }
  return LE_OK;
}

void le_engine_get_fx_workers_telemetry(le_engine* engine,
                                        le_fx_workers_telemetry* out) {
  if (engine == NULL || out == NULL) return;
  memset(out, 0, sizeof(*out));
  out->requested = engine->fx_workers_req;
  out->running =
      atomic_load_explicit(&engine->fx_par.a_workers, memory_order_relaxed);
  const le_fx_round_tm* rt = &engine->fx_round_tm;
  out->rounds = atomic_load_explicit(&rt->a_rounds, memory_order_relaxed);
  out->callback_jobs =
      atomic_load_explicit(&rt->a_callback_jobs, memory_order_relaxed);
  out->join_waits = atomic_load_explicit(&rt->a_join_waits,
                                         memory_order_relaxed);
  const uint64_t join_total =
      atomic_load_explicit(&rt->a_join_ns_total, memory_order_relaxed);
  out->join_wait_mean_ns =
      out->join_waits > 0 ? (uint32_t)(join_total / out->join_waits) : 0u;
  out->join_wait_max_ns =
      atomic_load_explicit(&rt->a_join_ns_max, memory_order_relaxed);
  for (int k = 0; k < LE_FX_WORKERS_MAX; ++k) {
    const le_fx_worker_tm* tm = &engine->fx_worker_tm[k];
    le_fx_worker_snapshot* w = &out->worker[k];
    w->wakes = atomic_load_explicit(&tm->a_wakes, memory_order_relaxed);
    const uint64_t wake_total =
        atomic_load_explicit(&tm->a_wake_ns_total, memory_order_relaxed);
    w->wake_mean_ns = w->wakes > 0 ? (uint32_t)(wake_total / w->wakes) : 0u;
    w->wake_max_ns =
        atomic_load_explicit(&tm->a_wake_ns_max, memory_order_relaxed);
    for (int b = 0; b < LE_FX_WAKE_BUCKETS; ++b) {
      w->wake_buckets[b] =
          atomic_load_explicit(&tm->a_wake_hist[b], memory_order_relaxed);
    }
    w->jobs = atomic_load_explicit(&tm->a_jobs, memory_order_relaxed);
    w->job_total_ns =
        atomic_load_explicit(&tm->a_job_ns_total, memory_order_relaxed);
    w->job_mean_ns = w->jobs > 0 ? (uint32_t)(w->job_total_ns / w->jobs) : 0u;
    w->job_max_ns =
        atomic_load_explicit(&tm->a_job_ns_max, memory_order_relaxed);
  }
}

void le_engine_hold_fx_worker_for_test(le_engine* engine, int32_t worker,
                                       int hold) {
  if (engine == NULL || worker < 0 || worker >= LE_FX_WORKERS_MAX) return;
  atomic_store_explicit(&engine->fx_worker_tm[worker].a_hold, hold ? 1 : 0,
                        memory_order_release);
}
