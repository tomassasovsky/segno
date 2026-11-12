/*
 * bench_fx_equiv.c — every effect kind against the reference engine's
 * render of the same input (#1755).
 *
 * WHY: the kernels are made cheaper without changing how they sound. Where
 * the arithmetic is unchanged the output must be bit-identical; where
 * vectorising or reordering it changes the rounding, the difference from
 * the reference must stay below LE_EQV_LIMIT_DB (-120 dBFS), tails
 * included, but where the owner approved a larger one (eqv_limit_db: the
 * Room reverb's Drum rooms, #1761). Nothing else in the suite compares a kind with what it
 * rendered before.
 *
 * bench_fx_equiv.sh builds two libraries from fx_equiv_shim.c and the
 * effects island (engine_fx.c, rt_alloc.c, plugin_disabled.c): the
 * reference, from the commit pinned in that script, and the working tree.
 * This harness loads both (dlopen, each resolving its own symbols) and runs
 * every setting through each, block by block, comparing as it goes:
 *
 *   - each kind at its defaults and at every factory setting
 *     (fx_factory_settings.inc), at 44.1, 48, 88.2 and 96 kHz, in blocks of
 *     32 and 64 frames;
 *   - the stimulus: impulses of both signs, a -1 dBFS logarithmic sweep from
 *     20 Hz to 20 kHz, and synthesized takes (a guitar phrase from E2 to E6,
 *     a bass line, a sung vowel with vibrato, a drum pattern, a noise
 *     burst), the right channel a quieter, later copy of the left; then
 *     silence until both renders have stayed under LE_EQV_QUIET for
 *     LE_EQV_QUIET_S (the whole tail), or the cap, the tempo moving from
 *     LE_EQV_BPM to LE_EQV_TAIL_BPM as it starts (the synced kinds' times);
 *   - the parameter sweeps: the guitar and drums looping while each setting
 *     in turn glides from its value to 0, to 1 and back, block by block,
 *     then alternates between 0.2 and 0.8 every block (what bench_fx_cpu's
 *     `moving` runs), so every update, redesign and ramp path runs; then the
 *     tail.
 *
 * The verdict, per kind: every render's largest difference on either
 * channel below its ceiling (LE_EQV_LIMIT_DB; eqv_limit_db), no NaN or infinity in either, both
 * libraries preparing it, and, for a kind not in k_reordered, every render
 * bit-identical. A kind goes in k_reordered only when its optimisation
 * reorders arithmetic (a sum split across lanes, a fused multiply-add the
 * compiler did not form before). A kind in k_moved is rendered and
 * reported but not judged: its sound was changed on purpose after the
 * reference (the PR that changes it lists it; the one that moves REF in
 * bench_fx_equiv.sh past that change takes it off).
 *
 *   ./bench_fx_equiv.sh                 # every setting, full stimulus
 *   ./bench_fx_equiv.sh --kind roomverb # one kind
 *   ./bench_fx_equiv.sh --ci            # the native tests' subset
 *   ./bench_fx_equiv.sh --detail        # every render's figure
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "engine_fx.h" /* LE_FX_PARAMS, LE_FX_WIDTHS, the type codes */

#define LE_EQV_LIMIT_DB (-120.0)
#define LE_EQV_QUIET 1e-7f /* -140 dBFS */
#define LE_EQV_QUIET_S 0.5
#define LE_EQV_BPM 97.0 /* a tempo no kind's table lands on exactly */
#define LE_EQV_TAIL_BPM 123.0 /* the tempo the tail moves to */
#define EQV_PI 3.14159265358979323846

/* ---------------- the two libraries ---------------- */

typedef struct {
  void* (*make)(int32_t type, int32_t sr, double bpm);
  void (*block)(void* h, const float* p, const float* in_l, const float* in_r,
                float* out_l, float* out_r, int32_t n);
  void (*drop)(void* h);
  void (*tempo)(void* h, double bpm);
  int32_t (*width)(int32_t type);
  int32_t (*params)(void);
  void (*defaults)(int32_t type, float* out);
  void* dl;
} eqv_lib;

static void* need(void* dl, const char* path, const char* sym) {
  void* f = dlsym(dl, sym);
  if (f == NULL) {
    fprintf(stderr, "%s: no %s\n", path, sym);
    exit(2);
  }
  return f;
}

static eqv_lib load(const char* path) {
  void* dl = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (dl == NULL) {
    fprintf(stderr, "%s\n", dlerror());
    exit(2);
  }
  eqv_lib l;
  l.dl = dl;
  *(void**)&l.make = need(dl, path, "eqv_new");
  *(void**)&l.block = need(dl, path, "eqv_block");
  *(void**)&l.drop = need(dl, path, "eqv_free");
  *(void**)&l.tempo = need(dl, path, "eqv_tempo");
  *(void**)&l.width = need(dl, path, "eqv_width");
  *(void**)&l.params = need(dl, path, "eqv_params");
  *(void**)&l.defaults = need(dl, path, "eqv_defaults");
  return l;
}

static eqv_lib g_ref, g_new;

/* ---------------- kinds and settings ---------------- */

typedef struct {
  int32_t type;
  const char* name;
} eqv_kind;

static const eqv_kind k_kinds[] = {
    {LE_FX_DRIVE, "drive"},         {LE_FX_FILTER, "filter"},
    {LE_FX_DELAY, "delay"},         {LE_FX_TREMOLO, "tremolo"},
    {LE_FX_OCTAVER, "octaver"},     {LE_FX_ECHO, "echo"},
    {LE_FX_REVERB, "reverb"},       {LE_FX_EQ, "eq"},
    {LE_FX_COMPRESSOR, "comp"},     {LE_FX_TRANSIENT, "transient"},
    {LE_FX_HP_GATE, "hpgate"},      {LE_FX_DOUBLER, "doubler"},
    {LE_FX_CHORUS, "chorus"},       {LE_FX_WAH, "wah"},
    {LE_FX_OVERDRIVE, "overdrive"}, {LE_FX_DISTORTION, "distortion"},
    {LE_FX_VINYL, "vinyl"},         {LE_FX_DEGRADE, "degrade"},
    {LE_FX_LPF, "lpf"},             {LE_FX_SPRING, "spring"},
    {LE_FX_DUB_VERB, "dubverb"},    {LE_FX_AMB_VERB, "ambverb"},
    {LE_FX_WHAMMY, "whammy"},       {LE_FX_PUMPER, "pumper"},
    {LE_FX_SLICER, "slicer"},       {LE_FX_MODE_DELAY, "modedelay"},
    {LE_FX_DUAL_OCTAVER, "dualoct"}, {LE_FX_AMP_CAB, "ampcab"},
    {LE_FX_MOD, "mod"},             {LE_FX_ROOM_VERB, "roomverb"},
    {LE_FX_SMART_TUNE, "smarttune"},
};
#define EQV_NKINDS (int)(sizeof(k_kinds) / sizeof(k_kinds[0]))

/* The kinds whose optimisation reorders arithmetic, so their renders may
 * round differently from the reference (within eqv_limit_db). Every other
 * kind must be bit-identical.
 *   roomverb  its early taps summed in four lanes a side (#1761, the
 *             owner's approval). */
static const char* const k_reordered[] = {
    "roomverb",
    /* the cabinet's 64 direct taps summed in four vector sums */
    "ampcab",
    NULL,
};

/* What a Drum room's low cut (a float biquad at 8 to 65 Hz) makes of a
 * rounding change ahead of it: the trunk's own clang -O2 and -O3 builds
 * differ by up to -48.8 dBFS on Drum Rack / Wet+Tight; the reordered taps
 * by up to -48.9 (#1761). */
#define LE_EQV_DRUM_ROOM_DB (-45.0)

/* The working tree's le_rv_room_is_drum_for_test: whether a Room reverb's
 * room setting picks a Drum room, as the engine picks it; resolved on
 * load, NULL for a library without it (a tree before #1761), which only a
 * Room reverb render needs. */
static int (*g_room_is_drum)(float v);

/* The ceiling of a render's residual: LE_EQV_LIMIT_DB, but for a Room
 * reverb render that runs a Drum room (its room is one, or the sweeps,
 * which move the room through every one) LE_EQV_DRUM_ROOM_DB. The taps
 * themselves are checked to a float sum's rounding by the native tests
 * (test_room_verb_taps_are_the_rooms). */
static double eqv_limit_db(int32_t type, const float* p, int sweeps) {
  if (type == LE_FX_ROOM_VERB) {
    if (g_room_is_drum == NULL) {
      fprintf(stderr, "the new library has no le_rv_room_is_drum_for_test\n");
      exit(2);
    }
    if (sweeps || g_room_is_drum(p[2])) return LE_EQV_DRUM_ROOM_DB;
  }
  return LE_EQV_LIMIT_DB;
}

/* The kinds whose sound a commit after the reference changed on purpose. */
static const char* const k_moved[] = {
    NULL,
};

static int kind_index(int32_t type) {
  for (int k = 0; k < EQV_NKINDS; ++k) {
    if (k_kinds[k].type == type) return k;
  }
  return -1;
}

static int kind_listed(const char* const* list, int k) {
  for (const char* const* r = list; *r != NULL; ++r) {
    if (!strcmp(*r, k_kinds[k].name)) return 1;
  }
  return 0;
}

typedef struct {
  const char* name;
  int32_t type;
  float p[LE_FX_PARAMS];
} eqv_setting;

static const eqv_setting k_factory[] = {
#include "fx_factory_settings.inc"
};
#define EQV_NFACTORY (int)(sizeof(k_factory) / sizeof(k_factory[0]))

#define EQV_NRATES 4
static const int k_rates[EQV_NRATES] = {44100, 48000, 88200, 96000};
#define EQV_NPERIODS 2
static const int k_periods[EQV_NPERIODS] = {32, 64};

/* ---------------- the stimulus ---------------- */

static int g_ci;
static double g_tail_cap_s;

/* A deterministic noise sample for frame [i] of stream [seed]. */
static float eqv_noise(uint32_t i, uint32_t seed) {
  uint32_t x = i * 2654435761u + seed * 0x9E3779B9u;
  x ^= x >> 16;
  x *= 0x7FEB352Du;
  x ^= x >> 15;
  x *= 0x846CA68Bu;
  x ^= x >> 16;
  return (float)((double)x / 4294967296.0 * 2.0 - 1.0);
}

/* A plucked note at [hz] from [t0] (s), its harmonics to [top] Hz, each
 * decaying faster than the last; peak about [a]. */
static double eqv_pluck(double t, double t0, double hz, double a, double dec,
                        double top) {
  const double u = t - t0;
  if (u < 0.0 || u > 6.0 * dec) return 0.0;
  const double att = u < 0.002 ? u / 0.002 : 1.0;
  double s = 0.0;
  for (int h = 1; h * hz < top; ++h) {
    s += sin(2.0 * EQV_PI * hz * h * u) / (double)h * exp(-u * h / dec);
  }
  return a * 0.55 * att * s;
}

/* The sung vowel: harmonics of a 220 Hz voice with a 5.5 Hz, half-semitone
 * vibrato, shaped by /a/'s formants, in three syllables over [len] s. */
static double eqv_vowel(double u, double len) {
  if (u < 0.0 || u > len) return 0.0;
  const double syl = len / 3.0;
  const double w = fmod(u, syl) / syl;
  const double env = sin(EQV_PI * w) * sin(EQV_PI * w);
  const double f0 = 220.0 * pow(2.0, (0.5 / 12.0) * sin(2.0 * EQV_PI * 5.5 * u));
  /* the phase of a vibrato: the integral of f0, closed form for a sine */
  const double ph = 220.0 * (u - (0.5 / 12.0) * log(2.0) *
                                     (cos(2.0 * EQV_PI * 5.5 * u) - 1.0) /
                                     (2.0 * EQV_PI * 5.5));
  static const double F[3] = {700.0, 1220.0, 2600.0};
  static const double B[3] = {130.0, 70.0, 160.0};
  double s = 0.0;
  for (int h = 1; h * f0 < 8000.0; ++h) {
    double g = 0.0;
    for (int k = 0; k < 3; ++k) {
      const double d = (h * f0 - F[k]) / B[k];
      g += 1.0 / (1.0 + d * d) / (double)(k + 1);
    }
    s += g * sin(2.0 * EQV_PI * ph * h) / sqrt((double)h);
  }
  return 0.35 * env * s;
}

/* A drum pattern at 100 BPM, eighth notes for [len] s: kick on 1 and 3, a
 * snare on 2 and 4, hats between. [i] is the frame, for the noise. */
static double eqv_drums(double u, double len, uint32_t i) {
  if (u < 0.0 || u > len) return 0.0;
  const double eighth = 0.3;
  const int n = (int)(u / eighth);
  const double v = u - n * eighth;
  double s = 0.0;
  if (n % 4 == 0) { /* the kick: a falling sine */
    const double f = 50.0 + 70.0 * exp(-v / 0.03);
    s += 0.95 * sin(2.0 * EQV_PI * f * v) * exp(-v / 0.15);
  } else if (n % 4 == 2) { /* the snare: a tone and noise */
    s += 0.5 * sin(2.0 * EQV_PI * 200.0 * v) * exp(-v / 0.05) +
         0.45 * eqv_noise(i, 3) * exp(-v / 0.08);
  }
  s += 0.2 * (eqv_noise(i, 5) - eqv_noise(i - 1u, 5)) * exp(-v / 0.02);
  return s;
}

typedef struct {
  float* l;
  float* r;
  int n;
} eqv_signal;

/* The left channel of the stimulus at frame [i] of [sr]. */
static double eqv_stim_at(int i, int sr, int* len) {
  const double t = (double)i / (double)sr;
  double s = 0.0;
  double at = 0.1;
  /* impulses */
  const int i0 = (int)(at * sr);
  if (i == i0) s += 1.0;
  if (i == (int)((at + 0.4) * sr)) s -= 0.8;
  at += 0.8;
  /* the sweep, 10 ms fades */
  const double sweep = g_ci ? 1.0 : 3.0;
  const double f1 = 20.0, f2 = sr * 0.45 < 20000.0 ? sr * 0.45 : 20000.0;
  if (t >= at && t < at + sweep) {
    const double u = t - at;
    const double k = log(f2 / f1);
    const double ph = f1 * sweep / k * (exp(u / sweep * k) - 1.0);
    double fade = 1.0;
    if (u < 0.01) fade = u / 0.01;
    if (sweep - u < 0.01) fade = (sweep - u) / 0.01;
    s += 0.89 * fade * sin(2.0 * EQV_PI * ph);
  }
  at += sweep + 0.3;
  /* the guitar phrase */
  static const double notes[8] = {82.41, 110.0, 146.83, 196.0,
                                  246.94, 329.63, 659.26, 1318.51};
  const int nn = g_ci ? 4 : 8;
  for (int k = 0; k < nn; ++k) {
    s += eqv_pluck(t, at + 0.3 * k, notes[g_ci ? 2 * k : k], 0.9, 0.25,
                   12000.0);
  }
  at += 0.3 * nn + 1.0;
  if (!g_ci) {
    /* the bass line */
    static const double bass[4] = {41.2, 55.0, 73.42, 98.0};
    for (int k = 0; k < 4; ++k) {
      s += eqv_pluck(t, at + 0.5 * k, bass[k], 1.0, 0.5, 4000.0);
    }
    at += 2.0 + 1.5;
    /* the vowel */
    s += eqv_vowel(t - at, 2.0);
    at += 2.0 + 0.2;
  }
  /* the drums */
  const double dl = g_ci ? 1.2 : 2.4;
  s += eqv_drums(t - at, dl, (uint32_t)i);
  at += dl + 0.3;
  if (!g_ci) {
    /* a noise burst at -6 dBFS peak */
    if (t >= at && t < at + 0.5) s += 0.5 * eqv_noise((uint32_t)i, 7);
    at += 0.5;
  }
  *len = (int)(at * sr);
  return s;
}

static eqv_signal eqv_stimulus(int sr) {
  int n = 0;
  (void)eqv_stim_at(0, sr, &n);
  eqv_signal x = {(float*)calloc((size_t)n, sizeof(float)),
                  (float*)calloc((size_t)n, sizeof(float)), n};
  if (x.l == NULL || x.r == NULL) exit(1);
  int dummy;
  for (int i = 0; i < n; ++i) x.l[i] = (float)eqv_stim_at(i, sr, &dummy);
  const int d = (int)(0.0017 * sr);
  for (int i = 0; i < n; ++i) x.r[i] = i >= d ? 0.8f * x.l[i - d] : 0.0f;
  return x;
}

/* The sweeps' program material: the guitar phrase and the drums, looping. */
static float eqv_loop_at(int i, int sr) {
  const double per = 2.4;
  const double t = fmod((double)i / (double)sr, per);
  static const double notes[4] = {110.0, 196.0, 329.63, 659.26};
  double s = eqv_drums(t, 1.2, (uint32_t)i);
  for (int k = 0; k < 4; ++k) s += eqv_pluck(t, 1.2 + 0.3 * k, notes[k], 0.8, 0.2, 12000.0);
  return (float)s;
}

/* ---------------- one render pair ---------------- */

typedef struct {
  double worst_db; /* -inf when identical */
  int identical;
  int nonfinite;
  int refused; /* 1: both refused, 2: one did */
  int frames;
  int first; /* the first frame that differs, -1 for none */
} eqv_cmp;

/* Runs one input through both libraries in [period]-frame blocks, the
 * settings from [setting_at] (NULL: [p] throughout), then silence until
 * both have stayed quiet for LE_EQV_QUIET_S or the cap. */
typedef void (*eqv_settings_fn)(const float* base, int32_t width, int block,
                                int blocks_per_param, float* out);

static eqv_cmp eqv_pair(int32_t type, int sr, int period, const float* p,
                        const float* in_l, const float* in_r, int n,
                        eqv_settings_fn moving, int blocks_per_param) {
  eqv_cmp c = {-INFINITY, 1, 0, 0, 0, -1};
  void* a = g_ref.make(type, sr, LE_EQV_BPM);
  void* b = g_new.make(type, sr, LE_EQV_BPM);
  if (a == NULL || b == NULL) {
    c.refused = a == NULL && b == NULL ? 1 : 2;
    if (a) g_ref.drop(a);
    if (b) g_new.drop(b);
    return c;
  }
  float zl[64], zr[64], al[64], ar[64], bl[64], br[64], q[LE_FX_PARAMS];
  memset(zl, 0, sizeof zl);
  memset(zr, 0, sizeof zr);
  const int32_t width = g_new.width(type);
  const int quiet_need = (int)(LE_EQV_QUIET_S * sr);
  const int cap = n + (int)(g_tail_cap_s * sr);
  int quiet = 0;
  double worst = 0.0;
  int at = 0;
  for (int blk = 0; at < cap; ++blk) {
    const int len = period;
    const float* il = at < n ? in_l + at : zl;
    const float* ir = at < n ? in_r + at : zr;
    float tl[64], tr[64];
    if (at < n && at + len > n) { /* the stimulus's last, partial block */
      memset(tl, 0, sizeof tl);
      memset(tr, 0, sizeof tr);
      memcpy(tl, il, sizeof(float) * (size_t)(n - at));
      memcpy(tr, ir, sizeof(float) * (size_t)(n - at));
      il = tl;
      ir = tr;
    }
    memcpy(q, p, sizeof q);
    if (moving != NULL && at < n) moving(p, width, blk, blocks_per_param, q);
    g_ref.block(a, q, il, ir, al, ar, len);
    g_new.block(b, q, il, ir, bl, br, len);
    float peak = 0.0f;
    for (int i = 0; i < len; ++i) {
      if (!isfinite(al[i]) || !isfinite(ar[i]) || !isfinite(bl[i]) ||
          !isfinite(br[i])) {
        c.nonfinite = 1;
        continue;
      }
      if ((al[i] != bl[i] || ar[i] != br[i]) && c.identical) {
        c.identical = 0;
        c.first = at + i;
      }
      const double dl = fabs((double)al[i] - (double)bl[i]);
      const double dr = fabs((double)ar[i] - (double)br[i]);
      if (dl > worst) worst = dl;
      if (dr > worst) worst = dr;
      const float m = fmaxf(fmaxf(fabsf(al[i]), fabsf(ar[i])),
                            fmaxf(fabsf(bl[i]), fabsf(br[i])));
      if (m > peak) peak = m;
    }
    at += len;
    if (at >= n && at - len < n) { /* the tail begins */
      g_ref.tempo(a, LE_EQV_TAIL_BPM);
      g_new.tempo(b, LE_EQV_TAIL_BPM);
    }
    if (at > n) {
      quiet = peak < LE_EQV_QUIET ? quiet + len : 0;
      if (quiet >= quiet_need) break;
    }
  }
  c.frames = at;
  c.worst_db = worst > 0.0 ? 20.0 * log10(worst) : -INFINITY;
  g_ref.drop(a);
  g_new.drop(b);
  return c;
}

/* The sweeps' settings at block [block]: parameter block / per in turn
 * glides from its value to 0, to 1 and back over its first two thirds,
 * then alternates 0.2 / 0.8 every block. */
static void eqv_sweep(const float* base, int32_t width, int block, int per,
                      float* out) {
  if (width <= 0) return;
  const int j = (block / per) % width;
  const int k = block % per;
  const int glide = per * 2 / 3;
  float v;
  if (k < glide) {
    const double u = (double)k / (double)glide * 3.0; /* 0..3 */
    const double b = base[j];
    v = (float)(u < 1.0 ? b * (1.0 - u)
                : u < 2.0 ? (u - 1.0)
                          : 1.0 + (b - 1.0) * (u - 2.0));
  } else {
    v = (k & 1) ? 0.2f : 0.8f;
  }
  out[j] = v;
}

/* ---------------- the work list ---------------- */

typedef struct {
  eqv_setting s;
  char name[160];
  int rate, period;
  eqv_cmp stim, sweep;
} eqv_item;

static eqv_item* g_items;
static int g_nitems;
static atomic_int g_next;
static atomic_int g_done;
static eqv_signal g_stim[EQV_NRATES];
static float* g_loop[EQV_NRATES];
static int g_loop_n[EQV_NRATES];
static double g_sweep_s;

static int rate_index(int sr) {
  for (int r = 0; r < EQV_NRATES; ++r) {
    if (k_rates[r] == sr) return r;
  }
  return -1;
}

static void run_item(eqv_item* it) {
  const int ri = rate_index(it->rate);
  const eqv_signal* x = &g_stim[ri];
  it->stim = eqv_pair(it->s.type, it->rate, it->period, it->s.p, x->l, x->r,
                      x->n, NULL, 0);
  const int32_t width = g_new.width(it->s.type);
  const int per = (int)(g_sweep_s * it->rate) / it->period;
  const int n = width * per * it->period;
  /* the loop, long enough for every parameter's turn */
  if (n > g_loop_n[ri]) {
    fprintf(stderr, "sweep longer than the loop\n");
    exit(1);
  }
  it->sweep = eqv_pair(it->s.type, it->rate, it->period, it->s.p, g_loop[ri],
                       g_loop[ri], n, eqv_sweep, per);
}

static void* worker(void* arg) {
  (void)arg;
  for (;;) {
    const int i = atomic_fetch_add(&g_next, 1);
    if (i >= g_nitems) break;
    run_item(&g_items[i]);
    const int d = atomic_fetch_add(&g_done, 1) + 1;
    if (!g_ci && d % 200 == 0) {
      fprintf(stderr, "  %d / %d renders\n", d, g_nitems);
    }
  }
  return NULL;
}

static void add_setting(const eqv_setting* s, const char* name) {
  for (int ri = 0; ri < EQV_NRATES; ++ri) {
    for (int pi = 0; pi < EQV_NPERIODS; ++pi) {
      eqv_item* it = &g_items[g_nitems++];
      it->s = *s;
      snprintf(it->name, sizeof(it->name), "%s", name);
      it->s.name = it->name;
      it->rate = k_rates[ri];
      it->period = k_periods[pi];
    }
  }
}

/* Each kind at its defaults, then every factory setting; [ci]: a kind's
 * first factory setting, or its defaults when no rack uses it. */
static void build_items(int32_t only) {
  const int per = EQV_NRATES * EQV_NPERIODS;
  g_items = (eqv_item*)calloc((size_t)((EQV_NKINDS + EQV_NFACTORY) * per),
                              sizeof(eqv_item));
  if (g_items == NULL) exit(1);
  int in_racks[EQV_NKINDS];
  memset(in_racks, 0, sizeof(in_racks));
  for (int i = 0; i < EQV_NFACTORY; ++i) {
    const int k = kind_index(k_factory[i].type);
    if (k < 0) {
      fprintf(stderr, "%s: type %d is not in the kinds\n", k_factory[i].name,
              k_factory[i].type);
      exit(2);
    }
    in_racks[k] = 1;
  }
  for (int k = 0; k < EQV_NKINDS; ++k) {
    if (only >= 0 && k_kinds[k].type != only) continue;
    if (g_ci && in_racks[k]) continue;
    eqv_setting s;
    memset(&s, 0, sizeof(s));
    s.type = k_kinds[k].type;
    g_new.defaults(s.type, s.p);
    char name[160];
    snprintf(name, sizeof(name), "%s defaults", k_kinds[k].name);
    add_setting(&s, name);
  }
  int taken[EQV_NKINDS];
  memset(taken, 0, sizeof(taken));
  for (int i = 0; i < EQV_NFACTORY; ++i) {
    const int k = kind_index(k_factory[i].type);
    if (only >= 0 && k_factory[i].type != only) continue;
    if (g_ci && taken[k]) continue;
    taken[k] = 1;
    add_setting(&k_factory[i], k_factory[i].name);
  }
}

/* ---------------- the report ---------------- */

static const char* db_text(double db, char* buf, size_t n) {
  if (isinf(db) && db < 0) {
    snprintf(buf, n, "identical");
  } else {
    snprintf(buf, n, "%.1f dBFS", db);
  }
  return buf;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr,
            "usage: bench_fx_equiv REF_LIB NEW_LIB [--ci] [--kind NAME] "
            "[--jobs N] [--detail]\n");
    return 2;
  }
  g_ref = load(argv[1]);
  g_new = load(argv[2]);
  *(void**)&g_room_is_drum = dlsym(g_new.dl, "le_rv_room_is_drum_for_test");
  int32_t only = -1;
  int jobs = 0, detail = 0;
  for (int i = 3; i < argc; ++i) {
    if (!strcmp(argv[i], "--ci")) {
      g_ci = 1;
    } else if (!strcmp(argv[i], "--detail")) {
      detail = 1;
    } else if (!strcmp(argv[i], "--jobs") && i + 1 < argc) {
      jobs = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--kind") && i + 1 < argc) {
      const char* name = argv[++i];
      for (int k = 0; k < EQV_NKINDS; ++k) {
        if (!strcmp(k_kinds[k].name, name)) only = k_kinds[k].type;
      }
      if (only < 0) {
        fprintf(stderr, "no kind %s\n", name);
        return 2;
      }
    } else {
      fprintf(stderr, "unknown option %s\n", argv[i]);
      return 2;
    }
  }
  if (g_ref.params() != LE_FX_PARAMS || g_new.params() != LE_FX_PARAMS) {
    fprintf(stderr, "the libraries hold %d and %d settings an entry, not %d\n",
            g_ref.params(), g_new.params(), LE_FX_PARAMS);
    return 2;
  }
  for (int32_t t = LE_FX_NONE + 1; t < LE_FX_WIDTHS; ++t) {
    if (t == LE_FX_PLUGIN) continue;
    if (kind_index(t) < 0) {
      fprintf(stderr, "effect type %d is missing from the kinds\n", t);
      return 2;
    }
    if (g_ref.width(t) != g_new.width(t)) {
      fprintf(stderr, "type %d: %d settings in the reference, %d now\n", t,
              g_ref.width(t), g_new.width(t));
      return 2;
    }
  }
  const char* const* lists[2] = {k_reordered, k_moved};
  for (int li = 0; li < 2; ++li) {
    for (const char* const* r = lists[li]; *r != NULL; ++r) {
      int found = 0;
      for (int k = 0; k < EQV_NKINDS; ++k) found |= !strcmp(*r, k_kinds[k].name);
      if (!found) {
        fprintf(stderr, "%s names no kind %s\n",
                li == 0 ? "k_reordered" : "k_moved", *r);
        return 2;
      }
    }
  }
  g_tail_cap_s = g_ci ? 6.0 : 120.0;
  g_sweep_s = g_ci ? 0.25 : 1.0;
  for (int ri = 0; ri < EQV_NRATES; ++ri) {
    g_stim[ri] = eqv_stimulus(k_rates[ri]);
    g_loop_n[ri] = (int)(LE_FX_PARAMS * (g_sweep_s + 0.01) * k_rates[ri]);
    g_loop[ri] = (float*)malloc(sizeof(float) * (size_t)g_loop_n[ri]);
    if (g_loop[ri] == NULL) return 1;
    for (int i = 0; i < g_loop_n[ri]; ++i) {
      g_loop[ri][i] = eqv_loop_at(i, k_rates[ri]);
    }
  }
  build_items(only);
  if (jobs <= 0) {
    const long n = sysconf(_SC_NPROCESSORS_ONLN);
    jobs = n > 0 ? (int)n : 1;
  }
  if (jobs > 64) jobs = 64;
  printf("bench_fx_equiv: %d renders pairs (%s), %d jobs, limit %.0f dBFS "
         "(%.0f for a Room reverb render that runs a Drum room)\n",
         g_nitems, g_ci ? "CI subset" : "every setting", jobs, LE_EQV_LIMIT_DB,
         LE_EQV_DRUM_ROOM_DB);
  fflush(stdout);
  pthread_t th[64];
  int started = 0;
  while (started < jobs &&
         pthread_create(&th[started], NULL, worker, NULL) == 0) {
    ++started;
  }
  if (started == 0) worker(NULL); /* no thread: this one does it all */
  for (int j = 0; j < started; ++j) pthread_join(th[j], NULL);

  int failed = 0;
  char a[32], b[32];
  printf("| kind       | renders | identical | worst residual | where |\n");
  printf("|------------|---------|-----------|----------------|-------|\n");
  for (int k = 0; k < EQV_NKINDS; ++k) {
    int total = 0, same = 0, bad = 0, over = 0;
    double worst = -INFINITY;
    const eqv_item* at = NULL;
    const char* what = "";
    for (int i = 0; i < g_nitems; ++i) {
      const eqv_item* it = &g_items[i];
      if (it->s.type != k_kinds[k].type) continue;
      const eqv_cmp* cs[2] = {&it->stim, &it->sweep};
      static const char* const names[2] = {"stimulus", "sweeps"};
      for (int w = 0; w < 2; ++w) {
        const eqv_cmp* c = cs[w];
        total++;
        if (c->refused || c->nonfinite) {
          bad = 1;
          printf("  %s %s %d Hz / %d: %s\n", it->name, names[w], it->rate,
                 it->period,
                 c->refused == 1   ? "both libraries refused it"
                 : c->refused == 2 ? "one library refused it"
                                   : "NaN or Inf");
          continue;
        }
        if (c->identical) same++;
        if (!kind_listed(k_moved, k) &&
            c->worst_db >= eqv_limit_db(it->s.type, it->s.p, w)) {
          over = 1;
          printf("  %s %s %d Hz / %d: %.1f dBFS, over its %.0f\n", it->name,
                 names[w], it->rate, it->period, c->worst_db,
                 eqv_limit_db(it->s.type, it->s.p, w));
        }
        if (c->worst_db > worst || at == NULL) {
          worst = c->worst_db;
          at = it;
          what = names[w];
        }
        if (detail) {
          printf("  %s %s %d Hz / %d: %s over %d frames", it->name, names[w],
                 it->rate, it->period, db_text(c->worst_db, a, sizeof a),
                 c->frames);
          if (c->first >= 0) printf(", first at frame %d", c->first);
          printf("\n");
        }
      }
    }
    if (total == 0) continue;
    const int moved = kind_listed(k_moved, k);
    const int inexact = !moved && same != total && !kind_listed(k_reordered, k);
    char where[220] = "";
    if (at != NULL && worst > -INFINITY) {
      snprintf(where, sizeof(where), "%s, %s, %d Hz / %d", at->name, what,
               at->rate, at->period);
    }
    printf("| %-10s | %7d | %9d | %14s | %s |%s\n", k_kinds[k].name, total,
           same, db_text(worst, b, sizeof b), where,
           bad || over ? " FAIL"
           : inexact   ? " FAIL: not bit-identical, and not in k_reordered"
           : moved     ? " (changed on purpose: k_moved, not judged)"
                       : "");
    failed |= bad || over || inexact;
  }
  printf("%s\n", failed ? "FAILED" : "ALL PASSED");
  return failed ? 1 : 0;
}
