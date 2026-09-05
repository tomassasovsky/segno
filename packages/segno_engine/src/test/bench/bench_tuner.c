/*
 * bench_tuner.c — what the chromatic tuner costs the audio callback.
 *
 * NOT part of the test gate. Build and run it with ./bench_tuner.sh.
 *
 * WHY: the tuner analyses the armed input ON the audio thread, and the Tuner
 * face being open is an ordinary thing for a performer to do — so its cost is
 * not "a feature's cost", it is the callback's cost whenever anyone is tuning.
 * At 96 kHz a 32-frame period has a 333 us deadline and a missed deadline is an
 * audible click, so the question this bench answers is not "how fast is the
 * detector" but "what does arming it add to the callback, at the mean and at
 * the tail".
 *
 * That is why it reports p99 alongside the mean. The two defects this bench was
 * written to measure had opposite signatures and only one of them shows up in a
 * mean:
 *
 *   - the device-rate ring was a shifting FIFO — 8188 bytes memmoved EVERY
 *     frame — which is pure mean, constant, and independent of track count
 *     because it is not DSP;
 *   - the detection pass ran to completion inside one callback — ~184k serial
 *     double accumulates once every 64 blocks — which is pure tail: invisible
 *     in the mean, and the whole deadline in the block it lands in.
 *
 * Run it armed and unarmed at the same configuration and read the DELTA; the
 * absolute numbers only mean something on the machine that produced them. The
 * appliance's A76 is roughly 3-4x slower than a desktop core on this scalar
 * double code, so scale accordingly — or, better, run this bench there.
 *
 * The track/lane configurations exist to show that the tuner's delta does NOT
 * scale with the mix (it is per-input work, not per-track work); a delta that
 * grows with the track count would mean the cost is somewhere else.
 *
 *   ./bench_tuner.sh                          # the default sweep
 *   ./bench_tuner.sh --sr 96000 --frames 32   # the tightest shipped deadline
 *   ./bench_tuner.sh --tracks 4 --lanes 2 --blocks 200000
 */
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segno_engine_api.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* A block at 96 kHz / 32 frames costs single-digit microseconds, so a clock
 * that only ticks per microsecond quantizes the whole measurement — which is
 * exactly what macOS's CLOCK_MONOTONIC does here. CLOCK_UPTIME_RAW via
 * clock_gettime_nsec_np is the nanosecond one on Darwin; CLOCK_MONOTONIC_RAW
 * is its counterpart elsewhere. */
static uint64_t now_ns(void) {
#if defined(__APPLE__)
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec ts;
#if defined(CLOCK_MONOTONIC_RAW)
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
#else
  clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static int cmp_u64(const void* a, const void* b) {
  const uint64_t x = *(const uint64_t*)a;
  const uint64_t y = *(const uint64_t*)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

/* A 110 Hz saw-ish harmonic stack: the tuner must see a REAL pitch, or the
 * detector takes its silence-floor early-out and the bench measures nothing. */
static void fill_tone(float* in, int frames, int ch, int sr, long* phase) {
  for (int f = 0; f < frames; ++f) {
    const double t = (double)(*phase + f) / (double)sr;
    double s = 0.0;
    for (int k = 1; k <= 6; ++k) {
      s += (1.0 / k) * sin(2.0 * M_PI * 110.0 * k * t);
    }
    const float v = (float)(0.3 * s);
    for (int c = 0; c < ch; ++c) in[f * ch + c] = v;
  }
  *phase += frames;
}

/* Records `tracks` loops of `lanes` lanes each, then leaves them all playing —
 * the baseline mix the tuner's cost is measured on top of. */
static le_engine* make_engine(int sr, int frames, int tracks, int lanes) {
  le_engine* e = le_engine_create();
  if (e == NULL) return NULL;
  /* The cap has to exceed what the fill loop below records, or the track
   * auto-finalizes into OVERDUBBING at max_loop_frames and the rest of the
   * loop overdubs instead — leaving a loop of `cap` frames, not the half
   * second the comment claims. One second of headroom for a half-second loop. */
  if (le_engine_configure(e, sr, 2, 2, sr) != LE_OK) {
    le_engine_destroy(e);
    return NULL;
  }
  float* in = (float*)calloc((size_t)frames * 2, sizeof(float));
  float* out = (float*)calloc((size_t)frames * 2, sizeof(float));
  if (in == NULL || out == NULL) {
    free(in);
    free(out);
    le_engine_destroy(e);
    return NULL;
  }
  long phase = 0;
  const int loop_blocks = (sr / 2) / frames; /* ~0.5 s per loop */
  for (int t = 0; t < tracks; ++t) {
    le_engine_set_lane_count(e, t, lanes);
    le_engine_record(e, t);
    for (int b = 0; b < loop_blocks; ++b) {
      fill_tone(in, frames, 2, sr, &phase);
      le_engine_process(e, out, in, (uint32_t)frames);
    }
    le_engine_record(e, t); /* finalize -> PLAYING */
    le_engine_process(e, out, in, (uint32_t)frames);
  }
  free(in);
  free(out);
  return e;
}

/* Times `blocks` calls of le_engine_process and prints mean / p50 / p99 / max.
 * Returns the mean in ns so the caller can print the armed-vs-unarmed delta. */
static double run(int sr, int frames, int tracks, int lanes, int blocks,
                  int armed, const char* label) {
  le_engine* e = make_engine(sr, frames, tracks, lanes);
  if (e == NULL) {
    printf("  %-8s ENGINE SETUP FAILED\n", label);
    return 0.0;
  }
  le_engine_set_tuner_input(e, armed ? 0 : -1);

  float* in = (float*)calloc((size_t)frames * 2, sizeof(float));
  float* out = (float*)calloc((size_t)frames * 2, sizeof(float));
  /* --blocks scales this array without bound; a failed allocation here would
   * otherwise be a segfault in the timing loop rather than a message. */
  uint64_t* ns = (uint64_t*)malloc(sizeof(uint64_t) * (size_t)blocks);
  if (in == NULL || out == NULL || ns == NULL) {
    printf("  %-8s OUT OF MEMORY (%d blocks)\n", label, blocks);
    free(ns);
    free(in);
    free(out);
    le_engine_destroy(e);
    return 0.0;
  }
  long phase = 0;

  /* Warm up: drains the arm command, fills the tuner's windows, and settles
   * every cache line the steady state touches. A cold first detection would
   * otherwise land in the sample set as a spurious tail. */
  const int warm = 4000;
  for (int b = 0; b < warm; ++b) {
    fill_tone(in, frames, 2, sr, &phase);
    le_engine_process(e, out, in, (uint32_t)frames);
  }

  for (int b = 0; b < blocks; ++b) {
    fill_tone(in, frames, 2, sr, &phase);
    const uint64_t t0 = now_ns();
    le_engine_process(e, out, in, (uint32_t)frames);
    ns[b] = now_ns() - t0;
  }

  double sum = 0.0;
  for (int b = 0; b < blocks; ++b) sum += (double)ns[b];
  const double mean = sum / (double)blocks;
  qsort(ns, (size_t)blocks, sizeof(uint64_t), cmp_u64);
  printf("  %-8s mean %7.2f us   p50 %7.2f   p99 %7.2f   max %8.2f\n", label,
         mean / 1000.0, (double)ns[blocks / 2] / 1000.0,
         (double)ns[(int)((double)blocks * 0.99)] / 1000.0,
         (double)ns[blocks - 1] / 1000.0);

  free(ns);
  free(in);
  free(out);
  le_engine_destroy(e);
  return mean;
}

static void usage(const char* argv0) {
  fprintf(stderr,
          "usage: %s [--sr N] [--frames N] [--blocks N] "
          "[--tracks N --lanes N]\n",
          argv0);
}

/* Every option here is a divisor, an array length or a loop count: --sr 0
 * divides by zero in the deadline print, --blocks 0 divides by zero for the
 * mean and reads ns[-1], and a negative --blocks wraps the malloc size. atoi
 * reports none of that, so parse strictly and refuse anything out of range —
 * this is committed tooling, meant to be re-run by hand on the appliance, not
 * a throwaway. Returns 0 on success and -1 after printing the reason. */
static int parse_positive(const char* flag, const char* text, int max,
                          int* out) {
  char* end = NULL;
  errno = 0;
  const long v = strtol(text, &end, 10);
  if (end == text || *end != '\0' || errno == ERANGE || v < 1 || v > max) {
    fprintf(stderr, "%s: expected an integer in [1, %d], got \"%s\"\n", flag,
            max, text);
    return -1;
  }
  *out = (int)v;
  return 0;
}

int main(int argc, char** argv) {
  int sr = 96000;
  int frames = 32;
  int blocks = 100000;
  int tracks = -1;
  int lanes = -1;
  for (int i = 1; i < argc; ++i) {
    const int more = i + 1 < argc;
    int rc = 0;
    if (strcmp(argv[i], "--sr") == 0 && more) {
      rc = parse_positive("--sr", argv[++i], 768000, &sr);
    } else if (strcmp(argv[i], "--frames") == 0 && more) {
      rc = parse_positive("--frames", argv[++i], 16384, &frames);
    } else if (strcmp(argv[i], "--blocks") == 0 && more) {
      rc = parse_positive("--blocks", argv[++i], 100000000, &blocks);
    } else if (strcmp(argv[i], "--tracks") == 0 && more) {
      rc = parse_positive("--tracks", argv[++i], LE_MAX_TRACKS, &tracks);
    } else if (strcmp(argv[i], "--lanes") == 0 && more) {
      rc = parse_positive("--lanes", argv[++i], LE_MAX_LANES, &lanes);
    } else {
      usage(argv[0]);
      return 2;
    }
    if (rc != 0) return 2;
  }
  /* --tracks and --lanes select one configuration together; honouring half a
   * pair would silently run the default sweep instead of what was asked for. */
  if ((tracks > 0) != (lanes > 0)) {
    fprintf(stderr, "--tracks and --lanes must be given together\n");
    return 2;
  }
  /* A loop must be at least one block long or make_engine records nothing. */
  if ((sr / 2) / frames < 1) {
    fprintf(stderr, "--frames %d is longer than half a second at --sr %d\n",
            frames, sr);
    return 2;
  }

  const int sweep[][2] = {{1, 1}, {4, 2}, {8, 4}};
  int n = (int)(sizeof(sweep) / sizeof(sweep[0]));
  int only[1][2];
  const int(*cfg)[2] = sweep;
  if (tracks > 0 && lanes > 0) {
    only[0][0] = tracks;
    only[0][1] = lanes;
    cfg = only;
    n = 1;
  }

  printf("bench_tuner: %d Hz, %d-frame blocks (%.0f us deadline), %d blocks\n",
         sr, frames, 1e6 * (double)frames / (double)sr, blocks);
  for (int i = 0; i < n; ++i) {
    printf("\n%dx%d tracks x lanes\n", cfg[i][0], cfg[i][1]);
    const double off = run(sr, frames, cfg[i][0], cfg[i][1], blocks, 0, "off");
    const double on = run(sr, frames, cfg[i][0], cfg[i][1], blocks, 1, "armed");
    printf("  delta    %+.2f us mean\n", (on - off) / 1000.0);
  }
  return 0;
}
