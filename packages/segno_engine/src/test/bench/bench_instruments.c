/* bench_instruments.c — the #1197 Part 1 CPU spike (instrument voices).
 *
 * Standalone harness built by bench_instruments.sh against the real engine
 * sources and the instrument voice TUs (synth_voice.c, synth_patch.c). NOT
 * part of the test gate; the native-tests CI job smoke-runs it and
 * native-bench-arm64 asserts the proxy thresholds. Numbers and verdicts live
 * in docs/plan/2026-10-06-instruments-spike-findings.md.
 *
 * Every timed figure is one le_synth_render call of --period frames (the
 * callback's share of the work), per period, at --rate:
 *   patches   each of the 19 patches at 8 voices, over --patch-seconds; the
 *             costliest (highest mean) is the patch the pool scenarios use.
 *             Drum hits end by themselves, so their voices are re-struck
 *             every period to keep 8 sounding (a continuous roll).
 *   voices    the costliest patch, then a mixed set (eight instruments, one
 *             per family plus a pad, voices spread across them), at 8, 16,
 *             32 and 64 voices of a 64-voice pool, over --seconds.
 *   burst     32 note-ons plus the render of the block they land in, timed
 *             together, repeated: on an idle pool, and on a full 32-voice
 *             pool (32 steals, 32 fades).
 *   engine    le_engine_process with 8 tracks x 8 lanes PLAYING (the
 *             pitch/time baseline), alone and with 32 voices of the costliest
 *             patch rendered in the same period (informational).
 *   joint     the whole worst case in one period, judged on its tail: the
 *             8 x 8 baseline with eight live inputs monitored through one
 *             reverb each, the pitch/time read head at 8x over the 64 lanes
 *             (the Speed work its plan adds to the mixer), and 32 voices of
 *             the costliest patch. Reported with p99.9 and the count of
 *             periods over the budget ("late"), and run a second time
 *             without the voices, so the instruments' share of the joint
 *             period is measured on its own.
 *
 * Scheduling: SCHED_FIFO (BENCH_RT_PRIO, below the app's audio thread) around
 * the timed loops only. Thresholds (--assert): the Pi 5 set, refused on
 * anything but a Cortex-A76 unless --proxy, which asserts the arm64 CI proxy
 * set (p50 at half the Pi percentages). --smoke: short runs, no assertions.
 *
 * The proxy gates the instruments' share of the joint period, not its total
 * (plan D2, "the proxy gate"): the total is mostly the looper, the monitors
 * and the read head, whose cost moves with every trunk change, and the CI
 * runner is not the appliance (it may refuse SCHED_FIFO). The total is
 * still printed against its old proxy reference; the Pi set gates it.
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
#include "synth_voice.h"

#include "bench_common.h"

static void usage(void) {
  fprintf(stderr,
          "bench_instruments [--smoke] [--seconds N] [--patch-seconds N] "
          "[--loop-seconds N] [--rate HZ] [--period FRAMES] [--budget-us N] "
          "[--assert] [--proxy]\n");
}

static le_synth g_synth;
static float g_bus_store[LE_SYNTH_MAX_INSTRUMENTS][8192];
static float* g_bus[LE_SYNTH_MAX_INSTRUMENTS];

static const int32_t k_drum_notes[] = {35, 36, 38, 39, 40, 42, 44};

/* Keeps `target` voices sounding on `inst`, striking new notes as needed. */
static void keep_voices(le_synth* s, int32_t inst, int32_t target,
                        uint32_t* origin) {
  const int drums =
      le_synth_patch_at(s->inst[inst].patch)->family == LE_SYNTH_DRUMS;
  int guard = 0;
  while (le_synth_active(s, inst) < target && guard++ < 2 * target) {
    const uint32_t o = ++*origin;
    const int32_t note = drums ? k_drum_notes[o % 7] : 48 + (int32_t)(o * 5 % 37);
    le_synth_note_on(s, inst, o, note, 100);
  }
}

typedef struct {
  int32_t patches[LE_SYNTH_MAX_INSTRUMENTS];
  int32_t n_inst;
} voice_set;

/* Times one le_synth_render per period with `voices` spread over the set. */
static stats run_voices(const bench_opts* o, const voice_set* set,
                        int32_t voices, int32_t pool, double seconds) {
  le_synth_init(&g_synth, o->rate, pool, 1);
  for (int32_t i = 0; i < set->n_inst; ++i) {
    le_synth_set_instrument(&g_synth, i, set->patches[i]);
  }
  uint32_t origin = 0;
  int32_t per[LE_SYNTH_MAX_INSTRUMENTS] = {0};
  for (int32_t v = 0; v < voices; ++v) per[v % set->n_inst]++;
  for (int32_t i = 0; i < set->n_inst; ++i) keep_voices(&g_synth, i, per[i], &origin);
  for (int k = 0; k < 50; ++k) {
    le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
  }
  const size_t periods = (size_t)(seconds * o->rate / o->period);
  double* t = (double*)malloc(sizeof(double) * (periods ? periods : 1));
  rt_enter();
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    for (int32_t i = 0; i < set->n_inst; ++i) keep_voices(&g_synth, i, per[i], &origin);
    le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
    t[k] = now_us() - a;
  }
  rt_leave();
  const stats s = stats_of(t, periods);
  free(t);
  return s;
}

/* `notes` note-ons plus their block; `prefill` voices already held. */
static stats run_burst(const bench_opts* o, int32_t patch, int32_t notes,
                       int32_t prefill, size_t iterations) {
  double* t = (double*)malloc(sizeof(double) * iterations);
  const int drums = le_synth_patch_at(patch)->family == LE_SYNTH_DRUMS;
  rt_enter();
  for (size_t k = 0; k < iterations; ++k) {
    le_synth_init(&g_synth, o->rate, LE_SYNTH_DEFAULT_VOICES, (uint32_t)k);
    le_synth_set_instrument(&g_synth, 0, patch);
    for (int32_t n = 0; n < prefill; ++n) {
      le_synth_note_on(&g_synth, 0, 1000u + (uint32_t)n,
                       drums ? k_drum_notes[n % 7] : 37 + n * 2, 90);
    }
    if (prefill > 0) {
      le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
    }
    const double a = now_us();
    for (int32_t n = 0; n < notes; ++n) {
      le_synth_note_on(&g_synth, 0, (uint32_t)n + 1,
                       drums ? k_drum_notes[n % 7] : 36 + n * 2, 110);
    }
    le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
    t[k] = now_us() - a;
  }
  rt_leave();
  const stats s = stats_of(t, iterations);
  free(t);
  return s;
}

/* The baseline rig with `voices` of `patch` rendered in the same period. */
static stats run_engine(const bench_opts* o, int32_t patch, int32_t voices,
                        const float* src, int32_t frames) {
  rig r;
  if (!rig_create(&r, o, 8, src, frames)) {
    fprintf(stderr, "engine rig failed\n");
    exit(3);
  }
  le_synth_init(&g_synth, o->rate, LE_SYNTH_DEFAULT_VOICES, 1);
  le_synth_set_instrument(&g_synth, 0, patch);
  uint32_t origin = 0;
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* t = (double*)malloc(sizeof(double) * (periods ? periods : 1));
  le_snapshot* snap = (le_snapshot*)calloc(1, sizeof(le_snapshot));
  rt_enter();
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    le_engine_process(r.e, r.out, r.in, (uint32_t)o->period);
    keep_voices(&g_synth, 0, voices, &origin);
    le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
    t[k] = now_us() - a;
    if ((k & 63) == 0) le_engine_get_snapshot(r.e, snap);
  }
  rt_leave();
  free(snap);
  const stats s = stats_of(t, periods);
  free(t);
  rig_destroy(&r);
  return s;
}

/* The joint worst case: everything the period may have to carry at once. */
static stats run_joint(const bench_opts* o, int32_t patch, int32_t voices,
                       const float* src, int32_t frames) {
  enum { kInputs = 8, kLanesPerTrack = 8 };
  rig r;
  if (!rig_create_io(&r, o, kLanesPerTrack, src, frames, kInputs)) {
    fprintf(stderr, "joint rig failed\n");
    exit(3);
  }
  for (int32_t c = 0; c < kInputs; ++c) {
    if (le_engine_set_monitor_input_fx(r.e, c, 0, LE_FX_REVERB) != LE_OK ||
        le_engine_set_monitor_input_fx_count(r.e, c, 1) != LE_OK ||
        le_engine_set_monitor_input(r.e, c, 1) != LE_OK) {
      fprintf(stderr, "joint monitor %d failed\n", c);
      exit(3);
    }
  }
  for (int k = 0; k < 50; ++k) le_engine_process(r.e, r.out, r.in, (uint32_t)o->period);
  /* the read head reads one copy per track (8 x frames floats), each lane of
   * a track the same copy: the arithmetic is the plan's, the cache footprint
   * an eighth of eight distinct lanes */
  float* copies[LE_MAX_TRACKS];
  float* lanes[LE_MAX_TRACKS * kLanesPerTrack];
  le_read_head heads[LE_MAX_TRACKS];
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    copies[t] = (float*)malloc(sizeof(float) * (size_t)frames);
    memcpy(copies[t], src, sizeof(float) * (size_t)frames);
    for (int l = 0; l < kLanesPerTrack; ++l) lanes[t * kLanesPerTrack + l] = copies[t];
    heads[t].reversed = 0;
    heads[t].origin = (double)(t * 977 % frames);
    heads[t].rate = 8.0;
  }
  float* acc = (float*)calloc((size_t)o->period, sizeof(float));
  le_synth_init(&g_synth, o->rate, LE_SYNTH_DEFAULT_VOICES, 1);
  le_synth_set_instrument(&g_synth, 0, patch);
  uint32_t origin = 0;
  const size_t periods = (size_t)(o->seconds * o->rate / o->period);
  double* t = (double*)malloc(sizeof(double) * (periods ? periods : 1));
  le_snapshot* snap = (le_snapshot*)calloc(1, sizeof(le_snapshot));
  int64_t base = 0;
  rt_enter();
  for (size_t k = 0; k < periods; ++k) {
    const double a = now_us();
    le_engine_process(r.e, r.out, r.in, (uint32_t)o->period);
    head_period(heads, lanes, kLanesPerTrack, frames, base, o->period, 8.0, acc);
    if (voices > 0) {
      keep_voices(&g_synth, 0, voices, &origin);
      le_synth_render(&g_synth, g_bus, LE_SYNTH_MAX_INSTRUMENTS, o->period);
    }
    t[k] = now_us() - a;
    base += o->period;
    g_sink = acc[(k * 7) % (size_t)o->period];
    if ((k & 63) == 0) le_engine_get_snapshot(r.e, snap);
  }
  rt_leave();
  free(snap);
  free(acc);
  for (int i = 0; i < LE_MAX_TRACKS; ++i) free(copies[i]);
  const stats s = stats_of(t, periods);
  free(t);
  rig_destroy(&r);
  return s;
}

int main(int argc, char** argv) {
  bench_opts o = {60.0, 30.0, 96000, 64, 0.0, 0, 0, 0};
  double patch_seconds = 5.0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) o.smoke = 1;
    else if (!strcmp(argv[i], "--assert")) o.do_assert = 1;
    else if (!strcmp(argv[i], "--proxy")) o.proxy = 1;
    else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) o.seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--patch-seconds") && i + 1 < argc) patch_seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--loop-seconds") && i + 1 < argc) o.loop_seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--rate") && i + 1 < argc) o.rate = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--period") && i + 1 < argc) o.period = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--budget-us") && i + 1 < argc) o.budget_us = atof(argv[++i]);
    else { usage(); return 2; }
  }
  if (o.smoke) {
    o.seconds = 1.0;
    o.loop_seconds = 2.0;
    patch_seconds = 0.25;
    o.do_assert = 0;
  }
  if (o.period < 1 || o.period > 8192 || o.rate < 8000) {
    usage();
    return 2;
  }
  if (o.budget_us <= 0) o.budget_us = 1e6 * o.period / o.rate;
  g_budget_us = o.budget_us;
  for (int i = 0; i < LE_SYNTH_MAX_INSTRUMENTS; ++i) g_bus[i] = g_bus_store[i];
  detect_cpu();
  if (o.do_assert && !o.proxy && g_cpu_part != 0xd0b) {
    fprintf(stderr,
            "--assert carries the Pi 5 (Cortex-A76) thresholds; this is %s. "
            "Use --assert --proxy for the arm64 CI proxy set.\n",
            g_cpu_name);
    return 2;
  }
  rt_enter();
  rt_leave();

  printf("# bench_instruments\n\n");
  printf("- CPU: %s\n- timed loops: %s, held only for the loop\n", g_cpu_name,
         g_timed_sched);
  printf("- rate %d Hz, period %d frames, budget %.1f us, %.0f s per pool "
         "scenario, %.2f s per patch%s\n",
         o.rate, o.period, o.budget_us, o.seconds, patch_seconds,
         o.smoke ? " (smoke)" : "");
  printf("- le_synth state: %zu bytes; default pool %d voices, %d fade slots\n\n",
         sizeof(le_synth), LE_SYNTH_DEFAULT_VOICES, LE_SYNTH_FADE_SLOTS);

  /* patches */
  printf("## patches (8 voices each, one le_synth_render per period)\n\n");
  print_header();
  int32_t costliest = 0;
  double costliest_mean = -1.0;
  for (int32_t p = 0; p < LE_SYNTH_PATCHES; ++p) {
    const voice_set one = {{p}, 1};
    const stats s = run_voices(&o, &one, 8, LE_SYNTH_MAX_VOICES, patch_seconds);
    print_row(le_synth_patch_at(p)->id, s);
    if (s.mean > costliest_mean) {
      costliest_mean = s.mean;
      costliest = p;
    }
  }
  printf("\ncostliest patch: %s\n\n", le_synth_patch_at(costliest)->id);

  /* voices */
  printf("## voices (64-voice pool)\n\n");
  print_tail_header();
  static const int32_t counts[] = {8, 16, 32, 64};
  stats worst[4], mixed[4];
  const voice_set cost = {{costliest}, 1};
  voice_set mix = {{0}, 8};
  static const char* mix_ids[8] = {"piano", "organ", "lead", "synth-bass",
                                   "strings", "drums", "vibes", "pad"};
  for (int i = 0; i < 8; ++i) mix.patches[i] = le_synth_patch_find(mix_ids[i]);
  for (int c = 0; c < 4; ++c) {
    char label[64];
    worst[c] = run_voices(&o, &cost, counts[c], LE_SYNTH_MAX_VOICES, o.seconds);
    snprintf(label, sizeof(label), "%s x %d", le_synth_patch_at(costliest)->id,
             counts[c]);
    print_tail_row(label, worst[c]);
  }
  for (int c = 0; c < 4; ++c) {
    char label[64];
    mixed[c] = run_voices(&o, &mix, counts[c], LE_SYNTH_MAX_VOICES, o.seconds);
    snprintf(label, sizeof(label), "mixed set x %d", counts[c]);
    print_tail_row(label, mixed[c]);
  }
  printf("\n");

  /* burst */
  printf("## burst (32 note-ons + the block they land in)\n\n");
  print_tail_header();
  size_t iterations = (size_t)(o.seconds * o.rate / o.period / 8);
  if (iterations < 200) iterations = 200;
  if (iterations > 20000) iterations = 20000;
  const stats burst_idle = run_burst(&o, costliest, 32, 0, iterations);
  print_tail_row("32-note burst, idle pool", burst_idle);
  const stats burst_full = run_burst(&o, costliest, 32, 32, iterations);
  print_tail_row("32-note burst, full pool", burst_full);
  const stats burst = burst_full.p999 > burst_idle.p999 ? burst_full : burst_idle;
  printf("\n");

  /* engine */
  printf("## engine (le_engine_process, 8 tracks x 8 lanes PLAYING; informational)\n\n");
  print_header();
  const int32_t frames = (int32_t)(o.loop_seconds * o.rate);
  float* src = make_source(frames, o.rate);
  const stats base = scenario_baseline(&o, 8, src, frames);
  print_row("8 x 8 lanes", base);
  const stats with = run_engine(&o, costliest, 32, src, frames);
  print_row("8 x 8 lanes + 32 voices", with);
  printf("\n## joint (8 x 8 lanes + 8 monitored inputs with reverb + read head 8x + 32 voices)\n\n");
  print_tail_header();
  const stats joint_base = run_joint(&o, costliest, 0, src, frames);
  print_tail_row("joint without instruments", joint_base);
  const stats joint = run_joint(&o, costliest, 32, src, frames);
  print_tail_row("joint worst case", joint);
  const double share_p50 = joint.p50 - joint_base.p50;
  printf("\n- instruments' share of the joint period, p50: %.1f us (%.1f%%)\n",
         share_p50, 100.0 * share_p50 / g_budget_us);
  free(src);
  printf("\n- peak RSS: %.0f MiB\n\n", peak_rss_bytes() / 1048576.0);

  /* the higher of the costliest-patch and mixed-set figures at each count */
  const double p999_32 = worst[2].p999 > mixed[2].p999 ? worst[2].p999 : mixed[2].p999;
  const double p999_64 = worst[3].p999 > mixed[3].p999 ? worst[3].p999 : mixed[3].p999;
  const double p50_32 = worst[2].p50 > mixed[2].p50 ? worst[2].p50 : mixed[2].p50;
  const double p50_64 = worst[3].p50 > mixed[3].p50 ? worst[3].p50 : mixed[3].p50;
  if (o.do_assert) {
    if (o.proxy) {
      judge("32 voices p50 <= 7.5% of period", 100.0 * p50_32 / g_budget_us, 7.5, 1);
      judge("64 voices p50 <= 15% of period", 100.0 * p50_64 / g_budget_us, 15.0, 1);
      judge("32-note burst p50 <= 10% of period", 100.0 * burst.p50 / g_budget_us, 10.0, 1);
      judge("joint instruments' share p50 <= 7.5% of period",
            100.0 * share_p50 / g_budget_us, 7.5, 1);
    } else {
      judge("32 voices p99.9 <= 15% of period", 100.0 * p999_32 / g_budget_us, 15.0, 1);
      judge("64 voices p99.9 <= 30% of period", 100.0 * p999_64 / g_budget_us, 30.0, 1);
      judge("32-note burst p99.9 <= 20% of period", 100.0 * burst.p999 / g_budget_us, 20.0, 1);
      judge("joint worst case p99.9 <= 75% of period", 100.0 * joint.p999 / g_budget_us, 75.0, 1);
      judge("joint worst case: no period over the budget", (double)joint.over, 0.0, 1);
    }
    printf("## verdict (%s thresholds)\n\n", o.proxy ? "arm64 proxy" : "Pi 5");
    int failed = 0;
    for (int i = 0; i < g_nverdicts; ++i) {
      printf("- %s: %s (%.2f vs %.2f)\n", g_verdicts[i].pass ? "PASS" : "FAIL",
             g_verdicts[i].what, g_verdicts[i].value, g_verdicts[i].limit);
      if (!g_verdicts[i].pass) failed++;
    }
    if (!o.proxy) {
      /* the pool size the plan's D2 takes from this run */
      printf("\nvoice pool: %d (64 when the 64-voice threshold passes)\n",
             g_verdicts[1].pass ? 64 : LE_SYNTH_DEFAULT_VOICES);
    }
    if (o.proxy) {
      /* not gated on the runner (see the header); the Pi set gates it */
      printf("- info: joint worst case p50 %.2f%% of period (old proxy reference "
             "37.50, not gated)\n", 100.0 * joint.p50 / g_budget_us);
    }
    printf("\n%s\n", failed ? "THRESHOLDS FAILED" : "ALL THRESHOLDS MET");
    return failed ? 1 : 0;
  }
  printf("(no assertions requested)\n");
  return 0;
}
