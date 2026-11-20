/*
 * engine_prof.h — where the audio callback's time goes, section by section
 * (#1914). A measuring build only: -DLE_PROFILE_SECTIONS=1 compiles it in;
 * by default every macro here is empty and the callback is unchanged.
 *
 * The callback thread stamps the monotonic clock at fixed points of a period
 * (the command drain, the snapshots, the first frame loop, the effects round
 * and its join, the second frame loop, the meters, the tail) and, around
 * le_engine_process, its own CPU clock, which separates the CPU it spends in
 * alsa-lib and miniaudio between two callbacks from the time it sleeps. Each
 * callback adds one count to a 1 us histogram per section, and a callback
 * whose service passes `tail_ns` copies its whole record into a ring. The
 * effects jobs add one count per job (on the callback and on the workers)
 * and the workers one per wake, so a job slowed by a cold cache shows as the
 * same job taking longer.
 *
 * Nothing reads it in the engine: a reader outside the process finds the
 * `le_prof_state` symbol and reads /proc/<pid>/mem (tool/proftel.py), so a
 * running app and the bench are measured the same way, with no tracing.
 *
 * Writers: the callback thread for everything but the per-job and wake
 * histograms, which the workers also add to (relaxed atomic adds). Readers
 * tolerate a torn view. One state per process, so it profiles one engine's
 * callback: the app's and each bench's. A process running two engines'
 * callbacks at once (some native tests) mixes their sections.
 */
#ifndef SEGNO_ENGINE_PROF_H
#define SEGNO_ENGINE_PROF_H

#ifndef LE_PROFILE_SECTIONS
#define LE_PROFILE_SECTIONS 0
#endif

#if LE_PROFILE_SECTIONS

#include <stdatomic.h>
#include <stdint.h>
#include <sys/resource.h>
#include <time.h>

#include "engine_telemetry.h" /* le_now_ns */

/* Per callback, in the order they run. */
enum {
  LE_PROF_CMD,       /* commands, heads, instruments, MIDI, dub update */
  LE_PROF_SETUP,     /* clip detection, every snapshot, the heard begin */
  LE_PROF_LOOP1,     /* the first frame loop: inputs, tracks, click */
  LE_PROF_JOBS_CB,   /* the effects jobs the callback ran itself */
  LE_PROF_JOIN,      /* spinning for the workers' jobs */
  LE_PROF_POSTJOBS,  /* the track jobs' sum and the heard end */
  LE_PROF_LOOP2,     /* the second frame loop: monitors, buses, master */
  LE_PROF_METERS,    /* meters, tuner tap, the tracks' published state */
  LE_PROF_TAIL,      /* perf tap, MIDI clock, revisions */
  LE_PROF_PROCESS,   /* the whole of le_engine_process */
  LE_PROF_OUT_WALL,  /* previous callback's exit to this one's entry */
  LE_PROF_OUT_CPU,   /* the CPU of that: alsa-lib, miniaudio, the kernel */
  LE_PROF_IN_CPU,    /* the CPU of le_engine_process */
  LE_PROF_SERVICE,   /* OUT_CPU + PROCESS: what a period costs the thread */
  /* Counts, not times (a histogram bin per count): the callback thread's
   * page faults and involuntary context switches, inside le_engine_process
   * and between two callbacks (getrusage, RUSAGE_THREAD). */
  LE_PROF_IN_FLT,
  LE_PROF_OUT_FLT,
  LE_PROF_IN_IVCSW,
  LE_PROF_OUT_IVCSW,
  LE_PROF_PER_CALL,  /* sections above are per callback, below per event */
  LE_PROF_CB_JOB = LE_PROF_PER_CALL, /* one job on the callback */
  LE_PROF_WK_JOB,    /* one job on a worker */
  LE_PROF_WK_WAKE,   /* a worker's wake, from the callback's futex wake */
  LE_PROF_N
};

#define LE_PROF_BINS 4096 /* 1 us each; the last one holds everything past */
#define LE_PROF_TAIL_N 32768
#define LE_PROF_MAGIC 0x31393134u /* "1914" */

typedef struct le_prof_rec {
  uint64_t at_ns; /* entry, monotonic */
  uint32_t frames;
  uint32_t ns[LE_PROF_PER_CALL];
} le_prof_rec;

typedef struct le_prof {
  uint32_t magic;
  uint32_t sections;  /* LE_PROF_N */
  uint32_t bins;      /* LE_PROF_BINS */
  uint32_t tail_cap;  /* LE_PROF_TAIL_N */
  uint64_t tail_ns;   /* a callback whose SERVICE passes this is copied */
  _Atomic uint64_t a_calls;
  _Atomic uint64_t a_tail_n; /* records written, ever; the ring wraps */
  /* The callback thread's in-flight state. */
  uint64_t last_ns;
  uint64_t prev_exit_ns;
  uint64_t prev_exit_cpu;
  uint64_t entry_ns;
  uint64_t entry_cpu;
  uint64_t prev_exit_flt;
  uint64_t prev_exit_ivcsw;
  uint64_t entry_flt;
  uint64_t entry_ivcsw;
  uint32_t acc[LE_PROF_PER_CALL];
  _Atomic uint32_t hist[LE_PROF_N][LE_PROF_BINS];
  le_prof_rec tail[LE_PROF_TAIL_N];
  /* The octaver family's pairs (engine_fx.c, le_oct_run_pair): samples run
   * on both channels, on the left alone, and each try's outcome (0 the
   * channels were equal, then the first part that differed). */
  _Atomic uint64_t a_oct_stereo;
  _Atomic uint64_t a_oct_mono;
  _Atomic uint64_t a_oct_try[8];
  _Atomic uint64_t a_oct_left; /* mono runs a stereo sample ended */
} le_prof;

extern le_prof le_prof_state;

static inline uint64_t le_prof_cpu_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* The thread's page faults (minor and major) and involuntary switches. */
static inline void le_prof_usage(uint64_t* flt, uint64_t* ivcsw) {
#if defined(__linux__)
  struct rusage ru;
  getrusage(1 /* RUSAGE_THREAD, which needs _GNU_SOURCE */, &ru);
  *flt = (uint64_t)ru.ru_minflt + (uint64_t)ru.ru_majflt;
  *ivcsw = (uint64_t)ru.ru_nivcsw;
#else
  *flt = 0u;
  *ivcsw = 0u;
#endif
}

static inline void le_prof_count_n(int k, uint64_t n) {
  if (n >= LE_PROF_BINS) n = LE_PROF_BINS - 1;
  atomic_fetch_add_explicit(&le_prof_state.hist[k][n], 1u,
                            memory_order_relaxed);
}

static inline void le_prof_count(int k, uint64_t ns) {
  uint64_t b = ns / 1000u;
  if (b >= LE_PROF_BINS) b = LE_PROF_BINS - 1;
  atomic_fetch_add_explicit(&le_prof_state.hist[k][b], 1u,
                            memory_order_relaxed);
}

/* Callback thread: a section ends here. */
static inline void le_prof_mark(int k) {
  le_prof* p = &le_prof_state;
  const uint64_t now = le_now_ns();
  p->acc[k] += (uint32_t)(now - p->last_ns);
  p->last_ns = now;
}

static inline void le_prof_begin(uint64_t entry_ns) {
  le_prof* p = &le_prof_state;
  if (p->magic != LE_PROF_MAGIC) {
    p->magic = LE_PROF_MAGIC;
    p->sections = LE_PROF_N;
    p->bins = LE_PROF_BINS;
    p->tail_cap = LE_PROF_TAIL_N;
    p->tail_ns = 500000u;
  }
  le_prof_usage(&p->entry_flt, &p->entry_ivcsw);
  p->entry_cpu = le_prof_cpu_ns();
  p->entry_ns = entry_ns;
  p->last_ns = entry_ns;
  for (int k = 0; k < LE_PROF_PER_CALL; ++k) p->acc[k] = 0u;
}

static inline void le_prof_end(uint64_t exit_ns, uint32_t frames) {
  le_prof* p = &le_prof_state;
  const uint64_t cpu = le_prof_cpu_ns();
  uint64_t flt, ivcsw;
  le_prof_usage(&flt, &ivcsw);
  p->acc[LE_PROF_IN_FLT] = (uint32_t)(flt - p->entry_flt);
  p->acc[LE_PROF_IN_IVCSW] = (uint32_t)(ivcsw - p->entry_ivcsw);
  p->acc[LE_PROF_TAIL] += (uint32_t)(exit_ns - p->last_ns);
  p->acc[LE_PROF_PROCESS] = (uint32_t)(exit_ns - p->entry_ns);
  p->acc[LE_PROF_IN_CPU] = (uint32_t)(cpu - p->entry_cpu);
  if (p->prev_exit_ns != 0u) {
    p->acc[LE_PROF_OUT_WALL] = (uint32_t)(p->entry_ns - p->prev_exit_ns);
    p->acc[LE_PROF_OUT_CPU] = (uint32_t)(p->entry_cpu - p->prev_exit_cpu);
    p->acc[LE_PROF_OUT_FLT] = (uint32_t)(p->entry_flt - p->prev_exit_flt);
    p->acc[LE_PROF_OUT_IVCSW] =
        (uint32_t)(p->entry_ivcsw - p->prev_exit_ivcsw);
  }
  p->acc[LE_PROF_SERVICE] =
      p->acc[LE_PROF_OUT_CPU] + p->acc[LE_PROF_PROCESS];
  p->prev_exit_ns = exit_ns;
  p->prev_exit_cpu = cpu;
  p->prev_exit_flt = flt;
  p->prev_exit_ivcsw = ivcsw;
  for (int k = 0; k < LE_PROF_IN_FLT; ++k) le_prof_count(k, p->acc[k]);
  for (int k = LE_PROF_IN_FLT; k < LE_PROF_PER_CALL; ++k) {
    le_prof_count_n(k, p->acc[k]);
  }
  if (p->acc[LE_PROF_SERVICE] >= p->tail_ns) {
    const uint64_t n =
        atomic_load_explicit(&p->a_tail_n, memory_order_relaxed);
    le_prof_rec* r = &p->tail[n % LE_PROF_TAIL_N];
    r->at_ns = p->entry_ns;
    r->frames = frames;
    for (int k = 0; k < LE_PROF_PER_CALL; ++k) r->ns[k] = p->acc[k];
    atomic_store_explicit(&p->a_tail_n, n + 1u, memory_order_release);
  }
  atomic_fetch_add_explicit(&p->a_calls, 1u, memory_order_relaxed);
}

#define LE_PROF_OCT(field) \
  atomic_fetch_add_explicit(&le_prof_state.field, 1u, memory_order_relaxed)
#define LE_PROF_MARK(k) le_prof_mark(k)
#define LE_PROF_NOW() le_now_ns()
#define LE_PROF_COUNT(k, ns) le_prof_count((k), (ns))

#else

#define LE_PROF_OCT(field) ((void)0)
#define LE_PROF_MARK(k) ((void)0)
#define LE_PROF_NOW() 0u
#define LE_PROF_COUNT(k, ns) ((void)0)

#endif /* LE_PROFILE_SECTIONS */

#endif /* SEGNO_ENGINE_PROF_H */
