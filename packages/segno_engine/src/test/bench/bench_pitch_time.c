/* bench_pitch_time.c — the #1179 Part 1 CPU spike (pitch and time core).
 *
 * Standalone harness built by bench_pitch_time.sh against the real engine
 * sources and the Signalsmith Stretch C shim. NOT part of the test gate; the
 * native-tests CI job smoke-runs it and native-bench-arm64 asserts the proxy
 * thresholds. Numbers and verdicts live in
 * docs/plan/2026-10-06-pitch-time-spike-findings.md.
 *
 * Scenarios (each over --seconds of simulated audio at --rate / --period):
 *   baseline  le_engine_process with 8 tracks x {1, 8} lanes of --loop-seconds
 *             content PLAYING, per-period cost. The control everything else is
 *             added to.
 *   head      the fractional read-head kernel (engine_read_head.h) over 8 and
 *             64 lanes at the five Speed factors and two tempo ratios, in a loop
 *             shaped like the mixer's lane loop; reported as the cost ADDED over
 *             the same loop at the identity head.
 *   render    le_stretch_render_offline throughput (seconds of audio per
 *             second) for one --loop-seconds mono lane, both presets, +-12 st
 *             and the two tempo ratios; idle, then under load (a second engine
 *             paced at the period on an RT thread while this thread runs at
 *             nice +10, the cache worker's priority).
 *   inline    streaming le_stretch_process at --period output frames per call
 *             for 1 / 8 / 64 streams, hop-aligned and hop-staggered, plus one
 *             seek re-prime; informational (the plan's D2 does not stream it).
 *   memory    RSS growth per stretcher instance, bytes per rendered entry,
 *             peak RSS.
 *
 * Thresholds (--assert): the Pi 5 set, refused on anything but a Cortex-A76
 * unless --proxy, which swaps in the arm64 CI proxy set (p50 and throughput
 * only, at twice the margin). --smoke: one second, two-second loops, no
 * assertions.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/sysctl.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#endif

#include "engine_read_head.h"
#include "segno_engine_api.h"
#include "../../stretch/le_stretch.h"

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

static void usage(void) {
  fprintf(stderr,
          "bench_pitch_time [--smoke] [--seconds N] [--loop-seconds N] "
          "[--rate HZ] [--period FRAMES] [--budget-us N] [--assert] [--proxy]\n");
}

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
  double p50, p99, max, mean;
  size_t n;
} stats;

static int cmp_double(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

static stats stats_of(double* v, size_t n) {
  stats s = {0, 0, 0, 0, n};
  if (n == 0) return s;
  qsort(v, n, sizeof(double), cmp_double);
  double sum = 0;
  for (size_t i = 0; i < n; ++i) sum += v[i];
  size_t i50 = (size_t)ceil(0.50 * (double)n), i99 = (size_t)ceil(0.99 * (double)n);
  if (i50) i50--;
  if (i99) i99--;
  s.p50 = v[i50];
  s.p99 = v[i99];
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
    size_t len = strlen(g_cpu_name);
    snprintf(g_cpu_name + len, sizeof(g_cpu_name) - len, "%s%s (part 0x%x)",
             have_name ? " / " : "", arm, g_cpu_part);
  }
#endif
}

static const char* try_realtime(void) {
#if defined(__linux__)
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = 80;
  const int rc = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
  if (rc == 0) return "SCHED_FIFO 80";
  return rc == EPERM ? "SCHED_OTHER (SCHED_FIFO refused: EPERM)"
                     : "SCHED_OTHER (SCHED_FIFO refused)";
#else
  return "no real-time scheduling on this platform";
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

/* Current resident set, for before/after deltas. */
static double rss_bytes(void) {
#if defined(__APPLE__)
  struct mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) == KERN_SUCCESS) {
    return (double)info.resident_size;
  }
  return peak_rss_bytes();
#else
  FILE* f = fopen("/proc/self/statm", "r");
  if (f == NULL) return peak_rss_bytes();
  long pages = 0, resident = 0;
  if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
  fclose(f);
  return (double)resident * (double)sysconf(_SC_PAGESIZE);
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

static int rig_create(rig* r, const bench_opts* o, int lanes_per_track,
                      const float* src, int32_t frames) {
  memset(r, 0, sizeof(*r));
  r->period = o->period;
  r->e = le_engine_create();
  if (r->e == NULL) return 0;
  if (le_engine_configure(r->e, o->rate, 2, 2, frames) != LE_OK) return 0;
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
  r->in = (float*)calloc((size_t)o->period * 2, sizeof(float));
  r->out = (float*)calloc((size_t)o->period * 2, sizeof(float));
  le_engine_process(r->e, r->out, r->in, 0); /* apply the commit */
  for (int32_t t = 0; t < LE_MAX_TRACKS; ++t) {
    if (le_engine_play(r->e, t) != LE_OK) return 0;
  }
  le_engine_process(r->e, r->out, r->in, 0);
  for (int k = 0; k < 200; ++k) le_engine_process(r->e, r->out, r->in, (uint32_t)o->period);
  return 1;
}

static void rig_destroy(rig* r) {
  if (r->e) le_engine_destroy(r->e);
  free(r->in);
  free(r->out);
}

/* ---------------- scenarios ---------------- */

static double g_budget_us;

static void print_row(const char* label, stats s) {
  printf("| %-34s | %8.1f | %8.1f | %8.1f | %8.1f | %6.1f%% | %6.1f%% |\n", label,
         s.p50, s.p99, s.max, s.mean, 100.0 * s.p50 / g_budget_us,
         100.0 * s.p99 / g_budget_us);
}

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
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    le_engine_process(r.e, r.out, r.in, (uint32_t)o->period);
    t[k] = now_us() - a;
    if ((k & 63) == 0) le_engine_get_snapshot(r.e, snap); /* the UI's poll */
  }
  free(snap);
  const stats s = stats_of(t, periods);
  free(t);
  rig_destroy(&r);
  return s;
}

static volatile float g_sink;

static stats scenario_head(const bench_opts* o, int total_lanes, double rate,
                           float** lane_bufs, int32_t len) {
  const int lanes_per_track = total_lanes / LE_MAX_TRACKS;
  le_read_head heads[LE_MAX_TRACKS];
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    heads[t].reversed = 0;
    heads[t].origin = (double)(t * 977 % len);
    heads[t].rate = rate;
  }
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* tm = (double*)malloc(sizeof(double) * periods);
  float* acc = (float*)calloc((size_t)o->period, sizeof(float));
  int64_t base = 0;
  const int decimate = rate >= 2.0;
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    for (int32_t f = 0; f < o->period; ++f) {
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
    base += o->period;
    tm[k] = now_us() - a;
    g_sink = acc[(k * 7) % (size_t)o->period];
  }
  free(acc);
  const stats s = stats_of(tm, periods);
  free(tm);
  return s;
}

typedef struct {
  int cheaper;
  float semitones;
  double ratio;
} render_cfg;

static double scenario_render_once(const render_cfg* c, const float* src,
                                   int32_t frames, int32_t sr) {
  const int32_t out_frames = (int32_t)llround((double)frames * c->ratio);
  float* out = (float*)calloc((size_t)out_frames, sizeof(float));
  const float* in[1] = {src};
  float* outs[1] = {out};
  const double a = now_us();
  const int32_t rc = le_stretch_render_offline(in, frames, 1, sr, c->ratio,
                                               c->semitones, 8000.0f / (float)sr,
                                               c->cheaper, 7u, 1, outs, out_frames);
  const double el = (now_us() - a) / 1e6;
  free(out);
  if (rc != LE_STRETCH_OK) {
    fprintf(stderr, "render failed: %d\n", rc);
    exit(3);
  }
  return ((double)frames / sr) / el; /* x real time */
}

typedef struct {
  const bench_opts* o;
  const float* src;
  int32_t frames;
  volatile int stop;
  int running;
  char sched[64];
} load_thread_args;

static void* load_thread_main(void* p) {
  load_thread_args* a = (load_thread_args*)p;
  snprintf(a->sched, sizeof(a->sched), "%s", try_realtime());
  rig r;
  if (!rig_create(&r, a->o, 1, a->src, a->frames)) {
    a->running = -1;
    return NULL;
  }
  a->running = 1;
  const double period_us = 1e6 * a->o->period / a->o->rate;
  double next = now_us();
  while (!a->stop) {
    le_engine_process(r.e, r.out, r.in, (uint32_t)a->o->period);
    next += period_us;
    sleep_until_us(next);
  }
  rig_destroy(&r);
  return NULL;
}

static stats scenario_inline(const bench_opts* o, int streams, int staggered,
                             const float* src, int32_t frames) {
  le_stretch** st = (le_stretch**)calloc((size_t)streams, sizeof(le_stretch*));
  int64_t* pos = (int64_t*)calloc((size_t)streams, sizeof(int64_t));
  float* in = (float*)calloc((size_t)o->period, sizeof(float));
  float* out = (float*)calloc((size_t)o->period, sizeof(float));
  const float* ins[1] = {in};
  float* outs[1] = {out};
  for (int i = 0; i < streams; ++i) {
    st[i] = le_stretch_create(1, o->rate, 1, (uint32_t)(100 + i));
    le_stretch_set_semitones(st[i], 3.0f, 8000.0f / (float)o->rate);
    if (staggered) {
      int32_t prime = (int32_t)((int64_t)le_stretch_interval_samples(st[i]) * i / streams);
      while (prime > 0) {
        const int32_t n = prime < o->period ? prime : o->period;
        for (int32_t f = 0; f < n; ++f) in[f] = src[(pos[i] + f) % frames];
        pos[i] += n;
        le_stretch_process(st[i], ins, n, outs, n);
        prime -= n;
      }
    }
  }
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* tm = (double*)malloc(sizeof(double) * periods);
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    for (int i = 0; i < streams; ++i) {
      for (int32_t f = 0; f < o->period; ++f) in[f] = src[(pos[i] + f) % frames];
      pos[i] += o->period;
      le_stretch_process(st[i], ins, o->period, outs, o->period);
    }
    tm[k] = now_us() - a;
    g_sink = out[0];
  }
  for (int i = 0; i < streams; ++i) le_stretch_destroy(st[i]);
  free(st);
  free(pos);
  free(in);
  free(out);
  const stats s = stats_of(tm, periods);
  free(tm);
  return s;
}

static double scenario_seek_us(const bench_opts* o, const float* src) {
  le_stretch* s = le_stretch_create(1, o->rate, 1, 5u);
  const int32_t n = le_stretch_block_samples(s) + le_stretch_interval_samples(s);
  const float* ins[1] = {src};
  double total = 0;
  for (int k = 0; k < 8; ++k) {
    le_stretch_reset(s);
    const double a = now_us();
    le_stretch_seek(s, ins, n, 1.0);
    total += now_us() - a;
  }
  le_stretch_destroy(s);
  return total / 8.0;
}

/* Live heap bytes (malloc accounting, not pages): the honest per-instance
 * figure once the process heap has already grown from earlier scenarios. */
static double heap_bytes(void) {
#if defined(__APPLE__)
  malloc_statistics_t st;
  malloc_zone_statistics(NULL, &st);
  return (double)st.size_in_use;
#elif defined(__GLIBC__)
  struct mallinfo2 mi = mallinfo2();
  return (double)mi.uordblks + (double)mi.hblkhd;
#else
  return rss_bytes();
#endif
}

static double scenario_memory_per_instance(const bench_opts* o, int cheaper) {
  const double before = heap_bytes();
  le_stretch* st[16];
  float probe[64] = {0};
  const float* ins[1] = {probe};
  float out[64];
  float* outs[1] = {out};
  for (int i = 0; i < 16; ++i) {
    st[i] = le_stretch_create(1, o->rate, cheaper, (uint32_t)i);
    le_stretch_process(st[i], ins, 64, outs, 64); /* touch the pages */
  }
  const double after = heap_bytes();
  for (int i = 0; i < 16; ++i) le_stretch_destroy(st[i]);
  return (after - before) / 16.0;
}

/* ---------------- main ---------------- */

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

int main(int argc, char** argv) {
  bench_opts o = {60.0, 30.0, 96000, 64, 0.0, 0, 0, 0};
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) o.smoke = 1;
    else if (!strcmp(argv[i], "--assert")) o.do_assert = 1;
    else if (!strcmp(argv[i], "--proxy")) o.proxy = 1;
    else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) o.seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--loop-seconds") && i + 1 < argc) o.loop_seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--rate") && i + 1 < argc) o.rate = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--period") && i + 1 < argc) o.period = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--budget-us") && i + 1 < argc) o.budget_us = atof(argv[++i]);
    else { usage(); return 2; }
  }
  if (o.smoke) {
    o.seconds = 1.0;
    o.loop_seconds = 2.0;
    o.do_assert = 0;
  }
  if (o.budget_us <= 0) o.budget_us = 1e6 * o.period / o.rate;
  g_budget_us = o.budget_us;
  detect_cpu();
  if (o.do_assert && !o.proxy && g_cpu_part != 0xd0b) {
    fprintf(stderr,
            "--assert carries the Pi 5 (Cortex-A76) thresholds; this is %s. "
            "Use --assert --proxy for the arm64 CI proxy set.\n",
            g_cpu_name);
    return 2;
  }
  const char* sched = try_realtime();

  printf("# bench_pitch_time\n\n");
  printf("- CPU: %s\n- scheduling: %s\n", g_cpu_name, sched);
  printf("- rate %d Hz, period %d frames, budget %.1f us, %.0f s per scenario, "
         "%.0f s loops%s\n\n",
         o.rate, o.period, o.budget_us, o.seconds, o.loop_seconds,
         o.smoke ? " (smoke)" : "");

  const int32_t frames = (int32_t)(o.loop_seconds * o.rate);
  float* src = make_source(frames, o.rate);

  /* baseline */
  printf("## baseline (le_engine_process, 8 tracks PLAYING)\n\n");
  print_header();
  const stats base1 = scenario_baseline(&o, 1, src, frames);
  print_row("8 tracks x 1 lane", base1);
  const stats base8 = scenario_baseline(&o, 8, src, frames);
  print_row("8 tracks x 8 lanes", base8);
  printf("\n");

  /* head */
  printf("## head (engine_read_head.h kernel; 'added' = minus the identity loop)\n\n");
  print_header();
  const double rates[] = {0.5, 2.0, 4.0, 8.0, 0.75, 4.0 / 3.0};
  const char* rate_names[] = {"1/2x", "2x", "4x", "8x", "ratio 0.75", "ratio 4/3"};
  const int lane_counts[] = {8, 64};
  double worst_added_p50[2] = {0, 0}, worst_added_p99[2] = {0, 0};
  for (int lc = 0; lc < 2; ++lc) {
    const int lanes = lane_counts[lc];
    float** bufs = (float**)calloc((size_t)lanes, sizeof(float*));
    for (int l = 0; l < lanes; ++l) {
      bufs[l] = (float*)malloc(sizeof(float) * (size_t)frames);
      memcpy(bufs[l], src, sizeof(float) * (size_t)frames);
    }
    const stats id = scenario_head(&o, lanes, 1.0, bufs, frames);
    char label[64];
    snprintf(label, sizeof(label), "%d lanes identity (control)", lanes);
    print_row(label, id);
    for (int r = 0; r < 6; ++r) {
      const stats s = scenario_head(&o, lanes, rates[r], bufs, frames);
      snprintf(label, sizeof(label), "%d lanes %s", lanes, rate_names[r]);
      print_row(label, s);
      const double ap50 = s.p50 - id.p50 > 0 ? s.p50 - id.p50 : 0;
      const double ap99 = s.p99 - id.p99 > 0 ? s.p99 - id.p99 : 0;
      if (ap50 > worst_added_p50[lc]) worst_added_p50[lc] = ap50;
      if (ap99 > worst_added_p99[lc]) worst_added_p99[lc] = ap99;
    }
    printf("| %-34s | %8.1f | %8.1f |          |          | %6.1f%% | %6.1f%% |\n",
           lc == 0 ? "8 lanes worst ADDED" : "64 lanes worst ADDED",
           worst_added_p50[lc], worst_added_p99[lc], 100.0 * worst_added_p50[lc] / g_budget_us,
           100.0 * worst_added_p99[lc] / g_budget_us);
    for (int l = 0; l < lanes; ++l) free(bufs[l]);
    free(bufs);
  }
  printf("\n");

  /* render, idle */
  const render_cfg cfgs[] = {{1, 12.0f, 1.0}, {1, -12.0f, 1.0}, {1, 0.0f, 0.75},
                             {1, 0.0f, 4.0 / 3.0}, {0, 12.0f, 1.0}, {0, 0.0f, 0.75}};
  const char* cfg_names[] = {"cheaper +12 st ratio 1", "cheaper -12 st ratio 1",
                             "cheaper stretch 0.75", "cheaper stretch 4/3",
                             "default +12 st ratio 1", "default stretch 0.75"};
  printf("## render (le_stretch_render_offline, %.0f s mono, x real time)\n\n", o.loop_seconds);
  printf("| configuration              |   idle |   loaded |\n");
  printf("|----------------------------|--------|----------|\n");
  double idle[6];
  for (int c = 0; c < 6; ++c) idle[c] = scenario_render_once(&cfgs[c], src, frames, o.rate);

  /* inline (informational) */
  const int stream_counts[] = {1, 8, 64};
  stats inl[3][2];
  for (int sc = 0; sc < 3; ++sc) {
    for (int stg = 0; stg < 2; ++stg) {
      inl[sc][stg] = scenario_inline(&o, stream_counts[sc], stg, src, frames);
    }
  }
  const double seek_us = scenario_seek_us(&o, src);

  /* memory */
  const double per_cheaper = scenario_memory_per_instance(&o, 1);
  const double per_default = scenario_memory_per_instance(&o, 0);

  /* render under load, this thread at nice +10 (the cache worker's level) */
  load_thread_args la;
  memset(&la, 0, sizeof(la));
  la.o = &o;
  la.src = src;
  la.frames = frames;
  pthread_t lt;
  pthread_create(&lt, NULL, load_thread_main, &la);
  while (la.running == 0) usleep(1000);
  const int nice_rc = setpriority(PRIO_PROCESS, 0, 10);
  double loaded[6];
  double loaded_cheaper_min = 1e9;
  for (int c = 0; c < 6; ++c) {
    loaded[c] = la.running > 0 ? scenario_render_once(&cfgs[c], src, frames, o.rate) : 0;
    if (cfgs[c].cheaper && loaded[c] < loaded_cheaper_min) loaded_cheaper_min = loaded[c];
    printf("| %-26s | %6.1fx | %7.1fx |\n", cfg_names[c], idle[c], loaded[c]);
  }
  la.stop = 1;
  pthread_join(lt, NULL);
  printf("\nload thread: %s; renderer nice +10 %s\n\n", la.running > 0 ? la.sched : "FAILED",
         nice_rc == 0 ? "applied" : "refused");

  printf("## inline (streaming le_stretch_process, %d frames per call; informational)\n\n", o.period);
  print_header();
  for (int sc = 0; sc < 3; ++sc) {
    char label[64];
    snprintf(label, sizeof(label), "%d streams aligned", stream_counts[sc]);
    print_row(label, inl[sc][0]);
    snprintf(label, sizeof(label), "%d streams staggered", stream_counts[sc]);
    print_row(label, inl[sc][1]);
  }
  printf("\nseek re-prime (block + interval frames): %.1f us (%.1f%% of the period)\n\n",
         seek_us, 100.0 * seek_us / g_budget_us);

  printf("## memory\n\n");
  printf("- stretcher live heap per instance: cheaper %.0f KiB, default %.0f KiB\n",
         per_cheaper / 1024.0, per_default / 1024.0);
  printf("- rendered entry: %d frames x 4 = %.1f MiB per mono lane\n", frames,
         (double)frames * 4.0 / 1048576.0);
  printf("- peak RSS: %.0f MiB\n\n", peak_rss_bytes() / 1048576.0);

  /* verdicts */
  if (o.do_assert) {
    if (o.proxy) {
      judge("head added p50 at 8 lanes <= 5% of period", 100.0 * worst_added_p50[0] / g_budget_us, 5.0, 1);
      judge("head added p50 at 64 lanes <= 17% of period", 100.0 * worst_added_p50[1] / g_budget_us, 17.0, 1);
      judge("render cheaper under load >= 40x real time", loaded_cheaper_min, 40.0, 0);
    } else {
      judge("head added p99 at 8 lanes <= 10% of period", 100.0 * worst_added_p99[0] / g_budget_us, 10.0, 1);
      judge("head added p99 at 64 lanes <= 35% of period", 100.0 * worst_added_p99[1] / g_budget_us, 35.0, 1);
      judge("baseline p99 + head added p99 (8 lanes) <= 50% of period",
            100.0 * (base1.p99 + worst_added_p99[0]) / g_budget_us, 50.0, 1);
      judge("render cheaper under load >= 20x real time", loaded_cheaper_min, 20.0, 0);
    }
    judge("stretcher heap per instance (cheaper) <= 4 MiB", per_cheaper / 1048576.0, 4.0, 1);
    printf("## verdict (%s thresholds)\n\n", o.proxy ? "arm64 proxy" : "Pi 5");
    int failed = 0;
    for (int i = 0; i < g_nverdicts; ++i) {
      printf("- %s: %s (%.2f vs %.2f)\n", g_verdicts[i].pass ? "PASS" : "FAIL",
             g_verdicts[i].what, g_verdicts[i].value, g_verdicts[i].limit);
      if (!g_verdicts[i].pass) failed++;
    }
    printf("\n%s\n", failed ? "THRESHOLDS FAILED" : "ALL THRESHOLDS MET");
    free(src);
    return failed ? 1 : 0;
  }
  free(src);
  printf("(no assertions requested)\n");
  return 0;
}
