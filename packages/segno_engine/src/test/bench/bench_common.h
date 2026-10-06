/* bench_common.h — what every engine CPU bench shares (#1179, #1197): the
 * options, monotonic timing and percentile stats, CPU-model detection, the
 * SCHED_FIFO window around timed loops, the playing 8-track rig and its
 * per-period baseline, the report rows and the threshold verdicts.
 *
 * Header-only and included by exactly one TU per bench binary (the includer
 * defines _GNU_SOURCE and includes the system headers first).
 */
#ifndef SEGNO_BENCH_COMMON_H
#define SEGNO_BENCH_COMMON_H

#include "segno_engine_api.h"

/* Below the app's audio thread (SCHED_FIFO 80, segno.service), so the bench
 * run beside the app on the appliance can be preempted by its callback rather
 * than starving it. */
#define BENCH_RT_PRIO 70

/* ---------------- options ---------------- */

typedef struct {
  double seconds;      /* simulated audio per timed scenario */
  double loop_seconds; /* content length per lane */
  int32_t rate;        /* sample rate */
  int32_t period;      /* frames per callback */
  double budget_us;    /* 0 = period / rate */
  int do_assert;
  int proxy;
  int smoke;
} bench_opts;

/* ---------------- timing ---------------- */

static double now_us(void) {
  struct timespec ts;
#if defined(__APPLE__)
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts); /* ns granularity (mach ticks) */
#else
  clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
  return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

static void sleep_until_us(double target) {
  for (;;) {
    const double d = target - now_us();
    if (d <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)(d / 1e6);
    ts.tv_nsec = (long)((d - (double)ts.tv_sec * 1e6) * 1e3);
    nanosleep(&ts, NULL);
  }
}

typedef struct {
  double p50, p99, p999, max, mean;
  size_t n;
  size_t over; /* samples above g_budget_us: periods that would be late */
} stats;

static int cmp_double(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

static double g_budget_us;

static stats stats_of(double* v, size_t n) {
  stats s = {0, 0, 0, 0, 0, n, 0};
  if (n == 0) return s;
  qsort(v, n, sizeof(double), cmp_double);
  double sum = 0;
  for (size_t i = 0; i < n; ++i) {
    sum += v[i];
    if (g_budget_us > 0 && v[i] > g_budget_us) s.over++;
  }
  size_t i50 = (size_t)ceil(0.50 * (double)n), i99 = (size_t)ceil(0.99 * (double)n);
  size_t i999 = (size_t)ceil(0.999 * (double)n);
  if (i50) i50--;
  if (i99) i99--;
  if (i999) i999--;
  s.p50 = v[i50];
  s.p99 = v[i99];
  s.p999 = v[i999];
  s.max = v[n - 1];
  s.mean = sum / (double)n;
  return s;
}

/* ---------------- machine ---------------- */

static char g_cpu_name[256] = "unknown";
static uint32_t g_cpu_part = 0; /* ARM "CPU part" (0xd0b = Cortex-A76) */

static void detect_cpu(void) {
#if defined(__APPLE__)
  size_t n = sizeof(g_cpu_name);
  if (sysctlbyname("machdep.cpu.brand_string", g_cpu_name, &n, NULL, 0) != 0) {
    snprintf(g_cpu_name, sizeof(g_cpu_name), "Apple (unknown)");
  }
#else
  FILE* f = fopen("/proc/cpuinfo", "r");
  if (f == NULL) return;
  char line[512];
  int have_name = 0;
  while (fgets(line, sizeof(line), f)) {
    char* colon = strchr(line, ':');
    if (colon == NULL) continue;
    if (!have_name && (strncmp(line, "model name", 10) == 0 ||
                       strncmp(line, "Model", 5) == 0 ||
                       strncmp(line, "Hardware", 8) == 0)) {
      const char* v = colon + 1;
      while (*v == ' ' || *v == '\t') v++;
      snprintf(g_cpu_name, sizeof(g_cpu_name), "%s", v);
      g_cpu_name[strcspn(g_cpu_name, "\n")] = 0;
      have_name = 1;
    }
    if (g_cpu_part == 0 && strncmp(line, "CPU part", 8) == 0) {
      g_cpu_part = (uint32_t)strtoul(colon + 1, NULL, 16);
    }
  }
  fclose(f);
  if (g_cpu_part != 0) {
    const char* arm = g_cpu_part == 0xd0b   ? "Cortex-A76"
                      : g_cpu_part == 0xd49 ? "Neoverse-N2"
                      : g_cpu_part == 0xd4f ? "Neoverse-V2"
                      : g_cpu_part == 0xd0c ? "Neoverse-N1"
                      : g_cpu_part == 0xd40 ? "Neoverse-V1"
                                            : "ARM (other)";
    /* without a model-name line the part is the whole label, not
     * "unknown" + part */
    const size_t len = have_name ? strlen(g_cpu_name) : 0;
    snprintf(g_cpu_name + len, sizeof(g_cpu_name) - len, "%s%s (part 0x%x)",
             have_name ? " / " : "", arm, g_cpu_part);
  }
#endif
}

/* ---------------- scheduling ---------------- */

/* The calling thread's policy, priority and nice, read back from the kernel
 * (not inferred from a call's return code). */
static void describe_sched(char* buf, size_t n) {
  int policy = 0;
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  pthread_getschedparam(pthread_self(), &policy, &sp);
  const char* name = policy == SCHED_FIFO ? "SCHED_FIFO"
                     : policy == SCHED_RR ? "SCHED_RR"
                                          : "SCHED_OTHER";
#if defined(__linux__)
  errno = 0;
  const int nice_v = getpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid));
#else
  errno = 0;
  const int nice_v = getpriority(PRIO_PROCESS, 0); /* process-wide here */
#endif
  if (policy == SCHED_FIFO || policy == SCHED_RR) {
    snprintf(buf, n, "%s %d", name, sp.sched_priority);
  } else if (errno == 0) {
    snprintf(buf, n, "%s, nice %d", name, nice_v);
  } else {
    snprintf(buf, n, "%s", name);
  }
}

/* Raises the calling thread to SCHED_FIFO BENCH_RT_PRIO for a timed loop and
 * records, once, what the kernel granted. A no-op where there is no real-time
 * scheduling. */
static char g_timed_sched[96] = "";

static void rt_enter(void) {
#if defined(__linux__)
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = BENCH_RT_PRIO;
  const int rc = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
  if (g_timed_sched[0] == 0) {
    char got[64];
    describe_sched(got, sizeof(got));
    snprintf(g_timed_sched, sizeof(g_timed_sched), "%s%s", got,
             rc == 0        ? ""
             : rc == EPERM ? " (SCHED_FIFO refused: EPERM)"
                           : " (SCHED_FIFO refused)");
  }
#else
  if (g_timed_sched[0] == 0) {
    char got[64];
    describe_sched(got, sizeof(got));
    snprintf(g_timed_sched, sizeof(g_timed_sched),
             "%s (no real-time scheduling on this platform)", got);
  }
#endif
}

/* Back to SCHED_OTHER between timed loops (setup, renders, reporting). */
static void rt_leave(void) {
#if defined(__linux__)
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  pthread_setschedparam(pthread_self(), SCHED_OTHER, &sp);
#endif
}

/* Peak resident set (ru_maxrss never falls). */
static double peak_rss_bytes(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return (double)ru.ru_maxrss; /* bytes */
#else
  return (double)ru.ru_maxrss * 1024.0; /* KiB */
#endif
}

/* ---------------- source signal (the D0 bench's) ---------------- */

static float* make_source(int32_t frames, int32_t sr) {
  float* s = (float*)calloc((size_t)frames, sizeof(float));
  const double freqs[] = {82.41, 220.0, 330.0, 587.33, 1244.5};
  const double amps[] = {0.28, 0.22, 0.16, 0.10, 0.06};
  for (int32_t i = 0; i < frames; ++i) {
    const double t = (double)i / sr;
    double x = 0;
    for (int k = 0; k < 5; ++k) {
      const double am = 0.7 + 0.3 * sin(2 * M_PI * (0.31 + 0.17 * k) * t);
      x += amps[k] * am * sin(2 * M_PI * freqs[k] * t);
    }
    s[i] = (float)x;
  }
  uint32_t rng = 12345u;
  const int32_t burst = sr * 30 / 1000;
  for (int32_t start = 0; start + sr / 2 <= frames; start += sr / 2) {
    for (int32_t i = 0; i < burst; ++i) {
      rng = rng * 1664525u + 1013904223u;
      const float u = (float)(rng >> 8) / 8388608.0f - 1.0f;
      s[start + i] += 0.4f * (float)exp(-6.0 * i / burst) * u;
    }
  }
  return s;
}

/* ---------------- a playing rig ---------------- */

typedef struct {
  le_engine* e;
  float* in;
  float* out;
  int32_t period;
} rig;

/* A playing rig with `in_ch` device inputs (the input buffer carries the
 * source signal on every channel, so monitors have something to process). */
static int rig_create_io(rig* r, const bench_opts* o, int lanes_per_track,
                         const float* src, int32_t frames, int32_t in_ch) {
  memset(r, 0, sizeof(*r));
  r->period = o->period;
  r->e = le_engine_create();
  if (r->e == NULL) return 0;
  if (le_engine_configure(r->e, o->rate, in_ch, 2, frames) != LE_OK) return 0;
  for (int32_t t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int32_t l = 0; l < lanes_per_track; ++l) {
      const int32_t rc = le_engine_import_track_lane(r->e, t, l, src, frames);
      if (rc != LE_OK) {
        fprintf(stderr, "import track %d lane %d failed: %d\n", t, l, rc);
        return 0;
      }
    }
  }
  if (le_engine_commit_session(r->e, frames, 0) != LE_OK) return 0;
  r->in = (float*)calloc((size_t)o->period * (size_t)in_ch, sizeof(float));
  r->out = (float*)calloc((size_t)o->period * 2, sizeof(float));
  if (in_ch > 2) {
    for (int32_t f = 0; f < o->period; ++f) {
      for (int32_t c = 0; c < in_ch; ++c) r->in[f * in_ch + c] = src[f];
    }
  }
  le_engine_process(r->e, r->out, r->in, 0); /* apply the commit */
  for (int32_t t = 0; t < LE_MAX_TRACKS; ++t) {
    if (le_engine_play(r->e, t) != LE_OK) return 0;
  }
  le_engine_process(r->e, r->out, r->in, 0);
  for (int k = 0; k < 200; ++k) le_engine_process(r->e, r->out, r->in, (uint32_t)o->period);
  return 1;
}

static int rig_create(rig* r, const bench_opts* o, int lanes_per_track,
                      const float* src, int32_t frames) {
  return rig_create_io(r, o, lanes_per_track, src, frames, 2);
}

static void rig_destroy(rig* r) {
  if (r->e) le_engine_destroy(r->e);
  free(r->in);
  free(r->out);
}

/* ---------------- scenarios ---------------- */

static void print_row(const char* label, stats s) {
  printf("| %-34s | %8.1f | %8.1f | %8.1f | %8.1f | %6.1f%% | %6.1f%% |\n", label,
         s.p50, s.p99, s.max, s.mean, 100.0 * s.p50 / g_budget_us,
         100.0 * s.p99 / g_budget_us);
}

/* A row with the tail figures the joint budget is judged on. */
static void print_tail_row(const char* label, stats s) {
  printf("| %-34s | %8.1f | %8.1f | %8.1f | %8.1f | %6.1f%% | %6.1f%% | %6.1f%% | %5zu |\n",
         label, s.p50, s.p99, s.p999, s.max, 100.0 * s.p50 / g_budget_us,
         100.0 * s.p99 / g_budget_us, 100.0 * s.p999 / g_budget_us, s.over);
}

static void print_tail_header(void) {
  printf("| scenario                           |  p50 us |  p99 us | p99.9 us |  max us | p50/bud | p99/bud | p99.9/bud | late |\n");
  printf("|------------------------------------|---------|---------|----------|---------|---------|---------|-----------|------|\n");
}

/* One period of the pitch/time read head (engine_read_head.h) over
 * `lanes_per_track` lanes of 8 tracks at `rate`: the mixer work Speed adds.
 * The includer includes engine_read_head.h. */
#ifdef LE_ENGINE_READ_HEAD_H
static volatile float g_sink;

static void head_period(const le_read_head* heads, float** lane_bufs,
                        int lanes_per_track, int32_t len, int64_t base,
                        int32_t period, double rate, float* acc) {
  const int decimate = rate >= 2.0;
  for (int32_t f = 0; f < period; ++f) {
    const int64_t pos = base + f;
    float sum = 0.0f;
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      const double idx = le_head_index(&heads[t], pos, len);
      for (int l = 0; l < lanes_per_track; ++l) {
        const float* buf = lane_bufs[t * lanes_per_track + l];
        sum += decimate ? le_head_sample_decimated(buf, len, idx, rate)
                        : le_head_sample(buf, len, idx);
      }
    }
    acc[f] = sum;
  }
}
#endif

static void print_header(void) {
  printf("| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |\n");
  printf("|------------------------------------|---------|---------|---------|---------|---------|---------|\n");
}

static stats scenario_baseline(const bench_opts* o, int lanes_per_track,
                               const float* src, int32_t frames) {
  rig r;
  if (!rig_create(&r, o, lanes_per_track, src, frames)) {
    fprintf(stderr, "baseline rig failed\n");
    exit(3);
  }
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* t = (double*)malloc(sizeof(double) * periods);
  le_snapshot* snap = (le_snapshot*)calloc(1, sizeof(le_snapshot));
  rt_enter();
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    le_engine_process(r.e, r.out, r.in, (uint32_t)o->period);
    t[k] = now_us() - a;
    if ((k & 63) == 0) le_engine_get_snapshot(r.e, snap); /* the UI's poll */
  }
  rt_leave();
  free(snap);
  const stats s = stats_of(t, periods);
  free(t);
  rig_destroy(&r);
  return s;
}

typedef struct {
  const char* what;
  double value, limit;
  int pass;
} verdict;

static verdict g_verdicts[64];
static int g_nverdicts;

static void judge(const char* what, double value, double limit, int at_most) {
  verdict* v = &g_verdicts[g_nverdicts++];
  v->what = what;
  v->value = value;
  v->limit = limit;
  v->pass = at_most ? value <= limit : value >= limit;
}

#endif /* SEGNO_BENCH_COMMON_H */
