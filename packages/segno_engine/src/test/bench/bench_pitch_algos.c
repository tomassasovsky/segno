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
 *   cpu        per-block cost of one stereo instance, after a warm-up and
 *              under SCHED_FIFO where the OS grants it: mean, p50, p99, max
 *              (us; percentiles as bench_common's stats_of takes them)
 *   latency    input to output, in ms (an onset's arrival)
 *   pitch      the output fundamental's error on a 220 Hz harmonic tone
 *              shifted +7 and -12 semitones, in cents, searched a tritone
 *              either side so a gross error shows ("silent" when the output
 *              has no energy there); not an octave, which on a harmonic
 *              tone would find the second harmonic (the formant-preserving
 *              PV keeps little of a fundamental pushed below the source's
 *              spectrum)
 *   purity     the share of the output's energy, up to Nyquist, within
 *              +-3 FFT bins (+-8.8 Hz) of the target's partials, on that tone
 *              and on an A major triad shifted +5 semitones (polyphony), in
 *              dB below total
 *
 * The octaver instances start settled at their parameters, as the engine's
 * offline renders seed them, so no row includes a start-up ramp.
 *
 *   ./bench_pitch_algos.sh            # the full table (CI runs this)
 *   ./bench_pitch_algos.sh --smoke    # a 1 s CPU run per algorithm
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
  s->params[0][0] = (float)(0.5 + semitones / 48.0);
  s->params[0][1] = 1.0f; /* tone open */
  s->params[0][2] = 1.0f; /* fully wet */
  s->params[0][3] = alg == ALG_PSOLA ? 1.0f : 0.0f;
  /* A standalone state's setup (engine_fx.h): settled enables, a reset slot,
   * the buffers, then the octaver settled at its parameters and mode. */
  s->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  for (int i = 0; i < LE_FX_MAX; ++i) le_fx_enable_seed_settled(s->fx, i);
  le_fx_entry_reset(s->fx, 0);
  if (le_fx_prepare(s->fx, 0, LE_FX_OCTAVER, SR) != LE_OK) {
    fprintf(stderr, "octaver prepare failed\n");
    exit(1);
  }
  le_fx_octaver_seed_settled(s->fx, 0, s->params[0]);
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

/* Energy at frequency f over x (a windowed single-bin DFT, Hann): the
 * fine search around the FFT's peak. */
static double bin_energy(const float* x, int n, double f) {
  double re = 0.0, im = 0.0;
  for (int i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (n - 1));
    re += w * x[i] * cos(2.0 * M_PI * f * i / SR);
    im -= w * x[i] * sin(2.0 * M_PI * f * i / SR);
  }
  return re * re + im * im;
}

/* The analysis length: the largest power of two in the half second a quality
 * run measures (a 2.93 Hz bin at 96 kHz). core/fft.h stops at LE_FFT_MAX_N
 * (4096, a 23 Hz bin), too coarse to separate a triad's partials, so the
 * bench carries its own double-precision transform. */
#define SPEC_N 32768

/* The Hann-windowed power spectrum of x[0 .. SPEC_N), bins 0 .. SPEC_N / 2,
 * into pw. An iterative radix-2 complex FFT on the real input. */
static void power_spectrum(const float* x, double* pw) {
  static double re[SPEC_N], im[SPEC_N];
  for (int i = 0; i < SPEC_N; ++i) {
    re[i] = x[i] * (0.5 - 0.5 * cos(2.0 * M_PI * i / (SPEC_N - 1)));
    im[i] = 0.0;
  }
  for (int i = 1, j = 0; i < SPEC_N; ++i) { /* bit reversal */
    int bit = SPEC_N >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j |= bit;
    if (i < j) {
      double t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (int len = 2; len <= SPEC_N; len <<= 1) {
    const double a = -2.0 * M_PI / len;
    for (int k = 0; k < len / 2; ++k) {
      const double wr = cos(a * k), wi = sin(a * k);
      for (int i = k; i < SPEC_N; i += len) {
        const int j = i + len / 2;
        const double tr = re[j] * wr - im[j] * wi;
        const double ti = re[j] * wi + im[j] * wr;
        re[j] = re[i] - tr;
        im[j] = im[i] - ti;
        re[i] += tr;
        im[i] += ti;
      }
    }
  }
  for (int k = 0; k <= SPEC_N / 2; ++k) pw[k] = re[k] * re[k] + im[k] * im[k];
}

static double g_pw[SPEC_N / 2 + 1];

/* The fundamental near [want] Hz: the strongest FFT bin within a tritone
 * either side, then a ternary search of the windowed DFT over +-1 bin around
 * it. Returns Hz, or 0 when the output has no energy there. */
static double find_f0(const float* x, double want) {
  power_spectrum(x, g_pw);
  const double hz = (double)SR / SPEC_N;
  int lo_k = (int)(want / M_SQRT2 / hz), hi_k = (int)(want * M_SQRT2 / hz);
  if (lo_k < 1) lo_k = 1;
  int best = lo_k;
  for (int k = lo_k; k <= hi_k; ++k) {
    if (g_pw[k] > g_pw[best]) best = k;
  }
  if (g_pw[best] <= 1e-12) return 0.0;
  double lo = (best - 1) * hz;
  double hi = (best + 1) * hz;
  for (int it = 0; it < 40; ++it) {
    const double m1 = lo + (hi - lo) / 3.0;
    const double m2 = hi - (hi - lo) / 3.0;
    if (bin_energy(x, SPEC_N, m1) < bin_energy(x, SPEC_N, m2)) {
      lo = m1;
    } else {
      hi = m2;
    }
  }
  return 0.5 * (lo + hi);
}

/* Share of [x]'s energy, up to Nyquist, within +-3 bins of the partials (12
 * each, below Nyquist) of the [count] fundamentals, in dB (0 = all of it).
 * NAN when the output has no energy. */
static double purity_db(const float* x, const double* f0, int count) {
  power_spectrum(x, g_pw);
  const double hz = (double)SR / SPEC_N;
  static unsigned char near_mask[SPEC_N / 2 + 1];
  memset(near_mask, 0, sizeof(near_mask));
  for (int c = 0; c < count; ++c) {
    for (int h = 1; h <= 12; ++h) {
      const int k = (int)(f0[c] * h / hz + 0.5);
      for (int d = -3; d <= 3; ++d) {
        if (k + d > 0 && k + d <= SPEC_N / 2) near_mask[k + d] = 1;
      }
    }
  }
  double total = 0.0;
  double near = 0.0;
  for (int k = 1; k <= SPEC_N / 2; ++k) {
    total += g_pw[k];
    if (near_mask[k]) near += g_pw[k];
  }
  if (total <= 1e-12) return NAN;
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

/* Prints a cents column, or "silent" for a fundamental not found. */
static void print_cents(double hz, double want, int width) {
  if (hz <= 0.0) {
    printf(" %*s |", width, "silent");
  } else {
    printf(" %+*.1f |", width, 1200.0 * log2(hz / want));
  }
}

int main(int argc, char** argv) {
  int seconds = 10;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) seconds = 1;
  }
  detect_cpu();
  g_budget_us = 1e6 * BLOCK / SR;
  printf("bench_pitch_algos: %s, %d Hz, %d-frame blocks (deadline %.1f us)\n",
         g_cpu_name, SR, BLOCK, g_budget_us);
  printf("| algorithm           | mean us | p50 us | p99 us | max us | latency ms "
         "| +7 cents | -12 cents | tone purity dB | triad purity dB |\n");
  printf("|---------------------|---------|--------|--------|--------|------------"
         "|----------|-----------|----------------|-----------------|\n");
  const int quality_n = SR;
  float* in = (float*)malloc(sizeof(float) * (size_t)quality_n);
  float* out = (float*)malloc(sizeof(float) * (size_t)quality_n);
  /* The quality runs measure the last SPEC_N samples of a 1 s run. */
  const float* tail = out + quality_n - SPEC_N;
  const double f0 = 220.0;
  float* src = (float*)malloc(sizeof(float) * (size_t)SR);
  make_tone(src, SR, &f0, 1); /* exactly 220 cycles: loops seamlessly */
  for (int alg = 0; alg < ALG_N; ++alg) {
    /* CPU: a 220 Hz tone, +7 semitones, stereo; half a second untimed
     * first. */
    const int warm = SR / 2 / BLOCK;
    const int blocks = seconds * SR / BLOCK;
    double* us = (double*)malloc(sizeof(double) * (size_t)blocks);
    shifter s;
    shifter_open(&s, alg, 7.0);
    float l[BLOCK], r[BLOCK];
    rt_enter();
    for (int b = 0; b < warm + blocks; ++b) {
      const int at = (b * BLOCK) % SR;
      memcpy(l, src + at, sizeof(l));
      memcpy(r, src + at, sizeof(r));
      const double t0 = now_us();
      shifter_block(&s, l, r, BLOCK);
      if (b >= warm) us[b - warm] = now_us() - t0;
    }
    rt_leave();
    shifter_close(&s);
    const stats cpu = stats_of(us, (size_t)blocks);
    free(us);

    double found[2];
    double want[2];
    const double shifts[2] = {7.0, -12.0};
    for (int k = 0; k < 2; ++k) {
      make_tone(in, quality_n, &f0, 1);
      shifter_open(&s, alg, shifts[k]);
      run(&s, in, out, quality_n);
      shifter_close(&s);
      want[k] = f0 * pow(2.0, shifts[k] / 12.0);
      found[k] = find_f0(tail, want[k]);
    }
    make_tone(in, quality_n, &f0, 1);
    shifter_open(&s, alg, 7.0);
    run(&s, in, out, quality_n);
    shifter_close(&s);
    const double tgt = f0 * pow(2.0, 7.0 / 12.0);
    const double tone_p = purity_db(tail, &tgt, 1);
    const double triad[3] = {220.0, 277.18, 329.63};
    make_tone(in, quality_n, triad, 3);
    shifter_open(&s, alg, 5.0);
    run(&s, in, out, quality_n);
    shifter_close(&s);
    double ttgt[3];
    for (int c = 0; c < 3; ++c) ttgt[c] = triad[c] * pow(2.0, 5.0 / 12.0);
    const double triad_p = purity_db(tail, ttgt, 3);

    printf("| %-19s | %7.2f | %6.2f | %6.2f | %6.2f | %10.1f |", k_names[alg],
           cpu.mean, cpu.p50, cpu.p99, cpu.max, latency_ms(alg, 7.0));
    print_cents(found[0], want[0], 8);
    print_cents(found[1], want[1], 9);
    printf(" %14.1f | %15.1f |\n", tone_p, triad_p);
    fflush(stdout);
  }
  printf("\ntimed under: %s\n", g_timed_sched);
  free(src);
  free(in);
  free(out);
  return 0;
}
