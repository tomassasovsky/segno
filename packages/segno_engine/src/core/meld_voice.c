/*
 * meld_voice.c — the Meld device (meld_voice.h).
 *
 * Written from the behavior description in docs/brainstorm/2026-11-24-
 * ableton-devices-brainstorm-doc.md ("Meld: behavior"). Values marked "fit"
 * were set against Live renders; the rest follow the description.
 */
#include "meld_voice.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define MV_PI 3.14159265358979323846f

/* The LFOs' random values are the same on every note and in every
 * instance, restarting with the phase (the Pulsate renders and their
 * copies repeat exactly; Detuned String Machine renders identically in
 * three instances). [measured] from Live's renders by the scratchpad's
 * meldfit/meas/lfo_tables.py, round 8, read as pitch through a 0.96
 * semitone route:
 * - Pulsate, per quarter of a cycle since the restart: the pulse's height,
 *   and the roll its chance is compared with, the middle of the bracket
 *   the chances it fired and did not fire at leave (pul-c100, -c080,
 *   -c050, -c020: a quarter that fires at several chances fires the same
 *   height at each);
 * - Wander's random targets, one per cycle from the restart (wander-step,
 *   Morph 0.5 and Step 1, so the LFO plays each target as it is);
 * - LFO 2's S&H values, one per cycle from the restart (sh-8hz; sh-2hz
 *   plays the same sequence).
 * Past the measured length each sequence starts over, and the Wander
 * walk's direction is the target's sign. [Segno] */
static const float kPulsateHeight[120] = {0.971f,-0.462f,-0.465f,0.956f,-0.488f,-0.914f,0.344f,0.000f,-0.122f,-0.027f,0.805f,-0.344f,-0.244f,0.944f,-0.491f,0.543f,0.000f,0.676f,-0.127f,0.874f,0.000f,-0.176f,-0.850f,-0.524f,0.000f,-0.229f,0.283f,0.583f,-0.481f,0.078f,-0.878f,0.031f,0.212f,-0.239f,0.248f,-0.239f,0.000f,-0.082f,0.073f,0.841f,0.599f,0.553f,-0.288f,0.548f,-0.221f,0.570f,-0.790f,-0.485f,0.178f,0.884f,0.757f,0.520f,0.000f,-0.221f,-0.706f,0.014f,0.477f,0.201f,0.067f,0.082f,0.559f,-0.190f,-0.624f,-0.235f,0.176f,0.000f,0.367f,-0.550f,0.067f,-0.537f,-0.433f,0.734f,-0.274f,-0.578f,-0.112f,0.742f,-0.423f,0.000f,0.893f,-0.412f,-0.739f,-0.443f,0.000f,0.379f,0.096f,0.712f,-0.706f,0.350f,-0.450f,-0.356f,-0.469f,0.000f,0.443f,0.163f,0.000f,-0.779f,0.520f,-0.469f,0.105f,-0.843f,-0.280f,0.000f,0.414f,0.103f,0.000f,-0.815f,0.803f,-0.725f,0.000f,-0.083f,0.105f,0.080f,-0.586f,-0.762f,0.000f,0.441f,0.635f,-0.243f,0.458f,-0.526f};
static const float kPulsateRoll[120] = {0.290f,0.181f,0.676f,0.631f,0.740f,0.631f,0.676f,0.950f,0.290f,0.181f,0.676f,0.631f,0.740f,0.631f,0.226f,0.181f,0.950f,0.631f,0.676f,0.181f,0.950f,0.631f,0.676f,0.181f,0.950f,0.181f,0.226f,0.631f,0.290f,0.631f,0.226f,0.181f,0.740f,0.181f,0.676f,0.181f,0.950f,0.181f,0.226f,0.181f,0.290f,0.631f,0.676f,0.631f,0.290f,0.631f,0.676f,0.181f,0.290f,0.181f,0.676f,0.631f,0.950f,0.631f,0.676f,0.181f,0.290f,0.181f,0.226f,0.181f,0.290f,0.631f,0.676f,0.631f,0.290f,0.950f,0.676f,0.631f,0.740f,0.631f,0.226f,0.631f,0.290f,0.631f,0.676f,0.181f,0.740f,0.950f,0.676f,0.631f,0.740f,0.181f,0.950f,0.181f,0.290f,0.631f,0.226f,0.181f,0.290f,0.631f,0.676f,0.950f,0.290f,0.631f,0.950f,0.181f,0.290f,0.631f,0.226f,0.181f,0.290f,0.950f,0.676f,0.181f,0.950f,0.631f,0.226f,0.631f,0.950f,0.631f,0.226f,0.631f,0.290f,0.181f,0.950f,0.631f,0.740f,0.181f,0.226f,0.631f};
static const float kWanderStep[30] = {-0.998f,0.974f,-0.998f,-0.147f,0.363f,-0.143f,-0.247f,0.900f,0.728f,0.570f,0.168f,0.838f,-0.137f,-0.139f,0.317f,-0.930f,0.806f,-0.694f,-0.739f,0.433f,-0.855f,-0.469f,-0.372f,0.522f,0.776f,-0.080f,0.363f,0.679f,0.323f,0.943f};
static const float kSampleHold[60] = {0.152f,-0.600f,-0.999f,0.383f,-0.525f,0.594f,0.718f,-0.820f,-0.252f,0.357f,0.894f,0.266f,0.010f,-0.858f,0.426f,0.680f,-0.737f,0.548f,0.020f,0.633f,-0.139f,-0.266f,-0.599f,0.318f,0.999f,0.992f,-0.140f,0.214f,0.092f,0.105f,-0.412f,-0.503f,-0.339f,-0.765f,-0.580f,-0.878f,0.775f,-0.077f,-0.122f,-0.010f,-0.118f,0.391f,0.433f,-0.625f,-0.525f,0.819f,0.903f,-0.260f,0.840f,-0.881f,-0.555f,0.157f,-0.258f,0.351f,0.981f,0.383f,-0.239f,-0.501f,0.064f,0.551f};

enum {
  LE_MELD_VOICE_FREE = 0,
  LE_MELD_VOICE_HELD,
  LE_MELD_VOICE_RELEASED,
  LE_MELD_VOICE_SUSTAINED,
  LE_MELD_VOICE_FADING
};

enum { ENV_IDLE = 0, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE, ENV_TAIL };
enum { LOOP_NONE = 0, LOOP_TRIGGER, LOOP_LOOP, LOOP_AD };

/* The matrix targets and sources, in the stored order. */
enum {
  T_DETUNE = 0, T_PITCH, T_PITCH_QUANT, T_OSC_M1, T_OSC_M2, T_FILTER_FREQ, T_FILTER_M1,
  T_FILTER_M2, T_LFO1_RATE, T_LFO1_M1, T_LFO1_M2, T_LFO1_FX1, T_LFO1_FX2, T_LFO2_RATE,
  T_AMP_ATTACK, T_AMP_DECAY, T_AMP_RELEASE, T_AMP_SUSTAIN, T_MOD_ATTACK, T_MOD_DECAY,
  T_MOD_RELEASE, T_MOD_SUSTAIN, T_TONE, T_PAN, T_VOLUME
};
enum {
  S_AMP_A = 0, S_MOD_A, S_LFO1_A, S_LFO1FX_A, S_LFO2_A, S_AMP_B, S_MOD_B, S_LFO1_B, S_LFO1FX_B,
  S_LFO2_B, S_VELOCITY, S_NOTE, S_BEND, S_NOTE_BEND, S_PRESSURE, S_SLIDE, S_MOD_WHEEL, S_RANDOM,
  S_SPREAD
};

/* ---- parameters ---- */

typedef struct mv_param_def {
  float def, lo, hi;
  int step;
} mv_param_def;

static mv_param_def engine_field(int32_t e, int32_t f) {
  switch (f) {
    case LE_MELD_E_ON: return (mv_param_def){e == 0 ? 1.0f : 0.0f, 0.0f, 1.0f, 1};
    case LE_MELD_E_OSC_TYPE: return (mv_param_def){0.0f, 0.0f, 24.0f, 1};
    case LE_MELD_E_KEYTRACK: return (mv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_MELD_E_TRANSPOSE: return (mv_param_def){0.0f, -12.0f, 12.0f, 1};
    case LE_MELD_E_SCALE_DEGREES: return (mv_param_def){0.0f, -48.0f, 48.0f, 1};
    case LE_MELD_E_OCTAVES: return (mv_param_def){0.0f, -3.0f, 3.0f, 1};
    case LE_MELD_E_DETUNE: return (mv_param_def){0.0f, -0.5f, 0.5f, 0};
    case LE_MELD_E_OSC_USE_SCALE:
    case LE_MELD_E_RESET_OFFSET:
    case LE_MELD_E_FILTER_ON:
    case LE_MELD_E_FILTER_USE_SCALE:
    case LE_MELD_E_LFO1_SYNC:
    case LE_MELD_E_LFO2_SYNC:
    case LE_MELD_E_LFO2_RETRIGGER:
      return (mv_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_MELD_E_RESET:
    case LE_MELD_E_LFO1_RETRIGGER:
      return (mv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_MELD_E_FILTER_TYPE: return (mv_param_def){0.0f, 0.0f, 16.0f, 1};
    case LE_MELD_E_FILTER_FREQ: return (mv_param_def){20480.0f, 20.0f, 20480.0f, 0};
    case LE_MELD_E_LFO1_TYPE: return (mv_param_def){0.0f, 0.0f, 5.0f, 1};
    case LE_MELD_E_LFO1_RATE:
    case LE_MELD_E_LFO2_RATE:
      return (mv_param_def){1.0f, 0.01f, 200.0f, 0};
    case LE_MELD_E_LFO1_SYNCED_RATE: return (mv_param_def){15.0f, 0.0f, 21.0f, 1};
    case LE_MELD_E_LFO2_SYNCED_RATE: return (mv_param_def){12.0f, 0.0f, 21.0f, 1};
    case LE_MELD_E_LFO1_PHASE:
    case LE_MELD_E_LFO2_PHASE:
      return (mv_param_def){0.0f, 0.0f, 360.0f, 0};
    case LE_MELD_E_LFO1_FX1_TYPE: return (mv_param_def){2.0f, 0.0f, 18.0f, 1};
    case LE_MELD_E_LFO1_FX2_TYPE: return (mv_param_def){11.0f, 0.0f, 18.0f, 1};
    case LE_MELD_E_LFO2_WAVE: return (mv_param_def){0.0f, 0.0f, 5.0f, 1};
    case LE_MELD_E_AMP_ATTACK:
    case LE_MELD_E_MOD_ATTACK:
      return (mv_param_def){0.001f, 0.0f, 40.0f, 0};
    case LE_MELD_E_AMP_DECAY:
    case LE_MELD_E_MOD_DECAY:
      return (mv_param_def){0.6f, 0.0015f, 40.0f, 0};
    case LE_MELD_E_AMP_RELEASE: return (mv_param_def){0.6f, 0.0015f, 40.0f, 0};
    case LE_MELD_E_MOD_RELEASE: return (mv_param_def){0.05f, 0.0015f, 40.0f, 0};
    case LE_MELD_E_AMP_ATTACK_SLOPE:
    case LE_MELD_E_MOD_ATTACK_SLOPE:
      return (mv_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_MELD_E_AMP_DECAY_SLOPE:
    case LE_MELD_E_AMP_RELEASE_SLOPE:
    case LE_MELD_E_MOD_DECAY_SLOPE:
    case LE_MELD_E_MOD_RELEASE_SLOPE:
      return (mv_param_def){0.5f, -1.0f, 1.0f, 0};
    case LE_MELD_E_AMP_SUSTAIN:
    case LE_MELD_E_MOD_PEAK:
      return (mv_param_def){1.0f, 0.0f, 1.0f, 0};
    case LE_MELD_E_AMP_LOOP:
    case LE_MELD_E_MOD_LOOP:
      return (mv_param_def){0.0f, 0.0f, 3.0f, 1};
    case LE_MELD_E_TONE:
    case LE_MELD_E_PAN:
      return (mv_param_def){0.0f, -1.0f, 1.0f, 0};
    case LE_MELD_E_VOLUME: return (mv_param_def){0.0f, -50.0f, 24.0f, 0};
    case LE_MELD_E_GLIDE_MODE: return (mv_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_MELD_E_GLIDE_TIME: return (mv_param_def){0.0f, 0.0f, 20.0f, 0};
    default: return (mv_param_def){0.0f, 0.0f, 1.0f, 0}; /* macros, levels */
  }
}

static mv_param_def param_def(int32_t p) {
  if (p < LE_MELD_DRIVE) return engine_field(p / LE_MELD_ENGINE_FIELDS, p % LE_MELD_ENGINE_FIELDS);
  if (p >= LE_MELD_MOD) return (mv_param_def){0.0f, -1.0f, 1.0f, 0};
  switch (p) {
    case LE_MELD_LIMITER: return (mv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_MELD_LINK_ENVELOPES:
    case LE_MELD_LEGACY_LOOP:
    case LE_MELD_USE_SCALE:
      return (mv_param_def){0.0f, 0.0f, 1.0f, 1};
    case LE_MELD_ENGINE_B_DELAY: return (mv_param_def){0.0f, 0.0f, 10.0f, 0};
    case LE_MELD_MONO_POLY: return (mv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_MELD_POLY_VOICES: return (mv_param_def){5.0f, 0.0f, 6.0f, 1};
    case LE_MELD_UNISON: return (mv_param_def){0.0f, 0.0f, 2.0f, 1};
    case LE_MELD_MONO_LEGATO: return (mv_param_def){1.0f, 0.0f, 1.0f, 1};
    case LE_MELD_VOLUME: return (mv_param_def){1.0f, 0.0f, 1.995f, 0};
    default: return (mv_param_def){0.0f, 0.0f, 1.0f, 0}; /* drive, spread */
  }
}

float le_meld_default(int32_t param) {
  if (param < 0 || param >= LE_MELD_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_meld_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_MELD_PARAMS) return 0.0f;
  const mv_param_def p = param_def(param);
  if (value != value) return p.def;
  if (value < p.lo) value = p.lo;
  if (value > p.hi) value = p.hi;
  return p.step ? floorf(value + 0.5f) : value;
}

static float vf(const le_meld* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_meld* d, int32_t p) { return (int32_t)d->values[p]; }
static float ef(const le_meld* d, int32_t e, int32_t f) { return d->values[LE_MELD_ENGINE(e, f)]; }
static int32_t ei(const le_meld* d, int32_t e, int32_t f) {
  return (int32_t)d->values[LE_MELD_ENGINE(e, f)];
}

/* An envelope field of engine e: engine A's when Link Envelopes is on. */
static float envf(const le_meld* d, int32_t e, int32_t f) {
  return ef(d, vi(d, LE_MELD_LINK_ENVELOPES) ? 0 : e, f);
}

static float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

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

static void build_routes(le_meld* d) {
  for (int32_t e = 0; e < 2; ++e) {
    int32_t n = 0;
    for (int32_t t = 0; t < LE_MELD_MOD_TARGETS; ++t) {
      for (int32_t s = 0; s < LE_MELD_MOD_SOURCES; ++s) {
        const float a = vf(d, LE_MELD_MOD_AMOUNT(e, t, s));
        if (a != 0.0f) d->routes[e][n++] = (le_meld_route){(int16_t)t, (int16_t)s, a};
      }
    }
    d->route_n[e] = n;
  }
}

int32_t le_meld_init(le_meld* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  le_meld_osc_tables();
  /* everything but the Noise Loop buffers, which are filled on first use */
  memset(d, 0, offsetof(le_meld, loops));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_MELD_VOICE_SLOTS * LE_MELD_COPIES;
  d->rng = 0x2545f491u;
  for (int32_t p = 0; p < LE_MELD_PARAMS; ++p) d->values[p] = param_def(p).def;
  const float rate = (float)sample_rate;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    d->voices[i].born = -1;
    for (int32_t c = 0; c < LE_MELD_COPIES; ++c) {
      le_meld_copy* cp = &d->voices[i].c[c];
      cp->rng = 0x9e3779b9u ^ (uint32_t)((i * LE_MELD_COPIES + c + 1) * 2654435761u);
      for (int32_t e = 0; e < 2; ++e) {
        le_meld_osc_init(&cp->e[e].osc, rate, cp->rng ^ (uint32_t)(e + 1) * 0x85ebca6bu,
                         d->loops[i][c][e]);
        cp->e[e].lfo2_sh = kSampleHold[0];
        le_meld_filter_init(&cp->e[e].filter, rate);
      }
    }
  }
  build_routes(d);
  return 0;
}

void le_meld_set_values(le_meld* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_MELD_PARAMS; ++p) d->values[p] = le_meld_clamp(p, values[p]);
  build_routes(d);
}

void le_meld_set_tempo(le_meld* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

/* ---- envelopes ---- */

/* A segment's curve: (e^(kx) - 1) / (e^k - 1) with k = -7.5 slope, so a
 * positive slope moves fast first; straight within |k| <= 0.001. */
static float env_curve(float x, float slope) {
  const float k = -7.5f * slope;
  if (fabsf(k) <= 0.001f) return x;
  return expm1f(k * x) / expm1f(k);
}

/* One envelope's settings: times in steps (samples or ticks), slopes,
 * levels and loop mode. */
typedef struct env_def {
  float dx[3]; /* attack, decay, release: x per step */
  float slope[3];
  float initial, peak, sustain, final;
  int32_t loop;
  int mod;     /* the Mod envelope: loops hold through note-off */
  int legacy;  /* LegacyEnvLoopBehaviour */
} env_def;

static void env_enter(le_meld_env* e, int32_t state, float y0, float y1) {
  e->state = state;
  e->x = 0.0f;
  e->y0 = y0;
  e->y1 = y1;
}

/* The stage after the decay, by loop mode. */
static void env_after_decay(le_meld_env* e, const env_def* p) {
  switch (p->loop) {
    case LOOP_NONE:
      e->state = ENV_SUSTAIN;
      e->y = p->sustain;
      break;
    case LOOP_AD:
      env_enter(e, ENV_ATTACK, p->initial, p->peak);
      break;
    default:
      env_enter(e, ENV_TAIL, p->sustain, p->final);
      break;
  }
}

static void env_start(le_meld_env* e, const env_def* p) {
  e->y = p->initial;
  env_enter(e, ENV_ATTACK, p->initial, p->peak);
  if (p->dx[0] >= 1.0f) {
    /* no attack: from the peak */
    env_enter(e, ENV_DECAY, p->peak, p->sustain);
    e->y = p->peak;
  }
}

static void env_release(le_meld_env* e, const env_def* p) {
  if (e->state == ENV_IDLE || p->loop == LOOP_TRIGGER) return;
  if (p->mod && !p->legacy && (p->loop == LOOP_LOOP || p->loop == LOOP_AD)) return;
  env_enter(e, ENV_RELEASE, e->y, p->final);
}

static float env_step(le_meld_env* e, const env_def* p) {
  switch (e->state) {
    case ENV_IDLE:
      return e->y = p->final;
    case ENV_SUSTAIN:
      return e->y = p->sustain;
    case ENV_ATTACK:
    case ENV_DECAY:
    case ENV_RELEASE:
    case ENV_TAIL: {
      const int seg = e->state == ENV_ATTACK ? 0 : e->state == ENV_DECAY ? 1 : 2;
      if (e->state == ENV_DECAY) e->y1 = p->sustain;
      e->x += p->dx[seg];
      /* fit: the Mod envelope ends a segment a step early (an AD Loop of
       * 0.1 + 0.2 s repeats every 0.29933 s in Live's render) */
      if (e->x >= 1.0f || (p->mod && e->x + p->dx[seg] >= 1.0f - 1e-5f)) {
        e->y = e->y1;
        switch (e->state) {
          case ENV_ATTACK:
            env_enter(e, ENV_DECAY, p->peak, p->sustain);
            break;
          case ENV_DECAY:
            env_after_decay(e, p);
            break;
          case ENV_TAIL:
            if (p->loop == LOOP_LOOP) {
              env_enter(e, ENV_ATTACK, p->initial, p->peak);
            } else {
              e->state = ENV_IDLE;
            }
            break;
          default:
            e->state = ENV_IDLE;
            break;
        }
        return e->y;
      }
      return e->y = e->y0 + (e->y1 - e->y0) * env_curve(e->x, p->slope[seg]);
    }
    default:
      return e->y;
  }
}

/* Whether `e` is idle or takes its last step to idle next: the voice's
 * quiet count starts there. fit: nloop-55-notes, where Live counts from
 * the release's last step, one sample before Segno's envelope reaches 0 */
static int env_ending(const le_meld_env* e, const env_def* p) {
  if (e->state == ENV_IDLE) return 1;
  if (e->state == ENV_RELEASE || (e->state == ENV_TAIL && p->loop != LOOP_LOOP)) {
    return e->x + p->dx[2] >= 1.0f;
  }
  return 0;
}

/* 2^x through the polynomial the Noise Loop description gives for its pow
 * (segno-re-findings/rng-01-drift-meld.md 2.3): Live's note frequency
 * follows it. [measured] (nl-n12, -n24, -n36, -n60: Noise Loop matches
 * Live's renders to the sample with it, and drifts a sample in two
 * seconds with an exact 2^x) */
static float fast_exp2(float x) {
  const float z = clampf(x + 127.0f, 0.0f, 255.0f);
  const float zi = floorf(z), f = z - zi;
  const float p = 1.0f + f * (0.6930501f + f * (0.2412875f + f * (0.0521745f + f * 0.0134879f)));
  return ldexpf(p, (int)zi - 127);
}

/* A time knob in seconds moved by the matrix: the knob's position is the
 * fourth root of the time over 40 s, and the modulation adds to it.
 * [measured] Velocity into Amp Release: 1 s + 0.25 at 127 releases over
 * 7.2 s in Live (7.04 by this law, 6.38 by a cube), 0.05 s + 0.109 over
 * 0.26 and 0.12 s at 120 and 90 (rel-vel-*: 0.265 and 0.119; a cube
 * gives 0.345 and 0.144); the attack and decay renders at 0.5 s + 0.25
 * ramp 4 % slower than a cube's, as this law does. */
static float mod_time(float seconds, float sum) {
  if (sum == 0.0f) return seconds;
  const float pos = sqrtf(sqrtf(seconds / 40.0f)) + sum;
  return pos <= 0.0f ? 0.0f : 40.0f * (pos * pos) * (pos * pos);
}

static float time_dx(float seconds, float steps_per_second) {
  const float n = seconds * steps_per_second;
  return n <= 1.0f ? 1.0f : 1.0f / n;
}

/* ---- LFO 1 ---- */

static float lfo_triangle(double p) {
  return p < 0.25 ? (float)(4.0 * p) : p < 0.75 ? (float)(2.0 - 4.0 * p) : (float)(4.0 * p - 4.0);
}

static float lfo_skew(float x, float m) {
  const float z = clampf(0.5f * (x + 1.0f), 0.0f, 1.0f);
  const float e = 1.0f + 6.0f * (2.0f * m - 1.0f) * (2.0f * m - 1.0f);
  return m < 0.5f ? 2.0f * powf(z, e) - 1.0f : 1.0f - 2.0f * powf(1.0f - z, e);
}

static float basic_lfo_shape(int k, double p, float fold) {
  switch (k) {
    case 0:
    case 1: {
      const float y0 = k == 0 ? sinf(2.0f * MV_PI * (float)p) : lfo_triangle(p);
      return fold * sinf(0.5f * MV_PI * (1.0f + 4.0f * fold) * y0) + (1.0f - fold) * y0;
    }
    case 2: {
      const double w = 1.0 - 0.5 * fold;
      return p < w ? (float)(2.0 * p / w - 1.0) : (float)(2.0 * (p - 1.0) / w + 1.0);
    }
    default:
      return p < 0.5 + 0.45 * fold ? 1.0f : -1.0f;
  }
}

/* Euclid: whether step i of n carries one of k pulses (evenly spread). */
static int euclid_on(int32_t i, int32_t n, int32_t k) { return ((i * k) % n) < k; }

/* The 24 orderings of the four bands, in lexicographic order. */
static void scramble_perm(int32_t index, int32_t out[4]) {
  int32_t pool[4] = {0, 1, 2, 3};
  int32_t left = 4;
  static const int32_t fact[4] = {6, 2, 1, 1};
  for (int32_t i = 0; i < 4; ++i) {
    const int32_t j = index / fact[i];
    index %= fact[i];
    out[i] = pool[j];
    for (int32_t q = j; q < left - 1; ++q) pool[q] = pool[q + 1];
    left--;
  }
}

/* One transformer: x the input, m its macro, f the LFO's rate, p the phase,
 * dt the tick in seconds. */
static float transform(le_meld_fx* s, int32_t type, float x, float m, float f, double p, float dt) {
  switch (type) {
    case 1:
      return fmaxf(x + 2.0f * m - 1.0f, -1.0f);
    case 2:
      return x * (1.0f - 2.0f * m);
    case 3: {
      if (m >= 1.0f) return x;
      const float g = m >= 0.196f ? 5.1f * m + 0.02f * (1.0f - m)
                                  : 0.02f + 0.9957f * (m / 0.196f) * (m / 0.196f);
      return s->t * f < g ? x : 0.0f;
    }
    case 4:
      return lfo_skew(x, m);
    case 5: {
      const float e = 1.0f + 6.0f * (2.0f * m - 1.0f) * (2.0f * m - 1.0f);
      const float a = fminf(fabsf(x), 1.0f);
      const float y = m < 0.5f ? powf(a, e) : 1.0f - powf(1.0f - a, e);
      return x < 0.0f ? -y : y;
    }
    case 6: {
      const float uni = 0.5f * (x + 1.0f), half = fmaxf(x, 0.0f), full = fabsf(x);
      return m <= 0.5f ? uni + 2.0f * m * (half - uni) : half + (2.0f * m - 1.0f) * (full - half);
    }
    case 7: {
      /* fit: x rounded to steps of 1 / (n - 1), symmetric about 0 (the
       * Quantizer render at 0.8 plays 0, +-0.5 and +-1) */
      const float n = floorf(45.0f * (1.0f - m) * (1.0f - m) + 2.0f) - 1.0f;
      return floorf(x * n + 0.5f) / n;
    }
    case 8: {
      const int32_t n = (int32_t)(30.0f * (1.0f - m) * (1.0f - m) + 2.0f);
      const int32_t cell = (int32_t)(p * n);
      if (cell != s->cell) {
        s->cell = cell;
        s->hold = x;
      }
      return s->hold;
    }
    case 9: {
      const float k = 0.571f + 63.43f * (1.0f - m) * (1.0f - m);
      s->ph += (double)(k * f * dt);
      if (s->ph >= 1.0) {
        s->ph -= floor(s->ph);
        s->hold = x;
      }
      return s->hold;
    }
    case 10: {
      if (m < 0.5f) {
        const float th = 0.95f * (1.0f - 2.0f * m);
        const float a = fabsf(x);
        if (a < th) return 0.0f;
        const float y = (a - th) / (1.0f - th);
        return x < 0.0f ? -y : y;
      }
      const float c = 1.0f - 0.995f * (2.0f * m - 1.0f);
      return clampf(x, -c, c) / c;
    }
    case 11:
    case 12: {
      const float T = 0.01f + 59.99f * m * m * m * m;
      if (type == 11) return m <= 0.0f ? x : x * fminf(s->t / T, 1.0f);
      return x * fmaxf(1.0f - s->t / T, 0.0f);
    }
    case 13:
    case 14:
    case 15: {
      const float S = 0.002f + 1.998f * m * m;
      const float lim = f * dt / S;
      float dv = x - s->slew;
      if (type != 14 && dv < -lim) dv = -lim; /* down */
      if (type != 13 && dv > lim) dv = lim;   /* up */
      s->slew += dv;
      return s->slew;
    }
    case 16: {
      const float T = 0.01f + 9.99f * m * m * m;
      if (s->last <= 0.0f && x > 0.0f) s->trig = 1.0f;
      else s->trig *= powf(0.001f, dt / T);
      s->last = x;
      return s->trig;
    }
    case 17:
      return x >= 2.0f * m - 1.0f ? 1.0f : -1.0f;
    case 18: {
      int32_t perm[4];
      scramble_perm((int32_t)fminf(24.0f * m, 23.0f), perm);
      int32_t band = (int32_t)floorf((clampf(x, -1.0f, 1.0f) + 1.0f) * 2.0f);
      if (band > 3) band = 3;
      return x + 0.5f * (float)(perm[band] - band);
    }
    default:
      return x;
  }
}

static void lfo1_reset(le_meld_lfo1* l) {
  l->ph = 0.0;
  l->gen = l->fx = 0.0f;
  l->walk = l->from = l->to = 0.0f;
  l->draw = 0;
  l->step = 0;
  l->pulse = l->pulse_left = 0.0f;
  l->quarter = -1;
  memset(l->t, 0, sizeof(l->t));
  for (int i = 0; i < 2; ++i) l->t[i].cell = -1;
}

/* One tick of LFO 1 at `hz`. */
static void lfo1_tick(le_meld_lfo1* l, const le_meld* d, int32_t e, float hz, float m1, float m2,
                      float fx1, float fx2, float dt) {
  const double prev = l->ph;
  const double off = ef(d, e, LE_MELD_E_LFO1_PHASE) / 360.0;
  double p = prev + off;
  p -= floor(p);
  const int32_t type = ei(d, e, LE_MELD_E_LFO1_TYPE);
  float g = 0.0f;
  switch (type) {
    case 0: {
      const float s = 3.0f * clampf(m1, 0.0f, 1.0f);
      int k = (int)s;
      if (k > 2) k = 2;
      const float fr = s - (float)k;
      g = (1.0f - fr) * basic_lfo_shape(k, p, m2);
      if (fr > 0.0f) g += fr * basic_lfo_shape(k + 1, p, m2);
      break;
    }
    case 1: {
      const double s = clampf(m1, 0.0f, 1.0f);
      float u;
      if (p < s) u = (float)(2.0 * p / s - 1.0);
      else u = s >= 1.0 ? 1.0f : (float)(1.0 - 2.0 * (p - s) / (1.0 - s));
      g = lfo_skew(u, m2);
      break;
    }
    case 2: {
      const float s = clampf(m2, 0.0f, 1.0f);
      const float ws = s <= 0.4f ? 1.0f - s / 0.4f : 0.0f;
      const float L = s <= 0.4f ? 1.0f : 1.0f - (s - 0.4f) / 0.6f;
      const float pp = (float)p;
      const float sc = pp < 0.5f ? 2.0f * pp * pp : 1.0f - 2.0f * (1.0f - pp) * (1.0f - pp);
      const float lin = L <= 0.0f ? 1.0f : fminf(pp / L, 1.0f);
      g = l->from + (l->to - l->from) * (ws * sc + (1.0f - ws) * lin);
      break;
    }
    case 3:
      g = p < 0.5 ? 2.0f * m1 - 1.0f : 2.0f * m2 - 1.0f;
      break;
    case 4: {
      const int32_t n = (int32_t)(3.0f + 14.0f * clampf(m1, 0.0f, 1.0f));
      int32_t k = (int32_t)(1.0f + (float)(n - 1) * clampf(m2, 0.0f, 1.0f));
      if (k > n - 1) k = n - 1;
      const double x = (double)l->step + prev + off * (double)n;
      int32_t i = (int32_t)floor(x) % n;
      if (i < 0) i += n;
      g = euclid_on(i, n, k) ? (float)(1.0 - (x - floor(x))) : 0.0f;
      break;
    }
    default: {
      /* Pulsate: a chance at every quarter of the cycle */
      const int32_t q = (int32_t)(prev * 4.0);
      if (q != l->quarter) {
        l->quarter = q;
        const float c = clampf(m1, 0.0f, 1.0f);
        float chance;
        if (q == 0) chance = c < 0.333f ? 0.1f + 0.8f * (c / 0.333f) : 0.9f;
        else if (q == 2) chance = fminf(fmaxf(0.9f * (c - 0.333f) / 0.333f, 0.0f), 0.9f);
        else chance = c > 0.666f ? 0.9f * (c - 0.666f) / 0.334f : 0.0f;
        const int32_t n = (4 * l->step + q) % 120;
        if (kPulsateRoll[n] < chance) {
          l->pulse = kPulsateHeight[n];
          l->pulse_left = 0.01f + 2.99f * m2 * m2;
        }
      }
      g = l->pulse_left > 0.0f ? l->pulse : 0.0f;
      l->pulse_left -= hz * dt;
      break;
    }
  }
  l->gen = g;
  float y = transform(&l->t[0], ei(d, e, LE_MELD_E_LFO1_FX1_TYPE), clampf(g, -1.0f, 1.0f),
                      clampf(fx1, 0.0f, 1.0f), hz, p, dt);
  y = transform(&l->t[1], ei(d, e, LE_MELD_E_LFO1_FX2_TYPE), clampf(y, -1.0f, 1.0f),
                clampf(fx2, 0.0f, 1.0f), hz, p, dt);
  l->fx = y;
  for (int i = 0; i < 2; ++i) l->t[i].t += dt;
  /* the phase, and what each new cycle draws */
  l->ph = prev + (double)(hz * dt);
  if (l->ph >= 1.0 || l->draw == 0) {
    if (l->ph >= 1.0) {
      l->ph -= floor(l->ph);
      l->step++;
      l->quarter = -1;
    }
    const float r = kWanderStep[l->draw++ % 30];
    const float dir = r < 0.0f ? -1.0f : 1.0f;
    l->walk += 0.25f * dir;
    if (l->walk > 1.0f) l->walk = 2.0f - l->walk;
    if (l->walk < -1.0f) l->walk = -2.0f - l->walk;
    const float m = clampf(m1, 0.0f, 1.0f);
    const float a = 1.0f - 2.0f * fminf(m, 0.5f);
    const float b = 1.0f - fabsf(2.0f * m - 1.0f);
    const float c = fmaxf(0.0f, 2.0f * m - 1.0f);
    l->from = l->to;
    l->to = a * l->walk + b * r + c * dir;
  }
}

static float lfo2_wave(int32_t w, double p, float sh) {
  switch (w) {
    case 0: return sinf(2.0f * MV_PI * (float)p);
    case 1: return lfo_triangle(p);
    case 2: return (float)(2.0 * p - 1.0);
    case 3: return (float)(1.0 - 2.0 * p);
    case 4: return p < 0.5 ? 1.0f : -1.0f;
    default: return sh;
  }
}

/* The Tempo divisions 0..21 in beats per cycle, slowest first (Drift's). */
static const float kSyncBeats[22] = {
    32.0f, 24.0f, 16.0f, 12.0f, 8.0f, 6.0f, 4.0f, 3.0f,
    2.0f, 1.5f, 1.333333f, 1.25f, 1.0f, 0.75f, 0.666667f, 0.5f,
    0.333333f, 0.25f, 0.166667f, 0.125f, 0.083333f, 0.0625f};

/* fit: a free rate's knob position is (rate / 79.5 Hz)^(1 / 3.036), and
 * the matrix adds to it (the LFO Rate renders: +0.1 at 2 Hz is 2.4122
 * times, -0.1 is 0.2879 times) */
#define MV_RATE_SCALE 79.5f
#define MV_RATE_POWER 3.036f

static float lfo_rate(const le_meld* d, int32_t e, int lfo2, float sum) {
  const int32_t sync = ei(d, e, lfo2 ? LE_MELD_E_LFO2_SYNC : LE_MELD_E_LFO1_SYNC);
  if (sync) {
    int32_t idx = ei(d, e, lfo2 ? LE_MELD_E_LFO2_SYNCED_RATE : LE_MELD_E_LFO1_SYNCED_RATE) +
                  (int32_t)floorf(22.0f * sum + 0.5f);
    idx = idx < 0 ? 0 : idx > 21 ? 21 : idx;
    return d->bpm / 60.0f / kSyncBeats[idx];
  }
  const float hz = ef(d, e, lfo2 ? LE_MELD_E_LFO2_RATE : LE_MELD_E_LFO1_RATE);
  if (sum == 0.0f) return hz;
  const float pos = powf(hz / MV_RATE_SCALE, 1.0f / MV_RATE_POWER) + sum;
  return pos <= 0.0f ? 0.01f : clampf(MV_RATE_SCALE * powf(pos, MV_RATE_POWER), 0.01f, 200.0f);
}

/* ---- voices ---- */

static const int32_t kPolyVoices[7] = {2, 3, 4, 5, 6, 8, 12};

static int sounding(const le_meld_voice* v) {
  return v->state == LE_MELD_VOICE_HELD || v->state == LE_MELD_VOICE_RELEASED ||
         v->state == LE_MELD_VOICE_SUSTAINED;
}

static void fade_voice(le_meld_voice* v) {
  if (v->state == LE_MELD_VOICE_FREE) return;
  v->state = LE_MELD_VOICE_FADING;
  if (v->fade <= 0.0f) v->fade = 1.0f;
}

static int32_t note_count(const le_meld* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

static int32_t copies_per_note(const le_meld* d) { return vi(d, LE_MELD_UNISON) + 1; }

/* Notes allowed: Live's count, within the voice limit (counted in copies). */
static int32_t voice_count(const le_meld* d) {
  int32_t n = vi(d, LE_MELD_MONO_POLY) ? kPolyVoices[vi(d, LE_MELD_POLY_VOICES)] : 1;
  const int32_t lim = d->voice_limit / copies_per_note(d);
  if (n > lim) n = lim;
  return n < 1 ? 1 : n;
}

static le_meld_voice* oldest(le_meld* d, int32_t state) {
  le_meld_voice* old = NULL;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    le_meld_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

static le_meld_voice* free_slot(le_meld* d) {
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_MELD_VOICE_FREE) return &d->voices[i];
  }
  le_meld_voice* v = oldest(d, LE_MELD_VOICE_FADING);
  if (v != NULL) return v;
  return oldest(d, LE_MELD_VOICE_RELEASED);
}

/* A copy's position among n items: symmetric in [-1, 1], alternating sides
 * outward, the middle item at 0 when n is odd. */
static float spread_position(int32_t u, int32_t n) {
  if (n <= 1) return 0.0f;
  if (n % 2 == 0) {
    const float p = (float)(u / 2 + 1) / (float)(n / 2);
    return u % 2 == 0 ? -p : p;
  }
  if (u == 0) return 0.0f;
  const int32_t w = u - 1;
  const float p = (float)(w / 2 + 1) / (float)((n - 1) / 2);
  return w % 2 == 0 ? -p : p;
}

/* The envelope settings of engine e, with the matrix sums `sum` (times,
 * sustain gains). */
static env_def amp_def(const le_meld* d, int32_t e, const float* dx, float sustain) {
  env_def p;
  p.dx[0] = dx[0];
  p.dx[1] = dx[1];
  p.dx[2] = dx[2];
  p.slope[0] = envf(d, e, LE_MELD_E_AMP_ATTACK_SLOPE);
  p.slope[1] = envf(d, e, LE_MELD_E_AMP_DECAY_SLOPE);
  p.slope[2] = envf(d, e, LE_MELD_E_AMP_RELEASE_SLOPE);
  p.initial = 0.0f;
  p.peak = 1.0f;
  p.sustain = sustain;
  p.final = 0.0f;
  p.loop = (int32_t)envf(d, e, LE_MELD_E_AMP_LOOP);
  p.mod = 0;
  p.legacy = 0;
  return p;
}

static env_def mod_def(const le_meld* d, int32_t e, const float* dx, float sustain) {
  env_def p;
  p.dx[0] = dx[0];
  p.dx[1] = dx[1];
  p.dx[2] = dx[2];
  p.slope[0] = envf(d, e, LE_MELD_E_MOD_ATTACK_SLOPE);
  p.slope[1] = envf(d, e, LE_MELD_E_MOD_DECAY_SLOPE);
  p.slope[2] = envf(d, e, LE_MELD_E_MOD_RELEASE_SLOPE);
  p.initial = envf(d, e, LE_MELD_E_MOD_INITIAL);
  p.peak = envf(d, e, LE_MELD_E_MOD_PEAK);
  p.sustain = sustain;
  p.final = envf(d, e, LE_MELD_E_MOD_FINAL);
  p.loop = (int32_t)envf(d, e, LE_MELD_E_MOD_LOOP);
  p.mod = 1;
  p.legacy = vi(d, LE_MELD_LEGACY_LOOP);
  return p;
}

/* The unmodulated envelope rates of engine e (a note start). */
static void base_rates(const le_meld* d, le_meld_engine* en, int32_t e) {
  const float rate = (float)d->sample_rate;
  const float tick = rate / (float)LE_MELD_TICK;
  en->amp_dx[0] = time_dx(envf(d, e, LE_MELD_E_AMP_ATTACK), rate);
  en->amp_dx[1] = time_dx(envf(d, e, LE_MELD_E_AMP_DECAY), rate);
  en->amp_dx[2] = time_dx(envf(d, e, LE_MELD_E_AMP_RELEASE), rate);
  en->mod_dx[0] = time_dx(envf(d, e, LE_MELD_E_MOD_ATTACK), tick);
  en->mod_dx[1] = time_dx(envf(d, e, LE_MELD_E_MOD_DECAY), tick);
  en->mod_dx[2] = time_dx(envf(d, e, LE_MELD_E_MOD_RELEASE), tick);
  en->amp_sustain = envf(d, e, LE_MELD_E_AMP_SUSTAIN);
  en->mod_sustain = envf(d, e, LE_MELD_E_MOD_SUSTAIN);
}

static void engine_start(le_meld* d, le_meld_voice* v, le_meld_copy* cp, int32_t e,
                         float glide_from) {
  le_meld_engine* en = &cp->e[e];
  en->live = 1;
  const float rate = (float)d->sample_rate;
  /* the oscillator and filter types the engine plays */
  if (en->osc.type != ei(d, e, LE_MELD_E_OSC_TYPE)) {
    le_meld_osc_set_type(&en->osc, ei(d, e, LE_MELD_E_OSC_TYPE));
  }
  if (en->filter.type != ei(d, e, LE_MELD_E_FILTER_TYPE)) {
    le_meld_filter_set_type(&en->filter, ei(d, e, LE_MELD_E_FILTER_TYPE));
  }
  /* pitch: from the glide source, or straight to the note */
  const float target = ei(d, e, LE_MELD_E_KEYTRACK) ? (float)v->note : 60.0f;
  en->pitch = target;
  en->glide_left = 0;
  const float gt = ef(d, e, LE_MELD_E_GLIDE_TIME);
  if (glide_from >= 0.0f && gt > 0.0f && ei(d, e, LE_MELD_E_KEYTRACK)) {
    const int32_t ticks = (int32_t)(gt * rate / (float)LE_MELD_TICK);
    if (ticks > 0) {
      en->pitch = glide_from;
      en->glide_left = ticks;
      en->glide_step = (target - glide_from) / (float)ticks;
    }
  }
  en->glide_to = target;
  /* the oscillator's phase: a note on a silent voice starts it as Reset
   * does, Reset or not [measured] (reset-off: both notes start at the
   * sine render's phase). A legato restart of a ringing voice lets the
   * oscillator run on, Reset or not [measured] (The Rhythm's Noise Loop
   * and Plate Kick's FM run on through it in Live; tr-gotta-catchem tf
   * 8.20 to 7.24, level 2.01 to 0.54, tr-comb-bass and tr-bully-bass
   * pass), except Tarp, whose sweep restarts with its phase (the
   * thunder-kick renders pass that way only) */
  if (!v->legato || (ei(d, e, LE_MELD_E_RESET) && en->osc.type == LE_MELD_OSC_TARP)) {
    float phase = 0.0f;
    if (ei(d, e, LE_MELD_E_RESET_OFFSET)) {
      /* unison copies: the copy's position, not scaled by Spread (fit: the
       * unison renders, reset-offset-u3, Happy Chords' engine B); a single
       * copy: its Spread source, the position times Spread (fit:
       * tr-detuned-string-machine, every note in phase with Live's, attack
       * 2.94 to 0.14 dB; tr-gametal) */
      const float f = 6.0f * (v->copies >= 2 ? cp->position : cp->spread);
      phase = f - truncf(f);
      if (phase < 0.0f) phase += 1.0f;
    }
    le_meld_osc_reset(&en->osc, phase);
  }
  /* envelopes and LFOs */
  base_rates(d, en, e);
  const env_def a = amp_def(d, e, en->amp_dx, en->amp_sustain);
  const env_def m = mod_def(d, e, en->mod_dx, en->mod_sustain);
  if (v->legato) {
    /* a legato key restarting a voice still ringing: the attacks start
     * from where the envelopes are. [measured] for the Mod envelope
     * (mono-leg-after-rel: the filter's sweep starts from the released
     * level, Live's to the hertz), the Amp envelope alike [Segno] */
    env_enter(&en->amp, ENV_ATTACK, en->amp.y, a.peak);
    env_enter(&en->mod, ENV_ATTACK, en->mod.y, m.peak);
  } else {
    env_start(&en->amp, &a);
    env_start(&en->mod, &m);
  }
  en->mod_prev = 0.0f;
  /* LFOs that do not retrigger run on from the voice's first note at the
   * free rate, whether the voice sounds or not. [measured] (free1-, free2-
   * mono and -poly: a 2 Hz LFO into pitch over notes at 0, 1.25 and 2.6 s
   * with silences between plays phases 0, 0.5 and 0.2 at their starts; the
   * training phrase, where Poly takes a voice that never played for each
   * new note: Werkstuecktraeger tf 6.56 to 2.82, Rich N Reich 6.13 to 2.75,
   * Key Ups 3.95 to 2.22 dB) The draws as one per cycle [Segno] */
  const int64_t free_t = (int64_t)d->now - v->born;
  if (ei(d, e, LE_MELD_E_LFO1_RETRIGGER)) {
    lfo1_reset(&en->lfo1);
  } else {
    for (int i = 0; i < 2; ++i) en->lfo1.t[i].t = 0.0f, en->lfo1.t[i].trig = 0.0f;
    /* a free LFO runs from the voice's first note on, sounding or not */
    const double c1 = (double)lfo_rate(d, e, 0, 0.0f) * (double)free_t / (double)d->sample_rate;
    en->lfo1.ph = c1 - floor(c1);
    en->lfo1.step = (int32_t)floor(c1);
    en->lfo1.draw = (int32_t)floor(c1);
    en->lfo1.quarter = -1;
  }
  if (ei(d, e, LE_MELD_E_LFO2_RETRIGGER)) {
    en->lfo2_ph = 0.0;
    en->lfo2_draw = 0;
    en->lfo2_sh = kSampleHold[0];
  }
  else {
    const double c2 = (double)lfo_rate(d, e, 1, 0.0f) * (double)free_t / (double)d->sample_rate;
    en->lfo2_ph = c2 - floor(c2);
    en->lfo2_draw = (int32_t)floor(c2);
    en->lfo2_sh = kSampleHold[en->lfo2_draw % 60];
  }
  en->gl = en->gr = -1.0f; /* set at the first tick without a ramp */
}

/* Starts `v` for `note`; the slot keeps its oscillators, filters and LFO
 * phases from its last note. */
static void start_voice(le_meld* d, le_meld_voice* v, uint32_t origin, int32_t note, float vel,
                        uint64_t serial, float glide_from, int32_t position_index,
                        int32_t position_count) {
  v->state = LE_MELD_VOICE_HELD;
  if (v->born < 0) v->born = (int64_t)d->now;
  v->note = note;
  v->origin = origin;
  v->serial = serial;
  v->velocity = vel;
  v->copies = copies_per_note(d);
  v->since = 0;
  v->tick_left = 0;
  v->quiet = 0;
  v->fade = 0.0f;
  const float rate = (float)d->sample_rate;
  const int32_t delay = (int32_t)(vf(d, LE_MELD_ENGINE_B_DELAY) * rate);
  v->b_delay = delay - delay % LE_MELD_TICK;
  for (int32_t c = 0; c < v->copies; ++c) {
    le_meld_copy* cp = &v->c[c];
    cp->position = v->copies >= 2 ? spread_position(c, v->copies)
                                  : spread_position(position_index % position_count, position_count);
    cp->spread = cp->position * vf(d, LE_MELD_SPREAD);
    cp->random = xs_bipolar(&cp->rng);
    cp->lim[0] = cp->lim[1] = 0.0f;
    cp->e[0].live = cp->e[1].live = 0;
    cp->e[0].amp.state = cp->e[1].amp.state = ENV_IDLE;
    engine_start(d, v, cp, 0, glide_from);
    if (v->b_delay == 0) engine_start(d, v, cp, 1, glide_from);
  }
}

static void held_push(le_meld* d, uint32_t origin, int32_t note) {
  if (d->held_n == LE_MELD_HELD_MAX) {
    memmove(d->held_note, d->held_note + 1, sizeof(int32_t) * (LE_MELD_HELD_MAX - 1));
    memmove(d->held_origin, d->held_origin + 1, sizeof(uint32_t) * (LE_MELD_HELD_MAX - 1));
    d->held_n--;
  }
  d->held_note[d->held_n] = note;
  d->held_origin[d->held_n] = origin;
  d->held_n++;
}

static void held_drop(le_meld* d, uint32_t origin) {
  int32_t keep = 0;
  for (int32_t i = 0; i < d->held_n; ++i) {
    if (d->held_origin[i] == origin) continue;
    d->held_note[keep] = d->held_note[i];
    d->held_origin[keep] = d->held_origin[i];
    keep++;
  }
  d->held_n = keep;
}

static void release_engine(le_meld* d, le_meld_engine* en, int32_t e) {
  const env_def a = amp_def(d, e, en->amp_dx, en->amp_sustain);
  const env_def m = mod_def(d, e, en->mod_dx, en->mod_sustain);
  env_release(&en->amp, &a);
  env_release(&en->mod, &m);
}

static void release_voice(le_meld* d, le_meld_voice* v) {
  v->state = LE_MELD_VOICE_RELEASED;
  for (int32_t c = 0; c < v->copies; ++c) {
    for (int32_t e = 0; e < 2; ++e) release_engine(d, &v->c[c].e[e], e);
  }
}

static void let_go(le_meld* d, le_meld_voice* v) {
  if (d->sustain_n > 0) {
    v->state = LE_MELD_VOICE_SUSTAINED;
  } else {
    release_voice(d, v);
  }
}

/* Moves a held voice to `note` without restarting it (mono legato). */
static void retune(le_meld* d, le_meld_voice* v, int32_t note) {
  v->note = note;
  const float rate = (float)d->sample_rate;
  for (int32_t c = 0; c < v->copies; ++c) {
    for (int32_t e = 0; e < 2; ++e) {
      le_meld_engine* en = &v->c[c].e[e];
      if (!ei(d, e, LE_MELD_E_KEYTRACK)) continue;
      const float gt = ef(d, e, LE_MELD_E_GLIDE_TIME);
      const int32_t ticks = (int32_t)(gt * rate / (float)LE_MELD_TICK);
      en->glide_to = (float)note;
      if (ticks > 0) {
        en->glide_left = ticks;
        en->glide_step = ((float)note - en->pitch) / (float)ticks;
      } else {
        en->pitch = (float)note;
        en->glide_left = 0;
      }
    }
  }
}

/* The lowest position number no held voice uses: Spread fans notes out by
 * arrival. */
static int32_t free_position(const le_meld* d, const le_meld_voice* skip) {
  for (int32_t k = 0; k < LE_MELD_VOICE_SLOTS; ++k) {
    int used = 0;
    for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
      const le_meld_voice* v = &d->voices[i];
      if (v != skip && v->state == LE_MELD_VOICE_HELD && v->position_no == k) used = 1;
    }
    if (!used) return k;
  }
  return 0;
}

int32_t le_meld_note_on(le_meld* d, uint32_t origin, int32_t note, int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  const float vel = (float)velocity / 127.0f;
  if (!chord) {
    for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
      le_meld_voice* v = &d->voices[i];
      if (v->state == LE_MELD_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
    held_drop(d, origin);
  }
  const int32_t count = voice_count(d);
  /* the glide source: the newest key still held */
  const float glide_from = !chord && d->held_n > 0 ? (float)d->held_note[d->held_n - 1] : -1.0f;
  /* mono legato: a held voice moves to the new key (Mono only: a Poly patch
   * the voice budget squeezes to one note still plays each note) */
  const int mono = vi(d, LE_MELD_MONO_POLY) == 0;
  if (mono && vi(d, LE_MELD_MONO_LEGATO) && d->held_n > 0) {
    for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
      le_meld_voice* v = &d->voices[i];
      if (v->state != LE_MELD_VOICE_HELD) continue;
      retune(d, v, note);
      v->origin = origin;
      v->velocity = vel;
      held_push(d, origin, note);
      return 0;
    }
  }
  if (mono && vi(d, LE_MELD_MONO_LEGATO) && d->held_n == 0) {
    /* the key before was let go: the voice still sounding restarts in
     * place, without a steal fade */
    le_meld_voice* last = NULL;
    for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
      le_meld_voice* v = &d->voices[i];
      if ((v->state == LE_MELD_VOICE_RELEASED || v->state == LE_MELD_VOICE_SUSTAINED) &&
          (last == NULL || v->serial > last->serial)) {
        last = v;
      }
    }
    if (last != NULL) {
      held_push(d, origin, note);
      last->legato = 1;
      start_voice(d, last, origin, note, vel, ++d->serial, glide_from, last->position_no, count);
      last->legato = 0;
      return 0;
    }
  }
  /* Stealing: every voice not free counts, fading ones too; the victims
   * are released voices, then sustained, then held, oldest first, never
   * one already fading. Without enough victims the note is dropped (three
   * keys at once in Mono without legato: the third is lost); with them the
   * note starts once the victims' 1 ms fade is over. */
  int32_t active = 0;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    const le_meld_voice* w = &d->voices[i];
    if (w->state != LE_MELD_VOICE_FREE && w->wait == 0) active++;
  }
  int32_t need = active - count + 1;
  int32_t wait = 0;
  le_meld_voice* victims[LE_MELD_VOICE_SLOTS];
  int32_t found = 0;
  if (need > 0) {
    static const int32_t order[3] = {LE_MELD_VOICE_RELEASED, LE_MELD_VOICE_SUSTAINED,
                                     LE_MELD_VOICE_HELD};
    for (int32_t o = 0; o < 3 && found < need; ++o) {
      for (;;) {
        le_meld_voice* old = NULL;
        for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
          le_meld_voice* w = &d->voices[i];
          int taken = 0;
          for (int32_t k = 0; k < found; ++k) taken |= victims[k] == w;
          if (w->state == order[o] && w->wait == 0 && !taken &&
              (old == NULL || w->serial < old->serial)) {
            old = w;
          }
        }
        if (old == NULL || found == need) break;
        victims[found++] = old;
      }
    }
    if (found < need) return 0;
    for (int32_t k = 0; k < found; ++k) {
      fade_voice(victims[k]);
      d->stolen++;
    }
    wait = (int32_t)(0.001f * (float)d->sample_rate) + 1;
  }
  held_push(d, origin, note);
  le_meld_voice* v = free_slot(d);
  if (v == NULL) return 0;
  if (mono && found > 0) {
    /* Mono plays one voice: the note that steals it takes over its LFOs,
     * so an LFO that does not retrigger runs on from the last note.
     * [measured] (the training phrase's mono presets: Death Kicks, LFO 2
     * into Pan, passes with it, strict stereo 5.7 dB without; Chords R Us
     * tf 5.83 to 2.65, Woozy Bass 7.83 to 5.98) */
    for (int32_t c = 0; c < LE_MELD_COPIES; ++c) {
      for (int32_t e = 0; e < 2; ++e) {
        const le_meld_engine* o = &victims[0]->c[c].e[e];
        le_meld_engine* n = &v->c[c].e[e];
        n->lfo1 = o->lfo1;
        n->lfo2_ph = o->lfo2_ph;
        n->lfo2_draw = o->lfo2_draw;
        n->lfo2_sh = o->lfo2_sh;
      }
    }
    v->born = victims[0]->born;
  }
  const int32_t pos = free_position(d, v);
  v->position_no = pos;
  start_voice(d, v, origin, note, vel, ++d->serial, glide_from, pos, count);
  v->wait = wait;
  return 0;
}

void le_meld_note_off(le_meld* d, uint32_t origin) {
  if (d == NULL) return;
  held_drop(d, origin);
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    le_meld_voice* v = &d->voices[i];
    if (v->state != LE_MELD_VOICE_HELD || v->origin != origin) continue;
    if (v->wait > 0) {
      /* still waiting for its victim's fade: it never starts */
      v->state = LE_MELD_VOICE_FREE;
      v->wait = 0;
      continue;
    }
    /* mono: back to the newest key still held, legato */
    if (vi(d, LE_MELD_MONO_POLY) == 0 && d->held_n > 0) {
      retune(d, v, d->held_note[d->held_n - 1]);
      v->origin = d->held_origin[d->held_n - 1];
      continue;
    }
    let_go(d, v);
  }
}

static void release_sustained(le_meld* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_MELD_VOICE_SUSTAINED) release_voice(d, &d->voices[i]);
  }
}

int32_t le_meld_sustain(le_meld* d, uint32_t origin, int on) {
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
  if (d->sustain_n >= LE_MELD_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_meld_expression(le_meld* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = clampf(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_meld_release_matching(le_meld* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = d->held_n - 1; i >= 0; --i) {
    if (i < d->held_n && (d->held_origin[i] & mask) == value) held_drop(d, d->held_origin[i]);
  }
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    le_meld_voice* v = &d->voices[i];
    if (v->state == LE_MELD_VOICE_HELD && (v->origin & mask) == value) {
      let_go(d, v);
    } else if (v->state == LE_MELD_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(d, v);
    }
  }
}

int32_t le_meld_held(const le_meld* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    const le_meld_voice* v = &d->voices[i];
    if (v->state == LE_MELD_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_meld_cut(le_meld* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->held_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_meld_fade_oldest(le_meld* d) {
  if (d == NULL) return 0;
  le_meld_voice* old = NULL;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    le_meld_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  fade_voice(old);
  d->stolen++;
  return old->copies;
}

int32_t le_meld_active(const le_meld* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (sounding(&d->voices[i])) n += d->voices[i].copies;
  }
  return n;
}

int32_t le_meld_fading(const le_meld* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_MELD_VOICE_FADING) n += d->voices[i].copies;
  }
  return n;
}

void le_meld_set_voice_limit(le_meld* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  const int32_t most = LE_MELD_VOICE_SLOTS * LE_MELD_COPIES;
  d->voice_limit = limit > most ? most : limit;
  while (le_meld_active(d) > d->voice_limit) {
    if (!le_meld_fade_oldest(d)) break;
  }
}

/* ---- the control tick ---- */

/* The matrix's two results per target: the adding sum and the gain
 * product. */
typedef struct mv_mods {
  float sum[LE_MELD_MOD_TARGETS];
  float prod[LE_MELD_MOD_TARGETS];
} mv_mods;

/* The Note source is (note - 60) / 12, octaves from C3; the semitone
 * targets read it so an amount of 1 tracks the key a semitone per
 * semitone: Detune as it is, Pitch and Pitch Quant at a quarter (fit: the
 * C6 render). `note_ff` is the Note source as Filter Freq reads it, the
 * engine's own pitch scaled the same way (fit: the Note into Filter Freq
 * renders at notes 36, 60, 84 and an octave transpose). Into Tone it is
 * the plain source (fit: the Note into Tone render at C1 sits at the
 * tone's end). */
static void eval_matrix(const le_meld* d, int32_t e, const float* sb, const float* su, float note_ff,
                        mv_mods* m) {
  for (int32_t t = 0; t < LE_MELD_MOD_TARGETS; ++t) {
    m->sum[t] = 0.0f;
    m->prod[t] = 1.0f;
  }
  for (int32_t i = 0; i < d->route_n[e]; ++i) {
    const le_meld_route* r = &d->routes[e][i];
    float b = sb[r->source];
    if (r->source == S_NOTE) {
      if (r->target == T_FILTER_FREQ) b = note_ff;
      else if (r->target == T_PITCH || r->target == T_PITCH_QUANT) b *= 0.25f;
    }
    m->sum[r->target] += r->amount * b;
    m->prod[r->target] *= fmaxf(0.0f, 1.0f + r->amount * su[r->source] - fmaxf(r->amount, 0.0f));
  }
}

static float unipolar(float b) { return fmaxf(0.0f, 0.5f * b + 0.5f); }

static float sat01(float x) { return clampf(x, 0.0f, 1.0f); }

static void tick_copy(le_meld* d, le_meld_voice* v, le_meld_copy* cp) {
  const float rate = (float)d->sample_rate;
  const float dt = (float)LE_MELD_TICK / rate;
  float sb[LE_MELD_MOD_SOURCES], su[LE_MELD_MOD_SOURCES];
  /* the Mod envelopes and LFOs first: both engines' are sources */
  for (int32_t e = 0; e < 2; ++e) {
    le_meld_engine* en = &cp->e[e];
    const int32_t o = e * 5;
    if (!en->live) {
      for (int32_t k = 0; k < 5; ++k) sb[o + k] = su[o + k] = 0.0f;
      continue;
    }
    const env_def m = mod_def(d, e, en->mod_dx, en->mod_sustain);
    /* fit: the matrix reads the Mod envelope's value from the tick before,
     * 0 at the note's first tick (Plate Kick's pitch sweep, the Mod
     * envelope loop renders) */
    const float mod_y = en->mod_prev;
    en->mod_prev = en->mod.y;
    (void)env_step(&en->mod, &m);
    sb[o + 0] = su[o + 0] = en->amp.y;
    sb[o + 1] = su[o + 1] = mod_y;
    sb[o + 2] = en->lfo1.gen;
    sb[o + 3] = en->lfo1.fx;
    sb[o + 4] = en->lfo2;
    su[o + 2] = unipolar(sb[o + 2]);
    su[o + 3] = unipolar(sb[o + 3]);
    su[o + 4] = unipolar(sb[o + 4]);
  }
  sb[S_VELOCITY] = 2.0f * v->velocity - 1.0f;
  su[S_VELOCITY] = v->velocity;
  sb[S_NOTE] = ((float)v->note - 60.0f) / 12.0f;
  su[S_NOTE] = sat01((float)v->note / 120.0f);
  sb[S_BEND] = d->bend;
  su[S_BEND] = 0.5f * d->bend + 0.5f;
  sb[S_NOTE_BEND] = 0.0f;
  su[S_NOTE_BEND] = 0.5f;
  sb[S_PRESSURE] = su[S_PRESSURE] = d->pressure;
  sb[S_SLIDE] = su[S_SLIDE] = 0.0f;
  sb[S_MOD_WHEEL] = su[S_MOD_WHEEL] = d->mod;
  sb[S_RANDOM] = cp->random;
  su[S_RANDOM] = 0.5f * cp->random + 0.5f;
  sb[S_SPREAD] = cp->spread;
  su[S_SPREAD] = unipolar(cp->spread);

  for (int32_t e = 0; e < 2; ++e) {
    le_meld_engine* en = &cp->e[e];
    if (!en->live) continue;
    /* pitch */
    if (en->glide_left > 0) {
      en->pitch += en->glide_step;
      if (--en->glide_left == 0) en->pitch = en->glide_to;
    }
    float semis = ei(d, e, LE_MELD_E_GLIDE_MODE) ? truncf(en->pitch) : en->pitch;
    semis += (float)ei(d, e, LE_MELD_E_TRANSPOSE) + 12.0f * (float)ei(d, e, LE_MELD_E_OCTAVES) +
             (float)ei(d, e, LE_MELD_E_SCALE_DEGREES) + ef(d, e, LE_MELD_E_DETUNE);
    mv_mods m;
    eval_matrix(d, e, sb, su, (semis - 60.0f) / 120.0f, &m);
    semis += m.sum[T_DETUNE] + 48.0f * m.sum[T_PITCH] + floorf(48.0f * m.sum[T_PITCH_QUANT] + 0.5f);
    const float hz = 440.0f * fast_exp2((semis - 69.0f) / 12.0f);
    if (en->osc.type != ei(d, e, LE_MELD_E_OSC_TYPE)) {
      le_meld_osc_set_type(&en->osc, ei(d, e, LE_MELD_E_OSC_TYPE));
    }
    le_meld_osc_set(&en->osc, hz, semis, ef(d, e, LE_MELD_E_OSC_MACRO1) + m.sum[T_OSC_M1],
                    ef(d, e, LE_MELD_E_OSC_MACRO2) + m.sum[T_OSC_M2]);
    if (v->since == 0 || (e == 1 && v->since == v->b_delay)) le_meld_osc_snap(&en->osc);
    /* the filter */
    if (ei(d, e, LE_MELD_E_FILTER_ON)) {
      int fresh = v->since == 0 || (e == 1 && v->since == v->b_delay);
      if (en->filter.type != ei(d, e, LE_MELD_E_FILTER_TYPE)) {
        le_meld_filter_set_type(&en->filter, ei(d, e, LE_MELD_E_FILTER_TYPE));
        fresh = 1;
      }
      le_meld_filter_set(&en->filter,
                         ef(d, e, LE_MELD_E_FILTER_FREQ) * exp2f(10.0f * m.sum[T_FILTER_FREQ]),
                         ef(d, e, LE_MELD_E_FILTER_MACRO1) + m.sum[T_FILTER_M1],
                         ef(d, e, LE_MELD_E_FILTER_MACRO2) + m.sum[T_FILTER_M2]);
      /* a new type or note starts at its values, without the glides */
      if (fresh) le_meld_filter_snap(&en->filter);
    }
    /* the envelopes' times and sustains */
    const float tick = rate / (float)LE_MELD_TICK;
    en->amp_dx[0] = time_dx(mod_time(envf(d, e, LE_MELD_E_AMP_ATTACK), m.sum[T_AMP_ATTACK]), rate);
    en->amp_dx[1] = time_dx(mod_time(envf(d, e, LE_MELD_E_AMP_DECAY), m.sum[T_AMP_DECAY]), rate);
    en->amp_dx[2] = time_dx(mod_time(envf(d, e, LE_MELD_E_AMP_RELEASE), m.sum[T_AMP_RELEASE]), rate);
    en->mod_dx[0] = time_dx(mod_time(envf(d, e, LE_MELD_E_MOD_ATTACK), m.sum[T_MOD_ATTACK]), tick);
    en->mod_dx[1] = time_dx(mod_time(envf(d, e, LE_MELD_E_MOD_DECAY), m.sum[T_MOD_DECAY]), tick);
    en->mod_dx[2] = time_dx(mod_time(envf(d, e, LE_MELD_E_MOD_RELEASE), m.sum[T_MOD_RELEASE]), tick);
    /* fit: the sustains are gain targets (the Amp Sustain render) */
    en->amp_sustain = envf(d, e, LE_MELD_E_AMP_SUSTAIN) * m.prod[T_AMP_SUSTAIN];
    en->mod_sustain = envf(d, e, LE_MELD_E_MOD_SUSTAIN) * m.prod[T_MOD_SUSTAIN];
    if (e == 1 && vi(d, LE_MELD_LINK_ENVELOPES)) {
      /* fit: linked, engine B's envelopes take engine A's values as the
       * matrix moved them (Vertical Bass: B's release follows A's) */
      const le_meld_engine* a = &cp->e[0];
      memcpy(en->amp_dx, a->amp_dx, sizeof(en->amp_dx));
      memcpy(en->mod_dx, a->mod_dx, sizeof(en->mod_dx));
      en->amp_sustain = a->amp_sustain;
      en->mod_sustain = a->mod_sustain;
    }
    /* a note's Amp attack takes the time the matrix sets at its first
     * tick: an attack of 0 the matrix lengthens is played, not skipped.
     * fit: aat-note-n67, -n72 and -n81 (Note into an attack of 0, 0.44)
     * match Live's to the sample, tf 20.7 dB to 0 at A5 */
    if ((v->since == 0 || (e == 1 && v->since == v->b_delay)) && en->amp.state == ENV_DECAY &&
        en->amp.x == 0.0 && en->amp_dx[0] < 1.0f) {
      const env_def ad = amp_def(d, e, en->amp_dx, en->amp_sustain);
      en->amp.y = ad.initial;
      env_enter(&en->amp, ENV_ATTACK, ad.initial, ad.peak);
    }
    /* the LFOs, for the next tick's sources */
    const float r1 = lfo_rate(d, e, 0, m.sum[T_LFO1_RATE]);
    lfo1_tick(&en->lfo1, d, e, r1, ef(d, e, LE_MELD_E_LFO1_MACRO1) + m.sum[T_LFO1_M1],
              ef(d, e, LE_MELD_E_LFO1_MACRO2) + m.sum[T_LFO1_M2],
              ef(d, e, LE_MELD_E_LFO1_FX1_MACRO) + m.sum[T_LFO1_FX1],
              ef(d, e, LE_MELD_E_LFO1_FX2_MACRO) + m.sum[T_LFO1_FX2], dt);
    {
      const float r2 = lfo_rate(d, e, 1, m.sum[T_LFO2_RATE]);
      double p = en->lfo2_ph + ef(d, e, LE_MELD_E_LFO2_PHASE) / 360.0;
      p -= floor(p);
      en->lfo2 = lfo2_wave(ei(d, e, LE_MELD_E_LFO2_WAVE), p, en->lfo2_sh);
      en->lfo2_ph += (double)(r2 * dt);
      if (en->lfo2_ph >= 1.0) {
        en->lfo2_ph -= floor(en->lfo2_ph);
        en->lfo2_sh = kSampleHold[++en->lfo2_draw % 60];
      }
    }
    /* the tone filter: a low-pass below 0, a high-pass above, 6 dB each */
    const float tone = clampf(ef(d, e, LE_MELD_E_TONE) + 2.0f * m.sum[T_TONE], -1.0f, 1.0f);
    const float flp = tone < 0.0f ? 20.0f * exp2f(10.0f * (tone + 1.0f)) : 20480.0f;
    const float fhp = tone > 0.0f ? 20.0f * exp2f(10.0f * tone) : 20.0f;
    en->tone_glp = tanf(fminf(MV_PI * flp / rate, 1.5668f));
    en->tone_ghp = tanf(fminf(MV_PI * fhp / rate, 1.5668f));
    /* the output gains: the engine's volume, the Volume target, the pan */
    const float gain = powf(10.0f, ef(d, e, LE_MELD_E_VOLUME) / 20.0f) * m.prod[T_VOLUME];
    const float pan = clampf(ef(d, e, LE_MELD_E_PAN) + 2.0f * m.sum[T_PAN], -1.0f, 1.0f);
    const float gl = gain * sinf((1.0f - pan) * MV_PI / 4.0f);
    const float gr = gain * sinf((1.0f + pan) * MV_PI / 4.0f);
    if (en->gl < 0.0f) {
      en->gl = gl;
      en->gr = gr;
    }
    en->gl_to = gl;
    en->gr_to = gr;
  }
}

/* ---- rendering ---- */

/* Drive: two tanh stages after up to 18 dB in, a small bias for even
 * harmonics, wet from 0 to full over the first quarter. */
static float drive(float x, float w, float gin, float gout, float off) {
  return (1.0f - w) * x + w * gout * (tanhf(tanhf(gin * x + 0.0025f)) - off);
}

static void render_voice(le_meld* d, le_meld_voice* v, float* left, float* right, int32_t frames) {
  const float rate = (float)d->sample_rate;
  const float dv = vf(d, LE_MELD_DRIVE);
  const float dw = fminf(4.0f * dv, 1.0f);
  const float dgin = powf(10.0f, 18.0f * dv / 20.0f);
  const float dgout = 1.31303f * powf(10.0f, -8.0f * dv / 20.0f);
  const float doff = tanhf(tanhf(0.0025f));
  const int limiter = vi(d, LE_MELD_LIMITER);
  const float att = 1.0f - expf(-1.0f / (0.01f * rate));
  const float rel = 1.0f - expf(-1.0f / (0.1f * rate));
  const float out_gain = 0.5f * vf(d, LE_MELD_VOLUME) / sqrtf((float)v->copies);
  /* the end check's level: the reading's 0.0002 on the voice's |L + R|,
   * before the device's 0.5 x Volume (fit below: nloop-55-vol05 ends each
   * note on the sample nloop-55-notes does, so the level scales with
   * Volume) */
  const float quiet_level = 0.0001f * vf(d, LE_MELD_VOLUME);
  const float fade_step = 1.0f / (0.001f * rate);
  /* the output gains follow the matrix through a one-pole of 4.8 ms
   * [measured]: Detuned String Machine's LFO 1, gated into Volume, has
   * Live's spectrum with it (strict tf 2.51 dB with a 16-sample ramp, 0.17
   * with 4.8 ms, 1.0 at 2.7 ms, 0.6 at 6.3 ms) */
  const float gain_k = 1.0f - expf(-1.0f / (0.0048f * rate));
  const int32_t quiet_need = (int32_t)(0.01f * rate);
  float bl[LE_MELD_TICK], br[LE_MELD_TICK];
  int32_t i = 0;
  if (v->wait > 0) {
    /* a note that stole a voice starts after the victim's fade */
    i = v->wait < frames ? v->wait : frames;
    v->wait -= i;
  }
  while (i < frames && v->state != LE_MELD_VOICE_FREE) {
    if (v->tick_left == 0) {
      for (int32_t c = 0; c < v->copies; ++c) {
        le_meld_copy* cp = &v->c[c];
        if (!cp->e[1].live && v->since >= v->b_delay) {
          engine_start(d, v, cp, 1, -1.0f);
          /* a note released before engine B's delay releases B at once */
          if (v->state == LE_MELD_VOICE_RELEASED) release_engine(d, &cp->e[1], 1);
        }
        tick_copy(d, v, cp);
      }
      v->tick_left = LE_MELD_TICK;
    }
    int32_t n = v->tick_left < frames - i ? v->tick_left : frames - i;
    /* a block ends where the voice could end, so nothing runs past it */
    if (v->quiet > 0 && quiet_need - v->quiet < n) n = quiet_need - v->quiet;
    float vl[LE_MELD_TICK] = {0}, vr[LE_MELD_TICK] = {0};
    /* per sample: whether every Amp envelope has reached its last step */
    int idle[LE_MELD_TICK];
    for (int32_t k = 0; k < n; ++k) idle[k] = 1;
    for (int32_t c = 0; c < v->copies; ++c) {
      le_meld_copy* cp = &v->c[c];
      memset(bl, 0, sizeof(float) * (size_t)n);
      memset(br, 0, sizeof(float) * (size_t)n);
      for (int32_t e = 0; e < 2; ++e) {
        le_meld_engine* en = &cp->e[e];
        if (!en->live) {
          for (int32_t k = 0; k < n; ++k) idle[k] = 0; /* engine B still to start */
          continue;
        }
        const env_def a = amp_def(d, e, en->amp_dx, en->amp_sustain);
        const int on = ei(d, e, LE_MELD_E_ON);
        const int filt = ei(d, e, LE_MELD_E_FILTER_ON);
        for (int32_t k = 0; k < n; ++k) {
          const float amp = env_step(&en->amp, &a);
          if (!env_ending(&en->amp, &a)) idle[k] = 0;
          float x = on ? le_meld_osc_tick(&en->osc) * amp : 0.0f;
          if (filt) x = le_meld_filter_tick(&en->filter, x);
          /* tone: the low-pass, then the high-pass as low-pass's remainder */
          const float vlp = en->tone_glp / (1.0f + en->tone_glp) * (x - en->tone_lp);
          const float lp = vlp + en->tone_lp;
          en->tone_lp = lp + vlp;
          const float vhp = en->tone_ghp / (1.0f + en->tone_ghp) * (lp - en->tone_hp);
          const float lo = vhp + en->tone_hp;
          en->tone_hp = lo + vhp;
          const float y = lp - lo;
          en->gl += (en->gl_to - en->gl) * gain_k;
          en->gr += (en->gr_to - en->gr) * gain_k;
          bl[k] += y * en->gl;
          br[k] += y * en->gr;
        }
      }
      for (int32_t k = 0; k < n; ++k) {
        float l = bl[k], r = br[k];
        if (dv > 0.0f) {
          l = drive(l, dw, dgin, dgout, doff);
          r = drive(r, dw, dgin, dgout, doff);
        }
        if (limiter) {
          /* fit: the limiter works at the device's level, after the 0.5 of
           * the output (a -9 dBFS sine passes it untouched) */
          float* g = cp->lim;
          const float lv[2] = {0.5f * l, 0.5f * r};
          float out[2];
          for (int ch = 0; ch < 2; ++ch) {
            const float level = 20.0f * log10f(fmaxf(fabsf(lv[ch]), 1e-6f));
            const float target = -0.75f * fmaxf(level + 6.0f, 0.0f);
            g[ch] += (target < g[ch] ? att : rel) * (target - g[ch]);
            out[ch] = lv[ch] * powf(10.0f, g[ch] / 20.0f);
          }
          l = 2.0f * out[0];
          r = 2.0f * out[1];
        }
        vl[k] += l;
        vr[k] += r;
      }
    }
    for (int32_t k = 0; k < n; ++k) {
      float g = out_gain;
      if (v->state == LE_MELD_VOICE_FADING) {
        v->fade -= fade_step;
        if (v->fade <= 0.0f) {
          v->fade = 0.0f;
          v->state = LE_MELD_VOICE_FREE;
        }
        g *= v->fade;
      }
      const float l = vl[k] * g, r = vr[k] * g;
      left[i + k] += l;
      right[i + k] += r;
      /* the end: every Amp envelope at its last step or idle, then 10 ms at
       * or below the quiet level; the oscillators stop with the voice.
       * fit: nloop-55-notes, five Noise Loop notes on one voice whose
       * generator runs on from note to note: with this rule each note
       * ends on Live's sample (26878, 26998, 26878, 26878, 26878 samples
       * ticked), the second where its tail crosses the level, and every
       * note matches Live's to the sample; the 0.0002 after the 0.5,
       * counting only from idle, or a count of 481 each part from it */
      if (idle[k] && v->state != LE_MELD_VOICE_FADING && v->state != LE_MELD_VOICE_FREE) {
        if (fabsf(l + r) <= quiet_level) {
          if (++v->quiet >= quiet_need) v->state = LE_MELD_VOICE_FREE;
        } else if (v->quiet > 0) {
          v->quiet = 0;
        }
      }
    }
    v->tick_left -= n;
    v->since += n;
    i += n;
  }
}

void le_meld_render(le_meld* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  memset(right, 0, sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    le_meld_voice* v = &d->voices[i];
    if (v->state != LE_MELD_VOICE_FREE) render_voice(d, v, left, right, frames);
  }
  d->now += (uint64_t)frames;
}
