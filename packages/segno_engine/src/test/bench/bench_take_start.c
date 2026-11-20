/*
 * bench_take_start.c — what starting and closing a take costs the audio
 * callback (#1914).
 *
 * NOT part of the test gate. Build and run it with ./bench_take_start.sh; it
 * needs no sound card.
 *
 * In the app, the period a take starts in ran 840-1620 us on the console
 * (Ed's Rack on 4 inputs + 6 tracks), its first frame alone 190-650 us, and
 * every later block's first frame stayed 20-90 us slower for as long as the
 * take recorded. This runs the engine on its own, a block at a time: six
 * playing tracks of two lanes, Ed's Rack on monitored input 0 (so the take
 * records a heard image; --racks2 on input 1 too, --no-racks on none),
 * the console's record offset (--offset, 641 frames), then a take on track 6's two
 * lanes from inputs 0 and 1, closed after --record seconds. It prints the
 * blocks before the take, the slowest blocks from its start, the blocks
 * while it records, and the blocks after it closes.
 *
 *   ./bench_take_start.sh                    # 48 kHz / 32, 2 s takes
 *   ./bench_take_start.sh --takes 8 --record 1
 */
#define _GNU_SOURCE 1

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "engine_fx.h"
#include "segno_engine_api.h"

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

static int cmp_double(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

static double pct(double* v, int n, double q) {
  double* c = (double*)malloc(sizeof(double) * (size_t)n);
  memcpy(c, v, sizeof(double) * (size_t)n);
  qsort(c, (size_t)n, sizeof(double), cmp_double);
  const double r = c[(int)(q / 100.0 * (n - 1))];
  free(c);
  return r;
}

/* Ed's Rack (bench_fx_parallel's). */
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
    r->type[s] = kinds[s];
    r->slot_enabled[s] = 1;
    r->level[s] = 1.0f;
    le_fx_defaults(kinds[s], r->params[s]);
  }
}

int main(int argc, char** argv) {
  int32_t rate = 48000, period = 32;
  double record_s = 2.0;
  int takes = 4, racks = 1, offset = 641, workers = 0, track_racks = 0;
  int image = 0, lane_fx = 0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--rate") && i + 1 < argc) rate = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--period") && i + 1 < argc) period = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--record") && i + 1 < argc) record_s = atof(argv[++i]);
    else if (!strcmp(argv[i], "--takes") && i + 1 < argc) takes = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--no-racks")) racks = 0;
    else if (!strcmp(argv[i], "--racks2")) racks = 2;
    else if (!strcmp(argv[i], "--offset") && i + 1 < argc) offset = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--workers") && i + 1 < argc) workers = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--image")) image = 1;
    else if (!strcmp(argv[i], "--lane-fx")) image = lane_fx = 1;
    else if (!strcmp(argv[i], "--track-racks") && i + 1 < argc) track_racks = atoi(argv[++i]);
    else {
      fprintf(stderr, "usage: %s [--rate HZ] [--period N] [--record S] "
                      "[--takes N] [--no-racks | --racks2] [--offset FRAMES] "
                      "[--workers N] [--track-racks N] [--image | --lane-fx]\n",
              argv[0]);
      return 2;
    }
  }
  const int32_t loop = rate * 2;
  float* src = (float*)calloc((size_t)loop, sizeof(float));
  for (int32_t i = 0; i < loop; ++i) {
    src[i] = 0.2f * (float)sin(2.0 * 3.14159265358979 * 110.0 * i / rate);
  }
  le_engine* e = le_engine_create();
  if (e == NULL || le_engine_configure(e, rate, 2, 2, rate * 60) != LE_OK) {
    fprintf(stderr, "engine failed\n");
    return 3;
  }
  for (int32_t t = 0; t < 6; ++t) {
    for (int32_t l = 0; l < 2; ++l) {
      if (le_engine_import_track_lane(e, t, l, src, loop) != LE_OK) return 3;
    }
  }
  if (le_engine_commit_session(e, loop, 0) != LE_OK) return 3;
  float* in = (float*)calloc((size_t)period * 2, sizeof(float));
  float* out = (float*)calloc((size_t)period * 2, sizeof(float));
  le_engine_process(e, out, in, 0);
  for (int32_t t = 0; t < 6; ++t) le_engine_play(e, t);
  if (racks) {
    le_fx_recipe rec;
    eds_rack(&rec);
    for (int32_t c = 0; c < racks; ++c) {
      le_engine_set_monitor_input(e, c, 1);
      le_engine_set_monitor_input_output(e, c, 0x3);
      le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, c, 0, 1, &rec);
    }
  }
  /* Ed's Rack on tracks 0..N-1's own chains (the recording track is 6),
   * and the effects workers on cores 1 and 2 beside this thread's 3, as the
   * console runs them. */
  if (track_racks > 0) {
    le_fx_recipe rec;
    eds_rack(&rec);
    for (int32_t t = 0; t < track_racks && t < 8; ++t) {
      le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, t, 0, 1, &rec);
    }
  }
  if (workers > 0) {
    const int32_t cores[3] = {3, 1, 2};
    if (le_engine_set_fx_workers(e, workers, cores) != LE_OK) {
      fprintf(stderr, "workers refused\n");
    }
  }
  /* The console's measured record offset (latency_offset, 641 frames at
   * 48 kHz / 32 there): a take starts that many frames back. */
  le_engine_set_record_offset(e, offset);
  le_engine_set_lane_input(e, 6, 0, 0);
  le_engine_set_lane_input(e, 6, 1, 1);
  le_snapshot* snap = (le_snapshot*)calloc(1, sizeof(le_snapshot));
  uint64_t frame = 0;
  /* One block of the input (the bass line on both inputs), timed. */
  #define BLOCK(dst)                                                     \
    do {                                                                 \
      for (int32_t f = 0; f < period; ++f) {                             \
        const float x = src[(frame + (uint64_t)f) % (uint64_t)loop];     \
        in[2 * f] = x;                                                   \
        in[2 * f + 1] = x;                                               \
      }                                                                  \
      const double a = now_us();                                         \
      le_engine_process(e, out, in, (uint32_t)period);                   \
      (dst) = now_us() - a;                                              \
      frame += (uint64_t)period;                                         \
    } while (0)
  const int warm = rate / period;               /* a second */
  const int rec_n = (int)(record_s * rate / period);
  const int after_n = rate / period;            /* a second after */
  double* base = (double*)malloc(sizeof(double) * (size_t)warm);
  double* rec = (double*)malloc(sizeof(double) * (size_t)rec_n);
  double* after = (double*)malloc(sizeof(double) * (size_t)after_n);
  double dummy;
  for (int k = 0; k < 4 * warm; ++k) BLOCK(dummy); /* settle the racks */
  printf("bench_take_start: %d Hz / %d, Ed's Rack on %d inputs and %d "
         "tracks, %d workers, record offset %d, %d takes of %.1f s on track "
         "6%s\n",
         rate, period, racks, track_racks, workers, offset, takes, record_s,
         image ? ", each recording its heard image" : "");
  for (int n = 0; n < takes; ++n) {
    for (int k = 0; k < warm; ++k) {
      BLOCK(base[k]);
      if (k % 16 == 0) le_engine_get_snapshot(e, snap); /* the UI's poll */
    }
    if (image) {
      /* As the app arms a take: both lanes at unity, centred, recording
       * their heard image (#1713). */
      le_record_image im;
      memset(&im, 0, sizeof(im));
      im.revision = (uint32_t)(n + 1);
      im.lane_mask = 0x3u;
      im.gain[0] = im.gain[1] = 1.0f;
      im.heard_mask = 0x3u;
      /* --lane-fx: each lane's own chain frozen with the arm, Ed's Rack. */
      le_fx_recipe lanes[LE_MAX_LANES];
      if (lane_fx) {
        for (int l = 0; l < LE_MAX_LANES; ++l) eds_rack(&lanes[l]);
        im.fx_lane_mask = 0x3u;
        im.lane_fx = lanes;
      }
      le_engine_record_with_image(e, 6, &im);
    } else {
      le_engine_record(e, 6);
    }
    for (int k = 0; k < rec_n; ++k) {
      BLOCK(rec[k]);
      if (k % 16 == 0) le_engine_get_snapshot(e, snap);
    }
    le_engine_record(e, 6); /* close: it plays */
    for (int k = 0; k < after_n; ++k) {
      BLOCK(after[k]);
      if (k % 16 == 0) le_engine_get_snapshot(e, snap);
    }
    printf("take %d: before p50 %.1f max %.1f | start: block 0 %.1f, 1 %.1f, "
           "2 %.1f | recording p50 %.1f p99 %.1f | close: block 0 %.1f, 1 "
           "%.1f | after p50 %.1f max %.1f us\n",
           n + 1, pct(base, warm, 50), pct(base, warm, 100), rec[0], rec[1],
           rec[2], pct(rec, rec_n, 50), pct(rec, rec_n, 99), after[0],
           after[1], pct(after, after_n, 50), pct(after, after_n, 100));
    le_engine_clear(e, 6);
    for (int k = 0; k < warm; ++k) BLOCK(dummy);
  }
  le_engine_destroy(e);
  return 0;
}
