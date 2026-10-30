/*
 * bench_fx_parallel.c — the multi-core effects spike (#1515).
 *
 * NOT part of the test gate. Build and run it with ./bench_fx_parallel.sh.
 *
 * QUESTION: if the audio callback hands effect chains to worker threads on
 * other cores, do N cores give close to N times the room for effects, with
 * no block over its budget?
 *
 * WHAT IT RUNS, once per period, paced to the period like a device:
 *   1. the callback thread wakes the workers (a futex wake, or nothing when
 *      they spin), then runs the engine's own work: the 8-track playing rig
 *      of bench_common.h, with no effects (the console's ~73 us base);
 *   2. it then releases the period's chain jobs, and it and the workers
 *      claim them one at a time from a shared index (work stealing) until
 *      none is left;
 *   3. it waits, spinning, until every job of the period is done.
 * A job is one effect chain run for one period exactly as the engine runs a
 * lane's chain: fx_apply_chain once per frame on the chain's own
 * le_fx_state, its FX clock set per frame the way the offline renders set
 * it (perf_render.c). The --engine-jobs option makes each job a whole
 * chain-host engine instead (the chain on a monitored input, through
 * le_engine_process), which adds the host engine's own per-block work.
 *
 * Chain i takes lane 0 of track i's hop-stagger seed (le_fx_lane_hop_seed),
 * so the hop work of K Ed's racks spreads over the hop the way it does live.
 *
 * Reported per scenario: the callback's service time per period (p50, p99,
 * p99.9, max), the periods over the budget share (80 %) and over the whole
 * period, the workers' wake latency (from the callback's wake to the worker
 * running), the CPU the callback and the workers used (CLOCK_THREAD_CPUTIME,
 * as a share of the whole machine: 100 % = every core busy),
 * and the minor page faults each thread took in the window.
 *
 *   ./bench_fx_parallel.sh --chains 4 --workers 2          # one scenario
 *   ./bench_fx_parallel.sh --sweep --seconds 20            # max chains per
 *                                                          # worker count
 *   bench_fx_parallel --cpu 3 --worker-cpus 2,1 --wait futex
 *
 * --wait futex (default): workers sleep on a private futex between periods.
 * --wait spin: workers spin on the period counter (a busy core each).
 * --hog-cpu N: a SCHED_OTHER thread copies 32 MB buffers on core N for the
 *   whole run, standing in for the UI's memory traffic.
 *
 * On the console, run it with segno.service stopped: the timed threads take
 * SCHED_FIFO BENCH_RT_PRIO (70) for the callback and 69 for the workers.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#if defined(__linux__)
#include <linux/futex.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#endif

#include "segno_engine_api.h"
#include "engine_fx.h" /* le_flush_denormals */
#include "bench_common.h"

#define MAX_WORKERS 3
#define MAX_JOBS 16
#define WORKER_RT_PRIO (BENCH_RT_PRIO - 1)
/* The share of each period the worst block may fill (fx_cost.dart). */
static const double kBudgetShare = 0.8;

enum { WAIT_FUTEX = 0, WAIT_SPIN = 1 };

static int g_wait = WAIT_FUTEX;
static int g_cpu = -1;                     /* the callback's core */
static int g_worker_cpu[MAX_WORKERS] = {-1, -1, -1};
static int g_hog_cpu = -1;

static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ __volatile__("yield" ::: "memory");
#elif defined(__x86_64__)
  __asm__ __volatile__("pause" ::: "memory");
#endif
}

static void pin_to(int cpu) {
#if defined(__linux__)
  if (cpu < 0) return;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#else
  (void)cpu;
#endif
}

static void fifo(int prio) {
#if defined(__linux__)
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = prio;
  pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
#else
  (void)prio;
#endif
}

static double thread_cpu_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

/* This thread's minor faults so far (/proc/self/task/<tid>/stat field 10). */
static long thread_minflt(void) {
#if defined(__linux__)
  char path[64];
  snprintf(path, sizeof(path), "/proc/self/task/%ld/stat",
           (long)syscall(SYS_gettid));
  FILE* f = fopen(path, "r");
  if (f == NULL) return -1;
  char buf[1024];
  const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = 0;
  const char* p = strrchr(buf, ')');
  if (p == NULL) return -1;
  long v = -1;
  /* after ")": state(3) ppid pgrp session tty tpgid flags minflt(10) */
  sscanf(p + 2, "%*c %*d %*d %*d %*d %*d %*u %ld", &v);
  return v;
#else
  return 0;
#endif
}

/* ---------------- the futex word and the claim word ---------------- */

/* Bumped once per period: what a sleeping worker waits on. */
static _Atomic uint32_t g_gen;
/* (epoch << 32) | next job index. Published only once the period's jobs are
 * released, so a worker can never claim a job of an epoch before its inputs
 * exist, nor one of a later epoch with a stale index. */
static _Atomic uint64_t g_claim;
static _Atomic int32_t g_done;
static _Atomic int g_quit;
static _Atomic uint64_t g_wake_ns; /* when the callback woke the workers */

static int g_jobs;

static void futex_wait_gen(uint32_t seen) {
#if defined(__linux__)
  syscall(SYS_futex, &g_gen, FUTEX_WAIT_PRIVATE, seen, NULL, NULL, 0);
#else
  (void)seen;
  sched_yield();
#endif
}

static void futex_wake_all(void) {
#if defined(__linux__)
  syscall(SYS_futex, &g_gen, FUTEX_WAKE_PRIVATE, MAX_WORKERS, NULL, NULL, 0);
#endif
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---------------- chain jobs ---------------- */

typedef struct {
  /* --engine-jobs: a chain-host engine */
  le_engine* e;
  float* in;
  float* out;
  /* otherwise: the chain on its own state */
  le_fx_state* fx;
  le_fx_tempo tempo;
  int32_t count;
  int32_t type[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t enabled[LE_FX_MAX];
  uint32_t clock;
  int32_t offset; /* where in the source this job reads */
  volatile float sink;
} host;

static host g_host[MAX_JOBS];
static const float* g_src;
static int32_t g_src_frames;
static int32_t g_period;
static int32_t g_rate;
static int g_engine_jobs;

/* Ed's rack in its chain order (bench_fx_cpu's --racks), each kind at the
 * heavy settings that bench uses. */
static void eds_rack(le_fx_recipe* r) {
  static const int32_t kinds[] = {LE_FX_DUAL_OCTAVER, LE_FX_WAH,
                                  LE_FX_COMPRESSOR,   LE_FX_OVERDRIVE,
                                  LE_FX_AMP_CAB,      LE_FX_CHORUS,
                                  LE_FX_ROOM_VERB,    LE_FX_MODE_DELAY,
                                  LE_FX_EQ};
  memset(r, 0, sizeof(*r));
  r->enabled = 1;
  r->count = (int32_t)(sizeof(kinds) / sizeof(kinds[0]));
  for (int s = 0; s < r->count; ++s) {
    const int32_t k = kinds[s];
    r->type[s] = k;
    r->slot_enabled[s] = 1;
    r->level[s] = 1.0f;
    le_fx_defaults(k, r->params[s]);
    if (k == LE_FX_DUAL_OCTAVER) {
      r->params[s][3] = 0.6f; /* Octave 2 at 60 % */
    } else if (k == LE_FX_COMPRESSOR) {
      r->params[s][0] = 0.5f;
      r->params[s][4] = 0.3f;
    } else if (k == LE_FX_AMP_CAB) {
      r->params[s][0] = 0.935f; /* Full Drive Power, the 4x12" */
      r->params[s][4] = 7.0f / 11.0f;
    } else if (k == LE_FX_ROOM_VERB) {
      r->params[s][2] = 3.0f / 15.0f; /* BOX: the most early taps */
    } else if (k == LE_FX_MODE_DELAY) {
      r->params[s][0] = 9.0f / 19.0f;
      r->params[s][3] = 7.0f / 13.0f; /* RES LO L/R: both taps voiced */
    } else if (k == LE_FX_EQ) {
      r->params[s][0] = 0.3f;
      r->params[s][1] = 0.6f;
      r->params[s][4] = 0.4f;
      r->params[s][7] = 0.65f;
      r->params[s][10] = 0.45f;
      r->params[s][13] = 0.8f;
      r->params[s][14] = 0.5f;
    }
  }
}

/* A harmonic bass line (bench_fx_cpu's), so the Dual Octaver's low band
 * works. */
static float* make_bass(int32_t frames, int32_t sr) {
  float* s = (float*)calloc((size_t)frames, sizeof(float));
  if (s == NULL) return NULL;
  static const double notes[4] = {82.41, 110.0, 146.83, 98.0};
  const int32_t len = sr / 4;
  double ph = 0.0;
  for (int32_t i = 0; i < frames; ++i) {
    ph += 2.0 * M_PI * notes[(i / len) % 4] / sr;
    double x = 0.0;
    for (int k = 1; k <= 10; ++k) x += sin(k * ph) / k;
    s[i] = (float)(0.14 * x);
  }
  return s;
}

static int host_create(host* h, const bench_opts* o, int index) {
  memset(h, 0, sizeof(*h));
  h->offset = (index * 7919) % g_src_frames;
  le_fx_recipe rec;
  eds_rack(&rec);
  if (g_engine_jobs) {
    h->e = le_engine_create();
    if (h->e == NULL) return 0;
    if (le_engine_configure(h->e, o->rate, 2, 2, o->rate) != LE_OK) return 0;
    if (le_engine_set_monitor_input(h->e, 0, 1) != LE_OK ||
        le_engine_set_monitor_input_output(h->e, 0, 0x3) != LE_OK ||
        le_engine_set_fx_recipe(h->e, LE_FX_OWNER_MONITOR, 0, 0, 1, &rec) !=
            LE_OK) {
      return 0;
    }
    h->in = (float*)calloc((size_t)o->period * 2, sizeof(float));
    h->out = (float*)calloc((size_t)o->period * 2, sizeof(float));
    if (h->in == NULL || h->out == NULL) return 0;
    for (int q = 0; q < (index & 3); ++q) {
      le_engine_process(h->e, h->out, h->in, 64u); /* its own hop quarter */
    }
    for (int k = 0; k < 400; ++k) {
      le_engine_process(h->e, h->out, h->in, (uint32_t)o->period);
    }
    return 1;
  }
  /* The offline renders' set-up (perf_render.c): a zeroed state, the live
   * owner's hop seed, a clock set every frame, the slots settled on and
   * prepared on this (the control) thread. */
  h->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (h->fx == NULL) return 0;
  h->fx->hop_seed = le_fx_lane_hop_seed(index, 0);
  h->fx->clocked = 1;
  h->tempo.qpf = (float)(120.0 / 60.0 / o->rate);
  h->tempo.num = 4;
  h->tempo.den = 4;
  h->fx->tempo = &h->tempo;
  h->count = rec.count;
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_at(h->fx, s, 1);
  for (int s = 0; s < rec.count; ++s) {
    h->type[s] = rec.type[s];
    h->enabled[s] = 1;
    memcpy(h->params[s], rec.params[s], sizeof(h->params[s]));
    le_fx_entry_reset(h->fx, s);
    if (le_fx_prepare(h->fx, s, rec.type[s], o->rate) != LE_OK) return 0;
  }
  for (int k = 0; k < 400; ++k) {
    /* warm-up on the control thread, before mlockall */
    for (int32_t f = 0; f < o->period; ++f) {
      float l = g_src[(h->offset + k * o->period + f) % g_src_frames];
      float r = l;
      h->fx->clock = h->clock + (uint32_t)f;
      fx_apply_chain(h->fx, o->rate, o->rate, &l, &r, h->count, h->type,
                     (const float(*)[LE_FX_PARAMS])h->params, h->enabled);
    }
    h->clock += (uint32_t)o->period;
  }
  return 1;
}

static void host_destroy(host* h) {
  if (h->e) le_engine_destroy(h->e);
  if (h->fx) {
    le_fx_state_free_buffers(h->fx);
    free(h->fx);
  }
  free(h->in);
  free(h->out);
}

/* One job: this period of chain [i] on its slice of the source. */
static void run_job(int i, uint64_t period_index) {
  host* h = &g_host[i];
  const int32_t base =
      (int32_t)((h->offset + (int64_t)period_index * g_period) %
                (g_src_frames - g_period));
  if (h->e != NULL) {
    for (int32_t f = 0; f < g_period; ++f) {
      h->in[2 * f] = g_src[base + f];
      h->in[2 * f + 1] = g_src[base + f];
    }
    le_engine_process(h->e, h->out, h->in, (uint32_t)g_period);
    return;
  }
  float acc = 0.0f;
  for (int32_t f = 0; f < g_period; ++f) {
    float l = g_src[base + f];
    float r = l;
    h->fx->clock = h->clock + (uint32_t)f;
    fx_apply_chain(h->fx, g_rate, g_rate, &l, &r, h->count, h->type,
                   (const float(*)[LE_FX_PARAMS])h->params, h->enabled);
    acc += l + r;
  }
  h->clock += (uint32_t)g_period;
  h->sink = acc;
}

/* Claims and runs jobs of [epoch] until none is left. */
static _Atomic uint64_t g_period_index;
static void claim_jobs(uint32_t epoch) {
  const uint64_t pi = atomic_load_explicit(&g_period_index,
                                           memory_order_relaxed);
  uint64_t c = atomic_load_explicit(&g_claim, memory_order_acquire);
  for (;;) {
    if ((uint32_t)(c >> 32) != epoch) return;
    const uint32_t idx = (uint32_t)c;
    if (idx >= (uint32_t)g_jobs) return;
    if (atomic_compare_exchange_weak_explicit(&g_claim, &c, c + 1,
                                              memory_order_acq_rel,
                                              memory_order_acquire)) {
      run_job((int)idx, pi);
      atomic_fetch_add_explicit(&g_done, 1, memory_order_release);
      c = atomic_load_explicit(&g_claim, memory_order_acquire);
    }
  }
}

/* ---------------- workers ---------------- */

typedef struct {
  int index;
  pthread_t thread;
  double* wake_us; /* per period */
  size_t periods;
  _Atomic size_t n;
  double cpu_us0, cpu_us1;
  long flt0, flt1;
  _Atomic int mark; /* 1: sample start, 2: sample end */
} worker;

static worker g_worker[MAX_WORKERS];
static int g_workers;

static void* worker_main(void* arg) {
  worker* w = (worker*)arg;
  pin_to(g_worker_cpu[w->index]);
  fifo(WORKER_RT_PRIO);
  le_flush_denormals();
  uint32_t seen = atomic_load_explicit(&g_gen, memory_order_acquire);
  for (;;) {
    uint32_t g;
    while ((g = atomic_load_explicit(&g_gen, memory_order_acquire)) == seen &&
           !atomic_load_explicit(&g_quit, memory_order_relaxed)) {
      if (g_wait == WAIT_SPIN) {
        cpu_relax();
      } else {
        futex_wait_gen(seen);
      }
    }
    if (atomic_load_explicit(&g_quit, memory_order_relaxed)) break;
    seen = g;
    const uint64_t woke = now_ns();
    const uint64_t at = atomic_load_explicit(&g_wake_ns, memory_order_relaxed);
    const size_t n = atomic_load_explicit(&w->n, memory_order_relaxed);
    if (n < w->periods) {
      w->wake_us[n] = woke > at ? (double)(woke - at) / 1e3 : 0.0;
      atomic_store_explicit(&w->n, n + 1, memory_order_relaxed);
    }
    const int m = atomic_exchange_explicit(&w->mark, 0, memory_order_relaxed);
    if (m == 1) {
      w->cpu_us0 = thread_cpu_us();
      w->flt0 = thread_minflt();
    } else if (m == 2) {
      w->cpu_us1 = thread_cpu_us();
      w->flt1 = thread_minflt();
    }
    /* Wait for this epoch's release (the callback is doing the engine's own
     * work), then steal jobs. */
    while ((uint32_t)(atomic_load_explicit(&g_claim, memory_order_acquire) >>
                      32) != g &&
           atomic_load_explicit(&g_gen, memory_order_acquire) == g &&
           !atomic_load_explicit(&g_quit, memory_order_relaxed)) {
      cpu_relax();
    }
    claim_jobs(g);
  }
  return NULL;
}

/* ---------------- the memory-traffic hog ---------------- */

static void* hog_main(void* arg) {
  (void)arg;
  pin_to(g_hog_cpu);
  const size_t n = 32u << 20;
  char* a = (char*)malloc(n);
  char* b = (char*)malloc(n);
  if (a == NULL || b == NULL) return NULL;
  memset(a, 1, n);
  while (!atomic_load_explicit(&g_quit, memory_order_relaxed)) {
    memcpy(b, a, n);
    memcpy(a, b, n);
  }
  free(a);
  free(b);
  return NULL;
}

static int ncpus(void) {
  const long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int)n : 1;
}

/* ---------------- one scenario ---------------- */

typedef struct {
  stats service;
  size_t over_budget, late;
  double wake_p99, wake_max; /* over every worker */
  double cb_pct, worker_pct; /* whole-machine %: 100 % = every core */
  long faults;
  double timer_late_max; /* the callback's own wake past its period start */
} result;

static int run_scenario(const bench_opts* o, rig* r, int jobs, int workers,
                        double seconds, result* out) {
  g_jobs = jobs;
  g_workers = workers;
  const size_t periods = (size_t)(seconds * o->rate / o->period);
  const size_t warm = (size_t)(0.5 * o->rate / o->period);
  double* svc = (double*)malloc(sizeof(double) * periods);
  if (svc == NULL) return 0;
  atomic_store(&g_quit, 0);
  atomic_store(&g_gen, 0);
  atomic_store(&g_claim, 0);
  for (int w = 0; w < workers; ++w) {
    worker* wk = &g_worker[w];
    memset(wk, 0, sizeof(*wk));
    wk->index = w;
    wk->periods = periods + warm + 8;
    wk->wake_us = (double*)calloc(wk->periods, sizeof(double));
    if (wk->wake_us == NULL) return 0;
    if (pthread_create(&wk->thread, NULL, worker_main, wk) != 0) return 0;
  }
  pin_to(g_cpu);
  fifo(BENCH_RT_PRIO);
  le_flush_denormals();
  const double period_us = 1e6 * o->period / o->rate;
  double next = now_us() + 2 * period_us;
  double cpu0 = 0, cpu1 = 0;
  long flt0 = 0, flt1 = 0;
  double t_win0 = 0, t_win1 = 0;
  double timer_late_max = 0;
  size_t over_budget = 0, late = 0, ns = 0;
  for (size_t k = 0; k < periods + warm; ++k) {
    sleep_until_us(next);
    const double t0 = now_us();
    if (k >= warm && t0 - next > timer_late_max) timer_late_max = t0 - next;
    next += period_us;
    if (k == warm) {
      for (int w = 0; w < workers; ++w) atomic_store(&g_worker[w].mark, 1);
      cpu0 = thread_cpu_us();
      flt0 = thread_minflt();
      t_win0 = t0;
    } else if (k == periods + warm - 1) {
      for (int w = 0; w < workers; ++w) atomic_store(&g_worker[w].mark, 2);
    }
    /* 1. wake the workers, then the engine's own work */
    atomic_store_explicit(&g_done, 0, memory_order_relaxed);
    atomic_store_explicit(&g_period_index, (uint64_t)k, memory_order_relaxed);
    atomic_store_explicit(&g_wake_ns, now_ns(), memory_order_relaxed);
    const uint32_t epoch =
        atomic_fetch_add_explicit(&g_gen, 1, memory_order_acq_rel) + 1u;
    if (g_wait == WAIT_FUTEX && workers > 0) futex_wake_all();
    le_engine_process(r->e, r->out, r->in, (uint32_t)o->period);
    /* 2. release the jobs and steal */
    atomic_store_explicit(&g_claim, (uint64_t)epoch << 32,
                          memory_order_release);
    claim_jobs(epoch);
    /* 3. join */
    while (atomic_load_explicit(&g_done, memory_order_acquire) < jobs) {
      cpu_relax();
    }
    const double t1 = now_us();
    if (k >= warm) {
      const double s = t1 - t0;
      svc[ns++] = s;
      if (s > period_us * kBudgetShare) over_budget++;
      if (s > period_us) late++;
    }
  }
  cpu1 = thread_cpu_us();
  flt1 = thread_minflt();
  t_win1 = now_us();
  rt_leave();
  /* one more period so every worker samples its end mark, then quit */
  sleep_until_us(now_us() + 2 * period_us);
  atomic_store(&g_quit, 1);
  atomic_fetch_add(&g_gen, 1);
  futex_wake_all();
  for (int w = 0; w < workers; ++w) pthread_join(g_worker[w].thread, NULL);

  memset(out, 0, sizeof(*out));
  g_budget_us = period_us * kBudgetShare;
  out->service = stats_of(svc, ns);
  out->over_budget = over_budget;
  out->late = late;
  out->timer_late_max = timer_late_max;
  const double wall = t_win1 - t_win0;
  const int cpus = ncpus();
  out->cb_pct = 100.0 * (cpu1 - cpu0) / (wall * cpus);
  out->faults = flt1 - flt0;
  double wsum = 0;
  double* all = (double*)malloc(sizeof(double) * (periods + warm + 8) *
                                (size_t)(workers > 0 ? workers : 1));
  size_t na = 0;
  for (int w = 0; w < workers; ++w) {
    worker* wk = &g_worker[w];
    wsum += wk->cpu_us1 - wk->cpu_us0;
    out->faults += wk->flt1 - wk->flt0;
    const size_t n = atomic_load(&wk->n);
    for (size_t i = warm < n ? warm : n; i < n; ++i) all[na++] = wk->wake_us[i];
    free(wk->wake_us);
  }
  out->worker_pct = 100.0 * wsum / (wall * cpus);
  if (na > 0) {
    const stats ws = stats_of(all, na);
    out->wake_p99 = ws.p99;
    out->wake_max = ws.max;
  }
  free(all);
  free(svc);
  return 1;
}

static void print_result_header(void) {
  printf("| chains | workers | wait  |  p50 us |  p99 us | p99.9 us |  max us "
         "| over 80%% | late | wake p99 us | wake max us | cb %% | workers %% "
         "| faults |\n");
  printf("|--------|---------|-------|---------|---------|----------|---------"
         "|----------|------|-------------|-------------|------|-----------"
         "|--------|\n");
}

static void print_result(int jobs, int workers, const result* r) {
  printf("| %6d | %7d | %-5s | %7.1f | %7.1f | %8.1f | %7.1f | %8zu | %4zu "
         "| %11.1f | %11.1f | %4.1f | %9.1f | %6ld |\n",
         jobs, workers, g_wait == WAIT_SPIN ? "spin" : "futex", r->service.p50,
         r->service.p99, r->service.p999, r->service.max, r->over_budget,
         r->late, r->wake_p99, r->wake_max, r->cb_pct, r->worker_pct,
         r->faults);
  fflush(stdout);
}

static void parse_cpus(const char* s, int* out, int n) {
  for (int i = 0; i < n; ++i) out[i] = -1;
  int i = 0;
  while (*s && i < n) {
    out[i++] = (int)strtol(s, (char**)&s, 10);
    if (*s == ',') ++s;
  }
}

int main(int argc, char** argv) {
  bench_opts o;
  memset(&o, 0, sizeof(o));
  o.rate = 96000;
  o.period = 64;
  o.loop_seconds = 4.0;
  int chains = 4, workers = 2, sweep = 0, max_chains = 12;
  double seconds = 10.0;
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    const char* v = i + 1 < argc ? argv[i + 1] : "";
    if (!strcmp(a, "--rate")) { o.rate = atoi(v); ++i; }
    else if (!strcmp(a, "--period")) { o.period = atoi(v); ++i; }
    else if (!strcmp(a, "--seconds")) { seconds = atof(v); ++i; }
    else if (!strcmp(a, "--chains")) { chains = atoi(v); ++i; }
    else if (!strcmp(a, "--max-chains")) { max_chains = atoi(v); ++i; }
    else if (!strcmp(a, "--workers")) { workers = atoi(v); ++i; }
    else if (!strcmp(a, "--cpu")) { g_cpu = atoi(v); ++i; }
    else if (!strcmp(a, "--worker-cpus")) {
      parse_cpus(v, g_worker_cpu, MAX_WORKERS);
      ++i;
    } else if (!strcmp(a, "--hog-cpu")) { g_hog_cpu = atoi(v); ++i; }
    else if (!strcmp(a, "--wait")) {
      g_wait = !strcmp(v, "spin") ? WAIT_SPIN : WAIT_FUTEX;
      ++i;
    } else if (!strcmp(a, "--sweep")) { sweep = 1; }
    else if (!strcmp(a, "--engine-jobs")) { g_engine_jobs = 1; }
    else if (!strcmp(a, "--smoke")) { seconds = 0.5; max_chains = 3; }
    else {
      fprintf(stderr, "unknown option %s\n", a);
      return 2;
    }
  }
  if (workers < 0 || workers > MAX_WORKERS || chains < 0 ||
      chains > MAX_JOBS || max_chains > MAX_JOBS) {
    fprintf(stderr, "workers 0..%d, chains 0..%d\n", MAX_WORKERS, MAX_JOBS);
    return 2;
  }
  detect_cpu();
  const int32_t frames = (int32_t)(o.loop_seconds * o.rate);
  float* src = make_source(frames, o.rate);
  float* bass = make_bass(frames, o.rate);
  if (src == NULL || bass == NULL) return 3;
  g_src = bass;
  g_src_frames = frames;
  g_period = o.period;
  g_rate = o.rate;

  rig r;
  if (!rig_create(&r, &o, 1, src, frames)) {
    fprintf(stderr, "the 8-track rig refused\n");
    return 3;
  }
  const int hosts = sweep ? max_chains : chains;
  for (int i = 0; i < hosts; ++i) {
    if (!host_create(&g_host[i], &o, i)) {
      fprintf(stderr, "chain host %d refused\n", i);
      return 3;
    }
  }
#if defined(__linux__)
  /* What the engine does for its audio memory (#900), process-wide here: no
   * page the timed threads touch may fault. */
  if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
    fprintf(stderr, "mlockall failed (%s); faults may show\n",
            strerror(errno));
  }
#endif
  pthread_t hog;
  if (g_hog_cpu >= 0) pthread_create(&hog, NULL, hog_main, NULL);

  const double period_us = 1e6 * o.period / o.rate;
  printf("bench_fx_parallel: %s, %d CPUs, %d Hz, %d-frame periods (period "
         "%.1f us, budget %.1f us), chain = %s, callback cpu %d, worker cpus "
         "%d,%d,%d%s\n",
         g_cpu_name, ncpus(), o.rate, o.period, period_us,
         period_us * kBudgetShare,
         g_engine_jobs ? "Ed's rack on a chain-host engine"
                       : "Ed's rack (9 kinds)", g_cpu,
         g_worker_cpu[0], g_worker_cpu[1], g_worker_cpu[2],
         g_hog_cpu >= 0 ? ", memory hog on" : "");
  if (g_hog_cpu >= 0) printf("memory hog on cpu %d\n", g_hog_cpu);
  print_result_header();
  int rc = 0;
  if (!sweep) {
    result res;
    if (!run_scenario(&o, &r, chains, workers, seconds, &res)) rc = 1;
    else print_result(chains, workers, &res);
  } else {
    /* For each worker count, add chains until a period goes over the budget
     * share; the last count with none over is that many cores' room. */
    for (int w = 0; w <= MAX_WORKERS; ++w) {
      if (w > 0 && g_worker_cpu[w - 1] < 0 && g_cpu >= 0) break;
      int best = 0;
      for (int k = 1; k <= max_chains; ++k) {
        result res;
        if (!run_scenario(&o, &r, k, w, seconds, &res)) {
          rc = 1;
          break;
        }
        print_result(k, w, &res);
        if (res.over_budget > 0) break;
        best = k;
      }
      printf("room: %d worker(s) + the callback fit %d Ed's racks with no "
             "period over the budget\n",
             w, best);
    }
  }
  printf("timed threads: callback SCHED_FIFO %d, workers SCHED_FIFO %d "
         "(Linux only)\n",
         BENCH_RT_PRIO, WORKER_RT_PRIO);
  atomic_store(&g_quit, 1);
  if (g_hog_cpu >= 0) pthread_join(hog, NULL);
  for (int i = 0; i < hosts; ++i) host_destroy(&g_host[i]);
  rig_destroy(&r);
  free(src);
  free(bass);
  return rc;
}
