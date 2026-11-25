/*
 * analog_voice.c — the Analog device (analog_voice.h).
 *
 * Written from the behavior description in docs/brainstorm/2026-11-24-
 * ableton-devices-brainstorm-doc.md ("Analog: behavior"). Values marked
 * "fit" were set against Live renders; the rest follow the description.
 */
#include "analog_voice.h"

#include <math.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define AV_PI 3.14159265358979323846f
/* fit: C4 0.98 cent below equal temperament's 261.6256 Hz (every
 * oscillator render, at every note) */
#define AV_C4 261.4776f
#define AV_PI_D 3.14159265358979323846

enum {
  LE_ANALOG_VOICE_FREE = 0,
  LE_ANALOG_VOICE_HELD,
  LE_ANALOG_VOICE_RELEASED,
  LE_ANALOG_VOICE_SUSTAINED,
  LE_ANALOG_VOICE_FADING
};

/* Envelope segments: attack, decay, the sustain stage, the stage after the
 * sustain time, release, done. */
enum { SEG_ATTACK = 0, SEG_DECAY, SEG_SUSTAIN, SEG_POST, SEG_RELEASE, SEG_IDLE, SEG_DROP };

/* ---- parameters ---- */

typedef struct av_param_def {
  float def, lo, hi;
  int step;
} av_param_def;

static av_param_def env_field(int32_t f) {
  switch (f) {
    case LE_ANALOG_ENV_EXP: return (av_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_ENV_LOOP: return (av_param_def){0.0f, 0.0f, 3.0f, 1};
    case LE_ANALOG_ENV_FREE_RUN:
    case LE_ANALOG_ENV_LEGATO:
      return (av_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_ENV_SUSTAIN: return (av_param_def){0.7f, 0.0f, 1.0f, 0};
    case LE_ANALOG_ENV_SUSTAIN_TIME: return (av_param_def){1.0f, 0.0f, 1.0f, 0};
    case LE_ANALOG_ENV_ATTACK_VEL:
    case LE_ANALOG_ENV_VEL:
      return (av_param_def){0.0f, 0.0f, 1.0f, 0};
    default: return (av_param_def){0.3f, 0.0f, 1.0f, 0}; /* the times */
  }
}

static av_param_def chain_field(int32_t c, int32_t f) {
  if (f >= LE_ANALOG_FILTER_ENV && f < LE_ANALOG_AMP_ENV) return env_field(f - LE_ANALOG_FILTER_ENV);
  if (f >= LE_ANALOG_AMP_ENV && f < LE_ANALOG_CHAIN_LINK) return env_field(f - LE_ANALOG_AMP_ENV);
  switch (f) {
    case LE_ANALOG_OSC_ON:
    case LE_ANALOG_FILTER_ON:
    case LE_ANALOG_AMP_ON:
      return (av_param_def){c == 0 ? 1.0f : 0.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_OSC_SHAPE: return (av_param_def){1.0f, 0.0f, 3.0f, 1};
    case LE_ANALOG_OSC_OCT: return (av_param_def){0.0f, -3.0f, 3.0f, 1};
    case LE_ANALOG_OSC_SEMI: return (av_param_def){0.0f, -12.0f, 12.0f, 1};
    case LE_ANALOG_OSC_MODE:
    case LE_ANALOG_LFO_ON:
    case LE_ANALOG_LFO_SYNC_ON:
      return (av_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_LFO_GATE_RESET: return (av_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_FILTER_TYPE: return (av_param_def){0.0f, 0.0f, 9.0f, 1};
    case LE_ANALOG_FILTER_DRIVE: return (av_param_def){0.0f, 0.0f, 6.0f, 1};
    case LE_ANALOG_LFO_WAVE: return (av_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_ANALOG_LFO_SYNC: return (av_param_def){0.0f, 0.0f, 23.0f, 1};
    case LE_ANALOG_OSC_ENV_AMOUNT:
    case LE_ANALOG_OSC_LFO_PITCH:
    case LE_ANALOG_OSC_LFO_PW:
    case LE_ANALOG_FILTER_KEY_CUTOFF:
    case LE_ANALOG_FILTER_KEY_Q:
    case LE_ANALOG_FILTER_LFO_CUTOFF:
    case LE_ANALOG_FILTER_ENV_CUTOFF:
    case LE_ANALOG_FILTER_LFO_Q:
    case LE_ANALOG_FILTER_ENV_Q:
    case LE_ANALOG_AMP_KEY_VOL:
    case LE_ANALOG_AMP_KEY_PAN:
    case LE_ANALOG_AMP_LFO_VOL:
    case LE_ANALOG_AMP_LFO_PAN:
    case LE_ANALOG_AMP_ENV_PAN:
      return (av_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_ANALOG_OSC_PW:
    case LE_ANALOG_LFO_PW:
      return (av_param_def){1.0f, 0.0f, 1.0f, 0};
    case LE_ANALOG_OSC_SUB:
    case LE_ANALOG_OSC_BALANCE:
    case LE_ANALOG_LFO_PHASE:
    case LE_ANALOG_LFO_DELAY:
    case LE_ANALOG_LFO_FADE:
    case LE_ANALOG_CHAIN_LINK:
      /* each oscillator into its own chain's filter: osc 1 at 1, osc 2 at 0 */
      return (av_param_def){c == 0 && f == LE_ANALOG_OSC_BALANCE ? 1.0f : 0.0f, 0.0f, 1.0f, 0};
    case LE_ANALOG_FILTER_CUTOFF: return (av_param_def){0.75f, 0.0f, 1.0f, 0};
    case LE_ANALOG_FILTER_Q: return (av_param_def){0.3f, 0.0f, 1.0f, 0};
    default: return (av_param_def){0.5f, 0.0f, 1.0f, 0}; /* the centred knobs */
  }
}

static av_param_def param_def(int32_t p) {
  if (p >= LE_ANALOG_CHAINS) {
    const int32_t i = p - LE_ANALOG_CHAINS;
    return chain_field(i / LE_ANALOG_CHAIN_FIELDS, i % LE_ANALOG_CHAIN_FIELDS);
  }
  switch (p) {
    case LE_ANALOG_POLYPHONY: return (av_param_def){5.0f, 0.0f, 9.0f, 1};
    case LE_ANALOG_BEND_RANGE: return (av_param_def){1.0f / 6.0f, 0.0f, 1.0f, 0};
    case LE_ANALOG_VOLUME: return (av_param_def){0.7048f, 0.0f, 1.0f, 0};
    case LE_ANALOG_NOTE_BEND_RANGE: return (av_param_def){48.0f, 0.0f, 48.0f, 1};
    case LE_ANALOG_PRESSURE_TARGET1:
    case LE_ANALOG_PRESSURE_TARGET2:
    case LE_ANALOG_SLIDE_TARGET1:
    case LE_ANALOG_SLIDE_TARGET2:
      return (av_param_def){0.0f, 0.0f, 45.0f, 1};
    case LE_ANALOG_PRESSURE_AMOUNT1:
    case LE_ANALOG_PRESSURE_AMOUNT2:
    case LE_ANALOG_SLIDE_AMOUNT1:
    case LE_ANALOG_SLIDE_AMOUNT2:
      return (av_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_ANALOG_OCTAVE: return (av_param_def){0.0f, -3.0f, 3.0f, 1};
    case LE_ANALOG_TRANSPOSE: return (av_param_def){0.0f, -12.0f, 12.0f, 1};
    case LE_ANALOG_UNISON_ON:
    case LE_ANALOG_UNISON:
    case LE_ANALOG_VIBRATO_ON:
    case LE_ANALOG_GLIDE_ON:
    case LE_ANALOG_GLIDE_MODE:
    case LE_ANALOG_GLIDE_LEGATO:
    case LE_ANALOG_NOISE_ON:
      return (av_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_ANALOG_PRIORITY: return (av_param_def){2.0f, 0.0f, 2.0f, 1};
    case LE_ANALOG_FINE_TUNE:
    case LE_ANALOG_STRETCH:
    case LE_ANALOG_NOISE_BALANCE:
      return (av_param_def){0.5f, 0.0f, 1.0f, 0};
    case LE_ANALOG_NOISE_COLOR: return (av_param_def){1.0f, 0.0f, 1.0f, 0};
    default: return (av_param_def){0.0f, 0.0f, 1.0f, 0};
  }
}

float le_analog_default(int32_t param) {
  if (param < 0 || param >= LE_ANALOG_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_analog_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_ANALOG_PARAMS) return 0.0f;
  const av_param_def p = param_def(param);
  if (value != value) return p.def;
  if (value < p.lo) value = p.lo;
  if (value > p.hi) value = p.hi;
  return p.step ? floorf(value + 0.5f) : value;
}

static float vf(const le_analog* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_analog* d, int32_t p) { return (int32_t)d->values[p]; }
static float cf(const le_analog* d, int32_t c, int32_t f) { return d->values[LE_ANALOG_CHAIN(c, f)]; }
static int32_t ci(const le_analog* d, int32_t c, int32_t f) {
  return (int32_t)d->values[LE_ANALOG_CHAIN(c, f)];
}

static float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

/* ---- the knob curves ---- */

/* A knob position 0..1 on the engine's 0..127 scale (0.5 is exactly 64),
 * as a fraction of full scale. */
static float knob(float v) {
  v = clampf(v, 0.0f, 1.0f);
  const float m = v <= 0.5f ? 128.0f * v : 126.0f * v + 1.0f;
  return m / 127.0f;
}

static float c_exp(float lo, float hi, float v) { return lo * powf(hi / lo, knob(v)); }
static float c_lin(float lo, float hi, float v) { return lo + (hi - lo) * knob(v); }
static float c_sq(float lo, float hi, float v) {
  const float u = knob(v);
  return lo + (hi - lo) * u * u;
}

/* A bipolar amount: its magnitude through the curve, then its sign. */
static float b_sq(float hi, float v) { return (v < 0.0f ? -1.0f : 1.0f) * c_sq(0.0f, hi, fabsf(v)); }
/* A bipolar amount through the fourth power of its magnitude (the filter
 * envelope's depth: Tension's reading of the shared filter, and the
 * factory-preset renders). */
static float b_q4(float hi, float v) {
  const float u = knob(fabsf(v));
  return (v < 0.0f ? -1.0f : 1.0f) * hi * u * u * u * u;
}
static float b_lin(float hi, float v) { return (v < 0.0f ? -1.0f : 1.0f) * c_lin(0.0f, hi, fabsf(v)); }

static uint32_t xs_next(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}
static float xs_unit(uint32_t* s) { return (float)(xs_next(s) >> 8) * (1.0f / 16777216.0f); }
static float xs_bipolar(uint32_t* s) { return 2.0f * xs_unit(s) - 1.0f; }

/* The engine's sine: a quintic on the phase in [0, 1) that meets sin(2 pi x)
 * at the quarter points, its small error a faint series of partials. */
static float av_sine(double ph) {
  const float x = (float)(ph - floor(ph));
  return x * (6.094263f + x * (6.094263f + x * (-85.31969f + x * (121.88526f - 48.754105f * x))));
}

/* ---- band-limited steps ---- */

/* The step's impulse: a sinc under a raised-cosine window, 13 zero
 * crossings each side. */
static double bl_kernel(double x) {
  const double h = (double)LE_ANALOG_BL_HALF;
  if (x <= -h || x >= h) return 0.0;
  const double s = x == 0.0 ? 1.0 : sin(AV_PI_D * x) / (AV_PI_D * x);
  return s * (0.5 + 0.5 * cos(AV_PI_D * x / (h + 0.5)));
}

/* The table of what a band-limited unit step adds to the naive one: row r
 * is a step r / LE_ANALOG_BL_PHASES of a sample before the current sample,
 * column j the sample j - LE_ANALOG_BL_HALF from it. The step is the
 * running sum of the impulse's samples, scaled to end at exactly 1. */
static void bl_init(le_analog* d) {
  const int32_t H = LE_ANALOG_BL_HALF;
  for (int32_t r = 0; r <= LE_ANALOG_BL_PHASES; ++r) {
    const double frac = (double)r / LE_ANALOG_BL_PHASES;
    double total = 0.0;
    for (int32_t i = -H - 1; i <= H + 1; ++i) total += bl_kernel((double)i + 1.0 - frac);
    for (int32_t j = 0; j < 2 * H; ++j) {
      const double x = (double)(j - H) + 1.0 - frac; /* the sample's time after the step */
      double run = 0.0;
      for (int32_t i = 0; i <= 2 * H + 1; ++i) run += bl_kernel(x - (double)i);
      d->bl[r][j] = (float)(run / total - (x >= 0.0 ? 1.0 : 0.0));
    }
  }
}

/* A step of height h at `te` of the way from the last sample to the
 * current one, band-limited into the chain's output ring. */
static void bl_add(const le_analog* d, le_analog_chain* ch, float te, float h) {
  const float p = clampf(te, 0.0f, 1.0f) * (float)LE_ANALOG_BL_PHASES;
  int32_t r = (int32_t)p;
  if (r >= LE_ANALOG_BL_PHASES) r = LE_ANALOG_BL_PHASES - 1;
  const float w = p - (float)r;
  const float* a = d->bl[r];
  const float* b = d->bl[r + 1];
  for (int32_t j = 0; j < 2 * LE_ANALOG_BL_HALF; ++j) {
    const int32_t at = (ch->ring_at + j - LE_ANALOG_BL_HALF) & (LE_ANALOG_BL_RING - 1);
    ch->ring[at] += h * (a[j] + w * (b[j] - a[j]));
  }
}

/* ---- envelopes ---- */

typedef struct av_env {
  float attack, decay, release, sustain, sustain_time; /* seconds, level */
  int exp_, loop, free_run;
  float vel_level, vel_time; /* 0..8 */
} av_env;

static av_env read_env(const le_analog* d, int32_t c, int32_t base) {
  av_env e;
  const int32_t b = LE_ANALOG_CHAIN(c, base);
  e.attack = c_exp(0.005f, 15.0f, d->values[b + LE_ANALOG_ENV_ATTACK]);
  e.decay = c_exp(0.005f, 15.0f, d->values[b + LE_ANALOG_ENV_DECAY]);
  e.release = c_exp(0.005f, 15.0f, d->values[b + LE_ANALOG_ENV_RELEASE]);
  e.sustain = c_lin(0.0f, 1.0f, d->values[b + LE_ANALOG_ENV_SUSTAIN]);
  e.sustain_time = c_exp(0.1f, 1000.0f, d->values[b + LE_ANALOG_ENV_SUSTAIN_TIME]);
  e.exp_ = (int)d->values[b + LE_ANALOG_ENV_EXP];
  e.loop = (int)d->values[b + LE_ANALOG_ENV_LOOP];
  e.free_run = (int)d->values[b + LE_ANALOG_ENV_FREE_RUN];
  e.vel_level = c_lin(0.0f, 8.0f, d->values[b + LE_ANALOG_ENV_VEL]);
  e.vel_time = c_lin(0.0f, 8.0f, d->values[b + LE_ANALOG_ENV_ATTACK_VEL]);
  return e;
}

static void env_segment(le_analog_env* e, int32_t seg, float to, float seconds, int exp_, float rate) {
  e->seg = seg;
  e->y0 = e->y;
  e->to = to;
  int32_t n = (int32_t)(seconds * rate);
  if (n < 1) n = 1;
  e->left = n;
  e->step = (to - e->y) / (float)n;
  e->c = exp_ ? 3.4906588f / (float)n : 0.0f;
  if (e->c > 1.0f) e->c = 1.0f;
}

static float env_attack_time(const av_env* p, float vel) {
  return p->attack * exp2f(-p->vel_time * (vel - 0.5f));
}

static void env_start(le_analog_env* e, const av_env* p, float vel, float rate, int from_current) {
  e->scale = exp2f(p->vel_level * (vel - 0.5f));
  if (!from_current) e->y = 0.0f;
  env_segment(e, SEG_ATTACK, e->scale, env_attack_time(p, vel), p->exp_, rate);
}

/* A retrigger: a straight fall to 0 over 0.7 ms, then the attack (fit:
 * the glide renders' dip at the key change). */
static void env_drop(le_analog_env* e, const av_env* p, float vel, float rate) {
  e->scale = exp2f(p->vel_level * (vel - 0.5f));
  if (e->seg == SEG_IDLE) e->y = 0.0f;
  env_segment(e, SEG_DROP, 0.0f, 0.0007f, 0, rate);
}

/* fit: what the envelope renders show, where the reading differs. The
 * sustain stage is a fall from the sustain level to 0 over Sustain Time
 * (its top position holds); loop mode 1 repeats attack and decay while the
 * gate is held; mode 2 attack, decay and release; mode 3 lets the sustain
 * fall like mode 0, and at the gate's end rises again over the attack time
 * before the release. */
static void env_release(le_analog_env* e, const av_env* p, float vel, float rate) {
  if (e->seg == SEG_IDLE || e->seg == SEG_RELEASE) return;
  if (p->loop == 3 && !(e->seg == SEG_POST && e->left >= 0)) {
    env_segment(e, SEG_POST, e->scale, env_attack_time(p, vel), p->exp_, rate);
    return;
  }
  env_segment(e, SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
}

/* The segment after `seg` ends. `held`: the gate is on. */
static void env_next(le_analog_env* e, const av_env* p, int held, float vel, float rate) {
  switch (e->seg) {
    case SEG_ATTACK:
      env_segment(e, SEG_DECAY, p->sustain * e->scale, p->decay, p->exp_, rate);
      break;
    case SEG_DECAY:
      if (p->loop == 1 && held) {
        env_segment(e, SEG_ATTACK, e->scale, env_attack_time(p, vel), p->exp_, rate);
      } else if (p->free_run || p->loop == 2) {
        env_segment(e, SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
      } else if (p->sustain_time >= 999.0f) {
        e->seg = SEG_SUSTAIN;
        e->left = -1;
      } else {
        env_segment(e, SEG_SUSTAIN, 0.0f, p->sustain_time, p->exp_, rate);
      }
      break;
    case SEG_SUSTAIN:
      if (p->loop == 3) {
        /* waits at 0 for the gate's end */
        e->seg = SEG_POST;
        e->left = -1;
      } else {
        e->seg = SEG_IDLE;
      }
      e->y = 0.0f;
      break;
    case SEG_DROP:
      env_segment(e, SEG_ATTACK, e->scale, env_attack_time(p, vel), p->exp_, rate);
      break;
    case SEG_POST:
      /* mode 3's rise at the gate's end, then the release */
      env_segment(e, SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
      break;
    case SEG_RELEASE:
      if (p->loop == 2 && held) {
        env_segment(e, SEG_ATTACK, e->scale, env_attack_time(p, vel), p->exp_, rate);
      } else {
        e->seg = SEG_IDLE;
        e->y = 0.0f;
      }
      break;
    default:
      break;
  }
}

static float env_tick(le_analog_env* e, const av_env* p, int held, float vel, float rate) {
  if (e->seg == SEG_IDLE) return 0.0f;
  if (e->left < 0) return e->seg == SEG_SUSTAIN ? (e->y = p->sustain * e->scale) : e->y;
  if (e->c > 0.0f) {
    /* toward an overshoot so the one-pole lands on the target in time */
    e->y = e->y * (1.0f - e->c) + e->c * (e->y0 + 1.0313935f * (e->to - e->y0));
  } else {
    e->y += e->step;
  }
  if (--e->left <= 0) {
    e->y = e->to;
    env_next(e, p, held, vel, rate);
  }
  return e->y;
}

/* ---- the LFO ---- */

/* The tempo divisions 0..23 in beats per cycle: 16 beats down to an
 * eighth of a beat, each dotted, straight and triplet (fit: the brass
 * presets' LFO pan, whose divisions 3 and 4 run 6 and 4 s at 120 BPM). */
static float sync_beats(int32_t s) {
  static const float beats[8] = {16.0f, 8.0f, 4.0f, 2.0f, 1.0f, 0.5f, 0.25f, 0.125f};
  if (s < 0) s = 0;
  if (s > 23) s = 23;
  const int32_t kind = s % 3;
  const float b = beats[s / 3];
  return kind == 0 ? 1.5f * b : kind == 1 ? b : b * 2.0f / 3.0f;
}

static float lfo_shape(int32_t wave, double p, float w, float sh, float sh_prev) {
  switch (wave) {
    case 0: return sinf(2.0f * AV_PI * (float)p);
    case 1: {
      /* starts at its top (fit: the lfo-wave renders); the fall lasts w of
       * the cycle */
      const float x = (float)p;
      return x < w ? 1.0f - 2.0f * x / w : -1.0f + 2.0f * (x - w) / (1.0f - w);
    }
    case 2: return p < w ? 1.0f : -1.0f;
    case 3: return sh; /* sample and hold */
    /* fit: noise ramps from one cycle's random value to the next (the
     * lfo-wave renders) */
    default: return sh_prev + (sh - sh_prev) * (float)p;
  }
}

/* ---- voices ---- */

static const int32_t kVoices[10] = {1, 2, 4, 8, 12, 16, 20, 24, 28, 32};

static int sounding(const le_analog_voice* v) {
  return v->state == LE_ANALOG_VOICE_HELD || v->state == LE_ANALOG_VOICE_RELEASED ||
         v->state == LE_ANALOG_VOICE_SUSTAINED;
}

static void fade_voice(le_analog_voice* v) {
  if (v->state == LE_ANALOG_VOICE_FREE) return;
  v->state = LE_ANALOG_VOICE_FADING;
  if (v->fade_left <= 0) v->fade_left = LE_ANALOG_FADE_MS * v->fade_len;
}

static int32_t copies_per_note(const le_analog* d) {
  return vi(d, LE_ANALOG_UNISON_ON) ? (vi(d, LE_ANALOG_UNISON) ? 4 : 2) : 1;
}

static int32_t note_count(const le_analog* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

static int mono(const le_analog* d) { return vi(d, LE_ANALOG_POLYPHONY) == 0; }

static int32_t voice_count(const le_analog* d) {
  int32_t n = kVoices[vi(d, LE_ANALOG_POLYPHONY)];
  const int32_t lim = d->voice_limit / copies_per_note(d);
  if (n > lim) n = lim;
  return n < 1 ? 1 : n;
}

static le_analog_voice* oldest(le_analog* d, int32_t state) {
  le_analog_voice* old = NULL;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

static le_analog_voice* free_slot(le_analog* d) {
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_ANALOG_VOICE_FREE) return &d->voices[i];
  }
  le_analog_voice* v = oldest(d, LE_ANALOG_VOICE_FADING);
  return v != NULL ? v : oldest(d, LE_ANALOG_VOICE_RELEASED);
}

/* The keyboard pitch of `note` in octaves from C4: transpose, octave and
 * fine tune included. */
static float key_pitch(const le_analog* d, int32_t note) {
  const float fine = (vf(d, LE_ANALOG_FINE_TUNE) - 0.5f) * 2.0f / 12.0f;
  return ((float)(note - 60) + (float)vi(d, LE_ANALOG_TRANSPOSE)) / 12.0f +
         (float)vi(d, LE_ANALOG_OCTAVE) + fine;
}

/* fit: the glide time knob, 3 ms .. 9 s (the glide renders' time
 * constants at two settings) */
static float glide_seconds(const le_analog* d) { return c_exp(0.003f, 9.0f, vf(d, LE_ANALOG_GLIDE_TIME)); }

/* The mono note among the held keys: 0 the highest, 1 the lowest, 2 the
 * newest (fit: the glide renders start at the lower key's release with
 * priority 1). Returns the index into the held list, or -1. */
static int32_t priority_index(const le_analog* d) {
  if (d->held_n == 0) return -1;
  const int32_t pr = vi(d, LE_ANALOG_PRIORITY);
  int32_t best = d->held_n - 1;
  for (int32_t i = 0; i < d->held_n && pr != 2; ++i) {
    if (pr == 0 ? d->held_note[i] > d->held_note[best] : d->held_note[i] < d->held_note[best]) best = i;
  }
  return best;
}

/* A copy starts from rest: its filters, the integrator's leak and the
 * noise filter cleared, so nothing of the slot's last note rings on. */
static void start_copy(le_analog* d, le_analog_voice* v, le_analog_copy* cp) {
  const float rate = (float)d->sample_rate;
  cp->noise_lp = 0.0f;
  for (int32_t c = 0; c < 2; ++c) {
    le_analog_chain* ch = &cp->ch[c];
    const av_env fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
    const av_env ae = read_env(d, c, LE_ANALOG_AMP_ENV);
    env_start(&ch->fenv, &fe, v->velocity, rate, 0);
    env_start(&ch->aenv, &ae, v->velocity, rate, 0);
    memset(ch->s, 0, sizeof(ch->s));
    ch->noise_lp = 0.0f;
    memset(ch->ring, 0, sizeof(ch->ring));
    ch->ring_at = 0;
    ch->penv = 1.0f;
    ch->penv_step = 1.0f / fmaxf(c_exp(0.01f, 10.0f, cf(d, c, LE_ANALOG_OSC_ENV_TIME)) * rate, 1.0f);
    /* fit: the oscillators start where Live's do (the oscillator renders):
     * the saw halfway up its ramp (the sync slave too), the rectangle at the
     * start of its low part, the sub square low, the sync master at its
     * reset; the rectangle's integrator holds its mean already */
    const int32_t shape = ci(d, c, LE_ANALOG_OSC_SHAPE);
    ch->ph = shape == 1 ? 0.5 : 0.0;
    ch->ph2 = 0.0;
    ch->sub_sign = -1;
    ch->dc = shape == 2 ? 0.0365f + 0.4635f * knob(cf(d, c, LE_ANALOG_OSC_PW)) : 0.0f;
    if (ci(d, c, LE_ANALOG_LFO_GATE_RESET)) {
      ch->lfo_ph = cf(d, c, LE_ANALOG_LFO_PHASE);
    }
    /* fit: the random waves start from a random value, noise held there
     * for the first cycle (the lfo-wave renders) */
    ch->lfo_sh = ch->lfo_sh_prev = xs_bipolar(&cp->rng);
    ch->lfo_wait = c_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_DELAY));
    if (cf(d, c, LE_ANALOG_LFO_DELAY) <= 0.0f) ch->lfo_wait = 0.0f;
    ch->lfo_amp = cf(d, c, LE_ANALOG_LFO_FADE) <= 0.0f ? 1.0f : 0.0f;
    ch->gl = ch->gr = -1.0f;
  }
}

/* The unison amounts' curve: Exp(lo, hi) on m = 127 v, exactly 0 at 0. */
static float unison_expz(float lo, float hi, float v) {
  const float m = 127.0f * clampf(v, 0.0f, 1.0f);
  return m <= 0.0f ? 0.0f : lo * powf(hi / lo, m / 127.0f);
}

static void start_voice(le_analog* d, le_analog_voice* v, uint32_t origin, int32_t note, float vel,
                        uint64_t serial, int glide) {
  v->state = LE_ANALOG_VOICE_HELD;
  v->note = note;
  v->origin = origin;
  v->serial = serial;
  v->velocity = vel;
  v->copies = copies_per_note(d);
  v->tick_left = 0;
  v->since = 0;
  v->fade_left = 0;
  v->fade_len = (int32_t)lroundf(0.001f * (float)d->sample_rate);
  v->vib_t = 0.0f;
  v->pitch_to = key_pitch(d, note);
  v->pitch = glide ? d->last_pitch : v->pitch_to;
  /* the unison copies sit 0, +1, -1, +2 steps from the note (fit: the
   * unison renders), a step of ExpZ(0.001, 1) octaves on the stored value
   * times 127 (Tension's reading of the shared unison; 0.379 semitone at
   * 0.5 where the renders measure 0.374, an octave at 1 as Organ Vibrato
   * shows); the copies start ExpZ(0.002, 0.1) s apart */
  static const float kSteps[LE_ANALOG_COPIES] = {0.0f, 1.0f, -1.0f, 2.0f};
  const float step = unison_expz(0.001f, 1.0f, vf(d, LE_ANALOG_UNISON_DETUNE));
  const float delay = unison_expz(0.002f, 0.1f, vf(d, LE_ANALOG_UNISON_DELAY)) * (float)d->sample_rate;
  for (int32_t k = 0; k < v->copies; ++k) {
    le_analog_copy* cp = &v->c[k];
    cp->detune = step * kSteps[k];
    cp->delay = (int32_t)(delay * (float)k / (float)(v->copies > 1 ? v->copies - 1 : 1));
    start_copy(d, v, cp);
  }
  d->last_pitch = v->pitch_to;
  d->played = 1;
}

static void held_push(le_analog* d, uint32_t origin, int32_t note) {
  if (d->held_n == LE_ANALOG_HELD_MAX) {
    memmove(d->held_note, d->held_note + 1, sizeof(int32_t) * (LE_ANALOG_HELD_MAX - 1));
    memmove(d->held_origin, d->held_origin + 1, sizeof(uint32_t) * (LE_ANALOG_HELD_MAX - 1));
    d->held_n--;
  }
  d->held_note[d->held_n] = note;
  d->held_origin[d->held_n] = origin;
  d->held_n++;
}

static void held_drop(le_analog* d, uint32_t origin) {
  int32_t keep = 0;
  for (int32_t i = 0; i < d->held_n; ++i) {
    if (d->held_origin[i] == origin) continue;
    d->held_note[keep] = d->held_note[i];
    d->held_origin[keep] = d->held_origin[i];
    keep++;
  }
  d->held_n = keep;
}

static void release_voice(le_analog* d, le_analog_voice* v) {
  v->state = LE_ANALOG_VOICE_RELEASED;
  const float rate = (float)d->sample_rate;
  for (int32_t k = 0; k < v->copies; ++k) {
    for (int32_t c = 0; c < 2; ++c) {
      const av_env fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
      const av_env ae = read_env(d, c, LE_ANALOG_AMP_ENV);
      env_release(&v->c[k].ch[c].fenv, &fe, v->velocity, rate);
      env_release(&v->c[k].ch[c].aenv, &ae, v->velocity, rate);
    }
  }
}

static void let_go(le_analog* d, le_analog_voice* v) {
  if (d->sustain_n > 0) v->state = LE_ANALOG_VOICE_SUSTAINED;
  else release_voice(d, v);
}

int32_t le_analog_init(le_analog* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_ANALOG_VOICE_SLOTS;
  d->rng = 0x2545f491u;
  bl_init(d);
  for (int32_t p = 0; p < LE_ANALOG_PARAMS; ++p) d->values[p] = param_def(p).def;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    for (int32_t k = 0; k < LE_ANALOG_COPIES; ++k) {
      d->voices[i].c[k].rng = 0x9e3779b9u ^ (uint32_t)((i * LE_ANALOG_COPIES + k + 1) * 2654435761u);
      for (int32_t c = 0; c < 2; ++c) d->voices[i].c[k].ch[c].fenv.seg = d->voices[i].c[k].ch[c].aenv.seg = SEG_IDLE;
    }
  }
  return 0;
}

void le_analog_set_values(le_analog* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_ANALOG_PARAMS; ++p) d->values[p] = le_analog_clamp(p, values[p]);
}

void le_analog_set_tempo(le_analog* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

int32_t le_analog_note_on(le_analog* d, uint32_t origin, int32_t note, int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  const float vel = (float)velocity / 127.0f;
  if (!chord) {
    for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
      le_analog_voice* v = &d->voices[i];
      if (v->state == LE_ANALOG_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
    held_drop(d, origin);
  }
  const int overlapping = d->held_n > 0;
  const int glide = vi(d, LE_ANALOG_GLIDE_ON) && d->played && !chord &&
                    (!vi(d, LE_ANALOG_GLIDE_LEGATO) || overlapping);
  /* mono: a held voice moves to the new key; legato envelopes do not
   * restart */
  if (mono(d)) {
    for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
      le_analog_voice* v = &d->voices[i];
      if (!sounding(v)) continue;
      held_push(d, origin, note);
      const int32_t pi = priority_index(d);
      if (overlapping && v->state == LE_ANALOG_VOICE_HELD && d->held_note[pi] != note) {
        return 0; /* the held key keeps the voice */
      }
      d->held_n--; /* pushed again below */
      /* legato only for a voice still held: one let go above restarts */
      const int was_held = v->state == LE_ANALOG_VOICE_HELD;
      v->note = note;
      v->origin = origin;
      v->velocity = vel;
      v->pitch_to = key_pitch(d, note);
      if (!glide) v->pitch = v->pitch_to;
      v->state = LE_ANALOG_VOICE_HELD;
      for (int32_t k = 0; k < v->copies; ++k) {
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &v->c[k].ch[c];
          const int fleg = overlapping && was_held && ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO);
          const int aleg = overlapping && was_held && ci(d, c, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO);
          const av_env fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
          const av_env ae = read_env(d, c, LE_ANALOG_AMP_ENV);
          if (!fleg) env_drop(&ch->fenv, &fe, vel, (float)d->sample_rate);
          if (!aleg) env_drop(&ch->aenv, &ae, vel, (float)d->sample_rate);
        }
      }
      held_push(d, origin, note);
      d->last_pitch = v->pitch_to;
      return 0;
    }
  }
  held_push(d, origin, note);
  const int32_t count = voice_count(d);
  while (note_count(d) >= count) {
    le_analog_voice* v = oldest(d, LE_ANALOG_VOICE_RELEASED);
    if (v == NULL) v = oldest(d, LE_ANALOG_VOICE_SUSTAINED);
    if (v == NULL) v = oldest(d, LE_ANALOG_VOICE_HELD);
    if (v == NULL) break;
    fade_voice(v);
    d->stolen++;
  }
  le_analog_voice* v = free_slot(d);
  if (v != NULL) start_voice(d, v, origin, note, vel, ++d->serial, glide);
  return 0;
}

/* A mono voice's envelopes start again for a new key, through a drop to
 * 0, each unless its Legato is on (fit: the glide renders dip to silence at
 * the key change). */
static void retrigger(le_analog* d, le_analog_voice* v) {
  for (int32_t k = 0; k < v->copies; ++k) {
    for (int32_t c = 0; c < 2; ++c) {
      le_analog_chain* ch = &v->c[k].ch[c];
      const av_env fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
      const av_env ae = read_env(d, c, LE_ANALOG_AMP_ENV);
      if (!ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO)) env_drop(&ch->fenv, &fe, v->velocity, (float)d->sample_rate);
      if (!ci(d, c, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO)) env_drop(&ch->aenv, &ae, v->velocity, (float)d->sample_rate);
    }
  }
}

/* A held voice whose key is up: in mono it moves to the held key the
 * priority picks, retriggered, otherwise it is let go. */
static void key_up(le_analog* d, le_analog_voice* v) {
  if (mono(d) && d->held_n > 0) {
    const int32_t pi = priority_index(d);
    const int moved = d->held_note[pi] != v->note;
    v->note = d->held_note[pi];
    v->origin = d->held_origin[pi];
    v->pitch_to = key_pitch(d, v->note);
    if (!vi(d, LE_ANALOG_GLIDE_ON)) v->pitch = v->pitch_to;
    d->last_pitch = v->pitch_to;
    if (moved) retrigger(d, v);
    return;
  }
  let_go(d, v);
}

void le_analog_note_off(le_analog* d, uint32_t origin) {
  if (d == NULL) return;
  held_drop(d, origin);
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (v->state == LE_ANALOG_VOICE_HELD && v->origin == origin) key_up(d, v);
  }
}

static void release_sustained(le_analog* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_ANALOG_VOICE_SUSTAINED) release_voice(d, &d->voices[i]);
  }
}

int32_t le_analog_sustain(le_analog* d, uint32_t origin, int on) {
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
  if (d->sustain_n >= LE_ANALOG_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_analog_expression(le_analog* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = clampf(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_analog_release_matching(le_analog* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = d->held_n - 1; i >= 0; --i) {
    if (i < d->held_n && (d->held_origin[i] & mask) == value) held_drop(d, d->held_origin[i]);
  }
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (v->state == LE_ANALOG_VOICE_HELD && (v->origin & mask) == value) {
      key_up(d, v);
    } else if (v->state == LE_ANALOG_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(d, v);
    }
  }
}

int32_t le_analog_held(const le_analog* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    const le_analog_voice* v = &d->voices[i];
    if (v->state == LE_ANALOG_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_analog_cut(le_analog* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->held_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_analog_fade_oldest(le_analog* d) {
  if (d == NULL) return 0;
  le_analog_voice* old = NULL;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  fade_voice(old);
  d->stolen++;
  return old->copies;
}

int32_t le_analog_active(const le_analog* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (sounding(&d->voices[i])) n += d->voices[i].copies;
  }
  return n;
}

int32_t le_analog_fading(const le_analog* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_ANALOG_VOICE_FADING) n += d->voices[i].copies;
  }
  return n;
}

void le_analog_set_voice_limit(le_analog* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_ANALOG_VOICE_SLOTS ? LE_ANALOG_VOICE_SLOTS : limit;
  while (le_analog_active(d) > d->voice_limit) {
    if (!le_analog_fade_oldest(d)) break;
  }
}

/* ---- the control tick ---- */

/* Per chain, the values one tick holds. */
typedef le_analog_tick av_tick;

/* The formant filter's vowels, Peterson and Barney's adult-male averages
 * (1952): F1..F3 in Hz and their levels in dB, for i, I, E, ae, a, open o,
 * U, u, ^ and the r-coloured vowel. fit: a's F1 at 660 Hz, not their 730,
 * where the formant renders put it. */
static const float kVowelHz[10][3] = {
    {270.0f, 2290.0f, 3010.0f}, {390.0f, 1990.0f, 2550.0f}, {530.0f, 1840.0f, 2480.0f},
    {660.0f, 1720.0f, 2410.0f}, {660.0f, 1090.0f, 2440.0f}, {570.0f, 840.0f, 2410.0f},
    {440.0f, 1020.0f, 2240.0f}, {300.0f, 870.0f, 2240.0f},  {640.0f, 1190.0f, 2390.0f},
    {490.0f, 1350.0f, 1690.0f}};
static const float kVowelDb[10][3] = {
    {-4.0f, -24.0f, -28.0f}, {-3.0f, -23.0f, -27.0f}, {-2.0f, -17.0f, -24.0f}, {-1.0f, -12.0f, -22.0f},
    {-1.0f, -5.0f, -28.0f},  {0.0f, -7.0f, -34.0f},   {-1.0f, -12.0f, -34.0f}, {-3.0f, -19.0f, -43.0f},
    {-1.0f, -10.0f, -27.0f}, {-5.0f, -15.0f, -20.0f}};

/* The formant types' coefficients: three band-passes at a vowel's
 * formants. The Q knob's position (plus its modulation, 64 steps an
 * octave) picks the vowel, 0..9 across the knob; the cutoff knob moves all
 * three an octave either way of a 270 Hz reference, by its whole steps,
 * and the cutoff modulation moves them smoothly. Formant 6 rings at Q 20,
 * Formant 12 at 45. */
static void formant_tick(const le_analog* d, le_analog_chain* ch, int32_t c, float e_cut, float e_q,
                         float rate) {
  const float m_q = roundf(knob(cf(d, c, LE_ANALOG_FILTER_Q)) * 127.0f);
  const float m_c = roundf(knob(cf(d, c, LE_ANALOG_FILTER_CUTOFF)) * 127.0f);
  const float vowel = 0.072f * (clampf(m_q + 64.0f * e_q, 1.0f, 126.0f) - 1.0f);
  const int32_t i0 = vowel >= 9.0f ? 8 : (int32_t)vowel;
  const float w = vowel - (float)i0;
  const float ref = fmaxf(270.0f * exp2f(e_cut + 2.0f * m_c / 127.0f - 1.0f), 20.0f);
  const float q = ci(d, c, LE_ANALOG_FILTER_TYPE) == 8 ? 20.0f : 45.0f;
  for (int32_t b = 0; b < 3; ++b) {
    const float hz = kVowelHz[i0][b] + w * (kVowelHz[i0 + 1][b] - kVowelHz[i0][b]);
    const float l0 = powf(10.0f, kVowelDb[i0][b] / 20.0f), l1 = powf(10.0f, kVowelDb[i0 + 1][b] / 20.0f);
    const float f = clampf(hz / 270.0f * ref, 10.0f, 0.49f * rate);
    ch->g[b] = tanf(AV_PI * f / rate);
    /* the band node peaks at q: each band at 1 / q peaks at unity */
    ch->level[b] = 8.0f / sqrtf(q) * (l0 + w * (l1 - l0)) * (b == 1 ? -1.0f : 1.0f);
  }
  ch->k = 1.0f / q;
}

static void tick_chain(le_analog* d, le_analog_voice* v, le_analog_copy* cp, int32_t c,
                       float pitch_cv, float vib, av_tick* t, float f1_fc) {
  const float rate = (float)d->sample_rate;
  le_analog_chain* ch = &cp->ch[c];
  const float dt = (float)LE_ANALOG_TICK / rate;
  /* the LFO, scaled by its delay and fade */
  float lfo = 0.0f;
  if (ci(d, c, LE_ANALOG_LFO_ON)) {
    float hz;
    if (ci(d, c, LE_ANALOG_LFO_SYNC_ON)) {
      hz = d->bpm / 60.0f / sync_beats(ci(d, c, LE_ANALOG_LFO_SYNC));
    } else {
      hz = c_exp(3.0f, 1000.0f, cf(d, c, LE_ANALOG_LFO_SPEED)) / 60.0f;
    }
    const float w = 0.05f + 0.9f * knob(cf(d, c, LE_ANALOG_LFO_PW));
    const double before = ch->lfo_ph;
    ch->lfo_ph += (double)(hz * dt);
    if (ch->lfo_ph >= 1.0) {
      ch->lfo_ph -= floor(ch->lfo_ph);
      ch->lfo_sh_prev = ch->lfo_sh;
      ch->lfo_sh = xs_bipolar(&cp->rng);
    }
    const int32_t wave = ci(d, c, LE_ANALOG_LFO_WAVE);
    float y = lfo_shape(wave, before, w, ch->lfo_sh, ch->lfo_sh_prev);
    if (ch->lfo_wait > 0.0f) {
      ch->lfo_wait -= dt;
      y = 0.0f;
    } else if (ch->lfo_amp < 1.0f) {
      const float fade = c_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_FADE));
      ch->lfo_amp = fminf(ch->lfo_amp + dt / fade, 1.0f);
    }
    lfo = y * ch->lfo_amp;
  }
  ch->lfo = lfo;
  /* the oscillator's pitch */
  const float det = knob(cf(d, c, LE_ANALOG_OSC_DETUNE)) * 127.0f / 64.0f - 1.0f;
  const float base = (float)ci(d, c, LE_ANALOG_OSC_OCT) + (float)ci(d, c, LE_ANALOG_OSC_SEMI) / 12.0f +
                     (det < 0.0f ? -0.25f : 0.25f) * det * det;
  const float m1 = knob(cf(d, c, LE_ANALOG_OSC_MOD1)) * 127.0f / 64.0f;
  const float k1 = m1 * m1;
  const float env_amt = cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT) != 0.0f
                            ? (cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT) < 0.0f ? -1.0f : 1.0f) *
                                  c_exp(0.01f, 6.0f, fabsf(cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT)))
                            : 0.0f;
  const float lfo_pitch = b_sq(4.0f, cf(d, c, LE_ANALOG_OSC_LFO_PITCH)) * lfo;
  const float key = clampf(pitch_cv + cp->detune + vib, -8.0f, 8.0f);
  const float sync = ci(d, c, LE_ANALOG_OSC_MODE) == 1 && ci(d, c, LE_ANALOG_OSC_SHAPE) != 0;
  const float f_key = AV_C4 * exp2f(base + k1 * key);
  if (sync) {
    t->ratio = c_exp(1.0f, 20.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    ch->inc_m = fminf(f_key, 0.25f * rate) / rate;
    ch->inc = fminf(fmaxf(f_key * t->ratio * exp2f(lfo_pitch + env_amt * ch->penv), f_key), 0.45f * rate) / rate;
    t->sub = 0.0f;
  } else {
    const float f = f_key * exp2f(lfo_pitch + env_amt * ch->penv);
    ch->inc = fminf(f, 0.25f * rate) / rate;
    ch->inc_m = ch->inc;
    const float s = c_exp(0.01f, 1.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    t->sub = s <= 0.0101f ? 0.0f : s;
    t->ratio = 0.0f; /* no sync */
  }
  ch->penv = fmaxf(ch->penv - ch->penv_step * (float)LE_ANALOG_TICK, 0.0f);
  /* the pulse width, folded into its range, then the LFO */
  float pw = 0.0365f + 0.4635f * knob(cf(d, c, LE_ANALOG_OSC_PW));
  pw *= 1.0f + 0.8f * b_sq(1.0f, cf(d, c, LE_ANALOG_OSC_LFO_PW)) * lfo;
  t->pw = clampf(pw, 0.02f, 0.98f);
  /* the routing: equal power into the two filters */
  const float lvl = ci(d, c, LE_ANALOG_OSC_ON) ? c_exp(0.01f, 3.0f, cf(d, c, LE_ANALOG_OSC_LEVEL)) : 0.0f;
  /* fit: the stored balance runs from filter 2 (0) to filter 1 (1) (the
   * routing renders; the factory presets store osc 1 at 1, osc 2 at 0) */
  const float bal = knob(cf(d, c, LE_ANALOG_OSC_BALANCE));
  t->to_f1 = lvl * sinf(0.5f * AV_PI * bal);
  t->to_f2 = lvl * cosf(0.5f * AV_PI * bal);
  /* the filter */
  const float fenv = ch->fenv.y;
  const float e_cut = b_sq(4.0f, cf(d, c, LE_ANALOG_FILTER_KEY_CUTOFF)) * (pitch_cv + vib) +
                      b_sq(4.0f, cf(d, c, LE_ANALOG_FILTER_LFO_CUTOFF)) * lfo +
                      b_q4(16.0f, cf(d, c, LE_ANALOG_FILTER_ENV_CUTOFF)) * fenv;
  float fc;
  if (c == 1 && ci(d, 1, LE_ANALOG_CHAIN_LINK)) {
    /* filter 2 follows filter 1, its knob a ratio of +-2 octaves */
    fc = f1_fc * exp2f(knob(cf(d, 1, LE_ANALOG_FILTER_CUTOFF)) * 127.0f / 32.0f - 2.0f) * exp2f(e_cut);
  } else {
    fc = c_exp(30.0f, 22000.0f, cf(d, c, LE_ANALOG_FILTER_CUTOFF)) * exp2f(e_cut);
  }
  fc = fmaxf(fc, 20.0f);
  ch->fc = fc;
  const float e_q = b_sq(4.0f, cf(d, c, LE_ANALOG_FILTER_KEY_Q)) * pitch_cv +
                    b_sq(4.0f, cf(d, c, LE_ANALOG_FILTER_LFO_Q)) * lfo +
                    b_sq(4.0f, cf(d, c, LE_ANALOG_FILTER_ENV_Q)) * fenv;
  t->q = fminf(c_exp(0.1f, 120.0f, cf(d, c, LE_ANALOG_FILTER_Q)) * exp2f(e_q), 100.0f);
  t->fc = fminf(fmaxf(fc, 10.0f), 0.49f * rate);
  if (ci(d, c, LE_ANALOG_FILTER_TYPE) >= 8) formant_tick(d, ch, c, e_cut, e_q, rate);
  /* the amp: level, LFO, key (the envelope applies per sample); the pan.
   * fit: the LFO's depths on the level and the pan are linear in the knob
   * (the tremolo renders) */
  const float aenv = ch->aenv.y;
  float gain = 0.0f;
  if (ci(d, c, LE_ANALOG_AMP_ON)) {
    gain = c_exp(0.01f, 2.0f, cf(d, c, LE_ANALOG_AMP_LEVEL)) *
           (1.0f + b_lin(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_VOL)) * lfo) *
           expf(b_lin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_VOL)) * v->pitch);
  }
  /* fit: the pan is its stored value, centred exactly at 0.5 (the pan
   * renders), not a 128-step knob position */
  const float p = clampf(cf(d, c, LE_ANALOG_AMP_PAN), 0.0f, 1.0f);
  const float pm = clampf(b_lin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_PAN)) * v->pitch, -1.0f, 1.0f) +
                   b_lin(1.0f, cf(d, c, LE_ANALOG_AMP_ENV_PAN)) * aenv +
                   b_lin(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_PAN)) * lfo;
  const float pp = clampf(p < 0.5f ? p + p * pm : p + pm * (1.0f - p), 0.0f, 1.0f);
  const float gl = gain * cosf(0.5f * AV_PI * pp), gr = gain * sinf(0.5f * AV_PI * pp);
  if (ch->gl < 0.0f) {
    ch->gl = gl;
    ch->gr = gr;
    ch->gl_step = ch->gr_step = 0.0f;
  } else {
    ch->gl_step = (gl - ch->gl) / (float)LE_ANALOG_TICK;
    ch->gr_step = (gr - ch->gr) / (float)LE_ANALOG_TICK;
  }
}

/* ---- rendering ---- */

/* The naive saw or rectangle at phase `ph`: the saw rising across
 * -0.5..0.5, the rectangle 0 then 1 for the last w of the cycle. */
static float osc_naive(int32_t shape, double ph, float w) {
  if (shape == 1) return (float)ph - 0.5f;
  return ph >= 1.0 - (double)w ? 1.0f : 0.0f;
}

/* Moves a saw or rectangle from t0 to t1 of the way from the last sample
 * to the current one, a band-limited step at each edge it crosses: the
 * rectangle's rise, and the reset, where the sub square turns over. */
static void osc_run(const le_analog* d, le_analog_chain* ch, int32_t shape, float w, float sub, float t0,
                    float t1) {
  const double dt = (double)ch->inc;
  const double ph = ch->ph;
  double end = ph + dt * (double)(t1 - t0);
  if (shape == 2) {
    const double hi = 1.0 - (double)w;
    if (ph < hi && end >= hi) bl_add(d, ch, t0 + (float)((hi - ph) / dt), 1.0f);
  }
  if (end >= 1.0) {
    const float h = -1.0f - sub * (float)ch->sub_sign;
    ch->sub_sign = -ch->sub_sign;
    bl_add(d, ch, t0 + (float)((1.0 - ph) / dt), h);
    end -= 1.0;
  }
  ch->ph = end;
}

/* One oscillator sample, LE_ANALOG_BL_HALF samples late as Live's are:
 * the shape at the chain's phase, its sub square or its sync slave; saw and
 * rectangle peak-to-peak 1, the sine 0.7. */
static float osc_tick(const le_analog* d, le_analog_chain* ch, int32_t shape, const av_tick* t, uint32_t* rng) {
  float y;
  switch (shape) {
    case 0: {
      ch->ph += ch->inc;
      if (ch->ph >= 1.0) ch->ph -= 1.0;
      ch->ph2 += 0.5 * ch->inc;
      if (ch->ph2 >= 1.0) ch->ph2 -= 1.0;
      y = 0.7f * av_sine(ch->ph);
      if (t->sub > 0.0f) y += 0.7f * t->sub * av_sine(ch->ph2);
      break;
    }
    case 3:
      y = 0.9f * xs_bipolar(rng);
      break;
    default: {
      const float w = t->pw;
      const float sub = t->sub;
      float reset = -1.0f;
      if (t->ratio > 0.0f) {
        /* the master resets the slave, at a ratio of 1 too (fit: Saw Pure
         * Brass's chains beat in Live's phase only so) */
        ch->ph2 += ch->inc_m;
        if (ch->ph2 >= 1.0) {
          ch->ph2 -= 1.0;
          reset = 1.0f - (float)(ch->ph2 / ch->inc_m);
        }
      }
      if (reset >= 0.0f) {
        osc_run(d, ch, shape, w, sub, 0.0f, reset);
        bl_add(d, ch, reset, osc_naive(shape, 0.0, w) - osc_naive(shape, ch->ph, w));
        ch->ph = 0.0;
        osc_run(d, ch, shape, w, sub, reset, 1.0f);
      } else {
        osc_run(d, ch, shape, w, sub, 0.0f, 1.0f);
      }
      y = osc_naive(shape, ch->ph, w);
      if (sub > 0.0f) y += 0.5f * sub * (float)ch->sub_sign;
      /* the integrator's leak: the saw's 0.9995, the rectangle's 0.999995 */
      const float leak = shape == 1 ? 0.0005f : 0.000005f;
      ch->dc += leak * (y - ch->dc);
      y -= ch->dc;
      break;
    }
  }
  const int32_t m = LE_ANALOG_BL_RING - 1;
  ch->ring[ch->ring_at] += y;
  const int32_t out = (ch->ring_at - LE_ANALOG_BL_HALF) & m;
  y = ch->ring[out];
  ch->ring[out] = 0.0f;
  ch->ring_at = (ch->ring_at + 1) & m;
  return y;
}

/* The 2-pole core: low, band, notch or high, Q per stage. */
static float core(float* s, float x, float g, float k, int32_t type) {
  const float h = 1.0f / (1.0f + g * (g + k));
  const float b = (g * (x - s[1]) + s[0]) * h;
  const float l = s[1] + g * b;
  s[0] = 2.0f * b - s[0];
  s[1] = 2.0f * l - s[1];
  switch (type) {
    case 0: return l;
    case 1: return b; /* fit: the band node itself, peaking at Q */
    case 2: return x - k * b;
    default: return x - k * b - l;
  }
}

/* Drive: unchanged up to 1, bending smoothly toward a ceiling beyond. */
static float drive(float x, int32_t mode) {
  static const float kGain[7] = {1.0f, 1.0f, 1.41421356f, 2.0f, 1.0f, 1.41421356f, 2.0f};
  static const float kPos[7] = {0.0f, 8.0f, 4.0f, 2.0f, 4.0f, 2.0f, 1.3f};
  if (mode <= 0) return x;
  const float u = kGain[mode] * x;
  const float a = fabsf(u);
  if (a <= 1.0f) return u;
  const float L = u > 0.0f ? kPos[mode] : (mode >= 4 ? 8.0f : kPos[mode]);
  const float r = 1.0f + (a - 1.0f) / (3.0f * (L - 1.0f));
  const float y = L - (L - 1.0f) / (r * r * r);
  return u > 0.0f ? y : -y;
}

static void render_voice(le_analog* d, le_analog_voice* v, float* left, float* right, int32_t frames) {
  const float rate = (float)d->sample_rate;
  /* fit: the bundle's x4 does not reach Live's output (the level renders) */
  const float out_gain = c_sq(0.0f, 2.0f, vf(d, LE_ANALOG_VOLUME));
  const float fade_step = 1.0f / (float)(LE_ANALOG_FADE_MS * v->fade_len);
  const int32_t ramp_len = d->sample_rate / 441 > 1 ? d->sample_rate / 441 : 1;
  const int noise_on = vi(d, LE_ANALOG_NOISE_ON);
  const float noise_lvl = noise_on ? c_exp(0.01f, 3.0f, vf(d, LE_ANALOG_NOISE_LEVEL)) : 0.0f;
  const float noise_bal = knob(vf(d, LE_ANALOG_NOISE_BALANCE));
  const float noise_a = fminf(2.0f * AV_PI * c_exp(20.0f, 22000.0f, vf(d, LE_ANALOG_NOISE_COLOR)) / rate, 1.0f);
  int32_t i = 0;
  while (i < frames && v->state != LE_ANALOG_VOICE_FREE) {
    if (v->tick_left == 0) {
      /* glide, vibrato, bend: the voice's pitch */
      if (vi(d, LE_ANALOG_GLIDE_ON) && v->pitch != v->pitch_to) {
        float T = glide_seconds(d);
        if (vi(d, LE_ANALOG_GLIDE_MODE)) T *= sqrtf(fabsf(v->pitch_to - v->pitch));
        const float a = fminf(2.0f * AV_PI / (fmaxf(T, 1e-4f) * rate), 1.0f);
        v->pitch = v->pitch_to + (v->pitch - v->pitch_to) * powf(1.0f - a, (float)LE_ANALOG_TICK);
        if (fabsf(v->pitch - v->pitch_to) < 1e-5f) v->pitch = v->pitch_to;
      } else {
        v->pitch = v->pitch_to;
      }
      float vib = 0.0f;
      const float dtk = (float)LE_ANALOG_TICK / rate;
      v->vib_t += dtk;
      if (vi(d, LE_ANALOG_VIBRATO_ON)) {
        const float hz = c_lin(0.25f, 10.0f, vf(d, LE_ANALOG_VIBRATO_SPEED));
        float depth = (vf(d, LE_ANALOG_VIBRATO_AMOUNT) > 0.0f
                           ? c_exp(0.0002f, 1.0f / 6.0f, vf(d, LE_ANALOG_VIBRATO_AMOUNT))
                           : 0.0f) +
                      d->mod * (vf(d, LE_ANALOG_VIBRATO_WHEEL) > 0.0f
                                    ? c_exp(0.0002f, 1.0f / 6.0f, vf(d, LE_ANALOG_VIBRATO_WHEEL))
                                    : 0.0f);
        const float delay =
            vf(d, LE_ANALOG_VIBRATO_DELAY) > 0.0f ? c_exp(0.05f, 5.0f, vf(d, LE_ANALOG_VIBRATO_DELAY)) : 0.0f;
        const float fade =
            vf(d, LE_ANALOG_VIBRATO_FADE) > 0.0f ? c_exp(0.05f, 5.0f, vf(d, LE_ANALOG_VIBRATO_FADE)) : 0.0f;
        if (v->vib_t < delay) depth = 0.0f;
        else if (fade > 0.0f) depth *= fminf((v->vib_t - delay) / fade, 1.0f);
        v->vib_ph += (double)(hz * dtk);
        v->vib_ph -= floor(v->vib_ph);
        vib = depth * sinf(2.0f * AV_PI * (float)v->vib_ph);
      }
      const float pitch_cv = v->pitch + vf(d, LE_ANALOG_BEND_RANGE) * d->bend;
      for (int32_t k = 0; k < v->copies; ++k) {
        le_analog_copy* cp = &v->c[k];
        tick_chain(d, v, cp, 0, pitch_cv, vib, &cp->ch[0].t, 0.0f);
        tick_chain(d, v, cp, 1, pitch_cv, vib, &cp->ch[1].t, cp->ch[0].fc);
        cp->ch[0].t.link = knob(cf(d, 0, LE_ANALOG_CHAIN_LINK));
        cp->ch[0].t.link = 2.0f * cp->ch[0].t.link * cp->ch[0].t.link;
        for (int32_t c = 0; c < 2; ++c) {
          const float q = cp->ch[c].t.q;
          const int32_t ft = ci(d, c, LE_ANALOG_FILTER_TYPE);
          if (ft >= 8) continue; /* formant_tick set them */
          /* fit: BP12's two stages each take the full Q (the BP12 render);
           * the other 4-pole types take sqrt(Q) each */
          const float qs = ft % 2 == 1 && ft != 3 ? sqrtf(q) : q;
          cp->ch[c].g[0] = tanf(AV_PI * cp->ch[c].t.fc / rate);
          cp->ch[c].k = 1.0f / fmaxf(qs, 0.01f);
        }
      }
      v->tick_left = LE_ANALOG_TICK;
    }
    const int32_t n = v->tick_left < frames - i ? v->tick_left : frames - i;
    int idle = 1;
    for (int32_t k = 0; k < v->copies; ++k) {
      le_analog_copy* cp = &v->c[k];
      /* a delayed copy starts at its own sample, whatever the block */
      if (v->since + n <= cp->delay) {
        idle = 0;
        continue;
      }
      const int32_t s0 = v->since < cp->delay ? cp->delay - v->since : 0;
      const int held = v->state == LE_ANALOG_VOICE_HELD || v->state == LE_ANALOG_VOICE_SUSTAINED;
      av_env fe[2], ae[2];
      for (int32_t c = 0; c < 2; ++c) {
        fe[c] = read_env(d, c, LE_ANALOG_FILTER_ENV);
        ae[c] = read_env(d, c, LE_ANALOG_AMP_ENV);
      }
      for (int32_t s = s0; s < n; ++s) {
        float pre[2] = {0.0f, 0.0f};
        /* fit: a fresh copy's amps rise from 0 over their first control
         * period, rate / 441 samples (the attack renders: the gain is the
         * envelope times that ramp) */
        const int32_t age = v->since + s - cp->delay;
        const float ramp = age >= ramp_len ? 1.0f : (float)age / (float)ramp_len;
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &cp->ch[c];
          (void)env_tick(&ch->fenv, &fe[c], held, v->velocity, rate);
          (void)env_tick(&ch->aenv, &ae[c], held, v->velocity, rate);
          if (ci(d, c, LE_ANALOG_OSC_ON)) {
            const float o = osc_tick(d, ch, ci(d, c, LE_ANALOG_OSC_SHAPE), &cp->ch[c].t, &cp->rng);
            pre[0] += cp->ch[c].t.to_f1 * o;
            pre[1] += cp->ch[c].t.to_f2 * o;
          }
        }
        if (noise_on) {
          cp->noise_lp += noise_a * (0.9f * xs_bipolar(&cp->rng) - cp->noise_lp);
          pre[0] += noise_lvl * sinf(0.5f * AV_PI * noise_bal) * cp->noise_lp;
          pre[1] += noise_lvl * cosf(0.5f * AV_PI * noise_bal) * cp->noise_lp;
        }
        float l = 0.0f, r = 0.0f, y1 = 0.0f;
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &cp->ch[c];
          float x = pre[c] + (c == 1 ? cp->ch[0].t.link * y1 : 0.0f);
          if (ci(d, c, LE_ANALOG_FILTER_ON)) {
            const int32_t ft = ci(d, c, LE_ANALOG_FILTER_TYPE);
            if (ft >= 8) {
              x = ch->level[0] * core(ch->s[0], x, ch->g[0], ch->k, 1) +
                  ch->level[1] * core(ch->s[1], x, ch->g[1], ch->k, 1) +
                  ch->level[2] * core(ch->s[2], x, ch->g[2], ch->k, 1);
            } else {
              x = core(ch->s[0], x, ch->g[0], ch->k, ft / 2);
              if (ft % 2 == 1) x = core(ch->s[1], x, ch->g[0], ch->k, ft / 2);
            }
            x = drive(x, ci(d, c, LE_ANALOG_FILTER_DRIVE));
          }
          if (c == 0) y1 = x;
          ch->gl += ch->gl_step;
          ch->gr += ch->gr_step;
          x *= ch->aenv.y * ramp;
          l += ch->gl * x;
          r += ch->gr * x;
        }
        float g = out_gain;
        if (v->state == LE_ANALOG_VOICE_FADING) g *= fade_step * (float)(v->fade_left > s ? v->fade_left - s : 0);
        left[i + s] += g * l;
        right[i + s] += g * r;
      }
      for (int32_t c = 0; c < 2; ++c) {
        const le_analog_chain* ch = &cp->ch[c];
        if (ch->aenv.seg != SEG_IDLE && ci(d, c, LE_ANALOG_AMP_ON)) idle = 0;
      }
    }
    v->tick_left -= n;
    if (v->state == LE_ANALOG_VOICE_FADING) {
      v->fade_left -= n;
      if (v->fade_left <= 0) v->state = LE_ANALOG_VOICE_FREE;
    } else if (idle && v->tick_left == 0 && v->state != LE_ANALOG_VOICE_HELD) {
      /* on a tick's edge, so in any block size */
      v->state = LE_ANALOG_VOICE_FREE;
    }
    if (v->since < (1 << 30)) v->since += n; /* only the copies' delays read it */
    i += n;
  }
}

void le_analog_render(le_analog* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  memset(right, 0, sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (v->state != LE_ANALOG_VOICE_FREE) render_voice(d, v, left, right, frames);
  }
}
