/*
 * electric_voice.c — the Electric device (electric_voice.h).
 */
#include "electric_voice.h"

#include <math.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define EV_PI 3.14159265358979f
#define EV_LN2 0.69314718f

enum {
  LE_ELECTRIC_VOICE_FREE = 0,
  LE_ELECTRIC_VOICE_HELD,
  LE_ELECTRIC_VOICE_RELEASED,
  LE_ELECTRIC_VOICE_SUSTAINED,
  LE_ELECTRIC_VOICE_FADING
};

/* ---- parameters ---- */

typedef struct ev_param_def {
  float def, lo, hi;
  int integer;
} ev_param_def;

static ev_param_def param_def(int32_t p) {
  switch (p) {
    case LE_ELECTRIC_VOICES: return (ev_param_def){30.0f, 0.0f, 30.0f, 1};
    case LE_ELECTRIC_BEND_RANGE: return (ev_param_def){1.0f / 6.0f, 0.0f, 1.0f, 0};
    case LE_ELECTRIC_NOTE_BEND_RANGE: return (ev_param_def){48.0f, 0.0f, 48.0f, 0};
    case LE_ELECTRIC_VOLUME: return (ev_param_def){0.7048f, 0.0f, 1.0f, 0};
    case LE_ELECTRIC_SEMITONE: return (ev_param_def){12.0f, 0.0f, 24.0f, 1};
    case LE_ELECTRIC_PICKUP_MODEL: return (ev_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_ELECTRIC_DAMPER_BALANCE: return (ev_param_def){0.5f, 0.0f, 1.0f, 0};
    default: return (ev_param_def){0.5f, 0.0f, 1.0f, 0};
  }
}

float le_electric_default(int32_t param) {
  if (param < 0 || param >= LE_ELECTRIC_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_electric_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_ELECTRIC_PARAMS) return 0.0f;
  const ev_param_def p = param_def(param);
  if (value != value) return p.def;
  if (p.integer) value = roundf(value);
  return value < p.lo ? p.lo : value > p.hi ? p.hi : value;
}

static float vf(const le_electric* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_electric* d, int32_t p) { return (int32_t)d->values[p]; }

/* A knob position 0..1 on the engine's 0..127 scale (0.5 is exactly 64). */
static float pos(float v) {
  v = v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v;
  return v <= 0.5f ? 128.0f * v : 126.0f * v + 1.0f;
}

static float c_lin(float lo, float hi, float v) { return lo + (hi - lo) * pos(v) / 127.0f; }
/* The same line, but exactly its midpoint at 64 (the controls whose
 * centre is a neutral setting). */
static float c_mid(float lo, float hi, float v) {
  return pos(v) == 64.0f ? 0.5f * (lo + hi) : c_lin(lo, hi, v);
}
static float c_exp(float lo, float hi, float v) { return lo * powf(hi / lo, pos(v) / 127.0f); }
static float db_curve(float k, float o, float v) { return powf(10.0f, k * pos(v) + o); }

/* the curves of the Stiffness amounts: 0 at 0, 1 at 64, 4.9 at 127 */
static float stiff_amount(float v) { return (powf(4.0f, pos(v) / 64.0f) - 1.0f) / 3.0f; }
/* the key exponents of the tines and the mallet noise: 1 at 64 */
static float key_exp(float v) { return pos(v) / 32.0f - 1.0f; }

/* ---- the voices ---- */

static int sounding(const le_electric_voice* v) {
  return v->state == LE_ELECTRIC_VOICE_HELD || v->state == LE_ELECTRIC_VOICE_RELEASED ||
         v->state == LE_ELECTRIC_VOICE_SUSTAINED;
}

static void fade_voice(le_electric* d, le_electric_voice* v) {
  if (v->state == LE_ELECTRIC_VOICE_FREE) return;
  if (!v->struck) {
    v->state = LE_ELECTRIC_VOICE_FREE; /* silent so far: nothing to fade */
    return;
  }
  v->state = LE_ELECTRIC_VOICE_FADING;
  if (v->fade <= 0.0f) v->fade = 1.0f;
  v->fade_step = 1.0f / (0.001f * (float)d->sample_rate);
}

static int32_t voice_count(const le_electric* d) {
  int32_t n = vi(d, LE_ELECTRIC_VOICES) + 2;
  if (n > d->voice_limit) n = d->voice_limit;
  return n < 1 ? 1 : n;
}

static int32_t note_count(const le_electric* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

static le_electric_voice* oldest(le_electric* d, int32_t state) {
  le_electric_voice* old = NULL;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    le_electric_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

static le_electric_voice* free_slot(le_electric* d) {
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_ELECTRIC_VOICE_FREE) return &d->voices[i];
  }
  le_electric_voice* v = oldest(d, LE_ELECTRIC_VOICE_FADING);
  return v != NULL ? v : oldest(d, LE_ELECTRIC_VOICE_RELEASED);
}

/* The key in octaves from C4, tuned, without bend. */
static float key_cv(const le_electric* d, int32_t note) {
  const float tune = ((float)vi(d, LE_ELECTRIC_SEMITONE) + vf(d, LE_ELECTRIC_DETUNE)) / 12.0f - 1.0416667f;
  return (float)(note - 60) / 12.0f + tune;
}

/* The fork's pitch: the key with bend, shifted by Keyboard Stretch (whose
 * scaling about A4 reaches no input in Live, so only its offset is left). */
static float fork_pitch(const le_electric* d, float key) {
  const float s = c_mid(0.992f, 1.008f, vf(d, LE_ELECTRIC_STRETCH));
  return key + vf(d, LE_ELECTRIC_BEND_RANGE) * d->bend + 0.75f * (1.0f - s);
}

int32_t le_electric_init(le_electric* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->block = (int32_t)lroundf(0.001f * (float)sample_rate);
  if (d->block < 1) d->block = 1;
  d->voice_limit = LE_ELECTRIC_VOICE_SLOTS;
  for (int32_t p = 0; p < LE_ELECTRIC_PARAMS; ++p) d->values[p] = le_electric_default(p);
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    d->voices[i].rng = 0x9e3779b9u ^ (uint32_t)((i + 1) * 2654435761u);
  }
  d->gain = -1.0f;
  return 0;
}

void le_electric_set_values(le_electric* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_ELECTRIC_PARAMS; ++p) d->values[p] = le_electric_clamp(p, values[p]);
}

void le_electric_set_tempo(le_electric* d, float bpm) { (void)d, (void)bpm; }

static void release_voice(le_electric_voice* v) {
  v->state = LE_ELECTRIC_VOICE_RELEASED;
  v->gate = 0;
  v->damp = 2;
  v->quiet = 0;
}

static void let_go(le_electric* d, le_electric_voice* v) {
  if (d->sustain_n > 0) v->state = LE_ELECTRIC_VOICE_SUSTAINED;
  else release_voice(v);
}

int32_t le_electric_note_on(le_electric* d, uint32_t origin, int32_t note, int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  if (!chord) {
    for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
      le_electric_voice* v = &d->voices[i];
      if (v->state == LE_ELECTRIC_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
  }
  /* the same key again restarts its own voice, after a 1 ms fade */
  le_electric_voice* v = NULL;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS && v == NULL; ++i) {
    if (sounding(&d->voices[i]) && d->voices[i].note == note) v = &d->voices[i];
  }
  if (v == NULL) {
    const int32_t count = voice_count(d);
    while (note_count(d) >= count) {
      le_electric_voice* o = oldest(d, LE_ELECTRIC_VOICE_RELEASED);
      if (o == NULL) o = oldest(d, LE_ELECTRIC_VOICE_SUSTAINED);
      if (o == NULL) o = oldest(d, LE_ELECTRIC_VOICE_HELD);
      if (o == NULL) break;
      fade_voice(d, o);
      d->stolen++;
    }
    v = free_slot(d);
    if (v == NULL) return 0;
    if (v->state == LE_ELECTRIC_VOICE_FREE) {
      memset(v->m, 0, sizeof(v->m));
      memset(v->r, 0, sizeof(v->r));
      v->fade = 0.0f;
      v->struck = 0;
    }
  }
  /* a voice still sounding fades out over the next block, then strikes (one
   * already fading goes on from where it is) */
  if (v->state != LE_ELECTRIC_VOICE_FREE && v->struck) {
    if (v->fade <= 0.0f || v->state != LE_ELECTRIC_VOICE_FADING) v->fade = 1.0f;
    v->fade_step = 1.0f / (float)d->block;
  } else {
    v->fade = 0.0f;
  }
  v->state = LE_ELECTRIC_VOICE_HELD;
  v->note = note;
  v->origin = origin;
  v->serial = ++d->serial;
  v->velocity = (float)(velocity - 1) / 126.0f;
  v->wait = 2;
  v->gate = 1;
  v->quiet = 0;
  return 0;
}

void le_electric_note_off(le_electric* d, uint32_t origin) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    le_electric_voice* v = &d->voices[i];
    if (v->state == LE_ELECTRIC_VOICE_HELD && v->origin == origin) let_go(d, v);
  }
}

static void release_sustained(le_electric* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_ELECTRIC_VOICE_SUSTAINED) release_voice(&d->voices[i]);
  }
}

int32_t le_electric_sustain(le_electric* d, uint32_t origin, int on) {
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
  if (d->sustain_n >= LE_ELECTRIC_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_electric_expression(le_electric* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = value < lo ? lo : value > 1.0f ? 1.0f : value;
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_electric_release_matching(le_electric* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    le_electric_voice* v = &d->voices[i];
    if (v->state == LE_ELECTRIC_VOICE_HELD && (v->origin & mask) == value) {
      let_go(d, v);
    } else if (v->state == LE_ELECTRIC_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(v);
    }
  }
}

int32_t le_electric_held(const le_electric* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    const le_electric_voice* v = &d->voices[i];
    if (v->state == LE_ELECTRIC_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_electric_cut(le_electric* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) fade_voice(d, &d->voices[i]);
  d->sustain_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_electric_fade_oldest(le_electric* d) {
  if (d == NULL) return 0;
  le_electric_voice* old = NULL;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    le_electric_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  fade_voice(d, old);
  d->stolen++;
  return 1;
}

int32_t le_electric_active(const le_electric* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

int32_t le_electric_fading(const le_electric* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_ELECTRIC_VOICE_SLOTS; ++i) {
    n += d->voices[i].state == LE_ELECTRIC_VOICE_FADING;
  }
  return n;
}

void le_electric_set_voice_limit(le_electric* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_ELECTRIC_VOICE_SLOTS ? LE_ELECTRIC_VOICE_SLOTS : limit;
  while (le_electric_active(d) > d->voice_limit) {
    if (!le_electric_fade_oldest(d)) break;
  }
}

/* ---- the strike and the blocks ---- */

static float uniform(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return (float)(x >> 8) * (1.0f / 16777216.0f);
}

/* The mallet's pulse: four one-pole stages, the first two at the
 * stiffness cutoff (moved by key and, downward, by velocity), the last two
 * 27 times higher, all of the strike's energy put in at once. */
static void strike(const le_electric* d, le_electric_voice* v, float key, float pitch) {
  const float rate = (float)d->sample_rate;
  const float stiff = 10.0f * exp2f(0.0753426f * pos(vf(d, LE_ELECTRIC_MALLET_STIFFNESS)));
  const float fc = stiff * exp2f(stiff_amount(vf(d, LE_ELECTRIC_STIFFNESS_KEY)) * key -
                                 stiff_amount(vf(d, LE_ELECTRIC_STIFFNESS_VEL)) * v->velocity);
  const float g = fminf(2.0f * EV_PI * fc / rate, 100.0f);
  v->mp1 = 1.0f / (1.0f + g);
  v->ma = sqrtf(g) / (1.0f + g);
  v->mp2 = 1.0f / (1.0f + 27.0f * g);
  v->mb = 27.0f * g / (1.0f + 27.0f * g);
  const float force = pos(vf(d, LE_ELECTRIC_MALLET_FORCE)) / 128.0f + 1.0f / 64.0f;
  /* the force exponent's multiplier, 2, is the patch's fixed value */
  const float f_exp = 2.0f * (c_lin(-0.5f, 0.9f, vf(d, LE_ELECTRIC_FORCE_KEY)) * pitch +
                              c_lin(0.0f, 3.5f, vf(d, LE_ELECTRIC_FORCE_VEL)) * v->velocity);
  v->m[0] = force * v->ma * exp2f(f_exp);
  v->m[1] = v->ma * v->m[0];
  v->m[2] = v->mb * v->m[1];
  v->m[3] = v->mb * v->m[2];
  /* the fork and the pickup start from rest */
  memset(v->r, 0, sizeof(v->r));
  v->x1 = v->x2 = 0.0f;
  v->pv = v->pu1 = v->pw1 = 0.0f;
  /* the pickup's settings, latched */
  v->pk_model = vi(d, LE_ELECTRIC_PICKUP_MODEL);
  const float out = pos(vf(d, LE_ELECTRIC_PICKUP_OUT)) == 0.0f
                        ? 0.0f
                        : db_curve(0.01171875f, -0.3f, vf(d, LE_ELECTRIC_PICKUP_OUT));
  v->pk_gain = out * exp2f(c_mid(-1.5f, 1.5f, vf(d, LE_ELECTRIC_PICKUP_KEY)) * key);
  v->pk_in = db_curve(0.009375f, -1.5f, vf(d, LE_ELECTRIC_PICKUP_IN));
  v->pk_a = pos(vf(d, LE_ELECTRIC_PICKUP_SYMMETRY)) == 0.0f ? 0.0f
                                                            : c_exp(0.02f, 2.0f, vf(d, LE_ELECTRIC_PICKUP_SYMMETRY));
  v->pk_b = c_exp(0.1f, 1.8f, vf(d, LE_ELECTRIC_PICKUP_DISTANCE));
}

/* A damper burst: a two-stage envelope at the damper tone (following the
 * key), its share of the amount set by Balance. */
static void damper(const le_electric* d, le_electric_voice* v, float key, int off) {
  const float rate = (float)d->sample_rate;
  const float fd = c_exp(4.0f, 3490.0f, vf(d, LE_ELECTRIC_DAMPER_TONE)) * exp2f(key);
  const float g = fminf(2.0f * EV_PI * fd / rate, 100.0f);
  v->dp = 1.0f / (1.0f + g);
  v->da = sqrtf(g) / (1.0f + g);
  v->np = 1.0f / (1.0f + 19.0f * g);
  v->nb = 19.0f * g / (1.0f + 19.0f * g);
  const float bal = c_mid(0.0f, 1.0f, vf(d, LE_ELECTRIC_DAMPER_BALANCE));
  const float share = off ? bal : 1.0f - bal;
  v->e[0] += v->da * share * db_curve(0.0140625f, -1.5f, vf(d, LE_ELECTRIC_DAMPER_AMOUNT));
}

/* One resonator: a constant-Q band-pass at hz decaying at `nepers` per
 * second with level `level`; off near Nyquist (above `limit` x pi). */
static void resonator(le_electric_res* r, float hz, float nepers, float level, float limit, int raise,
                      float rate) {
  float w = 2.0f * EV_PI * hz / rate;
  const float dl = nepers / rate;
  if (raise) w = sqrtf(w * w + dl * dl); /* the damped ring stays at pitch */
  if (w > limit * EV_PI || w <= 0.0f) {
    r->b = r->c1 = r->c2 = 0.0f;
    return;
  }
  const float sw = sinf(w) / w;
  const float alpha = sw * dl;
  const float a0 = 1.0f + alpha;
  r->c1 = 2.0f * cosf(w) / a0;
  r->c2 = (1.0f - alpha) / a0;
  r->b = level * 7342.65f * sw / (rate * a0);
}

static const float kTineHz = 1922.7f;

/* The fork's four resonators at the voice's pitch, held or released. */
static void fork_tune(const le_electric* d, le_electric_voice* v, float p) {
  const float rate = (float)d->sample_rate;
  const float up = exp2f(p);
  const int held = v->gate;
  const float release = 2.0f * powf(10.0f, 0.01171875f * pos(vf(d, LE_ELECTRIC_RELEASE)) - 1.0f);
  const float d_tone = 1024.0f * expf(-(pos(vf(d, LE_ELECTRIC_TONE_DECAY)) / 2.0f + 64.0f) / 14.0f);
  const float d_tine = 1024.0f * expf(-(pos(vf(d, LE_ELECTRIC_TINE_DECAY)) / 2.0f + 32.0f) / 14.0f);
  const float d_noise = 1024.0f * expf(-pos(vf(d, LE_ELECTRIC_NOISE_DECAY)) / 28.0f);
  const float a_tone = db_curve(0.0109375f, -1.1f, vf(d, LE_ELECTRIC_TONE_VOLUME));
  /* fit: Tine Color is the tines' key exponent and Tine < Key their
   * balance, as the presets store them (the tine renders) */
  const float a_tine = db_curve(0.021875f, -2.5f, vf(d, LE_ELECTRIC_TINE_VOLUME)) *
                       exp2f((key_exp(vf(d, LE_ELECTRIC_TINE_COLOR)) - 1.0f) * p);
  const float theta = 0.5f * EV_PI * c_mid(0.0f, 1.0f, vf(d, LE_ELECTRIC_TINE_KEY));
  const float a_noise = db_curve(0.021875f, -2.5f, vf(d, LE_ELECTRIC_NOISE_AMOUNT)) *
                        exp2f((key_exp(vf(d, LE_ELECTRIC_NOISE_KEY)) - 1.0f) * p);
  const float noise_hz = 367.31f * exp2f(c_mid(-4.5f, 5.5f, vf(d, LE_ELECTRIC_NOISE_PITCH)));
  resonator(&v->r[0], 261.62f * up, held ? EV_LN2 * d_tone * up : 52.80333f * up / release, a_tone, 0.9f, !held,
            rate);
  /* fit: the tine rings 7.349 times the note (1922.7 Hz at C4), its partial
   * 2.8169 times that (the tine renders) */
  resonator(&v->r[1], kTineHz * up, held ? EV_LN2 * d_tine * up : 38.33797f * up / release,
            a_tine * cosf(theta), 0.95f, !held, rate);
  resonator(&v->r[2], 2.8169f * kTineHz * up, held ? 0.7f * EV_LN2 * d_tine * up : 26.83658f * up / release,
            a_tine * sinf(theta), 0.95f, !held, rate);
  resonator(&v->r[3], noise_hz, EV_LN2 * d_noise, a_noise, 0.9f, 0, rate);
}

/* The electromagnetic pickup's flux profile and the electrostatic one's
 * (rational shapes of q / sqrt(1 + q^2) and q / (1 + q^2)^1.5). */
static float flux_r(float q) {
  const float q2 = q * q;
  return q * (0.0119986f * q2 + 0.8208554f) / (0.1894016f * q2 + 1.0f);
}
static float flux_w(float q) {
  const float q2 = q * q;
  return q * (0.032329477f * q2 + 1.0590756f) / (q2 * (0.31450027f * q2 + 1.8034482f) + 1.0f);
}

static void render_voice(le_electric* d, le_electric_voice* v, float* out, int32_t n) {
  const float rate = (float)d->sample_rate;
  /* the R pickup's leaky integrator, 0.95 / (s + 4398.2), bilinear */
  const float kk = 2.0f * rate, om = 4398.2f;
  const float vi_b = 0.95f / (kk + om), vi_a = (kk - om) / (kk + om);
  const float r_scale = rate / 4410.0f / 14000.0f, w_scale = rate / 7200.0f;
  const int32_t quiet_end = (int32_t)(0.01f * rate);
  for (int32_t s = 0; s < n; ++s) {
    float x = v->m[3];
    v->m[0] = v->mp1 * v->m[0] + 1e-22f;
    v->m[1] = v->ma * v->m[0] + v->mp1 * v->m[1];
    v->m[2] = v->mb * v->m[1] + v->mp2 * v->m[2];
    v->m[3] = v->mb * v->m[2] + v->mp2 * v->m[3];
    /* the damper's burst of noise */
    v->n[0] = v->nb * uniform(&v->rng) + v->np * v->n[0];
    v->n[1] = v->nb * v->n[0] + v->np * v->n[1];
    x += v->n[1] * v->e[1];
    v->e[0] *= v->dp;
    v->e[1] = v->da * v->e[0] + v->dp * v->e[1];
    /* the fork */
    const float dx = x - v->x2;
    v->x2 = v->x1;
    v->x1 = x;
    float f = 0.0f;
    for (int32_t k = 0; k < 4; ++k) {
      le_electric_res* r = &v->r[k];
      const float y = r->b * dx + r->c1 * r->y1 - r->c2 * r->y2;
      r->y2 = r->y1;
      r->y1 = y;
      f += y;
    }
    /* the pickup: the derivative of the motion through the flux profile */
    float y;
    if (v->pk_model == 0) {
      const float u = 5000.0f * v->pk_in * f;
      v->pv = vi_b * (u + v->pu1) + vi_a * v->pv;
      v->pu1 = u;
      const float w = u * flux_r((v->pv + v->pk_a) / v->pk_b);
      y = v->pk_gain * r_scale * (w - v->pw1);
      v->pw1 = w;
    } else {
      const float u = v->pk_in * f;
      y = v->pk_gain * w_scale * (u - v->pu1) * flux_w((u + v->pk_a) / v->pk_b);
      v->pu1 = u;
    }
    if (!v->struck) {
      y = 0.0f; /* not struck yet */
    } else if (v->fade > 0.0f) {
      y *= v->fade;
      v->fade = fmaxf(v->fade - v->fade_step, 0.0f);
    } else if (v->state == LE_ELECTRIC_VOICE_FADING || v->wait > 0) {
      y = 0.0f; /* faded out: silent until the strike or the end */
    }
    out[s] += y;
    /* fit: a released voice ends after 10 ms below -100 dBFS */
    if (v->state == LE_ELECTRIC_VOICE_RELEASED) {
      v->quiet = fabsf(y) < 1e-5f ? v->quiet + 1 : 0;
      if (v->quiet >= quiet_end) {
        v->state = LE_ELECTRIC_VOICE_FREE;
        return;
      }
    }
  }
}

/* The start of a 1 ms block: strikes, damper bursts, the fork's tuning. */
static void block_start(le_electric* d, le_electric_voice* v) {
  const float key = key_cv(d, v->note);
  const float pitch = fork_pitch(d, key);
  if (v->wait > 0 && --v->wait == 0) {
    strike(d, v, key, pitch);
    v->struck = 1;
    v->fade = 0.0f;
    damper(d, v, key, 0);
  }
  /* a release's burst, after the strike when both fall in this block */
  if (v->damp == 2 && v->wait == 0) {
    damper(d, v, key, 1);
    v->damp = 0;
  }
  if (v->wait == 0) fork_tune(d, v, pitch);
  if (v->state == LE_ELECTRIC_VOICE_FADING && v->fade <= 0.0f) v->state = LE_ELECTRIC_VOICE_FREE;
}

/* The output stage: linear up to 2.8, then bending smoothly (same value
 * and slope at the knee) toward a ceiling of 4, as Live's output stage
 * does at a quarter of this scale before its x4. */
static float out_clip(float x) {
  const float a = fabsf(x);
  if (a <= 2.8f) return x;
  const float u = 1.0f + (a - 2.8f) / 3.6f;
  return copysignf(4.0f - 1.2f / (u * u * u), x);
}

void le_electric_render(le_electric* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  const float vol = pos(vf(d, LE_ELECTRIC_VOLUME)) / 127.0f;
  /* the volume is 2u^2; fit: the voices' levels already carry Live's final
   * x4, so the output stage's ceiling sits at 4 */
  const float target = 2.0f * vol * vol;
  int32_t i = 0;
  while (i < frames) {
    if (d->block_left == 0) {
      for (int32_t k = 0; k < LE_ELECTRIC_VOICE_SLOTS; ++k) {
        if (d->voices[k].state != LE_ELECTRIC_VOICE_FREE) block_start(d, &d->voices[k]);
      }
      if (d->gain < 0.0f) d->gain = target;
      d->gain_step = (target - d->gain) / (float)d->block;
      d->block_left = d->block;
    }
    const int32_t n = d->block_left < frames - i ? d->block_left : frames - i;
    for (int32_t k = 0; k < LE_ELECTRIC_VOICE_SLOTS; ++k) {
      le_electric_voice* v = &d->voices[k];
      if (v->state != LE_ELECTRIC_VOICE_FREE) render_voice(d, v, left + i, n);
    }
    for (int32_t s = 0; s < n; ++s) {
      d->gain += d->gain_step;
      left[i + s] = out_clip(left[i + s] * d->gain);
    }
    d->block_left -= n;
    i += n;
  }
  memcpy(right, left, sizeof(float) * (size_t)frames);
}
