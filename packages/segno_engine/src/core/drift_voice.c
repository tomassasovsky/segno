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
/* A voice waiting to restart (Reset Oscillator Phase) falls exponentially
 * from full level to silence in this many milliseconds. Measured: Live's
 * legato restart, 0.866 per sample at 48 kHz. */
#define LE_DRIFT_PENDING_MS 1.0f

/* ---- P4: the values the behavior description leaves open ----
 *
 * Fitted (2026-11-25) against Live 12.2.7 renders of controlled patches (a
 * plain saw or white noise, one setting changed per render; see the
 * SEG-109 comments for the measurements), or still provisional where
 * marked. */

/* Voice counts 0..4: the voices (lanes) a note may take, so Stereo plays
 * half as many notes and Unison a quarter. */
static const int32_t kVoiceCounts[5] = {4, 8, 16, 24, 32};

/* The Sync divisions 0..21 in beats per cycle, slowest first: 8 bars down
 * to a 64th. Fitted: each division's vibrato rate at 120 BPM (indexes 7 to
 * 21 within 0.3 %; the slower ones take longer than the measurement). */
static const float kSyncBeats[22] = {
    32.0f, 24.0f, 16.0f, 12.0f, 8.0f, 6.0f, 4.0f, 3.0f,
    2.0f, 1.5f, 1.333333f, 1.25f, 1.0f, 0.75f, 0.666667f, 0.5f,
    0.333333f, 0.25f, 0.166667f, 0.125f, 0.083333f, 0.0625f};

/* The LFO's and the cycling envelope's rate modes, in the stored order.
 * Fitted: Time 1 s gives 1 Hz in mode 1, Ratio runs at audio rate in
 * mode 2. */
enum { RATE_FREQ = 0, RATE_TIME = 1, RATE_RATIO = 2, RATE_SYNC = 3 };

/* Decay and release reach LE_DRIFT_SILENT of their distance at the stage
 * time. Fitted: attack 50 % / 90 % points, sustain and the release's
 * -20 / -40 / -60 dB times match Live within 5 ms. */
static float envelope_coefficient(float seconds, float rate) {
  const float n = seconds * rate;
  if (n <= 1.0f) return 1.0f;
  return 1.0f - expf(-6.9077553f / n); /* ln(0.001) */
}

/* Volume 0..1 to gain: linear, +6 dB per doubling. Fitted at 0.25, 0.5,
 * 0.75 and 1 (within 0.1 dB), together with the noise level and the
 * filters' gains below (a saw and noise through each path). */
static float volume_gain(float v) { return 2.58f * v; }

/* Glide: a one-pole in frequency (hertz, not pitch: a rising glide covers
 * its first semitones fastest) with time constant 0.144 x Glide.
 * Fitted on Live's octave glides at 0.5, 1 and 2 s (Mono, legato): the
 * distance in hertz falls by the same ratio every 50 ms. */
static float glide_coefficient(float seconds, float rate) {
  const float n = 0.144f * seconds * rate;
  if (n <= 1.0f) return 1.0f;
  return 1.0f - expf(-1.0f / n);
}

/* Key tracking: the cutoff scaled by a blend, in hertz, of 1 and the
 * note's frequency over A4's, weighted by Tracking: 1:1 about A4 at
 * Tracking 1. Measured: filter II's peak at Tracking 0.3 on C3, C4 and C5
 * and at 1 on C3, and Bloom Pad's cutoff (an octave scale, the old form,
 * put C3 at 0.3 190 cents low). */
static float key_tracking(float tracking, float key) {
  return (1.0f - tracking) + tracking * exp2f(10.0f * key);
}

/* Stereo mode: the pair panned to -Spread and +Spread with sides
 * 0.5 (1 -+ pan), no detune. Fitted: Spread 0 and 1 both equal a Poly
 * voice's level on each side, and both sides stay on pitch. */
#define LE_DRIFT_STEREO_GAIN 0.5f

/* The output clip of a voice (after the high-pass and the bypass sum).
 * Measured: a saw at Gain 2 and two at Gain 2 into either filter at
 * resonance 0.7 (round 19) peak at the same level in Live at C2 and C4
 * (after the note gain), flat-topped; at 0.35 their harmonics 1 to 24 come
 * within 1.7 dB rms of Live's (from 4.3 to 8.4 at no clip). */
#define LE_DRIFT_VOICE_CLIP 0.35f

/* The noise generator's level: unit-variance Gaussian x this, per sample
 * at the host's rate (so its level per hertz falls 3 dB when the rate
 * doubles). Fitted on the filter bypass path at 48 kHz. */
#define LE_DRIFT_NOISE_LEVEL 0.3274f

/* The paths around the filters: oscillators and noise. Fitted: a sine and
 * noise routed around, each within 0.2 dB. */
#define LE_DRIFT_BYPASS_OSC 0.1572f
#define LE_DRIFT_BYPASS_NOISE 0.12821534f

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
    [LE_DRIFT_CYC_SYNCED_RATE] = {15.0f, 0.0f, 21.0f, 1},
    [LE_DRIFT_CYC_MIDPOINT] = {0.5f, 0.0f, 1.0f, 0},
    [LE_DRIFT_CYC_HOLD] = {0.0f, 0.0f, 1.0f, 0},
    [LE_DRIFT_LFO_MODE] = {0.0f, 0.0f, 3.0f, 1},
    [LE_DRIFT_LFO_SHAPE] = {0.0f, 0.0f, 8.0f, 1},
    [LE_DRIFT_LFO_RATE] = {1.0f, 0.17f, 1700.0f, 0},
    [LE_DRIFT_LFO_RATIO] = {1.0f, 0.25f, 16.0f, 0},
    [LE_DRIFT_LFO_TIME] = {1.0f, 0.1f, 60.0f, 0},
    [LE_DRIFT_LFO_SYNCED_RATE] = {15.0f, 0.0f, 21.0f, 1},
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
    [LE_DRIFT_SERIAL_NUMBER] = {0.0f, 0.0f, 8388607.0f, 1},
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

/* Shark Tooth's window width w by Shape: a near-triangle at 0 narrowing
 * toward a saw at 1. The oscillator plays it negated and backwards in
 * time: at 1 a falling ramp that rises back fast (the dip). Fitted: Live's
 * renders at six shapes within 1.5 dB rms per sixth-octave band, and
 * Live's waveform under an LFO sweeping the shape from -1 to 1 (each
 * period's correlation 0.99 up to shape 0.5, where the old direction gave
 * -1, and the narrow top widths), joined linearly. */
static float shark_width(float s) {
  static const float kS[6] = {0.0f, 0.135f, 0.25f, 0.5f, 0.75f, 1.0f};
  static const float kW[6] = {0.906f, 0.779f, 0.676f, 0.463f, 0.24f, 0.06f};
  /* past the ends (modulation drives the shape outside 0..1) the width
   * follows the nearest segment's slope, within 0.03..1 */
  if (s <= 0.0f) return fminf(1.0f, kW[0] + s * (kW[1] - kW[0]) / kS[1]);
  if (s >= 1.0f) return fmaxf(0.03f, kW[5] + (s - 1.0f) * (kW[5] - kW[4]) / 0.25f);
  for (int i = 1; i < 6; ++i) {
    if (s <= kS[i]) {
      const float t = (s - kS[i - 1]) / (kS[i] - kS[i - 1]);
      return kW[i - 1] + t * (kW[i] - kW[i - 1]);
    }
  }
  return kW[5];
}

static float osc_shark(float th, float s, float dt) {
  const float w = shark_width(s);
  const float lo = 0.75f - 0.5f * w;
  const float hi = 0.75f + 0.5f * w;
  float y;
  /* the window wraps past the cycle's end once w > 0.5 */
  if (frac(th - lo) < w) {
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
      return -osc_shark(frac(1.0f - th), s, dt);
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

/* Drift Depth's tuning: a deviation per key plus one per voice, both fixed
 * (neither moves over time, nor between strikes, nor between instances),
 * linear in w = Drift Depth / 0.58, in cents per unit of w. Measured on
 * Live 12.2.7's renders (rounds 17 and 18, a sine at Drift Depth 1): the
 * per-voice offsets from each lane of 16 Stereo pairs alone on its channel
 * (pair p is voices 2p and 2p + 1, at notes 84 + p); the per-key ones on
 * C1..B5 from voice 0 one key at a time and from every voice at once
 * (Stereo pairs at notes 28..43 and 48..63), minus the voice's offset. The
 * per-voice offset does not depend on the key, the per-key one follows the
 * key played (not Transpose), and keys outside C1..B5 have none (0.00 +-
 * 0.06 cents on Live's renders of keys 0..23 and 84..127). */
static const float kKeyCents[60] = {
    -0.17f, -2.40f, -5.12f, -4.06f, -4.36f, 1.83f, 5.63f, 14.06f, 9.53f, 6.27f,
    0.88f, -0.99f, -2.83f, -2.40f, -2.74f, 0.41f, -0.14f, 5.78f, 7.47f, 5.27f,
    1.22f, -1.58f, -2.10f, -1.00f, -1.50f, 0.10f, -0.39f, 0.41f, 1.96f, 4.81f,
    6.56f, 1.79f, 0.39f, -1.57f, 0.14f, 12.94f, 0.49f, 0.10f, -0.98f, 0.96f,
    0.90f, 2.83f, 3.29f, -0.43f, -1.28f, -0.00f, 0.13f, 0.41f, 0.16f, 1.35f,
    1.09f, 0.12f, 0.38f, -0.14f, 0.96f, 0.68f, 0.81f, 1.18f, -2.28f, 0.40f,
};
/* The per-voice offsets depend on the preset's SerialNumber (each serial
 * its own values; the per-key table is the same for all). Measured for the
 * three serials Live's factory presets hold, 0 (also -2147483648, which
 * Live clamps to 0), 2217915 and 8388607 (also every value above, which
 * Live clamps to it): per voice from each lane of 16 Stereo pairs alone on
 * its channel at notes 84..99 (rounds 17 and 20; serials 2217915 and
 * 8388607 cross-checked within 0.2 cent on their pairs at 24..83); Osc 2's
 * extra from Osc 2 alone on the same pairs (rounds 19 and 20), the same
 * within 0.14 cent at keys 8..83, at Osc 2 -1 octave, Detune +7 and
 * Transpose +24. Any other serial has values of its own in Live (1, 12345
 * measured: 17 and 20 cents rms from serial 0's); Segno uses serial 0's
 * for them. */
enum { TUNING_SETS = 3 };
static const int32_t kTuningSerials[TUNING_SETS] = {0, 2217915, 8388607};
static const float kVoiceCents[TUNING_SETS][32] = {
    {2.48f, 9.20f, 9.57f, 9.28f, -2.86f, 8.99f, -4.34f, 3.96f, 5.89f, 2.19f,
     1.00f, 6.91f, -7.42f, -3.03f, 10.76f, -1.34f, 2.89f, -4.67f, -12.33f,
     3.59f, -4.33f, 4.67f, -4.88f, 7.44f, -11.87f, -1.30f, -12.83f, -1.56f,
     9.76f, 0.24f, 11.13f, 11.25f},
    {-11.79f, -11.91f, -6.31f, 4.99f, 6.26f, -11.56f, -12.12f, -1.21f, -4.17f,
     5.03f, -13.33f, 10.91f, 12.79f, -7.13f, -4.49f, 1.34f, 10.98f, 0.99f,
     10.78f, -8.11f, -3.59f, -10.64f, -10.95f, -11.65f, 10.30f, 4.25f, -0.40f,
     7.65f, -7.38f, 10.99f, -5.35f, -7.51f},
    {-3.90f, -5.35f, 12.87f, -3.67f, -4.73f, 11.47f, -3.45f, -0.21f, -7.71f,
     4.26f, -5.93f, -9.95f, -8.52f, 10.62f, -5.80f, 1.59f, -4.39f, 5.13f,
     -11.09f, -2.32f, 2.58f, 4.69f, 10.99f, 2.39f, -12.83f, 1.60f, 4.39f,
     4.62f, 8.43f, -12.37f, 9.26f, -5.62f},
};
static const float kOsc2VoiceCents[TUNING_SETS][32] = {
    {0.21f, -0.19f, -0.34f, -0.74f, -0.22f, 0.76f, -0.60f, 0.62f, -0.66f,
     -0.04f, -0.53f, 0.40f, 0.19f, 0.67f, -0.67f, 0.79f, 0.76f, 0.25f, 0.22f,
     0.83f, 0.75f, 0.27f, -0.81f, 0.21f, 0.80f, -0.23f, -0.03f, 0.31f, -0.70f,
     -0.37f, -0.82f, 0.57f},
    {0.70f, -0.20f, 0.83f, -0.49f, -0.39f, -0.81f, -0.82f, 0.76f, 0.75f,
     0.51f, -0.16f, -0.54f, -0.77f, -0.05f, 0.25f, 0.41f, 0.26f, -0.12f,
     0.79f, 0.52f, -0.44f, 0.21f, -0.60f, 0.01f, 0.32f, 0.55f, -0.56f, -0.25f,
     0.32f, -0.15f, -0.76f, 0.70f},
    {0.54f, -0.50f, -0.66f, 0.02f, 0.09f, -0.40f, 0.08f, 0.15f, 0.49f, -0.33f,
     0.01f, 0.31f, -0.20f, 0.77f, -0.83f, 0.52f, -0.10f, -0.40f, -0.32f,
     0.58f, -0.04f, 0.40f, -0.41f, -0.83f, 0.59f, -0.83f, -0.24f, 0.30f,
     -0.67f, -0.10f, -0.38f, -0.78f},
};

/* The tuning set a serial picks: its own measured one, else serial 0's. */
static int32_t tuning_set(int32_t serial) {
  for (int32_t i = 1; i < TUNING_SETS; ++i) {
    if (serial == kTuningSerials[i]) return i;
  }
  return 0;
}

/* Loads tuning set `t` into the per-voice tables. */
static void load_tuning(le_drift* d, int32_t t) {
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    d->voice_cents[i] = kVoiceCents[t][i];
    d->osc2_cents[i] = kOsc2VoiceCents[t][i];
  }
  d->tuning_set = t;
}

static float key_cents(int32_t note) {
  return note < 24 || note > 83 ? 0.0f : kKeyCents[note - 24];
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

/* The phase a shape's LFO starts at: Sine and Triangle at their peak
 * (0.25), the saws at 0.5, the rest at 0. */
static float lfo_start_phase(int32_t shape) {
  return shape <= 1 ? 0.25f : shape <= 3 ? 0.5f : 0.0f;
}

/* A new random step for Sample & Hold (held) and Wander (the glide's new
 * end, from the last one). */
static void lfo_draw(le_drift_voice* v) {
  v->lfo_from = v->lfo_to;
  v->lfo_to = rnd_bipolar(&v->rng);
  v->lfo_hold = v->lfo_to;
}

static void derive(le_drift* d) {
  le_drift_derived* x = &d->d;
  /* The first chunk and a voice mode change reset the voice blocks: every
   * voice's LFO to its shape's start phase. Measured: a free-running LFO
   * (Retrigger off) starts Live's renders at that phase plus the time
   * since the reset. */
  if (d->block_mode != vi(d, LE_DRIFT_VOICE_MODE)) {
    d->block_mode = vi(d, LE_DRIFT_VOICE_MODE);
    for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
      d->voices[i].lfo_ph = lfo_start_phase(vi(d, LE_DRIFT_LFO_SHAPE));
      lfo_draw(&d->voices[i]);
    }
  }
  {
    const int32_t t = tuning_set(vi(d, LE_DRIFT_SERIAL_NUMBER));
    if (t != d->tuning_set) load_tuning(d, t);
  }
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
  x->env1_dec = envelope_coefficient(vf(d, LE_DRIFT_ENV1_DECAY), d->rate);
  x->env1_rel = envelope_coefficient(vf(d, LE_DRIFT_ENV1_RELEASE), d->rate);
  x->env2_dec = envelope_coefficient(vf(d, LE_DRIFT_ENV2_DECAY), d->rate);
  x->env2_rel = envelope_coefficient(vf(d, LE_DRIFT_ENV2_RELEASE), d->rate);
  x->volume = volume_gain(vf(d, LE_DRIFT_VOLUME));
  x->hp_hz = vf(d, LE_DRIFT_FILTER_HP_FREQ);
  x->res = vf(d, LE_DRIFT_FILTER_RES);
  switch (vi(d, LE_DRIFT_LFO_MODE)) {
    case RATE_TIME:
      x->lfo_hz = 1.0f / vf(d, LE_DRIFT_LFO_TIME);
      break;
    case RATE_SYNC:
      x->lfo_hz = sync_hz(d, vi(d, LE_DRIFT_LFO_SYNCED_RATE));
      break;
    default:
      x->lfo_hz = vf(d, LE_DRIFT_LFO_RATE);
      break;
  }
  switch (vi(d, LE_DRIFT_CYC_MODE)) {
    case RATE_TIME:
      x->cyc_hz = 1.0f / vf(d, LE_DRIFT_CYC_TIME);
      break;
    case RATE_SYNC:
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
  x->pending_fall = powf(LE_DRIFT_SILENT, 1.0f / (LE_DRIFT_PENDING_MS * 0.001f * d->rate));
  /* a voice never played turns at A4 with its own drift (tick) */
  const float w = vf(d, LE_DRIFT_DRIFT_DEPTH) / 0.58f;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    le_drift_voice* v = &d->voices[i];
    if (v->played) continue;
    const float f =
        440.0f * exp2f(w * (d->key_cents[69] + d->voice_cents[i]) / 1200.0f);
    v->dt1 = fminf(f * x->osc1_ratio / d->rate, 0.4999999f);
    v->dt2 = fminf(f * x->osc2_ratio * exp2f(w * d->osc2_cents[i] / 1200.0f) /
                       d->rate,
                   0.4999999f);
    /* and its LFO, in Ratio mode, at Ratio x A4: measured, a free LFO's
     * phase at a fresh voice's first note */
    v->lfo_inc = fminf(x->lfo_ratio * 440.0f / d->rate, 0.49999988f);
  }
}


/* Clears the low-pass state for filter type `kind` (the two types keep
 * different states in lp: filter II's are in circuit volts). */
static void clear_lowpass(const le_drift* d, le_drift_voice* v, int32_t kind) {
  if (kind) {
    memcpy(v->lp, d->f2_rest, sizeof(v->lp));
  } else {
    memset(v->lp, 0, sizeof(v->lp));
  }
  v->lp_kind = kind;
}

static void f2_rest_state(float* s);

/* ---- lifecycle and parameters ---- */

int32_t le_drift_init(le_drift* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_DRIFT_VOICES;
  for (int32_t p = 0; p < LE_DRIFT_PARAMS; ++p) d->values[p] = kParams[p].def;
  d->rate = (float)sample_rate;
  derive(d);
  d->block_mode = -1; /* the blocks reset at the first chunk rendered */
  for (int32_t n = 0; n < 128; ++n) {
    d->note_gain[n] = note_gain(note_hz(n));
    d->key_cents[n] = key_cents(n);
  }
  f2_rest_state(d->f2_rest);
  load_tuning(d, 0);
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    d->voices[i].rng = 0x9e3779b9u ^ (uint32_t)(i * 2654435761u);
    d->voices[i].lfo_mod = 1.0f;
    clear_lowpass(d, &d->voices[i], 0);
    /* each block's noise generators start alike: lane k of every block */
    d->noise_rng[i] = 0x2545f491u ^ (uint32_t)((i % 4) * 2654435761u);
  }
  return 0;
}

void le_drift_set_values(le_drift* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_DRIFT_PARAMS; ++p) {
    d->values[p] = le_drift_clamp(p, values[p]);
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
  v->pending = 0;
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
    /* lanes from sharpest (left) to flattest (right), as the code orders
     * them; measured with each voice's drift (Unison renders at Drift
     * Depth 0.63 and Bloom Pad) */
    static const float pan[4] = {-1.0f, -0.5f, 0.5f, 1.0f};
    static const float detune[4] = {1.0245496f, 1.0122024f, 0.9879406f, 0.9760254f};
    const float s = vf(d, LE_DRIFT_UNISON_DEPTH);
    const float g = 0.4731513f; /* -6.5 dB */
    const float p = pan[lane];
    /* equal power: 1 on the side it is panned to, 0.707 at the centre */
    const float pl = cosf((p + 1.0f) * 0.25f * PI_F);
    const float pr = sinf((p + 1.0f) * 0.25f * PI_F);
    gl = s * g * pl + (1.0f - s) * g;
    gr = s * g * pr + (1.0f - s) * g;
    ratio = (1.0f - s) + s * detune[lane];
  } else if (mode == MODE_STEREO) {
    const float s = vf(d, LE_DRIFT_STEREO_DEPTH);
    const float p = lane == 0 ? -s : s;
    gl = LE_DRIFT_STEREO_GAIN * (1.0f - p);
    gr = LE_DRIFT_STEREO_GAIN * (1.0f + p);
  }
  const float w = vf(d, LE_DRIFT_DRIFT_DEPTH) / 0.58f;
  const float cents = d->key_cents[note] + d->voice_cents[v - d->voices];
  v->ratio = ratio * exp2f(w * cents / 1200.0f);
  v->osc2_drift = exp2f(w * d->osc2_cents[v - d->voices] / 1200.0f);
  /* the Ratio rate modes follow a Mono lane's octave and the per-key
   * tuning, not Unison's detune nor the per-voice tuning (measured: round
   * 19's Ratio LFO on a pitch slot in Mono, Unison and Stereo at Drift
   * Depth 1; Crunch Arcade's Mono LFO at Ratio 12) */
  v->ref_ratio = (mode == MODE_MONO ? ratio : 1.0f) *
                 exp2f(w * d->key_cents[note] / 1200.0f);
  const float ng = d->note_gain[note];
  v->gain_l = gl * ng;
  v->gain_r = gr * ng;
}

static void begin_note(le_drift* d, le_drift_voice* v, int was_silent);

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
  v->played = 1;
  v->velocity = velocity;
  v->key = ((float)note - 69.0f) / 120.0f;
  v->serial = ++d->serial;
  /* A voice glides only from a pitch it is sounding (Mono, legato, a voice
   * struck again): fitted, a new Poly voice starts on its note. */
  v->pitch_target = note_hz(note);
  if (vf(d, LE_DRIFT_GLIDE) <= 0.0f || was_silent) v->pitch = v->pitch_target;
  lane_setup(d, v, lane, note);
  v->state = LE_DRIFT_VOICE_HELD;
  /* With Reset Oscillator Phase on, a note on a sounding voice (legato
   * included) is held while the voice falls silent fast, then starts from
   * silence with its phases reset (begin_note). Measured: Live's legato
   * note in Mono goes silent in 1 ms and restarts at phase 0, its glide
   * running on. */
  if (!was_silent && vi(d, LE_DRIFT_RESET_OSC_PHASE)) {
    v->pending = 1;
    return;
  }
  if (!retrigger && sounding(v)) return;
  begin_note(d, v, was_silent);
}

/* The envelopes and the per-note state of a note starting on voice `v`. */
static void begin_note(le_drift* d, le_drift_voice* v, int was_silent) {
  if (was_silent) {
    v->env1 = v->env2 = 0.0f;
    /* Reset Oscillator Phase starts a silent voice at phase 0; otherwise it
     * keeps the phase its last note left. Fitted: a note's lanes on fresh
     * voices start together (Live's Stereo pair at Drift 0 is mono), and
     * once voices are reused a Stereo note's lanes start apart. */
    if (vi(d, LE_DRIFT_RESET_OSC_PHASE)) v->ph1 = v->ph2 = 0.0f;
    clear_lowpass(d, v, vi(d, LE_DRIFT_FILTER_TYPE));
    memset(v->hp, 0, sizeof(v->hp));
  }
  const int32_t shape = vi(d, LE_DRIFT_LFO_SHAPE);
  /* Retrigger (and a one-shot shape) restarts the voice's LFO: Sine and
   * Triangle at their peak (0.25), the saws at 0.5, the rest at 0; without
   * it the note continues the phase the voice's LFO stopped at */
  if (vi(d, LE_DRIFT_LFO_RETRIGGER) || shape >= 7) {
    v->lfo_ph = lfo_start_phase(shape);
    lfo_draw(v); /* Sample & Hold and Wander start on a drawn value */
    v->lfo_done = 0;
  }
  v->cyc_ph = 0.0f;
  /* the attack rises from the level it starts at to 1 over Attack */
  const float n1 = vf(d, LE_DRIFT_ENV1_ATTACK) * d->rate;
  const float n2 = vf(d, LE_DRIFT_ENV2_ATTACK) * d->rate;
  v->att1 = n1 <= 1.0f ? 1.0f : (1.0f - v->env1) / n1;
  v->att2 = n2 <= 1.0f ? 1.0f : (1.0f - v->env2) / n2;
  if (v->att1 <= 0.0f) v->att1 = 1.0f; /* already at the top */
  if (v->att2 <= 0.0f) v->att2 = 1.0f;
  v->stage1 = v->stage2 = STAGE_ATTACK;
  v->fade = 0.0f;
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
    int free = 1;
    for (int32_t l = 0; l < lanes; ++l) {
      free &= d->voices[g * lanes + l].state == LE_DRIFT_VOICE_FREE;
    }
    if (free) {
      d->next_voice = g; /* the search starts at the group allocated last */
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

/* Drops `origin`'s notes from Mono's held stack; returns whether any was. */
static int mono_drop(le_drift* d, uint32_t origin) {
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
  return keep != was;
}

/* Mono: drops `origin`'s notes from the held stack; when the sounding note
 * was one, the newest left sounds (legato), or the voices let go. */
static void mono_note_off(le_drift* d, uint32_t origin) {
  if (!mono_drop(d, origin)) return;
  const int32_t keep = d->mono_n;
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
  } else {
    mono_drop(d, origin); /* held under Mono before a mode change */
  }
  /* Every held voice of the origin lets go, whatever mode started it: a
   * mode change while keys are held never strands a note. */
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

int32_t le_drift_fade_oldest(le_drift* d) {
  if (d == NULL) return 0;
  le_drift_voice* old = NULL;
  for (int32_t i = 0; i < LE_DRIFT_VOICES; ++i) {
    le_drift_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  fade_voice(old);
  d->stolen++;
  return 1;
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
      /* a symmetric quadratic S-curve over each half cycle */
      const float t = frac(2.0f * p);
      const float e = t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
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
  if (wrapped || (before < 0.5f && p >= 0.5f)) lfo_draw(v);
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

static float envelope(float* y, int32_t* stage, float step, float dec,
                      float sustain, float rel) {
  switch (*stage) {
    case STAGE_ATTACK: {
      *y += step;
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

/* The filters' input stage: linear up to +0.70 / -0.98, then a parabolic
 * knee 0.45 wide; the positive side is cut hard at +0.79, before the knee
 * levels off. Fitted: a sine at Gain 1 through filter I (linear at
 * resonance 0) gets Live's harmonics 2 to 41 within 3.2 dB rms, the hard
 * edge giving Live's slowly falling tail; one at Gain 0.5 stays clean. */
static float knee(float a, float t) {
  const float k = 0.45f;
  const float d = a - t;
  if (d <= 0.0f) return a;
  if (d >= k) return t + 0.5f * k;
  return t + d - d * d / (2.0f * k);
}

static float filter_input(float x) {
  if (x >= 0.0f) return fminf(knee(x, 0.70f), 0.79f);
  /* past the knee the negative side rises again, to the hard edge at -1.6:
   * measured, a saw at Gain 2 and two saws at Gain 2 into either filter
   * (round 19, harmonics 1 to 24 within 1 dB rms; held at the knee they
   * were 2 to 5 dB low on harmonics 2 to 5) */
  const float a = -x;
  float y = knee(a, 0.98f);
  if (a > 0.98f + 0.45f) y += a - (0.98f + 0.45f);
  return -fminf(y, 1.6f);
}

/* Filter I's feedback shaper: the cubic v - 2 (0.55032 v)^3, held flat past
 * its turning point. */
static float cubic_clip(float v) {
  const float n = 0.55032f, top = 0.7419f;
  const float c = v > top ? top : v < -top ? -top : v;
  const float m = n * c;
  return c - 2.0f * m * m * m;
}

/* Low-pass type I: one 12 dB/oct section whose two unequal poles (a
 * capacitor ratio of 3.3) give a base damping ratio near 1.18, and whose
 * resonance feedback cancels that damping at resonance 1, through the
 * cubic shaper (applied from the previous sample's band state), which
 * bounds the ringing and self-oscillation past 1. Above resonance 1 the
 * resonance is pulled back as the cutoff rises past 0.075 of the rate.
 * Fitted on Live's filter I renders: base damping 1.12, the shaper's
 * input x1.4, output gain 2.90 (a sine within 0.1 dB); sixth-octave
 * levels within 2.6 dB rms on average (the fitted state-variable filter it
 * replaces: 3.0). */
static float filter1(float* s, float x, float fc, float r, float rate,
                     uint32_t* rng) {
  const float g = prewarp(PI_F * fc / rate);
  const float f = fc / rate;
  const float rp = fmaxf(
      0.001f, r / (1.0f + 3.0f * fmaxf(f - 0.075f, 0.0f) * fmaxf(r - 1.0f, 0.0f)));
  const float k0 = 2.0f * 1.12f;
  const float kr = k0 * rp; /* the resonance's share of the damping */
  const float d = 1.4f;     /* into the shaper */
  const float b = s[2];
  x += 2e-5f * rnd_bipolar(rng);
  x += kr * (cubic_clip(b * d) / d - b);
  const float k = k0 - kr;
  const float hp = (x - (k + g) * s[0] - s[1]) / (1.0f + k * g + g * g);
  const float bp = g * hp + s[0];
  const float lp = g * bp + s[1];
  s[0] = bp + g * hp;
  s[1] = lp + g * bp;
  s[2] = bp;
  return lp * 2.90f;
}

/* Low-pass type II: two sections in series, each a Sallen-Key model of the
 * later MS-20 low-pass circuit (Segno's own model of it, from a reading of
 * Live's): a DC-blocked input drives a first integrator through a
 * transconductance that saturates; its capacitor's lower plate is the
 * feedback node X; a unity buffer follows each of the two integrators and
 * clips; the second buffer's output, DC-blocked, is the section's output
 * w, and the resonance feeds it back through a diode-like curve to X.
 * Small-signal Q is 1 / (2 - k) for a loop gain k, unity DC gain at every
 * resonance; the second section gets less of the resonance than the
 * first. The two nonlinear elements are linearised at the last estimate
 * and the loop solved in closed form, twice per sample. Levels are in the
 * circuit's volts: the voice signal enters at x 3 x 2.69 and leaves at
 * 2 / 9 of the passband. */

/* The diode curve in the feedback: a slope of 2.21 at 0, a sharp knee near
 * 1, and a slope of 0.62 beyond, slightly larger above 0 than below.
 * Segno's own form, fitted to a description of Live's within 0.04; the
 * slope at 0 sets the small-signal resonance: fitted, filter II's
 * resonant peaks on noise within 0.3 dB of Live's at resonance 0.5 to 1. */
static float f2_diode(float a) {
  const float gm = a >= 0.0f ? 1.0449f : 1.1195f;
  const float u = gm * a;
  return 0.62f * a + 1.59f * a / sqrtf(sqrtf(1.0f + u * u * u * u));
}

/* The first integrator's transconductance z (1 - z^2/4 + |z|^3/16) on its
 * normalised input z (clamped to +-2), saturating at 1: its secant. */
static float f2_ota_secant(float z) {
  z = clampf(z, -2.0f, 2.0f);
  const float az = fabsf(z);
  return 1.0f - 0.25f * z * z + 0.0625f * az * az * az;
}

static float f2_diode_secant(float a) {
  return fabsf(a) < 1e-4f ? 2.21f : f2_diode(a) / a;
}

#define F2_GI 2.69154f     /* into a section, in circuit volts */
#define F2_KAPPA 0.4165f   /* the first integrator's input scale, per volt */
#define F2_OTA_OFS 0.015f  /* its input offset (normalised) */
#define F2_DIODE_OFS 0.009f
#define F2_BUF_LO -4.987f  /* the buffers' clip */
#define F2_BUF_HI 4.806f
#define F2_X_LIM 5.1f

/* One section; s holds s[0] the input coupling, s[1] the first integrator,
 * s[2] the second, s[3] the output coupling, and the last sample's secant
 * gains s[4] (the transconductance) and s[5] (the diode). */
/* The per-sample coefficients both sections share. */
typedef struct {
  float g, he, c1, inv1g; /* g, 1/(1+gh), g/(1+g), 1/(1+g) */
} f2_coef;

static float filter2_section(float* s, float x, const f2_coef* c, float kfb) {
  const float g = c->g, he = c->he, C1 = c->c1;
  const float u = F2_GI * x;
  const float vin = (u - s[0]) * he; /* the input coupling's high-pass */
  float L = s[4], T = s[5];
  float X = 0.0f, y1 = 0.0f, y2 = 0.0f, b1 = 0.0f, b2 = 0.0f, w = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    if (pass == 1) {
      L = f2_ota_secant(F2_KAPPA * (vin - b1) + F2_OTA_OFS);
      T = f2_diode_secant(kfb * w + F2_DIODE_OFS);
    }
    /* y1 = A X + B, y2 = C1 y1 + C0, w = he y2 + F, X = P w + Q */
    const float gl = g * L;
    const float A = 1.0f / (1.0f + gl);
    const float B = (gl * (vin + F2_OTA_OFS / F2_KAPPA) + s[1]) * A;
    const float C0 = s[2] * c->inv1g;
    const float F = -s[3] * he;
    const float P = T * kfb;
    const float Q = T * F2_DIODE_OFS;
    X = (P * (he * (C1 * B + C0) + F) + Q) / (1.0f - P * he * C1 * A);
    X = clampf(X, -F2_X_LIM, F2_X_LIM);
    y1 = clampf(A * X + B, -21.0f, 21.0f);
    b1 = clampf(y1, F2_BUF_LO, F2_BUF_HI);
    y2 = clampf(C1 * b1 + C0, -21.0f, 21.0f);
    b2 = clampf(y2, F2_BUF_LO, F2_BUF_HI);
    w = he * b2 + F;
  }
  /* the next sample's first pass starts from this operating point */
  s[4] = f2_ota_secant(F2_KAPPA * (vin - b1) + F2_OTA_OFS);
  s[5] = f2_diode_secant(kfb * w + F2_DIODE_OFS);
  /* trapezoidal state updates */
  s[0] = 2.0f * (u - vin) - s[0];
  s[1] = 2.0f * (y1 - X) - s[1];
  s[2] = 2.0f * y2 - s[2];
  s[3] = 2.0f * (b2 - w) - s[3];
  return w / F2_GI;
}

/* With the same tiny injected noise as type I to start self-oscillation.
 * Resonance r maps to q = 4r / (3r + 1) + 4 (r - 1)^2 above 1; above 1 the
 * excess is pulled back as the cutoff nears the top of the range. */
static float filter2(float* s, float x, float fc, float r, float rate,
                     uint32_t* rng) {
  const float fcs = fminf(fmaxf(fc, 1.0f), 0.48f * rate);
  f2_coef c;
  c.g = 1.02038f * prewarp(fminf(PI_F * fcs / rate, 1.54f));
  c.he = 1.0f / (1.0f + PI_F * 1.5915f / rate); /* the 10 uF / 10 kOhm couplings */
  c.inv1g = 1.0f / (1.0f + c.g);
  c.c1 = c.g * c.inv1g;
  float q = 4.0f * r / (3.0f * r + 1.0f);
  if (r > 1.0f) q += 4.0f * (r - 1.0f) * (r - 1.0f);
  const float lim = fminf(10000.0f / rate + 0.25f, 0.5f);
  const float t = 1.0f - fminf(fc / rate, lim) / lim;
  q = fminf(q, 1.0f + (fmaxf(q, 1.0f) - 1.0f) * t * t * t);
  const float k1 = 0.91351f * q;
  const float k2 = k1 * (0.5f + 0.2f * r);
  x = 3.0f * x + 2e-5f * rnd_bipolar(rng);
  const float a = filter2_section(s, x, &c, k1);
  /* the cascade's 2 / 9, and Segno's path gain around it (fitted: every
   * filter II render, the factory presets' isolations and the presets,
   * sixth-octave levels within 1.7 dB rms on average, the resonant peaks'
   * shape within 1.3 dB; a sine and a saw at every gain within 0.05 dB) */
  return filter2_section(s + 6, a, &c, k2) * (2.0f / 9.0f) * 3.69f;
}

/* Filter II at rest: the state its offsets settle to with no input (at DC
 * no current flows into the integrators and the couplings, so neither the
 * cutoff nor the resonance moves it). A voice's filter starts there, not
 * from zero, which would step through the output coupling: measured, Live
 * starts its filter II notes without that transient. */
static void f2_rest_state(float* s) {
  memset(s, 0, 12 * sizeof(float));
  s[4] = s[10] = 1.0f; /* the secants at small signal */
  s[5] = s[11] = 2.21f;
  /* fast coefficients settle the same equilibrium in few samples */
  f2_coef c;
  c.g = 4.0f;
  c.he = 0.5f;
  c.inv1g = 1.0f / (1.0f + c.g);
  c.c1 = c.g * c.inv1g;
  for (int i = 0; i < 400; ++i) {
    const float a = filter2_section(s, 0.0f, &c, 0.5f);
    filter2_section(s + 6, a, &c, 0.25f);
  }
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
  if (v->pending) {
    /* falling to silence for a note waiting to start (start_voice) */
    v->env1 *= x->pending_fall;
    v->env2 *= x->pending_fall;
    if (v->env1 <= LE_DRIFT_SILENT) {
      v->pending = 0;
      begin_note(d, v, 1);
      if (v->state != LE_DRIFT_VOICE_HELD) v->stage1 = v->stage2 = STAGE_RELEASE;
    }
  }
  const float env1 =
      v->pending ? v->env1
                 : envelope(&v->env1, &v->stage1, v->att1, x->env1_dec,
                            b->sustain1, x->env1_rel);
  float env2;
  if (b->cycling) {
    env2 = cycling(v->cyc_ph, b->cyc_mid, b->cyc_hold);
  } else {
    env2 = v->pending ? v->env2
                      : envelope(&v->env2, &v->stage2, v->att2, x->env2_dec,
                                 b->sustain2, x->env2_rel);
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
  v->pitch += b->glide * (v->pitch_target - v->pitch);
  /* the lane's note frequency (glided, a Mono lane's octave below), before
   * the oscillators' own Transpose and pitch modulation, for the Ratio rate
   * modes only */
  const int lfo_ratio = b->lfo_mode == RATE_RATIO;
  const float note_f = (lfo_ratio || b->cyc_mode == RATE_RATIO)
                           ? v->pitch * b->bend_ratio * v->ref_ratio
                           : 0.0f;
  /* A pitch slot fed by a source running in Ratio mode (audio rate: the
   * LFO, or Envelope 2 as the cycling envelope) moves both oscillators'
   * phase instead of their pitch: phase modulation by source x amount x
   * half the slot's range in octaves, in cycles, limited below one cycle;
   * the cycling envelope centred on its middle (level - 0.5). Measured: the
   * LFO (range 2) on Live's Ratio renders; the cycling envelope (range 4)
   * on round 19's sine at Ratio 2 and 3, amounts 0.1 to 0.25 and two
   * shapes (sidebands within 0.8 dB rms; uncentred 3 to 10 dB), and on
   * Bellatine's at Ratio 14. */
  const int cyc_ratio = b->cycling && b->cyc_mode == RATE_RATIO;
  float pitch = 0.0f, phase = 0.0f;
  for (int k = 0; k < 2; ++k) {
    const int32_t s = b->pm_src[k];
    if ((lfo_ratio && s == LE_DRIFT_SRC_LFO) ||
        (cyc_ratio && s == LE_DRIFT_SRC_ENV2)) {
      phase += b->pm_amt[k] * 0.5f * kPitchRange[s] *
               (s == LE_DRIFT_SRC_ENV2 ? src.bi[s] - 0.5f : src.bi[s]);
    } else {
      pitch += b->pm_amt[k] * src.bi[s] * kPitchRange[s];
    }
  }
  phase = clampf(phase, -0.9999999f, 0.9999999f);
  const float base = v->pitch * exp2f(pitch) * v->ratio * b->bend_ratio;
  const float f1 = base * x->osc1_ratio;
  const float f2 = base * x->osc2_ratio * v->osc2_drift * exp2f(add_detune);
  const float dt1 = fminf(f1 / rate, 0.4999999f);
  const float dt2 = fminf(f2 / rate, 0.4999999f);
  v->dt1 = dt1; /* kept for while the voice is silent (tick) */
  v->dt2 = dt2;
  v->ph1 += dt1;
  if (v->ph1 >= 1.0f) v->ph1 -= 1.0f;
  v->ph2 += dt2;
  if (v->ph2 >= 1.0f) v->ph2 -= 1.0f;
  /* the LFO's and the cycling envelope's rates */
  const float lfo_hz = (lfo_ratio ? b->lfo_ratio * note_f : x->lfo_hz) *
                       exp2f(4.0f * add_lfo);
  v->lfo_inc = fminf(lfo_hz / rate, 0.49999988f);
  v->lfo_mod = exp2f(4.0f * add_lfo);
  lfo_advance(v, v->lfo_inc);
  const float cyc_hz = (b->cyc_mode == RATE_RATIO ? b->cyc_ratio * note_f : x->cyc_hz) *
                       exp2f(4.0f * add_cyc);
  v->cyc_ph += fminf(cyc_hz / rate, 0.49999988f);
  if (v->cyc_ph >= 1.0f) v->cyc_ph -= 1.0f;
  /* oscillators and noise */
  const float shape = b->shape + b->shape_mod * src.raw[b->shape_src] + add_shape;
  const float s1 = x->osc1 == WAVE_SATURATED ? fmaxf(shape, 0.0f)
                   : x->osc1 == WAVE_SHARK     ? shape
                   : x->osc1 == WAVE_RECTANGLE ? clampf(shape, -1.0f, 1.0f)
                                               : clampf(shape, 0.0f, 1.0f);
  const float th1 = phase == 0.0f ? v->ph1 : frac(v->ph1 + phase + 1.0f);
  const float th2 = phase == 0.0f ? v->ph2 : frac(v->ph2 + phase + 1.0f);
  /* the band-limiting follows the phase each sample really moves by */
  const float dph = phase - v->pm_prev;
  v->pm_prev = phase;
  const float be1 = fminf(fabsf(dt1 + dph), 0.4999999f);
  const float be2 = fminf(fabsf(dt2 + dph), 0.4999999f);
  const float o1 = oscillator(x->osc1, th1, s1, be1) * x->gain1 * g_osc1;
  const float o2 = oscillator(x->osc2, th2, 0.0f, be2) * x->gain2 * g_osc2;
  float noise =
      d->lane_noise[v - d->voices] * LE_DRIFT_NOISE_LEVEL * x->gain_noise * g_noise;
  /* mixer and routing */
  float thru = 0.0f, around = 0.0f, around_noise = 0.0f;
  if (x->thru1) thru += o1; else around += o1;
  if (x->thru2) thru += o2; else around += o2;
  /* fitted: noise reaches filter I 2.2 dB and filter II 2.0 dB quieter
   * than the bypass (Live's noise renders, levels 0.1 to 1) */
  if (x->thru_noise) noise *= x->filter_type ? 0.793f : 0.773f;
  if (x->thru_noise) thru += noise; else around_noise = noise;
  /* filters */
  float fc = b->freq * key_tracking(b->tracking, v->key) *
             exp2f(10.0f * (b->fm_amt[0] * src.bi[b->fm_src[0]] +
                            b->fm_amt[1] * src.bi[b->fm_src[1]] + add_lp));
  fc = clampf(fc, 10.0f, fminf(20000.0f, 0.45f * rate));
  const float res = clampf(x->res + add_res, 0.0f, 1.3f);
  /* a Filter Type change while the voice sounds starts the new filter from
   * rest: the other type's state would jolt it */
  if (v->lp_kind != x->filter_type) clear_lowpass(d, v, x->filter_type);
  float y = filter_input(thru) * 0.25f;
  y = x->filter_type ? filter2(v->lp, y, fc, res, rate, &v->rng)
                                  : filter1(v->lp, y, fc, res, rate, &v->rng);
  y *= 0.333f; /* -9.55 dB: fitted with the input knee, a saw within 0.1 dB */
  const float hc = clampf(x->hp_hz * exp2f(10.0f * add_hp), 20.0f,
                          fminf(20000.0f, 0.45f * rate));
  y = highpass(v->hp, y, hc, rate);
  y += around * LE_DRIFT_BYPASS_OSC + around_noise * LE_DRIFT_BYPASS_NOISE;
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
/* The voices run in blocks of four. A silent voice in a block where any
 * voice sounds keeps turning its oscillators at the rate it last had (a
 * voice never played: A4 with its own drift), and every silent voice's
 * LFO keeps running. Fitted: in Live a Stereo note on a fresh pair starts
 * its lanes together only when that pair's block was idle; once a block
 * runs, its idle lanes drift apart. */
static void tick(le_drift* d, float* l, float* r) {
  *l = 0.0f;
  *r = 0.0f;
  const float idle_lfo = d->d.lfo_hz / d->rate;
  const int noise_on = d->d.gain_noise > 0.0f;
  for (int32_t b = 0; b < LE_DRIFT_VOICES; b += 4) {
    int32_t busy = 0;
    for (int32_t i = b; i < b + 4; ++i) busy |= d->voices[i].state != LE_DRIFT_VOICE_FREE;
    /* A running block draws one noise value per voice, sounding or not, so
     * blocks that start together play the same noise voice for voice.
     * Fitted: Live's noise from simultaneous notes in different blocks adds
     * coherently (Stereo, 3 / 4 / 6 notes: +2.1 / +2.9 / +4.7 dB over
     * independent voices; Poly 5 / 6: +1.5 / +2.2), and within a block
     * stays independent. */
    if (busy) {
      for (int32_t i = b; i < b + 4; ++i) {
        const float r1 = rnd_bipolar(&d->noise_rng[i]);
        const float u2 = rnd_unit(&d->noise_rng[i]);
        d->lane_noise[i] =
            noise_on ? clampf(half_sine(fabsf(r1)) * (r1 < 0.0f ? -1.0f : 1.0f) *
                                  sqrtf(-2.0f * logf(u2)),
                              -10.0f, 10.0f)
                     : 0.0f;
      }
    }
    for (int32_t i = b; i < b + 4; ++i) {
      le_drift_voice* v = &d->voices[i];
      if (v->state != LE_DRIFT_VOICE_FREE) {
        voice_sample(d, v, l, r);
        continue;
      }
      if (busy) {
        v->ph1 += v->dt1;
        if (v->ph1 >= 1.0f) v->ph1 -= 1.0f;
        v->ph2 += v->dt2;
        if (v->ph2 >= 1.0f) v->ph2 -= 1.0f;
      }
      /* at the rate it last had (its LFO Rate modulation included), drawing
       * new Sample & Hold and Wander steps as it goes */
      lfo_advance(v, d->d.lfo_mode == RATE_RATIO
                         ? v->lfo_inc
                         : fminf(idle_lfo * v->lfo_mod, 0.49999988f));
    }
  }
}


void le_drift_render(le_drift* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  for (int32_t f = 0; f < frames; ++f) {
    if (d->chunk_left <= 0) {
      derive(d);
      d->chunk_left = LE_DRIFT_CHUNK;
    }
    d->chunk_left--;
    tick(d, &left[f], &right[f]);
  }
}
