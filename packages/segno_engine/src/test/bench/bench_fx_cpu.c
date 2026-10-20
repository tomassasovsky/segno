/*
 * bench_fx_cpu.c — what built-in effects cost the audio callback (#915).
 *
 * NOT part of the test gate. Build and run it with ./bench_fx_cpu.sh.
 *
 * WHY: a phase-vocoder octaver runs four length-1024 FFTs per channel once
 * every LE_PV_HOP (256) samples. At 96 kHz / 64 frames that is one callback in
 * four, so its cost is a TAIL, not a mean, and what matters is whether several
 * instances land their frames in the same callback. Before #915 every instance
 * reset its hop counter to 0, so a chain publish (which resets every slot it
 * carries) put all of a chain's octavers on one sample index; two stereo
 * octavers then missed the 667 us deadline on every heavy block on the console.
 *
 * Every scenario runs on a playing 8-track rig (bench_common.h) and publishes
 * its effects through le_engine_set_fx_recipe, the path the app uses, so the
 * resets happen exactly as they do live:
 *
 *   chain N   N octavers in one monitor chain, one publish.
 *   lanes N   one octaver on lane 0 of N tracks, N publishes in one block.
 *
 * Reported per scenario: p50 / p99 / p99.9 / max per callback, the callbacks
 * over the period's deadline, and the mean cost of the blocks starting in
 * each quarter of the octaver's hop, which is where the FFT work lands.
 *
 *   ./bench_fx_cpu.sh                      # 96 kHz / 64 frames, unpaced
 *   ./bench_fx_cpu.sh --paced              # paced to the period, like a device
 *   ./bench_fx_cpu.sh --smoke              # short runs (CI)
 *   bench_fx_cpu --paced --cpu 3           # on the console, off the audio core
 *
 * On the console, run it pinned away from the app's audio core; the timed
 * loops raise themselves to SCHED_FIFO BENCH_RT_PRIO (below the app's 80).
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

#include "segno_engine_api.h"
#include "engine_fx.h" /* LE_PV_HOP, LE_PV_STAGGER_QUARTER */
#include "bench_common.h"

/* The octaver's hop in quarters: each block is counted in the quarter its
 * first sample falls in, so the column shows where the FFT work lands at any
 * period. */
#define HOP LE_PV_HOP
#define PHASES (LE_PV_HOP / LE_PV_STAGGER_QUARTER)

static int g_paced;

/* An octaver recipe entry: one octave up, tone open, full wet, phase vocoder.
 * Full wet keeps the wet path (the FFTs) the whole output. */
static void octaver_entry(le_fx_recipe* r, int s) {
  r->type[s] = LE_FX_OCTAVER;
  r->slot_enabled[s] = 1;
  r->params[s][0] = 0.75f;
  r->params[s][1] = 1.0f;
  r->params[s][2] = 1.0f;
  r->params[s][3] = 0.0f;
  r->level[s] = 1.0f;
}

/* Times `blocks` callbacks after `warm` discarded ones. */
static stats time_blocks(rig* r, int blocks, int warm, double phase_mean[PHASES]) {
  double* us = (double*)malloc(sizeof(double) * (size_t)blocks);
  stats none;
  memset(&none, 0, sizeof(none));
  if (us == NULL) {
    fprintf(stderr, "out of memory for %d timings\n", blocks);
    for (int p = 0; p < PHASES; ++p) phase_mean[p] = 0.0;
    return none;
  }
  double phase_sum[PHASES] = {0};
  int phase_n[PHASES] = {0};
  const double step = g_budget_us; /* one period, in us */
  rt_enter();
  double next = now_us();
  int kept = 0;
  for (int b = 0; b < blocks + warm; ++b) {
    if (g_paced) {
      next += step;
      sleep_until_us(next);
    }
    const double t0 = now_us();
    le_engine_process(r->e, r->out, r->in, (uint32_t)r->period);
    const double dt = now_us() - t0;
    if (b >= warm) {
      us[kept++] = dt;
      const int q =
          (int)(((long long)b * r->period) % HOP) / (HOP / PHASES);
      phase_sum[q] += dt;
      phase_n[q]++;
    }
  }
  rt_leave();
  for (int p = 0; p < PHASES; ++p) {
    phase_mean[p] = phase_n[p] ? phase_sum[p] / phase_n[p] : 0.0;
  }
  stats s = stats_of(us, (size_t)kept);
  free(us);
  return s;
}

static void report(const char* label, stats s, const double ph[PHASES]) {
  printf("| %-18s | %8.1f | %8.1f | %8.1f | %8.1f | %5zu | %7.1f %7.1f %7.1f %7.1f |\n",
         label, s.p50, s.p99, s.p999, s.max, s.over, ph[0], ph[1], ph[2],
         ph[3]);
  fflush(stdout);
}

int main(int argc, char** argv) {
  bench_opts o;
  memset(&o, 0, sizeof(o));
  o.rate = 96000;
  o.period = 64;
  o.loop_seconds = 2.0;
  int blocks = 12000;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) {
      o.smoke = 1;
      blocks = 400;
    } else if (!strcmp(argv[i], "--paced")) {
      g_paced = 1;
    } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
      o.rate = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--period") && i + 1 < argc) {
      o.period = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) {
      blocks = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--cpu") && i + 1 < argc) {
      /* Pin to one core, so on the console the bench stays off the app's
       * audio core. Linux only. */
      const int cpu = atoi(argv[++i]);
#if defined(__linux__)
      cpu_set_t set;
      CPU_ZERO(&set);
      CPU_SET(cpu, &set);
      if (sched_setaffinity(0, sizeof(set), &set) != 0) perror("sched_setaffinity");
#else
      (void)cpu;
#endif
    } else {
      fprintf(stderr,
              "usage: %s [--smoke] [--paced] [--rate HZ] [--period FRAMES] "
              "[--blocks N] [--cpu N]\n",
              argv[0]);
      return 2;
    }
  }
  if (blocks < 100) blocks = 100;
  g_budget_us = 1e6 * (double)o.period / (double)o.rate;
  detect_cpu();
  const int32_t frames = (int32_t)(o.loop_seconds * o.rate);
  float* src = make_source(frames, o.rate);
  if (src == NULL) return 1;

  const int warm = 600;
  const int counts[] = {0, 1, 2, 4, 8};
  printf("bench_fx_cpu: %s, %d Hz, %d-frame periods (deadline %.1f us), "
         "%d timed blocks%s\n",
         g_cpu_name, o.rate, o.period, g_budget_us, blocks,
         g_paced ? ", paced" : "");
  printf("| scenario           |  p50 us |  p99 us | p99.9 us |  max us | late "
         "| phase 0..3 mean us               |\n");
  printf("|--------------------|---------|---------|----------|---------|------"
         "|-----------------------------------|\n");
  for (int mode = 0; mode < 2; ++mode) {
    for (size_t k = 0; k < sizeof(counts) / sizeof(counts[0]); ++k) {
      const int n = counts[k];
      if (mode == 1 && n == 0) continue;
      rig r;
      if (!rig_create_io(&r, &o, 1, src, frames, 2)) {
        fprintf(stderr, "rig failed\n");
        return 1;
      }
      if (le_engine_set_monitor_input(r.e, 0, 1) != LE_OK ||
          le_engine_set_monitor_input_output(r.e, 0, 0x3) != LE_OK) {
        fprintf(stderr, "monitor input 0 refused\n");
        return 1;
      }
      for (int32_t f = 0; f < o.period; ++f) {
        r.in[2 * f] = src[f];
        r.in[2 * f + 1] = src[f];
      }
      if (n > 0) {
        le_fx_recipe rec;
        memset(&rec, 0, sizeof(rec));
        rec.enabled = 1;
        if (mode == 0) {
          rec.count = n;
          for (int s = 0; s < n; ++s) octaver_entry(&rec, s);
          if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_MONITOR, 0, 0, 1, &rec) !=
              LE_OK) {
            fprintf(stderr, "monitor recipe refused\n");
            return 1;
          }
        } else {
          rec.count = 1;
          octaver_entry(&rec, 0);
          for (int t = 0; t < n; ++t) {
            if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_LANE, t, 0, 1, &rec) !=
                LE_OK) {
              fprintf(stderr, "lane recipe refused\n");
              return 1;
            }
          }
        }
      }
      double ph[PHASES];
      const stats s = time_blocks(&r, blocks, warm, ph);
      char label[32];
      snprintf(label, sizeof(label), "%s %d", mode == 0 ? "chain" : "lanes", n);
      report(label, s, ph);
      rig_destroy(&r);
    }
  }
  printf("timed loops ran at: %s\n", g_timed_sched);
  free(src);
  return 0;
}
