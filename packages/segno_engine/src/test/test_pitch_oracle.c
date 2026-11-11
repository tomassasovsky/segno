/*
 * test_pitch_oracle.c — the pitch kinds render as they did before #1755.
 *
 * #1755 makes the pitch family cheaper (the Octaver in both modes, the
 * Whammy, the Dual Octaver, Smart Tune) on the rule that none of them
 * changes its sound. This holds each of them to the kernels as they were
 * before it, frozen in test/pitch_ref/pitch_ref.c: every case renders twice
 * through the same engine, once on the live kernels and once on the frozen
 * ones (le_fx_test_process_hook), and the two must be bit-identical. The
 * largest difference is printed in dBFS as well, so a change that is not
 * exact shows how far it is from the rule's -120 dBFS.
 *
 * The cases run each kind through a monitored input's chain at 44.1, 48,
 * 88.2 and 96 kHz, at 32- and 64-frame blocks (le_engine_process, the path
 * the device callback runs), on a stimulus of a plucked guitar phrase, a
 * bass line, a sung vowel gliding with vibrato, a sine sweep, clicks
 * between stretches of digital silence, noise, and signals at the floor and
 * at full scale, while their settings move (the shift, the mix and the tone
 * sweeping, the mode and the formants switching, the Whammy's pedal, the
 * Dual Octaver's switch and levels, Smart Tune's speed, root and scale).
 * Two instances share each chain, so two hop phases run. A stereo pass
 * through fx_apply_chain feeds the two channels different signals.
 *
 * Built -O2 by run_native_tests.sh (--ci: every case on a short stimulus,
 * 64-frame blocks at 48 kHz only);
 * the full run (no argument) renders a longer one, and --input FILE adds a
 * mono 32-bit float file (a take) to the stimulus.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_private.h"
#include "fft.h"
#include "pitch_ref/pitch_ref.h"
#include "segno_engine_api.h"

#define PO_PI 3.14159265358979323846

/* The engine's test-build hooks, which this binary does not use. */
void le_test_after_clear_posted(le_engine* e) { (void)e; }
void le_test_record_image_staged(le_engine* e) { (void)e; }

static const int k_rates[] = {44100, 48000, 88200, 96000};
static const int k_blocks[] = {32, 64};

/* ---- The stimulus: functions of time, so every rate hears the same ---- */

static uint32_t g_seed = 0x1755u;
static double po_noise(void) {
  g_seed = g_seed * 1664525u + 1013904223u;
  return (double)(g_seed >> 8) / 8388608.0 - 1.0;
}

/* A plucked note of [f0] Hz at [t] s after its onset: harmonics to 12 kHz,
 * a 2 ms attack and a 250 ms decay. */
static double pluck(double f0, double t) {
  if (t < 0.0) return 0.0;
  const double env = (t < 0.002 ? t / 0.002 : 1.0) * exp(-t / 0.25);
  double s = 0.0;
  for (int h = 1; h * f0 < 12000.0; ++h) {
    s += sin(2.0 * PO_PI * f0 * h * t) / (double)h * exp(-t * 0.6 * h);
  }
  return 0.35 * env * s;
}

/* A sung vowel: a glottal pulse train gliding from 110 to 330 Hz with a
 * 5.5 Hz vibrato, through three formants that move from /a/ to /i/, with
 * a little breath. [ph] carries the glottal phase. */
typedef struct {
  double ph;
  double z[3][2];
} po_voice;

static double voice(po_voice* v, double t, double len, int sr) {
  const double u = t / len;
  const double f0 = 110.0 * pow(3.0, u) * (1.0 + 0.012 * sin(2.0 * PO_PI * 5.5 * t));
  v->ph += f0 / sr;
  v->ph -= floor(v->ph);
  const double g = v->ph < 0.6 ? 0.5 - 0.5 * cos(PO_PI * v->ph / 0.6) : 0.0;
  double x = g - 0.3 + 0.02 * po_noise();
  static const double fa[3] = {800.0, 1150.0, 2900.0};
  static const double fi[3] = {270.0, 2300.0, 3000.0};
  double y = 0.0;
  for (int k = 0; k < 3; ++k) {
    const double fc = fa[k] + (fi[k] - fa[k]) * u;
    const double r = exp(-PO_PI * 90.0 / sr);
    const double c = 2.0 * r * cos(2.0 * PO_PI * fc / sr);
    const double o = (1.0 - r) * x + c * v->z[k][0] - r * r * v->z[k][1];
    v->z[k][1] = v->z[k][0];
    v->z[k][0] = o;
    y += o;
  }
  return 0.25 * y;
}

/* The composite stimulus at [sr]: each stretch [scale] times its length in
 * seconds, then the takes in [take] (mono float, read as they are). */
static float* make_stimulus(int sr, double scale, const float* take,
                            int64_t take_n, int64_t* n_out) {
  const double lens[] = {2.4, 1.6, 2.0, 1.5, 1.2, 0.6, 0.4, 0.5, 0.5};
  int64_t n = take_n;
  for (size_t k = 0; k < sizeof(lens) / sizeof(lens[0]); ++k) {
    n += (int64_t)(lens[k] * scale * sr);
  }
  float* x = (float*)calloc((size_t)n, sizeof(float));
  if (x == NULL) exit(1);
  int64_t at = 0;
  g_seed = 0x1755u;
  /* 1. A guitar phrase, E2 to E6, a note every 300 ms. */
  static const double notes[8] = {82.41, 110.0, 146.83, 196.0,
                                  246.94, 329.63, 659.26, 1318.51};
  int64_t len = (int64_t)(lens[0] * scale * sr);
  for (int64_t i = 0; i < len; ++i) {
    const double t = (double)i / sr;
    double s = 0.0;
    for (int k = 0; k < 8; ++k) s += pluck(notes[k], t - 0.3 * scale * k);
    x[at + i] = (float)s;
  }
  at += len;
  /* 2. A bass line, every 200 ms. */
  static const double bass[4] = {41.2, 55.0, 73.42, 61.74};
  len = (int64_t)(lens[1] * scale * sr);
  for (int64_t i = 0; i < len; ++i) {
    const double t = (double)i / sr;
    const int k = (int)(t / (0.2 * scale));
    const double tt = t - k * 0.2 * scale;
    x[at + i] = (float)(1.6 * pluck(bass[k & 3], tt));
  }
  at += len;
  /* 3. A sung vowel. */
  po_voice v;
  memset(&v, 0, sizeof(v));
  len = (int64_t)(lens[2] * scale * sr);
  for (int64_t i = 0; i < len; ++i) {
    x[at + i] = (float)voice(&v, (double)i / sr, lens[2] * scale, sr);
  }
  at += len;
  /* 4. A sine sweep, 30 Hz to 16 kHz, at -6 dBFS. */
  len = (int64_t)(lens[3] * scale * sr);
  {
    const double T = lens[3] * scale;
    const double k = log(16000.0 / 30.0);
    for (int64_t i = 0; i < len; ++i) {
      const double t = (double)i / sr;
      x[at + i] =
          (float)(0.5 * sin(2.0 * PO_PI * 30.0 * T / k * (exp(t / T * k) - 1.0)));
    }
  }
  at += len;
  /* 5. Clicks of either sign between digital silence, every 90 ms. */
  len = (int64_t)(lens[4] * scale * sr);
  for (int64_t i = 0; i < len; i += (int64_t)(0.09 * sr)) {
    x[at + i] = (i / (int64_t)(0.09 * sr)) & 1 ? -0.9f : 0.7f;
  }
  at += len;
  /* 6. Silence, then 7. noise at -20 dBFS. */
  at += (int64_t)(lens[5] * scale * sr);
  len = (int64_t)(lens[6] * scale * sr);
  for (int64_t i = 0; i < len; ++i) x[at + i] = (float)(0.1 * po_noise());
  at += len;
  /* 8. A tone at the floor (denormal territory once shifted), then 9. a
   * square at full scale. */
  len = (int64_t)(lens[7] * scale * sr);
  for (int64_t i = 0; i < len; ++i) {
    x[at + i] = (float)(1e-36 * sin(2.0 * PO_PI * 220.0 * i / sr));
  }
  at += len;
  len = (int64_t)(lens[8] * scale * sr);
  for (int64_t i = 0; i < len; ++i) {
    x[at + i] = fmod((double)i * 147.0 / sr, 1.0) < 0.5 ? 1.0f : -1.0f;
  }
  at += len;
  if (take_n > 0) memcpy(x + at, take, sizeof(float) * (size_t)take_n);
  *n_out = n;
  return x;
}

/* ---- The cases ---- */

/* A case: up to two chain entries and how their settings move. [move]
 * writes entry [e]'s settings at [u] (0 to 1 through the render). */
typedef struct po_case po_case;
struct po_case {
  const char* name;
  int count;
  int32_t type[2];
  void (*move)(int e, double u, float* p);
};

static float tri(double u, double cycles) {
  const double x = fmod(u * cycles, 1.0);
  return (float)(x < 0.5 ? 2.0 * x : 2.0 - 2.0 * x);
}

static void mv_oct_pv(int e, double u, float* p) {
  p[0] = e == 0 ? 0.75f : 0.25f; /* an octave up; an octave down */
  p[1] = 1.0f;
  p[2] = 1.0f;
  p[3] = 0.0f;
  p[4] = e == 0 ? 0.0f : 1.0f; /* formants held; moved */
  (void)u;
}

static void mv_oct_moving(int e, double u, float* p) {
  p[0] = e == 0 ? tri(u, 1.5) : 0.5f + 0.4f * (float)sin(2.0 * PO_PI * 3.0 * u);
  p[1] = tri(u, 2.0);
  p[2] = 0.3f + 0.7f * tri(u, 3.0);
  p[3] = e == 0 ? (fmod(u * 4.0, 1.0) < 0.6 ? 0.0f : 1.0f) : 0.0f;
  p[4] = fmod(u * 5.0, 1.0) < 0.5 ? 0.0f : 1.0f;
}

static void mv_oct_psola(int e, double u, float* p) {
  p[0] = e == 0 ? 0.75f : 0.5f - 0.1f * tri(u, 2.0);
  p[1] = 1.0f;
  p[2] = e == 0 ? 1.0f : 0.6f;
  p[3] = 1.0f;
  p[4] = 0.0f;
}

static void mv_whammy(int e, double u, float* p) {
  p[0] = e == 0 ? 1.0f : 0.5f - 0.5f * (float)cos(2.0 * PO_PI * 2.5 * u);
  p[1] = e == 0 ? 1.0f : (fmod(u * 3.0, 1.0) < 0.5 ? 0.0f : 1.0f);
}

static void mv_dual(int e, double u, float* p) {
  p[0] = e == 0 ? (fmod(u * 3.0, 1.0) < 0.5 ? 0.0f : 1.0f) : 0.0f;
  p[1] = e == 0 ? 1.0f : tri(u, 2.0);
  p[2] = e == 0 ? 1.0f : 0.5f + 0.5f * tri(u, 3.0);
  p[3] = e == 0 ? 0.7f : tri(u, 1.0);
}

static void mv_smart(int e, double u, float* p) {
  p[0] = e == 0 ? 0.5f : 0.2f + 0.6f * tri(u, 2.0);
  p[1] = e == 0 ? 0.0f : (float)((int)(u * 5.0) % 12) / 11.0f;
  p[2] = e == 0 ? 0.0f : (float)((int)(u * 7.0) % 14) / 13.0f;
  p[3] = 0.5f;
}

static void mv_mixed(int e, double u, float* p) {
  if (e == 0) {
    mv_oct_pv(0, u, p);
  } else {
    mv_whammy(1, u, p);
  }
}

static const po_case k_cases[] = {
    {"octaver PV, held and moved formants", 2, {LE_FX_OCTAVER, LE_FX_OCTAVER},
     mv_oct_pv},
    {"octaver, every setting moving", 2, {LE_FX_OCTAVER, LE_FX_OCTAVER},
     mv_oct_moving},
    {"octaver PSOLA", 2, {LE_FX_OCTAVER, LE_FX_OCTAVER}, mv_oct_psola},
    {"whammy", 2, {LE_FX_WHAMMY, LE_FX_WHAMMY}, mv_whammy},
    {"dual octaver", 2, {LE_FX_DUAL_OCTAVER, LE_FX_DUAL_OCTAVER}, mv_dual},
    {"smart tune", 2, {LE_FX_SMART_TUNE, LE_FX_SMART_TUNE}, mv_smart},
    {"octaver then whammy", 2, {LE_FX_OCTAVER, LE_FX_WHAMMY}, mv_mixed},
};

/* ---- Rendering ---- */

static void set_params(le_engine* e, const po_case* c, double u) {
  for (int k = 0; k < c->count; ++k) {
    float p[LE_FX_PARAMS] = {0.0f};
    c->move(k, u, p);
    for (int q = 0; q < le_fx_param_width(c->type[k]); ++q) {
      le_engine_set_monitor_input_fx_param(e, 0, k, q, p[q]);
    }
  }
}

/* [c] through a monitored input at [sr] in [block]-frame blocks, on the
 * live kernels or (ref) the frozen ones, into [out] (interleaved stereo). */
static int render_engine(const po_case* c, int sr, int block, int ref,
                         const float* in, int64_t n, float* out) {
  le_fx_test_process_hook = ref ? le_pitch_ref_process : NULL;
  le_engine* e = le_engine_create();
  if (e == NULL) return 0;
  int ok = le_engine_configure(e, sr, 1, 2, sr) == LE_OK &&
           le_engine_set_monitor_input(e, 0, 1) == LE_OK &&
           le_engine_set_monitor_input_output(e, 0, 3) == LE_OK;
  for (int k = 0; ok && k < c->count; ++k) {
    ok = le_engine_set_monitor_input_fx(e, 0, k, c->type[k]) == LE_OK;
  }
  if (ok) set_params(e, c, 0.0);
  ok = ok && le_engine_set_monitor_input_fx_count(e, 0, c->count) == LE_OK;
  for (int64_t at = 0; ok && at < n; at += block) {
    const int64_t len = n - at < block ? n - at : block;
    set_params(e, c, (double)at / (double)n);
    le_engine_process(e, out + 2 * at, in + at, (uint32_t)len);
  }
  le_engine_destroy(e);
  le_fx_test_process_hook = NULL;
  return ok;
}

/* [c]'s chain on a bare le_fx_state, the left channel on [in] and the
 * right on it reversed in time, so the two channels differ. */
static int render_chain(const po_case* c, int sr, int ref, const float* in,
                        int64_t n, float* out) {
  le_fx_test_process_hook = ref ? le_pitch_ref_process : NULL;
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) return 0;
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  int ok = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  memset(params, 0, sizeof(params));
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  for (int k = 0; ok && k < c->count; ++k) {
    types[k] = c->type[k];
    ok = le_fx_prepare(fx, k, c->type[k], sr) == LE_OK;
    if (ok) le_fx_entry_reset(fx, k, c->type[k]);
  }
  fx->clocked = 1;
  fx->hop_seed = 64; /* a quarter in, as an owner may be */
  for (int64_t i = 0; ok && i < n; ++i) {
    if (i % 32 == 0) {
      for (int k = 0; k < c->count; ++k) c->move(k, (double)i / (double)n, params[k]);
    }
    fx->clock = (uint32_t)i;
    float l = in[i];
    float r = 0.8f * in[n - 1 - i];
    fx_apply_chain(fx, sr, sr, &l, &r, c->count, types,
                   (const float(*)[LE_FX_PARAMS])params, NULL);
    out[2 * i] = l;
    out[2 * i + 1] = r;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  le_fx_test_process_hook = NULL;
  return ok;
}

/* ---- Comparing ---- */

static int g_fail;
static double g_worst_db = -400.0;

/* Compares the two renders of [what]: bit-identical, or the largest
 * difference in dBFS. */
static void compare(const char* what, const float* a, const float* b,
                    int64_t n) {
  int64_t diff_at = -1;
  double worst = 0.0;
  for (int64_t i = 0; i < n; ++i) {
    if (memcmp(&a[i], &b[i], sizeof(float)) != 0) {
      if (diff_at < 0) diff_at = i;
      const double d = fabs((double)a[i] - (double)b[i]);
      if (d > worst || isnan(d)) worst = isnan(d) ? INFINITY : d;
    }
  }
  if (diff_at < 0) {
    printf("  %-44s bit-identical\n", what);
    return;
  }
  const double db = worst > 0.0 ? 20.0 * log10(worst) : -400.0;
  if (db > g_worst_db) g_worst_db = db;
  printf("  %-44s DIFFERS from sample %lld (frame %lld), largest %.1f dBFS\n",
         what, (long long)diff_at, (long long)(diff_at / 2), db);
  g_fail = 1;
}

/* ---- The FFT alone ---- */

/* One input of [n] floats of kind [kind]: noise at several scales, tones,
 * sparse values with zeros of both signs, denormals, and huge values. */
static void fft_input(float* x, int n, int kind) {
  for (int i = 0; i < n; ++i) {
    const double u = po_noise();
    switch (kind % 6) {
      case 0: x[i] = (float)u; break;
      case 1: x[i] = (float)(1e-3 * u + sin(0.37 * i) + 0.5 * cos(2.9 * i)); break;
      case 2: x[i] = u > 0.6 ? (float)u : (u < -0.6 ? -0.0f : 0.0f); break;
      case 3: x[i] = (float)(u * 1e-39); break;
      case 4: x[i] = (float)(u * 1e30); break;
      default: x[i] = (float)(u * pow(10.0, 8.0 * po_noise())); break;
    }
  }
}

/* The live transforms (fft.h, NEON on arm64 under Clang) against the ones
 * before #1755 (pitch_ref.c), bit for bit, both ways, at every length a
 * plan holds. */
static void test_fft(void) {
  static le_rfft_plan plan;
  static float x[LE_FFT_MAX_N], re[LE_FFT_MAX_N / 2 + 1], im[LE_FFT_MAX_N / 2 + 1];
  static float re2[LE_FFT_MAX_N / 2 + 1], im2[LE_FFT_MAX_N / 2 + 1];
  static float y[LE_FFT_MAX_N], y2[LE_FFT_MAX_N];
  int bad = 0;
  for (int n = 4; n <= 4096; n *= 2) {
    plan.n = 0; /* each length builds afresh */
    if (!le_rfft_plan_init(&plan, n)) {
      printf("  fft %d: no plan\n", n);
      g_fail = 1;
      continue;
    }
    for (int t = 0; t < 120; ++t) {
      fft_input(x, n, t);
      le_rfft_fwd(&plan, x, re, im);
      le_pitch_ref_rfft_fwd(n, x, re2, im2);
      if (memcmp(re, re2, sizeof(float) * (size_t)(n / 2 + 1)) != 0 ||
          memcmp(im, im2, sizeof(float) * (size_t)(n / 2 + 1)) != 0) {
        ++bad;
      }
      fft_input(re, n / 2 + 1, t + 1);
      fft_input(im, n / 2 + 1, t + 2);
      le_rfft_inv(&plan, re, im, y);
      le_pitch_ref_rfft_inv(n, re, im, y2);
      if (memcmp(y, y2, sizeof(float) * (size_t)n) != 0) ++bad;
    }
  }
  if (bad) {
    printf("  fft: %d transforms differ from the ones before #1755\n", bad);
    g_fail = 1;
  } else {
    printf("  fft, 4 to 4096 points, both ways          bit-identical\n");
  }
}

static float* read_take(const char* path, int64_t* n) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) {
    fprintf(stderr, "cannot open %s\n", path);
    exit(2);
  }
  fseek(f, 0, SEEK_END);
  const long bytes = ftell(f);
  fseek(f, 0, SEEK_SET);
  *n = bytes / (long)sizeof(float);
  float* x = (float*)malloc(sizeof(float) * (size_t)(*n > 0 ? *n : 1));
  if (x == NULL || fread(x, sizeof(float), (size_t)*n, f) != (size_t)*n) exit(2);
  fclose(f);
  for (int64_t i = 0; i < *n; ++i) {
    if (!isfinite(x[i])) x[i] = 0.0f;
  }
  return x;
}

int main(int argc, char** argv) {
  double scale = 1.0;
  int ci = 0;
  float* take = NULL;
  int64_t take_n = 0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--ci")) {
      scale = 0.25;
      ci = 1;
    } else if (!strcmp(argv[i], "--input") && i + 1 < argc) {
      take = read_take(argv[++i], &take_n);
    } else {
      fprintf(stderr, "usage: %s [--ci] [--input take.f32]\n", argv[0]);
      return 2;
    }
  }
  printf("test_pitch_oracle: the pitch kinds against their kernels before "
         "#1755%s\n", scale < 1.0 ? " (CI subset)" : "");
  test_fft();
  for (size_t ri = 0; ri < sizeof(k_rates) / sizeof(k_rates[0]); ++ri) {
    const int sr = k_rates[ri];
    int64_t n = 0;
    float* in = make_stimulus(sr, scale, take, take_n, &n);
    float* a = (float*)malloc(sizeof(float) * 2 * (size_t)n);
    float* b = (float*)malloc(sizeof(float) * 2 * (size_t)n);
    if (a == NULL || b == NULL) return 1;
    for (size_t k = 0; k < sizeof(k_cases) / sizeof(k_cases[0]); ++k) {
      const po_case* c = &k_cases[k];
      char what[128];
      /* The CI subset runs 64-frame blocks at 48 kHz only: the kernels run
       * per sample on the engine's clock, so the block moves only where
       * the settings change. */
      const size_t nb = ci && sr != 48000 ? 1 : sizeof(k_blocks) / sizeof(k_blocks[0]);
      for (size_t bi = 0; bi < nb; ++bi) {
        memset(a, 0, sizeof(float) * 2 * (size_t)n);
        memset(b, 0, sizeof(float) * 2 * (size_t)n);
        if (!render_engine(c, sr, k_blocks[bi], 0, in, n, a) ||
            !render_engine(c, sr, k_blocks[bi], 1, in, n, b)) {
          printf("  %s: the engine refused the chain\n", c->name);
          g_fail = 1;
          continue;
        }
        snprintf(what, sizeof(what), "%d Hz /%d %s", sr, k_blocks[bi], c->name);
        compare(what, a, b, 2 * n);
      }
      if (!render_chain(c, sr, 0, in, n, a) || !render_chain(c, sr, 1, in, n, b)) {
        printf("  %s: the chain refused\n", c->name);
        g_fail = 1;
        continue;
      }
      snprintf(what, sizeof(what), "%d Hz stereo %s", sr, c->name);
      compare(what, a, b, 2 * n);
    }
    free(in);
    free(a);
    free(b);
  }
  free(take);
  if (g_fail) {
    printf("FAILED: a pitch kind no longer renders as it did (largest "
           "difference %.1f dBFS)\n", g_worst_db);
    return 1;
  }
  printf("ALL PASSED\n");
  return 0;
}
