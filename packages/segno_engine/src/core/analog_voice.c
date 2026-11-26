/*
 * analog_voice.c — the Analog device (analog_voice.h).
 *
 * Written from the behavior description in docs/brainstorm/2026-11-24-
 * ableton-devices-brainstorm-doc.md ("Analog: behavior"). Values marked
 * "fit" were set against Live renders; the rest follow the description.
 */
#include "analog_voice.h"

#include "aas_parts.h"

#include <math.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

/* fit: C4 0.98 cent below equal temperament's 261.6256 Hz (every
 * oscillator render, at every note) */
#define AV_C4 261.4776f
#define AV_PI_D 3.14159265358979323846
/* The oscillator's pitch tick, samples. */
#define AV_OSC_TICK 40
/* fit: the pitch envelope's length over Exp(0.01, 10) s, by the time knob
 * (each value the best fit of a full-depth sweep's onset and 8 Hz tail:
 * segno-analog-fit7 penv7-t005 .. t060, penv-1-t015, Kick Complex Perc);
 * linear between the points, flat beyond them */
static float penv_factor(float knob) {
  static const float kAt[9] = {0.05f, 0.10f, 0.15f, 0.20f, 0.25f, 0.30f, 0.40f, 0.50f, 0.60f};
  static const float kK[9] = {0.99f, 1.04f, 1.035f, 1.0275f, 1.025f, 1.0205f, 1.025f, 1.0243f, 1.0245f};
  if (knob <= kAt[0]) return kK[0];
  for (int32_t i = 1; i < 9; ++i) {
    if (knob <= kAt[i]) return kK[i - 1] + (kK[i] - kK[i - 1]) * (knob - kAt[i - 1]) / (kAt[i] - kAt[i - 1]);
  }
  return kK[8];
}

enum {
  LE_ANALOG_VOICE_FREE = 0,
  LE_ANALOG_VOICE_HELD,
  LE_ANALOG_VOICE_RELEASED,
  LE_ANALOG_VOICE_SUSTAINED,
  LE_ANALOG_VOICE_FADING
};

_Static_assert(LE_ANALOG_ENV_FIELDS == LE_AAS_ENV_FIELDS && LE_ANALOG_ENV_RELEASE == LE_AAS_ENV_RELEASE &&
                   LE_ANALOG_ENV_EXP == LE_AAS_ENV_EXP,
               "Analog's envelope fields are the shared envelope's");

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

/* A cubic 2^x: 2^i times 1 + y + y^2 (1/2 + c y) on the fraction f, y =
 * f ln 2, c chosen so the cubic meets 2 at f = 1 (its error peaks at 1.3
 * cents near f = 0.75). */
static float exp2_cubic(float x) {
  const float ln2 = 0.69314718f;
  const float c = (1.0f - ln2 - 0.5f * ln2 * ln2) / (ln2 * ln2 * ln2);
  const float i = floorf(x), y = (x - i) * ln2;
  return ldexpf(1.0f + y + y * y * (0.5f + c * y), (int)i);
}

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
 * is a step r / LE_ANALOG_BL_PHASES of the way from the last sample to the
 * current one, column j the sample j - LE_ANALOG_BL_HALF from the current
 * one. The step is the running sum of the impulse's samples, scaled to end
 * at exactly 1. */
static void bl_init(le_analog* d) {
  const int32_t H = LE_ANALOG_BL_HALF;
  for (int32_t r = 0; r <= LE_ANALOG_BL_PHASES; ++r) {
    const double frac = (double)r / LE_ANALOG_BL_PHASES;
    /* the impulse's samples: sample j - H sits x = j - H + 1 - frac after it */
    double k[2 * LE_ANALOG_BL_HALF + 1];
    double total = 0.0;
    for (int32_t j = 0; j <= 2 * H; ++j) total += (k[j] = bl_kernel((double)(j - H) + 1.0 - frac));
    double run = 0.0;
    for (int32_t j = 0; j < 2 * H; ++j) {
      run += k[j];
      const double x = (double)(j - H) + 1.0 - frac;
      d->bl[r][j] = (float)(run / total - (x >= 0.0 ? 1.0 : 0.0));
    }
  }
}

/* A step of height h at `te` of the way from the last sample to the
 * current one, band-limited into the chain's output ring. */
static void bl_add(const le_analog* d, le_analog_chain* ch, float te, float h) {
  const float p = le_aas_clamp(te, 0.0f, 1.0f) * (float)LE_ANALOG_BL_PHASES;
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

/* A chain's envelope settings, from its knobs at `base`. */
static le_aas_env_set read_env(const le_analog* d, int32_t c, int32_t base) {
  return le_aas_env_read(&d->values[LE_ANALOG_CHAIN(c, base)]);
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

/* A slot's device voice gives up its free LFOs' phases: `at` the age they
 * stop at (the slot still sounding: now, else when it went quiet). */
static void lv_store(le_analog* d, le_analog_voice* v, int32_t at) {
  if (v->lv < 0) return;
  for (int32_t k = 0; k < LE_ANALOG_COPIES; ++k) {
    for (int32_t c = 0; c < 2; ++c) {
      d->lv_ph[v->lv][k][c] = v->c[k].ch[c].lfo_ph;
      d->lv_sh[v->lv][k][c][0] = v->c[k].ch[c].lfo_sh;
      d->lv_sh[v->lv][k][c][1] = v->c[k].ch[c].lfo_sh_prev;
      d->lv_fenv[v->lv][k][c] = v->c[k].ch[c].fenv;
    }
  }
  d->lv_quiet[v->lv] = at;
  d->lv_vib[v->lv] = v->vib_ph;
  v->lv = -1;
}

/* The device voice a new note takes: the stolen one's, else an idle one. */
static float lfo_hz(const le_analog* d, int32_t c);

/* fit: a device voice that went quiet stays with its last note for
 * AV_LV_RUN_ON s, its free LFOs running; a note in the first AV_LV_RETAKE s
 * of that takes it back, a later one takes another voice (segno-analog-fit8
 * lvr-gap050 keeps one voice, lvr-gap100 and round 5's lfo-free alternate
 * two, gaps of 150 ms and more find the first one idle again). */
#define AV_LV_RUN_ON 0.1125
#define AV_LV_RETAKE 0.06

static int32_t lv_pick(le_analog* d) {
  if (d->lv_steal >= 0) return d->lv_steal;
  int32_t n = kVoices[vi(d, LE_ANALOG_POLYPHONY)];
  if (n < 2) n = 2; /* a mono voice alternates two as well */
  if (n > LE_ANALOG_DEVICE_VOICES) n = LE_ANALOG_DEVICE_VOICES;
  int32_t busy[LE_ANALOG_DEVICE_VOICES] = {0};
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (d->voices[i].state != LE_ANALOG_VOICE_FREE && d->voices[i].lv >= 0) busy[d->voices[i].lv] = 1;
  }
  const int32_t run_on = (int32_t)(AV_LV_RUN_ON * (double)d->sample_rate);
  const int32_t retake = (int32_t)(AV_LV_RETAKE * (double)d->sample_rate);
  int32_t back = -1;
  for (int32_t j = 0; j < n; ++j) {
    if (busy[j] || !d->lv_used[j]) continue;
    const int32_t q = d->age - d->lv_quiet[j];
    if (q < retake && (back < 0 || q < d->age - d->lv_quiet[back])) back = j;
  }
  if (back >= 0) return back;
  for (int32_t j = 0; j < n; ++j) {
    if (!busy[j] && (!d->lv_used[j] || d->age - d->lv_quiet[j] >= run_on)) return j; /* the lowest idle one */
  }
  for (int32_t j = 0; j < n; ++j) {
    if (!busy[j]) return j;
  }
  return (d->lv_last + 1) % n;
}

/* A device voice's free LFOs run on while it is quiet for its run-on, and
 * whenever another voice of the device sounds (fit: lvr-gap100, whose
 * first voice's LFO runs through the second voice's note and stops when it
 * ends). */
static void lv_run_on(le_analog* d, int32_t frames) {
  int32_t attached[LE_ANALOG_DEVICE_VOICES] = {0};
  int active = 0;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    const le_analog_voice* v = &d->voices[i];
    if (v->state == LE_ANALOG_VOICE_FREE) continue;
    active = 1;
    if (v->lv >= 0) attached[v->lv] = 1;
  }
  const int32_t run_on = (int32_t)(AV_LV_RUN_ON * (double)d->sample_rate);
  for (int32_t j = 0; j < LE_ANALOG_DEVICE_VOICES; ++j) {
    if (attached[j] || !d->lv_used[j] || (!active && d->age - d->lv_quiet[j] >= run_on)) continue;
    for (int32_t c = 0; c < 2; ++c) {
      if (!ci(d, c, LE_ANALOG_LFO_ON) || ci(d, c, LE_ANALOG_LFO_GATE_RESET)) continue;
      const double dph = (double)lfo_hz(d, c) * (double)frames / (double)d->sample_rate;
      for (int32_t k = 0; k < LE_ANALOG_COPIES; ++k) {
        double ph = d->lv_ph[j][k][c] + dph;
        if (ph >= 1.0) {
          ph -= floor(ph);
          d->lv_sh[j][k][c][1] = d->lv_sh[j][k][c][0];
          d->lv_sh[j][k][c][0] = le_aas_bipolar(&d->rng);
        }
        d->lv_ph[j][k][c] = ph;
      }
    }
  }
}

/* The keyboard pitch of `note` in octaves from C4: transpose, octave and
 * fine tune included. */
static float key_pitch(const le_analog* d, int32_t note) {
  const float fine = (vf(d, LE_ANALOG_FINE_TUNE) - 0.5f) * 2.0f / 12.0f;
  const float key = (float)(note + vi(d, LE_ANALOG_TRANSPOSE) + 12 * vi(d, LE_ANALOG_OCTAVE));
  /* fit: Keyboard Stretch widens the scale about A4, 0.8 cent a semitone
   * at either end of the knob (the stretch renders, C2 to C7) */
  const float stretch = 2.0f * (le_aas_clamp(vf(d, LE_ANALOG_STRETCH), 0.0f, 1.0f) - 0.5f) * 0.8f / 1200.0f;
  return (key - 60.0f) / 12.0f + stretch * (key - 69.0f) + fine;
}

/* fit: Keyboard Error sharpens each copy of a note by a random amount,
 * uniform from 0 to 22 cents times Error^1.5 (24 strikes at Error 1 over
 * three Live instances: all sharp, mean 10.8, the largest 21.5; eight at
 * 0.5: mean 3.6, the largest 7.8). */
static float key_error(const le_analog* d, le_analog_copy* cp) {
  const float e = le_aas_clamp(vf(d, LE_ANALOG_ERROR), 0.0f, 1.0f);
  if (e <= 0.0f) return 0.0f;
  return e * sqrtf(e) * le_aas_unit(&cp->rng) * 22.0f / 1200.0f;
}

/* fit: the glide time knob, 3 ms .. 9 s (the glide renders' time
 * constants at two settings) */
static float glide_seconds(const le_analog* d) { return le_aas_exp(0.003f, 9.0f, vf(d, LE_ANALOG_GLIDE_TIME)); }

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

/* The LFO's rate in Hz: a tempo division, or Exp(3, 1000) a minute. */
static float lfo_hz(const le_analog* d, int32_t c) {
  if (ci(d, c, LE_ANALOG_LFO_SYNC_ON)) return d->bpm / 60.0f / le_aas_sync_beats(ci(d, c, LE_ANALOG_LFO_SYNC));
  return le_aas_exp(3.0f, 1000.0f, cf(d, c, LE_ANALOG_LFO_SPEED)) / 60.0f;
}

/* Runs an envelope on by `n` samples in its current segment (it stops at
 * the segment's end: the release's end is idle). */
static void env_advance(le_aas_env* e, int32_t n) {
  if (e->seg == LE_AAS_SEG_IDLE || e->left < 0 || n <= 0) return;
  if (n >= e->left) {
    e->y = e->to;
    if (e->seg == LE_AAS_SEG_RELEASE) e->seg = LE_AAS_SEG_IDLE, e->y = 0.0f;
    e->left = 1;
    return;
  }
  if (e->c > 0.0f) {
    const float target = e->y0 + 1.0313935f * (e->to - e->y0);
    e->y = target + (e->y - target) * powf(1.0f - e->c, (float)n);
  } else {
    e->y += e->step * (float)n;
  }
  e->left -= n;
}

/* A copy starts from rest: its filters, the integrator's leak and the
 * noise filter cleared, so nothing of the slot's last note rings on. */
static void start_copy(le_analog* d, le_analog_voice* v, le_analog_copy* cp) {
  const float rate = (float)d->sample_rate;
  cp->noise_lp = 0.0f;
  memset(cp->noise_ring, 0, sizeof(cp->noise_ring));
  cp->noise_at = 0;
  for (int32_t c = 0; c < 2; ++c) {
    le_analog_chain* ch = &cp->ch[c];
    const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
    const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
    /* fit: a filter envelope with Legato on carries on from the device
     * voice's last note, its release run on through the gap, and rises from
     * there (Square Pure Bass's and Rhythmic Octaves Bass's later notes);
     * without Legato it starts from 0 (Muted Dark Bass, Accordion Unisono
     * Pad) */
    int from = 0;
    if (d->lv_used[v->lv] && ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO)) {
      ch->fenv = d->lv_fenv[v->lv][cp - v->c][c];
      /* fit: it runs on for 0.1 s after the voice goes quiet, then holds
       * (fleg-on, fleg-on-mono, fleg-on-pos: 0.08 to 0.12 s fit, the whole
       * gap leaves the later notes 2 to 5 dB too bright) */
      const int32_t gap = d->age - d->lv_quiet[v->lv], run_on = d->sample_rate / 10;
      env_advance(&ch->fenv, gap < run_on ? gap : run_on);
      from = ch->fenv.seg != LE_AAS_SEG_IDLE;
    }
    le_aas_env_start(&ch->fenv, &fe, v->velocity, rate, from);
    le_aas_env_start(&ch->aenv, &ae, v->velocity, rate, 0);
    memset(ch->f.s, 0, sizeof(ch->f.s));
    ch->noise_lp = 0.0f;
    memset(ch->ring, 0, sizeof(ch->ring));
    ch->ring_at = 0;
    ch->penv = 1.0f;
    ch->per = 0.0f;
    ch->otick = 0;
    ch->penv_step = 1.0f / fmaxf(penv_factor(cf(d, c, LE_ANALOG_OSC_ENV_TIME)) * le_aas_exp(0.01f, 10.0f, cf(d, c, LE_ANALOG_OSC_ENV_TIME)) * rate, 1.0f);
    /* fit: the oscillators start where Live's do (the oscillator renders):
     * the saw halfway up its ramp (the sync slave too), the rectangle at the
     * start of its low part, the sub square low, the sync master at its
     * reset; the rectangle's integrator holds its mean already */
    const int32_t shape = ci(d, c, LE_ANALOG_OSC_SHAPE);
    ch->ph = shape == 1 ? 0.5 : 0.0;
    ch->ph2 = 0.0;
    ch->sub_sign = -1;
    ch->dc = shape == 2 ? 0.0365f + 0.4635f * le_aas_knob(cf(d, c, LE_ANALOG_OSC_PW)) : 0.0f;
    /* with Retrigger the LFO restarts at its Phase at each note. fit:
     * without, each of the device's voices (as many as the Voices setting,
     * a stolen one handing its LFOs to the note that takes it) runs its
     * LFO from the device's start, three quarters of Phase into its cycle
     * there, until the voice's first note (segno-analog-fit6 Nasal Mod
     * Lead's triad on fresh voices from 8.6 to 3.8 dB, Glass High Strings
     * Pad 7.5 to 5.9; lfo-free's second voice enters within 0.013 cycle of
     * that phase); from then on it runs while the voice plays and for 52 ms
     * after it goes quiet (two Live instances render the same free LFO;
     * eight strikes 0.4 s apart keep its phase from note to note, losing
     * the rest of each gap; Rhythmic Octaves Bass's triad on two voices) */
    if (ci(d, c, LE_ANALOG_LFO_GATE_RESET)) {
      ch->lfo_ph = cf(d, c, LE_ANALOG_LFO_PHASE);
      /* fit: a retriggered random wave starts from a random value, noise
       * held there for the first cycle (the lfo-wave renders; Live's copies
       * of lfo-wave3 differ from the first sample) */
      ch->lfo_sh = ch->lfo_sh_prev = le_aas_bipolar(&cp->rng);
    } else {
      double ph;
      const int32_t k = (int32_t)(cp - v->c);
      if (!d->lv_used[v->lv]) {
        /* fit: from the device's first note, 0.07 + 0.648 Phase cycles in
         * there (lvr-gap and lfo9-late at Phase 0, lfo-free at Phase 1;
         * lfo9-late's one note at 1.3 s starts where a note at 0 s does) */
        ph = 0.07 + 0.648 * cf(d, c, LE_ANALOG_LFO_PHASE) +
             (double)lfo_hz(d, c) * (double)(d->age - d->first_age) / (double)d->sample_rate;
        /* fit: a free random wave holds 0 until its first cycle ends (Live's
         * copies of the free S&H and noise presets agree to the sample until
         * then; segno-analog-fit6 Dual OSC Sample & Hold Bass's first 0.35 s
         * from 17.9 dB to 0.45, Overtones' 6.8 to 0.7) */
        ch->lfo_sh = ch->lfo_sh_prev = 0.0f;
      } else {
        /* as the device voice left it, run on by lv_run_on, its held
         * random values with it */
        ph = d->lv_ph[v->lv][k][c];
        ch->lfo_sh = d->lv_sh[v->lv][k][c][0];
        ch->lfo_sh_prev = d->lv_sh[v->lv][k][c][1];
      }
      ch->lfo_ph = ph - floor(ph);
    }
    ch->lfo_wait = le_aas_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_DELAY));
    if (cf(d, c, LE_ANALOG_LFO_DELAY) <= 0.0f) ch->lfo_wait = 0.0f;
    ch->lfo_amp = cf(d, c, LE_ANALOG_LFO_FADE) <= 0.0f ? 1.0f : 0.0f;
    ch->gl = ch->gr = 0.0f;
    ch->g_fresh = 1;
  }
}

/* fit: a mono voice's new key restarts each retriggered LFO, at its Phase,
 * with a fresh random value, its delay and its fade-in, as a new note does
 * (segno-analog-fit6 Rhythmic Iron, whose A5 retakes the releasing voice:
 * its S&H on the cutoff fading in again, from 10.4 to 5.8 dB). */
static void lfo_restart(const le_analog* d, le_analog_copy* cp, int32_t c) {
  le_analog_chain* ch = &cp->ch[c];
  if (!ci(d, c, LE_ANALOG_LFO_GATE_RESET)) return;
  ch->lfo_ph = cf(d, c, LE_ANALOG_LFO_PHASE);
  ch->lfo_sh = ch->lfo_sh_prev = le_aas_bipolar(&cp->rng);
  ch->lfo_wait = cf(d, c, LE_ANALOG_LFO_DELAY) <= 0.0f ? 0.0f : le_aas_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_DELAY));
  ch->lfo_amp = cf(d, c, LE_ANALOG_LFO_FADE) <= 0.0f ? 1.0f : 0.0f;
}

/* The unison amounts' curve: Exp(lo, hi) on m = 127 v, exactly 0 at 0. */
static float unison_expz(float lo, float hi, float v) {
  const float m = 127.0f * le_aas_clamp(v, 0.0f, 1.0f);
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
  v->vib_dev = 0.0f;
  v->pitch_to = key_pitch(d, note);
  v->pitch = glide ? d->last_pitch : v->pitch_to;
  v->glided = glide;
  v->keyed_at = d->age;
  /* the unison copies sit 0, +1, -1, +2 steps from the note (fit: the
   * unison renders), a step of ExpZ(0.001, 1) octaves on the stored value
   * times 127 (Tension's reading of the shared unison; 0.379 semitone at
   * 0.5 where the renders measure 0.374, an octave at 1 as Organ Vibrato
   * shows); the copies start ExpZ(0.002, 0.1) s apart */
  if (!d->played) d->first_age = d->age;
  v->lv = lv_pick(d);
  d->lv_last = v->lv;
  d->lv_steal = -1;
  /* fit: a mono voice's vibrato runs on through the silence between its
   * notes, from the device's start (segno-analog-fit6 Square Pure Bass's
   * median pitch error from 0.38 to 0.04 cent, Saw Detune Sync Lead's from
   * 12.0 to 2.8); a poly voice's starts at 0 with each note (Strings
   * Detuned Pad's triad, 5.5 cents off if it ran on) */
  if (mono(d)) {
    const double hz = (double)le_aas_lin(0.25f, 10.0f, vf(d, LE_ANALOG_VIBRATO_SPEED));
    const double ph = d->lv_used[v->lv] ? d->lv_vib[v->lv] + hz * (double)(d->age - d->lv_quiet[v->lv]) / (double)d->sample_rate
                                        : hz * (double)(d->age - d->first_age) / (double)d->sample_rate;
    v->vib_ph = ph - floor(ph);
  } else {
    v->vib_ph = 0.0;
  }
  static const float kSteps[LE_ANALOG_COPIES] = {0.0f, 1.0f, -1.0f, 2.0f};
  const float step = unison_expz(0.001f, 1.0f, vf(d, LE_ANALOG_UNISON_DETUNE));
  const float delay = unison_expz(0.002f, 0.1f, vf(d, LE_ANALOG_UNISON_DELAY)) * (float)d->sample_rate;
  for (int32_t k = 0; k < v->copies; ++k) {
    le_analog_copy* cp = &v->c[k];
    cp->detune = step * kSteps[k] + key_error(d, cp);
    /* fit: copy k starts k delays after the note (uni4-dly-100's copies
     * enter at 0.1, 0.2 and 0.3 s; its level from 5.4 dB low to 0.7), and
     * its release comes as late. It starts ahead of a copy begun at that
     * moment, by four times its own pitch over the delay and 13 samples
     * (segno-analog-fit8: separating the ud8 sines' copies puts copy k at
     * 4 (k D) / P cycles, D from 2.9 to 100 ms; the ud8 sines from 5 to 20
     * dB to 0.2 to 3, the saws from 8 to 0.3 to 1.6) */
    cp->delay = (int32_t)(delay * (float)k);
    cp->rel_at = -1;
    for (int32_t c = 0; c < 2; ++c) cp->ch[c].ph_lead = cp->delay > 0 ? (float)cp->delay + 13.0f : 0.0f;
    start_copy(d, v, cp);
  }
  d->last_pitch = v->pitch_to;
  d->played = 1;
  d->lv_used[v->lv] = 1;
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

static void release_copy(le_analog* d, le_analog_voice* v, int32_t k) {
  const float rate = (float)d->sample_rate;
  v->c[k].rel_at = -1;
  {
    for (int32_t c = 0; c < 2; ++c) {
      const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
      const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
      /* fit: a free-running envelope ignores the gate's end: it runs its
       * attack and decay, then releases (Zap's mono triad, whose key-up
       * hands the voice on and retriggers it after its keys are up) */
      if (!fe.free_run) le_aas_env_release(&v->c[k].ch[c].fenv, &fe, v->velocity, rate);
      if (!ae.free_run) le_aas_env_release(&v->c[k].ch[c].aenv, &ae, v->velocity, rate);
    }
  }
}

/* The gate's end: a delayed copy releases as many samples later as it
 * started (fit: segno-analog-fit8's ud8 renders, whose second copy rings
 * on for its delay after the note-off). */
static void release_voice(le_analog* d, le_analog_voice* v) {
  v->state = LE_ANALOG_VOICE_RELEASED;
  for (int32_t k = 0; k < v->copies; ++k) {
    if (v->c[k].delay > 0) v->c[k].rel_at = v->since + v->c[k].delay;
    else release_copy(d, v, k);
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
  d->lv_steal = -1;
  d->lv_last = -1;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) d->voices[i].lv = -1;
  bl_init(d);
  for (int32_t p = 0; p < LE_ANALOG_PARAMS; ++p) d->values[p] = param_def(p).def;
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    for (int32_t k = 0; k < LE_ANALOG_COPIES; ++k) {
      d->voices[i].c[k].rng = 0x9e3779b9u ^ (uint32_t)((i * LE_ANALOG_COPIES + k + 1) * 2654435761u);
      for (int32_t c = 0; c < 2; ++c) d->voices[i].c[k].ch[c].fenv.seg = d->voices[i].c[k].ch[c].aenv.seg = LE_AAS_SEG_IDLE;
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
      /* fit: in Const mode, keys that arrive with the key that started or
       * took back the voice do not glide when that key did not (Muted Dark
       * Bass's triads, on a fresh and on a releasing voice, land on their
       * last key at once); in Prop mode they glide (Dual OSC Buzz Octaves
       * Bass's) */
      if (!was_held) {
        v->keyed_at = d->age;
        v->glided = glide;
      }
      if (!glide || (was_held && v->keyed_at == d->age && !v->glided && !vi(d, LE_ANALOG_GLIDE_MODE))) {
        v->pitch = v->pitch_to;
      }
      v->state = LE_ANALOG_VOICE_HELD;
      for (int32_t k = 0; k < v->copies; ++k) {
        v->c[k].rel_at = -1;
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &v->c[k].ch[c];
          const int fleg = overlapping && was_held && ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO);
          const int aleg = overlapping && was_held && ci(d, c, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO);
          const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
          const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
          if (!fleg) le_aas_env_drop(&ch->fenv, &fe, vel, (float)d->sample_rate);
          if (!aleg) le_aas_env_drop(&ch->aenv, &ae, vel, (float)d->sample_rate);
          if (!aleg) {
            ch->penv = 1.0f; /* the pitch envelope restarts with the amp's */
            lfo_restart(d, &v->c[k], c);
          }
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
    d->lv_steal = v->lv;
    lv_store(d, v, d->age);
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
      const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
      const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
      if (!ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO)) le_aas_env_drop(&ch->fenv, &fe, v->velocity, (float)d->sample_rate);
      if (!ci(d, c, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO)) {
        le_aas_env_drop(&ch->aenv, &ae, v->velocity, (float)d->sample_rate);
        ch->penv = 1.0f;
        lfo_restart(d, &v->c[k], c);
      }
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
  value = le_aas_clamp(value, lo, 1.0f);
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

static void tick_chain(le_analog* d, le_analog_voice* v, le_analog_copy* cp, int32_t c,
                       float pitch_cv, float vib, av_tick* t, float f1_fc) {
  const float rate = (float)d->sample_rate;
  le_analog_chain* ch = &cp->ch[c];
  const float dt = (float)LE_ANALOG_TICK / rate;
  /* the LFO, scaled by its delay and fade */
  float lfo = 0.0f;
  if (ci(d, c, LE_ANALOG_LFO_ON)) {
    const float hz = lfo_hz(d, c);
    const float w = 0.05f + 0.9f * le_aas_knob(cf(d, c, LE_ANALOG_LFO_PW));
    const double before = ch->lfo_ph;
    ch->lfo_ph += (double)(hz * dt);
    if (ch->lfo_ph >= 1.0) {
      ch->lfo_ph -= floor(ch->lfo_ph);
      ch->lfo_sh_prev = ch->lfo_sh;
      ch->lfo_sh = le_aas_bipolar(&cp->rng);
    }
    const int32_t wave = ci(d, c, LE_ANALOG_LFO_WAVE);
    float y = le_aas_lfo_shape(wave, before, w, ch->lfo_sh, ch->lfo_sh_prev);
    if (ch->lfo_wait > 0.0f) {
      ch->lfo_wait -= dt;
      y = 0.0f;
    } else if (ch->lfo_amp < 1.0f) {
      const float fade = le_aas_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_FADE));
      ch->lfo_amp = fminf(ch->lfo_amp + dt / fade, 1.0f);
    }
    lfo = y * ch->lfo_amp;
  }
  ch->lfo = lfo;
  /* the oscillator's pitch */
  const float det = le_aas_knob(cf(d, c, LE_ANALOG_OSC_DETUNE)) * 127.0f / 64.0f - 1.0f;
  const float base = (float)ci(d, c, LE_ANALOG_OSC_OCT) + (float)ci(d, c, LE_ANALOG_OSC_SEMI) / 12.0f +
                     (det < 0.0f ? -0.25f : 0.25f) * det * det;
  const float m1 = le_aas_knob(cf(d, c, LE_ANALOG_OSC_MOD1)) * 127.0f / 64.0f;
  const float k1 = m1 * m1;
  const float env_amt = cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT) != 0.0f
                            ? (cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT) < 0.0f ? -1.0f : 1.0f) *
                                  le_aas_exp(0.01f, 6.0f, fabsf(cf(d, c, LE_ANALOG_OSC_ENV_AMOUNT)))
                            : 0.0f;
  const float lfo_pitch = le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_OSC_LFO_PITCH)) * lfo;
  const float key = le_aas_clamp(pitch_cv + cp->detune + vib, -8.0f, 8.0f);
  const float sync = ci(d, c, LE_ANALOG_OSC_MODE) == 1 && ci(d, c, LE_ANALOG_OSC_SHAPE) != 0;
  /* fit: the keyboard pitch (with the unison offsets and the vibrato) and
   * the pitch envelope go through the cubic 2^x, the oscillator's own
   * octave, semitone and detune and the LFO through exact ones (a mono G4
   * sits 1.16 cents sharp of a C4's fifth, as the cubic puts it, the poly
   * chord's E4 and G4 too; the unison renders' lower copy 0.3 cent sharp;
   * the LFO renders fit closer with the LFO exact) */
  const float f_base = AV_C4 * exp2f(base);
  const float f_key = f_base * exp2_cubic(k1 * key);
  /* the oscillator's own tick turns these into its period (osc_pitch) */
  t->env_amt = env_amt;
  if (sync) {
    t->ratio = le_aas_exp(1.0f, 20.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    ch->inc_m = fminf(f_key, 0.25f * rate) / rate;
    t->f_osc = f_key * t->ratio * exp2f(lfo_pitch);
    t->x_osc = 0.0f;
    t->f_lo = f_key;
    t->f_hi = 0.45f * rate;
    t->sub = 0.0f;
  } else {
    t->f_osc = f_base * exp2f(lfo_pitch);
    t->x_osc = k1 * key;
    /* the saw and rectangle stop at a quarter of the rate (their 4-sample
     * period); fit: the sine goes on to 16 kHz and beyond (penv-1-t04's
     * 3-sample periods) */
    t->f_lo = 0.0f;
    t->f_hi = (ci(d, c, LE_ANALOG_OSC_SHAPE) == 0 ? 0.45f : 0.25f) * rate;
    /* the knob is the sub's level only in Sub mode: a sine set to Sync has
     * neither (fit: segno-analog-fit4 Soft Morning Keys with amp 1 off,
     * from 3.9 to 0.2 dB; its sine's Sync mode left a sub 10 dB loud) */
    const float s = le_aas_exp(0.01f, 1.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    t->sub = s <= 0.0101f || ci(d, c, LE_ANALOG_OSC_MODE) == 1 ? 0.0f : s;
    t->ratio = 0.0f; /* no sync */
  }
  /* the pulse width, folded into its range, then the LFO */
  float pw = 0.0365f + 0.4635f * le_aas_knob(cf(d, c, LE_ANALOG_OSC_PW));
  pw *= 1.0f + 0.8f * le_aas_bsq(1.0f, cf(d, c, LE_ANALOG_OSC_LFO_PW)) * lfo;
  t->pw = le_aas_clamp(pw, 0.02f, 0.98f);
  /* the routing: equal power into the two filters */
  const float lvl = ci(d, c, LE_ANALOG_OSC_ON) ? le_aas_exp(0.01f, 3.0f, cf(d, c, LE_ANALOG_OSC_LEVEL)) : 0.0f;
  /* fit: the stored balance runs from filter 2 (0) to filter 1 (1) (the
   * routing renders; the factory presets store osc 1 at 1, osc 2 at 0) */
  const float bal = le_aas_knob(cf(d, c, LE_ANALOG_OSC_BALANCE));
  t->to_f1 = lvl * sinf(0.5f * LE_AAS_PI * bal);
  t->to_f2 = lvl * cosf(0.5f * LE_AAS_PI * bal);
  /* the filter */
  const float fenv = ch->fenv.y;
  const float e_cut = le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_FILTER_KEY_CUTOFF)) * (pitch_cv + vib) +
                      le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_FILTER_LFO_CUTOFF)) * lfo +
                      le_aas_bq4(16.0f, cf(d, c, LE_ANALOG_FILTER_ENV_CUTOFF)) * fenv;
  float fc;
  if (c == 1 && ci(d, 1, LE_ANALOG_CHAIN_LINK)) {
    /* filter 2 follows filter 1, its knob a ratio of +-2 octaves */
    fc = f1_fc * exp2f(le_aas_knob(cf(d, 1, LE_ANALOG_FILTER_CUTOFF)) * 127.0f / 32.0f - 2.0f) * exp2f(e_cut);
  } else {
    fc = le_aas_exp(30.0f, 22000.0f, cf(d, c, LE_ANALOG_FILTER_CUTOFF)) * exp2f(e_cut);
  }
  fc = fmaxf(fc, 20.0f);
  ch->fc = fc;
  const float e_q = le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_FILTER_KEY_Q)) * pitch_cv +
                    le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_FILTER_LFO_Q)) * lfo +
                    le_aas_bsq(4.0f, cf(d, c, LE_ANALOG_FILTER_ENV_Q)) * fenv;
  t->q = le_aas_exp(0.1f, 120.0f, cf(d, c, LE_ANALOG_FILTER_Q)) * exp2f(e_q); /* each stage clamps its own */
  t->fc = fminf(fmaxf(fc, 10.0f), 0.49f * rate);
  if (ci(d, c, LE_ANALOG_FILTER_TYPE) >= 8) {
    le_aas_formant_set(&ch->f, ci(d, c, LE_ANALOG_FILTER_TYPE), cf(d, c, LE_ANALOG_FILTER_CUTOFF),
                       cf(d, c, LE_ANALOG_FILTER_Q), e_cut, e_q, rate);
  }
  /* the amp: level, LFO, key (the envelope applies per sample); the pan.
   * fit: the LFO's depths on the level and the pan are linear in the knob
   * (the tremolo renders) */
  const float aenv = ch->aenv.y;
  float gain = 0.0f;
  if (ci(d, c, LE_ANALOG_AMP_ON)) {
    gain = le_aas_exp(0.01f, 2.0f, cf(d, c, LE_ANALOG_AMP_LEVEL)) *
           (1.0f + le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_VOL)) * lfo) *
           expf(le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_VOL)) * v->pitch);
  }
  /* fit: the pan is the knob position on the 0..127 scale like the other
   * knobs (0.5 sits at 64/127, 0.4 % right of centre, below what the pan
   * renders can show); the near-centre pans of Thick Chord Pad, Saw Detune
   * Sync Lead and Saw Pure Brass need it */
  const float p = le_aas_knob(cf(d, c, LE_ANALOG_AMP_PAN));
  const float pm = le_aas_clamp(le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_PAN)) * v->pitch, -1.0f, 1.0f) +
                   le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_ENV_PAN)) * aenv +
                   le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_PAN)) * lfo;
  /* fit: the modulated position is not clamped: past an edge the pan's
   * angle runs on, the far channel's gain turning negative (segno-analog-
   * fit4 Soft Morning Keys with amp 1 off, whose envelope and LFO pans add
   * to 1.35: from 3.7 to 0.4 dB, its attack from 16.1 to 0.9, stereo from
   * 1.0 to 0.15; clamping silenced the left channel where Live's stays 27
   * dB down, and folding back gave the levels but not the side signal) */
  const float pp = p < 0.5f ? p + p * pm : p + pm * (1.0f - p);
  const float gl = gain * cosf(0.5f * LE_AAS_PI * pp), gr = gain * sinf(0.5f * LE_AAS_PI * pp);
  if (ch->g_fresh) {
    ch->g_fresh = 0;
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

/* The oscillator's pitch, on its own tick of AV_OSC_TICK samples: at each
 * tick the period's target from the chain's control values and the pitch
 * envelope's value at the tick's end, the period ramping to it linearly
 * across the tick. A copy's first tick ramps from the period without the
 * pitch envelope. fit: the pitch envelope renders (penv-1-t015's zero
 * crossings within 3 samples and its tail's phase, penv-1-t04's and
 * penv-saw-1-t03's sweeps) */
static void osc_pitch(le_analog_chain* ch, const av_tick* t, float rate) {
  if (ch->otick <= 0) {
    const float e = fmaxf(ch->penv - ch->penv_step * (float)AV_OSC_TICK, 0.0f);
    const float target = rate / le_aas_clamp(t->f_osc * exp2_cubic(t->x_osc + t->env_amt * e), t->f_lo, t->f_hi);
    if (ch->per <= 0.0f) {
      ch->per = rate / le_aas_clamp(t->f_osc * exp2_cubic(t->x_osc), t->f_lo, t->f_hi);
      if (ch->ph_lead > 0.0f) {
        /* a delayed copy's lead (start_voice); a sine's sub at half */
        const double a = 4.0 * (double)ch->ph_lead / (double)ch->per;
        ch->ph += a - floor(a);
        ch->ph -= floor(ch->ph);
        if (t->ratio <= 0.0f) {
          ch->ph2 += 0.5 * a;
          ch->ph2 -= floor(ch->ph2);
        }
        ch->ph_lead = 0.0f;
      }
    }
    ch->per_step = (target - ch->per) / (float)AV_OSC_TICK;
    ch->penv = e;
    ch->otick = AV_OSC_TICK;
  }
  ch->per += ch->per_step;
  ch->otick--;
  ch->inc = 1.0f / ch->per;
}

/* One oscillator sample, LE_ANALOG_BL_HALF samples late as Live's are:
 * the shape at the chain's phase, its sub square or its sync slave; saw and
 * rectangle peak-to-peak 1, the sine 0.7. */
static float osc_tick(const le_analog* d, le_analog_chain* ch, int32_t shape, const av_tick* t, uint32_t* rng) {
  float y;
  if (shape != 3) osc_pitch(ch, t, (float)d->sample_rate);
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
      y = 0.9f * le_aas_bipolar(rng);
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

static void render_voice(le_analog* d, le_analog_voice* v, float* left, float* right, int32_t frames) {
  const float rate = (float)d->sample_rate;
  /* fit: the bundle's x4 does not reach Live's output (the level renders) */
  const float out_gain = le_aas_sq(0.0f, 2.0f, vf(d, LE_ANALOG_VOLUME));
  const float fade_step = 1.0f / (float)(LE_ANALOG_FADE_MS * v->fade_len);
  const int32_t ramp_len = d->sample_rate / 441 > 1 ? d->sample_rate / 441 : 1;
  const int noise_on = vi(d, LE_ANALOG_NOISE_ON);
  const float noise_lvl = noise_on ? le_aas_exp(0.01f, 3.0f, vf(d, LE_ANALOG_NOISE_LEVEL)) : 0.0f;
  const float noise_bal = le_aas_knob(vf(d, LE_ANALOG_NOISE_BALANCE));
  const float noise_a = fminf(2.0f * LE_AAS_PI * le_aas_exp(20.0f, 22000.0f, vf(d, LE_ANALOG_NOISE_COLOR)) / rate, 1.0f);
  int32_t i = 0;
  while (i < frames && v->state != LE_ANALOG_VOICE_FREE) {
    if (v->tick_left == 0) {
      /* glide, vibrato, bend: the voice's pitch */
      if (vi(d, LE_ANALOG_GLIDE_ON) && v->pitch != v->pitch_to) {
        float T = glide_seconds(d);
        if (vi(d, LE_ANALOG_GLIDE_MODE)) T *= sqrtf(fabsf(v->pitch_to - v->pitch));
        const float a = fminf(2.0f * LE_AAS_PI / (fmaxf(T, 1e-4f) * rate), 1.0f);
        v->pitch = v->pitch_to + (v->pitch - v->pitch_to) * powf(1.0f - a, (float)LE_ANALOG_TICK);
        if (fabsf(v->pitch - v->pitch_to) < 1e-5f) v->pitch = v->pitch_to;
      } else {
        v->pitch = v->pitch_to;
      }
      float vib = 0.0f;
      const float dtk = (float)LE_ANALOG_TICK / rate;
      v->vib_t += dtk;
      if (vi(d, LE_ANALOG_VIBRATO_ON)) {
        /* the rate, off by up to Error = Lin(0, 0.2) of it, a new draw each
         * cycle */
        const float hz = le_aas_clamp(le_aas_lin(0.25f, 10.0f, vf(d, LE_ANALOG_VIBRATO_SPEED)) * (1.0f + v->vib_dev), 0.1f, 15.0f);
        float depth = (vf(d, LE_ANALOG_VIBRATO_AMOUNT) > 0.0f
                           ? le_aas_exp(0.0002f, 1.0f / 6.0f, vf(d, LE_ANALOG_VIBRATO_AMOUNT))
                           : 0.0f) +
                      d->mod * (vf(d, LE_ANALOG_VIBRATO_WHEEL) > 0.0f
                                    ? le_aas_exp(0.0002f, 1.0f / 6.0f, vf(d, LE_ANALOG_VIBRATO_WHEEL))
                                    : 0.0f);
        const float delay =
            vf(d, LE_ANALOG_VIBRATO_DELAY) > 0.0f ? le_aas_exp(0.05f, 5.0f, vf(d, LE_ANALOG_VIBRATO_DELAY)) : 0.0f;
        const float fade =
            vf(d, LE_ANALOG_VIBRATO_FADE) > 0.0f ? le_aas_exp(0.05f, 5.0f, vf(d, LE_ANALOG_VIBRATO_FADE)) : 0.0f;
        if (v->vib_t < delay) depth = 0.0f;
        else if (fade > 0.0f) depth *= fminf((v->vib_t - delay) / fade, 1.0f);
        v->vib_ph += (double)(hz * dtk);
        if (v->vib_ph >= 1.0) {
          v->vib_ph -= floor(v->vib_ph);
          v->vib_dev = le_aas_lin(0.0f, 0.2f, vf(d, LE_ANALOG_VIBRATO_ERROR)) * le_aas_bipolar(&v->c[0].rng);
        }
        vib = depth * sinf(2.0f * LE_AAS_PI * (float)v->vib_ph);
      }
      const float pitch_cv = v->pitch + vf(d, LE_ANALOG_BEND_RANGE) * d->bend;
      for (int32_t k = 0; k < v->copies; ++k) {
        le_analog_copy* cp = &v->c[k];
        tick_chain(d, v, cp, 0, pitch_cv, vib, &cp->ch[0].t, 0.0f);
        tick_chain(d, v, cp, 1, pitch_cv, vib, &cp->ch[1].t, cp->ch[0].fc);
        cp->ch[0].t.link = le_aas_knob(cf(d, 0, LE_ANALOG_CHAIN_LINK));
        cp->ch[0].t.link = 2.0f * cp->ch[0].t.link * cp->ch[0].t.link;
        for (int32_t c = 0; c < 2; ++c) {
          const float q = cp->ch[c].t.q;
          const int32_t ft = ci(d, c, LE_ANALOG_FILTER_TYPE);
          if (ft < 8) le_aas_filter_set(&cp->ch[c].f, ft, cp->ch[c].t.fc, q, rate);
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
      int held = v->state == LE_ANALOG_VOICE_HELD || v->state == LE_ANALOG_VOICE_SUSTAINED || cp->rel_at >= 0;
      le_aas_env_set fe[2], ae[2];
      for (int32_t c = 0; c < 2; ++c) {
        fe[c] = read_env(d, c, LE_ANALOG_FILTER_ENV);
        ae[c] = read_env(d, c, LE_ANALOG_AMP_ENV);
      }
      for (int32_t s = s0; s < n; ++s) {
        float pre[2] = {0.0f, 0.0f};
        if (cp->rel_at >= 0 && v->since + s >= cp->rel_at) {
          release_copy(d, v, k);
          held = 0;
        }

        /* fit: the amps' gain smoothing starts from 0 when the device
         * starts and reaches its value over the first control period, rate
         * / 441 samples: a note at the very start rises with it (the attack
         * renders: the gain is the envelope times that ramp), later notes
         * do not (the event renders' and held-out notes' onsets) */
        const int32_t age = d->age + i + s;
        const float ramp = age >= ramp_len ? 1.0f : (float)age / (float)ramp_len;
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &cp->ch[c];
          (void)le_aas_env_tick(&ch->fenv, &fe[c], held, v->velocity, rate);
          (void)le_aas_env_tick(&ch->aenv, &ae[c], held, v->velocity, rate);
          if (ci(d, c, LE_ANALOG_OSC_ON)) {
            const float o = osc_tick(d, ch, ci(d, c, LE_ANALOG_OSC_SHAPE), &cp->ch[c].t, &cp->rng);
            pre[0] += cp->ch[c].t.to_f1 * o;
            pre[1] += cp->ch[c].t.to_f2 * o;
          }
        }
        if (noise_on) {
          cp->noise_lp += noise_a * (0.9f * le_aas_bipolar(&cp->rng) - cp->noise_lp);
          /* fit: the noise comes out as late as the oscillators (Zap's and
           * the noise renders' onsets) */
          cp->noise_ring[cp->noise_at] = cp->noise_lp;
          const float nz = cp->noise_ring[(cp->noise_at - LE_ANALOG_BL_HALF) & (LE_ANALOG_BL_RING - 1)];
          cp->noise_at = (cp->noise_at + 1) & (LE_ANALOG_BL_RING - 1);
          pre[0] += noise_lvl * sinf(0.5f * LE_AAS_PI * noise_bal) * nz;
          pre[1] += noise_lvl * cosf(0.5f * LE_AAS_PI * noise_bal) * nz;
        }
        float l = 0.0f, r = 0.0f, y1 = 0.0f;
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &cp->ch[c];
          float x = pre[c] + (c == 1 ? cp->ch[0].t.link * y1 : 0.0f);
          if (ci(d, c, LE_ANALOG_FILTER_ON)) {
            const int32_t ft = ci(d, c, LE_ANALOG_FILTER_TYPE);
            x = le_aas_filter_tick(&ch->f, ft, x);
            x = le_aas_drive(x, ci(d, c, LE_ANALOG_FILTER_DRIVE));
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
        if (ch->aenv.seg != LE_AAS_SEG_IDLE && ci(d, c, LE_ANALOG_AMP_ON)) idle = 0;
      }
    }
    v->tick_left -= n;
    if (v->state == LE_ANALOG_VOICE_FADING) {
      v->fade_left -= n;
      if (v->fade_left <= 0) v->state = LE_ANALOG_VOICE_FREE;
    } else if (idle && v->tick_left == 0 && v->state != LE_ANALOG_VOICE_HELD) {
      /* on a tick's edge, so in any block size */
      v->state = LE_ANALOG_VOICE_FREE;
      lv_store(d, v, d->age + i + n);
    }
    if (v->since < (1 << 30)) v->since += n; /* only the copies' delays read it */
    i += n;
  }
}

void le_analog_render(le_analog* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  memset(right, 0, sizeof(float) * (size_t)frames);
  lv_run_on(d, frames);
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    le_analog_voice* v = &d->voices[i];
    if (v->state != LE_ANALOG_VOICE_FREE) render_voice(d, v, left, right, frames);
  }
  if (d->age < (1 << 30)) d->age += frames;
}
