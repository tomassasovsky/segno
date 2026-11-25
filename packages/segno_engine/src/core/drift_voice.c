/*
 * drift_voice.c — the Drift device (SEG-109 P3). See drift_voice.h, and the
 * behavior it implements in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Drift: behavior"). The section names below follow
 * that description.
 */
#include "drift_voice.h"

#include <math.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

enum {
  LE_DRIFT_VOICE_FREE = 0,
  LE_DRIFT_VOICE_HELD = 1,
  LE_DRIFT_VOICE_RELEASED = 2,
  LE_DRIFT_VOICE_SUSTAINED = 3,
  LE_DRIFT_VOICE_FADING = 4,
};

enum { STAGE_IDLE = 0, STAGE_ATTACK = 1, STAGE_DECAY = 2, STAGE_RELEASE = 3 };

/* The DSP's waveform kinds (the stored type order is the UI's). */
enum {
  WAVE_SINE = 0,
  WAVE_TRIANGLE,
  WAVE_SHARK,
  WAVE_SATURATED,
  WAVE_SAW,
  WAVE_PULSE,
  WAVE_RECTANGLE,
};

enum { MODE_POLY = 0, MODE_MONO = 1, MODE_STEREO = 2, MODE_UNISON = 3 };

#define TWO_PI 6.28318530717958647692f
#define PI_F 3.14159265358979323846f

/* A voice has finished its release, or its amplitude envelope is silent,
 * below this level (-60 dB). */
#define LE_DRIFT_SILENT 0.001f
/* Steals, restrikes with phase reset, Cut and device changes fade a voice
 * over this many milliseconds. */
#define LE_DRIFT_FADE_MS 3.0f

/* ---- P4: the values the behavior description leaves open ----
 *
 * Each is Segno's provisional choice until plan part 4 fits it against
 * renders of Live; the comment names the open item. */

/* Voice counts 0..4 (open item 4). */
static const int32_t kVoiceCounts[5] = {8, 12, 16, 24, 32};

/* The Sync divisions 0..21 in beats per cycle (open item 4: read from
 * Live's UI). */
static const float kSyncBeats[22] = {
    0.0625f, 0.083333f, 0.125f, 0.166667f, 0.25f, 0.333333f, 0.375f, 0.5f,
    0.666667f, 0.75f, 1.0f, 1.333333f, 1.5f, 2.0f, 2.666667f, 3.0f,
    4.0f, 6.0f, 8.0f, 12.0f, 16.0f, 32.0f};

/* Decay and release reach LE_DRIFT_SILENT of their distance at the stage
 * time (open item 1). */
static float envelope_coefficient(float seconds, float rate) {
  const float n = seconds * rate;
  if (n <= 1.0f) return 1.0f;
  return 1.0f - expf(-6.9077553f / n); /* ln(0.001) */
}

/* Volume 0..1 to gain: (2v)^2, 0 dB at 0.5 (open item 3). */
static float volume_gain(float v) { return 4.0f * v * v; }

/* Glide: the pitch reaches 1 % of the interval at the glide time (open
 * item 3). */
static float glide_coefficient(float seconds, float rate) {
  const float n = seconds * rate;
  if (n <= 1.0f) return 1.0f;
  return 1.0f - expf(-4.6051702f / n); /* ln(0.01) */
}

/* Key tracking: 10 octaves per unit of the key value at Tracking 1, so 1:1
 * about A4 (open item 2). */
static float key_tracking(float tracking, float key) {
  return exp2f(10.0f * tracking * key);
}

/* Stereo mode: the pair panned to -Spread and +Spread and detuned by
 * +-8 cents x Spread; mode gain -3 dB (open item 3). */
#define LE_DRIFT_STEREO_CENTS 8.0f
#define LE_DRIFT_STEREO_GAIN 0.7079458f

/* The output clip of a voice (open item 5). */
#define LE_DRIFT_VOICE_CLIP 2.0f

/* Filter II: the per-section damping from the resonance curve, and the
 * section's saturator offset (open item 2). */
static float filter2_damping(float q) {
  const float r = 2.0f - 1.41f * q;
  return r < 0.02f ? 0.02f : r;
}
#define LE_DRIFT_F2_OFFSET 0.012f

/* ---- parameters ---- */

typedef struct drift_param_def {
  float def, lo, hi;
  int32_t step; /* 1: integer (enum, count, switch) */
} drift_param_def;

static const drift_param_def kParams[LE_DRIFT_PARAMS] = {
    [LE_DRIFT_OSC1_TYPE] = {4.0f, 0.0f, 6.0f, 1},
    [LE_DRIFT_OSC1_SHAPE] = {0.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_OSC1_SHAPE_MOD] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_OSC1_SHAPE_MOD_SOURCE] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_OSC1_TRANSPOSE] = {0.0f, -2.0f, 3.0f, 1},
    [LE_DRIFT_OSC2_TYPE] = {3.0f, 0.0f, 4.0f, 1},
    [LE_DRIFT_OSC2_DETUNE] = {0.05f, -7.0f, 7.0f, 0},
    [LE_DRIFT_OSC2_TRANSPOSE] = {0.0f, -3.0f, 2.0f, 1},
    [LE_DRIFT_OSC1_GAIN] = {0.5f, 0.0f, 1.995268f, 0},
    [LE_DRIFT_OSC1_ON] = {1.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_OSC2_GAIN] = {0.5f, 0.0f, 1.995268f, 0},
    [LE_DRIFT_OSC2_ON] = {1.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_NOISE_GAIN] = {0.0f, 0.0f, 1.995268f, 0},
    [LE_DRIFT_NOISE_ON] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_FILTER_TYPE] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_FILTER_FREQ] = {2000.0f, 20.0f, 20000.0f, 0},
    [LE_DRIFT_FILTER_RES] = {0.2f, 0.0f, 1.01f, 0},
    [LE_DRIFT_FILTER_TRACKING] = {0.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_FILTER_HP_FREQ] = {10.0f, 10.0f, 20480.0f, 0},
    [LE_DRIFT_FILTER_MOD_SOURCE1] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_FILTER_MOD_AMOUNT1] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_FILTER_MOD_SOURCE2] = {2.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_FILTER_MOD_AMOUNT2] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_FILTER_OSC1_THROUGH] = {1.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_FILTER_OSC2_THROUGH] = {1.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_FILTER_NOISE_THROUGH] = {1.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_ENV1_ATTACK] = {0.001f, 0.0f, 60.0f, 0},
    [LE_DRIFT_ENV1_DECAY] = {0.6f, 0.005f, 60.0f, 0},
    [LE_DRIFT_ENV1_SUSTAIN] = {0.7f, 0.0f, 1.0f, 0},
    [LE_DRIFT_ENV1_RELEASE] = {0.2f, 0.01f, 60.0f, 0},
    [LE_DRIFT_ENV2_ATTACK] = {0.001f, 0.0f, 60.0f, 0},
    [LE_DRIFT_ENV2_DECAY] = {0.6f, 0.005f, 60.0f, 0},
    [LE_DRIFT_ENV2_SUSTAIN] = {0.7f, 0.0f, 1.0f, 0},
    [LE_DRIFT_ENV2_RELEASE] = {0.2f, 0.01f, 60.0f, 0},
    [LE_DRIFT_ENV2_CYCLING] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_CYC_MODE] = {0.0f, 0.0f, 3.0f, 1},
    [LE_DRIFT_CYC_RATE] = {1.0f, 0.17f, 1700.0f, 0},
    [LE_DRIFT_CYC_RATIO] = {1.0f, 0.25f, 16.0f, 0},
    [LE_DRIFT_CYC_TIME] = {1.0f, 0.1f, 60.0f, 0},
    [LE_DRIFT_CYC_SYNCED_RATE] = {10.0f, 0.0f, 21.0f, 1},
    [LE_DRIFT_CYC_MIDPOINT] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_CYC_HOLD] = {0.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_LFO_MODE] = {0.0f, 0.0f, 3.0f, 1},
    [LE_DRIFT_LFO_SHAPE] = {0.0f, 0.0f, 8.0f, 1},
    [LE_DRIFT_LFO_RATE] = {1.0f, 0.17f, 1700.0f, 0},
    [LE_DRIFT_LFO_RATIO] = {1.0f, 0.25f, 16.0f, 0},
    [LE_DRIFT_LFO_TIME] = {1.0f, 0.1f, 60.0f, 0},
    [LE_DRIFT_LFO_SYNCED_RATE] = {10.0f, 0.0f, 21.0f, 1},
    [LE_DRIFT_LFO_AMOUNT] = {1.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_LFO_MOD_SOURCE] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_LFO_MOD_AMOUNT] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_LFO_RETRIGGER] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_PITCH_MOD_SOURCE1] = {1.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_PITCH_MOD_AMOUNT1] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_PITCH_MOD_SOURCE2] = {2.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_PITCH_MOD_AMOUNT2] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_MATRIX_SOURCE1] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_MATRIX_TARGET1] = {0.0f, 0.0f, 11.0f, 1},
    [LE_DRIFT_MATRIX_AMOUNT1] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_MATRIX_SOURCE2] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_MATRIX_TARGET2] = {0.0f, 0.0f, 11.0f, 1},
    [LE_DRIFT_MATRIX_AMOUNT2] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_MATRIX_SOURCE3] = {0.0f, 0.0f, 7.0f, 1},
    [LE_DRIFT_MATRIX_TARGET3] = {0.0f, 0.0f, 11.0f, 1},
    [LE_DRIFT_MATRIX_AMOUNT3] = {0.0f, -1.0f, 1.0f, 0},
    [LE_DRIFT_VOICE_MODE] = {0.0f, 0.0f, 3.0f, 1},
    [LE_DRIFT_VOICE_COUNT] = {4.0f, 0.0f, 4.0f, 1},
    [LE_DRIFT_MONO_DEPTH] = {0.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_STEREO_DEPTH] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_UNISON_DEPTH] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_DRIFT_DEPTH] = {0.3f, 0.0f, 1.0f, 0},
    [LE_DRIFT_GLIDE] = {0.0f, 0.0f, 2.0f, 0},
    [LE_DRIFT_LEGATO] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_PITCH_BEND_RANGE] = {2.0f, 0.0f, 12.0f, 1},
    [LE_DRIFT_VOL_VEL] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_VOLUME] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_TRANSPOSE] = {0.0f, -48.0f, 48.0f, 1},
    [LE_DRIFT_RESET_OSC_PHASE] = {0.0f, 0.0f, 1.0f, 1},
    [LE_DRIFT_HIQUALITY] = {1.0f, 0.0f, 1.0f, 1},
};

float le_drift_default(int32_t param) {
  if (param < 0 || param >= LE_DRIFT_PARAMS) return 0.0f;
  return kParams[param].def;
}

float le_drift_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_DRIFT_PARAMS) return 0.0f;
  const drift_param_def* p = &kParams[param];
  if (value != value) return p->def;
  if (value < p->lo) value = p->lo;
  if (value > p->hi) value = p->hi;
  return p->step ? floorf(value + 0.5f) : value;
}

static int32_t vi(const le_drift* d, int32_t p) { return (int32_t)d->values[p]; }
static float vf(const le_drift* d, int32_t p) { return d->values[p]; }

/* ---- small helpers ---- */

static float clampf(float x, float lo, float hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

static uint32_t xorshift(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

/* Uniform in [-1, 1). */
static float rnd_bipolar(uint32_t* s) {
  return (float)(int32_t)xorshift(s) * (1.0f / 2147483648.0f);
}

/* Uniform in (0, 1]. */
static float rnd_unit(uint32_t* s) {
  return ((float)(xorshift(s) >> 8) + 1.0f) * (1.0f / 16777216.0f);
}

/* tanh by a Pade form, exact enough inside +-3, clamped to +-1 outside. */
static float soft(float x) {
  if (x > 3.0f) return 1.0f;
  if (x < -3.0f) return -1.0f;
  const float x2 = x * x;
  return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

/* tan for the filters' prewarp, on [0, 1.53]: a rational form accurate to
 * well under a cent of cutoff in the audible range. */
static float prewarp(float w) {
  if (w > 1.53f) w = 1.53f;
  const float w2 = w * w;
  return w * (15.0f - w2) / (15.0f - 6.0f * w2);
}

static float frac(float x) { return x - floorf(x); }

/* ---- Oscillators ---- */

/* The 2-sample polyBLEP residual at distance t (cycles) from a unit jump,
 * transition width dt. */
static float blep(float t, float dt) {
  if (t < dt) {
    const float x = t / dt;
    return -(x - 1.0f) * (x - 1.0f);
  }
  if (t > 1.0f - dt) {
    const float x = (t - 1.0f) / dt;
    return (x + 1.0f) * (x + 1.0f);
  }
  return 0.0f;
}

/* The polyBLAMP residual at distance t from a unit slope change. */
static float blamp(float t, float dt) {
  if (t < dt) {
    const float x = t / dt - 1.0f;
    return -x * x * x / 3.0f;
  }
  if (t > 1.0f - dt) {
    const float x = (t - 1.0f) / dt + 1.0f;
    return x * x * x / 3.0f;
  }
  return 0.0f;
}

/* A triangle starting at 0, +1 at a quarter cycle, -1 at three quarters. */
static float tri(float th) {
  return 1.0f - fabsf(2.0f - fabsf(4.0f * th - 3.0f));
}

/* A parabolic sine of x in [-0.5, 0.5]: about sin(2 pi x). */
static float psin(float x) { return 16.0f * x * (0.5f - fabsf(x)); }

/* sin(pi/2 * x) for x in [0, 1], an odd 7th-order polynomial. */
static float half_sine(float x) {
  const float x2 = x * x;
  return x * (1.5707963f + x2 * (-0.6459640f + x2 * (0.0796926f + x2 * -0.0046818f)));
}

/* Both triangle corners band-limited. The slope changes by 8 per cycle,
 * 8 dt per sample, and a slope change of m per sample takes m / 2 times the
 * residual. */
static float tri_blamp(float th, float dt) {
  float y = tri(th);
  y -= 4.0f * dt * blamp(frac(th - 0.25f), dt);
  y += 4.0f * dt * blamp(frac(th - 0.75f), dt);
  return y;
}

static float osc_sine(float th, float s) {
  const float s0 = psin(0.5f - th);
  if (s <= 0.0f) return s0;
  float m = (1.0f + 4.0f * s) * fabsf(s0);
  m = fmodf(m, 2.0f);
  if (m > 1.0f) m = 2.0f - m;
  return s0 < 0.0f ? -m : m;
}

static float osc_triangle(float th, float s, float dt) {
  float x = (1.0f + 7.0f * s) * tri_blamp(th, dt);
  if (x > 4.22f) x = 8.44f - x;
  if (x < -5.75f) x = -11.5f - x;
  if (x > 2.31f) x = 4.62f - x;
  if (x < -2.73f) x = -5.46f - x;
  if (x > 1.0f) x = 2.0f - x;
  if (x < -1.0f) x = -2.0f - x;
  return x;
}

static float osc_shark(float th, float s, float dt) {
  const float w = s + 0.1f * (1.0f - s);
  const float lo = 0.75f - 0.5f * w;
  const float hi = 0.75f + 0.5f * w;
  float y;
  if (th >= lo && th < hi) {
    y = tri(th);
  } else {
    y = 1.0f - 2.0f * frac(th + 0.25f - 0.5f * w);
  }
  /* the jump from 2w - 1 up to +1 at the window's end */
  y += (1.0f - w) * blep(frac(th - hi), dt);
  return y;
}

static float osc_saturated(float th, float s) {
  const float y = clampf((s + 0.25f) * tri(th), -0.25f, 0.25f);
  return 0.65f * (16.0f * fabsf(y * (0.5f - y)) - 1.5f);
}

static float osc_saw(float th, float s, float dt) {
  const float k = 1.0f + 10.0f * s;
  const float f = frac(k * th);
  float y = f < 0.5f ? 2.0f * f : 2.0f * f - 2.0f;
  y -= blep(frac(f - 0.5f), k * dt);
  return y;
}

static float osc_pulse(float th, float s, float dt) {
  const float k = 1.0f + 10.0f * s;
  const float x = k * th;
  const float f = frac(x);
  const float w = 0.2f + 0.79f * s;
  const float kdt = k * dt;
  float p = f < w ? 1.0f : -1.0f;
  p += blep(f, kdt) - blep(frac(f - w), kdt);
  const float a = 0.5f * (p + 1.0f);
  const float b = f < w ? half_sine(1.0f - fabsf(2.0f * f / w - 1.0f)) : 0.0f;
  const float m = (1.0f - s) * a + s * b;
  float win = 1.0f;
  if (x > 1.0f && k > 1.0f) {
    const float q = 1.0f - (x - 1.0f) / (k - 1.0f);
    win = q * q;
  }
  return 2.0f * win * m - 1.0f;
}

static float osc_rectangle(float th, float s, float dt) {
  const float pw = clampf(0.5f + 0.49f * s, 0.0f, 0.9999999f);
  float y = th < pw ? 1.0f : -1.0f;
  y += blep(th, dt) - blep(frac(th - pw), dt);
  return y;
}

static float oscillator(int32_t wave, float th, float s, float dt) {
  switch (wave) {
    case WAVE_SINE:
      return osc_sine(th, s);
    case WAVE_TRIANGLE:
      return osc_triangle(th, s, dt);
    case WAVE_SHARK:
      return osc_shark(th, s, dt);
    case WAVE_SATURATED:
      return osc_saturated(th, s);
    case WAVE_SAW:
      return osc_saw(th, s, dt);
    case WAVE_PULSE:
      return osc_pulse(th, s, dt);
    case WAVE_RECTANGLE:
    default:
      return osc_rectangle(th, s, dt);
  }
}

/* The stored type order to the DSP's kinds. */
static int32_t osc1_wave(int32_t stored) {
  static const int32_t map[7] = {WAVE_SINE,  WAVE_TRIANGLE, WAVE_SHARK,
                                 WAVE_SATURATED, WAVE_SAW, WAVE_PULSE,
                                 WAVE_RECTANGLE};
  return map[stored < 0 ? 0 : stored > 6 ? 6 : stored];
}

static int32_t osc2_wave(int32_t stored) {
  static const int32_t map[5] = {WAVE_SINE, WAVE_TRIANGLE, WAVE_SATURATED,
                                 WAVE_SAW, WAVE_RECTANGLE};
  return map[stored < 0 ? 0 : stored > 4 ? 4 : stored];
}

/* ---- Pitch: per-key tuning and note gain ---- */

/* Segno's own per-key deviations for C1..B5 (24..83), in cents: a fixed
 * pseudo-random table with an rms near 4 cents, clipped at +-14. */
static float key_cents(int32_t note) {
  if (note < 24 || note > 83) return 0.0f;
  uint32_t h = (uint32_t)(note * 2654435761u) ^ 0x5e9a7u;
  float sum = 0.0f;
  for (int i = 0; i < 4; ++i) sum += rnd_bipolar(&h);
  return clampf(sum * 3.5f, -14.0f, 14.0f);
}

/* The ISO 226:2003 40-phon equal-loudness level at 1/10-decade steps from
 * 20 Hz (the standard's frequencies and parameters). */
static float iso226_40(int32_t i) {
  static const float af[29] = {0.532f, 0.506f, 0.480f, 0.455f, 0.432f, 0.409f,
                               0.387f, 0.367f, 0.349f, 0.330f, 0.315f, 0.301f,
                               0.288f, 0.276f, 0.267f, 0.259f, 0.253f, 0.250f,
                               0.246f, 0.244f, 0.243f, 0.243f, 0.243f, 0.242f,
                               0.242f, 0.245f, 0.254f, 0.271f, 0.301f};
  static const float lu[29] = {-31.6f, -27.2f, -23.0f, -19.1f, -15.9f, -13.0f,
                               -10.3f, -8.1f,  -6.2f,  -4.5f,  -3.1f,  -2.0f,
                               -1.1f,  -0.4f,  0.0f,   0.3f,   0.5f,   0.0f,
                               -2.7f,  -4.1f,  -1.0f,  1.7f,   2.5f,   1.2f,
                               -2.1f,  -7.1f,  -11.2f, -10.7f, -3.1f};
  static const float tf[29] = {78.5f, 68.7f, 59.5f, 51.1f, 44.0f, 37.5f,
                               31.5f, 26.5f, 22.1f, 17.9f, 14.4f, 11.4f,
                               8.6f,  6.2f,  4.4f,  3.0f,  2.2f,  2.4f,
                               3.5f,  1.7f,  -1.3f, -4.2f, -6.0f, -5.4f,
                               -1.5f, 6.0f,  12.6f, 13.9f, 12.3f};
  const double ln = 40.0;
  const double a = 4.47e-3 * (pow(10.0, 0.025 * ln) - 1.15) +
                   pow(0.4 * pow(10.0, (tf[i] + lu[i]) / 10.0 - 9.0), af[i]);
  return (float)(10.0 / af[i] * log10(a) - lu[i] + 94.0);
}

/* A note's loudness compensation: 1 % of the contour, relative to 20 Hz.
 * Computed once per note start (two contour points). */
static float note_gain(float hz) {
  const float x = 10.0f * log10f(hz / 20.0f);
  float l;
  if (x <= 0.0f) {
    l = iso226_40(0);
  } else if (x >= 28.0f) {
    l = iso226_40(28);
  } else {
    const int i = (int)x;
    const float t = x - (float)i;
    const float a = iso226_40(i);
    l = a + t * (iso226_40(i + 1) - a);
  }
  return powf(10.0f, (l - iso226_40(0)) * 0.01f / 20.0f);
}

static float note_hz(int32_t note) {
  return 440.0f * exp2f(((float)note - 69.0f) / 12.0f);
}

/* ---- derived parameters ---- */

static float sync_hz(const le_drift* d, int32_t index) {
  const float beats = kSyncBeats[index < 0 ? 0 : index > 21 ? 21 : index];
  return d->bpm / 60.0f / beats;
}

static void derive(le_drift* d) {
  le_drift_derived* x = &d->d;
  x->osc1 = osc1_wave(vi(d, LE_DRIFT_OSC1_TYPE));
  x->osc2 = osc2_wave(vi(d, LE_DRIFT_OSC2_TYPE));
  x->osc1_ratio = exp2f(vf(d, LE_DRIFT_OSC1_TRANSPOSE));
  x->osc2_ratio = exp2f(vf(d, LE_DRIFT_OSC2_TRANSPOSE) +
                        vf(d, LE_DRIFT_OSC2_DETUNE) / 12.0f);
  x->gain1 = vi(d, LE_DRIFT_OSC1_ON) ? vf(d, LE_DRIFT_OSC1_GAIN) : 0.0f;
  x->gain2 = vi(d, LE_DRIFT_OSC2_ON) ? vf(d, LE_DRIFT_OSC2_GAIN) : 0.0f;
  x->gain_noise = vi(d, LE_DRIFT_NOISE_ON) ? vf(d, LE_DRIFT_NOISE_GAIN) : 0.0f;
  x->thru1 = vi(d, LE_DRIFT_FILTER_OSC1_THROUGH);
  x->thru2 = vi(d, LE_DRIFT_FILTER_OSC2_THROUGH);
  x->thru_noise = vi(d, LE_DRIFT_FILTER_NOISE_THROUGH);
  x->env1_att = vf(d, LE_DRIFT_ENV1_ATTACK);
  x->env2_att = vf(d, LE_DRIFT_ENV2_ATTACK);
  x->env1_dec = envelope_coefficient(vf(d, LE_DRIFT_ENV1_DECAY), d->rate);
  x->env1_rel = envelope_coefficient(vf(d, LE_DRIFT_ENV1_RELEASE), d->rate);
  x->env2_dec = envelope_coefficient(vf(d, LE_DRIFT_ENV2_DECAY), d->rate);
  x->env2_rel = envelope_coefficient(vf(d, LE_DRIFT_ENV2_RELEASE), d->rate);
  x->volume = volume_gain(vf(d, LE_DRIFT_VOLUME));
  x->hp_hz = vf(d, LE_DRIFT_FILTER_HP_FREQ);
  x->res = vf(d, LE_DRIFT_FILTER_RES);
  switch (vi(d, LE_DRIFT_LFO_MODE)) {
    case 2:
      x->lfo_hz = 1.0f / vf(d, LE_DRIFT_LFO_TIME);
      break;
    case 3:
      x->lfo_hz = sync_hz(d, vi(d, LE_DRIFT_LFO_SYNCED_RATE));
      break;
    default:
      x->lfo_hz = vf(d, LE_DRIFT_LFO_RATE);
      break;
  }
  switch (vi(d, LE_DRIFT_CYC_MODE)) {
    case 2:
      x->cyc_hz = 1.0f / vf(d, LE_DRIFT_CYC_TIME);
      break;
    case 3:
      x->cyc_hz = sync_hz(d, vi(d, LE_DRIFT_CYC_SYNCED_RATE));
      break;
    default:
      x->cyc_hz = vf(d, LE_DRIFT_CYC_RATE);
      break;
  }
  x->rate = d->rate;
  x->sustain1 = vf(d, LE_DRIFT_ENV1_SUSTAIN);
  x->sustain2 = vf(d, LE_DRIFT_ENV2_SUSTAIN);
  x->vol_vel = vf(d, LE_DRIFT_VOL_VEL);
  x->freq = vf(d, LE_DRIFT_FILTER_FREQ);
  x->tracking = vf(d, LE_DRIFT_FILTER_TRACKING);
  x->filter_type = vi(d, LE_DRIFT_FILTER_TYPE);
  x->lfo_shape = vi(d, LE_DRIFT_LFO_SHAPE);
  x->lfo_mode = vi(d, LE_DRIFT_LFO_MODE);
  x->cyc_mode = vi(d, LE_DRIFT_CYC_MODE);
  x->cycling = vi(d, LE_DRIFT_ENV2_CYCLING);
  x->lfo_ratio = vf(d, LE_DRIFT_LFO_RATIO);
  x->cyc_ratio = vf(d, LE_DRIFT_CYC_RATIO);
  x->cyc_mid = vf(d, LE_DRIFT_CYC_MIDPOINT);
  x->cyc_hold = vf(d, LE_DRIFT_CYC_HOLD);
  for (int m = 0; m < 3; ++m) {
    x->mtx_src[m] = vi(d, LE_DRIFT_MATRIX_SOURCE1 + 3 * m);
    x->mtx_tgt[m] = vi(d, LE_DRIFT_MATRIX_TARGET1 + 3 * m);
    x->mtx_amt[m] = vf(d, LE_DRIFT_MATRIX_AMOUNT1 + 3 * m);
  }
  x->pm_src[0] = vi(d, LE_DRIFT_PITCH_MOD_SOURCE1);
  x->pm_amt[0] = vf(d, LE_DRIFT_PITCH_MOD_AMOUNT1);
  x->pm_src[1] = vi(d, LE_DRIFT_PITCH_MOD_SOURCE2);
  x->pm_amt[1] = vf(d, LE_DRIFT_PITCH_MOD_AMOUNT2);
  x->fm_src[0] = vi(d, LE_DRIFT_FILTER_MOD_SOURCE1);
  x->fm_amt[0] = vf(d, LE_DRIFT_FILTER_MOD_AMOUNT1);
  x->fm_src[1] = vi(d, LE_DRIFT_FILTER_MOD_SOURCE2);
  x->fm_amt[1] = vf(d, LE_DRIFT_FILTER_MOD_AMOUNT2);
  x->lfo_src = vi(d, LE_DRIFT_LFO_MOD_SOURCE);
  x->lfo_amt = vf(d, LE_DRIFT_LFO_AMOUNT);
  x->lfo_mod_amt = vf(d, LE_DRIFT_LFO_MOD_AMOUNT);
  x->shape_src = vi(d, LE_DRIFT_OSC1_SHAPE_MOD_SOURCE);
  x->shape_mod = vf(d, LE_DRIFT_OSC1_SHAPE_MOD);
  x->shape = vf(d, LE_DRIFT_OSC1_SHAPE);
  x->bend_ratio = exp2f(d->bend * vf(d, LE_DRIFT_PITCH_BEND_RANGE) / 12.0f +
                        vf(d, LE_DRIFT_TRANSPOSE) / 12.0f);
  x->glide = glide_coefficient(vf(d, LE_DRIFT_GLIDE), d->rate);
  x->fade_step = 1000.0f / (LE_DRIFT_FADE_MS * d->rate);
}

/* ---- HiQuality's decimator ---- */

static void halfband_taps(float* h) {
  const int c = LE_DRIFT_HB_TAPS / 2;
  float sum = 0.0f;
  for (int i = 0; i < LE_DRIFT_HB_TAPS; ++i) {
    const int n = i - c;
    float v;
    if (n == 0) {
      v = 0.5f;
    } else if (n % 2 == 0) {
      v = 0.0f;
    } else {
      const float x = PI_F * 0.5f * (float)n;
      v = 0.5f * sinf(x) / x;
    }
    const float w = 0.42f - 0.5f * cosf(TWO_PI * (float)i / (LE_DRIFT_HB_TAPS - 1)) +
                    0.08f * cosf(2.0f * TWO_PI * (float)i / (LE_DRIFT_HB_TAPS - 1));
    h[i] = v * w;
    sum += h[i];
  }
  for (int i = 0; i < LE_DRIFT_HB_TAPS; ++i) h[i] /= sum;
}

static void set_rate(le_drift* d) {
  d->oversample = vi(d, LE_DRIFT_HIQUALITY) && d->sample_rate < 88200 ? 2 : 1;
  d->rate = (float)d->sample_rate * (float)d->oversample;
  memset(d->hb_l, 0, sizeof(d->hb_l));
  memset(d->hb_r, 0, sizeof(d->hb_r));
  d->hb_pos = 0;
}

/* ---- lifecycle and parameters ---- */

int32_t le_drift_init(le_drift* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_DRIFT_VOICES;
  for (int32_t p = 0; p < LE_DRIFT_PARAMS; ++p) d->values[p] = kParams[p].def;
  halfband_taps(d->hb_taps);
  set_rate(d);
  derive(d);
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    d->voices[i].rng = 0x9e3779b9u ^ (uint32_t)(i * 2654435761u);
  }
  return 0;
}

void le_drift_set_values(le_drift* d, const float* values) {
  if (d == NULL || values == NULL) return;
  const float hq = d->values[LE_DRIFT_HIQUALITY];
  for (int32_t p = 0; p < LE_DRIFT_PARAMS; ++p) {
    d->values[p] = le_drift_clamp(p, values[p]);
  }
  if (d->values[LE_DRIFT_HIQUALITY] != hq) {
    set_rate(d);
    derive(d);
  }
}

void le_drift_set_tempo(le_drift* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

/* ---- voices ---- */

static int sounding(const le_drift_voice* v) {
  return v->state == LE_DRIFT_VOICE_HELD || v->state == LE_DRIFT_VOICE_RELEASED ||
         v->state == LE_DRIFT_VOICE_SUSTAINED;
}

static void fade_voice(le_drift_voice* v) {
  if (v->state == LE_DRIFT_VOICE_FREE) return;
  v->state = LE_DRIFT_VOICE_FADING;
  if (v->fade <= 0.0f) v->fade = 1.0f;
}

static int32_t voice_mode(const le_drift* d) { return vi(d, LE_DRIFT_VOICE_MODE); }

static int32_t lanes_per_note(int32_t mode) {
  return mode == MODE_POLY ? 1 : mode == MODE_STEREO ? 2 : 4;
}

/* The voices a mode may use: the first n of the pool. */
static int32_t pool_size(const le_drift* d) {
  const int32_t mode = voice_mode(d);
  if (mode == MODE_MONO) return 4;
  int32_t n = kVoiceCounts[vi(d, LE_DRIFT_VOICE_COUNT)];
  if (n > d->voice_limit) n = d->voice_limit;
  const int32_t lanes = lanes_per_note(mode);
  n -= n % lanes;
  return n < lanes ? lanes : n;
}

/* The fixed pitch ratio and gains of lane `lane` in the current mode, for
 * `note` (per-key tuning included). */
static void lane_setup(const le_drift* d, le_drift_voice* v, int32_t lane,
                       int32_t note) {
  const int32_t mode = voice_mode(d);
  float ratio = 1.0f, gl = 1.0f, gr = 1.0f;
  if (mode == MODE_MONO) {
    static const float sub[4] = {1.0f, 0.5f, 0.5f, 0.25f};
    const float t = vf(d, LE_DRIFT_MONO_DEPTH);
    const float g = 0.8912509f; /* -1 dB */
    const float lane_gain[4] = {g, g * clampf(3.0f * t, 0.0f, 1.0f),
                                g * clampf(3.0f * t - 1.0f, 0.0f, 1.0f),
                                g * fmaxf(0.0f, 3.0f * t - 2.0f)};
    ratio = sub[lane];
    gl = gr = lane_gain[lane];
  } else if (mode == MODE_UNISON) {
    static const float pan[4] = {-1.0f, -0.5f, 0.5f, 1.0f};
    static const float detune[4] = {1.0245496f, 1.0122024f, 0.9879406f, 0.9760254f};
    const float s = vf(d, LE_DRIFT_UNISON_DEPTH);
    const float g = 0.4731513f; /* -6.5 dB */
    const float p = pan[lane];
    const float pl = 1.0f - fmaxf(p, 0.0f), pr = 1.0f + fminf(p, 0.0f);
    gl = s * g * pl + (1.0f - s) * g;
    gr = s * g * pr + (1.0f - s) * g;
    ratio = (1.0f - s) + s * detune[lane];
  } else if (mode == MODE_STEREO) {
    const float s = vf(d, LE_DRIFT_STEREO_DEPTH);
    const float p = lane == 0 ? -s : s;
    gl = LE_DRIFT_STEREO_GAIN * (1.0f - fmaxf(p, 0.0f));
    gr = LE_DRIFT_STEREO_GAIN * (1.0f + fminf(p, 0.0f));
    ratio = exp2f((lane == 0 ? -1.0f : 1.0f) * s * LE_DRIFT_STEREO_CENTS / 1200.0f);
  }
  const float w = vf(d, LE_DRIFT_DRIFT_DEPTH) / 0.58f;
  v->ratio = ratio * exp2f(w * key_cents(note) / 1200.0f);
  const float ng = note_gain(note_hz(note));
  v->gain_l = gl * ng;
  v->gain_r = gr * ng;
}

/* Starts (or retriggers) voice `v` on `note`. `retrigger`: the envelopes
 * restart (attack from the current level); otherwise the note only changes
 * pitch (legato). */
static void start_voice(le_drift* d, le_drift_voice* v, int32_t lane,
                        uint32_t origin, int32_t note, float velocity,
                        int retrigger) {
  const int was_silent = !sounding(v) || v->env1 < LE_DRIFT_SILENT;
  v->origin = origin;
  v->note = note;
  v->lane = lane;
  v->velocity = velocity;
  v->key = ((float)note - 69.0f) / 120.0f;
  v->serial = ++d->serial;
  v->hz_target = note_hz(note);
  if (vf(d, LE_DRIFT_GLIDE) <= 0.0f || d->last_hz <= 0.0f) {
    v->hz = v->hz_target;
  } else if (was_silent) {
    v->hz = d->last_hz;
  }
  lane_setup(d, v, lane, note);
  if (!retrigger && sounding(v)) {
    v->state = LE_DRIFT_VOICE_HELD;
    return;
  }
  if (was_silent) {
    v->env1 = v->env2 = 0.0f;
    if (vi(d, LE_DRIFT_RESET_OSC_PHASE)) v->ph1 = v->ph2 = 0.0f;
    memset(v->lp, 0, sizeof(v->lp));
    memset(v->hp, 0, sizeof(v->hp));
  }
  const int32_t shape = vi(d, LE_DRIFT_LFO_SHAPE);
  if (vi(d, LE_DRIFT_LFO_RETRIGGER) || shape >= 7) {
    v->lfo_ph = 0.0f;
    v->lfo_done = 0;
  }
  v->cyc_ph = 0.0f;
  v->stage1 = v->stage2 = STAGE_ATTACK;
  v->fade = 0.0f;
  v->state = LE_DRIFT_VOICE_HELD;
}

/* The group of `lanes` voices to play a new note on: a group whose first
 * voice holds `origin` (a restrike, unless `chord`) or plays `note`, else
 * the next free group round-robin, else the oldest. */
static int32_t pick_group(le_drift* d, uint32_t origin, int32_t note,
                          int chord) {
  const int32_t lanes = lanes_per_note(voice_mode(d));
  const int32_t n = pool_size(d);
  const int32_t groups = n / lanes;
  for (int32_t g = 0; g < groups; ++g) {
    const le_drift_voice* v = &d->voices[g * lanes];
    if (!chord && v->state == LE_DRIFT_VOICE_HELD && v->origin == origin) {
      return g;
    }
  }
  for (int32_t g = 0; g < groups; ++g) {
    const le_drift_voice* v = &d->voices[g * lanes];
    if (sounding(v) && v->note == note) return g;
  }
  for (int32_t k = 0; k < groups; ++k) {
    const int32_t g = (d->next_voice + k) % groups;
    const le_drift_voice* v = &d->voices[g * lanes];
    if (v->state == LE_DRIFT_VOICE_FREE) {
      d->next_voice = (g + 1) % groups;
      return g;
    }
  }
  int32_t best = 0;
  for (int32_t g = 1; g < groups; ++g) {
    if (d->voices[g * lanes].serial < d->voices[best * lanes].serial) best = g;
  }
  d->stolen++;
  return best;
}

static void start_group(le_drift* d, int32_t g, uint32_t origin, int32_t note,
                        float velocity, int retrigger) {
  const int32_t lanes = lanes_per_note(voice_mode(d));
  for (int32_t l = 0; l < lanes; ++l) {
    start_voice(d, &d->voices[g * lanes + l], l, origin, note, velocity,
                retrigger);
  }
  d->last_hz = note_hz(note);
}

static void release_voice(le_drift_voice* v) {
  v->state = LE_DRIFT_VOICE_RELEASED;
  v->stage1 = v->stage2 = STAGE_RELEASE;
}

int32_t le_drift_note_on(le_drift* d, uint32_t origin, int32_t note,
                         int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) {
    return -1;
  }
  const float vel = (float)velocity / 127.0f;
  if (voice_mode(d) == MODE_MONO) {
    const int held = d->mono_n > 0;
    if (d->mono_n == LE_DRIFT_MONO_STACK) {
      memmove(d->mono_note, d->mono_note + 1, sizeof(int32_t) * (LE_DRIFT_MONO_STACK - 1));
      memmove(d->mono_origin, d->mono_origin + 1, sizeof(uint32_t) * (LE_DRIFT_MONO_STACK - 1));
      memmove(d->mono_velocity, d->mono_velocity + 1, sizeof(float) * (LE_DRIFT_MONO_STACK - 1));
      d->mono_n--;
    }
    d->mono_note[d->mono_n] = note;
    d->mono_origin[d->mono_n] = origin;
    d->mono_velocity[d->mono_n] = vel;
    d->mono_n++;
    start_group(d, 0, origin, note, vel, !(held && vi(d, LE_DRIFT_LEGATO)));
    return 0;
  }
  start_group(d, pick_group(d, origin, note, chord), origin, note, vel, 1);
  return 0;
}

static void let_go(le_drift* d, le_drift_voice* v) {
  if (d->sustain_n > 0) {
    v->state = LE_DRIFT_VOICE_SUSTAINED;
  } else {
    release_voice(v);
  }
}

/* Mono: drops `origin`'s notes from the held stack; when the sounding note
 * was one, the newest left sounds (legato), or the voices let go. */
static void mono_note_off(le_drift* d, uint32_t origin) {
  const int32_t was = d->mono_n;
  int32_t keep = 0;
  for (int32_t i = 0; i < d->mono_n; ++i) {
    if (d->mono_origin[i] == origin) continue;
    d->mono_note[keep] = d->mono_note[i];
    d->mono_origin[keep] = d->mono_origin[i];
    d->mono_velocity[keep] = d->mono_velocity[i];
    keep++;
  }
  d->mono_n = keep;
  if (keep == was) return;
  le_drift_voice* v0 = &d->voices[0];
  if (v0->state != LE_DRIFT_VOICE_HELD || v0->origin != origin) return;
  if (keep > 0) {
    start_group(d, 0, d->mono_origin[keep - 1], d->mono_note[keep - 1],
                d->mono_velocity[keep - 1], 0);
    return;
  }
  for (int32_t l = 0; l < 4; ++l) let_go(d, &d->voices[l]);
}

void le_drift_note_off(le_drift* d, uint32_t origin) {
  if (d == NULL) return;
  if (voice_mode(d) == MODE_MONO) {
    mono_note_off(d, origin);
    return;
  }
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    le_drift_voice* v = &d->voices[i];
    if (v->state == LE_DRIFT_VOICE_HELD && v->origin == origin) let_go(d, v);
  }
}

static void release_sustained(le_drift* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    if (d->voices[i].state == LE_DRIFT_VOICE_SUSTAINED) release_voice(&d->voices[i]);
  }
}

int32_t le_drift_sustain(le_drift* d, uint32_t origin, int on) {
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
  if (d->sustain_n >= LE_DRIFT_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_drift_expression(le_drift* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = clampf(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_drift_release_matching(le_drift* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = d->mono_n - 1; i >= 0; --i) {
    /* mono_note_off compacts the stack: an index past its end was moved */
    if (i < d->mono_n && (d->mono_origin[i] & mask) == value) {
      mono_note_off(d, d->mono_origin[i]);
    }
  }
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    le_drift_voice* v = &d->voices[i];
    if (v->state == LE_DRIFT_VOICE_HELD && (v->origin & mask) == value) {
      let_go(d, v);
    } else if (v->state == LE_DRIFT_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(v);
    }
  }
}

int32_t le_drift_held(const le_drift* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    const le_drift_voice* v = &d->voices[i];
    if (v->state == LE_DRIFT_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_drift_cut(le_drift* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->mono_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_drift_active(const le_drift* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) n += sounding(&d->voices[i]);
  return n;
}

int32_t le_drift_fading(const le_drift* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    n += d->voices[i].state == LE_DRIFT_VOICE_FADING;
  }
  return n;
}

void le_drift_set_voice_limit(le_drift* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_DRIFT_VOICES ? LE_DRIFT_VOICES : limit;
  while (le_drift_active(d) > d->voice_limit) {
    le_drift_voice* old = NULL;
    for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
      le_drift_voice* v = &d->voices[i];
      if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
    }
    fade_voice(old);
  }
}

/* ---- Modulation ---- */

typedef struct drift_sources {
  float raw[LE_DRIFT_SOURCES];
  float bi[LE_DRIFT_SOURCES];  /* velocity centred at 64 */
  float uni[LE_DRIFT_SOURCES]; /* LFO in 0..1, Key clamped at 0 */
} drift_sources;

/* A gain-type modulation: amount a, unipolar source u. */
static float gain_mod(float a, float u) {
  const float m = fabsf(a);
  return (1.0f - m) + m * (a > 0.0f ? u : 1.0f - u);
}

static float lfo_shape(le_drift_voice* v, int32_t shape, float p) {
  switch (shape) {
    case 0:
      return sinf(TWO_PI * p);
    case 1:
      return tri(p);
    case 2:
      return p < 0.5f ? 2.0f * p : 2.0f * (p - 1.0f);
    case 3:
      return p < 0.5f ? -2.0f * p : -2.0f * (p - 1.0f);
    case 4:
      return p < 0.5f ? 1.0f : -1.0f;
    case 5:
      return v->lfo_hold;
    case 6: {
      const float t = frac(2.0f * p);
      const float e = t * t * (3.0f - 2.0f * t);
      return v->lfo_from + e * (v->lfo_to - v->lfo_from);
    }
    case 7:
      return v->lfo_done ? 0.0f : 1.0f - p;
    case 8: {
      if (v->lfo_done) return 0.0f;
      const float q = 1.0f - p;
      return q * q * q * q;
    }
    default:
      return 0.0f;
  }
}

/* Advances the LFO phase by `inc`, drawing new random steps at each half
 * cycle and ending a one-shot shape at its cycle's end. */
static void lfo_advance(le_drift_voice* v, float inc) {
  const float before = v->lfo_ph;
  float p = before + inc;
  const int wrapped = p >= 1.0f;
  if (wrapped) p -= floorf(p);
  if (wrapped) v->lfo_done = 1;
  if (wrapped || (before < 0.5f && p >= 0.5f)) {
    v->lfo_hold = rnd_bipolar(&v->rng);
    v->lfo_from = v->lfo_to;
    v->lfo_to = rnd_bipolar(&v->rng);
  }
  v->lfo_ph = p;
}

/* The cycling envelope's level at phase p. */
static float cycling(float p, float mid, float hold) {
  const float m = clampf((mid - 0.2f) / 0.6f, 0.0f, 1.0f);
  float tri_v;
  if (m <= 0.0f) {
    tri_v = 1.0f - p;
  } else if (m >= 1.0f) {
    tri_v = p;
  } else {
    tri_v = p < m ? p / m : (1.0f - p) / (1.0f - m);
  }
  float q = mid < 0.5f ? 1.0f - p : p;
  q = fmaxf(0.0f, (q - 0.2f) * 1.25f);
  q = q * q * q * q;
  const float b = clampf(5.0f * fminf(mid, 1.0f - mid), 0.0f, 1.0f);
  float y = b * tri_v + (1.0f - b) * q;
  y *= 1.0f / (1.0f - 0.95f * hold);
  return y > 1.0f ? 1.0f : y;
}

static float envelope(float* y, int32_t* stage, float attack, float dec,
                      float sustain, float rel, float rate) {
  switch (*stage) {
    case STAGE_ATTACK: {
      const float n = attack * rate;
      *y += n <= 1.0f ? 1.0f : 1.0f / n;
      if (*y >= 1.0f) {
        *y = 1.0f;
        *stage = STAGE_DECAY;
      }
      break;
    }
    case STAGE_DECAY:
      *y += dec * (sustain - *y);
      break;
    case STAGE_RELEASE:
      *y += rel * (0.0f - *y);
      break;
    default:
      break;
  }
  return *y;
}

/* ---- Filters ---- */

/* Low-pass type I: a zero-delay two-integrator loop with unequal integrator
 * gains (ratio 3.3: a 12 dB/oct slope with a soft knee), resonance as less
 * damping, pulled back above resonance 1 at high cutoffs, and a soft clip on
 * the band node that bounds self-oscillation. */
#define LE_DRIFT_F1_C 3.3f
static float filter1(float* s, float x, float fc, float r, float rate,
                     uint32_t* rng) {
  const float f = fc / rate;
  float rr = r / (1.0f + 1.5f * fmaxf(f - 0.075f, 0.0f) * 2.0f * fmaxf(r - 1.0f, 0.0f));
  if (rr < 0.001f) rr = 0.001f;
  const float g = prewarp(PI_F * f);
  const float sc = 1.8165902f; /* sqrt(3.3) */
  const float g1 = g / sc, g2 = g * sc;
  const float damp = (1.0f + 1.0f / LE_DRIFT_F1_C) * (1.0f - rr);
  x = x * 1.6666667f + 2e-5f * rnd_bipolar(rng);
  const float hp = (x - (damp + g2) * s[0] - s[1]) / (1.0f + damp * g1 + g1 * g2);
  const float bp = g1 * hp + s[0];
  const float lp = g2 * bp + s[1];
  s[0] = soft(bp + g1 * hp);
  s[1] = lp + g2 * bp;
  return lp;
}

/* One section of low-pass type II: an equal-integrator loop with an
 * asymmetric soft clip on the band node. */
static float filter2_section(float* s, float x, float g, float damp) {
  const float hp = (x - (damp + g) * s[0] - s[1]) / (1.0f + damp * g + g * g);
  const float bp = g * hp + s[0];
  const float lp = g * bp + s[1];
  s[0] = soft(bp + g * hp + LE_DRIFT_F2_OFFSET) - soft(LE_DRIFT_F2_OFFSET);
  s[1] = lp + g * bp;
  return lp;
}

static float filter2(float* s, float x, float fc, float r, float rate) {
  r = fminf(r, 1.3f);
  const float q = 4.0f * r / (3.0f * r + 1.0f) + 4.0f * fmaxf(r - 1.0f, 0.0f) *
                                                     fmaxf(r - 1.0f, 0.0f);
  const float damp = filter2_damping(q);
  const float g = prewarp(PI_F * fc / rate);
  const float a = filter2_section(s, x * 3.0f, g, damp);
  return filter2_section(s + 2, a, g, damp) * (1.6666667f / 3.0f);
}

/* The high-pass: a linear two-integrator loop, damping 0.68. */
static float highpass(float* s, float x, float fc, float rate) {
  const float k = 0.6802721f;
  const float g = prewarp(PI_F * fc / rate);
  const float hp = (x - (k + g) * s[0] - s[1]) / (1.0f + k * g + g * g);
  const float bp = g * hp + s[0];
  const float lp = g * bp + s[1];
  s[0] = bp + g * hp;
  s[1] = lp + g * bp;
  return hp;
}

/* ---- the voice, one sample ---- */


static const float kPitchRange[LE_DRIFT_SOURCES] = {4.0f, 4.0f, 2.0f, 10.0f,
                                                     4.0f, 2.0f, 2.0f, 2.0f};

static void voice_sample(le_drift* d, le_drift_voice* v, float* out_l,
                         float* out_r) {
  const le_drift_derived* x = &d->d;
  const le_drift_derived* b = x;
  const float rate = x->rate;
  /* sources */
  drift_sources src;
  const float env1 = envelope(&v->env1, &v->stage1, x->env1_att, x->env1_dec,
                              b->sustain1, x->env1_rel, rate);
  float env2;
  if (b->cycling) {
    env2 = cycling(v->cyc_ph, b->cyc_mid, b->cyc_hold);
  } else {
    env2 = envelope(&v->env2, &v->stage2, x->env2_att, x->env2_dec, b->sustain2,
                    x->env2_rel, rate);
  }
  const int one_shot = b->lfo_shape >= 7;
  src.raw[LE_DRIFT_SRC_ENV1] = env1;
  src.raw[LE_DRIFT_SRC_ENV2] = env2;
  src.raw[LE_DRIFT_SRC_LFO] = 0.0f; /* the LFO's own gain cannot read itself */
  src.raw[LE_DRIFT_SRC_KEY] = v->key;
  src.raw[LE_DRIFT_SRC_VELOCITY] = v->velocity;
  src.raw[LE_DRIFT_SRC_MODWHEEL] = d->mod;
  src.raw[LE_DRIFT_SRC_PRESSURE] = d->pressure;
  src.raw[LE_DRIFT_SRC_SLIDE] = 0.0f;
  const float lfo_gain =
      gain_mod(b->lfo_mod_amt, fmaxf(0.0f, b->lfo_src == LE_DRIFT_SRC_KEY
                                               ? fmaxf(v->key, 0.0f)
                                               : src.raw[b->lfo_src]));
  const float lfo = lfo_shape(v, b->lfo_shape, v->lfo_ph) * b->lfo_amt * lfo_gain;
  src.raw[LE_DRIFT_SRC_LFO] = lfo;
  for (int i = 0; i < LE_DRIFT_SOURCES; ++i) {
    src.bi[i] = src.raw[i];
    src.uni[i] = src.raw[i];
  }
  src.bi[LE_DRIFT_SRC_VELOCITY] = v->velocity - 64.0f / 127.0f;
  src.uni[LE_DRIFT_SRC_LFO] = one_shot ? lfo : 0.5f * (lfo + 1.0f);
  src.uni[LE_DRIFT_SRC_KEY] = fmaxf(v->key, 0.0f);
  /* the matrix */
  float add_shape = 0.0f, add_detune = 0.0f, add_lp = 0.0f, add_res = 0.0f,
        add_hp = 0.0f, add_lfo = 0.0f, add_cyc = 0.0f;
  float g_osc1 = 1.0f, g_osc2 = 1.0f, g_noise = 1.0f, g_main = 1.0f;
  for (int m = 0; m < 3; ++m) {
    const float a = b->mtx_amt[m];
    const int32_t s = b->mtx_src[m];
    switch (b->mtx_tgt[m]) {
      case LE_DRIFT_TGT_OSC1_GAIN:
        g_osc1 *= gain_mod(a, src.uni[s]);
        break;
      case LE_DRIFT_TGT_OSC1_SHAPE:
        add_shape += a * src.bi[s];
        break;
      case LE_DRIFT_TGT_OSC2_GAIN:
        g_osc2 *= gain_mod(a, src.uni[s]);
        break;
      case LE_DRIFT_TGT_OSC2_DETUNE:
        add_detune += a * src.raw[s];
        break;
      case LE_DRIFT_TGT_NOISE_GAIN:
        g_noise *= gain_mod(a, src.uni[s]);
        break;
      case LE_DRIFT_TGT_LP_FREQ:
        add_lp += a * src.bi[s];
        break;
      case LE_DRIFT_TGT_LP_RES:
        add_res += a * src.bi[s];
        break;
      case LE_DRIFT_TGT_HP_FREQ:
        add_hp += a * src.bi[s];
        break;
      case LE_DRIFT_TGT_LFO_RATE:
        add_lfo += a * src.raw[s];
        break;
      case LE_DRIFT_TGT_CYC_RATE:
        add_cyc += a * src.raw[s];
        break;
      case LE_DRIFT_TGT_MAIN_VOLUME:
        g_main *= gain_mod(a, src.uni[s]);
        break;
      default:
        break;
    }
  }
  /* pitch */
  v->hz += b->glide * (v->hz_target - v->hz);
  float pitch = b->pm_amt[0] * src.bi[b->pm_src[0]] * kPitchRange[b->pm_src[0]] +
                b->pm_amt[1] * src.bi[b->pm_src[1]] * kPitchRange[b->pm_src[1]];
  const float base = v->hz * v->ratio * b->bend_ratio * exp2f(pitch);
  const float f1 = base * x->osc1_ratio;
  const float f2 = base * x->osc2_ratio * exp2f(add_detune);
  const float dt1 = fminf(f1 / rate, 0.4999999f);
  const float dt2 = fminf(f2 / rate, 0.4999999f);
  v->ph1 += dt1;
  if (v->ph1 >= 1.0f) v->ph1 -= 1.0f;
  v->ph2 += dt2;
  if (v->ph2 >= 1.0f) v->ph2 -= 1.0f;
  /* the LFO's and the cycling envelope's rates */
  const float lfo_hz = (b->lfo_mode == 1 ? b->lfo_ratio * v->hz : x->lfo_hz) *
                       exp2f(4.0f * add_lfo);
  lfo_advance(v, fminf(lfo_hz / rate, 0.49999988f));
  const float cyc_hz = (b->cyc_mode == 1 ? b->cyc_ratio * v->hz : x->cyc_hz) *
                       exp2f(4.0f * add_cyc);
  v->cyc_ph += fminf(cyc_hz / rate, 0.49999988f);
  if (v->cyc_ph >= 1.0f) v->cyc_ph -= 1.0f;
  /* oscillators and noise */
  const float shape = b->shape + b->shape_mod * src.raw[b->shape_src] + add_shape;
  const float s1 = x->osc1 == WAVE_SATURATED ? fmaxf(shape, 0.0f)
                   : x->osc1 == WAVE_RECTANGLE ? clampf(shape, -1.0f, 1.0f)
                                               : clampf(shape, 0.0f, 1.0f);
  const float o1 = oscillator(x->osc1, v->ph1, s1, dt1) * x->gain1 * g_osc1;
  const float o2 = oscillator(x->osc2, v->ph2, 0.0f, dt2) * x->gain2 * g_osc2;
  float noise = 0.0f;
  if (x->gain_noise > 0.0f) {
    const float r1 = rnd_bipolar(&v->rng);
    const float u2 = rnd_unit(&v->rng);
    noise = clampf(half_sine(fabsf(r1)) * (r1 < 0.0f ? -1.0f : 1.0f) *
                       sqrtf(-2.0f * logf(u2)),
                   -10.0f, 10.0f) *
            x->gain_noise * g_noise;
  }
  /* mixer and routing */
  float thru = 0.0f, around = 0.0f;
  if (x->thru1) thru += o1; else around += o1;
  if (x->thru2) thru += o2; else around += o2;
  if (x->thru_noise) thru += noise; else around += noise;
  /* filters */
  float fc = b->freq * key_tracking(b->tracking, v->key) *
             exp2f(10.0f * (b->fm_amt[0] * src.bi[b->fm_src[0]] +
                            b->fm_amt[1] * src.bi[b->fm_src[1]] + add_lp));
  fc = clampf(fc, 10.0f, fminf(20000.0f, 0.45f * rate));
  const float res = clampf(x->res + add_res, 0.0f, 1.3f);
  float y = clampf(thru, -1.6f, 1.6f) * 0.25f;
  y = x->filter_type ? filter2(v->lp, y, fc, res, rate)
                                  : filter1(v->lp, y, fc, res, rate, &v->rng);
  y *= 0.3162278f; /* -10 dB */
  const float hc = clampf(x->hp_hz * exp2f(10.0f * add_hp), 20.0f,
                          fminf(20000.0f, 0.45f * rate));
  y = highpass(v->hp, y, hc, rate);
  y += around * 0.12821534f;
  y = clampf(y, -LE_DRIFT_VOICE_CLIP, LE_DRIFT_VOICE_CLIP);
  /* amplitude */
  float amp = env1 * (1.0f - b->vol_vel + b->vol_vel * v->velocity) * g_main *
              x->volume;
  if (v->state == LE_DRIFT_VOICE_FADING) {
    amp *= v->fade;
    v->fade -= x->fade_step;
    if (v->fade <= 0.0f) v->state = LE_DRIFT_VOICE_FREE;
  }
  y *= amp;
  *out_l += y * v->gain_l;
  *out_r += y * v->gain_r;
  if (v->stage1 == STAGE_RELEASE && v->env1 < LE_DRIFT_SILENT) {
    v->state = LE_DRIFT_VOICE_FREE;
    v->stage1 = v->stage2 = STAGE_IDLE;
  }
}

/* One output sample at the device's internal rate: every live voice. */
static void tick(le_drift* d, float* l, float* r) {
  *l = 0.0f;
  *r = 0.0f;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    le_drift_voice* v = &d->voices[i];
    if (v->state == LE_DRIFT_VOICE_FREE) continue;
    voice_sample(d, v, l, r);
  }
}

/* HiQuality: two internal samples in, one out. */
static void decimate(le_drift* d, const float* l2, const float* r2, float* l,
                     float* r) {
  for (int k = 0; k < 2; ++k) {
    d->hb_l[d->hb_pos] = l2[k];
    d->hb_r[d->hb_pos] = r2[k];
    d->hb_pos = (d->hb_pos + 1) % LE_DRIFT_HB_TAPS;
  }
  float sl = 0.0f, sr = 0.0f;
  int32_t at = d->hb_pos; /* the oldest sample */
  for (int i = 0; i < LE_DRIFT_HB_TAPS; ++i) {
    const float h = d->hb_taps[i];
    sl += h * d->hb_l[at];
    sr += h * d->hb_r[at];
    at = at + 1 == LE_DRIFT_HB_TAPS ? 0 : at + 1;
  }
  *l = sl;
  *r = sr;
}

void le_drift_render(le_drift* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  for (int32_t f = 0; f < frames; ++f) {
    if (d->chunk_left <= 0) {
      derive(d);
      d->chunk_left = LE_DRIFT_CHUNK;
    }
    d->chunk_left--;
    if (d->oversample == 2) {
      float l2[2], r2[2];
      tick(d, &l2[0], &r2[0]);
      tick(d, &l2[1], &r2[1]);
      decimate(d, l2, r2, &left[f], &right[f]);
    } else {
      tick(d, &left[f], &right[f]);
    }
  }
}
