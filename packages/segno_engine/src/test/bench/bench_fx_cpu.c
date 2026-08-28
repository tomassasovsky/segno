/*
 * bench_fx_cpu.c — per-callback CPU cost of le_engine_process, for the two
 * defects the #897 engine audit measured.
 *
 * NOT part of the test gate. Build and run it with ./bench_fx_cpu.sh.
 *
 * WHY: the appliance now runs 32-frame periods at 96 kHz — a 333 us callback
 * deadline. Two per-frame costs the audit flagged only show up as a
 * DISTRIBUTION, not a mean:
 *
 *   oct1 / oct4   Every phase-vocoder octaver instance seeded its hop counter
 *                 to 0 and advances one per sample, so before the stagger fix
 *                 they all ran their four length-1024 FFTs on the SAME sample
 *                 index. One block in eight carried the whole pile. The mean
 *                 hides that; p50 vs p99 is the whole finding, which is why
 *                 this bench reports both.
 *   lanes1/lanes8 Empty, silent lanes were snapshotted and run in full every
 *                 frame. The cost is linear in lanes, so the lanes8 - lanes1
 *                 delta is what 49 lanes whose only job is adding zero cost.
 *
 * Modes:
 *   oct1        1 octaver, slot 0 of monitor input 0 (full wet, PV mode).
 *   oct4        4 octavers, slots 0..3 of ONE chain (monitor input 0).
 *   oct4lanes   4 octavers, slot 0 of lane 0 on four DIFFERENT tracks — the
 *               cross-chain shape, which a slot-only stagger cannot spread.
 *   lanes1      1 playing track + 7 EMPTY tracks x 1 lane.
 *   lanes8      1 playing track + 7 EMPTY tracks x 8 lanes.
 *   all         every mode above, in order.
 *
 * Usage: ./bench_fx_cpu.sh [--blocks N] [--mode all|oct1|oct4|...]
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segno_engine_api.h"

#define BENCH_SR 96000
#define BENCH_BLOCK 32
#define BENCH_CH 2

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

static int cmp_double(const void* a, const void* b) {
  const double x = *(const double*)a;
  const double y = *(const double*)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

/* Drives `blocks` callbacks of BENCH_BLOCK frames through `e`, timing each one,
 * and prints mean / p50 / p99 / max in microseconds. `warm` leading blocks are
 * run but discarded (octaver warmup, chain ramp-in, cache settling). */
static void run_mode(const char* name, le_engine* e, int blocks, int warm) {
  const int total = blocks + warm;
  float in[BENCH_BLOCK * BENCH_CH];
  float out[BENCH_BLOCK * BENCH_CH];
  double* us = (double*)malloc(sizeof(double) * (size_t)blocks);
  double phase = 0.0;
  int kept = 0;
  double sum = 0.0;
  for (int b = 0; b < total; ++b) {
    for (int i = 0; i < BENCH_BLOCK; ++i) {
      const float s = 0.4f * sinf((float)(2.0 * 3.14159265358979 * phase));
      phase += 220.0 / (double)BENCH_SR;
      if (phase >= 1.0) phase -= 1.0;
      for (int c = 0; c < BENCH_CH; ++c) in[i * BENCH_CH + c] = s;
    }
    const double t0 = now_us();
    le_engine_process(e, out, in, (uint32_t)BENCH_BLOCK);
    const double t1 = now_us();
    if (b >= warm) {
      us[kept] = t1 - t0;
      sum += us[kept];
      ++kept;
    }
  }
  qsort(us, (size_t)kept, sizeof(double), cmp_double);
  const double deadline = 1e6 * (double)BENCH_BLOCK / (double)BENCH_SR;
  const double p99 = us[(int)((double)kept * 0.99)];
  printf("%-10s mean %7.2f  p50 %7.2f  p99 %7.2f  max %8.2f us"
         "   (deadline %.0f us, p99 = %.0f%%)\n",
         name, sum / (double)kept, us[kept / 2], p99, us[kept - 1], deadline,
         100.0 * p99 / deadline);
  free(us);
}

static le_engine* fresh(void) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, BENCH_SR, BENCH_CH, BENCH_CH, BENCH_SR * 4);
  return e;
}

/* `count` full-wet PV octavers in chain slots 0..count-1 of monitor input 0. */
static void arm_monitor_octavers(le_engine* e, int count) {
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x3);
  for (int s = 0; s < count; ++s) {
    le_engine_set_monitor_input_fx(e, 0, s, LE_FX_OCTAVER);
    le_engine_set_monitor_input_fx_param(e, 0, s, 0, 0.75f); /* octave up */
    le_engine_set_monitor_input_fx_param(e, 0, s, 1, 1.0f);  /* tone open */
    le_engine_set_monitor_input_fx_param(e, 0, s, 2, 1.0f);  /* full wet */
    le_engine_set_monitor_input_fx_param(e, 0, s, 3, 0.0f);  /* PV mode */
  }
  le_engine_set_monitor_input_fx_count(e, 0, count);
}

/* Records then plays track 0 so exactly one track is PLAYING; every other
 * track stays EMPTY. `lanes` sets the lane count on the empty tracks. */
static void arm_one_playing_track(le_engine* e, int lanes) {
  float in[BENCH_BLOCK * BENCH_CH];
  float out[BENCH_BLOCK * BENCH_CH];
  for (int i = 0; i < BENCH_BLOCK * BENCH_CH; ++i) in[i] = 0.25f;
  le_engine_record(e, 0);
  for (int b = 0; b < 400; ++b) le_engine_process(e, out, in, BENCH_BLOCK);
  le_engine_record(e, 0); /* second press: ends the defining take */
  for (int b = 0; b < 40; ++b) le_engine_process(e, out, in, BENCH_BLOCK);
  le_engine_play(e, 0);
  for (int b = 0; b < 40; ++b) le_engine_process(e, out, in, BENCH_BLOCK);
  le_track_snapshot ts;
  le_engine_get_track(e, 0, &ts);
  if (ts.state != LE_TRACK_PLAYING) {
    printf("  !! track 0 state is %d, wanted PLAYING(%d)\n", (int)ts.state,
           (int)LE_TRACK_PLAYING);
  }
  for (int t = 1; t < 8; ++t) le_engine_set_lane_count(e, t, lanes);
}

int main(int argc, char** argv) {
  int blocks = 20000;
  const char* mode = "all";
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--blocks") == 0 && i + 1 < argc) {
      blocks = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
      mode = argv[++i];
    }
  }
  const int all = strcmp(mode, "all") == 0;
  printf("bench_fx_cpu: %d Hz, %d-frame blocks, %d timed blocks/mode\n",
         BENCH_SR, BENCH_BLOCK, blocks);

  if (all || strcmp(mode, "oct1") == 0) {
    le_engine* e = fresh();
    arm_monitor_octavers(e, 1);
    run_mode("oct1", e, blocks, 2000);
    le_engine_destroy(e);
  }
  if (all || strcmp(mode, "oct4") == 0) {
    le_engine* e = fresh();
    arm_monitor_octavers(e, 4);
    run_mode("oct4", e, blocks, 2000);
    le_engine_destroy(e);
  }
  if (all || strcmp(mode, "oct4lanes") == 0) {
    le_engine* e = fresh();
    for (int t = 0; t < 4; ++t) {
      le_engine_set_lane_fx(e, t, 0, 0, LE_FX_OCTAVER);
      le_engine_set_lane_fx_param(e, t, 0, 0, 0, 0.75f);
      le_engine_set_lane_fx_param(e, t, 0, 0, 1, 1.0f);
      le_engine_set_lane_fx_param(e, t, 0, 0, 2, 1.0f);
      le_engine_set_lane_fx_param(e, t, 0, 0, 3, 0.0f);
      le_engine_set_lane_fx_count(e, t, 0, 1);
    }
    run_mode("oct4lanes", e, blocks, 2000);
    le_engine_destroy(e);
  }
  if (all || strcmp(mode, "lanes1") == 0) {
    le_engine* e = fresh();
    arm_one_playing_track(e, 1);
    run_mode("lanes1", e, blocks, 2000);
    le_engine_destroy(e);
  }
  if (all || strcmp(mode, "lanes8") == 0) {
    le_engine* e = fresh();
    arm_one_playing_track(e, 8);
    run_mode("lanes8", e, blocks, 2000);
    le_engine_destroy(e);
  }
  return 0;
}
