/*
 * synth_voice.c — the instrument voice pool (#1197 Part 1). See synth_voice.h.
 *
 * Voice models follow the accepted prototype's synthVoice
 * (docs/design/instrument-runtime.js, main checkout):
 *   - melodic: the patch wave at the note, a second partial at `ratio` (sine
 *     for sine patches, else triangle) whose level follows the character,
 *     a third partial at 4x for organs, a 5.4x partial for bells; a low-pass
 *     at 180 * 70^(brightness/100) Hz; a linear attack (8 ms, or the attack
 *     parameter for Synths and Strings) to 0.5 * velocity, then an
 *     exponential fall to `level` of that (transient patches, over the decay)
 *     or to 0.8 of it (over 0.4 s); a 5 Hz LFO (5.8 for organs) driving
 *     vibrato (Strings) and tremolo (organ rotary, Percussion tremolo);
 *   - drums: GM 35/36 kick (sine 135 -> 47 Hz, or 180 -> 38 Hz electronic,
 *     over half the hit), 38/40 snare, 39 clap, 42/44 closed hat (noise plus a
 *     triangle, high-passed); an exponential fall to 1e-4 over the hit, then
 *     the voice ends. Drums ignore note-off. Their level is the prototype's
 *     times LE_SYNTH_DRUM_HEADROOM, so one hit stays under full scale.
 * The release falls exponentially with a time constant of release / 5 toward
 * a point just below zero, so it reaches exactly zero at the release time and
 * the voice ends there: no tail to cut, no click.
 */
#include "synth_voice.h"

#include <math.h>
#include <string.h>

#define LE_SYNTH_PI 3.14159265358979f
/* The prototype's drum level puts a single electronic snare at 1.15 of full
 * scale; this keeps every single hit below it (0.98 at most) with the same
 * balance between the pieces. */
#define LE_SYNTH_DRUM_HEADROOM 0.85f

enum {
  LE_SYNTH_VOICE_FREE = 0,
  LE_SYNTH_VOICE_HELD = 1,
  LE_SYNTH_VOICE_RELEASED = 2,
  LE_SYNTH_VOICE_FADING = 3,
};

enum {
  STAGE_ATTACK = 0,
  STAGE_DECAY = 1,
  STAGE_SUSTAIN = 2,
  STAGE_RELEASE = 3,
};

enum {
  LE_SYNTH_DRUM_KICK = 1,
  LE_SYNTH_DRUM_SNARE = 2,
  LE_SYNTH_DRUM_HAT = 3,
  LE_SYNTH_DRUM_CLAP = 4,
};

/* What each family parameter does in the voice. -1: the family has none and
 * the prototype's fallback applies. */
enum {
  R_BRIGHT,
  R_CHARACTER,
  R_PUNCH,
  R_VIBRATO,
  R_TREMOLO,
  R_DECAY,
  R_RELEASE,
  R_ATTACK,
  R_BODY,
  R_COUNT
};

static const int8_t k_roles[LE_SYNTH_FAMILIES][R_COUNT] = {
    /*            bright char punch vib trem decay rel att body */
    /* Keys */ {0, 2, -1, -1, -1, 1, -1, -1, -1},
    /* Organs */ {-1, 0, -1, -1, 1, -1, 2, -1, -1},
    /* Synths */ {0, -1, -1, -1, -1, -1, 2, 1, -1},
    /* Bass */ {0, -1, 1, -1, -1, -1, 2, -1, -1},
    /* Strings */ {0, -1, -1, 2, -1, -1, -1, 1, -1},
    /* Drums */ {0, -1, -1, -1, -1, 1, -1, -1, 2},
    /* Percussion */ {0, 0, -1, -1, 2, 1, -1, -1, -1},
};

static float role(const float* params, int32_t family, int32_t r,
                  float fallback) {
  const int32_t i = k_roles[family][r];
  return i < 0 ? fallback : params[i];
}

/* The prototype's decay/release and attack mappings (synth_patch.c). */
static float seconds_of(float v) { return 0.08f + v / 100.0f * 2.4f; }
static float attack_of(float v) { return 0.008f + v / 100.0f * 0.9f; }

static int32_t frames_of(float seconds, int32_t sr) {
  const int32_t n = (int32_t)(seconds * (float)sr + 0.5f);
  return n < 1 ? 1 : n;
}

static float sine_at(const le_synth* s, float phase) {
  const float x = phase * (float)LE_SYNTH_SINE_SIZE;
  int32_t i = (int32_t)x;
  if (i >= LE_SYNTH_SINE_SIZE) i = LE_SYNTH_SINE_SIZE - 1;
  const float f = x - (float)i;
  return s->sine[i] + f * (s->sine[i + 1] - s->sine[i]);
}

static float blep(float t, float dt) {
  if (t < dt) {
    t /= dt;
    return t + t - t * t - 1.0f;
  }
  if (t > 1.0f - dt) {
    t = (t - 1.0f) / dt;
    return t * t + t + t + 1.0f;
  }
  return 0.0f;
}

static float osc(const le_synth* s, le_synth_voice* v, int32_t p) {
  const float t = v->phase[p];
  const float dt = v->inc[p];
  switch (v->wave[p]) {
    case LE_SYNTH_WAVE_SINE:
      return sine_at(s, t);
    case LE_SYNTH_WAVE_TRIANGLE:
      return 1.0f - 4.0f * fabsf(t - 0.5f);
    case LE_SYNTH_WAVE_SAW:
      return 2.0f * t - 1.0f - blep(t, dt);
    case LE_SYNTH_WAVE_SQUARE: {
      float t2 = t + 0.5f;
      if (t2 >= 1.0f) t2 -= 1.0f;
      return (t < 0.5f ? 1.0f : -1.0f) + blep(t, dt) - blep(t2, dt);
    }
    default: {
      uint32_t x = v->noise;
      x ^= x << 13;
      x ^= x >> 17;
      x ^= x << 5;
      v->noise = x;
      return (float)(x >> 8) / 8388608.0f - 1.0f;
    }
  }
}

static const float* inst_params(const le_synth* s, const le_synth_voice* v) {
  return s->inst[v->inst].params;
}

/* Control-rate update: pitch modulation, partial levels, filter, tremolo.
 * `start` places the amplitude at its target instead of ramping to it. */
static void voice_ctrl(const le_synth* s, le_synth_voice* v, int start) {
  const le_synth_patch* p = le_synth_patch_at(v->patch);
  const int32_t fam = p->family;
  const float* prm = inst_params(s, v);
  const float sr = (float)s->sample_rate;

  const float lfo = sine_at(s, v->lfo_phase);
  v->lfo_phase += (fam == LE_SYNTH_ORGANS ? 5.8f : 5.0f) *
                  (float)LE_SYNTH_CTRL_FRAMES / sr;
  if (v->lfo_phase >= 1.0f) v->lfo_phase -= 1.0f;

  if (!v->drum) {
    const float cents = lfo * role(prm, fam, R_VIBRATO, 0.0f) * 0.35f;
    const float pm = exp2f(cents / 1200.0f);
    const float character = role(prm, fam, R_CHARACTER, 35.0f) / 100.0f;
    v->gain[0] = 0.62f;
    v->gain[1] = 0.03f + character * 0.34f;
    if (fam == LE_SYNTH_ORGANS) v->gain[2] = character * 0.22f;
    if (p->extra_partial) v->gain[v->partials - 1] = 0.12f;
    for (int32_t i = 0; i < v->partials; ++i) {
      v->inc[i] = v->hz * v->mult[i] * pm / sr;
      if (v->inc[i] >= 0.45f) { /* at or above Nyquist: silent */
        v->inc[i] = 0.0f;
        v->gain[i] = 0.0f;
      }
    }
  }

  const float bright = role(prm, fam, R_BRIGHT, 65.0f);
  float fc;
  if (v->drum && v->drum != LE_SYNTH_DRUM_KICK) {
    fc = 300.0f + bright * (v->drum == LE_SYNTH_DRUM_HAT ? 85.0f : 22.0f);
  } else {
    fc = 180.0f * powf(70.0f, bright / 100.0f);
  }
  if (fc > 19000.0f) fc = 19000.0f;
  if (fc > 0.45f * sr) fc = 0.45f * sr;
  const float q = fam == LE_SYNTH_BASS
                      ? 0.7f + role(prm, fam, R_PUNCH, 0.0f) / 24.0f
                      : p->resonance;
  const float g = tanf(LE_SYNTH_PI * fc / sr);
  v->k = 1.0f / q;
  v->a1 = 1.0f / (1.0f + g * (g + v->k));
  v->a2 = g * v->a1;
  v->a3 = g * v->a2;

  const float target =
      1.0f + lfo * role(prm, fam, R_TREMOLO, 0.0f) / 100.0f * 0.25f;
  if (start) {
    v->amp = target;
    v->amp_step = 0.0f;
  } else {
    v->amp_step = (target - v->amp) / (float)LE_SYNTH_CTRL_FRAMES;
  }
}

/* Renders n frames of one voice into out (NULL: advance only). Returns 0 when
 * the voice ended. */
static int voice_run(const le_synth* s, le_synth_voice* v, float* out,
                     int32_t n) {
  const float inv_sr = 1.0f / (float)s->sample_rate;
  for (int32_t f = 0; f < n; ++f) {
    if (v->sweep_left > 0) {
      v->hz *= v->sweep_mul;
      v->sweep_left--;
      v->inc[0] = v->hz * inv_sr;
    }
    float x = 0.0f;
    for (int32_t p = 0; p < v->partials; ++p) {
      x += v->gain[p] * osc(s, v, p);
      v->phase[p] += v->inc[p];
      if (v->phase[p] >= 1.0f) v->phase[p] -= 1.0f;
    }
    const float v3 = x - v->ic2;
    const float v1 = v->a1 * v->ic1 + v->a2 * v3;
    const float v2 = v->ic2 + v->a2 * v->ic1 + v->a3 * v3;
    v->ic1 = 2.0f * v1 - v->ic1;
    v->ic2 = 2.0f * v2 - v->ic2;
    const float y = v->highpass ? x - v->k * v1 - v2 : v2;

    int ended = 0;
    switch (v->stage) {
      case STAGE_ATTACK:
        v->env += v->att_step;
        if (--v->att_left <= 0) {
          v->env = v->peak;
          v->stage = STAGE_DECAY;
        }
        break;
      case STAGE_DECAY:
        v->env *= v->dec_mul;
        if (--v->dec_left <= 0) {
          v->env = v->dec_target;
          v->stage = STAGE_SUSTAIN;
          if (v->drum) ended = 1;
        }
        break;
      case STAGE_RELEASE:
        v->env = -v->rel_floor + (v->env + v->rel_floor) * v->rel_k;
        if (v->env <= 0.0f) {
          v->env = 0.0f;
          ended = 1;
        }
        break;
      default:
        break;
    }
    float o = y * v->env * v->amp;
    v->amp += v->amp_step;
    if (v->state == LE_SYNTH_VOICE_FADING) {
      o *= v->fade;
      v->fade -= v->fade_step;
      if (v->fade <= 0.0f) ended = 1;
    }
    if (out != NULL) out[f] += o;
    if (ended) {
      v->state = LE_SYNTH_VOICE_FREE;
      return 0;
    }
  }
  return 1;
}

/* Moves main voice `v` into a fade slot (or overwrites the most finished
 * fade when all are busy) and frees its main slot. */
static void fade_out(le_synth* s, le_synth_voice* v) {
  le_synth_voice* slot = NULL;
  for (int32_t i = 0; i < LE_SYNTH_FADE_SLOTS; ++i) {
    if (s->fades[i].state == LE_SYNTH_VOICE_FREE) {
      slot = &s->fades[i];
      break;
    }
  }
  if (slot == NULL) {
    slot = &s->fades[0];
    for (int32_t i = 1; i < LE_SYNTH_FADE_SLOTS; ++i) {
      if (s->fades[i].fade < slot->fade) slot = &s->fades[i];
    }
    s->stolen_hard++;
  }
  *slot = *v;
  slot->state = LE_SYNTH_VOICE_FADING;
  slot->fade = 1.0f;
  slot->fade_step =
      1000.0f / ((float)LE_SYNTH_FADE_MS * (float)s->sample_rate);
  slot->amp_step = 0.0f;
  v->state = LE_SYNTH_VOICE_FREE;
}

static le_synth_voice* oldest(le_synth* s, int32_t state, int32_t inst) {
  le_synth_voice* best = NULL;
  for (int32_t i = 0; i < s->voice_count; ++i) {
    le_synth_voice* v = &s->voices[i];
    if (v->state != state || (inst >= 0 && v->inst != inst)) continue;
    if (best == NULL || v->serial < best->serial) best = v;
  }
  return best;
}

/* A free main slot, stealing when the pool is full: the oldest released
 * voice of this instrument, then of any instrument, then the oldest held
 * voice of this instrument, then of any. */
static le_synth_voice* take_slot(le_synth* s, int32_t inst) {
  for (int32_t i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].state == LE_SYNTH_VOICE_FREE) return &s->voices[i];
  }
  le_synth_voice* v = oldest(s, LE_SYNTH_VOICE_RELEASED, inst);
  if (v == NULL) v = oldest(s, LE_SYNTH_VOICE_RELEASED, -1);
  if (v == NULL) v = oldest(s, LE_SYNTH_VOICE_HELD, inst);
  if (v == NULL) v = oldest(s, LE_SYNTH_VOICE_HELD, -1);
  fade_out(s, v);
  s->stolen++;
  return v;
}

static int32_t drum_kind(int32_t note) {
  switch (note) {
    case 35:
    case 36:
      return LE_SYNTH_DRUM_KICK;
    case 38:
    case 40:
      return LE_SYNTH_DRUM_SNARE;
    case 39:
      return LE_SYNTH_DRUM_CLAP;
    case 42:
    case 44:
      return LE_SYNTH_DRUM_HAT;
    default:
      return 0;
  }
}

int32_t le_synth_init(le_synth* s, int32_t sample_rate, int32_t voices,
                      uint32_t seed) {
  if (s == NULL || sample_rate <= 0 || voices < 1 ||
      voices > LE_SYNTH_MAX_VOICES) {
    return -1;
  }
  memset(s, 0, sizeof(*s));
  s->sample_rate = sample_rate;
  s->voice_count = voices;
  s->seed = seed;
  for (int32_t i = 0; i <= LE_SYNTH_SINE_SIZE; ++i) {
    s->sine[i] = (float)sin(2.0 * 3.14159265358979323846 * (double)i /
                            (double)LE_SYNTH_SINE_SIZE);
  }
  for (int32_t n = 0; n < 128; ++n) {
    s->note_hz[n] = (float)(440.0 * pow(2.0, ((double)n - 69.0) / 12.0));
  }
  for (int32_t i = 0; i < LE_SYNTH_MAX_INSTRUMENTS; ++i) s->inst[i].patch = -1;
  return 0;
}

int32_t le_synth_set_instrument(le_synth* s, int32_t inst, int32_t patch) {
  if (s == NULL || inst < 0 || inst >= LE_SYNTH_MAX_INSTRUMENTS) return -1;
  const le_synth_patch* p = NULL;
  if (patch >= 0) {
    p = le_synth_patch_at(patch);
    if (p == NULL) return -1;
  } else {
    patch = -1;
  }
  if (s->inst[inst].patch != patch) {
    for (int32_t i = 0; i < s->voice_count; ++i) {
      le_synth_voice* v = &s->voices[i];
      if (v->state != LE_SYNTH_VOICE_FREE && v->inst == inst) fade_out(s, v);
    }
  }
  s->inst[inst].patch = patch;
  for (int32_t i = 0; i < LE_SYNTH_FAMILY_PARAMS; ++i) {
    s->inst[inst].params[i] = p != NULL ? p->defaults[i] : 0.0f;
  }
  return 0;
}

int32_t le_synth_set_param(le_synth* s, int32_t inst, int32_t index, float v) {
  if (s == NULL || inst < 0 || inst >= LE_SYNTH_MAX_INSTRUMENTS || index < 0 ||
      index >= LE_SYNTH_FAMILY_PARAMS || s->inst[inst].patch < 0 || v != v) {
    return -1;
  }
  if (v < 0.0f) v = 0.0f;
  if (v > 100.0f) v = 100.0f;
  s->inst[inst].params[index] = v;
  return 0;
}

int32_t le_synth_note_on(le_synth* s, int32_t inst, uint32_t origin,
                         int32_t note, int32_t velocity) {
  if (s == NULL || inst < 0 || inst >= LE_SYNTH_MAX_INSTRUMENTS || note < 0 ||
      note > 127 || velocity < 1 || velocity > 127) {
    return -1;
  }
  const int32_t patch = s->inst[inst].patch;
  const le_synth_patch* p = le_synth_patch_at(patch);
  if (p == NULL) return -1;
  const int32_t drum = p->family == LE_SYNTH_DRUMS ? drum_kind(note) : 0;
  if (p->family == LE_SYNTH_DRUMS && drum == 0) return -1;

  /* A repeated strike from the same origin replaces its held voice. */
  for (int32_t i = 0; i < s->voice_count; ++i) {
    le_synth_voice* v = &s->voices[i];
    if (v->state == LE_SYNTH_VOICE_HELD && v->inst == inst &&
        v->origin == origin) {
      fade_out(s, v);
    }
  }

  le_synth_voice* v = take_slot(s, inst);
  memset(v, 0, sizeof(*v));
  v->state = LE_SYNTH_VOICE_HELD;
  v->inst = inst;
  v->patch = patch;
  v->note = note;
  v->origin = origin;
  v->serial = ++s->serial;
  v->velocity = (float)velocity / 127.0f;
  v->noise = s->seed ^ (uint32_t)(v->serial * 2654435761u);
  if (v->noise == 0) v->noise = 0x9e3779b9u;

  const float* prm = s->inst[inst].params;
  const int32_t fam = p->family;
  const int32_t sr = s->sample_rate;
  if (drum) {
    const float d = seconds_of(role(prm, fam, R_DECAY, 45.0f));
    const float body = role(prm, fam, R_BODY, 0.0f);
    float duration;
    v->drum = drum;
    if (drum == LE_SYNTH_DRUM_KICK) {
      duration = 0.15f + d * 0.55f;
      const float f0 = p->electronic ? 180.0f : 135.0f;
      const float f1 = p->electronic ? 38.0f : 47.0f;
      v->partials = 1;
      v->wave[0] = LE_SYNTH_WAVE_SINE;
      v->gain[0] = 0.8f;
      v->hz = f0;
      v->inc[0] = f0 / (float)sr;
      v->sweep_left = frames_of(duration * 0.5f, sr);
      v->sweep_mul = powf(f1 / f0, 1.0f / (float)v->sweep_left);
    } else {
      duration = drum == LE_SYNTH_DRUM_HAT ? 0.04f + d * 0.13f
                                           : 0.08f + d * 0.3f;
      v->partials = 2;
      v->wave[0] = LE_SYNTH_WAVE_NOISE;
      v->gain[0] = 1.0f;
      v->wave[1] = LE_SYNTH_WAVE_TRIANGLE;
      v->gain[1] = 0.1f + body / 250.0f;
      v->inc[1] = (drum == LE_SYNTH_DRUM_SNARE ? 180.0f : 320.0f) / (float)sr;
      v->highpass = 1;
    }
    const float g0 =
        (0.35f + body / 160.0f) * v->velocity * LE_SYNTH_DRUM_HEADROOM;
    v->stage = STAGE_DECAY;
    v->env = g0;
    v->dec_left = frames_of(duration, sr);
    v->dec_target = 0.0001f;
    v->dec_mul = powf(0.0001f / g0, 1.0f / (float)v->dec_left);
  } else {
    v->hz = s->note_hz[note];
    v->partials = 2;
    v->wave[0] = p->wave;
    v->mult[0] = 1.0f;
    v->wave[1] = p->wave == LE_SYNTH_WAVE_SINE ? LE_SYNTH_WAVE_SINE
                                               : LE_SYNTH_WAVE_TRIANGLE;
    v->mult[1] = p->ratio;
    if (fam == LE_SYNTH_ORGANS) {
      v->wave[v->partials] = LE_SYNTH_WAVE_SINE;
      v->mult[v->partials++] = 4.0f;
    }
    if (p->extra_partial) {
      v->wave[v->partials] = LE_SYNTH_WAVE_SINE;
      v->mult[v->partials++] = 5.4f;
    }
    const float attack =
        (fam == LE_SYNTH_STRINGS || fam == LE_SYNTH_SYNTHS)
            ? attack_of(role(prm, fam, R_ATTACK, 0.0f))
            : 0.008f;
    v->peak = 0.5f * v->velocity;
    v->env = 0.0001f;
    v->stage = STAGE_ATTACK;
    v->att_left = frames_of(attack, sr);
    v->att_step = (v->peak - v->env) / (float)v->att_left;
    v->dec_target = v->peak * (p->transient ? p->level : 0.8f);
    v->dec_left = frames_of(
        p->transient ? seconds_of(role(prm, fam, R_DECAY, 45.0f)) : 0.4f, sr);
    v->dec_mul = powf(v->dec_target / v->peak, 1.0f / (float)v->dec_left);
  }
  voice_ctrl(s, v, 1);
  return 0;
}

void le_synth_note_off(le_synth* s, uint32_t origin) {
  if (s == NULL) return;
  for (int32_t i = 0; i < s->voice_count; ++i) {
    le_synth_voice* v = &s->voices[i];
    if (v->state != LE_SYNTH_VOICE_HELD || v->origin != origin || v->drum) {
      continue;
    }
    const le_synth_patch* p = le_synth_patch_at(v->patch);
    const float* prm = s->inst[v->inst].params;
    const float release = seconds_of(role(
        prm, p->family, R_RELEASE, role(prm, p->family, R_DECAY, 35.0f)));
    if (v->env <= 0.0f) {
      v->state = LE_SYNTH_VOICE_FREE;
      continue;
    }
    /* Toward -floor with tau = release / 5: zero exactly at the release time
     * (floor / (env + floor) = e^-5). */
    const float tau = release / 5.0f;
    v->rel_k = expf(-1.0f / (tau * (float)s->sample_rate));
    v->rel_floor = v->env * 0.006783654f; /* e^-5 / (1 - e^-5) */
    v->stage = STAGE_RELEASE;
    v->state = LE_SYNTH_VOICE_RELEASED;
  }
}

void le_synth_render(le_synth* s, float* const* bus, int32_t n_bus,
                     int32_t frames) {
  if (s == NULL || frames <= 0) return;
  for (int32_t b = 0; b < n_bus; ++b) {
    if (bus != NULL && bus[b] != NULL) {
      memset(bus[b], 0, sizeof(float) * (size_t)frames);
    }
  }
  int32_t pos = 0;
  while (pos < frames) {
    if (s->ctrl_left <= 0) {
      for (int32_t i = 0; i < s->voice_count; ++i) {
        le_synth_voice* v = &s->voices[i];
        if (v->state == LE_SYNTH_VOICE_HELD ||
            v->state == LE_SYNTH_VOICE_RELEASED) {
          voice_ctrl(s, v, 0);
        }
      }
      s->ctrl_left = LE_SYNTH_CTRL_FRAMES;
    }
    int32_t n = frames - pos;
    if (n > s->ctrl_left) n = s->ctrl_left;
    for (int32_t i = 0; i < s->voice_count; ++i) {
      le_synth_voice* v = &s->voices[i];
      if (v->state == LE_SYNTH_VOICE_FREE) continue;
      float* out = (bus != NULL && v->inst < n_bus && bus[v->inst] != NULL)
                       ? bus[v->inst] + pos
                       : NULL;
      voice_run(s, v, out, n);
    }
    for (int32_t i = 0; i < LE_SYNTH_FADE_SLOTS; ++i) {
      le_synth_voice* v = &s->fades[i];
      if (v->state == LE_SYNTH_VOICE_FREE) continue;
      float* out = (bus != NULL && v->inst < n_bus && bus[v->inst] != NULL)
                       ? bus[v->inst] + pos
                       : NULL;
      voice_run(s, v, out, n);
    }
    s->ctrl_left -= n;
    pos += n;
  }
}

int32_t le_synth_active(const le_synth* s, int32_t inst) {
  if (s == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < s->voice_count; ++i) {
    const le_synth_voice* v = &s->voices[i];
    if (v->state != LE_SYNTH_VOICE_FREE && (inst < 0 || v->inst == inst)) n++;
  }
  return n;
}

int32_t le_synth_fading(const le_synth* s) {
  if (s == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_SYNTH_FADE_SLOTS; ++i) {
    if (s->fades[i].state != LE_SYNTH_VOICE_FREE) n++;
  }
  return n;
}

int32_t le_synth_has_origin(const le_synth* s, uint32_t origin) {
  if (s == NULL) return 0;
  for (int32_t i = 0; i < s->voice_count; ++i) {
    const le_synth_voice* v = &s->voices[i];
    if (v->state != LE_SYNTH_VOICE_FREE && v->origin == origin) return 1;
  }
  return 0;
}
