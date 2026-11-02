/*
 * bench_alias.c — how much the nonlinear effects alias at 48 kHz against
 * 96 kHz (#1540).
 *
 * NOT part of the test gate. Build and run it with ./bench_alias.sh.
 *
 * WHY: the console moved from 96 kHz to 48 kHz (#1529). No built-in effect
 * oversamples, so a waveshaper's harmonics above 24 kHz now fold back below
 * it as inharmonic tones. This measures how much, per kind, at the settings
 * the factory presets use and at a high-gain setting, so the measurement can
 * be rerun after any oversampling change.
 *
 * Each case runs one effect through fx_apply_chain (the kernel the engine
 * and the offline renders call) on a sine at -12 dBFS peak (--level), at
 * 48 and at 96 kHz, and reads the steady-state output's spectrum:
 *
 *   - Every tone is a whole number of cycles in the analysis window (65536
 *     frames at 48 kHz, 131072 at 96 kHz, both 1.365 s), so each harmonic
 *     and each fold of a harmonic lands on one FFT bin with no window and
 *     no leakage. The tones sit on odd bins, so no fold lands on a
 *     harmonic.
 *   - alias dB: the energy on the bins the harmonics above Nyquist fold to
 *     (followed up to 1.536 MHz), from 1 Hz to 20 kHz, over the output's
 *     energy in the same band. The other non-harmonic bins hold mostly the
 *     kernel's own noise and are left out. The dry row is the
 *     measurement's floor.
 *   - worst dBFS: the largest single alias component below 20 kHz, as the
 *     peak level of a sine.
 *
 * The cost columns time the same renders: ns per frame for one instance
 * (net of the chain with no effect), and what 2x oversampling at 48 kHz
 * would cost: the kind's own work at 96 kHz per 48 kHz frame (twice its
 * 96 kHz per-frame cost) plus a streaming 63-tap polyphase half-band up and
 * down on each channel the kernel runs (one for the Amp+Cab, which is mono
 * inside; two for the rest), timed here. An upper bound: the slot's own
 * per-sample work is doubled with the kernel, and the Amp+Cab's cabinet
 * need not run oversampled.
 *
 *   ./bench_alias.sh                        # the table
 *   ./bench_alias.sh --case od-crunch       # one case
 *   ./bench_alias.sh --level -6             # a hotter input
 *   ./bench_alias.sh --list                 # the cases
 *   bench_alias --render amp-fullpower --rate 48000 in.f32 out.f32
 *                                           # a raw mono float32 file
 *                                           # through one case (the A/B)
 */
#define _GNU_SOURCE
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segno_engine_api.h"
#include "engine_fx.h"
#include "engine_private.h"

/* ---------------- the cases ---------------- */

typedef struct {
  const char* name;
  const char* what;
  int32_t type;
  float p[LE_FX_PARAMS];
} alias_case;

/* The preset settings are the catalogue's (packages/fx_catalogue/assets/
 * presets), mapped as fx_module_build.dart maps them. The vinyl runs with
 * its noise off so its hiss and clicks do not read as aliasing. */
static const alias_case k_cases[] = {
    {"dry", "no effect: the measurement's floor", LE_FX_NONE, {0}},
    {"drive", "Drive (built-in) at its defaults", LE_FX_DRIVE, {0.5f, 0.8f}},
    {"drive-high", "Drive at 100 %", LE_FX_DRIVE, {1.0f, 0.8f}},
    {"od-crunch", "Overdrive, Guitar Rack Lead Crunch", LE_FX_OVERDRIVE,
     {0.987f, 0.823f}},
    {"od-beatbox", "Overdrive, Ed's Beatbox Heavy Drive", LE_FX_OVERDRIVE,
     {0.532f, 0.659f}},
    {"od-high", "Overdrive at 100 %, tone 100 %", LE_FX_OVERDRIVE, {1.0f, 1.0f}},
    {"dist-grubby", "Distortion, Lo-Fi Rack Grubby", LE_FX_DISTORTION,
     {0.535f, 0.901f}},
    {"dist-simple", "Distortion, Lo-Fi Rack Simple Distort", LE_FX_DISTORTION,
     {0.0f, 1.0f}},
    {"dist-high", "Distortion at 100 %, tone 100 %", LE_FX_DISTORTION,
     {1.0f, 1.0f}},
    {"amp-bassdirty", "Amp+Cab, Ed's Bass Amp Dirty (BASS cab)", LE_FX_AMP_CAB,
     {0.67f, 0.55f, 0.44f, 0.247f, 9.0f / 11.0f}},
    {"amp-lead2", "Amp+Cab, Ed's Electric Guitar Dirty Lead 2 (4x10\")",
     LE_FX_AMP_CAB, {0.69f, 0.707f, 0.52f, 0.502f, 6.0f / 11.0f}},
    {"amp-fullpower", "Amp+Cab, Guitar Rack Full Drive Power (4x12\")",
     LE_FX_AMP_CAB, {0.935f, 0.695f, 0.407f, 0.608f, 7.0f / 11.0f}},
    {"amp-clean", "Amp+Cab, Ed's Electric Guitar Clean Rhythm (2x12\")",
     LE_FX_AMP_CAB, {0.0f, 0.75f, 0.41f, 0.634f, 5.0f / 11.0f}},
    {"amp-high-di", "Amp+Cab at 100 % drive, treble and modern, D.I.",
     LE_FX_AMP_CAB, {1.0f, 0.5f, 1.0f, 1.0f, 0.0f}},
    {"vinyl-ghost", "Vinyl, Lo-Fi Rack Ghost, noise off", LE_FX_VINYL,
     {1.0f, 0.678f, 0.0f, 1.0f}},
    {"vinyl-robo", "Vinyl, Lo-Fi Rack Robo, noise off", LE_FX_VINYL,
     {0.593f, 0.35f, 0.0f, 1.0f}},
    {"vinyl-high", "Vinyl at 100 %, 50 Hz, noise off", LE_FX_VINYL,
     {1.0f, 0.0f, 0.0f, 1.0f}},
    {"lpf-lightlo", "LPF, Lo-Fi Rack Light Lo", LE_FX_LPF, {0.651f, 0.708f}},
    {"lpf-high", "LPF at 85 % resonance", LE_FX_LPF, {0.75f, 0.85f}},
};
#define N_CASES (int)(sizeof(k_cases) / sizeof(k_cases[0]))

static const alias_case* find_case(const char* name) {
  for (int i = 0; i < N_CASES; ++i) {
    if (!strcmp(k_cases[i].name, name)) return &k_cases[i];
  }
  return NULL;
}

/* ---------------- running a kind ---------------- */

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

/* A chain of one slot holding [c]'s kind, settled, at [sr]. */
static le_fx_state* kind_state(const alias_case* c, int sr) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) return NULL;
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  le_fx_entry_reset(fx, 0);
  if (le_fx_prepare(fx, 0, c->type, sr) != LE_OK) {
    le_fx_state_free_buffers(fx);
    free(fx);
    return NULL;
  }
  fx->clocked = 1;
  return fx;
}

static void kind_free(le_fx_state* fx) {
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* [n] samples of [in] through [c] at [sr] (both channels, left kept), into
 * [out]. Returns the ns the loop took. */
static double kind_run(const alias_case* c, int sr, const float* in, float* out,
                       int64_t n) {
  le_fx_state* fx = kind_state(c, sr);
  if (fx == NULL) {
    fprintf(stderr, "%s refused at %d Hz\n", c->name, sr);
    exit(1);
  }
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  memcpy(params[0], c->p, sizeof(c->p));
  const int32_t types[1] = {c->type};
  const double t0 = now_ns();
  for (int64_t i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    out[i] = l;
  }
  const double dt = now_ns() - t0;
  kind_free(fx);
  return dt;
}

/* ---------------- the spectrum ---------------- */

/* In-place radix-2 complex FFT, double precision ([n] a power of two). */
static void fft(double* re, double* im, int n) {
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      double t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    const double a = -2.0 * M_PI / len;
    for (int k = 0; k < len / 2; ++k) {
      const double wr = cos(a * k), wi = sin(a * k);
      for (int i = k; i < n; i += len) {
        const int j = i + len / 2;
        const double xr = re[j] * wr - im[j] * wi;
        const double xi = re[j] * wi + im[j] * wr;
        re[j] = re[i] - xr;
        im[j] = im[i] - xi;
        re[i] += xr;
        im[i] += xi;
      }
    }
  }
}

#define WIN_48K 65536 /* analysis window at 48 kHz: 1.365 s */
#define SETTLE_S 1.0  /* glides, envelopes and the cabinet's tail settle */
#define TOP_HZ 20000.0
/* Harmonics up to here are followed into their folds: 32 times 48 kHz,
 * the 32nd fold at 48 kHz and the 16th at 96 kHz. */
#define FOLD_TOP_HZ (32.0 * 48000.0)

/* The tones: whole cycles of the 48 kHz window (odd bins), so the same
 * frequency is coherent at 96 kHz too. 330.32, 659.91, 1320.56 and
 * 2640.38 Hz. */
static const int k_bins[4] = {451, 901, 1803, 3605};

typedef struct {
  double alias_db;   /* folded harmonics over all, below TOP_HZ */
  double worst_dbfs; /* the largest folded component */
  double ns;         /* render time */
  int64_t frames;
} alias_result;

/* --detail: the five largest alias components of one measurement, on
 * stderr, so the table stays whole on stdout. */
static int g_detail;

static void print_detail(const alias_case* c, int sr, double hz,
                         const unsigned char* fold, const double* re,
                         const double* im, int win, int top) {
  int best[5] = {0, 0, 0, 0, 0};
  double e_best[5] = {0, 0, 0, 0, 0};
  for (int j = 1; j <= top && j < win / 2; ++j) {
    if (!fold[j]) continue;
    const double e = re[j] * re[j] + im[j] * im[j];
    for (int k = 0; k < 5; ++k) {
      if (e > e_best[k]) {
        for (int m = 4; m > k; --m) {
          e_best[m] = e_best[m - 1];
          best[m] = best[m - 1];
        }
        e_best[k] = e;
        best[k] = j;
        break;
      }
    }
  }
  fprintf(stderr, "%s, %d Hz, %.1f Hz tone:", c->name, sr, hz);
  for (int k = 0; k < 5 && best[k] > 0; ++k) {
    fprintf(stderr, " %.0f Hz %.1f dBFS%s", (double)best[k] * sr / win,
            20.0 * log10(2.0 * sqrt(e_best[k]) / win), k < 4 ? "," : "");
  }
  fprintf(stderr, "\n");
}

static alias_result measure(const alias_case* c, int sr, int bin, double amp) {
  const int win = WIN_48K * (sr / 48000);
  const int64_t settle = (int64_t)(SETTLE_S * sr);
  const int64_t n = settle + win;
  const double hz = (double)bin * 48000.0 / WIN_48K;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  double* re = (double*)calloc((size_t)win, sizeof(double));
  double* im = (double*)calloc((size_t)win, sizeof(double));
  if (in == NULL || out == NULL || re == NULL || im == NULL) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  for (int64_t i = 0; i < n; ++i) {
    in[i] = (float)(amp * sin(2.0 * M_PI * hz * (double)i / sr));
  }
  alias_result r;
  r.ns = kind_run(c, sr, in, out, n);
  r.frames = n;
  for (int i = 0; i < win; ++i) re[i] = out[settle + i];
  fft(re, im, win);
  /* The tone's bin is the same at both rates (the window grows with the
   * rate). The bins its folds land on: harmonic k at k x bin, reflected
   * into the half spectrum. The bin is odd and the window a power of two,
   * so a fold of a harmonic below FOLD_TOP_HZ never lands on a harmonic.
   * Only these bins count as aliasing. The other non-harmonic bins hold the
   * kernel's own noise (float rounding in a low corner, a DC blocker still
   * settling) and the folds of harmonics past FOLD_TOP_HZ; counting them
   * too moves no figure above -65 dB by more than 0.6 dB. */
  const int half = win / 2;
  unsigned char* fold = (unsigned char*)calloc((size_t)half + 1, 1);
  if (fold == NULL) exit(1);
  for (int64_t k = 1; (double)k * hz <= FOLD_TOP_HZ; ++k) {
    if ((double)k * hz <= 0.5 * sr) continue; /* in band: a harmonic */
    int64_t b = (k * bin) % win;
    if (b > half) b = win - b;
    fold[b] = 1;
  }
  /* The alias sum is its own (not the total less the harmonics, which
   * would cancel to nothing at the floor). */
  double total = 0.0, alias = 0.0, worst = 0.0;
  const int top = (int)(TOP_HZ * win / sr);
  for (int j = 1; j <= top && j < half; ++j) {
    const double e = re[j] * re[j] + im[j] * im[j];
    total += e;
    if (fold[j]) {
      alias += e;
      if (e > worst) worst = e;
    }
  }
  r.alias_db = 10.0 * log10(alias / total + 1e-30);
  r.worst_dbfs = 20.0 * log10(2.0 * sqrt(worst) / win + 1e-15);
  if (g_detail) print_detail(c, sr, hz, fold, re, im, win, top);
  free(fold);
  free(in);
  free(out);
  free(re);
  free(im);
  return r;
}

/* ---------------- a real-time half-band pair ---------------- */

/* A 63-tap half-band low-pass at 96 kHz (Kaiser, beta 8: flat to about
 * 20 kHz, about 80 dB down from 28 kHz), run polyphase: 16 coefficient
 * pairs a side, every even tap but the centre zero. What a 2x oversampled
 * kind would run around its kernel, per channel. */
#define HB_K 16
static float g_hb[HB_K]; /* the taps at +-(2k + 1) */

static double bessel_i0(double x) {
  double sum = 1.0, term = 1.0;
  for (int k = 1; k < 40; ++k) {
    term *= (x / (2.0 * k)) * (x / (2.0 * k));
    sum += term;
  }
  return sum;
}

static void hb_design(void) {
  const double beta = 8.0, half = 2.0 * HB_K; /* taps -32 .. 32 */
  for (int k = 0; k < HB_K; ++k) {
    const double n = 2.0 * k + 1.0;
    const double r = n / half;
    const double w = bessel_i0(beta * sqrt(1.0 - r * r)) / bessel_i0(beta);
    g_hb[k] = (float)(sin(M_PI * n / 2.0) / (M_PI * n) * w);
  }
}

/* The last 2 HB_K samples, newest at [0], kept twice over so the view
 * never wraps. */
typedef struct {
  float x[4 * HB_K];
  int p;
} hb_hist;

static inline const float* hb_push(hb_hist* h, float v) {
  h->p = (h->p + 2 * HB_K - 1) & (2 * HB_K - 1);
  h->x[h->p] = v;
  h->x[h->p + 2 * HB_K] = v;
  return h->x + h->p;
}

/* One 48 kHz sample up to two 96 kHz samples. */
static inline void hb_up(hb_hist* h, float v, float out[2]) {
  const float* b = hb_push(h, v);
  float acc = 0.0f;
  for (int k = 0; k < HB_K; ++k) acc += g_hb[k] * (b[HB_K - 1 - k] + b[HB_K + k]);
  out[0] = b[HB_K];
  out[1] = 2.0f * acc;
}

/* Two 96 kHz samples down to one 48 kHz sample. */
static inline float hb_down(hb_hist* even, hb_hist* odd, const float in[2]) {
  const float* e = hb_push(even, in[0]);
  const float* o = hb_push(odd, in[1]);
  float acc = 0.0f;
  for (int k = 0; k < HB_K; ++k) acc += g_hb[k] * (o[HB_K - 1 - k] + o[HB_K + k]);
  return 0.5f * e[HB_K - 1] + acc;
}

/* ns per 48 kHz frame of the pair, up then down, on one channel. Checks the
 * pair passes a 1 kHz sine at unity first. */
static double halfband_pair_ns(void) {
  hb_design();
  const int n = 48000;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  if (x == NULL) exit(1);
  for (int i = 0; i < n; ++i) x[i] = (float)sin(2.0 * M_PI * 1000.0 * i / 48000.0);
  hb_hist up, de, dodd;
  memset(&up, 0, sizeof(up));
  memset(&de, 0, sizeof(de));
  memset(&dodd, 0, sizeof(dodd));
  double peak = 0.0;
  for (int i = 0; i < n; ++i) {
    float u[2];
    hb_up(&up, x[i], u);
    const float y = hb_down(&de, &dodd, u);
    if (i > n / 2 && fabs(y) > peak) peak = fabs(y);
  }
  if (fabs(peak - 1.0) > 0.01) {
    fprintf(stderr, "the half-band pair passes 1 kHz at %.4f, not 1\n", peak);
    exit(1);
  }
  const int reps = 40;
  volatile float sink = 0.0f;
  const double t0 = now_ns();
  for (int r = 0; r < reps; ++r) {
    for (int i = 0; i < n; ++i) {
      float u[2];
      hb_up(&up, x[i], u);
      sink += hb_down(&de, &dodd, u);
    }
  }
  const double dt = now_ns() - t0;
  (void)sink;
  free(x);
  return dt / ((double)reps * n);
}

/* The channels [type]'s kernel runs: the Amp+Cab is mono inside. */
static int kind_channels(int32_t type) { return type == LE_FX_AMP_CAB ? 1 : 2; }

/* ---------------- the table ---------------- */

static int run_table(const char* only, double level_db) {
  const double amp = pow(10.0, level_db / 20.0);
  const double hb = halfband_pair_ns();
  printf("bench_alias: one instance per case, sine at %.1f dBFS peak, "
         "%d-frame window at 48 kHz (%d at 96 kHz) after %.1f s\n",
         level_db, WIN_48K, 2 * WIN_48K, SETTLE_S);
  printf("alias dB = folded-harmonic energy below 20 kHz over the output's; "
         "worst = the largest alias component, dBFS\n"
         "(near -80 dB and below, the bins hold the kernel's own noise)\n");
  printf("63-tap polyphase half-band, 2:1 up and down: %.1f ns per 48 kHz "
         "frame per channel\n\n",
         hb);
  printf("| case          |  330 Hz 48k / 96k |  660 Hz 48k / 96k | "
         "1320 Hz 48k / 96k | 2640 Hz 48k / 96k | worst 48k | worst 96k | "
         "ns/frame 48k | ns/frame 96k | 2x at 48k |\n");
  printf("|---------------|-------------------|-------------------|---------"
         "----------|-------------------|-----------|-----------|----------"
         "----|--------------|-----------|\n");
  double dry_ns[2] = {0.0, 0.0};
  for (int i = 0; i < N_CASES; ++i) {
    const alias_case* c = &k_cases[i];
    if (only != NULL && strcmp(only, c->name) != 0 && c->type != LE_FX_NONE) {
      continue;
    }
    double a[2][4];
    double worst[2] = {-400.0, -400.0};
    double ns[2] = {0.0, 0.0};
    for (int rate = 0; rate < 2; ++rate) {
      const int sr = rate ? 96000 : 48000;
      double t = 0.0;
      int64_t frames = 0;
      for (int k = 0; k < 4; ++k) {
        const alias_result r = measure(c, sr, k_bins[k], amp);
        a[rate][k] = r.alias_db;
        if (r.worst_dbfs > worst[rate]) worst[rate] = r.worst_dbfs;
        t += r.ns;
        frames += r.frames;
      }
      ns[rate] = t / (double)frames;
    }
    if (c->type == LE_FX_NONE) {
      dry_ns[0] = ns[0];
      dry_ns[1] = ns[1];
    }
    const double n48 = ns[0] - dry_ns[0];
    const double n96 = ns[1] - dry_ns[1];
    printf("| %-13s |", c->name);
    for (int k = 0; k < 4; ++k) {
      printf(" %7.1f / %7.1f |", a[0][k], a[1][k]);
    }
    if (c->type == LE_FX_NONE) {
      printf(" %9.1f | %9.1f | %12s | %12s | %9s |\n", worst[0], worst[1],
             "-", "-", "-");
    } else {
      printf(" %9.1f | %9.1f | %12.1f | %12.1f | %9.1f |\n", worst[0],
             worst[1], n48, n96,
             2.0 * n96 + kind_channels(c->type) * hb);
    }
    fflush(stdout);
  }
  printf("\n");
  for (int i = 0; i < N_CASES; ++i) {
    if (only == NULL || !strcmp(only, k_cases[i].name)) {
      printf("%-13s %s\n", k_cases[i].name, k_cases[i].what);
    }
  }
  return 0;
}

/* ---------------- --render ---------------- */

/* A raw mono float32 file through [c] at [sr]. */
static int run_render(const alias_case* c, int sr, const char* in_path,
                      const char* out_path) {
  FILE* f = fopen(in_path, "rb");
  if (f == NULL) {
    perror(in_path);
    return 1;
  }
  long bytes = -1;
  if (fseek(f, 0, SEEK_END) == 0) bytes = ftell(f);
  if (bytes <= 0 || bytes % (long)sizeof(float) != 0 ||
      fseek(f, 0, SEEK_SET) != 0) {
    fprintf(stderr, "%s: not a raw float32 file\n", in_path);
    fclose(f);
    return 1;
  }
  const int64_t n = bytes / (long)sizeof(float);
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  int rc = 0;
  if (in == NULL || out == NULL ||
      (int64_t)fread(in, sizeof(float), (size_t)n, f) != n) {
    fprintf(stderr, "could not read %s\n", in_path);
    rc = 1;
  }
  fclose(f);
  if (rc == 0) {
    kind_run(c, sr, in, out, n);
    FILE* g = fopen(out_path, "wb");
    if (g == NULL || (int64_t)fwrite(out, sizeof(float), (size_t)n, g) != n) {
      perror(out_path);
      rc = 1;
    }
    if (g != NULL) fclose(g);
  }
  free(in);
  free(out);
  return rc;
}

int main(int argc, char** argv) {
  const char* only = NULL;
  const char* render = NULL;
  const char* paths[2] = {NULL, NULL};
  int npaths = 0;
  int sr = 0; /* --render's rate; 48 kHz when not given */
  double level_db = -12.0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--case") && i + 1 < argc) {
      only = argv[++i];
    } else if (!strcmp(argv[i], "--level") && i + 1 < argc) {
      level_db = atof(argv[++i]);
    } else if (!strcmp(argv[i], "--render") && i + 1 < argc) {
      render = argv[++i];
    } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
      sr = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--detail")) {
      g_detail = 1;
    } else if (!strcmp(argv[i], "--list")) {
      for (int k = 0; k < N_CASES; ++k) {
        printf("%-13s %s\n", k_cases[k].name, k_cases[k].what);
      }
      return 0;
    } else if (argv[i][0] != '-' && npaths < 2) {
      paths[npaths++] = argv[i];
    } else {
      fprintf(stderr,
              "usage: %s [--case NAME] [--level DBFS] [--detail] [--list]\n"
              "       %s --render NAME [--rate HZ] IN.f32 OUT.f32\n",
              argv[0], argv[0]);
      return 2;
    }
  }
  if (only != NULL && find_case(only) == NULL) {
    fprintf(stderr, "unknown case %s (--list)\n", only);
    return 2;
  }
  if (render == NULL && (npaths > 0 || sr != 0)) {
    fprintf(stderr, "--rate and files go with --render; the table runs both "
                    "rates on its own tones\n");
    return 2;
  }
  if (render != NULL) {
    const alias_case* c = find_case(render);
    if (sr == 0) sr = 48000;
    if (c == NULL || npaths != 2 || sr <= 0) {
      fprintf(stderr, "--render needs a case (--list), IN.f32 and OUT.f32\n");
      return 2;
    }
    return run_render(c, sr, paths[0], paths[1]);
  }
  return run_table(only, level_db);
}
