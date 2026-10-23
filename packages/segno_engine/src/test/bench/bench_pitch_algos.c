/*
 * bench_pitch_algos.c — which pitch shifter the Looper X pitch kinds use
 * (#887 part 9).
 *
 * NOT part of the test gate. Build and run it with ./bench_pitch_algos.sh.
 *
 * The plan asks for a measurement before any new pitch kind: the vendored
 * Signalsmith Stretch (#1179) against PSOLA (and the phase vocoder the
 * octaver already runs) for Pitch Shift, Whammy and the Harmonizer. This
 * bench runs the three on the same signals at 96 kHz / 64-frame blocks and
 * reports, for each:
 *
 *   cpu        per-block cost of one stereo instance: mean, p50, p99, max (us)
 *   latency    input to output, in ms (an onset's arrival)
 *   pitch      the output fundamental's error on a 220 Hz harmonic tone
 *              shifted +7 and -12 semitones, in cents
 *   purity     the share of the output's energy within +-30 cents of the
 *              target's partials, on that tone and on an A major triad
 *              shifted +5 semitones (polyphony), in dB below total
 *
 *   ./bench_pitch_algos.sh            # the full table
 *   ./bench_pitch_algos.sh --smoke    # short runs (CI)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "segno_engine_api.h"
#include "engine_fx.h"
#include "bench_common.h"
#include "../../stretch/le_stretch.h"

#define SR 96000
#define BLOCK 64

enum { ALG_PV, ALG_PSOLA, ALG_STRETCH, ALG_N };
static const char* const k_names[ALG_N] = {"phase vocoder", "PSOLA",
                                           "Signalsmith Stretch"};

typedef struct shifter {
  int alg;
  le_fx_state* fx;
  le_stretch* st;
  float params[LE_FX_MAX][LE_FX_PARAMS];
} shifter;

static void shifter_open(shifter* s, int alg, double semitones) {
  memset(s, 0, sizeof(*s));
  s->alg = alg;
  if (alg == ALG_STRETCH) {
    s->st = le_stretch_create(2, SR, 0, 1u);
    le_stretch_set_semitones(s->st, (float)semitones, 8000.0f / SR);
    return;
  }
  s->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  for (int i = 0; i < LE_FX_MAX; ++i) le_fx_enable_seed_settled(s->fx, i);
  le_fx_prepare(s->fx, 0, LE_FX_OCTAVER, SR);
  s->params[0][0] = (float)(0.5 + semitones / 48.0);
  s->params[0][1] = 1.0f; /* tone open */
  s->params[0][2] = 1.0f; /* fully wet */
  s->params[0][3] = alg == ALG_PSOLA ? 1.0f : 0.0f;
}

static void shifter_close(shifter* s) {
  if (s->st) le_stretch_destroy(s->st);
  if (s->fx) {
    le_fx_state_free_buffers(s->fx);
    free(s->fx);
  }
}

/* Runs one block of [n] frames, stereo in place. */
static void shifter_block(shifter* s, float* l, float* r, int n) {
  if (s->alg == ALG_STRETCH) {
    float il[BLOCK], ir[BLOCK];
    memcpy(il, l, sizeof(float) * (size_t)n);
    memcpy(ir, r, sizeof(float) * (size_t)n);
    const float* in[2] = {il, ir};
    float* out[2] = {l, r};
    le_stretch_process(s->st, in, n, out, n);
    return;
  }
  const int32_t types[1] = {LE_FX_OCTAVER};
  for (int i = 0; i < n; ++i) {
    fx_apply_chain(s->fx, SR, SR, &l[i], &r[i], 1, types, s->params, NULL);
  }
}

/* A band-limited harmonic tone (sawtooth-like, 12 partials) at f0, or the sum
 * of [count] of them. */
static void make_tone(float* x, int n, const double* f0, int count) {
  for (int i = 0; i < n; ++i) {
    double v = 0.0;
    for (int c = 0; c < count; ++c) {
      for (int h = 1; h <= 12; ++h) {
        v += sin(2.0 * M_PI * f0[c] * h * i / SR) / h;
      }
    }
    x[i] = (float)(0.15 * v / count);
  }
}

static void run(shifter* s, const float* in, float* out, int n) {
  float l[BLOCK], r[BLOCK];
  for (int a = 0; a + BLOCK <= n; a += BLOCK) {
    memcpy(l, in + a, sizeof(l));
    memcpy(r, in + a, sizeof(r));
    shifter_block(s, l, r, BLOCK);
    memcpy(out + a, l, sizeof(l));
  }
}

/* Energy at frequency f over x (a windowed single-bin DFT, Hann). */
static double bin_energy(const float* x, int n, double f) {
  double re = 0.0, im = 0.0;
  for (int i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (n - 1));
    re += w * x[i] * cos(2.0 * M_PI * f * i / SR);
    im -= w * x[i] * sin(2.0 * M_PI * f * i / SR);
  }
  return re * re + im * im;
}

/* The fundamental near [want] Hz: the strongest bin within +-1 semitone, on
 * a 0.1-cent grid, refined by a parabola. Returns Hz. */
static double find_f0(const float* x, int n, double want) {
  double best_f = want;
  double best_e = -1.0;
  for (double c = -100.0; c <= 100.0; c += 2.0) {
    const double f = want * pow(2.0, c / 1200.0);
    const double e = bin_energy(x, n, f);
    if (e > best_e) {
      best_e = e;
      best_f = f;
    }
  }
  double lo = best_f * pow(2.0, -2.0 / 1200.0);
  double hi = best_f * pow(2.0, 2.0 / 1200.0);
  for (int it = 0; it < 30; ++it) {
    const double m1 = lo + (hi - lo) / 3.0;
    const double m2 = hi - (hi - lo) / 3.0;
    if (bin_energy(x, n, m1) < bin_energy(x, n, m2)) {
      lo = m1;
    } else {
      hi = m2;
    }
  }
  return 0.5 * (lo + hi);
}

/* Share of [x]'s energy within +-30 cents of the partials (12 each) of the
 * [count] fundamentals, in dB (0 = all of it). From the power spectrum. */
static double purity_db(const float* x, int n, const double* f0, int count) {
  int m = 1;
  while (m < n) m <<= 1;
  m >>= 1; /* the largest power of two inside */
  double total = 0.0;
  double near = 0.0;
  for (int k = 1; k < m / 2; ++k) {
    const double f = (double)k * SR / m;
    if (f > 8000.0) break;
    const double e = bin_energy(x, m, f);
    total += e;
    int hit = 0;
    for (int c = 0; c < count && !hit; ++c) {
      for (int h = 1; h <= 12; ++h) {
        const double p = f0[c] * h;
        if (fabs(1200.0 * log2(f / p)) < 30.0) {
          hit = 1;
          break;
        }
      }
    }
    if (hit) near += e;
  }
  return 10.0 * log10(near / total);
}

/* The latency: a burst of the tone starting at a known frame; the output's
 * envelope first reaching half its steady level. */
static double latency_ms(int alg, double semis) {
  const int n = SR / 2;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* out = (float*)calloc((size_t)n, sizeof(float));
  const double f0 = 220.0;
  const int start = SR / 10;
  make_tone(in + start, n - start, &f0, 1);
  shifter s;
  shifter_open(&s, alg, semis);
  run(&s, in, out, n);
  shifter_close(&s);
  double steady = 0.0;
  for (int i = n - SR / 10; i < n; ++i) steady = fmax(steady, fabs(out[i]));
  int at = -1;
  for (int i = start; i < n; ++i) {
    if (fabs(out[i]) > 0.5 * steady) {
      at = i;
      break;
    }
  }
  free(in);
  free(out);
  return at < 0 ? -1.0 : 1000.0 * (at - start) / SR;
}

static int cmp_d(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char** argv) {
  int seconds = 10;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) seconds = 1;
  }
  detect_cpu();
  printf("bench_pitch_algos: %s, %d Hz, %d-frame blocks (deadline %.1f us)\n",
         g_cpu_name, SR, BLOCK, 1e6 * BLOCK / SR);
  printf("| algorithm           | mean us | p50 us | p99 us | max us | latency ms "
         "| +7 cents | -12 cents | tone purity dB | triad purity dB |\n");
  printf("|---------------------|---------|--------|--------|--------|------------"
         "|----------|-----------|----------------|-----------------|\n");
  const int quality_n = SR;
  float* in = (float*)malloc(sizeof(float) * (size_t)quality_n);
  float* out = (float*)malloc(sizeof(float) * (size_t)quality_n);
  for (int alg = 0; alg < ALG_N; ++alg) {
    /* CPU: a 220 Hz tone, +7 semitones, stereo. */
    const int blocks = seconds * SR / BLOCK;
    double* us = (double*)malloc(sizeof(double) * (size_t)blocks);
    shifter s;
    shifter_open(&s, alg, 7.0);
    float l[BLOCK], r[BLOCK];
    const double f0 = 220.0;
    float* src = (float*)malloc(sizeof(float) * (size_t)SR);
    make_tone(src, SR, &f0, 1);
    double sum = 0.0;
    for (int b = 0; b < blocks; ++b) {
      const int at = (b * BLOCK) % (SR - BLOCK);
      memcpy(l, src + at, sizeof(l));
      memcpy(r, src + at, sizeof(r));
      const double t0 = now_us();
      shifter_block(&s, l, r, BLOCK);
      us[b] = now_us() - t0;
      sum += us[b];
    }
    shifter_close(&s);
    free(src);
    qsort(us, (size_t)blocks, sizeof(double), cmp_d);
    const double mean = sum / blocks;

    /* Quality on the second half second of a 1 s run. */
    const int half = quality_n / 2;
    double cents[2];
    const double shifts[2] = {7.0, -12.0};
    for (int k = 0; k < 2; ++k) {
      make_tone(in, quality_n, &f0, 1);
      shifter_open(&s, alg, shifts[k]);
      run(&s, in, out, quality_n);
      shifter_close(&s);
      const double want = f0 * pow(2.0, shifts[k] / 12.0);
      cents[k] = 1200.0 * log2(find_f0(out + half, half, want) / want);
    }
    make_tone(in, quality_n, &f0, 1);
    shifter_open(&s, alg, 7.0);
    run(&s, in, out, quality_n);
    shifter_close(&s);
    const double tgt = f0 * pow(2.0, 7.0 / 12.0);
    const double tone_p = purity_db(out + half, half, &tgt, 1);
    const double triad[3] = {220.0, 277.18, 329.63};
    make_tone(in, quality_n, triad, 3);
    shifter_open(&s, alg, 5.0);
    run(&s, in, out, quality_n);
    shifter_close(&s);
    double ttgt[3];
    for (int c = 0; c < 3; ++c) ttgt[c] = triad[c] * pow(2.0, 5.0 / 12.0);
    const double triad_p = purity_db(out + half, half, ttgt, 3);

    printf("| %-19s | %7.2f | %6.2f | %6.2f | %6.2f | %10.1f | %+8.1f | %+9.1f "
           "| %14.1f | %15.1f |\n",
           k_names[alg], mean, us[blocks / 2], us[(int)(blocks * 0.99)],
           us[blocks - 1], latency_ms(alg, 7.0), cents[0], cents[1], tone_p,
           triad_p);
    fflush(stdout);
    free(us);
  }
  free(in);
  free(out);
  return 0;
}
