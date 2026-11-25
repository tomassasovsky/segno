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

#define AV_C4 261.6256f

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

/* The engine's sine: a quintic on the phase in [0, 1) that meets sin(2 pi x)
 * at the quarter points, its small error a faint series of partials. */
static float av_sine(double ph) {
  const float x = (float)(ph - floor(ph));
  return x * (6.094263f + x * (6.094263f + x * (-85.31969f + x * (121.88526f - 48.754105f * x))));
}

/* ---- band-limited steps ---- */

static float blep(double ph, double edge, float dt) {
  double dd = ph - edge;
  if (dd < -0.5) dd += 1.0;
  if (dd >= 0.5) dd -= 1.0;
  const float t = (float)(dd / dt);
  if (t >= 1.0f || t <= -1.0f) return 0.0f;
  if (t >= 0.0f) {
    const float u = 1.0f - t;
    return -0.5f * u * u;
  }
  const float u = 1.0f + t;
  return 0.5f * u * u;
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

/* The keyboard pitch of `note` in octaves from C4: transpose, octave and
 * fine tune included. */
static float key_pitch(const le_analog* d, int32_t note) {
  const float fine = (vf(d, LE_ANALOG_FINE_TUNE) - 0.5f) * 2.0f / 12.0f;
  return ((float)(note - 60) + (float)vi(d, LE_ANALOG_TRANSPOSE)) / 12.0f +
         (float)vi(d, LE_ANALOG_OCTAVE) + fine;
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

/* A copy starts from rest: its filters, the integrator's leak and the
 * noise filter cleared, so nothing of the slot's last note rings on. */
static void start_copy(le_analog* d, le_analog_voice* v, le_analog_copy* cp) {
  const float rate = (float)d->sample_rate;
  cp->noise_lp = 0.0f;
  for (int32_t c = 0; c < 2; ++c) {
    le_analog_chain* ch = &cp->ch[c];
    const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
    const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
    le_aas_env_start(&ch->fenv, &fe, v->velocity, rate, 0);
    le_aas_env_start(&ch->aenv, &ae, v->velocity, rate, 0);
    memset(ch->f.s, 0, sizeof(ch->f.s));
    ch->dc = 0.0f;
    ch->noise_lp = 0.0f;
    ch->penv = 1.0f;
    ch->penv_step = 1.0f / fmaxf(le_aas_exp(0.01f, 10.0f, cf(d, c, LE_ANALOG_OSC_ENV_TIME)) * rate, 1.0f);
    ch->ph = ch->ph2 = 0.0;
    ch->sub_sign = 1;
    if (ci(d, c, LE_ANALOG_LFO_GATE_RESET)) {
      ch->lfo_ph = cf(d, c, LE_ANALOG_LFO_PHASE);
    }
    /* fit: the random waves start from a random value, noise held there
     * for the first cycle (the lfo-wave renders) */
    ch->lfo_sh = ch->lfo_sh_prev = le_aas_bipolar(&cp->rng);
    ch->lfo_wait = le_aas_exp(0.2f, 5.0f, cf(d, c, LE_ANALOG_LFO_DELAY));
    if (cf(d, c, LE_ANALOG_LFO_DELAY) <= 0.0f) ch->lfo_wait = 0.0f;
    ch->lfo_amp = cf(d, c, LE_ANALOG_LFO_FADE) <= 0.0f ? 1.0f : 0.0f;
    ch->gl = ch->gr = -1.0f;
  }
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
      const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
      const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
      le_aas_env_release(&v->c[k].ch[c].fenv, &fe, v->velocity, rate);
      le_aas_env_release(&v->c[k].ch[c].aenv, &ae, v->velocity, rate);
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
      if (!glide) v->pitch = v->pitch_to;
      v->state = LE_ANALOG_VOICE_HELD;
      for (int32_t k = 0; k < v->copies; ++k) {
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &v->c[k].ch[c];
          const int fleg = overlapping && was_held && ci(d, c, LE_ANALOG_FILTER_ENV + LE_ANALOG_ENV_LEGATO);
          const int aleg = overlapping && was_held && ci(d, c, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO);
          const le_aas_env_set fe = read_env(d, c, LE_ANALOG_FILTER_ENV);
          const le_aas_env_set ae = read_env(d, c, LE_ANALOG_AMP_ENV);
          if (!fleg) le_aas_env_start(&ch->fenv, &fe, vel, (float)d->sample_rate, 1);
          if (!aleg) le_aas_env_start(&ch->aenv, &ae, vel, (float)d->sample_rate, 1);
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

/* A held voice whose key is up: in mono it moves to the held key the
 * priority picks, otherwise it is let go. */
static void key_up(le_analog* d, le_analog_voice* v) {
  if (mono(d) && d->held_n > 0) {
    const int32_t pi = priority_index(d);
    v->note = d->held_note[pi];
    v->origin = d->held_origin[pi];
    v->pitch_to = key_pitch(d, v->note);
    if (!vi(d, LE_ANALOG_GLIDE_ON)) v->pitch = v->pitch_to;
    d->last_pitch = v->pitch_to;
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
    float hz;
    if (ci(d, c, LE_ANALOG_LFO_SYNC_ON) && ci(d, c, LE_ANALOG_LFO_SYNC) > 0) {
      hz = d->bpm / 60.0f / le_aas_sync_beats(ci(d, c, LE_ANALOG_LFO_SYNC));
    } else {
      hz = le_aas_exp(3.0f, 1000.0f, cf(d, c, LE_ANALOG_LFO_SPEED)) / 60.0f;
    }
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
  const float f_key = AV_C4 * exp2f(base + k1 * key);
  if (sync) {
    t->ratio = le_aas_exp(1.0f, 20.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    ch->inc_m = fminf(f_key, 0.25f * rate) / rate;
    ch->inc = fminf(fmaxf(f_key * t->ratio * exp2f(lfo_pitch + env_amt * ch->penv), f_key), 0.45f * rate) / rate;
    t->sub = 0.0f;
  } else {
    const float f = f_key * exp2f(lfo_pitch + env_amt * ch->penv);
    ch->inc = fminf(f, 0.25f * rate) / rate;
    ch->inc_m = ch->inc;
    const float s = le_aas_exp(0.01f, 1.0f, cf(d, c, LE_ANALOG_OSC_SUB));
    t->sub = s <= 0.0101f ? 0.0f : s;
    t->ratio = 1.0f;
  }
  ch->penv = fmaxf(ch->penv - ch->penv_step * (float)LE_ANALOG_TICK, 0.0f);
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
  t->q = fminf(le_aas_exp(0.1f, 120.0f, cf(d, c, LE_ANALOG_FILTER_Q)) * exp2f(e_q), 100.0f);
  t->fc = fminf(fmaxf(fc, 10.0f), 0.49f * rate);
  if (ci(d, c, LE_ANALOG_FILTER_TYPE) >= 8) {
    le_aas_formant_set(&ch->f, ci(d, c, LE_ANALOG_FILTER_TYPE), cf(d, c, LE_ANALOG_FILTER_CUTOFF),
                       cf(d, c, LE_ANALOG_FILTER_Q), e_cut, e_q, rate);
  }
  /* the amp: level, envelope, LFO, key; the pan */
  const float aenv = ch->aenv.y;
  float gain = 0.0f;
  if (ci(d, c, LE_ANALOG_AMP_ON)) {
    gain = le_aas_exp(0.01f, 2.0f, cf(d, c, LE_ANALOG_AMP_LEVEL)) * aenv *
           (1.0f + le_aas_bsq(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_VOL)) * lfo) *
           expf(le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_VOL)) * v->pitch);
  }
  /* fit: the pan is its stored value, centred exactly at 0.5 (the pan
   * renders), not a 128-step knob position */
  const float p = le_aas_clamp(cf(d, c, LE_ANALOG_AMP_PAN), 0.0f, 1.0f);
  const float pm = le_aas_clamp(le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_KEY_PAN)) * v->pitch, -1.0f, 1.0f) +
                   le_aas_blin(1.0f, cf(d, c, LE_ANALOG_AMP_ENV_PAN)) * aenv +
                   le_aas_bsq(1.0f, cf(d, c, LE_ANALOG_AMP_LFO_PAN)) * lfo;
  const float pp = le_aas_clamp(p < 0.5f ? p + p * pm : p + pm * (1.0f - p), 0.0f, 1.0f);
  const float gl = gain * cosf(0.5f * LE_AAS_PI * pp), gr = gain * sinf(0.5f * LE_AAS_PI * pp);
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

/* One oscillator sample: the shape at the chain's phase, its sub square or
 * its sync slave; saw and rectangle peak-to-peak 1, the sine 0.7. */
static float osc_tick(le_analog_chain* ch, int32_t shape, const av_tick* t, uint32_t* rng) {
  const float dt = ch->inc;
  float y;
  switch (shape) {
    case 0: {
      y = 0.7f * av_sine(ch->ph);
      if (t->sub > 0.0f) y += 0.7f * t->sub * av_sine(ch->ph2);
      ch->ph += dt;
      if (ch->ph >= 1.0) ch->ph -= 1.0;
      ch->ph2 += 0.5 * dt;
      if (ch->ph2 >= 1.0) ch->ph2 -= 1.0;
      return y;
    }
    case 3:
      return 0.9f * le_aas_bipolar(rng);
    default:
      break;
  }
  const int sync = t->ratio > 1.0001f;
  if (sync) {
    /* the master resets the slave */
    ch->ph2 += ch->inc_m;
    if (ch->ph2 >= 1.0) {
      ch->ph2 -= 1.0;
      ch->ph = ch->ph2 * (double)(dt / ch->inc_m);
    }
  }
  const double ph = ch->ph;
  if (shape == 1) {
    y = (float)ph - 0.5f - blep(ph, 0.0, dt);
  } else {
    /* the rectangle keeps its DC (an almost lossless integrator) */
    const float w = t->pw;
    y = (ph < w ? -1.0f : 0.0f) - blep(ph, 0.0, dt) + blep(ph, w, dt);
  }
  if (t->sub > 0.0f) y += 0.5f * t->sub * (float)ch->sub_sign;
  ch->ph += dt;
  if (ch->ph >= 1.0) {
    ch->ph -= 1.0;
    ch->sub_sign = -ch->sub_sign;
  }
  /* the integrator's leak: the saw's 0.9995, the rectangle's 0.999995 */
  const float leak = shape == 1 ? 0.0005f : 0.000005f;
  ch->dc += leak * (y - ch->dc);
  return y - ch->dc;
}

static void render_voice(le_analog* d, le_analog_voice* v, float* left, float* right, int32_t frames) {
  const float rate = (float)d->sample_rate;
  /* fit: the bundle's x4 does not reach Live's output (the level renders) */
  const float out_gain = le_aas_sq(0.0f, 2.0f, vf(d, LE_ANALOG_VOLUME));
  const float fade_step = 1.0f / (float)(LE_ANALOG_FADE_MS * v->fade_len);
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
        const float hz = le_aas_lin(0.25f, 10.0f, vf(d, LE_ANALOG_VIBRATO_SPEED));
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
        v->vib_ph -= floor(v->vib_ph);
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
      const int held = v->state == LE_ANALOG_VOICE_HELD || v->state == LE_ANALOG_VOICE_SUSTAINED;
      le_aas_env_set fe[2], ae[2];
      for (int32_t c = 0; c < 2; ++c) {
        fe[c] = read_env(d, c, LE_ANALOG_FILTER_ENV);
        ae[c] = read_env(d, c, LE_ANALOG_AMP_ENV);
      }
      for (int32_t s = s0; s < n; ++s) {
        float pre[2] = {0.0f, 0.0f};
        for (int32_t c = 0; c < 2; ++c) {
          le_analog_chain* ch = &cp->ch[c];
          (void)le_aas_env_tick(&ch->fenv, &fe[c], held, v->velocity, rate);
          (void)le_aas_env_tick(&ch->aenv, &ae[c], held, v->velocity, rate);
          if (ci(d, c, LE_ANALOG_OSC_ON)) {
            const float o = osc_tick(ch, ci(d, c, LE_ANALOG_OSC_SHAPE), &cp->ch[c].t, &cp->rng);
            pre[0] += cp->ch[c].t.to_f1 * o;
            pre[1] += cp->ch[c].t.to_f2 * o;
          }
        }
        if (noise_on) {
          cp->noise_lp += noise_a * (0.9f * le_aas_bipolar(&cp->rng) - cp->noise_lp);
          pre[0] += noise_lvl * sinf(0.5f * LE_AAS_PI * noise_bal) * cp->noise_lp;
          pre[1] += noise_lvl * cosf(0.5f * LE_AAS_PI * noise_bal) * cp->noise_lp;
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
        if ((ch->aenv.seg != LE_AAS_SEG_IDLE && ci(d, c, LE_ANALOG_AMP_ON)) || fabsf(ch->gl) > 1e-6f || fabsf(ch->gr) > 1e-6f) idle = 0;
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
