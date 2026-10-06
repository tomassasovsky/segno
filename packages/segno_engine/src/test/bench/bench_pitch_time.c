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
 *             the mixer's integer path (`lbuf[seg_base + position % len]`,
 *             which Part 2a keeps for identity heads). The identity head is
 *             timed too, as a row of its own.
 *   render    le_stretch_render_offline throughput (seconds of audio per
 *             second) for one --loop-seconds mono lane, both presets, +-12 st
 *             and the two tempo ratios; idle, then under load (a second engine
 *             paced at the period on a real-time thread). The renders run on
 *             their own SCHED_OTHER thread at nice +10, the cache worker's
 *             priority, and the report prints the policy and nice read back on
 *             that thread.
 *   inline    streaming le_stretch_process at --period output frames per call
 *             for 1 / 8 / 64 streams, hop-aligned and hop-staggered, plus one
 *             seek re-prime; informational (the plan's D2 does not stream it).
 *   memory    live C++ heap per stretcher instance and the peak C++ heap
 *             during each render (bench_alloc.cpp counts operator new), from
 *             which the render's worker scratch = peak - one stretcher; bytes
 *             per rendered entry; peak RSS.
 *
 * Scheduling: SCHED_FIFO (priority BENCH_RT_PRIO, below the app's audio thread
 * at 80, so a run beside the app never starves its callback) is held only
 * around the timed per-period loops of baseline, head and inline, and dropped
 * back to SCHED_OTHER in between.
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
#include <sys/sysctl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif

#include "engine_read_head.h"
#include "segno_engine_api.h"
#include "../../stretch/le_stretch.h"

/* bench_alloc.cpp: the counting global operator new. */
long long bench_cxx_heap_live(void);
void bench_cxx_heap_reset_peak(void);
long long bench_cxx_heap_peak(void);

#include "bench_common.h"


static void usage(void) {
  fprintf(stderr,
          "bench_pitch_time [--smoke] [--seconds N] [--loop-seconds N] "
          "[--rate HZ] [--period FRAMES] [--budget-us N] [--assert] [--proxy]\n");
}

/* Lowers the calling thread to nice +10, the cache worker's level. Per thread
 * on Linux (nice is a per-task attribute there); process-wide elsewhere,
 * which is why the renders run last. */
static void lower_to_worker_nice(void) {
#if defined(__linux__)
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 10);
#else
  setpriority(PRIO_PROCESS, 0, 10);
#endif
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
  rt_enter();
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
  rt_leave();
  free(acc);
  const stats s = stats_of(tm, periods);
  free(tm);
  return s;
}

/* The control the head's cost is ADDED to: the mixer's integer read as it is
 * today and as Part 2a keeps it for identity heads, one `position % len` per
 * track per frame and one `lbuf[seg_base + trk_pos]` load per lane
 * (engine_process.c mix loop), in the same loop shape as scenario_head. */
static stats scenario_int(const bench_opts* o, int total_lanes,
                          float** lane_bufs, int32_t len) {
  const int lanes_per_track = total_lanes / LE_MAX_TRACKS;
  int64_t origin[LE_MAX_TRACKS];
  for (int t = 0; t < LE_MAX_TRACKS; ++t) origin[t] = t * 977 % len;
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* tm = (double*)malloc(sizeof(double) * periods);
  float* acc = (float*)calloc((size_t)o->period, sizeof(float));
  int64_t base = 0;
  rt_enter();
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    for (int32_t f = 0; f < o->period; ++f) {
      const int64_t pos = base + f;
      float sum = 0.0f;
      for (int t = 0; t < LE_MAX_TRACKS; ++t) {
        const int64_t trk_pos = (pos + origin[t]) % len;
        for (int l = 0; l < lanes_per_track; ++l) {
          sum += lane_bufs[t * lanes_per_track + l][trk_pos];
        }
      }
      acc[f] = sum;
    }
    base += o->period;
    tm[k] = now_us() - a;
    g_sink = acc[(k * 7) % (size_t)o->period];
  }
  rt_leave();
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

/* One render of a mono lane: returns x real time and stores the peak C++ heap
 * the call held above what was live before it (the stretcher plus the
 * render's scratch; the entry itself, `out`, is the caller's and is not in
 * it). */
static double scenario_render_once(const render_cfg* c, const float* src,
                                   int32_t frames, int32_t sr,
                                   double* peak_heap_bytes) {
  const int32_t out_frames = (int32_t)llround((double)frames * c->ratio);
  float* out = (float*)calloc((size_t)out_frames, sizeof(float));
  const float* in[1] = {src};
  float* outs[1] = {out};
  const long long before = bench_cxx_heap_live();
  bench_cxx_heap_reset_peak();
  const double a = now_us();
  const int32_t rc = le_stretch_render_offline(in, frames, 1, sr, c->ratio,
                                               c->semitones, 8000.0f / (float)sr,
                                               c->cheaper, 7u, 1, outs, out_frames);
  const double el = (now_us() - a) / 1e6;
  *peak_heap_bytes = (double)(bench_cxx_heap_peak() - before);
  free(out);
  if (rc != LE_STRETCH_OK) {
    fprintf(stderr, "render failed: %d\n", rc);
    exit(3);
  }
  return ((double)frames / sr) / el; /* x real time */
}

/* The renders, on a thread of their own at the cache worker's priority. */
typedef struct {
  const render_cfg* cfgs;
  int n;
  const float* src;
  int32_t frames;
  int32_t rate;
  double* xrt;       /* [n] x real time */
  double* peak_heap; /* [n] bytes */
  char sched[96];    /* read back on the thread */
} render_job;

static void* render_thread_main(void* p) {
  render_job* j = (render_job*)p;
  lower_to_worker_nice();
  describe_sched(j->sched, sizeof(j->sched));
  for (int c = 0; c < j->n; ++c) {
    j->xrt[c] = scenario_render_once(&j->cfgs[c], j->src, j->frames, j->rate,
                                     &j->peak_heap[c]);
  }
  return NULL;
}

static void run_render_job(render_job* j) {
  pthread_t th;
  if (pthread_create(&th, NULL, render_thread_main, j) != 0) {
    fprintf(stderr, "render thread failed\n");
    exit(3);
  }
  pthread_join(th, NULL);
}

typedef struct {
  const bench_opts* o;
  const float* src;
  int32_t frames;
  volatile int stop;
  volatile int running;
  char sched[96];
} load_thread_args;

/* The load: a second engine paced at the period on a real-time thread, as
 * the app's callback would be (at BENCH_RT_PRIO, like the timed loops). */
static void* load_thread_main(void* p) {
  load_thread_args* a = (load_thread_args*)p;
  rig r;
  if (!rig_create(&r, a->o, 1, a->src, a->frames)) {
    a->running = -1;
    return NULL;
  }
  rt_enter();
  describe_sched(a->sched, sizeof(a->sched));
  a->running = 1;
  const double period_us = 1e6 * a->o->period / a->o->rate;
  double next = now_us();
  while (!a->stop) {
    le_engine_process(r.e, r.out, r.in, (uint32_t)a->o->period);
    next += period_us;
    sleep_until_us(next);
  }
  rt_leave();
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
  rt_enter();
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
  rt_leave();
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

/* Live C++ heap per mono stretcher instance (exact: bench_alloc.cpp counts
 * every operator new the shim and the library make). */
static double scenario_memory_per_instance(const bench_opts* o, int cheaper) {
  const long long before = bench_cxx_heap_live();
  le_stretch* st[16];
  for (int i = 0; i < 16; ++i) {
    st[i] = le_stretch_create(1, o->rate, cheaper, (uint32_t)i);
  }
  const long long after = bench_cxx_heap_live();
  for (int i = 0; i < 16; ++i) le_stretch_destroy(st[i]);
  return (double)(after - before) / 16.0;
}

/* ---------------- main ---------------- */

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
  /* what the timed loops get: raise once, read it back, drop again */
  rt_enter();
  rt_leave();

  printf("# bench_pitch_time\n\n");
  printf("- CPU: %s\n- timed loops (baseline, head, inline): %s, held only "
         "for the loop\n",
         g_cpu_name, g_timed_sched);
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
  printf("## head (engine_read_head.h kernel; 'added' = minus the mixer's "
         "integer read)\n\n");
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
    const stats ctl = scenario_int(&o, lanes, bufs, frames);
    char label[64];
    snprintf(label, sizeof(label), "%d lanes integer read (control)", lanes);
    print_row(label, ctl);
    const stats id = scenario_head(&o, lanes, 1.0, bufs, frames);
    snprintf(label, sizeof(label), "%d lanes identity head", lanes);
    print_row(label, id);
    for (int r = 0; r < 6; ++r) {
      const stats s = scenario_head(&o, lanes, rates[r], bufs, frames);
      snprintf(label, sizeof(label), "%d lanes %s", lanes, rate_names[r]);
      print_row(label, s);
      const double ap50 = s.p50 - ctl.p50 > 0 ? s.p50 - ctl.p50 : 0;
      const double ap99 = s.p99 - ctl.p99 > 0 ? s.p99 - ctl.p99 : 0;
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

  /* inline (informational) */
  const int stream_counts[] = {1, 8, 64};
  stats inl[3][2];
  for (int sc = 0; sc < 3; ++sc) {
    for (int stg = 0; stg < 2; ++stg) {
      inl[sc][stg] = scenario_inline(&o, stream_counts[sc], stg, src, frames);
    }
  }
  const double seek_us = scenario_seek_us(&o, src);
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

  /* memory per instance */
  const double per_cheaper = scenario_memory_per_instance(&o, 1);
  const double per_default = scenario_memory_per_instance(&o, 0);

  /* render: last, because outside Linux nice +10 is process-wide */
  enum { kCfgs = 6 };
  const render_cfg cfgs[kCfgs] = {{1, 12.0f, 1.0}, {1, -12.0f, 1.0}, {1, 0.0f, 0.75},
                                  {1, 0.0f, 4.0 / 3.0}, {0, 12.0f, 1.0}, {0, 0.0f, 0.75}};
  const char* cfg_names[kCfgs] = {"cheaper +12 st ratio 1", "cheaper -12 st ratio 1",
                                  "cheaper stretch 0.75", "cheaper stretch 4/3",
                                  "default +12 st ratio 1", "default stretch 0.75"};
  double idle[kCfgs], loaded[kCfgs], idle_heap[kCfgs], loaded_heap[kCfgs];
  render_job idle_job = {cfgs, kCfgs, src, frames, o.rate, idle, idle_heap, ""};
  run_render_job(&idle_job);

  load_thread_args la;
  memset(&la, 0, sizeof(la));
  la.o = &o;
  la.src = src;
  la.frames = frames;
  pthread_t lt;
  pthread_create(&lt, NULL, load_thread_main, &la);
  while (la.running == 0) usleep(1000);
  render_job loaded_job = {cfgs, kCfgs, src, frames, o.rate, loaded, loaded_heap, ""};
  if (la.running > 0) {
    run_render_job(&loaded_job);
  } else {
    for (int c = 0; c < kCfgs; ++c) loaded[c] = loaded_heap[c] = 0;
  }
  la.stop = 1;
  pthread_join(lt, NULL);

  printf("## render (le_stretch_render_offline, %.0f s mono, x real time)\n\n", o.loop_seconds);
  printf("| configuration              |   idle |   loaded | peak heap KiB | scratch KiB |\n");
  printf("|----------------------------|--------|----------|---------------|-------------|\n");
  double loaded_cheaper_min = 1e9, scratch_max = 0;
  for (int c = 0; c < kCfgs; ++c) {
    if (cfgs[c].cheaper && loaded[c] < loaded_cheaper_min) loaded_cheaper_min = loaded[c];
    const double peak = idle_heap[c] > loaded_heap[c] ? idle_heap[c] : loaded_heap[c];
    const double scratch = peak - (cfgs[c].cheaper ? per_cheaper : per_default);
    if (scratch > scratch_max) scratch_max = scratch;
    printf("| %-26s | %6.1fx | %7.1fx | %13.0f | %11.0f |\n", cfg_names[c], idle[c],
           loaded[c], peak / 1024.0, scratch / 1024.0);
  }
  printf("\nrenderer thread (read back): %s; load thread (read back): %s\n\n",
         idle_job.sched, la.running > 0 ? la.sched : "FAILED");

  printf("## memory\n\n");
  printf("- stretcher live heap per mono instance: cheaper %.0f KiB, default %.0f KiB\n",
         per_cheaper / 1024.0, per_default / 1024.0);
  printf("- render worker scratch (peak C++ heap during a render minus one "
         "stretcher), worst recipe: %.0f KiB\n",
         scratch_max / 1024.0);
  printf("- rendered entry: %d frames x 4 = %.1f MiB per mono lane (the "
         "caller's buffer, outside the scratch)\n",
         frames, (double)frames * 4.0 / 1048576.0);
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
    judge("render worker scratch under 1 MiB", scratch_max / 1048576.0, 1.0, 1);
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
