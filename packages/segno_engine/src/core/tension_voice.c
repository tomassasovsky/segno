/*
 * tension_voice.c — the Tension device (tension_voice.h).
 */
#include "tension_voice.h"

#include <math.h>
#include <string.h>

#include "aas_parts.h"
#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define TV_C4 261.62f /* Hz: the string's C4, the engine's own [code] (the references keep Live's pitch) */
#define TV_G 9.81f
#define TV_MASK (LE_TENSION_RAIL - 1)
#define TV_SMASK (LE_TENSION_SHIFT - 1)
/* the filter envelope's segments are straight lines (its Exp switch, which
 * nothing in Live reaches, stays off) */
#define TV_FENV_EXP 0.0f
#define TV_BOW_HOLD 48 /* samples the bow's speed keeps its last scaling for, at a strike */
#define TV_BRIDGE_READ 1.5f /* samples: rail B's read at the bridge sits this much past L + e */

enum {
  LE_TENSION_VOICE_FREE = 0,
  LE_TENSION_VOICE_HELD,
  LE_TENSION_VOICE_RELEASED,
  LE_TENSION_VOICE_SUSTAINED,
  LE_TENSION_VOICE_FADING
};

/* the exciters' engine types */
enum { EXC_OFF = 0, EXC_PLECTRUM = 1, EXC_HAMMER = 2, EXC_BOUNCE = 3, EXC_BOW = 4 };

/* ---- parameters ---- */

typedef struct tv_param_def {
  float def, lo, hi;
  int integer;
} tv_param_def;

static tv_param_def param_def(int32_t p) {
  switch (p) {
    case LE_TENSION_POLYPHONY: return (tv_param_def){5.0f, 0.0f, 9.0f, 1};
    case LE_TENSION_BEND_RANGE: return (tv_param_def){2.0f, 0.0f, 12.0f, 1};
    case LE_TENSION_OCTAVE: return (tv_param_def){0.0f, -3.0f, 3.0f, 1};
    case LE_TENSION_TRANSPOSE: return (tv_param_def){0.0f, -12.0f, 12.0f, 1};
    case LE_TENSION_PRIORITY: return (tv_param_def){2.0f, 0.0f, 2.0f, 1};
    case LE_TENSION_EXC_TYPE: return (tv_param_def){1.0f, 0.0f, 3.0f, 1};
    case LE_TENSION_LFO_WAVE: return (tv_param_def){0.0f, 0.0f, 4.0f, 1};
    case LE_TENSION_LFO_SYNC: return (tv_param_def){0.0f, 0.0f, 23.0f, 1};
    case LE_TENSION_FILTER_TYPE: return (tv_param_def){0.0f, 0.0f, 9.0f, 1};
    case LE_TENSION_BODY_TYPE: return (tv_param_def){0.0f, 0.0f, 3.0f, 1};
    case LE_TENSION_BODY_SIZE: return (tv_param_def){2.0f, 0.0f, 4.0f, 1};
    case LE_TENSION_NOTE_BEND_RANGE: return (tv_param_def){48.0f, 0.0f, 48.0f, 1};
    case LE_TENSION_PRESSURE_TARGET1:
    case LE_TENSION_PRESSURE_TARGET2:
    case LE_TENSION_SLIDE_TARGET1:
    case LE_TENSION_SLIDE_TARGET2:
      return (tv_param_def){0.0f, 0.0f, 11.0f, 1};
    /* switches */
    case LE_TENSION_EXC_ON:
    case LE_TENSION_DAMPER_GATED:
    case LE_TENSION_BODY_ON:
      return (tv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_TENSION_UNISON_ON:
    case LE_TENSION_UNISON:
    case LE_TENSION_VIBRATO_ON:
    case LE_TENSION_GLIDE_ON:
    case LE_TENSION_GLIDE_PROP:
    case LE_TENSION_GLIDE_LEGATO:
    case LE_TENSION_EXC_POS_ABS:
    case LE_TENSION_DAMPER_POS_ABS:
    case LE_TENSION_PICKUP_ON:
    case LE_TENSION_DAMPER_ON:
    case LE_TENSION_TERM_ON:
    case LE_TENSION_LFO_ON:
    case LE_TENSION_LFO_SYNC_ON:
    case LE_TENSION_FILTER_ON:
    case LE_TENSION_FENV_ON:
      return (tv_param_def){0.0f, 0.0f, 1.0f, 1};
    /* bipolar amounts */
    case LE_TENSION_EXC_POS_KEY:
    case LE_TENSION_EXC_POS_VEL:
    case LE_TENSION_DAMPER_POS_KEY:
    case LE_TENSION_DAMPER_POS_VEL:
    case LE_TENSION_EXC_X_KEY:
    case LE_TENSION_EXC_X_VEL:
    case LE_TENSION_EXC_STIFF_KEY:
    case LE_TENSION_EXC_STIFF_VEL:
    case LE_TENSION_EXC_VEL_KEY:
    case LE_TENSION_EXC_VEL_VEL:
    case LE_TENSION_DAMPER_MASS_KEY:
    case LE_TENSION_DAMPER_STIFF_KEY:
    case LE_TENSION_DAMPER_VEL_KEY:
    case LE_TENSION_STRING_DAMPING_KEY:
    case LE_TENSION_STRING_DECAY_KEY:
    case LE_TENSION_TERM_FINGER_FORCE_KEY:
    case LE_TENSION_TERM_FINGER_FORCE_VEL:
    case LE_TENSION_FILTER_KEY_CUTOFF:
    case LE_TENSION_FILTER_LFO_CUTOFF:
    case LE_TENSION_FILTER_ENV_CUTOFF:
    case LE_TENSION_FILTER_KEY_Q:
    case LE_TENSION_FILTER_LFO_Q:
    case LE_TENSION_FILTER_ENV_Q:
    case LE_TENSION_PRESSURE_AMOUNT1:
    case LE_TENSION_PRESSURE_AMOUNT2:
    case LE_TENSION_SLIDE_AMOUNT1:
    case LE_TENSION_SLIDE_AMOUNT2:
      return (tv_param_def){0.0f, -1.0f, 1.0f, 0};
    /* knobs whose centre is not the default */
    case LE_TENSION_UNISON_DETUNE:
    case LE_TENSION_UNISON_DELAY:
    case LE_TENSION_ERROR:
    case LE_TENSION_VIBRATO_AMOUNT:
    case LE_TENSION_VIBRATO_ERROR:
    case LE_TENSION_VIBRATO_DELAY:
    case LE_TENSION_VIBRATO_FADE:
    case LE_TENSION_LFO_DELAY:
    case LE_TENSION_LFO_FADE:
    case LE_TENSION_STRING_INHARM:
    case LE_TENSION_FENV_ATTACK:
    case LE_TENSION_FENV_ATTACK_VEL:
    case LE_TENSION_FENV_VEL:
      return (tv_param_def){0.0f, 0.0f, 1.0f, 0};
    case LE_TENSION_BODY_LEVEL: return (tv_param_def){0.7048f, 0.0f, 1.0f, 0};
    case LE_TENSION_STRETCH: return (tv_param_def){0.5f, 0.0f, 1.0f, 0}; /* no stretch */
    case LE_TENSION_FILTER_CUTOFF: return (tv_param_def){0.75f, 0.0f, 1.0f, 0};
    case LE_TENSION_FILTER_Q: return (tv_param_def){0.3f, 0.0f, 1.0f, 0};
    case LE_TENSION_FENV_SUSTAIN: return (tv_param_def){1.0f, 0.0f, 1.0f, 0};
    default: return (tv_param_def){0.5f, 0.0f, 1.0f, 0};
  }
}

float le_tension_default(int32_t param) {
  if (param < 0 || param >= LE_TENSION_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_tension_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_TENSION_PARAMS) return 0.0f;
  const tv_param_def p = param_def(param);
  if (value != value) return p.def;
  if (p.integer) value = roundf(value);
  return value < p.lo ? p.lo : value > p.hi ? p.hi : value;
}

static float vf(const le_tension* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_tension* d, int32_t p) { return (int32_t)d->values[p]; }

/* A knob's step on the engine's integer 0..127 scale, as its curves take
 * it: 128 v up to the middle (64), 126 v + 1 above, cut to the step below
 * in single precision (so a preset's 72nd step, stored as 71/126, lands
 * on 71: fit, term-soft and the plucked presets). */
static int32_t knob_m(float v) {
  v = le_aas_clamp(v, 0.0f, 1.0f);
  return (int32_t)(v <= 0.5f ? 128.0f * v : 126.0f * v + 1.0f);
}
/* The curves on that step: Exp(lo, hi); Lin exactly at its
 * middle at step 64; ExpZ exactly 0 at step 0. */
static float exp_m(float lo, float hi, int32_t m) { return lo * powf(hi / lo, (float)m / 127.0f); }
static float kexp(float lo, float hi, float v) { return exp_m(lo, hi, knob_m(v)); }
static float lin_int(float lo, float hi, float v) {
  const int32_t m = knob_m(v);
  return lo + (hi - lo) * (m == 64 ? 0.5f : (float)m / 127.0f);
}
static float expz(float lo, float hi, float v) { return knob_m(v) <= 0 ? 0.0f : kexp(lo, hi, v); }
/* The shared modules (vibrato, glide, the LFO) take the knob's position
 * itself, not its whole step (fit: the vibrato renders' rate and depth). */
static float mod_expz(float lo, float hi, float v) { return le_aas_knob(v) <= 0.0f ? 0.0f : le_aas_exp(lo, hi, v); }

/* A key or velocity amount: Exp(0.1, 16) of its magnitude, with its sign.
 * At its bottom step (m = 0) most amounts keep their resting 0.1, which a
 * knob at zero never moves; the four whose resting value is larger (Force
 * < Key, Stiffness and Velocity < Vel, Finger Force < Vel) go to exactly
 * 0. fit: the reference's decay and level at C2 and C6. */
static float amount(const le_tension* d, int32_t p) {
  const float v = vf(d, p);
  const int32_t m = knob_m(fabsf(v));
  if (m <= 0) {
    const int zero = p == LE_TENSION_EXC_X_KEY || p == LE_TENSION_EXC_STIFF_VEL || p == LE_TENSION_EXC_VEL_VEL ||
                     p == LE_TENSION_TERM_FINGER_FORCE_VEL;
    return zero ? 0.0f : 0.1f;
  }
  return (v < 0.0f ? -1.0f : 1.0f) * 0.1f * powf(160.0f, (float)(m > 127 ? 127 : m) / 127.0f);
}

/* The engine's 2^x: the whole octaves exactly, the fraction f by a cubic,
 * 1 + t + t^2 / 2 + 0.200064 t^3 with t = f ln 2 (exact at both ends of
 * the octave, 0.05 % high near 0.85 of it), for the string's pitch and
 * every key and velocity scaling. [code] (Sitar Far's parts at D2, which
 * it brings to Live's sample for sample) */
static float exp2_engine(float x) {
  const float i = floorf(x);
  const float t = (x - i) * 0.6931472f;
  return ldexpf(t + 1.0f + (t * 0.200064f + 0.5f) * t * t, (int)i);
}

/* 2^e for a key or velocity scaling, which a full amount takes 16 octaves
 * either way (held within 30, short of overflow). fit: the muted guitar preset's
 * and Wurli Mellow's phrase renders, whose velocity amounts reach 15 octaves. */
static float scale2(float e) { return exp2_engine(le_aas_clamp(e, -30.0f, 30.0f)); }

/* The unison amounts' curve: Exp(lo, hi) on m = 127 v, exactly 0 at 0. */
static float unison_expz(float lo, float hi, float v) {
  const float m = 127.0f * le_aas_clamp(v, 0.0f, 1.0f);
  return m <= 0.0f ? 0.0f : lo * powf(hi / lo, m / 127.0f);
}

/* ---- voices ---- */

static const int32_t kVoices[10] = {1, 2, 4, 8, 12, 16, 20, 24, 28, 32};

static int sounding(const le_tension_voice* v) {
  return v->state == LE_TENSION_VOICE_HELD || v->state == LE_TENSION_VOICE_RELEASED ||
         v->state == LE_TENSION_VOICE_SUSTAINED;
}

static void fade_voice(le_tension_voice* v) {
  if (v->state == LE_TENSION_VOICE_FREE) return;
  v->state = LE_TENSION_VOICE_FADING;
  if (v->fade_left <= 0) v->fade_left = v->fade_len;
}

static int mono(const le_tension* d) { return vi(d, LE_TENSION_POLYPHONY) == 0; }

static int32_t copies_per_note(const le_tension* d) {
  return vi(d, LE_TENSION_UNISON_ON) ? (vi(d, LE_TENSION_UNISON) ? 4 : 2) : 1;
}

/* The notes sounding: one per unison group, whichever of its strings are
 * left. */
static int32_t note_count(const le_tension* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    if (!sounding(&d->voices[i])) continue;
    int first = 1;
    for (int32_t j = 0; j < i && first; ++j) {
      first = !(sounding(&d->voices[j]) && d->voices[j].serial == d->voices[i].serial);
    }
    n += first;
  }
  return n;
}

static int32_t voice_count(const le_tension* d) {
  /* the voices count strings, so a unison note takes two or four of them
   * [measured] (round 5: two voices with unison play one note of a
   * chord, four play two) */
  int32_t n = kVoices[vi(d, LE_TENSION_POLYPHONY)] / copies_per_note(d);
  const int32_t lim = d->voice_limit / copies_per_note(d);
  if (n > lim) n = lim;
  return n < 1 ? 1 : n;
}

static le_tension_voice* oldest(le_tension* d, int32_t state) {
  le_tension_voice* old = NULL;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

/* Every voice of the note `v` is a string of (its unison group). */
static void fade_note(le_tension* d, const le_tension_voice* lead) {
  const uint64_t serial = lead->serial;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    if (d->voices[i].serial == serial && sounding(&d->voices[i])) fade_voice(&d->voices[i]);
  }
}

static int32_t free_count(const le_tension* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) n += d->voices[i].state == LE_TENSION_VOICE_FREE;
  return n;
}

static le_tension_voice* free_slot(le_tension* d) {
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_TENSION_VOICE_FREE) return &d->voices[i];
  }
  le_tension_voice* old = NULL;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (v->state == LE_TENSION_VOICE_FADING && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

/* The keyboard pitch of `note` in octaves from C4: the key stretched about
 * A4 (Stretch, 0.992 to 1.008 times), then the octave, transpose and fine
 * tune (half a semitone either way). The voice adds its Error offset. */
static float key_pitch(const le_tension* d, int32_t note) {
  const float fine = lin_int(-1.0f / 24.0f, 1.0f / 24.0f, vf(d, LE_TENSION_FINE_TUNE));
  const float stretch = lin_int(0.992f, 1.008f, vf(d, LE_TENSION_STRETCH));
  return 0.75f + stretch * ((float)(note - 60) / 12.0f - 0.75f) + (float)vi(d, LE_TENSION_TRANSPOSE) / 12.0f +
         (float)vi(d, LE_TENSION_OCTAVE) + fine;
}

static float bend_oct(const le_tension* d) { return vf(d, LE_TENSION_BEND_RANGE) / 12.0f * d->bend; }

static int32_t priority_index(const le_tension* d) {
  if (d->held_n == 0) return -1;
  const int32_t pr = vi(d, LE_TENSION_PRIORITY);
  int32_t best = d->held_n - 1;
  for (int32_t i = 0; i < d->held_n && pr != 2; ++i) {
    if (pr == 0 ? d->held_note[i] > d->held_note[best] : d->held_note[i] < d->held_note[best]) best = i;
  }
  return best;
}

static void held_push(le_tension* d, uint32_t origin, int32_t note) {
  if (d->held_n == LE_TENSION_HELD_MAX) {
    memmove(d->held_note, d->held_note + 1, sizeof(int32_t) * (LE_TENSION_HELD_MAX - 1));
    memmove(d->held_origin, d->held_origin + 1, sizeof(uint32_t) * (LE_TENSION_HELD_MAX - 1));
    d->held_n--;
  }
  d->held_note[d->held_n] = note;
  d->held_origin[d->held_n] = origin;
  d->held_n++;
}

static void held_drop(le_tension* d, uint32_t origin) {
  int32_t keep = 0;
  for (int32_t i = 0; i < d->held_n; ++i) {
    if (d->held_origin[i] == origin) continue;
    d->held_note[keep] = d->held_note[i];
    d->held_origin[keep] = d->held_origin[i];
    keep++;
  }
  d->held_n = keep;
}

/* ---- the string ---- */

/* The phase delay, in samples, of the all-pass (a + z^-1) / (1 + a z^-1)
 * at w radians a sample. */
static float ap_delay(float a, float w) {
  return -(atan2f(-sinf(w), a + cosf(w)) - atan2f(-a * sinf(w), 1.0f + a * cosf(w))) / w;
}

/* The loss per reflection for decay T at key pitch p. */
static float string_loss(const le_tension* d, float p, float ratio) {
  const float T = kexp(0.1f, 100.0f, vf(d, LE_TENSION_STRING_DECAY));
  const float fd = exp2_engine(p * (1.0f + amount(d, LE_TENSION_STRING_DECAY_KEY)));
  return powf(10.0f, -0.03f * ratio / (2.0f * T * fd));
}

/* A position along the string, Exp(0.05, 0.5) of its length. */
static float position(float v) { return kexp(0.05f, 0.5f, v); }

static int32_t clampi(int32_t x, int32_t lo, int32_t hi) { return x < lo ? lo : x > hi ? hi : x; }

/* A contact of the given frame side `side` (+1 below the string, -1 above):
 * the force this sample for the string arriving at velocity `u` with the
 * contact frame displacement `ys`, solving F = K max(delta, 0)^2 where
 * delta falls linearly with F (the body's, the felt's and the string's
 * give), in closed form. `moving`: the body moves under the force. */
static float contact_force(const le_tension_contact* c, double ys, float u, int moving, float rate) {
  const double sr = rate, c1 = 80.0 / (c->r * sr + 80.0), c2 = 1.0 / (c->r * sr + 80.0);
  const double yb = moving ? c->y + (c->v + c->grav / sr) / sr : c->y + c->v / sr;
  const double d0 = yb - c->z * (1.0 - c1) - ys - u / sr;
  if (d0 <= 0.0) return 0.0f;
  const double beta = (moving ? 1.0 / (c->m * sr * sr) : 0.0) + c2 + 0.5 / sr;
  const double kb = c->k * beta;
  const double s = 2.0 * kb * d0 + 1.0;
  /* F = K d0^2 * 2 / (s + sqrt(4 K beta d0 + 1)): the root that is small */
  return (float)(c->k * d0 * d0 * 2.0 / (s + sqrt(4.0 * kb * d0 + 1.0)));
}

/* Advances a contact by one sample under force f. */
static void contact_step(le_tension_contact* c, float f, int moving, float rate) {
  const double sr = rate, c1 = 80.0 / (c->r * sr + 80.0), c2 = 1.0 / (c->r * sr + 80.0);
  if (moving) c->v += (c->grav - f / c->m) / sr;
  c->y += c->v / sr;
  /* the felt's surface yields under the force but follows the body's own
   * push only through the felt, so the body's give this sample comes off
   * the compression. fit: the bouncing hammer's re-strikes (round 4) and
   * the lightest hammer's level */
  c->z = c->z * (1.0 - c1) + f * c2;
  if (moving) c->z -= f / (c->m * sr * sr);
  c->f = f;
}

/* The string at the strike: its length and filters at played pitch `p`
 * (key pitch `pk`), its contacts set. `fresh`: start from rest. */
static void string_strike(le_tension* d, le_tension_voice* v, float p, float pk, int fresh) {
  const float rate = (float)d->sample_rate;
  const float fkey = exp2_engine(pk);
  /* the damping low-pass, the dispersion all-pass */
  const float fc = kexp(200.0f, 200000.0f, vf(d, LE_TENSION_STRING_DAMPING)) *
                   scale2(amount(d, LE_TENSION_STRING_DAMPING_KEY) * pk);
  const float wl = 2.0f * LE_AAS_PI * fc / rate;
  v->lp_b = wl / (wl + 2.0f);
  v->lp_a = (wl - 2.0f) / (wl + 2.0f);
  const float inh = fmaxf(0.02f, lin_int(0.02f, 20.0f, vf(d, LE_TENSION_STRING_INHARM)));
  const float dd = fmaxf(1.0f, inh / fkey + 1.0f);
  v->ap_a = (1.0f - dd) / (1.0f + dd);
  /* the length: the loop's filters' phase delay at the key's fundamental
   * and the bridge read's own 2.5 samples taken off the period. The
   * damping's share is the engine's estimate, an analog one-pole's
   * atan(w / wc) / w, not its filter's exact delay [code] (the reference
   * at C6 keeps its pitch to 1 % for 2 s) */
  const float w0 = fminf(2.0f * LE_AAS_PI * TV_C4 * fkey / rate, 3.0f);
  v->c_tune = atanf(w0 / wl) / w0 + ap_delay(v->ap_a, w0) + TV_BRIDGE_READ;
  const float period = rate / (TV_C4 * exp2_engine(p));
  const float h = fmaxf(0.5f * (period - v->c_tune), 4.0f);
  const int32_t len = clampi((int32_t)floorf(h), 4, LE_TENSION_RAIL / 2 - 8);
  /* positions */
  const float vel = v->velocity;
  const float c4_len = 0.5f * (rate / TV_C4 - v->c_tune);
  const float pkey = fmaxf(p, pk);
  float pe = position(vf(d, LE_TENSION_EXC_POS)) *
             scale2(amount(d, LE_TENSION_EXC_POS_KEY) * pkey + amount(d, LE_TENSION_EXC_POS_VEL) * vel);
  float pd = position(vf(d, LE_TENSION_DAMPER_POS)) *
             scale2((amount(d, LE_TENSION_DAMPER_POS_KEY) + amount(d, LE_TENSION_DAMPER_POS_VEL)) * pkey);
  /* each a fraction of the half period (not its whole samples), within the
   * string's first half */
  const float base_e = vi(d, LE_TENSION_EXC_POS_ABS) ? c4_len : h;
  const float base_d = vi(d, LE_TENSION_DAMPER_POS_ABS) ? c4_len : h;
  int32_t exc_tap = (int32_t)fminf(pe * base_e, (float)len);
  if (exc_tap >= len / 2) exc_tap = len / 2 - 1;
  if (exc_tap < 2) exc_tap = 1;
  int32_t damp_tap = (int32_t)fminf(pd * base_d, (float)len);
  if (damp_tap > len / 2) damp_tap = len / 2;
  if (damp_tap < 2) damp_tap = 1;
  int32_t pick_tap = (int32_t)(position(vf(d, LE_TENSION_PICKUP_POS)) * h);
  if (pick_tap == damp_tap) pick_tap += pick_tap + 1 != len / 2 ? 1 : -1; /* never on the damper */
  if (pick_tap > len / 2) pick_tap = len / 2;
  if (pick_tap < 2) pick_tap = 1;
  const int reinit = fresh || len != v->len || damp_tap != v->damp_tap;
  if (reinit) {
    memset(v->a, 0, sizeof(v->a));
    memset(v->b, 0, sizeof(v->b));
    v->lp_x = v->lp_y = v->ap_x = v->ap_y = v->hp_x = v->hp_y = 0.0f;
    v->ys_exc = v->ys_damp = 0.0f;
    memset(v->sh, 0, sizeof(v->sh));
  }
  v->len = len;
  v->exc_tap = exc_tap;
  v->damp_tap = damp_tap;
  v->pick_tap = pick_tap;
  v->e = v->e_to = le_aas_clamp(2.0f * (h - (float)len), -(float)exc_tap, (float)(LE_TENSION_RAIL - 8 - len));
  v->e_step = 0.0f;
  v->p0 = pk; /* the pitch handler's: the key's, before glide and vibrato */
  /* the loss ramps in over 1 ms */
  v->g_to = string_loss(d, pk, 1.0f);
  v->g_step = (v->g_to - v->g) / (0.001f * rate);
  if (fresh) v->g = v->g_to, v->g_step = 0.0f;
  /* the exciter, scaled by key and velocity */
  const float X = scale2(amount(d, LE_TENSION_EXC_X_KEY) * p + amount(d, LE_TENSION_EXC_X_VEL) * vel);
  const float S =
      scale2(amount(d, LE_TENSION_EXC_STIFF_KEY) * p + amount(d, LE_TENSION_EXC_STIFF_VEL) * vel);
  const float V = scale2(amount(d, LE_TENSION_EXC_VEL_KEY) * p + amount(d, LE_TENSION_EXC_VEL_VEL) * vel);
  static const int32_t kType[4] = {EXC_BOW, EXC_HAMMER, EXC_BOUNCE, EXC_PLECTRUM};
  v->exc_type = vi(d, LE_TENSION_EXC_ON) ? kType[vi(d, LE_TENSION_EXC_TYPE)] : EXC_OFF;
  le_tension_contact* c = &v->exc;
  memset(c, 0, sizeof(*c));
  const float xk = vf(d, LE_TENSION_EXC_X), sk = vf(d, LE_TENSION_EXC_STIFF), vk = vf(d, LE_TENSION_EXC_VEL);
  const float damping = vf(d, LE_TENSION_EXC_DAMPING);
  switch (v->exc_type) {
    case EXC_HAMMER:
    case EXC_BOUNCE:
      c->on = 1;
      /* not held to any range: the muted guitar preset's velocity amounts take
       * its hammer far past the knobs' ends [code] */
      c->m = X * kexp(1e-5f, 0.01f, xk);
      c->k = S * kexp(1e3f, 1e11f, sk);
      c->v = V * kexp(0.01f, 100.0f, vk);
      c->r = kexp(0.01f, 1000.0f, damping);
      c->grav = v->exc_type == EXC_BOUNCE ? TV_G : -TV_G;
      c->y0 = v->ys_exc;
      c->y = v->ys_exc - 1e-4f;
      break;
    case EXC_PLECTRUM:
      c->on = 1;
      c->reach = fminf(X * kexp(1e-4f, 0.01f, xk), 0.01f);
      c->k = S * kexp(1e3f, 1e11f, sk);
      c->v = V * kexp(0.01f, 5.0f, vk);
      c->r = kexp(0.001f, 1000.0f, damping);
      c->y0 = v->ys_exc;
      c->y = v->ys_exc - 1e-4f; /* just behind the string, as it stands */
      break;
    case EXC_BOW:
      v->bow_f = X * kexp(0.01f, 5.0f, xk);
      v->bow_vc = S * kexp(0.001f, 0.1f, sk);
      /* the bow's speed takes the strike's key and velocity scaling only
       * from the engine's next block: until then it keeps the one it took
       * last (none on a string never bowed). [code] Live's block falls
       * anywhere against a note; Segno holds the old speed a fixed 48
       * samples, so its output keeps to any block size [Segno]
       * [measured] (a note at the start of a Live render: the C2 bow
       * renders' first 100 samples then match Live's to -57 dB) */
      v->bow_vb_late = V * kexp(0.001f, 10.0f, vk);
      v->bow_vb = (v->bow_vscale > 0.0f ? v->bow_vscale : 1.0f) * kexp(0.001f, 10.0f, vk);
      v->bow_vscale = V;
      v->bow_hold = TV_BOW_HOLD;
      break;
    default:
      break;
  }
  /* the damper: on the string, or thrown off while the key is held */
  le_tension_contact* dm = &v->damper;
  const int damper_was = dm->on;
  if (!vi(d, LE_TENSION_DAMPER_ON)) memset(dm, 0, sizeof(*dm));
  if (vi(d, LE_TENSION_DAMPER_ON)) {
    const float kk = scale2(amount(d, LE_TENSION_DAMPER_MASS_KEY) * pk);
    dm->on = 1;
    /* none of the damper's or plectrum's values is held to a range either
     * [code] (Nice Harp) */
    dm->m = kexp(1e-4f, 0.5f, vf(d, LE_TENSION_DAMPER_MASS)) * kk;
    dm->k = kexp(1e4f, 1e12f, vf(d, LE_TENSION_DAMPER_STIFF)) * scale2(amount(d, LE_TENSION_DAMPER_STIFF_KEY) * pk);
    dm->r = kexp(0.01f, 1000.0f, vf(d, LE_TENSION_DAMPER_DAMPING));
    const float vd =
        kexp(0.01f, 100.0f, vf(d, LE_TENSION_DAMPER_VEL)) * scale2(amount(d, LE_TENSION_DAMPER_VEL_KEY) * p);
    /* a string started again has the damper resting on it, its weight
     * against the felt and the contact; a gated damper is thrown off from
     * where it is, so it pushes the string while it parts from it */
    if (reinit || !damper_was) {
      const float w = dm->m * TV_G;
      dm->z = w / 80.0f;
      dm->y = v->ys_damp + sqrtf(w / dm->k) + dm->z;
      dm->v = 0.0f;
    }
    if (vi(d, LE_TENSION_DAMPER_GATED)) {
      dm->v = -vd;
      dm->grav = -TV_G;
    } else {
      dm->grav = TV_G;
    }
    dm->reach = vd; /* the damper's speed, kept for the release */
  }
  /* a string started again with the damper on starts bent under its
   * weight: the constant waves that the weight's push (half of m g into
   * each rail, toward the damper's side) and the two lossy reflections
   * hold, a / (1 + g) on the damper's far side of each rail and -a g /
   * (1 + g) on its near side, the damper's own tap on each rail still
   * holding the wave before its push [measured] (Soft Buzz Bass's B3,
   * 0.04 dB rms, and Clav Celesta's first sample: with rail B's tap
   * holding the wave after it, the string started with a jolt) */
  float rest_wave = 0.0f;
  if (reinit && dm->on) {
    const float g = fminf(v->g_to, 0.99999f);
    const float a = 0.5f * dm->m * TV_G;
    const float far = a / (1.0f + g), near = -a * g / (1.0f + g);
    rest_wave = far;
    const int32_t tail = len + (int32_t)v->e + 5;
    for (int32_t k = 0; k <= len; ++k) v->a[(v->w - k) & TV_MASK] = k > len - damp_tap ? far : near;
    for (int32_t k = 0; k <= tail; ++k) v->b[(v->w - k) & TV_MASK] = k > damp_tap ? far : near;
    /* the bridge's filters and the output's high-pass already settled on
     * it, so the bent string makes no step */
    v->ap_x = v->ap_y = v->lp_x = v->lp_y = far;
    v->hp_x = vi(d, LE_TENSION_PICKUP_ON) ? v->a[(v->w - (len - pick_tap)) & TV_MASK] + v->b[(v->w - pick_tap) & TV_MASK]
                                          : far;
    v->hp_y = 0.0f;
  }
  /* the finger on the fret */
  v->term = vi(d, LE_TENSION_TERM_ON);
  if (v->term) {
    v->tf_m = fminf(kexp(0.01f, 100.0f, vf(d, LE_TENSION_TERM_FINGER_FORCE)) *
                        exp2_engine(amount(d, LE_TENSION_TERM_FINGER_FORCE_KEY) * p +
                              amount(d, LE_TENSION_TERM_FINGER_FORCE_VEL) * vel),
                    100.0f);
    v->tf_k = kexp(1e3f, 1e12f, vf(d, LE_TENSION_TERM_FINGER_STIFF)) * fkey;
    v->ta_k = kexp(1e3f, 1e12f, vf(d, LE_TENSION_TERM_FRET_STIFF)) * fkey;
    /* a string started again rests on the fret under the finger's weight
     * and the bent string's own push at the nut */
    if (reinit || !v->term_was) {
      const float w = v->tf_m * TV_G, wa = fmaxf(w + 2.0f * rest_wave, 0.0f);
      v->te_y = -sqrt((double)wa / v->ta_k);
      v->tf_y = v->te_y - sqrt((double)w / v->tf_k);
      v->tf_v = 0.0;
      v->t_ff = w;
      v->t_fa = wa;
    }
  }
  v->term_was = v->term;
}

/* The nut end with a finger pressing the string onto a fret: the two
 * contacts' compressions solved together by Newton, the end free. Returns
 * the wave leaving the nut: the arriving wave and the contacts' push, the
 * loss taken on the sum. */
static float finger_fret(le_tension_voice* v, float in_wave, float rate) {
  /* in double, as the engine's: the two forces are large (a heavy finger
   * on a stiff fret) and the wave is their small difference, which single
   * precision leaves 80 dB down in noise. [code] (Kalimba Big's highs) */
  const double dt = 1.0 / (double)rate;
  /* the fret lies on the side the exciters push toward: solved below in
   * a frame with the fret underneath, so the waves change sign there.
   * [code] fit: Sitar Far, Banjo and the upright and fretless basses */
  const double in = -(double)in_wave;
  const double kf = v->tf_k, ka = v->ta_k, g = TV_G;
  const double ye0 = v->te_y + 2.0 * in * dt;
  const double yf0 = v->tf_y + (v->tf_v - g * dt) * dt;
  const double bf = dt + dt * dt / v->tf_m;
  double df = sqrt(v->t_ff / kf), da = sqrt(v->t_fa / ka);
  for (int32_t it = 0; it < 24; ++it) {
    const double dfp = fmax(df, 0.0), dap = fmax(da, 0.0);
    const double ff = kf * dfp * dfp, fa = ka * dap * dap;
    const double g1 = df - (ye0 - yf0 + fa * dt - ff * bf);
    const double g2 = da - (-ye0 - fa * dt + ff * dt);
    const double j11 = 1.0 + 2.0 * kf * bf * dfp, j12 = -2.0 * ka * dt * dap;
    const double j21 = -2.0 * kf * dt * dfp, j22 = 1.0 + 2.0 * ka * dt * dap;
    const double det = j11 * j22 - j12 * j21;
    if (!(fabs(det) > 1e-30)) break;
    const double sf = (g1 * j22 - g2 * j12) / det, sa = (g2 * j11 - g1 * j21) / det;
    df -= sf;
    da -= sa;
    if (fabs(sf) < 1e-13 && fabs(sa) < 1e-13) break;
  }
  if (!(df == df) || !(da == da)) df = da = 0.0;
  const double dfp = fmax(df, 0.0), dap = fmax(da, 0.0);
  v->t_ff = kf * dfp * dfp;
  v->t_fa = ka * dap * dap;
  const double out = in + (v->t_fa - v->t_ff);
  v->te_y += (in + out) * dt;
  v->tf_v += (v->t_ff / v->tf_m - g) * dt;
  v->tf_y += v->tf_v * dt;
  return (float)(-(double)v->g * out);
}

/* The bow at junction velocity u (the incoming waves' sum): the velocity
 * it leaves, sticking within a zone around the bow's speed, released along
 * a straight line (slope 10) back to u beyond it, transparent past that. */
static float bow(const le_tension_voice* v, float u) {
  const float f = v->bow_f, vc = v->bow_vc, vb = v->bow_vb;
  if (f <= 0.0f) return u;
  const float du = u - vb, a = fabsf(du);
  const float edge = vc + 0.5f * f, outer = vc + f / 1.8f;
  if (a <= edge) return (2.0f * vc * u + f * vb) / (f + 2.0f * vc);
  if (a >= outer) return u;
  const float stick = vb + (du > 0.0f ? vc : -vc);
  const float t = (a - edge) / (outer - edge);
  return stick + (du > 0.0f ? t : -t) * (outer - vc); /* a straight line [code] */
}

/* rail B at delay len + e + 1.5 samples: a 5-tap Lagrange read on the
 * taps len + n .. len + n + 4, n the whole part of e (toward zero), so the
 * read point sits 1.5 + its fraction into them, about their middle [code]
 * [measured] (taps one earlier, off the middle, lost up to 1.2 dB a round
 * trip at 14 kHz: Clav Bright's and the guitar presets' highs on loud high
 * notes 10 to 30 dB short of Live's; now 0.05 dB rms) */
static float rail_read(const float* r, int32_t w, int32_t len, float e) {
  const int32_t n = (int32_t)e;
  const int32_t i0 = len + n;
  const float x = TV_BRIDGE_READ + (e - (float)n);
  float y = 0.0f;
  for (int32_t k = 0; k < 5; ++k) {
    float h = 1.0f;
    for (int32_t j = 0; j < 5; ++j) {
      if (j != k) h *= (x - (float)j) / (float)(k - j);
    }
    y += h * r[(w - i0 - k) & TV_MASK];
  }
  return y;
}

/* One sample of the string: the reflections, the contacts, the output. */
static float string_tick(le_tension* d, le_tension_voice* v, int held) {
  const float rate = (float)d->sample_rate;
  const int32_t w = v->w, len = v->len;
  /* the bridge: rail B, delayed, through the dispersion and damping */
  const float rb = rail_read(v->b, w, len, v->e);
  const float ap = v->ap_a * rb + v->ap_x - v->ap_a * v->ap_y;
  v->ap_x = rb;
  v->ap_y = ap;
  const float lp = v->lp_b * (ap + v->lp_x) - v->lp_a * v->lp_y;
  v->lp_x = ap;
  v->lp_y = lp;
  const float a_new = -v->g * lp;
  /* the nut */
  const float ra = v->a[(w - len) & TV_MASK];
  const float b_new = v->term ? finger_fret(v, ra, rate) : -v->g * ra;
  v->a[w] = a_new;
  v->b[w] = b_new;
  /* the exciter, x from the bridge */
  float* ea = &v->a[(w - v->exc_tap) & TV_MASK];
  float* eb = &v->b[(w - (len - v->exc_tap)) & TV_MASK];
  const float u = *ea + *eb;
  if (v->exc_type == EXC_BOW) {
    if (v->bow_hold > 0 && --v->bow_hold == 0) v->bow_vb = v->bow_vb_late;
    const float u2 = held ? bow(v, u) : u;
    const float ain = *ea, bin = *eb;
    *ea = u2 - bin;
    *eb = u2 - ain;
    v->ys_exc += u2 / rate;
  } else if (v->exc.on) {
    le_tension_contact* c = &v->exc;
    const int moving = v->exc_type != EXC_PLECTRUM;
    float f;
    if (v->exc_type == EXC_PLECTRUM) {
      /* the plectrum pushes only while it overlaps the string by less than
       * its protrusion; past that it has slipped by */
      const float ov = c->y + c->v / rate - (v->ys_exc + u / rate);
      f = ov > 0.0f && ov < c->reach ? contact_force(c, v->ys_exc, u, 0, rate) : 0.0f;
    } else {
      f = contact_force(c, v->ys_exc, u, 1, rate);
    }
    contact_step(c, f, moving, rate);
    *ea += 0.5f * f;
    *eb += 0.5f * f;
    v->ys_exc += (u + 0.5f * f) / rate;
    /* parked 1 m behind its start (a hammer, once gravity takes it away:
     * a bouncing hammer still held falls back from any height), or 1 m
     * past it (the plectrum); a hammer driven on into the string stays on
     * it [code] (Slap Bass's hard C5; Moving String Pad's chord) */
    if (moving ? c->grav < 0.0f && c->y - c->y0 < -1.0 : c->y - c->y0 > 1.0) c->on = 0;
  } else {
    v->ys_exc += u / rate;
  }
  /* the damper, from the nut end, on the exciter's side */
  if (v->damper.on) {
    le_tension_contact* c = &v->damper;
    float* da = &v->a[(w - (len - v->damp_tap)) & TV_MASK];
    float* db = &v->b[(w - v->damp_tap) & TV_MASK];
    const float ud = *da + *db;
    const float f = contact_force(c, v->ys_damp, ud, 1, rate);
    contact_step(c, f, 1, rate);
    *da += 0.5f * f;
    *db += 0.5f * f;
    v->ys_damp += (ud + 0.5f * f) / rate;
    if (fabs(c->y - v->ys_damp) > 1.0) {
      /* parked away; at the key's release it returns */
      c->v = 0.0f;
      c->grav = 0.0f;
    }
  } else {
    v->ys_damp += (v->a[(w - (len - v->damp_tap)) & TV_MASK] + v->b[(w - v->damp_tap) & TV_MASK]) / rate;
  }
  /* the output: the pickup, or the wave at the bridge */
  float y;
  if (vi(d, LE_TENSION_PICKUP_ON)) {
    y = v->a[(w - (len - v->pick_tap)) & TV_MASK] + v->b[(w - v->pick_tap) & TV_MASK];
  } else {
    y = lp;
  }
  if (!(y == y) || fabsf(y) > 1e9f) {
    /* blown up: the string starts again from rest */
    memset(v->a, 0, sizeof(v->a));
    memset(v->b, 0, sizeof(v->b));
    v->lp_x = v->lp_y = v->ap_x = v->ap_y = v->hp_x = v->hp_y = 0.0f;
    v->ys_exc = v->ys_damp = 0.0f;
    v->exc.on = 0;
    y = 0.0f;
  }
  /* a 10 Hz high-pass and a gain of 2 */
  const float hw = 62.8f / rate;
  v->hp_y = (y - v->hp_x + (1.0f - hw) * v->hp_y) / (1.0f + hw);
  v->hp_x = y;
  v->w = (w + 1) & TV_MASK;
  /* the loss ramps */
  if (v->g_step != 0.0f) {
    v->g += v->g_step;
    if ((v->g_step > 0.0f && v->g >= v->g_to) || (v->g_step < 0.0f && v->g <= v->g_to)) {
      v->g = v->g_to;
      v->g_step = 0.0f;
    }
  }
  v->e += v->e_step;
  /* the reading's gain of 2. measured: 1.4373, 2.9 dB under it (the
   * median level of the 95 hammer, plectrum and bow fit renders that pass,
   * at the default Body Level, which is unity) */
  return 1.4373f * v->hp_y;
}

/* The shifter for pitch above the strike: a two-tap delay read rotating
 * across one period of the string, crossfaded. */
static float shift_tick(le_tension_voice* v, float x, float period) {
  v->sh[v->sh_w] = x;
  float p = fminf(period, (float)(LE_TENSION_SHIFT / 2 - 4));
  if (p < 4.0f) p = 4.0f;
  v->sh_d += 1.0f - v->sh_ratio;
  while (v->sh_d < 0.0f) v->sh_d += p;
  while (v->sh_d >= p) v->sh_d -= p;
  const float d1 = v->sh_d + 1.0f, d2 = v->sh_d + p + 1.0f;
  const int32_t i1 = (int32_t)d1, i2 = (int32_t)d2;
  const float f1 = d1 - (float)i1, f2 = d2 - (float)i2;
  const float t1 = v->sh[(v->sh_w - i1) & TV_SMASK] * (1.0f - f1) + v->sh[(v->sh_w - i1 - 1) & TV_SMASK] * f1;
  const float t2 = v->sh[(v->sh_w - i2) & TV_SMASK] * (1.0f - f2) + v->sh[(v->sh_w - i2 - 1) & TV_SMASK] * f2;
  v->sh_w = (v->sh_w + 1) & TV_SMASK;
  const float wgt = v->sh_d / p;
  return t1 * (1.0f - wgt) + t2 * wgt;
}

/* ---- notes ---- */

static void start_voice(le_tension* d, le_tension_voice* v, uint32_t origin, int32_t note, float vel,
                        uint64_t serial, int32_t copy, int32_t copies, int glide, int fresh) {
  const float rate = (float)d->sample_rate;
  v->state = LE_TENSION_VOICE_HELD;
  v->note = note;
  v->origin = origin;
  v->serial = serial;
  v->velocity = vel;
  v->copy = copy;
  v->copies = copies;
  static const float kSteps[4] = {0.0f, 1.0f, -1.0f, 2.0f};
  v->detune = unison_expz(0.001f, 1.0f, vf(d, LE_TENSION_UNISON_DETUNE)) * kSteps[copy];
  /* each copy a whole delay behind the one before, the delay counted in
   * whole milliseconds (the engine's 1 ms blocks). [measured] (round 5:
   * the reference's second string at delays 0.25, 0.5, 0.75 and 1 and
   * four strings at 0.5 land on Live's sample) */
  v->delay = (int32_t)(floorf(unison_expz(0.002f, 0.1f, vf(d, LE_TENSION_UNISON_DELAY)) * 1000.0f) * rate /
                       1000.0f) * copy;
  if (fresh) v->since = 0; /* a re-strike keeps the copies' delays behind them */
  v->quiet = 0;
  v->flying = 0;
  v->off_wait = 0;
  v->fade_left = 0;
  v->fade_len = (int32_t)lroundf(0.001f * rate);
  v->tick_left = 0;
  v->rng = 0x9e3779b9u ^ (uint32_t)(serial * 2654435761u + (uint32_t)copy * 40503u);
  /* Keyboard Error: a random rise of up to 0.02 octave, drawn at each strike */
  v->kerr = lin_int(0.0f, 0.02f, vf(d, LE_TENSION_ERROR)) * le_aas_unit(&v->rng);
  v->pitch_to = key_pitch(d, note) + v->kerr + v->detune;
  v->pitch = glide ? d->last_pitch + v->detune : v->pitch_to;
  v->vib_t = 0.0f;
  if (fresh) v->vib_ph = 0.0;
  string_strike(d, v, v->pitch, v->pitch_to, fresh);
  v->sh_ratio = 1.0f;
  v->sh_mix = 0.0f;
  v->sh_mix_step = 0.0f;
  if (fresh) v->sh_d = 0.0f, v->sh_w = 0;
  /* the filter section */
  if (fresh) memset(&v->f, 0, sizeof(v->f));
  float k[LE_AAS_ENV_FIELDS] = {TV_FENV_EXP, 0.0f, 0.0f, 0.0f, vf(d, LE_TENSION_FENV_ATTACK_VEL),
                                vf(d, LE_TENSION_FENV_ATTACK), vf(d, LE_TENSION_FENV_DECAY), vf(d, LE_TENSION_FENV_VEL),
                                vf(d, LE_TENSION_FENV_SUSTAIN), 1.0f, vf(d, LE_TENSION_FENV_RELEASE)};
  const le_aas_env_set es = le_aas_env_read(k);
  /* a string struck again drops its envelope from where it stands to 0
   * over 0.7 ms before the attack, the shared retrigger [measured]
   * (sbb-leg, the mono legato line, 0.34 to 0.14 dB rms) */
  if (fresh) {
    le_aas_env_start(&v->fenv, &es, vel, rate, 0);
  } else {
    le_aas_env_drop(&v->fenv, &es, vel, rate);
  }
  v->lfo_ph = 0.0;
  v->lfo_sh = v->lfo_sh_prev = le_aas_bipolar(&v->rng);
  v->lfo_wait = vf(d, LE_TENSION_LFO_DELAY) > 0.0f ? le_aas_exp(0.2f, 5.0f, vf(d, LE_TENSION_LFO_DELAY)) : 0.0f;
  v->lfo_amp = vf(d, LE_TENSION_LFO_FADE) > 0.0f ? 0.0f : 1.0f;
  d->last_pitch = v->pitch_to - v->detune;
  d->played = 1;
}

static le_aas_env_set fenv_set(const le_tension* d) {
  float k[LE_AAS_ENV_FIELDS] = {TV_FENV_EXP, 0.0f, 0.0f, 0.0f, vf(d, LE_TENSION_FENV_ATTACK_VEL),
                                vf(d, LE_TENSION_FENV_ATTACK), vf(d, LE_TENSION_FENV_DECAY), vf(d, LE_TENSION_FENV_VEL),
                                vf(d, LE_TENSION_FENV_SUSTAIN), 1.0f, vf(d, LE_TENSION_FENV_RELEASE)};
  return le_aas_env_read(k);
}

static void release_voice(le_tension* d, le_tension_voice* v) {
  const float rate = (float)d->sample_rate;
  v->state = LE_TENSION_VOICE_RELEASED;
  v->quiet = 0;
  v->rel_n = 0;
  v->blk_peak = 0.0f;
  /* the loss ramps over 8 ms to the release's: Ratio times faster, or none */
  const float ratio = expz(1.0f, 1000.0f, vf(d, LE_TENSION_STRING_RATIO));
  v->g_to = ratio <= 0.0f ? 1.0f : string_loss(d, v->pitch_to, ratio);
  v->g_step = (v->g_to - v->g) / (0.008f * rate);
  const le_aas_env_set es = fenv_set(d);
  le_aas_env_release(&v->fenv, &es, v->velocity, rate);
  /* the bouncing hammer leaves; the bow lifts; a gated damper returns */
  if (v->exc_type == EXC_BOUNCE) v->exc.grav = -TV_G;
  if (v->exc_type == EXC_BOW) v->bow_f = 0.0f;
  if (v->damper.on && vi(d, LE_TENSION_DAMPER_GATED)) {
    v->damper.y = v->ys_damp - 1e-5f;
    v->damper.v = v->damper.reach;
    v->damper.grav = TV_G;
    v->damper.z = 0.0f;
  }
}

/* A unison copy lets go its delay after the key, as it started its delay
 * after it: each copy plays the note delayed, its end too [measured]
 * (ccg-tri, 1.6 to 1.3 dB rms; 12 String Chorus Guitar's release, its
 * error 15 dB under Live's signal before, 40 after). */
static void release_copy(le_tension* d, le_tension_voice* v) {
  if (v->delay > 0) {
    v->state = LE_TENSION_VOICE_RELEASED;
    v->off_wait = v->delay;
  } else {
    release_voice(d, v);
  }
}

static void let_go(le_tension* d, le_tension_voice* v) {
  if (d->sustain_n > 0) v->state = LE_TENSION_VOICE_SUSTAINED;
  else release_copy(d, v);
}

int32_t le_tension_init(le_tension* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_TENSION_VOICE_SLOTS;
  for (int32_t p = 0; p < LE_TENSION_PARAMS; ++p) d->values[p] = le_tension_default(p);
  d->body.type = d->body.size = -1;
  d->body.level = -1.0f;
  return 0;
}

void le_tension_set_values(le_tension* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_TENSION_PARAMS; ++p) d->values[p] = le_tension_clamp(p, values[p]);
}

void le_tension_set_tempo(le_tension* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

int32_t le_tension_note_on(le_tension* d, uint32_t origin, int32_t note, int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  /* velocity 1..127 to 0..1, as the engines' shared MIDI front end sends
   * it [code] (the hammer references then match Live's to -100 dB) */
  const float vel = (float)(velocity - 1) / 126.0f;
  if (!chord) {
    for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
      le_tension_voice* v = &d->voices[i];
      if (v->state == LE_TENSION_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
    held_drop(d, origin);
  }
  const int overlapping = d->held_n > 0;
  const int glide = vi(d, LE_TENSION_GLIDE_ON) && d->played && !chord &&
                    (!vi(d, LE_TENSION_GLIDE_LEGATO) || overlapping);
  held_push(d, origin, note);
  const int32_t copies = copies_per_note(d);
  /* mono: the sounding note moves to the key the priority picks, struck
   * again on its own strings */
  if (mono(d)) {
    const int32_t pi = priority_index(d);
    if (overlapping && d->held_note[pi] != note) return 0; /* the held key keeps the voice */
    int found = 0;
    for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
      le_tension_voice* v = &d->voices[i];
      if (!sounding(v)) continue;
      found = 1;
      start_voice(d, v, origin, note, vel, v->serial, v->copy, v->copies, glide, 0);
    }
    if (found) return 0;
  }
  /* the same key again strikes its sounding strings without resetting them */
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (sounding(v) && v->note == note) {
      const uint64_t serial = ++d->serial;
      const uint64_t old = v->serial;
      for (int32_t j = 0; j < LE_TENSION_VOICE_SLOTS; ++j) {
        le_tension_voice* u = &d->voices[j];
        if (u->serial == old && sounding(u)) start_voice(d, u, origin, note, vel, serial, u->copy, u->copies, glide, 0);
      }
      return 0;
    }
  }
  const int32_t count = voice_count(d);
  while (note_count(d) >= count || free_count(d) < copies) {
    le_tension_voice* v = oldest(d, LE_TENSION_VOICE_RELEASED);
    if (v == NULL) v = oldest(d, LE_TENSION_VOICE_SUSTAINED);
    if (v == NULL) v = oldest(d, LE_TENSION_VOICE_HELD);
    if (v == NULL) break;
    fade_note(d, v);
    d->stolen++;
    if (free_count(d) < copies && note_count(d) < count) break; /* the fades free them */
  }
  const uint64_t serial = ++d->serial;
  for (int32_t k = 0; k < copies; ++k) {
    le_tension_voice* v = free_slot(d);
    if (v == NULL) break;
    start_voice(d, v, origin, note, vel, serial, k, copies, glide, 1);
  }
  return 0;
}

static void key_up(le_tension* d, le_tension_voice* v) {
  if (mono(d) && d->held_n > 0) {
    const int32_t pi = priority_index(d);
    v->note = d->held_note[pi];
    v->origin = d->held_origin[pi];
    v->pitch_to = key_pitch(d, v->note) + v->kerr + v->detune;
    if (!vi(d, LE_TENSION_GLIDE_ON)) v->pitch = v->pitch_to;
    d->last_pitch = v->pitch_to - v->detune;
    return;
  }
  let_go(d, v);
}

void le_tension_note_off(le_tension* d, uint32_t origin) {
  if (d == NULL) return;
  held_drop(d, origin);
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (v->state == LE_TENSION_VOICE_HELD && v->origin == origin) key_up(d, v);
  }
}

static void release_sustained(le_tension* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_TENSION_VOICE_SUSTAINED) release_copy(d, &d->voices[i]);
  }
}

int32_t le_tension_sustain(le_tension* d, uint32_t origin, int on) {
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
  if (d->sustain_n >= LE_TENSION_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_tension_expression(le_tension* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = le_aas_clamp(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_tension_release_matching(le_tension* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = d->held_n - 1; i >= 0; --i) {
    if (i < d->held_n && (d->held_origin[i] & mask) == value) held_drop(d, d->held_origin[i]);
  }
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (v->state == LE_TENSION_VOICE_HELD && (v->origin & mask) == value) {
      key_up(d, v);
    } else if (v->state == LE_TENSION_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_copy(d, v);
    }
  }
}

int32_t le_tension_held(const le_tension* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    const le_tension_voice* v = &d->voices[i];
    if (v->state == LE_TENSION_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_tension_cut(le_tension* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->held_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_tension_fade_oldest(le_tension* d) {
  if (d == NULL) return 0;
  le_tension_voice* old = NULL;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) n += d->voices[i].serial == old->serial && sounding(&d->voices[i]);
  fade_note(d, old);
  d->stolen++;
  return n;
}

int32_t le_tension_active(const le_tension* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

/* The voices fading, and the body while its tail rings. */
int32_t le_tension_fading(const le_tension* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) n += d->voices[i].state == LE_TENSION_VOICE_FADING;
  return n + (d->body.tail_left > 0);
}

void le_tension_set_voice_limit(le_tension* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_TENSION_VOICE_SLOTS ? LE_TENSION_VOICE_SLOTS : limit;
  while (le_tension_active(d) > d->voice_limit) {
    if (!le_tension_fade_oldest(d)) break;
  }
}

/* ---- the control tick ---- */

static void tick_voice(le_tension* d, le_tension_voice* v) {
  const float rate = (float)d->sample_rate;
  const float dt = (float)LE_TENSION_TICK / rate;
  /* glide and vibrato: the played pitch */
  if (vi(d, LE_TENSION_GLIDE_ON) && v->pitch != v->pitch_to) {
    float T = le_aas_exp(0.003f, 9.0f, vf(d, LE_TENSION_GLIDE_TIME));
    if (vi(d, LE_TENSION_GLIDE_PROP)) T *= sqrtf(fabsf(v->pitch_to - v->pitch));
    const float a = fminf(2.0f * LE_AAS_PI / (fmaxf(T, 1e-4f) * rate), 1.0f);
    v->pitch = v->pitch_to + (v->pitch - v->pitch_to) * powf(1.0f - a, (float)LE_TENSION_TICK);
    if (fabsf(v->pitch - v->pitch_to) < 1e-5f) v->pitch = v->pitch_to;
  } else {
    v->pitch = v->pitch_to;
  }
  float vib = 0.0f;
  v->vib_t += dt;
  if (vi(d, LE_TENSION_VIBRATO_ON)) {
    const float hz = le_aas_lin(0.25f, 10.0f, vf(d, LE_TENSION_VIBRATO_SPEED));
    float depth = mod_expz(0.0002f, 1.0f / 6.0f, vf(d, LE_TENSION_VIBRATO_AMOUNT)) +
                  d->mod * mod_expz(0.0002f, 1.0f / 6.0f, vf(d, LE_TENSION_VIBRATO_WHEEL));
    const float delay = mod_expz(0.05f, 5.0f, vf(d, LE_TENSION_VIBRATO_DELAY));
    const float fade = mod_expz(0.05f, 5.0f, vf(d, LE_TENSION_VIBRATO_FADE));
    if (v->vib_t < delay) depth = 0.0f;
    else if (fade > 0.0f) depth *= fminf((v->vib_t - delay) / fade, 1.0f);
    v->vib_ph += (double)(hz * dt);
    v->vib_ph -= floor(v->vib_ph);
    vib = depth * sinf(2.0f * LE_AAS_PI * (float)v->vib_ph);
  }
  /* the pitch handler: the key with bend follows on the string at or below
   * the strike's pitch; above it the string holds that and the shifter
   * takes the rest, crossfaded over 100 ms. Glide and vibrato then move
   * the string's length from the held pitch, so they never reach the
   * shifter */
  const float key = v->pitch_to + bend_oct(d);
  const float up = fmaxf(key - v->p0, 0.0f);
  const float ps = v->pitch + vib + (fminf(key, v->p0) - v->pitch_to);
  const float h = 0.5f * (rate / (TV_C4 * exp2_engine(ps)) - v->c_tune);
  float e_to = 2.0f * (h - (float)v->len);
  e_to = fmaxf(e_to, -(float)v->exc_tap);
  e_to = fminf(e_to, (float)(LE_TENSION_RAIL - 8 - v->len));
  v->e_step = (e_to - v->e) / (float)LE_TENSION_TICK;
  v->e_to = e_to;
  v->sh_ratio = exp2f(up);
  const float target = up > 1e-6f ? 1.0f : 0.0f;
  v->sh_mix_step = (target - v->sh_mix) / fmaxf(0.1f * rate * fabsf(target - v->sh_mix), 1.0f);
  /* the LFO */
  float lfo = 0.0f;
  if (vi(d, LE_TENSION_LFO_ON)) {
    float hz;
    if (vi(d, LE_TENSION_LFO_SYNC_ON)) {
      hz = d->bpm / 60.0f / le_aas_sync_beats(vi(d, LE_TENSION_LFO_SYNC));
    } else {
      hz = le_aas_exp(3.0f, 1000.0f, vf(d, LE_TENSION_LFO_SPEED)) / 60.0f;
    }
    const double before = v->lfo_ph;
    v->lfo_ph += (double)(hz * dt);
    if (v->lfo_ph >= 1.0) {
      v->lfo_ph -= floor(v->lfo_ph);
      v->lfo_sh_prev = v->lfo_sh;
      v->lfo_sh = le_aas_bipolar(&v->rng);
    }
    float y = le_aas_lfo_shape(vi(d, LE_TENSION_LFO_WAVE), before, 0.5f, v->lfo_sh, v->lfo_sh_prev);
    if (v->lfo_wait > 0.0f) {
      v->lfo_wait -= dt;
      y = 0.0f;
    } else if (v->lfo_amp < 1.0f) {
      v->lfo_amp = fminf(v->lfo_amp + dt / le_aas_exp(0.2f, 5.0f, vf(d, LE_TENSION_LFO_FADE)), 1.0f);
    }
    lfo = y * v->lfo_amp;
  }
  /* the filter: the key with bend, not glide or vibrato */
  if (vi(d, LE_TENSION_FILTER_ON)) {
    const float key = key_pitch(d, v->note) + v->kerr + v->detune + bend_oct(d);
    const float fenv = vi(d, LE_TENSION_FENV_ON) ? v->fenv.y : 0.0f;
    const float e_cut = le_aas_bsq(4.0f, vf(d, LE_TENSION_FILTER_KEY_CUTOFF)) * key +
                        le_aas_bsq(4.0f, vf(d, LE_TENSION_FILTER_LFO_CUTOFF)) * lfo +
                        le_aas_bq4(16.0f, vf(d, LE_TENSION_FILTER_ENV_CUTOFF)) * fenv;
    const float e_q = le_aas_bsq(4.0f, vf(d, LE_TENSION_FILTER_KEY_Q)) * key +
                      le_aas_bsq(4.0f, vf(d, LE_TENSION_FILTER_LFO_Q)) * lfo +
                      le_aas_bsq(4.0f, vf(d, LE_TENSION_FILTER_ENV_Q)) * fenv;
    const int32_t type = vi(d, LE_TENSION_FILTER_TYPE);
    const float fc = fmaxf(kexp(30.0f, 22000.0f, vf(d, LE_TENSION_FILTER_CUTOFF)) * exp2f(e_cut), 20.0f);
    const float q = kexp(0.1f, 120.0f, vf(d, LE_TENSION_FILTER_Q)) * exp2f(e_q); /* each stage clamps its own */
    if (type >= 8) {
      le_aas_formant_set(&v->f, type, vf(d, LE_TENSION_FILTER_CUTOFF), vf(d, LE_TENSION_FILTER_Q), e_cut, e_q, rate);
    } else {
      le_aas_filter_set(&v->f, type, le_aas_clamp(fc, 10.0f, 0.49f * rate), q, rate);
    }
  }
}

/* ---- the body ---- */

/* The soundboard's lines in samples at 44.1 kHz and size 1, one set per
 * body type, and the all-pass taps inside them, the same in every type.
 * fit: every type's wet-only render at all five sizes fitted sample by
 * sample against the dry string (Live's own renders, the lengths found as
 * whole samples at 48 kHz); each value the one, or the lowest of the few,
 * that gives all twenty renders' lengths. */
static const float kBodyLong[4][4] = {
    {239.0f, 288.0f, 334.0f, 411.0f}, {105.0f, 126.0f, 238.0f, 441.0f}, {55.0f, 81.0f, 107.0f, 150.0f}, {286.0f, 345.0f, 386.0f, 507.0f}};
static const float kBodyTap[4] = {44.0f, 48.0f, 61.0f, 71.0f};
static const float kBodySize[5] = {0.3f, 0.7f, 1.0f, 1.3f, 2.0f};

static int is_prime(int32_t n) {
  if (n < 2) return 0;
  for (int32_t k = 2; k * k <= n; ++k) {
    if (n % k == 0) return 0;
  }
  return 1;
}

static int32_t prime_below(int32_t n) {
  while (n > 2 && !is_prime(n)) n--;
  return n;
}

/* The body's lines and filters at rest. */
static void body_clear(le_tension_body* b) {
  memset(b->line, 0, sizeof(b->line));
  memset(b->apb, 0, sizeof(b->apb));
  b->apw = 0;
  memset(b->hp_y, 0, sizeof(b->hp_y));
  memset(b->hp_x, 0, sizeof(b->hp_x));
  memset(b->lp_y, 0, sizeof(b->lp_y));
  memset(b->fb, 0, sizeof(b->fb));
  b->w = 0;
}

static void body_build(le_tension* d) {
  le_tension_body* b = &d->body;
  const int32_t type = vi(d, LE_TENSION_BODY_TYPE), size = vi(d, LE_TENSION_BODY_SIZE);
  if (type == b->type && size == b->size) return;
  b->type = type;
  b->size = size;
  /* size x rate / 44.1 kHz, in single precision as the lengths were found */
  const float scale = kBodySize[size] * (1.0f / 44100.0f) * (float)d->sample_rate;
  for (int32_t k = 0; k < 4; ++k) {
    b->len[k] = clampi(prime_below((int32_t)(kBodyLong[type][k] * scale)), 8, LE_TENSION_BODY_LINE - 2);
    b->tap[k] = clampi(prime_below((int32_t)(kBodyTap[k] * scale)), 1, b->len[k] < LE_TENSION_BODY_AP - 1 ? b->len[k] : LE_TENSION_BODY_AP - 1);
  }
  body_clear(b);
}

/* The body on a block of the voices' sum, in place. */
static void body_render(le_tension* d, float* x, int32_t n) {
  le_tension_body* b = &d->body;
  const float rate = (float)d->sample_rate;
  /* Body Level, the device's volume: Sq(0, 2) on the knob's 0..127 value
   * as it stands, not its whole step (the default 0.7048 is unity).
   * [measured] (the first milliseconds of every preset with the body on,
   * which then match Live's within 0.03 %) */
  const float lv = le_aas_clamp(vf(d, LE_TENSION_BODY_LEVEL), 0.0f, 1.0f);
  const float lm = (lv <= 0.5f ? 128.0f * lv : 126.0f * lv + 1.0f) / 127.0f;
  const float level = 2.0f * lm * lm;
  const int on = vi(d, LE_TENSION_BODY_ON);
  const float theta = lin_int(0.0f, 0.5f * LE_AAS_PI, vf(d, LE_TENSION_BODY_MIX));
  const float dry_to = on ? cosf(theta) : 1.0f, wet_to = on ? 0.35f * sinf(theta) : 0.0f;
  if (b->level < 0.0f) {
    b->level = level;
    b->mix_dry = dry_to;
    b->mix_wet = wet_to;
  }
  body_build(d);
  const float tb = kexp(0.04f, 0.6f, vf(d, LE_TENSION_BODY_DECAY));
  /* High Cut is the ratio of the highs' decay to the lows', smaller as the
   * knob rises (fit: the body renders; the reading leaves its direction
   * open) */
  const float hc = exp_m(0.05f, 0.7f, 127 - knob_m(vf(d, LE_TENSION_BODY_HIGH_CUT)));
  const float lc_k = vf(d, LE_TENSION_BODY_LOW_CUT);
  const float hpa = 1.0f / (1.0f + 6.2f * kexp(20.0f, 700.0f, lc_k) / rate);
  /* the absorption: DC gain g, Nyquist gain g^(1 / High Cut) at 44.1 kHz,
   * its coefficient taken at the host rate as it stands */
  float lpa[4], lpb[4];
  for (int32_t k = 0; k < 4; ++k) {
    const float g = powf(10.0f, -3.0f * (float)b->len[k] / (rate * tb));
    const float p = powf(g, (1.0f - hc) / hc);
    const float kk = 88200.0f / rate * p / (p + 1.0f);
    lpa[k] = 1.0f - kk;
    lpb[k] = kk * g;
  }
  /* the diffusion: -0.29 at size 1, deeper as the square root of the size */
  const float diff = -0.29126f * sqrtf(kBodySize[b->size]);
  /* the ramps: a new target sets its step, kept until it arrives */
  if (level != b->level_to) b->level_to = level, b->level_step = (level - b->level) / 4000.0f;
  if (dry_to != b->dry_to) b->dry_to = dry_to, b->dry_step = (dry_to - b->mix_dry) / 500.0f;
  if (wet_to != b->wet_to) b->wet_to = wet_to, b->wet_step = (wet_to - b->mix_wet) / 500.0f;
  /* the tail: as long as a line's decay lasts after the last string, then
   * the lines are cleared */
  int sounding_any = 0;
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS && !sounding_any; ++i) {
    sounding_any = d->voices[i].state != LE_TENSION_VOICE_FREE;
  }
  const int32_t tail_len = (int32_t)(rate * (2.0f * tb + 0.05f));
  for (int32_t s = 0; s < n; ++s) {
    const float in = x[s];
    float wet = 0.0f;
    if (on || b->mix_wet > 0.0f) {
      for (int32_t k = 0; k < 4; ++k) {
        /* the line: the input with its own feedback through a delay, then a
         * Schroeder all-pass (the diffusion) at its tap */
        const int32_t L = b->len[k], T = b->tap[k];
        float* line = b->line[k];
        float* ap = b->apb[k];
        line[b->w] = in + b->fb[k];
        const float x = line[(b->w - (L - T) + LE_TENSION_BODY_LINE) % LE_TENSION_BODY_LINE];
        const float vt = ap[(b->apw - T + LE_TENSION_BODY_AP) % LE_TENSION_BODY_AP];
        const float vn = x + diff * vt;
        ap[b->apw] = vn;
        const float y = vt - diff * vn;
        /* the low cut, then the absorption */
        b->hp_y[k] = hpa * (b->hp_y[k] + y - b->hp_x[k]);
        b->hp_x[k] = y;
        b->lp_y[k] = lpb[k] * b->hp_y[k] + lpa[k] * b->lp_y[k];
        b->fb[k] = b->lp_y[k];
        wet += b->fb[k];
      }
      b->w = (b->w + 1) % LE_TENSION_BODY_LINE;
      b->apw = (b->apw + 1) % LE_TENSION_BODY_AP;
    }
    b->level = fabsf(level - b->level) > fabsf(b->level_step) ? b->level + b->level_step : level;
    b->mix_dry = fabsf(dry_to - b->mix_dry) > fabsf(b->dry_step) ? b->mix_dry + b->dry_step : dry_to;
    b->mix_wet = fabsf(wet_to - b->mix_wet) > fabsf(b->wet_step) ? b->mix_wet + b->wet_step : wet_to;
    x[s] = b->level * (b->mix_dry * in + b->mix_wet * wet);
    if (sounding_any) {
      b->tail_left = tail_len;
    } else if (b->tail_left > 0 && --b->tail_left == 0) {
      body_clear(b);
    }
  }
  if (!on && b->mix_wet == 0.0f && b->tail_left > 0 && !sounding_any) {
    b->tail_left = 0;
    body_clear(b);
  }
}

/* ---- rendering ---- */

static void render_voice(le_tension* d, le_tension_voice* v, float* out, int32_t frames) {
  const float rate = (float)d->sample_rate;
  const le_aas_env_set es = fenv_set(d);
  const int32_t ftype = vi(d, LE_TENSION_FILTER_TYPE);
  const int filter_on = vi(d, LE_TENSION_FILTER_ON);
  const float fade_step = 1.0f / (float)(v->fade_len > 0 ? v->fade_len : 1);
  const int32_t block_len = (int32_t)lroundf(0.001f * rate);
  int32_t i = 0;
  while (i < frames && v->state != LE_TENSION_VOICE_FREE) {
    if (v->since < v->delay) {
      if (v->state == LE_TENSION_VOICE_FADING) {
        v->state = LE_TENSION_VOICE_FREE; /* never started */
        return;
      }
      const int32_t n = v->delay - v->since < frames - i ? v->delay - v->since : frames - i;
      v->since += n;
      if (v->off_wait > 0 && (v->off_wait -= n) == 0 && v->state == LE_TENSION_VOICE_RELEASED) release_voice(d, v);
      i += n;
      continue;
    }
    if (v->tick_left == 0) {
      tick_voice(d, v);
      v->tick_left = LE_TENSION_TICK;
    }
    int32_t n = v->tick_left < frames - i ? v->tick_left : frames - i;
    if (v->state == LE_TENSION_VOICE_FADING && v->fade_left < n) n = v->fade_left > 0 ? v->fade_left : 0;
    if (n == 0) {
      v->state = LE_TENSION_VOICE_FREE;
      return;
    }
    if (v->off_wait > 0 && v->off_wait < n) n = v->off_wait;
    const int held = v->state == LE_TENSION_VOICE_HELD || v->state == LE_TENSION_VOICE_SUSTAINED || v->off_wait > 0;
    const float period = rate / (TV_C4 * exp2_engine(fminf(v->pitch_to + bend_oct(d), v->p0)));
    for (int32_t s = 0; s < n; ++s) {
      float y = string_tick(d, v, held);
      const float y_string = y; /* the string's own sound, before the filter */
      if (v->sh_mix > 0.0f || v->sh_mix_step > 0.0f) {
        const float z = shift_tick(v, y, period);
        y = y + v->sh_mix * (z - y);
      } else {
        v->sh[v->sh_w] = y;
        v->sh_w = (v->sh_w + 1) & TV_SMASK;
      }
      v->sh_mix = le_aas_clamp(v->sh_mix + v->sh_mix_step, 0.0f, 1.0f);
      (void)le_aas_env_tick(&v->fenv, &es, held, v->velocity, rate);
      if (filter_on) y = le_aas_filter_tick(&v->f, ftype, y);
      if (v->state == LE_TENSION_VOICE_FADING) {
        y *= fade_step * (float)(v->fade_left > s ? v->fade_left - s : 0);
      }
      out[i + s] += y;
      /* a released string ends after 84 one-millisecond blocks in a row,
       * counted from the release, in which its own sound (not the
       * filter's, which an LFO may close for a while) peaks below -101.1
       * dBFS; and not while a gated damper is still in the air, for at most
       * 2 s of flight. [measured] (rounds 6 and 7: Live cuts to silence on
       * 1 ms boundaries, never sooner than 84 blocks after the release, at
       * 84 for a still string; -101.1 dBFS from a string held at -88 dB
       * with no release loss, cut 2094 blocks on; Wurli Mellow's low thump
       * 190 ms after a release) [Segno] (Live cuts a resting damper's,
       * a terminated string's and a landed gated damper's string sooner,
       * by a condition the renders have not shown) */
      if (v->state == LE_TENSION_VOICE_RELEASED && v->off_wait == 0) {
        const int flying = v->damper.on && v->damper.f <= 0.0 && v->damper.grav != 0.0f &&
                           v->flying < (int32_t)(2.0f * rate);
        v->flying += flying;
        if (fabsf(y_string) > v->blk_peak) v->blk_peak = fabsf(y_string);
        if (flying) v->blk_peak = 1.0f;
        if (++v->rel_n >= block_len) {
          v->quiet = v->blk_peak < 8.84e-6f ? v->quiet + 1 : 0;
          v->rel_n = 0;
          v->blk_peak = 0.0f;
          if (v->quiet >= 84) {
            v->state = LE_TENSION_VOICE_FREE;
            return;
          }
        }
      }
    }
    v->tick_left -= n;
    if (v->off_wait > 0 && (v->off_wait -= n) == 0 && v->state == LE_TENSION_VOICE_RELEASED) release_voice(d, v);
    if (v->since < (1 << 30)) v->since += n;
    i += n;
    if (v->state == LE_TENSION_VOICE_FADING) {
      v->fade_left -= n;
      if (v->fade_left <= 0) v->state = LE_TENSION_VOICE_FREE;
    }
  }
}

void le_tension_render(le_tension* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
    le_tension_voice* v = &d->voices[i];
    if (v->state != LE_TENSION_VOICE_FREE) render_voice(d, v, left, frames);
  }
  body_render(d, left, frames);
  /* the output stage: linear to 0.7 of full scale (4), then bending toward
   * it, 1 - 0.3 / u^3 with u = (10 x + 2) / 9 */
  for (int32_t i = 0; i < frames; ++i) {
    const float x = 0.25f * left[i], a = fabsf(x);
    if (a > 0.7f) {
      const float u = a * (10.0f / 9.0f) + 2.0f / 9.0f;
      left[i] = (x < 0.0f ? -4.0f : 4.0f) * (1.0f - 0.3f / (u * u * u));
    }
  }
  memcpy(right, left, sizeof(float) * (size_t)frames);
}
