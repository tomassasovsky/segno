/*
 * operator_voice.c — the Operator device (operator_voice.h).
 *
 * Written from the behavior description in docs/brainstorm/2026-11-24-
 * ableton-devices-brainstorm-doc.md ("Operator: behavior"). Values marked
 * "fit" were set against Live renders; the rest follow the description.
 */
#include "operator_voice.h"

#include <math.h>
#include <pthread.h>
#include <string.h>

#include "fft.h"
#include "ms2_section.h"
#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define N_TABLE 4096
#define OP_PI 3.14159265358979323846

enum {
  LE_OPERATOR_VOICE_FREE = 0,
  LE_OPERATOR_VOICE_HELD,
  LE_OPERATOR_VOICE_RELEASED,
  LE_OPERATOR_VOICE_SUSTAINED,
  LE_OPERATOR_VOICE_FADING
};

enum { ENV_ATTACK = 0, ENV_DECAY, ENV_LOOP, ENV_SUSTAIN, ENV_RELEASE, ENV_OFF };
enum { LOOP_NONE = 0, LOOP_LOOP, LOOP_BEAT, LOOP_SYNC, LOOP_TRIGGER };
enum { SIDE_BOTH = 0, SIDE_LEFT, SIDE_RIGHT };
enum {
  DST_OFF = 0, DST_VOL_A, DST_VOL_B, DST_VOL_C, DST_VOL_D, DST_XFADE_AC,
  DST_XFADE_BD, DST_FEEDBACK, DST_FIXED, DST_FM_DRIVE, DST_FILTER_FREQ,
  DST_FILTER_Q, DST_FILTER_RES, DST_FILTER_MORPH, DST_FILTER_DRIVE,
  DST_FILTER_ENV, DST_SHAPER_DRIVE, DST_LFO_RATE, DST_LFO_AMOUNT,
  DST_PITCH_ENV, DST_VOLUME, DST_PAN, DST_TONE, DST_TIME
};
enum { SRC_VELOCITY = 0, SRC_KEY, SRC_PRESSURE, SRC_BEND, SRC_MOD };

/* The key a voice's key scalings follow: its first note's, kept through a
 * legato glide (a mono triad's later notes keep the first's operator key
 * scaling: diagnosed on a held-out preset, round 8 confirms) */
#define VKEY(v) ((v)->key)

/* ---- parameters ---- */

typedef struct op_param_def {
  float def, lo, hi;
  int step;
} op_param_def;

/* An envelope's field `f`; `levels` gives the level range and defaults. */
static op_param_def env_field(int32_t f, int levels) {
  /* levels: 0 an operator or LFO envelope, 1 the filter's, 2 the pitch's */
  const float lo = levels == 2 ? -48.0f : 0.0f;
  const float hi = levels == 2 ? 48.0f : 1.0f;
  const float floor_level = levels == 0 ? 0.00031622799f : 0.0f;
  switch (f) {
    case LE_OPERATOR_ENV_ATTACK_TIME: return (op_param_def){0.1f, 0.1f, 20000.0f, 0};
    case LE_OPERATOR_ENV_ATTACK_LEVEL: return (op_param_def){levels == 0 ? floor_level : 0.0f, lo, hi, 0};
    case LE_OPERATOR_ENV_ATTACK_SLOPE: return (op_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_ENV_DECAY_TIME: return (op_param_def){600.0f, 1.0f, 60000.0f, 0};
    case LE_OPERATOR_ENV_DECAY_LEVEL: return (op_param_def){levels == 2 ? 0.0f : 1.0f, lo, hi, 0};
    case LE_OPERATOR_ENV_DECAY_SLOPE: return (op_param_def){1.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_ENV_SUSTAIN: return (op_param_def){levels == 2 ? 0.0f : 1.0f, lo, hi, 0};
    case LE_OPERATOR_ENV_RELEASE_TIME: return (op_param_def){50.0f, 1.0f, 60000.0f, 0};
    case LE_OPERATOR_ENV_RELEASE_LEVEL: return (op_param_def){floor_level, lo, hi, 0};
    case LE_OPERATOR_ENV_RELEASE_SLOPE: return (op_param_def){1.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_ENV_LOOP_MODE: return (op_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_OPERATOR_ENV_LOOP_TIME: return (op_param_def){100.0f, 0.2f, 20000.0f, 0};
    case LE_OPERATOR_ENV_REPEAT: return (op_param_def){3.0f, 0.0f, 14.0f, 1};
    default: return (op_param_def){0.0f, -100.0f, 100.0f, 0}; /* time vel */
  }
}

static op_param_def op_field(int32_t op, int32_t f) {
  if (f >= LE_OPERATOR_OP_ENV && f < LE_OPERATOR_OP_ENV + LE_OPERATOR_ENV_FIELDS) {
    return env_field(f - LE_OPERATOR_OP_ENV, 0);
  }
  if (f >= LE_OPERATOR_OP_USER_HARMONIC) {
    return (op_param_def){f == LE_OPERATOR_OP_USER_HARMONIC ? 1.0f : 0.0f, 0.0f, 1.0f, 0};
  }
  switch (f) {
    case LE_OPERATOR_OP_ON: return (op_param_def){op == 0 ? 1.0f : 0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_WAVE: return (op_param_def){0.0f, 0.0f, 22.0f, 1};
    case LE_OPERATOR_OP_VOLUME: return (op_param_def){1.0f, 0.0f, 1.0f, 0};
    case LE_OPERATOR_OP_COARSE: return (op_param_def){1.0f, 0.0f, 48.0f, 1};
    case LE_OPERATOR_OP_FINE: return (op_param_def){0.0f, 0.0f, 1000.0f, 0};
    case LE_OPERATOR_OP_FIXED_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_FIXED_FREQ: return (op_param_def){100.0f, 1.0f, 1000.0f, 0};
    case LE_OPERATOR_OP_FIXED_MULTI: return (op_param_def){4.0f, 0.0f, 5.0f, 1};
    case LE_OPERATOR_OP_VEL_COARSE: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_OP_VEL_COARSE_QUANTIZED: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_PHASE: return (op_param_def){0.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_OP_RETRIGGER: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_LFO_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_PITCH_ENV_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_OP_VEL_SCALE: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_OP_KEY_SCALE: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_OP_FEEDBACK: return (op_param_def){0.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_OP_USER_COUNT: return (op_param_def){0.0f, 0.0f, 2.0f, 1};
    case LE_OPERATOR_OP_USER_EXPANSION: return (op_param_def){0.0f, 0.0f, 5.0f, 1};
    default: return (op_param_def){1.0f, 0.0f, 1.0f, 1}; /* normalize */
  }
}

static op_param_def param_def(int32_t p) {
  if (p < LE_OPERATOR_ALGORITHM) {
    return op_field(p / LE_OPERATOR_OP_FIELDS, p % LE_OPERATOR_OP_FIELDS);
  }
  if (p >= LE_OPERATOR_LFO_ENV && p < LE_OPERATOR_LFO_ENV + LE_OPERATOR_ENV_FIELDS) {
    return env_field(p - LE_OPERATOR_LFO_ENV, 0);
  }
  if (p >= LE_OPERATOR_PITCH_ENV && p < LE_OPERATOR_PITCH_ENV + LE_OPERATOR_ENV_FIELDS) {
    return env_field(p - LE_OPERATOR_PITCH_ENV, 2);
  }
  if (p >= LE_OPERATOR_FILTER_ENV && p < LE_OPERATOR_FILTER_ENV + LE_OPERATOR_ENV_FIELDS) {
    return env_field(p - LE_OPERATOR_FILTER_ENV, 1);
  }
  if (p >= LE_OPERATOR_ROUTE) {
    return ((p - LE_OPERATOR_ROUTE) & 1) == 0 ? (op_param_def){0.0f, 0.0f, 23.0f, 1}
                                              : (op_param_def){0.0f, -100.0f, 100.0f, 0};
  }
  switch (p) {
    case LE_OPERATOR_ALGORITHM: return (op_param_def){0.0f, 0.0f, 10.0f, 1};
    case LE_OPERATOR_VOICES: return (op_param_def){5.0f, 0.0f, 15.0f, 1};
    case LE_OPERATOR_RETRIGGER_MODE: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_INTERPOLATION: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_ANTIALIAS: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_TRANSPOSE: return (op_param_def){0.0f, -48.0f, 48.0f, 1};
    case LE_OPERATOR_PITCH_BEND_RANGE: return (op_param_def){5.0f, 0.0f, 24.0f, 1};
    case LE_OPERATOR_VOLUME: return (op_param_def){1.0f, 0.0f, 1.995f, 0};
    case LE_OPERATOR_PAN: return (op_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_PAN_KEY: return (op_param_def){0.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_PAN_RANDOM: return (op_param_def){0.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_TONE: return (op_param_def){0.7f, 0.0f, 1.0f, 0};
    case LE_OPERATOR_SPREAD: return (op_param_def){0.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_GLIDE_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_GLIDE_TIME: return (op_param_def){50.0f, 0.1f, 10000.0f, 0};
    case LE_OPERATOR_LFO_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_LFO_TYPE: return (op_param_def){0.0f, 0.0f, 6.0f, 1};
    case LE_OPERATOR_LFO_RANGE: return (op_param_def){0.0f, 0.0f, 2.0f, 1};
    case LE_OPERATOR_LFO_RATE: return (op_param_def){100.0f, 0.0f, 127.0f, 0};
    case LE_OPERATOR_LFO_SYNCED_RATE: return (op_param_def){3.0f, 0.0f, 14.0f, 1};
    case LE_OPERATOR_LFO_RATE_KEY: return (op_param_def){0.0f, 0.0f, 1.0f, 0};
    case LE_OPERATOR_LFO_RETRIGGER: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_LFO_AMOUNT: return (op_param_def){1.0f, 0.0f, 1.0f, 0};
    case LE_OPERATOR_LFO_AMOUNT_A: return (op_param_def){100.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_LFO_AMOUNT_VEL: return (op_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_LFO_PITCH_ENV_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_LFO_DEST: return (op_param_def){0.0f, 0.0f, 23.0f, 1};
    case LE_OPERATOR_LFO_DEST_AMOUNT: return (op_param_def){100.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_PITCH_ENV_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_PITCH_ENV_AMOUNT: return (op_param_def){1.0f, -1.0f, 1.0f, 0};
    case LE_OPERATOR_PITCH_ENV_AMOUNT_A: return (op_param_def){100.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_PITCH_ENV_DEST: return (op_param_def){0.0f, 0.0f, 23.0f, 1};
    case LE_OPERATOR_PITCH_ENV_DEST_AMOUNT: return (op_param_def){100.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_ENV_TIME: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_ENV_TIME_KEY: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_ENV_TIME_ATTACK: return (op_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_FILTER_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_FILTER_TYPE: return (op_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_OPERATOR_FILTER_CIRCUIT_LPHP: return (op_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_OPERATOR_FILTER_CIRCUIT_BPNOMO: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_FILTER_SLOPE: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_FILTER_FREQ: return (op_param_def){18500.0f, 30.0f, 18500.0f, 0};
    case LE_OPERATOR_FILTER_RES: return (op_param_def){0.0f, 0.0f, 1.25f, 0};
    case LE_OPERATOR_FILTER_MORPH: return (op_param_def){0.0f, 0.0f, 1.0f, 0};
    case LE_OPERATOR_FILTER_DRIVE: return (op_param_def){0.0f, 0.0f, 24.0f, 0};
    case LE_OPERATOR_FILTER_VEL: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_FILTER_KEY: return (op_param_def){0.0f, -200.0f, 100.0f, 0};
    case LE_OPERATOR_FILTER_ENV_AMOUNT: return (op_param_def){0.0f, -100.0f, 100.0f, 0};
    case LE_OPERATOR_FILTER_LFO_ON: return (op_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_OPERATOR_SHAPER_TYPE: return (op_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_OPERATOR_SHAPER_DRY_WET: return (op_param_def){100.0f, 0.0f, 100.0f, 0};
    case LE_OPERATOR_SHAPER_DRIVE: return (op_param_def){0.0f, -12.0f, 12.0f, 0};
    case LE_OPERATOR_ROUTE_NEUTRAL_KEY: return (op_param_def){60.0f, 0.0f, 127.0f, 1};
    default: return (op_param_def){0.0f, 0.0f, 1.0f, 0};
  }
}

float le_operator_default(int32_t param) {
  if (param < 0 || param >= LE_OPERATOR_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_operator_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_OPERATOR_PARAMS) return 0.0f;
  const op_param_def p = param_def(param);
  if (value != value) return p.def;
  if (value < p.lo) value = p.lo;
  if (value > p.hi) value = p.hi;
  return p.step ? floorf(value + 0.5f) : value;
}

static float vf(const le_operator* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_operator* d, int32_t p) { return (int32_t)d->values[p]; }
static float opf(const le_operator* d, int32_t op, int32_t f) {
  return d->values[LE_OPERATOR_OP(op, f)];
}
static int32_t opi(const le_operator* d, int32_t op, int32_t f) {
  return (int32_t)d->values[LE_OPERATOR_OP(op, f)];
}

static float clampf(float x, float lo, float hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

/* The 32-bit linear congruential generator the noises and random phases
 * draw from, and its value mapped to [-1, 1) and [0, 1). */
static uint32_t lcg(uint32_t* s) {
  *s = *s * 1664525u + 1013904223u;
  return *s;
}
static float lcg_bipolar(uint32_t* s) {
  return (float)((double)lcg(s) / 2147483648.0 - 1.0);
}
static float lcg_unit(uint32_t* s) { return (float)((double)lcg(s) / 4294967296.0); }

/* ---- wave tables ---- */

/* The tables are 4096 samples (the full table) and band-limited copies.
 * A copy keeping `limit` harmonics needs far fewer samples than the full
 * table; it takes 16 per period of its top harmonic, at least 64. */
static int32_t copy_size(int32_t limit) {
  int32_t s = 16 * limit;
  if (s < 64) s = 64;
  return s > N_TABLE ? N_TABLE : s;
}

static le_rfft_plan g_plans[7]; /* sizes 64 .. 4096 */
static float g_wave_store[22][LE_OPERATOR_WAVE_FLOATS];
static le_operator_wave g_waves[22];
static pthread_once_t g_tables_once = PTHREAD_ONCE_INIT;

static const le_rfft_plan* plan_for(int32_t size) {
  int32_t i = 0;
  while ((64 << i) < size) ++i;
  return &g_plans[i];
}

static int32_t pow2_ceil(int32_t h) {
  int32_t p = 1;
  while (p < h) p <<= 1;
  return p;
}

/* Fills `w`'s copies (in `store`, after the full table already there) from
 * the full table's spectrum re/im (a 4096-point forward transform's bins),
 * for a wave whose highest harmonic is `h`: limits below h, halving from
 * the power of two at or above it. */
static void build_copies(le_operator_wave* w, float* store, int32_t used,
                         const float* re, const float* im, int32_t h) {
  float bre[N_TABLE / 2 + 1], bim[N_TABLE / 2 + 1];
  w->levels = 1;
  for (int32_t lim = pow2_ceil(h); lim >= 1; lim >>= 1) {
    if (lim >= h || w->levels > LE_OPERATOR_LEVELS) continue;
    const int32_t size = copy_size(lim);
    const float scale = (float)size / (float)N_TABLE;
    for (int32_t k = 0; k <= size / 2; ++k) {
      const int keep = k >= 1 && k <= lim && k < size / 2;
      bre[k] = keep ? re[k] * scale : 0.0f;
      bim[k] = keep ? im[k] * scale : 0.0f;
    }
    float* t = store + used;
    le_rfft_inv(plan_for(size), bre, bim, t);
    t[size] = t[0];
    w->level[w->levels] = t;
    w->size[w->levels] = size;
    w->limit[w->levels] = lim;
    w->levels++;
    used += size + 1;
  }
}

/* Builds `w` from sine amplitudes amp[1..h] (amp[0] unused): the full table
 * by inverse transform, then its copies; peak-normalised when `normalise`,
 * the peak kept as the gain when `keep_gain`. */
static void build_additive(le_operator_wave* w, float* store, const float* amp,
                           int32_t h, int normalise, int keep_gain) {
  /* on the stack: a user wave is built on the audio thread, and slots may
   * render on different threads */
  float re[N_TABLE / 2 + 1], im[N_TABLE / 2 + 1];
  for (int32_t k = 0; k <= N_TABLE / 2; ++k) {
    re[k] = 0.0f;
    im[k] = k >= 1 && k <= h && k < N_TABLE / 2 ? -amp[k] * (float)(N_TABLE / 2) : 0.0f;
  }
  le_rfft_inv(plan_for(N_TABLE), re, im, store);
  store[N_TABLE] = store[0];
  w->level[0] = store;
  w->size[0] = N_TABLE;
  w->limit[0] = h;
  w->freq_mult = 1.0f;
  w->white = 0;
  build_copies(w, store, N_TABLE + 1, re, im, h);
  float peak = 0.0f;
  for (int32_t i = 0; i < N_TABLE; ++i) peak = fmaxf(peak, fabsf(store[i]));
  w->gain = 1.0f;
  if (normalise && peak > 0.0f) {
    for (int32_t l = 0; l < w->levels; ++l) {
      float* t = (float*)w->level[l];
      for (int32_t i = 0; i <= w->size[l]; ++i) t[i] /= peak;
    }
    if (keep_gain) w->gain = peak;
  }
}

/* A drawn wave (Saw D, Square D): the table as drawn, its copies from its
 * spectrum. */
static void build_drawn(le_operator_wave* w, float* store, int square) {
  for (int32_t i = 0; i < N_TABLE; ++i) {
    store[i] = square ? (i < N_TABLE / 2 ? 1.0f : -1.0f)
                      : 1.0f - 2.0f * (float)i / (float)N_TABLE;
  }
  store[N_TABLE] = store[0];
  static float re[N_TABLE / 2 + 1], im[N_TABLE / 2 + 1];
  le_rfft_fwd(plan_for(N_TABLE), store, re, im);
  /* the forward transform is unnormalised: a bin holds N/2 x amplitude, as
   * build_additive's do */
  w->level[0] = store;
  w->size[0] = N_TABLE;
  w->limit[0] = N_TABLE / 2;
  w->freq_mult = 1.0f;
  w->white = 0;
  w->gain = 1.0f;
  build_copies(w, store, N_TABLE + 1, re, im, N_TABLE / 2);
}

static void build_noise(le_operator_wave* w, float* store, uint32_t seed, int white) {
  uint32_t s = seed;
  for (int32_t i = 0; i < N_TABLE; ++i) store[i] = lcg_bipolar(&s);
  store[N_TABLE] = store[0];
  w->level[0] = store;
  w->size[0] = N_TABLE;
  w->limit[0] = N_TABLE / 2;
  w->levels = 1;
  w->gain = 1.0f;
  w->freq_mult = white ? 1.0f : 1.0f / 64.0f;
  w->white = white;
}

static void tables_build(void) {
  for (int32_t i = 0; i < 7; ++i) le_rfft_plan_init(&g_plans[i], 64 << i);
  static float amp[N_TABLE / 2];
  /* 0..2: Sine, and Sine 4 and 8 Bit (truncated to 8 and 128 steps a unit) */
  for (int32_t w = 0; w < 3; ++w) {
    memset(amp, 0, sizeof(amp));
    amp[1] = 1.0f;
    build_additive(&g_waves[w], g_wave_store[w], amp, 1, 1, 1);
    if (w > 0) {
      const float q = w == 1 ? 8.0f : 128.0f;
      float* t = g_wave_store[w];
      for (int32_t i = 0; i <= N_TABLE; ++i) t[i] = truncf(t[i] * q) / q;
    }
  }
  static const int32_t counts[7] = {3, 4, 6, 8, 16, 32, 64};
  for (int32_t c = 0; c < 7; ++c) {
    /* 3..9: Saw N, the first N harmonics at 2/(pi k) */
    memset(amp, 0, sizeof(amp));
    for (int32_t k = 1; k <= counts[c]; ++k) amp[k] = (float)(2.0 / OP_PI / k);
    build_additive(&g_waves[3 + c], g_wave_store[3 + c], amp, counts[c], 1, 1);
    /* 11..17: Square N, the first N odd harmonics at 4/(pi k) */
    memset(amp, 0, sizeof(amp));
    for (int32_t j = 0; j < counts[c]; ++j) {
      amp[2 * j + 1] = (float)(4.0 / OP_PI / (2 * j + 1));
    }
    build_additive(&g_waves[11 + c], g_wave_store[11 + c], amp, 2 * counts[c] - 1, 1, 1);
  }
  build_drawn(&g_waves[10], g_wave_store[10], 0);
  build_drawn(&g_waves[18], g_wave_store[18], 1);
  /* 19: Triangle, the first 8 odd harmonics, alternating */
  memset(amp, 0, sizeof(amp));
  for (int32_t j = 0; j < 8; ++j) {
    const int32_t k = 2 * j + 1;
    amp[k] = (float)((j % 2 ? -8.0 : 8.0) / (OP_PI * OP_PI * k * k));
  }
  build_additive(&g_waves[19], g_wave_store[19], amp, 15, 1, 1);
  build_noise(&g_waves[20], g_wave_store[20], 0x1234567u, 0);
  build_noise(&g_waves[21], g_wave_store[21], 0x89abcdefu, 1);
}

static void tables_ensure(void) { (void)pthread_once(&g_tables_once, tables_build); }

/* Operator op's user wave from its drawn harmonics. */
static void build_user(le_operator* d, int32_t op) {
  static const float rolloff[6] = {0.0f, 0.25f, 0.5f, 1.0f, 3.0f, 4.0f};
  float amp[N_TABLE / 2];
  float drawn[64];
  const int32_t m = 16 << opi(d, op, LE_OPERATOR_OP_USER_COUNT);
  for (int32_t k = 0; k < 64; ++k) {
    const float v = opf(d, op, LE_OPERATOR_OP_USER_HARMONIC + k);
    drawn[k] = v > 0.0f ? powf(10.0f, (48.0f * v - 48.0f) / 20.0f) : 0.0f;
  }
  const int32_t mode = opi(d, op, LE_OPERATOR_OP_USER_EXPANSION);
  memset(amp, 0, sizeof(amp));
  for (int32_t k = 1; k < N_TABLE / 2; ++k) {
    if (mode == 0) {
      if (k <= m) amp[k] = drawn[k - 1];
    } else {
      amp[k] = drawn[(k - 1) % m] / (1.0f + rolloff[mode] * (float)(k - 1));
    }
  }
  build_additive(&d->user[op], d->user_tables[op], amp, N_TABLE / 2,
                 opi(d, op, LE_OPERATOR_OP_USER_NORMALIZE), 0);
}

static const le_operator_wave* op_wave(const le_operator* d, int32_t op) {
  const int32_t w = opi(d, op, LE_OPERATOR_OP_WAVE);
  return w == 22 ? &d->user[op] : &g_waves[w];
}

/* The table to read for phase increment `inc` (table indices per engine
 * sample): the richest whose top harmonic stays below the engine's Nyquist. */
static int32_t pick_table(const le_operator_wave* w, float inc, int aa) {
  if (!aa) return 0;
  const float step = floorf(inc);
  for (int32_t l = 0; l < w->levels; ++l) {
    if ((float)w->limit[l] * step < (float)(N_TABLE / 2)) return l;
  }
  return w->levels - 1;
}

static float wave_read(const le_operator_wave* w, int32_t level, double pos, int interp) {
  const int32_t size = w->size[level];
  const float* t = w->level[level];
  const double p = pos * (double)size / (double)N_TABLE;
  int32_t i = (int32_t)p;
  if (i >= size) i -= size;
  if (i < 0) i = 0;
  if (!interp) return t[i];
  const float f = (float)(p - (double)(int32_t)p);
  return t[i] + f * (t[i + 1] - t[i]);
}

/* ---- algorithms ---- */

/* kModBy[alg][op]: the operators modulating op (a bit per operator, A = 1);
 * kCarriers[alg]: the operators that sound. */
static const uint8_t kModBy[11][4] = {
    {2, 4, 8, 0},     /* 0: D -> C -> B -> A */
    {2, 12, 0, 0},    /* 1: (C + D) -> B -> A */
    {10, 4, 0, 0},    /* 2: C -> B, (B + D) -> A */
    {6, 8, 8, 0},     /* 3: D -> B, D -> C, (B + C) -> A */
    {4, 4, 8, 0},     /* 4: D -> C -> A and B */
    {0, 4, 8, 0},     /* 5: D -> C -> B, A alone */
    {14, 0, 0, 0},    /* 6: (B + C + D) -> A */
    {2, 0, 8, 0},     /* 7: B -> A, D -> C */
    {8, 8, 8, 0},     /* 8: D -> A, B, C */
    {0, 0, 8, 0},     /* 9: D -> C, B, A */
    {0, 0, 0, 0},     /* 10: additive */
};
static const uint8_t kCarriers[11] = {1, 1, 1, 1, 3, 3, 1, 5, 7, 7, 15};

/* ---- envelopes ---- */

/* how close a slope-1 segment comes to its target: about -84 dB */
#define ENV_EPS 6.3095734e-5

/* One envelope's stored fields, starting at parameter `base`. */
typedef struct env_def {
  float at, al, as, dt, dl, ds, sl, rt, rl, rs, loop_ms, tvel;
  int32_t loop, repeat;
  int32_t curved; /* slopes other than 0 and 1 follow the curved shape */
} env_def;

static env_def read_env(const le_operator* d, int32_t base) {
  const float* v = d->values + base;
  env_def e;
  e.at = v[LE_OPERATOR_ENV_ATTACK_TIME];
  e.al = v[LE_OPERATOR_ENV_ATTACK_LEVEL];
  e.as = v[LE_OPERATOR_ENV_ATTACK_SLOPE];
  e.dt = v[LE_OPERATOR_ENV_DECAY_TIME];
  e.dl = v[LE_OPERATOR_ENV_DECAY_LEVEL];
  e.ds = v[LE_OPERATOR_ENV_DECAY_SLOPE];
  e.sl = v[LE_OPERATOR_ENV_SUSTAIN];
  e.rt = v[LE_OPERATOR_ENV_RELEASE_TIME];
  e.rl = v[LE_OPERATOR_ENV_RELEASE_LEVEL];
  e.rs = v[LE_OPERATOR_ENV_RELEASE_SLOPE];
  e.loop = (int32_t)v[LE_OPERATOR_ENV_LOOP_MODE];
  e.loop_ms = v[LE_OPERATOR_ENV_LOOP_TIME];
  e.repeat = (int32_t)v[LE_OPERATOR_ENV_REPEAT];
  e.tvel = v[LE_OPERATOR_ENV_TIME_VEL];
  e.curved = 0;
  /* an operator's or the LFO's level at its -70 dB floor is silence */
  if (base < LE_OPERATOR_ALGORITHM || base == LE_OPERATOR_LFO_ENV) {
    float* lv[4] = {&e.al, &e.dl, &e.sl, &e.rl};
    for (int32_t i = 0; i < 4; ++i) {
      if (*lv[i] <= 0.00031623f) *lv[i] = 0.0f;
    }
  }
  return e;
}

/* The pitch envelope runs on its levels in semitones (its route output
 * moves linearly in them: measured); a voice's pitch takes
 * 2^(level x amount / 12). */
static env_def pitch_env(const le_operator* d) { return read_env(d, LE_OPERATOR_PITCH_ENV); }

/* RepeatTime's note values, in beats. */
static const float kRepeatBeats[15] = {1.0f / 12, 0.125f, 1.0f / 6, 0.25f, 1.0f / 3,
                                       0.5f, 2.0f / 3, 1.0f, 4.0f / 3, 2.0f,
                                       4.0f, 6.0f, 8.0f, 12.0f, 16.0f};

/* Starts a segment from the current value to `y1` over `ms` x `f`
 * milliseconds with slope `s`. */
static void env_segment(le_operator_env* e, int32_t state, float y1, float ms, float f,
                        float s, float rate) {
  e->state = state;
  e->y0 = e->y;
  e->y1 = y1;
  e->s = s;
  double n = (double)ms * (double)rate / 1000.0 * (double)f;
  if (n < 1.0) n = 1.0;
  e->t = 0.0;
  e->dt = 1.0 / n;
  /* slope 1: a one-pole that comes within ENV_EPS of the target as its time
   * runs out, its span measured in the scaled level. The pitch envelope's
   * keeps one shape whatever its span, reaching 10^-3.95 of it (the curve's
   * constant): falls and rises of 2 to 24 semitones at amounts 0.5 to 1
   * all want the same rate (measured: round 9's penvd renders, the span
   * the old rule would need 0.44 to 0.66 of a ratio unit every time) */
  if (e->pitch) {
    e->c = 9.0949 / fmax(n, 10.0);
    return;
  }
  const double d0 = ((double)e->y0 - (double)y1) * (double)e->scale;
  const double span = fmax(fabs(d0), 2.0 * ENV_EPS);
  e->c = log(span / ENV_EPS) / fmax(n, 10.0);
}

/* The time factors: velocity (per envelope) and key and EnvTime (shared). */
static float env_vel_factor(const env_def* e, float vel127) {
  return exp2f(-8.0f * (e->tvel / 100.0f) * (vel127 - 70.0f) / 127.0f);
}

typedef struct env_ctx {
  float rate;
  float fglob;  /* EnvTime and its key scaling */
  float bpm;
  double clock; /* the device clock at the chunk, samples (Sync's grid) */
} env_ctx;

/* from_initial: 1 at a note (a minimal attack starts at the peak), 2 at a
 * loop's restart (it runs even a minimal attack: measured, Geigerzaehler
 * Bleep and round 9 loop-minatt), 0
 * from the current value (Beat and Sync). */
static void env_attack(le_operator_env* e, const env_def* p, float fv, const env_ctx* c,
                       int from_initial) {
  const float fa = fv * c->fglob;
  if (from_initial) {
    if (p->at <= 0.11f && from_initial == 1) {
      /* a minimal attack starts at the peak */
      e->y = p->dl;
      env_segment(e, ENV_DECAY, p->sl, p->dt, fv * c->fglob, p->ds, c->rate);
      return;
    }
    e->y = p->al;
  }
  env_segment(e, ENV_ATTACK, p->dl, p->at, fa, p->as, c->rate);
}

static void env_start(le_operator_env* e, const env_def* p, float fv, const env_ctx* c) {
  env_attack(e, p, fv, c, 1);
  const double period = (double)kRepeatBeats[p->repeat] * 60.0 / (double)c->bpm * (double)c->rate;
  e->repeat = period;
  if (p->loop == LOOP_SYNC) {
    /* Sync: the first retrigger a period after the note, moved on to the
     * next sixteenth of the device clock; the rest a period apart
     * (measured: a note 0.1 s into the song retriggers at 0.25, 0.375 ..) */
    const double grid = 0.25 * 60.0 / (double)c->bpm * (double)c->rate;
    const double at = c->clock + period;
    e->repeat = ceil(at / grid - 1e-6) * grid - c->clock;
  }
}

static void env_release(le_operator_env* e, const env_def* p, float fv, const env_ctx* c) {
  if (e->state == ENV_OFF || e->state == ENV_RELEASE || p->loop == LOOP_TRIGGER) return;
  env_segment(e, ENV_RELEASE, p->rl, p->rt, fv * c->fglob, p->rs, c->rate);
}

/* The curved segment from y0 to y1 at progress t for slope s: a crossfade
 * between the straight line (1 - |s|) and an exponential shape (|s|), fast
 * first for s > 0 and its mirror for s < 0, reaching 10^-3.95 of the span. */
#define ENV_CURVE_K 9.0949f
static float env_curve(float y0, float y1, float s, double t) {
  const float a = fabsf(s);
  const float tt = (float)t;
  float g;
  if (s > 0.0f) {
    g = (expf(-ENV_CURVE_K * tt) - expf(-ENV_CURVE_K)) / (1.0f - expf(-ENV_CURVE_K));
  } else {
    g = (expf(ENV_CURVE_K) - expf(ENV_CURVE_K * tt)) / (expf(ENV_CURVE_K) - 1.0f);
  }
  return y1 + (y0 - y1) * ((1.0f - a) * (1.0f - tt) + a * g);
}

/* One sample of `e`; returns its value. */
static float env_tick(le_operator_env* e, const env_def* p, float fv, const env_ctx* c) {
  if (p->loop == LOOP_BEAT || p->loop == LOOP_SYNC) {
    e->repeat -= 1.0;
    /* the retrigger falls a whole period after its start, so one due at a
     * note-off finds the release begun (measured: round 7's sync and beat
     * renders, 0.69 dB to 0.14; held out, Pure Bell 8ths 6.0 to 0.1) */
    if (e->repeat < 0.0) {
      e->repeat += (double)kRepeatBeats[p->repeat] * 60.0 / (double)c->bpm * (double)c->rate;
      if (e->state != ENV_RELEASE && e->state != ENV_OFF) env_attack(e, p, fv, c, 0);
    }
  }
  if (e->state == ENV_SUSTAIN) {
    e->y = p->sl;
    return e->y;
  }
  if (e->state == ENV_OFF) return e->y;
  e->t += e->dt;
  /* a segment lasts its time rounded up to whole samples, with no sample
   * lost to rounding (measured: round 9 loop-minatt, 3029 samples a cycle
   * for 0.1 + 13 + 50 ms, the first 3024) */
  if (e->t >= 1.0 - 1e-9) {
    e->y = e->y1;
    switch (e->state) {
      case ENV_ATTACK:
        env_segment(e, ENV_DECAY, p->sl, p->dt, fv * c->fglob, p->ds, c->rate);
        break;
      case ENV_DECAY:
        if (p->loop == LOOP_TRIGGER) {
          env_segment(e, ENV_RELEASE, p->rl, p->rt, fv * c->fglob, p->rs, c->rate);
        } else if (p->loop == LOOP_LOOP) {
          env_segment(e, ENV_LOOP, p->al, p->loop_ms, fv * c->fglob, 0.0f, c->rate);
        } else {
          e->state = ENV_SUSTAIN;
        }
        break;
      case ENV_LOOP:
        env_attack(e, p, fv, c, 2);
        break;
      default:
        e->state = ENV_OFF;
        break;
    }
    return e->y;
  }
  if (e->s == 0.0f) {
    e->y = e->y0 + (e->y1 - e->y0) * (float)e->t;
  } else if (e->s == 1.0f) {
    e->y += (float)e->c * (e->y1 - e->y);
  } else if (p->curved) {
    e->y = env_curve(e->y0, e->y1, e->s, e->t);
  }
  /* On an operator's or the LFO's envelope any other slope holds the start
   * value until the segment ends, then jumps to the target: what Live
   * 12.2.7 renders for every slope but 0 and 1 (fit: measured at -0.95 ..
   * 0.5 on attack, decay and release). The filter and pitch envelopes
   * follow the curved shape (measured: Analog Bouquet Brass). */
  return e->y;
}

/* The pitch envelope's frequency ratio at level y (semitones) of segment
 * `e`: the segment interpolates between its ends' ratios, at the progress
 * y has made in semitones (Live's pitch moves linearly in ratio, its route
 * output linearly in semitones: both measured). `a` is the amount over 12. */
static float penv_ratio(float y, const le_operator_env* e, float a) {
  const float span = e->y1 - e->y0;
  if (e->state == ENV_SUSTAIN || e->state == ENV_OFF || fabsf(span) < 1e-6f) {
    return exp2f(y * a);
  }
  const float r0 = exp2f(e->y0 * a), r1 = exp2f(e->y1 * a);
  return r0 + (r1 - r0) * (y - e->y0) / span;
}

/* ---- init and parameters ---- */

static void mark_user_changes(le_operator* d, const float* old) {
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    const int32_t b = LE_OPERATOR_OP(op, LE_OPERATOR_OP_USER_COUNT);
    if (memcmp(old + b, d->values + b, sizeof(float) * 67) != 0) d->user_dirty |= 1u << op;
  }
}

int32_t le_operator_init(le_operator* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  tables_ensure();
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_OPERATOR_VOICE_SLOTS;
  d->rng = 0x2545f491u;
  for (int32_t p = 0; p < LE_OPERATOR_PARAMS; ++p) d->values[p] = param_def(p).def;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) build_user(d, op);
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    d->voices[i].rng = 0x9e3779b9u ^ (uint32_t)(i * 2654435761u);
  }
  return 0;
}

void le_operator_set_values(le_operator* d, const float* values) {
  if (d == NULL || values == NULL) return;
  float old[LE_OPERATOR_PARAMS];
  memcpy(old, d->values, sizeof(old));
  for (int32_t p = 0; p < LE_OPERATOR_PARAMS; ++p) {
    d->values[p] = le_operator_clamp(p, values[p]);
  }
  mark_user_changes(d, old);
}

void le_operator_set_tempo(le_operator* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

/* ---- modulation routes ---- */

/* A voice's modulation (measured against Live's renders). Each source has
 * a bipolar value s and a unipolar one u: velocity s = 2v - 1 (u = v), the
 * key s = (key - neutral) / 63.5, pitch bend s = bend, the LFO s = its
 * output, the pitch envelope s = its level / 48 semitones, each with
 * u = (s + 1) / 2; aftertouch and the mod wheel have s = u = their value,
 * resting at 0. An adding destination takes amount x s; a gain destination
 * (the volumes, FM Drive, LFO Amount, Filter Env amount, Tone) only
 * attenuates, by 1 - a+ + a u (a+ the amount's positive part): a full
 * positive amount spans 0 .. 1 over its source, a negative one 1 .. 0. LFO
 * Rate takes the gain sum in octaves (8 per unit), the LFO's own route
 * adding. The LFO's and the pitch envelope's routes scale with their own
 * amounts and are silent while they are off. */
typedef struct op_mods {
  float m[LE_OPERATOR_DESTS];  /* the adding sum: amount x s */
  float g[LE_OPERATOR_DESTS];  /* the gain sum: amount x u - a+ */
  float bi[LE_OPERATOR_DESTS]; /* amount x (2u - 1): u made bipolar */
  float lfo_rate;              /* LFO Rate, octaves */
  float time;                  /* Time, octaves */
} op_mods;

static void route_add(op_mods* r, int32_t dst, float amount, float sb, float su) {
  r->m[dst] += amount * sb;
  r->g[dst] += amount * su - fmaxf(amount, 0.0f);
  r->bi[dst] += amount * (2.0f * su - 1.0f);
}

/* `lfo` the LFO's output (shape x envelope), `penv_st` the pitch envelope's
 * level in semitones. */
static void route_mods(const le_operator* d, const le_operator_voice* v, float lfo, float penv_st,
                       int with_lfo, op_mods* r) {
  memset(r, 0, sizeof(*r));
  if (with_lfo && vi(d, LE_OPERATOR_LFO_ON)) {
    const float s = clampf(lfo, -1.0f, 1.0f);
    route_add(r, vi(d, LE_OPERATOR_LFO_DEST),
              vf(d, LE_OPERATOR_LFO_DEST_AMOUNT) / 100.0f * vf(d, LE_OPERATOR_LFO_AMOUNT), s,
              0.5f * (s + 1.0f));
  }
  if (vi(d, LE_OPERATOR_PITCH_ENV_ON)) {
    const float s = clampf(penv_st / 48.0f, -1.0f, 1.0f);
    route_add(r, vi(d, LE_OPERATOR_PITCH_ENV_DEST),
              vf(d, LE_OPERATOR_PITCH_ENV_DEST_AMOUNT) / 100.0f * vf(d, LE_OPERATOR_PITCH_ENV_AMOUNT),
              s, 0.5f * (s + 1.0f));
  }
  const float sv = 2.0f * v->velocity - 1.0f;
  const float sk = clampf(((float)VKEY(v) - vf(d, LE_OPERATOR_ROUTE_NEUTRAL_KEY)) / 63.5f, -1.0f, 1.0f);
  const float sb[LE_OPERATOR_ROUTE_SOURCES] = {sv, sk, d->pressure, d->bend, d->mod};
  const float su[LE_OPERATOR_ROUTE_SOURCES] = {v->velocity, 0.5f * (sk + 1.0f), d->pressure,
                                               0.5f * (d->bend + 1.0f), d->mod};
  for (int32_t k = 0; k < LE_OPERATOR_ROUTE_SOURCES; ++k) {
    for (int32_t j = 0; j < 2; ++j) {
      const int32_t p = LE_OPERATOR_ROUTE + k * 4 + j * 2;
      route_add(r, vi(d, p), vf(d, p + 1) / 100.0f, sb[k], su[k]);
    }
  }
  r->m[DST_OFF] = r->g[DST_OFF] = 0.0f;
  /* LFO Rate: 8 octaves per unit of amount x (2u - 1), so aftertouch and
   * the mod wheel at rest count as -1 there (measured: +20 % at rest slows
   * the rate 1.6 octaves, -20 % speeds it 1.6) */
  r->lfo_rate = 8.0f * r->bi[DST_LFO_RATE];
  r->time = 3.0f * r->m[DST_TIME]; /* 3 octaves per unit */
}

static float route_gain(const op_mods* r, int32_t dst) {
  return clampf(1.0f + r->g[dst], 0.0f, 1.0f);
}

/* Filter Freq: 48 semitones per unit; Time: 3 octaves of envelope time;
 * Fixed Frequency: 63 semitones; LFO Rate: 8 octaves (measured or read). */
#define OP_FILTER_K 48.0f
#define OP_TIME_K 3.0f

static float lfo_periodic(int32_t type, double u);
static float op_amp(const le_operator* d, const le_operator_voice* v, int32_t op);

/* ---- voices ---- */


/* Spread in whole percent: Live plays 0.5 % as off and 1 % as Spread
 * (measured) */
static float spread_pct(const le_operator* d) { return floorf(vf(d, LE_OPERATOR_SPREAD)); }

static const int32_t kVoiceCounts[16] = {1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 32, 48};

static int sounding(const le_operator_voice* v) {
  return v->state == LE_OPERATOR_VOICE_HELD || v->state == LE_OPERATOR_VOICE_RELEASED ||
         v->state == LE_OPERATOR_VOICE_SUSTAINED;
}

static void fade_voice(le_operator_voice* v) {
  if (v->state == LE_OPERATOR_VOICE_FREE) return;
  v->state = LE_OPERATOR_VOICE_FADING;
  if (v->fade <= 0.0f) v->fade = 1.0f;
}

/* Fades every voice of the note `serial` started (a Spread pair). */
static void fade_note(le_operator* d, uint64_t serial) {
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    if (d->voices[i].state != LE_OPERATOR_VOICE_FREE && d->voices[i].serial == serial) {
      fade_voice(&d->voices[i]);
    }
  }
}

static int32_t note_count(const le_operator* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    n += sounding(&d->voices[i]) && d->voices[i].side != SIDE_RIGHT;
  }
  return n;
}

/* Notes allowed: Live's count, within the voice limit (a Spread note takes
 * two voices). */
static int32_t voice_count(const le_operator* d) {
  int32_t n = kVoiceCounts[vi(d, LE_OPERATOR_VOICES)];
  const int32_t lim = spread_pct(d) > 0.0f ? d->voice_limit / 2 : d->voice_limit;
  if (n > lim) n = lim;
  return n < 1 ? 1 : n;
}

/* The oldest note in `state`, or NULL. */
static le_operator_voice* oldest(le_operator* d, int32_t state) {
  le_operator_voice* old = NULL;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    le_operator_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

/* A voice slot to start in: a free one, or the oldest fading one. */
static le_operator_voice* free_slot(le_operator* d) {
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_OPERATOR_VOICE_FREE) return &d->voices[i];
  }
  le_operator_voice* v = oldest(d, LE_OPERATOR_VOICE_FADING);
  if (v != NULL) return v;
  return oldest(d, LE_OPERATOR_VOICE_RELEASED);
}

static env_ctx make_ctx(const le_operator* d, int32_t note, float rate, float time_mod) {
  env_ctx c;
  c.rate = rate;
  c.fglob = time_mod * exp2f(3.0f * vf(d, LE_OPERATOR_ENV_TIME) / 100.0f -
                  6.0f * (vf(d, LE_OPERATOR_ENV_TIME_KEY) / 100.0f) * ((float)note - 70.0f) / 127.0f);
  c.bpm = d->bpm;
  c.clock = d->clock;
  return c;
}

static float penv_amount(const le_operator* d) {
  return vf(d, LE_OPERATOR_PITCH_ENV_AMOUNT) * (vf(d, LE_OPERATOR_PITCH_ENV_AMOUNT_A) / 100.0f);
}

static void start_envelopes(le_operator* d, le_operator_voice* v) {
  const float rate = (float)d->sample_rate;
  const env_ctx c = make_ctx(d, VKEY(v), rate, v->time_mod);
  const float vel127 = v->velocity * 127.0f;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    const env_def e = read_env(d, LE_OPERATOR_OP(op, LE_OPERATOR_OP_ENV));
    env_start(&v->env[op], &e, env_vel_factor(&e, vel127), &c);
  }
  env_def e = read_env(d, LE_OPERATOR_FILTER_ENV);
  env_start(&v->fenv, &e, env_vel_factor(&e, vel127), &c);
  e = pitch_env(d);
  env_start(&v->penv, &e, env_vel_factor(&e, vel127), &c);
  e = read_env(d, LE_OPERATOR_LFO_ENV);
  env_start(&v->lenv, &e, env_vel_factor(&e, vel127), &c);
}

static void start_voice(le_operator* d, le_operator_voice* v, uint32_t origin, int32_t note,
                        float vel, uint64_t serial, int32_t side, float pan_rnd, int glide) {
  const uint32_t rng = v->rng;
  memset(v, 0, sizeof(*v));
  v->rng = rng;
  v->state = LE_OPERATOR_VOICE_HELD;
  v->note = note;
  v->key = note;
  v->origin = origin;
  v->serial = serial;
  v->side = side;
  v->velocity = vel;
  const float spread = spread_pct(d) / 100.0f;
  v->detune = side == SIDE_LEFT ? -0.1f * spread : side == SIDE_RIGHT ? 0.1f * spread : 0.0f;
  v->pan = (vf(d, LE_OPERATOR_PAN_KEY) / 100.0f) * ((float)note - 60.0f) / 64.0f +
           (vf(d, LE_OPERATOR_PAN_RANDOM) / 100.0f) * 2.0f * pan_rnd;
  /* glide: from the last played note when portamento is on */
  v->pitch = (float)note;
  if (glide) {
    const int32_t chunks = (int32_t)(vf(d, LE_OPERATOR_GLIDE_TIME) * (float)d->sample_rate /
                                     1000.0f / (float)LE_OPERATOR_CHUNK);
    v->glide_chunks = chunks < 1 ? 1 : chunks;
    v->pitch = d->last_pitch;
    v->pitch_step = ((float)note - d->last_pitch) / (float)v->glide_chunks;
  }
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    const float u = opi(d, op, LE_OPERATOR_OP_RETRIGGER) ? opf(d, op, LE_OPERATOR_OP_PHASE) / 100.0f
                                                         : lcg_unit(&v->rng);
    v->phase[op] = floor((double)u * N_TABLE);
  }
  v->lfo_phase = vi(d, LE_OPERATOR_LFO_RETRIGGER) ? 0.0 : d->lfo_free - floor(d->lfo_free);
  v->lfo_sh = lcg_bipolar(&v->rng);
  /* the shape smoother starts at the shape's first value */
  v->lfo_lp = v->lfo_lp_x = lfo_periodic(vi(d, LE_OPERATOR_LFO_TYPE) <= 4 ? vi(d, LE_OPERATOR_LFO_TYPE) : 0, v->lfo_phase);
  {
    op_mods rm;
    route_mods(d, v, 0.0f, 0.0f, 1, &rm);
    v->time_mod = exp2f(rm.time);
  }
  /* an envelope's one-pole runs on its level times its scale: an operator's
   * amplitude, 1 for the others */
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) v->env[op].scale = op_amp(d, v, op);
  v->fenv.scale = v->penv.scale = v->lenv.scale = 1.0f;
  v->penv.pitch = 1;
  start_envelopes(d, v);
  v->gl = v->gr = -1.0f; /* set at the first chunk without a ramp */
}

static void held_push(le_operator* d, uint32_t origin, int32_t note) {
  if (d->held_n == LE_OPERATOR_HELD_MAX) {
    memmove(d->held_note, d->held_note + 1, sizeof(int32_t) * (LE_OPERATOR_HELD_MAX - 1));
    memmove(d->held_origin, d->held_origin + 1, sizeof(uint32_t) * (LE_OPERATOR_HELD_MAX - 1));
    d->held_n--;
  }
  d->held_note[d->held_n] = note;
  d->held_origin[d->held_n] = origin;
  d->held_n++;
}

static void held_drop(le_operator* d, uint32_t origin) {
  int32_t keep = 0;
  for (int32_t i = 0; i < d->held_n; ++i) {
    if (d->held_origin[i] == origin) continue;
    d->held_note[keep] = d->held_note[i];
    d->held_origin[keep] = d->held_origin[i];
    keep++;
  }
  d->held_n = keep;
}

static void release_voice(le_operator* d, le_operator_voice* v) {
  v->state = LE_OPERATOR_VOICE_RELEASED;
  const env_ctx c = make_ctx(d, VKEY(v), (float)d->sample_rate, v->time_mod);
  const float vel127 = v->velocity * 127.0f;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    const env_def e = read_env(d, LE_OPERATOR_OP(op, LE_OPERATOR_OP_ENV));
    env_release(&v->env[op], &e, env_vel_factor(&e, vel127), &c);
  }
  env_def e = read_env(d, LE_OPERATOR_FILTER_ENV);
  env_release(&v->fenv, &e, env_vel_factor(&e, vel127), &c);
  e = pitch_env(d);
  env_release(&v->penv, &e, env_vel_factor(&e, vel127), &c);
  e = read_env(d, LE_OPERATOR_LFO_ENV);
  env_release(&v->lenv, &e, env_vel_factor(&e, vel127), &c);
}

static void let_go(le_operator* d, le_operator_voice* v) {
  if (d->sustain_n > 0) {
    v->state = LE_OPERATOR_VOICE_SUSTAINED;
  } else {
    release_voice(d, v);
  }
}

int32_t le_operator_note_on(le_operator* d, uint32_t origin, int32_t note, int32_t velocity,
                            int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  const float vel = (float)velocity / 127.0f;
  if (!chord) {
    for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
      le_operator_voice* v = &d->voices[i];
      if (v->state == LE_OPERATOR_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
    held_drop(d, origin);
  }
  const int32_t count = voice_count(d);
  /* mono legato: with portamento on, a held voice glides to the new note */
  if (count == 1 && vi(d, LE_OPERATOR_GLIDE_ON) && d->held_n > 0) {
    int retuned = 0;
    for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
      le_operator_voice* v = &d->voices[i];
      if (v->state != LE_OPERATOR_VOICE_HELD) continue;
      const int32_t chunks = (int32_t)(vf(d, LE_OPERATOR_GLIDE_TIME) * (float)d->sample_rate /
                                       1000.0f / (float)LE_OPERATOR_CHUNK);
      v->glide_chunks = chunks < 1 ? 1 : chunks;
      v->pitch_step = ((float)note - v->pitch) / (float)v->glide_chunks;
      /* a voice that has just taken a sounding voice's place (and so starts
       * at its own pitch) takes the chord's later notes at theirs too
       * (measured: Harsh FM Bass, round 8, 1.9 dB to 1.1) */
      if (v->snap) {
        v->glide_chunks = 0;
        v->pitch = (float)note;
      }
      v->note = note;
      v->origin = origin;
      retuned = 1;
    }
    /* a held key whose voice was taken (the voice budget) starts afresh */
    if (retuned) {
      held_push(d, origin, note);
      d->last_pitch = (float)note;
      return 0;
    }
  }
  held_push(d, origin, note);
  /* a new voice glides from the last note only while some voice sounds */
  int glide = vi(d, LE_OPERATOR_GLIDE_ON) && d->played && le_operator_active(d) > 0;
  int took = 0;
  if (vi(d, LE_OPERATOR_RETRIGGER_MODE)) {
    for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
      le_operator_voice* v = &d->voices[i];
      if (sounding(v) && v->note == note) {
        fade_voice(v);
        took = 1;
      }
    }
  }
  while (note_count(d) >= count) {
    le_operator_voice* v = oldest(d, LE_OPERATOR_VOICE_RELEASED);
    if (v == NULL) v = oldest(d, LE_OPERATOR_VOICE_SUSTAINED);
    if (v == NULL) v = oldest(d, LE_OPERATOR_VOICE_HELD);
    if (v == NULL) break;
    fade_note(d, v->serial);
    d->stolen++;
    took = 1;
  }
  /* a note that takes a sounding voice's place starts at its own pitch */
  if (took) glide = 0;
  const uint64_t serial = ++d->serial;
  const float pan_rnd = lcg_bipolar(&d->rng);
  if (spread_pct(d) > 0.0f) {
    le_operator_voice* a = free_slot(d);
    if (a != NULL) start_voice(d, a, origin, note, vel, serial, SIDE_LEFT, pan_rnd, glide);
    le_operator_voice* b = free_slot(d);
    if (b != NULL) start_voice(d, b, origin, note, vel, serial, SIDE_RIGHT, pan_rnd, glide);
  } else {
    le_operator_voice* a = free_slot(d);
    if (a != NULL) start_voice(d, a, origin, note, vel, serial, SIDE_BOTH, pan_rnd, glide);
  }
  if (took) {
    for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
      if (d->voices[i].serial == serial) d->voices[i].snap = 1;
    }
  }
  d->last_pitch = (float)note;
  d->played = 1;
  return 0;
}

void le_operator_note_off(le_operator* d, uint32_t origin) {
  if (d == NULL) return;
  held_drop(d, origin);
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    le_operator_voice* v = &d->voices[i];
    if (v->state == LE_OPERATOR_VOICE_HELD && v->origin == origin) let_go(d, v);
  }
}

static void release_sustained(le_operator* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_OPERATOR_VOICE_SUSTAINED) release_voice(d, &d->voices[i]);
  }
}

int32_t le_operator_sustain(le_operator* d, uint32_t origin, int on) {
  if (d == NULL) return -1;
  int32_t at = -1;
  for (int32_t i = 0; i < d->sustain_n; ++i) {
    if (d->sustain[i] == origin) at = i;
  }
  if (!on) {
    if (at >= 0) {
      d->sustain[at] = d->sustain[--d->sustain_n];
      release_sustained(d);
    }
    return 0;
  }
  if (at >= 0) return 0;
  if (d->sustain_n >= LE_OPERATOR_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_operator_expression(le_operator* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = clampf(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_operator_release_matching(le_operator* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = d->held_n - 1; i >= 0; --i) {
    if (i < d->held_n && (d->held_origin[i] & mask) == value) held_drop(d, d->held_origin[i]);
  }
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    le_operator_voice* v = &d->voices[i];
    if (v->state == LE_OPERATOR_VOICE_HELD && (v->origin & mask) == value) {
      let_go(d, v);
    } else if (v->state == LE_OPERATOR_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(d, v);
    }
  }
}

int32_t le_operator_held(const le_operator* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    const le_operator_voice* v = &d->voices[i];
    if (v->state == LE_OPERATOR_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_operator_cut(le_operator* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->held_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_operator_fade_oldest(le_operator* d) {
  if (d == NULL) return 0;
  le_operator_voice* old = NULL;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    le_operator_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  const int32_t before = le_operator_active(d);
  fade_note(d, old->serial);
  d->stolen++;
  return before - le_operator_active(d);
}

int32_t le_operator_active(const le_operator* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

int32_t le_operator_fading(const le_operator* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    n += d->voices[i].state == LE_OPERATOR_VOICE_FADING;
  }
  return n;
}

void le_operator_set_voice_limit(le_operator* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_OPERATOR_VOICE_SLOTS ? LE_OPERATOR_VOICE_SLOTS : limit;
  while (le_operator_active(d) > d->voice_limit) {
    if (!le_operator_fade_oldest(d)) break;
  }
}

/* ---- the LFO ---- */

static const float kSyncBeats[15] = {1.0f / 12, 0.125f, 1.0f / 6, 0.25f, 1.0f / 3,
                                     0.5f, 2.0f / 3, 1.0f, 4.0f / 3, 2.0f,
                                     4.0f, 6.0f, 8.0f, 12.0f, 16.0f};

/* The LFO's rate in Hz for `note`, before rate modulation; `keyed` adds the
 * key scaling. */
static float lfo_hz(const le_operator* d, int32_t note, int keyed) {
  const int32_t range = vi(d, LE_OPERATOR_LFO_RANGE);
  if (range == 2) {
    return d->bpm / 60.0f / kSyncBeats[vi(d, LE_OPERATOR_LFO_SYNCED_RATE)];
  }
  float n = vf(d, LE_OPERATOR_LFO_RATE) - (range == 0 ? 104.0f : 0.0f);
  if (keyed) n += ((float)note - 60.0f) * vf(d, LE_OPERATOR_LFO_RATE_KEY);
  return 440.0f * exp2f((n - 69.0f) / 12.0f);
}

/* A periodic shape at phase u (0..1), read as from a 512-entry table. */
static float lfo_periodic(int32_t type, double u) {
  const float q = (float)u;
  switch (type) {
    case 0: return sinf((float)(2.0 * OP_PI) * q);
    case 1: return q < 0.5f ? 1.0f : -1.0f;
    case 2: return q < 0.5f ? 4.0f * q - 1.0f : 3.0f - 4.0f * q; /* from -1, rising */
    case 3: return 2.0f * q - 1.0f;
    default: return 1.0f - 2.0f * q;
  }
}

/* Per-chunk LFO coefficients of a voice. */
typedef struct lfo_coef {
  float inc;            /* cycles per sample */
  float lp_b, lp_a;     /* the shape smoother (bilinear one-pole) */
  float bp_b0, bp_a1, bp_a2; /* the noise band-pass (b1 = 0, b2 = -b0) */
  float fl_c;           /* the filter path's smoother coefficient */
} lfo_coef;

static float lfo_sample(le_operator_voice* v, int32_t type, const lfo_coef* c) {
  float y;
  if (type <= 4) {
    const float s = lfo_periodic(type, v->lfo_phase);
    y = c->lp_b * (s + v->lfo_lp_x) - c->lp_a * v->lfo_lp;
    v->lfo_lp_x = s;
    v->lfo_lp = y;
  } else if (type == 5) {
    v->lfo_hold += c->inc;
    if (v->lfo_hold >= 0.5f) {
      v->lfo_hold -= 0.5f * floorf(v->lfo_hold / 0.5f);
      v->lfo_sh = lcg_bipolar(&v->rng);
    }
    y = v->lfo_sh;
  } else {
    const float x = 4.0f * lcg_bipolar(&v->rng);
    /* direct form I: lfo_bp = x1, x2, y1, y2 */
    y = c->bp_b0 * (x - v->lfo_bp[1]) - c->bp_a1 * v->lfo_bp[2] - c->bp_a2 * v->lfo_bp[3];
    v->lfo_bp[1] = v->lfo_bp[0];
    v->lfo_bp[0] = x;
    v->lfo_bp[3] = v->lfo_bp[2];
    v->lfo_bp[2] = y;
  }
  v->lfo_phase += c->inc;
  if (v->lfo_phase >= 1.0) v->lfo_phase -= floor(v->lfo_phase);
  return y;
}

static lfo_coef lfo_coefs(float f, float rate) {
  lfo_coef c;
  f = clampf(f, 0.001f, 18500.0f);
  c.inc = f / rate;
  float fc = fmaxf(16.0f * f, 200.0f);
  if (fc > 0.49f * rate) fc = 0.49f * rate;
  const float t = tanf((float)OP_PI * fc / rate);
  c.lp_b = t / (1.0f + t);
  c.lp_a = (t - 1.0f) / (1.0f + t);
  float f0 = fmaxf(f, 5.0f);
  if (f0 > 0.95f * 0.5f * rate) f0 = 0.95f * 0.5f * rate;
  const float w0 = 2.0f * (float)OP_PI * f0 / rate;
  const float sw = sinf(w0);
  const float alpha = sw * sinhf(0.5f * logf(2.0f) * 1.0f * w0 / sw);
  const float a0 = 1.0f + alpha;
  c.bp_b0 = alpha / a0;
  c.bp_a1 = -2.0f * cosf(w0) / a0;
  c.bp_a2 = (1.0f - alpha) / a0;
  /* the filter path's smoother cutoff falls for fast LFOs */
  float sc = f < 25.0f ? 200.0f : 200.0f - 185.0f * (f - 25.0f) / 35.0f;
  if (sc < 15.0f) sc = 15.0f;
  c.fl_c = 1.0f - expf(-2.0f * (float)OP_PI * sc / rate);
  return c;
}

/* ---- the filter ---- */

/* The circuits. */
enum { CIRC_CLEAN = 0, CIRC_OSR, CIRC_MS2, CIRC_SMP, CIRC_PRD, CIRC_MS2_HP };

/* MS2's and SMP's high-pass: a linear state-variable section's high output
 * plus c x its band output, so it falls 12 dB an octave just below the
 * cutoff and 6 below c x cutoff, damped by 0.37 + 1.26 (1 - q)^1.32 (q
 * at most 1: it does not self-oscillate) (fit: the HP renders' third-octave
 * bands at resonance 0, 0.5 and 1, c 0.43 for MS2 and 0.49 for SMP) */
#ifndef OP_MS2_HP_C
#define OP_MS2_HP_C 0.43f
#endif
#ifndef OP_SMP_FB
#define OP_SMP_FB 0.85f /* fit: the SMP renders' levels (0.904 reads too resonant) */
#endif
#ifndef OP_SMP_HP_C
#define OP_SMP_HP_C 0.49f
#endif

/* Per-chunk filter targets: the Clean filter's ramped coefficients, and
 * the cutoff, resonance and drive the analog circuits take per chunk. */
typedef struct filter_target {
  float g, q;
  float w[3];
  float fc, r, drive;
} filter_target;

static void morph_weights(float m, float* w) {
  m = m - floorf(m);
  const float u = 4.0f * m;
  const float cl = clampf(fabsf(u - 1.5f) - 0.5f, 0.0f, 1.0f);
  const float ch = clampf(1.5f - fabsf(u - 2.5f), 0.0f, 1.0f);
  const float s = cl + ch;
  w[0] = cl;
  w[1] = sqrtf(fmaxf(0.0f, 1.0f - s * s));
  w[2] = ch;
}

/* One Clean section: states s (band, low), the previous input *x1. Writes
 * low, band and high. */
static void clean_section(float* s, float* x1, float x, float g, float k, float* lo, float* bp,
                          float* hp) {
  const float dd = 1.0f / (1.0f + g * (g + k));
  const float e = x + *x1 - 2.0f * s[1];
  const float b = s[0] * (1.0f - 2.0f * g * (g + k) * dd) + g * dd * e;
  const float l = s[1] + g * g * dd * e + 2.0f * g * dd * s[0];
  *hp = x - k * b - l;
  s[0] = b;
  s[1] = l;
  *x1 = x;
  *lo = l;
  *bp = b;
}

static float clean_pick(int32_t type, const float* w, float l, float b, float h) {
  switch (type) {
    case 0: return l;
    case 1: return h;
    case 2: return b;
    case 3: return l + h;
    default: return w[0] * l + w[1] * b + w[2] * h;
  }
}

/* MS2: Segno's MS-20 section (ms2_section.h, Drift's filter II), one for
 * 12 dB, two for 24, the second at (0.4 + 0.2 r) of the first's loop gain;
 * the signal enters at 0.6 of Drift's level (fit: the MS2 renders and OP
 * Bass, third-octave bands within 2.5 dB rms, at the noise renders' own
 * spread). */
#ifndef OP_MS2_K2
#define OP_MS2_K2 0.4f
#endif
#ifndef OP_MS2_K2R
#define OP_MS2_K2R 0.2f
#endif
#ifndef OP_MS2_IN
#define OP_MS2_IN 0.6f
#endif
#ifndef OP_MS2_OUT
#define OP_MS2_OUT 1.0f
#endif

/* PRD: Segno's model of a four-stage transistor ladder. Each stage is a
 * one-pole whose input and output pass the same saturating curve
 * z (1 - z^2/4 + |z|^3/16) (z clamped to +-2, reaching 1), with a small
 * offset of its own (the stages' mismatch, slightly asymmetric clipping);
 * the fourth stage's output feeds back to the input by k = 4.04 q, so it
 * self-oscillates near resonance 1. The curves are linearised at the last
 * estimate and the loop solved in closed form, twice per sample. 12 dB
 * takes the second stage, 24 the fourth. Fitted against the PRD renders and
 * Three Op Bass (third-octave bands within 2.5 dB rms, at the noise
 * renders' own spread): the input at 0.5 x drive, the feedback at 0.8 of
 * the reading's 4.04 q, and the pass band made up in full, by (1 + k). */
#ifndef OP_PRD_IN
#define OP_PRD_IN 0.5f /* fit: the signal's level inside the ladder */
#endif
#ifndef OP_PRD_KB
#define OP_PRD_KB 0.1f /* fit: below self-oscillation the feedback rises 10 % x (1 - q) */
#endif
#ifndef OP_PRD_K
#define OP_PRD_K 0.8f /* fit: the feedback, 0.8 x 4.04 q */
#endif
/* OSR: Segno's model of Ableton's state-variable circuit. A two-integrator
 * loop whose transconductances both saturate (the curve PRD's stages use,
 * on the node voltages scaled by 0.145 per volt), damped by 2 (1 - q) -
 * 0.01 and by a diode across the band node that conducts above a knee: so
 * from about resonance 1 the loop rings at the level where the diode's
 * damping makes up the negative linear damping. The input passes an op-amp
 * stage that saturates softly near its 5 V rails. Linearised at the last
 * estimate and solved in closed form, twice per sample; one core gives the
 * low, band and high outputs, 24 dB two cores. */
#ifndef OP_OSR_IN
#define OP_OSR_IN 2.59076f /* the signal into the circuit, in volts */
#endif
#ifndef OP_OSR_G
#define OP_OSR_G 1.00934f /* the cutoff calibration */
#endif
#ifndef OP_OSR_K2
#define OP_OSR_K2 0.5f /* fit: the second 24 dB core's share of q */
#endif
#ifndef OP_OSR_VK
#define OP_OSR_VK 0.5f /* fit: the diode's knee, volts */
#endif
#ifndef OP_OSR_DK
#define OP_OSR_DK 0.85f /* fit: its conductance above the knee (round 9's self-oscillation levels) */
#endif
/* fit: the transconductances' scale, volts to the curve (round 9: the
 * self-oscillation at 100 Hz to 1 kHz within 6 cents of Live's) */
#define OP_OSR_KAPPA 0.145f

#ifndef OP_OSR_RAIL
#define OP_OSR_RAIL 20.0f /* fit: the input stage saturates far above the 5 V rails the reading names */
#endif
static float osr_input(float u) { return OP_OSR_RAIL * tanhf(u / OP_OSR_RAIL); }

static float osr_ota_secant(float v) {
  const float z = clampf(OP_OSR_KAPPA * v, -2.0f, 2.0f);
  const float az = fabsf(z);
  return 1.0f - 0.25f * z * z + 0.0625f * az * az * az;
}

static float osr_diode_secant(float v) {
  const float a = fabsf(v);
  return a <= OP_OSR_VK ? 0.0f : OP_OSR_DK * (a - OP_OSR_VK) / a;
}

/* One OSR core: st[0], st[1] the integrators, st[2..4] the last secants
 * (the two transconductances and the diode). Writes high, band and low to
 * o[0..2]. */
static void osr_tick(float* st, float u, float g, float k, float* o) {
  float s1 = st[2], s2 = st[3], sd = st[4];
  float vh = 0.0f, vb = 0.0f, vl = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    const float g1 = g * s1, g2 = g * s2, kk = k + sd;
    vh = (u - (kk + g2) * st[0] - st[1]) / (1.0f + kk * g1 + g1 * g2);
    vh = clampf(vh, -5.2f * OP_OSR_IN, 5.2f * OP_OSR_IN);
    vb = g1 * vh + st[0];
    vl = g2 * vb + st[1];
    s1 = osr_ota_secant(vh);
    s2 = osr_ota_secant(vb);
    sd = osr_diode_secant(vb);
  }
  st[2] = s1;
  st[3] = s2;
  st[4] = sd;
  st[0] = 2.0f * vb - st[0];
  st[1] = 2.0f * vl - st[1];
  o[0] = vh;
  o[1] = vb;
  o[2] = vl;
}

static const float kPrdOffset[5] = {-0.0135f, 0.0211f, -0.0031f, 0.0299f, 0.0217f};

static float prd_curve(float z) {
  z = clampf(z, -2.0f, 2.0f);
  const float az = fabsf(z);
  return z * (1.0f - 0.25f * z * z + 0.0625f * az * az * az);
}

/* The curve's secant at a (value over argument). */
static float prd_secant(float a) {
  return fabsf(a) < 1e-6f ? 1.0f : prd_curve(a) / a;
}

/* q for resonance r, and the high-cutoff pull-back MS2 has. */
static float prd_q(float r, float fc, float rate) {
  float q = fminf(r + 4.0f * fmaxf(r - 1.0f, 0.0f) * fmaxf(r - 1.0f, 0.0f),
                  4.0f * r / (7.0f - 3.0f * fminf(r, 2.0f)));
  const float lim = fminf(10000.0f / rate + 0.25f, 0.5f);
  const float t = 1.0f - fminf(fc / rate, lim) / lim;
  return fminf(q, 1.0f + (fmaxf(q, 1.0f) - 1.0f) * t * t * t);
}

/* One sample of the ladder: st[0..3] the stages' states, st[4..8] the last
 * secants (input, stages 1..4). Writes the input node and the four stage
 * outputs to y[0..4]. */
static void prd_tick(float* st, float u, float g, float k, float* y) {
  float sg[5];
  for (int i = 0; i < 5; ++i) sg[i] = st[4 + i];
  for (int pass = 0; pass < 2; ++pass) {
    /* stage i: y_i (1 + g sg_i) = s_i + g sg_{i-1} (y_{i-1} + o_{i-1}) - g sg_i o_i,
     * with y_0 = u - k y_4 as the input node: y_4 = A y_0 + B */
    float A = 1.0f, B = 0.0f;
    float a[4], b[4];
    for (int i = 0; i < 4; ++i) {
      const float den = 1.0f / (1.0f + g * sg[i + 1]);
      a[i] = g * sg[i] * den;
      b[i] = (st[i] + g * sg[i] * kPrdOffset[i] - g * sg[i + 1] * kPrdOffset[i + 1]) * den;
      A = a[i] * A;
      B = a[i] * B + b[i];
    }
    y[0] = (u - k * B) / (1.0f + k * A);
    for (int i = 0; i < 4; ++i) y[i + 1] = a[i] * y[i] + b[i];
    for (int i = 0; i < 5; ++i) sg[i] = prd_secant(y[i] + kPrdOffset[i]);
  }
  for (int i = 0; i < 5; ++i) st[4 + i] = sg[i];
  /* trapezoidal states: s = 2 y - s */
  for (int i = 0; i < 4; ++i) st[i] = 2.0f * y[i + 1] - st[i];
}

/* ---- the shaper ---- */

static float shape_curve(int32_t type, float x) {
  const float a = fabsf(x);
  const float sg = x < 0.0f ? -1.0f : 1.0f;
  switch (type) {
    case 1: { /* Soft: linear to -3 dB, then an exponential knee to 1 */
      const float k = 0.708f;
      if (a < k) return x;
      return sg * (1.0f - (1.0f - k) * expf(-(a - k) / (1.0f - k)));
    }
    case 2: return 0.6798f * atanf(10.0f * x); /* Hard */
    case 3: return a <= 9.0f ? sinf(0.5f * (float)OP_PI * x) : sg; /* Sine fold */
    default: { /* 4-Bit: a triangle fold quantized to eighths */
      const float c = fminf(a, 21.0f);
      float p = fmodf(c + 1.0f, 4.0f);
      const float t = p < 2.0f ? p - 1.0f : 3.0f - p;
      return sg * roundf(8.0f * t) / 8.0f;
    }
  }
}

/* The half-band pair the shaper's and the operators' 2x run through: two
 * paths of two first-order allpass sections each (my own design: a
 * 4-coefficient elliptic half-band, 0.05 transition). */
static const float kHalfband[4] = {0.1207321175f, 0.3903621872f, 0.6632020224f,
                                   0.8907868327f};

/* One allpass section a: state s = (x1, y1). */
static float allpass(float a, float* s, float x) {
  const float y = a * (x - s[1]) + s[0];
  s[0] = x;
  s[1] = y;
  return y;
}

/* Two outputs at twice the rate from one input: path A, then path B. */
static void upsample2(float st[4][2], float x, float* y0, float* y1) {
  *y0 = allpass(kHalfband[2], st[1], allpass(kHalfband[0], st[0], x));
  *y1 = allpass(kHalfband[3], st[3], allpass(kHalfband[1], st[2], x));
}

/* One output from two inputs at twice the rate. */
static float downsample2(float st[4][2], float x0, float x1) {
  const float a = allpass(kHalfband[2], st[1], allpass(kHalfband[0], st[0], x1));
  const float b = allpass(kHalfband[3], st[3], allpass(kHalfband[1], st[2], x0));
  return 0.5f * (a + b);
}

/* ---- rendering ---- */

/* Operator op's amplitude: Volume, velocity and key scaling. */
static float op_amp(const le_operator* d, const le_operator_voice* v, int32_t op) {
  float lvl = opf(d, op, LE_OPERATOR_OP_VOLUME);
  const float vs = opf(d, op, LE_OPERATOR_OP_VEL_SCALE) / 100.0f;
  if (vs != 0.0f) {
    const float g = (v->velocity - 0.5f) * vs + 0.5f;
    lvl *= 4.0f * g * g;
  }
  const float ks = opf(d, op, LE_OPERATOR_OP_KEY_SCALE) / 100.0f;
  if (ks != 0.0f) lvl *= exp2f(ks * ((float)VKEY(v) - 60.0f) / 12.0f);
  return lvl;
}

/* Everything a voice needs for one chunk. */
typedef struct chunk_ctx {
  int32_t alg, aa, interp, os;
  float erate; /* the operators' rate: the sample rate, doubled for Antialias */
  int32_t on[LE_OPERATOR_OPS], fb_op[LE_OPERATOR_OPS], lfo_on[LE_OPERATOR_OPS],
      penv_on[LE_OPERATOR_OPS];
  float fb[LE_OPERATOR_OPS];
  env_def env[LE_OPERATOR_OPS], fenv, penv, lenv;
  int32_t lfo_type, lfo_active, penv_active;
  float penv_amount; /* the pitch envelope's semitones to octaves, x its amount */
  int32_t filter_on, filter_type, slope, shaper, circuit;
  float shaper_dry, shaper_drive;
} chunk_ctx;


/* Sets the voice's per-chunk operator increments, levels, filter, gains;
 * returns the filter target and LFO coefficients through the pointers. */
static void voice_chunk(le_operator* d, le_operator_voice* v, const chunk_ctx* c,
                        filter_target* ft, lfo_coef* lc, float* lfo_a, float* penv_a,
                        int32_t frames) {
  const float rate = (float)d->sample_rate;
  /* glide */
  if (v->glide_chunks > 0) {
    v->pitch += v->pitch_step;
    if (--v->glide_chunks == 0) v->pitch = (float)v->note;
  }
  const float penv_st = c->penv_active ? v->penv.y : 0.0f;
  op_mods rm;
  /* the LFO Amount route scales both of the LFO's destinations: a first
   * pass finds it, the second routes the scaled LFO */
  route_mods(d, v, 0.0f, penv_st, 0, &rm);
  const float lfo_gain = route_gain(&rm, DST_LFO_AMOUNT);
  route_mods(d, v, v->lfo_out * lfo_gain, penv_st, 1, &rm);
  const float* mod = rm.m;
  /* Aux Env (the pitch envelope's amount) is a gain destination: the mod
   * wheel at rest with +100 % silences it (measured: round 9 mw-auxenv) */
  *penv_a = c->penv_amount * route_gain(&rm, DST_PITCH_ENV);
  /* LFO */
  float fl = lfo_hz(d, VKEY(v), 1) * exp2f(rm.lfo_rate);
  if (vi(d, LE_OPERATOR_LFO_PITCH_ENV_ON) && c->penv_active) {
    fl *= penv_ratio(v->penv.y, &v->penv, *penv_a);
  }
  *lc = lfo_coefs(fl, rate);
  const float amount = vf(d, LE_OPERATOR_LFO_AMOUNT);
  *lfo_a = 2.0f * amount * amount * (vf(d, LE_OPERATOR_LFO_AMOUNT_A) / 100.0f) *
           lfo_gain;
  /* Tone: the operators' modulation low-pass */
  {
    const float tone = vf(d, LE_OPERATOR_TONE) * route_gain(&rm, DST_TONE);
    float fc = 30.0f * powf(22000.0f / 30.0f, tone);
    if (fc > 0.49f * c->erate) fc = 0.49f * c->erate;
    const float t = tanf((float)OP_PI * fc / c->erate);
    v->tone_b = t / (1.0f + t);
    v->tone_a = (t - 1.0f) / (1.0f + t);
  }
  v->time_mod = exp2f(rm.time);
  /* pitch */
  const float p = v->pitch + v->detune + vf(d, LE_OPERATOR_TRANSPOSE) +
                  d->bend * vf(d, LE_OPERATOR_PITCH_BEND_RANGE);
  const float hz = 440.0f * exp2f((fmaxf(p, -127.0f) - 69.0f) / 12.0f);
  const float vel127 = v->velocity * 127.0f;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    if (!c->on[op]) {
      v->amp[op] = v->amp_step[op] = 0.0f;
      continue;
    }
    const le_operator_wave* w = op_wave(d, op);
    float f;
    const float vc = opf(d, op, LE_OPERATOR_OP_VEL_COARSE) / 100.0f;
    const int quant = opi(d, op, LE_OPERATOR_OP_VEL_COARSE_QUANTIZED);
    if (opi(d, op, LE_OPERATOR_OP_FIXED_ON)) {
      static const float multi[6] = {0.0f, 0.001f, 0.01f, 0.1f, 1.0f, 10.0f};
      const float f0 = opf(d, op, LE_OPERATOR_OP_FIXED_FREQ) * multi[opi(d, op, LE_OPERATOR_OP_FIXED_MULTI)];
      f = f0;
      if (vc != 0.0f) {
        const float vv = vc > 0.0f ? v->velocity : 1.0f - v->velocity;
        f = f0 * exp2f(4.0f * fabsf(vc) * vv);
        if (quant && f0 > 0.0f) f = floorf(f / f0) * f0;
      }
      f *= exp2f(mod[DST_FIXED] * 63.0f / 12.0f) * exp2f(v->detune / 12.0f);
    } else {
      const int32_t coarse = opi(d, op, LE_OPERATOR_OP_COARSE);
      float r0 = coarse == 0 ? 0.5f : (float)coarse;
      if (vc != 0.0f) {
        float add = 16.0f * vc * v->velocity;
        /* quantized: whole steps, rounded (Live's renders: Coarse 0 with
         * 12 % gives 1.5 at velocity 90 and 2.5 at 100) */
        if (quant) add = roundf(add);
        r0 = fmaxf(0.5f, r0 + add);
      }
      f = hz * r0 * (1.0f + opf(d, op, LE_OPERATOR_OP_FINE) / 1000.0f);
    }
    float inc = w->white ? 1.0f : f * w->freq_mult * (float)N_TABLE / c->erate;
    v->inc[op] = inc;
    v->table[op] = w->white ? 0 : pick_table(w, inc, c->aa);
    /* level */
    float lvl = op_amp(d, v, op);
    lvl *= w->gain * route_gain(&rm, DST_VOL_A + op);
    /* oversampled white noise gets back the power the decimator drops */
    if (w->white && c->aa) lvl *= 1.41421356f;
    /* the crossfades take amount x (2u - 1): the mod wheel at rest with
     * +58 % gives C 0.42 and A 1.58 (measured: Analog Bouquet Brass) */
    if (op == 0 || op == 1) lvl *= clampf(1.0f - rm.bi[op == 0 ? DST_XFADE_AC : DST_XFADE_BD], 0.0f, 2.0f);
    else lvl *= clampf(1.0f + rm.bi[op == 2 ? DST_XFADE_AC : DST_XFADE_BD], 0.0f, 2.0f);
    if (!(kCarriers[c->alg] & (1u << op))) lvl *= route_gain(&rm, DST_FM_DRIVE);
    if (v->gl < 0.0f) {
      v->amp[op] = lvl;
      v->amp_step[op] = 0.0f;
    } else {
      v->amp_step[op] = (lvl - v->amp[op]) / (float)frames;
    }
  }
  /* filter */
  if (c->filter_on) {
    const float s = ((float)VKEY(v) - 70.0f) * vf(d, LE_OPERATOR_FILTER_KEY) / 100.0f +
                    (vel127 - 70.0f) * vf(d, LE_OPERATOR_FILTER_VEL) / 100.0f +
                    v->lfo_filter +
                    1.08f * vf(d, LE_OPERATOR_FILTER_ENV_AMOUNT) *
                        route_gain(&rm, DST_FILTER_ENV) * v->fenv.y +
                    OP_FILTER_K * mod[DST_FILTER_FREQ];
    float fc = vf(d, LE_OPERATOR_FILTER_FREQ) * exp2f(clampf(s / 12.0f, -31.0f, 31.0f));
    fc = clampf(fc, 30.0f, fminf(0.48f * rate, 18500.0f));
    /* Res and Drive are gain destinations: the mod wheel at rest with +50 %
     * halves the resonance, -50 % leaves it, +100 % opens none and takes
     * all the drive (measured: round 9 mw-res-p50, -m50, mw-fdrive; Harsh
     * FM Bass) */
    const float res = vf(d, LE_OPERATOR_FILTER_RES) * route_gain(&rm, DST_FILTER_RES);
    /* Clean holds resonance at 0.9; the analog circuits take up to 2 */
    const float r = clampf(res, 0.0f, 0.9f);
    ft->q = 4.0f * r / (3.0f * r + 1.0f);
    ft->g = tanf((float)OP_PI * fc / rate);
    ft->fc = fc;
    ft->r = clampf(res, 0.0f, 2.0f);
    ft->drive = powf(10.0f, clampf(vf(d, LE_OPERATOR_FILTER_DRIVE) * route_gain(&rm, DST_FILTER_DRIVE),
                                   0.0f, 24.0f) / 20.0f);
    morph_weights(vf(d, LE_OPERATOR_FILTER_MORPH) + mod[DST_FILTER_MORPH], ft->w);
  }
  /* gains */
  const float q = clampf(vf(d, LE_OPERATOR_PAN) + v->pan + mod[DST_PAN], -1.0f, 1.0f);
  const float th = (q + 1.0f) * 0.25f * (float)OP_PI;
  /* the Volume route scales the voice's output, after the filter and the
   * shaper (measured: Creep Bass, velocity on Volume, drives its shaper as
   * hard at velocity 64 as at 127, and leaves its modulators whole) */
  const float vol = vf(d, LE_OPERATOR_VOLUME) * route_gain(&rm, DST_VOLUME);
  float gl = fmaxf(1.41421356f * cosf(th), 1e-5f) * vol;
  float gr = fmaxf(1.41421356f * sinf(th), 1e-5f) * vol;
  if (v->side == SIDE_LEFT) gr = 0.0f;
  if (v->side == SIDE_RIGHT) gl = 0.0f;
  if (v->gl < 0.0f) {
    v->gl = gl;
    v->gr = gr;
    v->gl_step = v->gr_step = 0.0f;
  } else {
    v->gl_step = (gl - v->gl) / (float)frames;
    v->gr_step = (gr - v->gr) / (float)frames;
  }
}

/* One engine sample of the operators. */
static float operators_tick(le_operator* d, le_operator_voice* v, const chunk_ctx* c,
                            const float* env, float lfo_mul, float penv_mul) {
  const uint8_t* mod_by = kModBy[c->alg];
  float sum = 0.0f;
  const float kpm = -2.0f * (float)N_TABLE;
  for (int32_t op = LE_OPERATOR_OPS - 1; op >= 0; --op) {
    if (!c->on[op]) {
      v->y2[op] = v->out[op];
      v->out[op] = 0.0f;
      continue;
    }
    float off;
    if (c->fb_op[op]) {
      off = kpm * c->fb[op] * (0.75f * v->out[op] + 0.25f * v->y2[op]);
    } else {
      float x = 0.0f;
      for (int32_t m = 0; m < LE_OPERATOR_OPS; ++m) {
        if (mod_by[op] & (1u << m)) x += v->out[m];
      }
      const float lp = v->tone_b * (x + v->lp_x[op]) - v->tone_a * v->lp_y[op];
      v->lp_x[op] = x;
      v->lp_y[op] = lp;
      off = kpm * lp;
    }
    const le_operator_wave* w = op_wave(d, op);
    float s;
    if (w->white) {
      s = lcg_bipolar(&v->rng);
    } else {
      double pos = v->phase[op] + (double)off;
      pos -= floor(pos / N_TABLE) * N_TABLE;
      s = wave_read(w, v->table[op], pos, c->interp);
    }
    const float y = v->amp[op] * env[op] * s;
    v->y2[op] = v->out[op];
    v->out[op] = y;
    if (kCarriers[c->alg] & (1u << op)) sum += y;
    float inc = v->inc[op];
    if (c->lfo_on[op]) inc *= lfo_mul;
    if (c->penv_on[op]) inc *= penv_mul;
    double ph = v->phase[op] + (double)inc;
    if (ph >= N_TABLE || ph < 0.0) ph -= floor(ph / N_TABLE) * N_TABLE;
    v->phase[op] = ph;
  }
  return sum;
}

/* Whether every sounding carrier's envelope has ended: run out, or fallen
 * in its release below 10^-3 of full level (before the operator's own
 * amplitude). Live ends a voice there, about 40 samples later: a 50 ms
 * release at 1760 samples from full level, 1648 from 0.25, 2296 from full
 * level at volume 0.1 (measured: sine, env-loop-1, round 9's rel-in-*
 * and osr-self renders, all at 10^-3 within 2 %). */
#ifndef ENV_END
#define ENV_END 1e-3f
#endif
static int voice_done(const le_operator_voice* v, const chunk_ctx* c) {
  int any = 0;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    if (!c->on[op] || !(kCarriers[c->alg] & (1u << op))) continue;
    any = 1;
    const le_operator_env* e = &v->env[op];
    if (e->state != ENV_OFF && !(e->state == ENV_RELEASE && fabsf(e->y) < ENV_END && e->y1 < ENV_END))
      return 0;
  }
  return any || v->state == LE_OPERATOR_VOICE_RELEASED;
}

/* Whether every sounding carrier's envelope ignores note-off (Trigger), so a
 * voice whose carriers have ended is over even with its key held. */
static int carriers_triggered(const chunk_ctx* c) {
  int any = 0;
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    if (!c->on[op] || !(kCarriers[c->alg] & (1u << op))) continue;
    if (c->env[op].loop != LOOP_TRIGGER) return 0;
    any = 1;
  }
  return any;
}

static void render_voice(le_operator* d, le_operator_voice* v, const chunk_ctx* c, float* left,
                         float* right, int32_t frames) {
  filter_target ft = {0};
  lfo_coef lc;
  float lfo_a, penv_a;
  v->snap = 0;
  voice_chunk(d, v, c, &ft, &lc, &lfo_a, &penv_a, frames);
  if (c->filter_on) {
    if (v->f_g <= 0.0f) {
      v->f_g = ft.g;
      v->f_k = ft.q;
      memcpy(v->f_w, ft.w, sizeof(ft.w));
      v->f_g_step = v->f_k_step = 0.0f;
      v->f_w_step[0] = v->f_w_step[1] = v->f_w_step[2] = 0.0f;
    } else {
      v->f_g_step = (ft.g - v->f_g) / (float)frames;
      v->f_k_step = (ft.q - v->f_k) / (float)frames;
      for (int32_t i = 0; i < 3; ++i) v->f_w_step[i] = (ft.w[i] - v->f_w[i]) / (float)frames;
    }
  }
  /* the analog circuits' coefficients, per chunk */
  const float rate = (float)d->sample_rate;
  int32_t circuit = c->filter_on ? c->circuit : CIRC_CLEAN;
  le_ms2_coef ms2 = {0};
  float k1 = 0.0f, k2 = 0.0f;
  /* PRD's high-pass is a core of its own, not built: Clean's */
  if (circuit == CIRC_PRD && c->filter_type == 1) circuit = CIRC_CLEAN;
  float in_scale = OP_MS2_IN;
  float hp_c = 0.0f;
  if ((circuit == CIRC_MS2 || circuit == CIRC_SMP) && c->filter_type == 1) {
    const float fcs = fminf(fmaxf(ft.fc, 1.0f), 0.48f * rate);
    ms2.g = tanf(fminf((float)OP_PI * fcs / rate, 1.54f));
    {
      /* the damping falls from 1.63 at resonance 0 to 0.37 at 1 and stays
       * there (fit: the HP renders at resonance 0, 0.5 and 1) */
      const float q = fminf(le_ms2_q(ft.r, ft.fc, rate), 1.0f);
      k1 = 0.37f + 1.26f * powf(1.0f - q, 1.32f);
      const float q2 = q * (OP_MS2_K2 + OP_MS2_K2R * ft.r);
      k2 = 0.37f + 1.26f * powf(1.0f - q2, 1.32f);
    }
    hp_c = circuit == CIRC_SMP ? OP_SMP_HP_C : OP_MS2_HP_C;
    circuit = CIRC_MS2_HP;
  }
  if (circuit == CIRC_SMP) {
    /* SMP: MS2's section with SMP's feedback (0.904, MS2 0.914) and input
     * (2.47 V, MS2 2.69); no factory preset uses it */
    circuit = CIRC_MS2;
    in_scale = OP_MS2_IN * 2.47474f / LE_MS2_GI;
  }
  if (circuit == CIRC_MS2) {
    const float fcs = fminf(fmaxf(ft.fc, 1.0f), 0.48f * rate);
    ms2 = le_ms2_coefs(tanf(fminf((float)OP_PI * fcs / rate, 1.54f)), rate);
    k1 = (c->circuit == CIRC_SMP ? OP_SMP_FB : LE_MS2_FEEDBACK) * le_ms2_q(ft.r, ft.fc, rate);
    k2 = k1 * (OP_MS2_K2 + OP_MS2_K2R * ft.r);
  } else if (circuit == CIRC_PRD) {
    const float fcs = fminf(fmaxf(ft.fc, 1.0f), 0.48f * rate);
    ms2.g = tanf(fminf((float)OP_PI * fcs / rate, 1.54f));
    {
      const float q = prd_q(ft.r, ft.fc, rate);
      k1 = OP_PRD_K * 4.04f * q * (1.0f + OP_PRD_KB * (1.0f - fminf(q, 1.0f)));
    }
    k2 = (1.0f + k1) / OP_PRD_IN;
  }
  /* the analog state belongs to one circuit and slope: a change starts it
   * afresh (no other circuit's voltages read as its own) */
  {
    const int32_t kind = 1 + 2 * circuit + c->slope;
    if (v->f_kind != kind) {
      memset(v->f_an, 0, sizeof(v->f_an));
      v->f_kind = kind;
    }
  }
  if (circuit == CIRC_OSR) {
    const float fcs = fminf(fmaxf(ft.fc, 1.0f), 0.48f * rate);
    ms2.g = OP_OSR_G * tanf(fminf((float)OP_PI * fcs / rate, 1.54f));
    k1 = 2.0f * (1.0f - le_ms2_q(ft.r, ft.fc, rate)) - 0.01f;
    k2 = 2.0f * (1.0f - OP_OSR_K2 * le_ms2_q(ft.r, ft.fc, rate)) - 0.01f;
  }
  const env_ctx ec = make_ctx(d, VKEY(v), rate, v->time_mod);
  const float vel127 = v->velocity * 127.0f;
  float fv[LE_OPERATOR_OPS];
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) fv[op] = env_vel_factor(&c->env[op], vel127);
  const float fvf = env_vel_factor(&c->fenv, vel127);
  const float fvp = env_vel_factor(&c->penv, vel127);
  const float fvl = env_vel_factor(&c->lenv, vel127);
  const float vamt = vf(d, LE_OPERATOR_LFO_AMOUNT_VEL);
  const float vfac = 0.5f + vamt * (v->velocity - 0.5f);
  const float lfo_scale = 4.0f * vfac * vfac;
  const float fade_step = 1.0f / (0.001f * (float)d->sample_rate);
  const float shp_pre = powf(10.0f, c->shaper_drive / 20.0f);
  const float shp_wet = (1.0f - c->shaper_dry) * powf(10.0f, -c->shaper_drive / 40.0f);
  for (int32_t i = 0; i < frames; ++i) {
    float env[LE_OPERATOR_OPS];
    for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
      env[op] = c->on[op] ? env_tick(&v->env[op], &c->env[op], fv[op], &ec) : 0.0f;
    }
    const float fenv = c->filter_on ? env_tick(&v->fenv, &c->fenv, fvf, &ec) : 0.0f;
    (void)fenv;
    const float pmul = c->penv_active ? penv_ratio(env_tick(&v->penv, &c->penv, fvp, &ec),
                                                   &v->penv, penv_a)
                                      : 1.0f;
    float la = 0.0f;
    if (c->lfo_active) {
      const float le = env_tick(&v->lenv, &c->lenv, fvl, &ec) * lfo_scale;
      v->lfo_out = lfo_sample(v, c->lfo_type, &lc) * le;
      la = v->lfo_out * lfo_a;
      if (c->filter_on && vi(d, LE_OPERATOR_FILTER_LFO_ON)) {
        v->lfo_filter += lc.fl_c * (24.0f * la - v->lfo_filter);
      }
    }
    const float lmul = 1.0f + la;
    float x;
    if (c->os == 2) {
      const float a = operators_tick(d, v, c, env, lmul, pmul);
      const float b = operators_tick(d, v, c, env, lmul, pmul);
      x = downsample2(v->aa, a, b);
    } else {
      x = operators_tick(d, v, c, env, lmul, pmul);
    }
    for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) v->amp[op] += v->amp_step[op];
    if (c->filter_on) {
      float y;
      if (circuit == CIRC_OSR) {
        const float u = osr_input(OP_OSR_IN * ft.drive * x);
        float o[3];
        osr_tick(v->f_an, u, ms2.g, k1, o);
        y = clean_pick(c->filter_type, v->f_w, o[2], o[1], o[0]);
        if (c->slope) {
          osr_tick(v->f_an + 8, y, ms2.g, k2, o);
          y = clean_pick(c->filter_type, v->f_w, o[2], o[1], o[0]);
        }
        y *= 1.0f / OP_OSR_IN;
      } else if (circuit == CIRC_PRD) {
        float yy[5];
        prd_tick(v->f_an, OP_PRD_IN * ft.drive * x, ms2.g, k1, yy);
        y = k2 * (c->slope ? yy[4] : yy[2]);
      } else if (circuit == CIRC_MS2_HP) {
        float l, b, h;
        clean_section(v->f_an, v->f_an + 2, ft.drive * x, ms2.g, k1, &l, &b, &h);
        y = h + hp_c * b;
        if (c->slope) {
          clean_section(v->f_an + 4, v->f_an + 6, y, ms2.g, k2, &l, &b, &h);
          y = h + hp_c * b;
        }
        y = 8.0f * tanhf(0.125f * y); /* the output stage's rails */
      } else if (circuit == CIRC_MS2) {
        y = OP_MS2_OUT / in_scale * le_ms2_section(v->f_an, in_scale * ft.drive * x, &ms2, k1);
        if (c->slope) {
          y = le_ms2_section(v->f_an + LE_MS2_STATES, in_scale * y, &ms2, k2) / in_scale;
        }
      } else {
        const float g = v->f_g;
        float l, b, h;
        clean_section(v->f_s[0], &v->f_x1[0], x, g, 2.0f * (1.0f - v->f_k), &l, &b, &h);
        y = clean_pick(c->filter_type, v->f_w, l, b, h);
        if (c->slope) {
          clean_section(v->f_s[1], &v->f_x1[1], y, g, 2.0f - v->f_k, &l, &b, &h);
          y = clean_pick(c->filter_type, v->f_w, l, b, h);
        }
      }
      x = y;
      v->f_g += v->f_g_step;
      v->f_k += v->f_k_step;
      for (int32_t j = 0; j < 3; ++j) v->f_w[j] += v->f_w_step[j];
      if (c->shaper) {
        float u0, u1;
        upsample2(v->sh_up, x, &u0, &u1);
        u0 = c->shaper_dry * u0 + shp_wet * shape_curve(c->shaper, shp_pre * u0);
        u1 = c->shaper_dry * u1 + shp_wet * shape_curve(c->shaper, shp_pre * u1);
        x = downsample2(v->sh_dn, u0, u1);
      }
    }
    if (v->state == LE_OPERATOR_VOICE_FADING) {
      x *= v->fade;
      v->fade -= fade_step;
      if (v->fade <= 0.0f) {
        v->state = LE_OPERATOR_VOICE_FREE;
        return;
      }
    }
    left[i] += v->gl * x;
    right[i] += v->gr * x;
    v->gl += v->gl_step;
    v->gr += v->gr_step;
  }
  if (v->state != LE_OPERATOR_VOICE_FADING && voice_done(v, c) &&
      ((v->state != LE_OPERATOR_VOICE_HELD && v->state != LE_OPERATOR_VOICE_SUSTAINED) ||
       carriers_triggered(c))) {
    /* Live ends it a block after: one more chunk */
    if (v->ending) v->state = LE_OPERATOR_VOICE_FREE;
    v->ending = 1;
  } else {
    v->ending = 0;
  }
}

static void make_chunk_ctx(const le_operator* d, chunk_ctx* c) {
  c->alg = vi(d, LE_OPERATOR_ALGORITHM);
  c->aa = vi(d, LE_OPERATOR_ANTIALIAS);
  c->os = c->aa ? 2 : 1;
  c->interp = vi(d, LE_OPERATOR_INTERPOLATION);
  c->erate = (float)d->sample_rate * (float)c->os;
  c->lfo_active = vi(d, LE_OPERATOR_LFO_ON);
  c->penv_active = vi(d, LE_OPERATOR_PITCH_ENV_ON);
  for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
    c->on[op] = opi(d, op, LE_OPERATOR_OP_ON);
    c->fb_op[op] = kModBy[c->alg][op] == 0;
    c->fb[op] = opf(d, op, LE_OPERATOR_OP_FEEDBACK) / 100.0f * 0.3333f;
    c->lfo_on[op] = c->lfo_active && opi(d, op, LE_OPERATOR_OP_LFO_ON);
    c->penv_on[op] = c->penv_active && opi(d, op, LE_OPERATOR_OP_PITCH_ENV_ON);
    c->env[op] = read_env(d, LE_OPERATOR_OP(op, LE_OPERATOR_OP_ENV));
  }
  c->fenv = read_env(d, LE_OPERATOR_FILTER_ENV);
  c->fenv.curved = 1;
  c->penv = pitch_env(d);
  c->penv.curved = 1;
  c->penv_amount = penv_amount(d) / 12.0f;
  c->lenv = read_env(d, LE_OPERATOR_LFO_ENV);
  c->lfo_type = vi(d, LE_OPERATOR_LFO_TYPE);
  c->filter_on = vi(d, LE_OPERATOR_FILTER_ON);
  c->filter_type = vi(d, LE_OPERATOR_FILTER_TYPE);
  c->slope = vi(d, LE_OPERATOR_FILTER_SLOPE);
  /* LP and HP take one of five circuits, BP, Notch and Morph Clean or OSR */
  c->circuit = c->filter_type <= 1 ? vi(d, LE_OPERATOR_FILTER_CIRCUIT_LPHP)
                                   : vi(d, LE_OPERATOR_FILTER_CIRCUIT_BPNOMO);
  c->shaper = vi(d, LE_OPERATOR_SHAPER_TYPE);
  c->shaper_dry = 1.0f - vf(d, LE_OPERATOR_SHAPER_DRY_WET) / 100.0f;
  c->shaper_drive = vf(d, LE_OPERATOR_SHAPER_DRIVE);
}

void le_operator_render(le_operator* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  memset(right, 0, sizeof(float) * (size_t)frames);
  /* one changed user wave a call */
  if (d->user_dirty) {
    for (int32_t op = 0; op < LE_OPERATOR_OPS; ++op) {
      if (d->user_dirty & (1u << op)) {
        build_user(d, op);
        d->user_dirty &= ~(1u << op);
        break;
      }
    }
  }
  int32_t done = 0;
  while (done < frames) {
    if (d->chunk_left <= 0) d->chunk_left = LE_OPERATOR_CHUNK;
    int32_t n = frames - done;
    if (n > d->chunk_left) n = d->chunk_left;
    chunk_ctx c;
    make_chunk_ctx(d, &c);
    for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
      le_operator_voice* v = &d->voices[i];
      if (v->state == LE_OPERATOR_VOICE_FREE) continue;
      render_voice(d, v, &c, left + done, right + done, n);
    }
    d->lfo_free += (double)lfo_hz(d, 60, 0) * (double)n / (double)d->sample_rate;
    d->clock += (double)n;
    if (d->lfo_free >= 1.0) d->lfo_free -= floor(d->lfo_free);
    d->chunk_left -= n;
    done += n;
  }
}
