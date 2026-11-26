/*
 * meld_osc.c — Meld's oscillators (SEG-109). See meld_osc.h.
 */
#include "meld_osc.h"

#include <math.h>
#include <string.h>

#define MO_PI 3.14159265358979323846
#define MO_TWO_PI 6.28318530717958647692

/* ---- small parts ---- */

static uint32_t mo_next(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

/* Uniform in [0, 1), and in [-1, 1). */
static float mo_uniform(uint32_t* s) { return (float)(mo_next(s) >> 8) * (1.0f / 16777216.0f); }
static float mo_bipolar(uint32_t* s) { return 2.0f * mo_uniform(s) - 1.0f; }

static double mo_wrap(double ph) { return ph - floor(ph); }

static float mo_clamp(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

/* The distance from `edge` to `ph` in samples, both phases in [0, 1),
 * taken the short way round. */
static float mo_dist(double ph, double edge, float dt) {
  double d = ph - edge;
  if (d < -0.5) d += 1.0;
  if (d >= 0.5) d -= 1.0;
  return (float)(d / dt);
}

/* The two-sample correction for a unit step up at `edge`. */
static float mo_blep(double ph, double edge, float dt) {
  const float t = mo_dist(ph, edge, dt);
  if (t >= 1.0f || t <= -1.0f) return 0.0f;
  if (t >= 0.0f) {
    const float u = 1.0f - t;
    return -0.5f * u * u;
  }
  const float u = 1.0f + t;
  return 0.5f * u * u;
}

/* Its integral: the correction for a unit change of slope per sample at
 * `edge`. */
static float mo_blamp(double ph, double edge, float dt) {
  const float t = fabsf(mo_dist(ph, edge, dt));
  if (t >= 1.0f) return 0.0f;
  const float u = 1.0f - t;
  return u * u * u * (1.0f / 6.0f);
}

/* The band-limited waves: sine, triangle (0 at phase 0, 1 at a quarter),
 * saw (0 at phase 0, its step at a half) and pulse (+1 before `duty`). */
static float mo_sine(double ph) { return sinf((float)(MO_TWO_PI * ph)); }

/* A parabolic sine: 16 |t| (0.5 - |t|) with t = 0.5 - phase (odd partials
 * at 1/n^3). */
static float mo_parabolic(double ph) {
  const float t = (float)(0.5 - ph);
  const float at = fabsf(t);
  return (t < 0.0f ? -1.0f : 1.0f) * 16.0f * at * (0.5f - at);
}

static float mo_tri_naive(double ph) {
  return ph < 0.25 ? (float)(4.0 * ph) : ph < 0.75 ? (float)(2.0 - 4.0 * ph) : (float)(4.0 * ph - 4.0);
}

static float mo_triangle(double ph, float dt) {
  return mo_tri_naive(ph) + 8.0f * dt * (mo_blamp(ph, 0.75, dt) - mo_blamp(ph, 0.25, dt));
}

static float mo_saw(double ph, float dt) {
  const float p = ph < 0.5 ? (float)ph : (float)(ph - 1.0);
  return 2.0f * p - 2.0f * mo_blep(ph, 0.5, dt);
}

static float mo_pulse(double ph, float duty, float dt) {
  const float v = ph < duty ? 1.0f : -1.0f;
  return v + 2.0f * (mo_blep(ph, 0.0, dt) - mo_blep(ph, duty, dt));
}

static float mo_tan(float f, float rate) {
  return tanf(fminf((float)MO_PI * fmaxf(f, 1.0f) / rate, 1.56685f));
}

/* The plain shapes Dual Basic Shapes and Noisy Shapes mix: 0 sine, 1
 * triangle, 2 saw, 3 square. */
static float mo_shape(int k, double ph, float dt) {
  switch (k) {
    case 0: return mo_sine(ph);
    case 1: return mo_triangle(ph, dt);
    case 2: return mo_saw(ph, dt);
    default: return mo_pulse(ph, 0.5f, dt);
  }
}

/* A mix at position s between shape `first + floor(s)` and the next. */
static float mo_shape_mix(int first, float s, int last, double ph, float dt) {
  int k = (int)s;
  if (first + k > last - 1) k = last - 1 - first;
  const float fr = s - (float)k;
  float y = (1.0f - fr) * mo_shape(first + k, ph, dt);
  if (fr > 0.0f) y += fr * mo_shape(first + k + 1, ph, dt);
  return y;
}

/* ---- shared tables ---- */

/* Basic Shapes' sine fold: the mean of sin(pi/2 (K sin + 1.01)) over a
 * cycle, sin(1.01 pi/2) J0(pi K/2), for K from 1 to 5. */
#define MO_FOLD_DC_N 128
static float g_fold_dc[MO_FOLD_DC_N + 1];
static int g_tables_built;

static double mo_j0(double x) {
  /* the power series, exact enough below 8 */
  double term = 1.0, sum = 1.0;
  const double q = -0.25 * x * x;
  for (int k = 1; k < 40; ++k) {
    term *= q / ((double)k * (double)k);
    sum += term;
  }
  return sum;
}

void le_meld_osc_tables(void) {
  if (g_tables_built) return;
  for (int i = 0; i <= MO_FOLD_DC_N; ++i) {
    const double k = 1.0 + 4.0 * (double)i / MO_FOLD_DC_N;
    g_fold_dc[i] = (float)(sin(1.01 * MO_PI / 2.0) * mo_j0(MO_PI * k / 2.0));
  }
  g_tables_built = 1;
}

static float mo_fold_dc(float k) {
  const float x = mo_clamp((k - 1.0f) * (MO_FOLD_DC_N / 4.0f), 0.0f, (float)MO_FOLD_DC_N);
  const int i = (int)x < MO_FOLD_DC_N ? (int)x : MO_FOLD_DC_N - 1;
  const float f = x - (float)i;
  return g_fold_dc[i] + f * (g_fold_dc[i + 1] - g_fold_dc[i]);
}

/* ---- the 44.1 kHz resampler ---- */

/* Runs `gen` at the internal rate and reads it at the host rate through a
 * 4-point cubic Hermite. */
static float mo_resampled(le_meld_osc* o, float rate, float (*gen)(le_meld_osc*)) {
  le_meld_resampler* rs = &o->rs;
  rs->pos += rate / o->rate;
  while (rs->pos >= 1.0) {
    rs->pos -= 1.0;
    rs->h[0] = rs->h[1];
    rs->h[1] = rs->h[2];
    rs->h[2] = rs->h[3];
    rs->h[3] = gen(o);
  }
  const float t = (float)rs->pos;
  const float* h = rs->h;
  const float c1 = 0.5f * (h[2] - h[0]);
  const float c2 = h[0] - 2.5f * h[1] + 2.0f * h[2] - 0.5f * h[3];
  const float c3 = 0.5f * (h[3] - h[0]) + 1.5f * (h[1] - h[2]);
  return ((c3 * t + c2) * t + c1) * t + h[1];
}

static float mo_r44(le_meld_osc* o, float (*gen)(le_meld_osc*)) {
  return mo_resampled(o, o->irate, gen);
}

/* ---- Basic Shapes ---- */

/* Shape `k` (0 sine, 1 triangle, 2 saw, 3 pulse) with Macro 2 at m. */
static float basic_shape(int k, double ph, float dt, float m) {
  const float kk = 1.0f + 4.0f * m;
  switch (k) {
    case 0: {
      const float s = mo_sine(ph);
      return (1.0f - m) * s +
             m * (sinf((float)(MO_PI / 2.0) * (kk * s + 1.01f)) - mo_fold_dc(kk));
    }
    case 1: {
      const float t = mo_triangle(ph, dt);
      return (1.0f - m) * t + m * sinf((float)(MO_PI / 2.0) * kk * t);
    }
    case 2:
      /* a second saw half a cycle along at full Macro 2: an octave up */
      return mo_saw(ph, dt) + m * mo_saw(mo_wrap(ph + 0.5 * m), dt);
    default: {
      const float duty = 0.5f * (1.0f - 0.999f * m);
      return mo_pulse(ph, duty, dt) + 1.0f - 2.0f * duty;
    }
  }
}

static float basic_tick(le_meld_osc* o) {
  const float f = fminf(o->hz, 0.25f * o->rate);
  const float dt = f / o->rate;
  const double ph = o->s.basic.ph[0];
  const float s = 3.0f * o->m1;
  int k = (int)s;
  if (k > 2) k = 2;
  const float fr = s - (float)k;
  float y = (1.0f - fr) * basic_shape(k, ph, dt, o->m2);
  if (fr > 0.0f) y += fr * basic_shape(k + 1, ph, dt, o->m2);
  o->s.basic.ph[0] = mo_wrap(ph + dt);
  return y;
}

/* ---- Dual Basic Shapes ---- */

/* Each oscillator's level fades from 0.5 to 0 between rate/8 and rate/4. */
static float dual_weight(float dt) {
  const float a = 1.0f - mo_clamp(8.0f * (dt - 0.125f), 0.0f, 1.0f);
  return 0.5f * a * a * a * a;
}

static float dual_tick(le_meld_osc* o) {
  const float d1 = fminf(o->hz / o->rate, 0.49f);
  const float d2 = fminf(o->hz * exp2f(o->m2) / o->rate, 0.49f);
  double* ph = o->s.basic.ph;
  /* at unison the two merge into one voice */
  if (fabsf(d1 - d2) < 1e-6f) {
    double diff = ph[1] - ph[0];
    diff -= floor(diff + 0.5);
    ph[0] = mo_wrap(ph[0] + diff * 10.0 / o->rate);
  }
  const float s = 3.0f * o->m1;
  const float y = dual_weight(d1) * mo_shape_mix(0, s, 3, ph[0], d1) +
                  dual_weight(d2) * mo_shape_mix(0, s, 3, ph[1], d2);
  ph[0] = mo_wrap(ph[0] + d1);
  ph[1] = mo_wrap(ph[1] + d2);
  return y;
}

/* ---- Noisy Shapes (44.1 kHz) ---- */

static float noisy_internal(le_meld_osc* o) {
  const float rate = o->irate;
  const float m1 = o->m1, m2 = o->m2;
  const float delta = 2.0f * fmaxf(0.0f, 2.0f * m2 - 1.0f) * fmaxf(0.0f, 2.0f * m2 - 1.0f);
  const float fs[2] = {fminf(o->hz + delta, 22000.0f), fminf(fmaxf(o->hz - delta, 1.0f), 22000.0f)};
  /* the shape: triangle, saw, square (80 % of the way at Macro 1 = 1) */
  const float s = m1 <= 0.5f ? 2.0f * m1 : 1.0f + 0.8f * (2.0f * m1 - 1.0f);
  /* the f/2 modulation, above Macro 2 = 0.75 */
  const float v = mo_parabolic(o->s.noisy.half);
  const float b = 4.0f * (mo_clamp(m2, 0.75f, 1.0f) - 0.75f);
  const float mod = 1.0f - b * (0.5f * v + 0.5f);
  float sum = 0.0f;
  for (int i = 0; i < 2; ++i) {
    const float dt = fs[i] / rate;
    const double ph = o->s.noisy.ph[i];
    float y = mo_shape_mix(1, s, 4, ph, dt);
    /* a noise burst in the first tenth of each cycle, high-passed */
    const float duty = fmaxf(dt, 0.1f);
    const float gate = 0.5f * (mo_pulse(ph, duty, dt) + 1.0f);
    const float noise = mo_bipolar(&o->rng) * gate * (0.1f + 0.9f * m2) * mod;
    float hp = 0.0f;
    (void)le_meld_svf(&o->s.noisy.hp[i], noise, mo_tan(fs[i], rate), 10.0f, 0, &hp);
    sum += y + hp;
  }
  /* below Macro 2 = 0.5 the second oscillator locks to the first */
  const float c = 1.0f - 2.0f * fminf(m2, 0.5f);
  double diff = o->s.noisy.ph[0] - o->s.noisy.ph[1];
  diff -= floor(diff + 0.5);
  o->s.noisy.ph[0] = mo_wrap(o->s.noisy.ph[0] + fs[0] / rate);
  o->s.noisy.ph[1] = mo_wrap(o->s.noisy.ph[1] + fs[1] / rate + diff * c * 20.0 / rate);
  o->s.noisy.half = mo_wrap(o->s.noisy.half + 0.5 * o->hz / rate);
  /* the drive into a sine, its depth falling between 500 Hz and 4 kHz */
  const float a = (mo_clamp(o->hz, 500.0f, 4000.0f) - 500.0f) / 3500.0f;
  const float D = mod * m2 * (1.0f - a);
  const float x = sum * (0.8f * (1.0f - D) + 4.0f * D);
  const float x1 = o->s.noisy.x1;
  o->s.noisy.x1 = x;
  /* first-order antiderivative anti-aliasing of sin */
  if (fabsf(x - x1) < 1e-4f) return sinf(0.5f * (x + x1));
  return (cosf(x1) - cosf(x)) / (x - x1);
}

/* ---- Swarm ---- */

/* Segno's voicings, built by the rule the description gives: unison, then
 * octaves both ways, then fifths and fourths in place of octave copies,
 * then thirds, then upper harmonics; 12 ratios each. */
#define MO_STACKS 9
static const float kStacks[MO_STACKS][LE_MELD_SWARM_LANES] = {
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
    {1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2},
    {1, 1, 1, 2, 2, 2, 4, 4, 4, 0.5f, 0.5f, 0.5f},
    {1, 1, 2, 2, 0.5f, 0.5f, 4, 4, 1.5f, 3, 4.0f / 3, 8.0f / 3},
    {1, 1, 2, 2, 0.5f, 4, 1.5f, 1.5f, 3, 0.75f, 4.0f / 3, 2.0f / 3},
    {1, 1, 2, 0.5f, 4, 1.5f, 3, 0.75f, 4.0f / 3, 8.0f / 3, 2.0f / 3, 4.0f / 3},
    {1, 2, 0.5f, 4, 1.5f, 3, 0.75f, 1.5f, 4.0f / 3, 8.0f / 3, 1.25f, 2.5f},
    {1, 2, 0.5f, 4, 1.5f, 3, 0.75f, 4.0f / 3, 2.0f / 3, 1.2f, 1.25f, 5.0f / 3},
    {0.25f, 0.5f, 1, 2, 4, 8, 16, 1.5f, 3, 2.25f, 1.375f, 1.875f},
};
#define MO_SWARM_UPDATE 32

static void swarm_retune(le_meld_osc* o) {
  const float d = 0.13f * o->m1 * o->m1 + 0.002f;
  const float p = 8.0f * o->m2;
  int a = (int)p;
  if (a > MO_STACKS - 1) a = MO_STACKS - 1;
  const int b = a < MO_STACKS - 1 ? a + 1 : a;
  const float top = 0.45f * o->rate;
  for (int k = 0; k < LE_MELD_SWARM_LANES; ++k) {
    const float x = o->s.swarm.x[k];
    o->s.swarm.inc[k] = fminf(o->hz * kStacks[a][k] * (1.0f + d * x), top) / o->rate;
    o->s.swarm.inc[LE_MELD_SWARM_LANES + k] =
        fminf(o->hz * kStacks[b][k] * (1.0f - d * x), top) / o->rate;
  }
}

/* Each lane moves in a straight line to a new random target over 0.32 to
 * 0.65 s. */
static void swarm_drift(le_meld_osc* o) {
  const float lo = fmaxf(1.0f, 0.3229f * o->rate / MO_SWARM_UPDATE);
  const float hi = fmaxf(1.0f, 0.6458f * o->rate / MO_SWARM_UPDATE);
  for (int k = 0; k < LE_MELD_SWARM_LANES; ++k) {
    if (o->s.swarm.steps[k] <= 0) {
      const float to = mo_bipolar(&o->rng);
      const int32_t n = (int32_t)(lo + mo_uniform(&o->rng) * (hi - lo));
      o->s.swarm.steps[k] = n < 1 ? 1 : n;
      o->s.swarm.dx[k] = (to - o->s.swarm.x[k]) / (float)o->s.swarm.steps[k];
    }
    o->s.swarm.x[k] += o->s.swarm.dx[k];
    o->s.swarm.steps[k]--;
  }
}

static float swarm_wave(int type, double ph, float dt) {
  switch (type) {
    case LE_MELD_OSC_SWARM_SINE: return mo_sine(ph);
    case LE_MELD_OSC_SWARM_TRIANGLE: return mo_triangle(ph, dt);
    case LE_MELD_OSC_SWARM_SAW: return mo_saw(ph, dt);
    default: return mo_pulse(ph, 0.5f, dt);
  }
}

static float swarm_tick(le_meld_osc* o) {
  if (--o->s.swarm.left <= 0) {
    o->s.swarm.left = MO_SWARM_UPDATE;
    swarm_drift(o);
    swarm_retune(o);
  } else if (o->ramp_left > 0) {
    swarm_retune(o);
  }
  const float p = 8.0f * o->m2;
  const float fr = p >= (float)(MO_STACKS - 1) ? 0.0f : p - floorf(p);
  float ya = 0.0f, yb = 0.0f;
  for (int k = 0; k < LE_MELD_SWARM_LANES; ++k) {
    const float dt = o->s.swarm.inc[k];
    ya += swarm_wave(o->type, o->s.swarm.ph[k], dt);
    o->s.swarm.ph[k] = mo_wrap(o->s.swarm.ph[k] + dt);
  }
  for (int k = LE_MELD_SWARM_LANES; k < 2 * LE_MELD_SWARM_LANES; ++k) {
    const float dt = o->s.swarm.inc[k];
    if (fr > 0.0f) yb += swarm_wave(o->type, o->s.swarm.ph[k], dt);
    o->s.swarm.ph[k] = mo_wrap(o->s.swarm.ph[k] + dt);
  }
  return 0.28867513f * ((1.0f - fr) * ya + fr * yb);
}

/* ---- Chord ---- */

/* The 13 chord types, as degrees above the note in its major scale (3 or 4
 * tones; -1 ends a shorter chord): triad, seventh, added ninth, the sixth
 * voicings, the sus4 and sus2 families, added tenth. */
#define MO_CHORDS 13
static const int8_t kChords[MO_CHORDS][4] = {
    {0, 2, 4, -1}, {0, 2, 4, 6}, {0, 2, 4, 8}, {0, 2, 5, -1}, {0, 3, 5, -1},
    {0, 3, 4, -1}, {0, 3, 4, 6}, {0, 3, 4, 8}, {0, 1, 5, -1}, {0, 1, 4, -1},
    {0, 1, 4, 6},  {0, 1, 4, 8}, {0, 2, 4, 9},
};
static const int8_t kMajor[7] = {0, 2, 4, 5, 7, 9, 11};
#define MO_CHORD_UPDATE 32

static float chord_semitones(int degree) {
  const int oct = degree >= 0 ? degree / 7 : -((6 - degree) / 7);
  return (float)(12 * oct + kMajor[degree - 7 * oct]);
}

static int chord_tones(int type) { return kChords[type][3] < 0 ? 3 : 4; }

/* Tone k of chord `type` at inversion `inv`: the chord rotated upward. */
static float chord_tone(int type, int inv, int k) {
  const int n = chord_tones(type);
  const int i = inv + k;
  return chord_semitones(kChords[type][i % n] + 7 * (i / n));
}

static void chord_retune(le_meld_osc* o) {
  int type = (int)(12.0f * o->m1);
  if (type > MO_CHORDS - 1) type = MO_CHORDS - 1;
  const float p = 7.0f * o->m2;
  int ie = 2 * (int)floorf(p / 2.0f + 0.5f);
  int io = 2 * (int)floorf(p / 2.0f) + 1;
  if (ie > 7) ie = 7;
  if (io > 7) io = 7;
  const float top = 0.45f * o->rate;
  const int n = chord_tones(type);
  /* a three-tone chord's fourth voice doubles its lowest tone an octave
   * up, at the others' level. [measured] from the triad renders, each line
   * as the saws' harmonics sum: at inversion 0 C4 -29, C5 -26 and C6 -32
   * dB in Live (a doubling two octaves up gives -29, -28 and -29), and
   * halfway to inversion 1 E4 cancels (E3's second harmonic against the
   * doubled E4), -64 dB in Live (scratchpad meldfit/meas/chord_lines.py) */
  for (int t = 0; t < 4; ++t) {
    const float sa = t < n ? chord_tone(type, ie, t) : chord_tone(type, ie, 0) + 12.0f;
    const float sb = t < n ? chord_tone(type, io, t) : chord_tone(type, io, 0) + 12.0f;
    o->s.chord.inc[t] = fminf(o->hz * exp2f(sa / 12.0f), top) / o->rate;
    o->s.chord.inc[4 + t] = fminf(o->hz * exp2f(sb / 12.0f), top) / o->rate;
  }
}

static float chord_tick(le_meld_osc* o) {
  if (--o->s.chord.left <= 0) {
    o->s.chord.left = MO_CHORD_UPDATE;
    chord_retune(o);
  }
  const float p = 7.0f * o->m2;
  /* the weight of the odd inversion: p's distance from the nearest even */
  const float tw = fminf(fabsf(p - 2.0f * floorf(p / 2.0f + 0.5f)), 1.0f);
  const float wa = cosf(tw * (float)(MO_PI / 2.0));
  const float wb = sinf(tw * (float)(MO_PI / 2.0));
  float y = 0.0f;
  for (int t = 0; t < LE_MELD_CHORD_TONES; ++t) {
    const float dt = o->s.chord.inc[t];
    if (dt <= 0.0f) continue;
    y += (t < 4 ? wa : wb) * mo_saw(o->s.chord.ph[t], dt);
    o->s.chord.ph[t] = mo_wrap(o->s.chord.ph[t] + dt);
  }
  return 0.3f * y;
}

/* ---- Filtered Noise ---- */

static float fnoise_tick(le_meld_osc* o) {
  const float rate = o->rate;
  const float fc = mo_clamp(o->hz * exp2f(4.0f * o->m1 - 2.0f), 20.0f, 0.5f * rate);
  float flp = fc, fhp = fc, k = 2.0f, gdb;
  if (o->m2 <= 0.75f) {
    const float a = o->m2 / 0.75f;
    const float w = exp2f(6.0f * (1.0f - a));
    flp = fc * w;
    fhp = fc / w;
    const float g = (0.3f + 0.7f * a) * (0.3f + 0.7f * a);
    gdb = 28.0f * g - 12.0f;
  } else {
    const float b = 4.0f * (o->m2 - 0.75f);
    k = 1.0f / (12.0f * b * b + 0.5f * (1.0f - b * b));
    gdb = 28.0f * (1.0f - 1.25f * b) - 12.0f;
  }
  const float noise = mo_bipolar(&o->rng);
  const float gain = 1.5f * sqrtf(rate / 44100.0f) * powf(10.0f, gdb / 20.0f);
  const float lp =
      le_meld_svf(&o->s.fnoise.lp, noise, mo_tan(fminf(flp, 0.49f * rate), rate), k, 0, 0);
  float hp = 0.0f;
  (void)le_meld_svf(&o->s.fnoise.hp, lp, mo_tan(fminf(fhp, 0.49f * rate), rate), k, 0, &hp);
  return gain * hp;
}

/* ---- Sub ---- */

/* the DC blocker after Sub's clip */
#define MO_SUB_HP_HZ 5.0f

static float sub_tick(le_meld_osc* o) {
  const float f = fminf(o->hz, o->rate - 1.0f);
  const float y = mo_sine(o->s.sub.ph);
  const float m = o->m1 / 3.0f;
  const float K = 1.0f + 64.0f * m * m;
  const float x = (y + 0.3f) * K;
  /* the parabolic clip: rises to 0.92 at |x| = 1.6 and holds there */
  /* fit: the parabola stops at its peak, |x| = 1.6 (the Sub renders) */
  const float u = fminf(0.625f * fabsf(x) - 0.5f, 0.5f);
  float s = 0.92167f * (u + 0.75f - u * u);
  if (x < 0.0f) s = -s;
  const float r = 1.0f - 2.0f * (float)MO_PI * MO_SUB_HP_HZ / o->rate;
  const float hp = s - o->s.sub.hp_x + r * o->s.sub.hp_y;
  o->s.sub.hp_x = s;
  o->s.sub.hp_y = hp;
  const float low = 2.0f * powf(o->m2, 2.5f) * mo_sine(o->s.sub.ph4);
  o->s.sub.ph = mo_wrap(o->s.sub.ph + 0.5 * f / o->rate);
  o->s.sub.ph4 = mo_wrap(o->s.sub.ph4 + 0.25 * f / o->rate);
  return o->m1 * hp + (1.0f - o->m1) * y + low;
}

/* ---- the sweep kernel: Tarp and Extratone (44.1 kHz) ---- */

static float tanh_odd(float z) { return tanhf(z); }

/* Starts a sweep over `seconds` with curvature `a`. */
static void sweep_start(le_meld_osc* o, float seconds, float a) {
  const float rate = o->irate;
  const float n = fmaxf(1.0f, seconds * rate);
  o->s.tarp.len = (int32_t)n;
  o->s.tarp.n = 0;
  o->s.tarp.step = expf(-a / n);
  o->s.tarp.decay = 1.0f;          /* e^(-a n / N) */
  o->s.tarp.w = 1.0f - 0.0f;       /* the weight, 1 -> 0 */
  o->s.tarp.ph = o->s.tarp.ph;     /* the phase runs on */
  o->s.tarp.repeat = o->s.tarp.repeat;
  (void)a;
}

static float sweep_weight(le_meld_osc* o, float a) {
  if (o->s.tarp.n >= o->s.tarp.len) return 0.0f;
  const float s = (1.0f - o->s.tarp.decay) / (1.0f - expf(-a));
  o->s.tarp.decay *= o->s.tarp.step;
  o->s.tarp.n++;
  return 1.0f - s;
}

static float tarp_time(float m1) {
  if (m1 < 0.5f) return 0.2f * m1;
  const float x = 2.0f * m1 - 1.0f;
  return 0.75f * x * x * x + 0.1f * (1.0f - x * x * x);
}

static float tarp_internal(le_meld_osc* o) {
  const float rate = o->irate;
  const float m2 = o->m2;
  const float fmax = fminf(0.5f * rate, 22000.0f);
  const float f0 = 0.5f * o->hz;
  const float a = 7.5f * (0.5f + 0.5f * m2);
  const float w = sweep_weight(o, a);
  const float r = 2.0f + 28.0f * m2 * m2 * m2 * m2;
  const float fosc = w * fminf(r * f0, fmax) + (1.0f - w) * f0;
  const float sine = mo_sine(o->s.tarp.ph);
  o->s.tarp.ph = mo_wrap(o->s.tarp.ph + fminf(fosc, fmax) / rate);
  const float gn = fmaxf(0.0f, 0.2f * m2 - 0.1f) * sqrtf(rate / 44100.0f);
  const float fc = w * fmax + (1.0f - w) * f0;
  const float lp = le_meld_svf(&o->s.tarp.lp, gn * mo_bipolar(&o->rng),
                               fminf((float)MO_PI * fc / rate, 1.5f), 1.0f / (2.0f + 0.9f * m2), 0, 0);
  const float u = sine + lp;
  const float D = 1.0f + 3.7f * m2;
  return 1.4f * 0.5f * (sine + (tanh_odd(D * u + 0.3f) - 0.29131261f) / D);
}

/* Extratone: the kernel as a kick from (20 + 80 M1)(100 + 140 M2) Hz down to
 * 20 + 80 M1 Hz over 100 to 20 ms, restarted at an eighth of the note's
 * frequency without resetting its phase. */
static float extratone_internal(le_meld_osc* o) {
  const float rate = o->irate;
  const float m1 = o->m1, m2 = o->m2;
  const float a = 7.5f * (0.5f + 0.5f * m2);
  if (--o->s.tarp.repeat <= 0) {
    o->s.tarp.repeat = (int32_t)fmaxf(1.0f, rate / fminf(fmaxf(o->hz / 8.0f, 0.1f), 0.5f * rate));
    sweep_start(o, 0.1f - 0.08f * m2 * m2, a);
  }
  const float w = sweep_weight(o, a);
  const float fmax = fminf(0.5f * rate, 22000.0f);
  const float f0 = 20.0f + 80.0f * m1;
  const float fosc = w * fminf((100.0f + 140.0f * m2) * f0, fmax) + (1.0f - w) * f0;
  const float sine = mo_sine(o->s.tarp.ph);
  o->s.tarp.ph = mo_wrap(o->s.tarp.ph + fosc / rate);
  const float fc = w * fmax + (1.0f - w) * f0;
  const float lp = le_meld_svf(&o->s.tarp.lp, 0.25f * sqrtf(rate / 44100.0f) * mo_bipolar(&o->rng),
                               fminf((float)MO_PI * fc / rate, 1.5f), 1.0f / (2.0f + 1.35f * m2), 0, 0);
  return 0.5f * (sine + tanh_odd(sine + lp + 0.3f) - 0.29131261f);
}

/* ---- the FM types (44.1 kHz) ---- */

/* Harmonic FM's modulator ratios, Segno's set: simple fractions, unity,
 * the ratios between 1 and 2, then the integers to 10. */
#define MO_HFM_RATIOS 18
static const float kHfmRatios[MO_HFM_RATIOS] = {
    0.25f, 1.0f / 3.0f, 0.5f, 2.0f / 3.0f, 0.75f, 1.0f, 1.25f, 4.0f / 3.0f, 1.5f,
    2.0f,  3.0f,        4.0f, 5.0f,        6.0f,  7.0f, 8.0f,  9.0f,        10.0f,
};

/* Fold FM's modulator ratios: the intervals 2, 3, 5, 7, 11, 12, 15 and
 * 19 semitones, Macro 1 squared crossing them evenly with neighbours
 * crossfaded. [measured] from the fold128-000..127 renders (Macro 1 at
 * each of its 128 steps), scratchpad meldfit/meas/fold_law.py: the lines
 * sit at the equal-tempered ratios (5 semitones' third sideband at 4.005
 * f0), and this law gives every step's spectrum within 0.05 to 1.1 dB
 * mean over its lines, the best crossfade at each step within 0.05 of
 * it. */
#define MO_FOLD_RATIOS 8
static const float kFoldRatios[MO_FOLD_RATIOS] = {
    1.1224620f, 1.1892071f, 1.3348399f, 1.4983071f, 1.8877486f, 2.0f, 2.3784142f, 2.9966142f,
};

/* Two FM pairs at the neighbouring ratios of `ratios` at position `pos`
 * (0..1), crossfaded; `amount` in cycles, each pair's index capped so that
 * the carrier, the modulator and the deviation stay below 0.4 of the
 * rate. */
static float fm_pairs(le_meld_osc* o, const float* ratios, int n, float pos, float amount) {
  const double dc = o->hz / o->irate;
  const float p = mo_clamp(pos, 0.0f, 1.0f) * (float)(n - 1);
  int a = (int)p;
  if (a > n - 2) a = n - 2;
  const float fr = p - (float)a;
  float y = 0.0f;
  for (int k = 0; k < 2; ++k) {
    const float r = ratios[a + k];
    const float cap = fmaxf(0.0f, (0.4f - (float)dc - (float)dc * r) / (float)fmax(dc, 1e-9));
    const float index = fminf(amount, cap);
    const float yk = sinf((float)(MO_TWO_PI * (o->s.fm.c + index * mo_sine(o->s.fm.m[k]))));
    y += (k == 0 ? 1.0f - fr : fr) * yk;
    o->s.fm.m[k] = mo_wrap(o->s.fm.m[k] + fmin(dc * r, 0.5));
  }
  o->s.fm.c = mo_wrap(o->s.fm.c + dc);
  return y;
}

static float simple_fm_internal(le_meld_osc* o) {
  const double dc = o->hz / o->irate;
  const float m3 = o->m1 * o->m1 * o->m1;
  const float index = 4.0f * m3 + 0.01f * (1.0f - m3);
  const double dm = fmin(dc * 8.0 * o->m2 * o->m2, 0.5);
  const float y = sinf((float)(MO_TWO_PI * (o->s.fm.c + index * mo_sine(o->s.fm.m[0]))));
  o->s.fm.m[0] = mo_wrap(o->s.fm.m[0] + dm);
  o->s.fm.c = mo_wrap(o->s.fm.c + dc);
  return y;
}

static float harmonic_fm_internal(le_meld_osc* o) {
  return fm_pairs(o, kHfmRatios, MO_HFM_RATIOS, o->m2, o->m1);
}

static float fold_fm_internal(le_meld_osc* o) {
  const float x = fm_pairs(o, kFoldRatios, MO_FOLD_RATIOS, o->m1 * o->m1, 4.0f * o->m1);
  const float G = 1.0f + 7.7f * o->m2;
  const float u = tanhf(G * x + 0.4f) - 0.37994896f;
  const float d = 0.08f * o->m1 / G;
  float v = (1.0f + 2.0f * o->m2) * mo_parabolic(mo_wrap(o->s.fm.psi + d * u));
  if (v > 1.0f) v = 2.0f - v;
  if (v < -1.0f) v = -2.0f - v;
  o->s.fm.psi = mo_wrap(o->s.fm.psi + fmin(o->hz / o->irate, 0.5));
  return 1.4f * v;
}

/* Squelch: an FM bass two octaves down, a self-modulated triangle and a
 * triangle 32 times higher as its modulators. */
static float squelch_internal(le_meld_osc* o) {
  const double inc = fmin(0.25 * o->hz / o->irate, 0.5);
  const float t1p = o->s.squelch.t1;
  const float t1 = mo_tri_naive(mo_wrap(o->s.squelch.m + 0.2 * o->m2 * t1p));
  const float t2 = mo_tri_naive(mo_wrap(o->s.squelch.h - 0.9 * o->m2 * t1p));
  const float m3 = o->m1 * o->m1 * o->m1;
  const float index = 4.0f * m3 + 0.01f * (1.0f - m3);
  const float y =
      sinf((float)(MO_TWO_PI * (o->s.squelch.c + index * (-0.9f * t1 - 0.1f * t2))));
  o->s.squelch.t1 = t1;
  o->s.squelch.c = mo_wrap(o->s.squelch.c + inc);
  o->s.squelch.m = mo_wrap(o->s.squelch.m + inc);
  o->s.squelch.h = mo_wrap(o->s.squelch.h + fmin(32.0 * inc, 0.5));
  return y;
}

/* ---- Square 5th ---- */

/* A position x in [0, 1] skewed by e. */
static float sq5_skew(float x, float e) {
  const float e2 = 32.0f * e * e;
  return e > 0.0f ? 1.0f - (1.0f - x) / (e2 * x + 1.0f) : x / (e2 * (1.0f - x) + 1.0f);
}

/* A unit pulse over [lo, hi) of the cycle with corrected edges. */
static float sq5_gate(double ph, float lo, float hi, float dt) {
  const float in = ph >= lo && ph < hi ? 1.0f : 0.0f;
  return in + mo_blep(ph, lo, dt) - mo_blep(ph, hi, dt);
}

static float sq5_tick(le_meld_osc* o) {
  const float m1 = o->m1, m2 = o->m2;
  const double mult = m1 <= 0.5f ? 1.0 : 3.0;
  /* the phase scales with the multiple so the wave stays continuous */
  if (o->s.basic.ph[1] != 0.0 && o->s.basic.ph[1] != mult) {
    o->s.basic.ph[0] = mo_wrap(o->s.basic.ph[0] * mult / o->s.basic.ph[1]);
  }
  o->s.basic.ph[1] = mult;
  const float dt = fminf((float)mult * o->hz, 0.45f * o->rate) / o->rate;
  const double ph = o->s.basic.ph[0];
  const float a = m2 * fabsf(1.0f - 2.0f * m1);
  const float d1 = 1.0f - 0.5f / (16.0f * a * a + 1.0f);
  const float m = m1 <= 0.5f ? 2.0f * m1 : 2.0f * m1 - 1.0f;
  const float L = fminf(4.0f * m, 2.0f);
  const float x4 = fmodf(4.0f * m1, 2.0f);
  const float e = -m2 * (1.0f - fabsf(x4 - 1.0f));
  const float ulo = sq5_skew(0.5f - m / 6.0f, e), uhi = sq5_skew(0.5f + m / 6.0f, e);
  const float w = uhi - ulo;
  float y = mo_pulse(ph, d1, dt);
  y -= L * sq5_gate(ph, d1 * ulo, d1 * uhi, dt);
  y += L * sq5_gate(ph, d1 + (1.0f - d1) * ulo, d1 + (1.0f - d1) * uhi, dt);
  /* the mean taken out */
  y -= (2.0f * d1 - 1.0f) + L * w * (1.0f - 2.0f * d1);
  o->s.basic.ph[0] = mo_wrap(ph + dt);
  return y;
}

/* ---- Square Sync ---- */

/* A step of height h at time te in (0, 1] of the sample interval: its
 * correction to this sample and to the one before. */
static void sync_step(float h, double te, float* now, float* prev) {
  const float t = (float)te;
  *now += h * (-0.5f * t * t);
  *prev += h * (0.5f * (1.0f - t) * (1.0f - t));
}

/* The square's edges while its unwrapped phase runs from p0 at time t0 to
 * time t1 at dp per sample: up at whole phases, down at halves. */
static void sync_edges(double p0, double dp, double t0, double t1, float* now, float* prev) {
  double pe = (floor(p0 * 2.0) + 1.0) * 0.5;
  for (;;) {
    const double te = t0 + (pe - p0) / dp;
    if (te >= t1) break;
    sync_step(fmod(pe, 1.0) == 0.0 ? 2.0f : -2.0f, te, now, prev);
    pe += 0.5;
  }
}

/* Two 50 % squares hard-synced to a master at the note's frequency, the
 * first raised by 2 kHz M1^2, the second by 2 kHz (M1^2 + M2^2); every
 * step is corrected across two samples, so the output runs one sample
 * late. */
static float sync_tick(le_meld_osc* o) {
  const float rate = o->rate;
  const double dm = fmin(o->hz, 12543.85) / rate;
  const double ds[2] = {fmin(o->hz + 2000.0f * o->m1 * o->m1, 0.45f * rate) / rate,
                        /* fit: the second slave rides on the first (the sync renders) */
                        fmin(o->hz + 2000.0f * (o->m1 * o->m1 + o->m2 * o->m2), 0.45f * rate) / rate};
  double master = o->s.sync.master + dm;
  const int wrap = master >= 1.0;
  /* the reset's time within this sample interval */
  const double tr = wrap ? 1.0 - (master - 1.0) / dm : 1.0;
  if (wrap) master -= 1.0;
  float now = 0.0f, prev = 0.0f;
  for (int i = 0; i < 2; ++i) {
    const double p0 = o->s.sync.slave[i];
    double end;
    if (wrap) {
      sync_edges(p0, ds[i], 0.0, tr, &now, &prev);
      const double at = mo_wrap(p0 + ds[i] * tr);
      if (at >= 0.5) sync_step(2.0f, tr, &now, &prev); /* back up to +1 */
      sync_edges(0.0, ds[i], tr, 1.0, &now, &prev);
      end = ds[i] * (1.0 - tr);
    } else {
      sync_edges(p0, ds[i], 0.0, 1.0, &now, &prev);
      end = p0 + ds[i];
    }
    end = mo_wrap(end);
    o->s.sync.slave[i] = end;
    now += end < 0.5 ? 1.0f : -1.0f;
  }
  o->s.sync.master = master;
  const float out = 0.5f * (o->s.sync.out + prev);
  o->s.sync.out = now;
  return out;
}

/* ---- Rain ---- */

static float rain_k(float q) {
  return 2.0f * (1.0f - 4.0f * q / (3.0f * q + 1.0f) - 4.0f * fmaxf(0.0f, q - 1.0f) * fmaxf(0.0f, q - 1.0f));
}

static float rain_tick(le_meld_osc* o) {
  const float rate = o->rate;
  const float m1 = o->m1, m2 = o->m2;
  /* the lanes' pitches scatter around the note, redrawn when it changes */
  if (o->hz != o->s.rain.last_hz) {
    o->s.rain.last_hz = o->hz;
    const float glo = mo_tan(20.0f, rate), ghi = mo_tan(fminf(20480.0f, 0.49f * rate), rate);
    for (int i = 0; i < LE_MELD_RAIN_LANES; ++i) {
      o->s.rain.g[i] = mo_clamp(mo_tan(fminf(o->hz, 0.49f * rate), rate) + 0.025f * mo_bipolar(&o->rng),
                                glo, ghi);
    }
  }
  const float lambda = 10.0f * m2 * m2 + 0.1f * (1.0f - m2 * m2);
  const float kd = fmaxf(rain_k(0.75f + 0.23f * m1), 0.005f);
  float y = 0.0f;
  for (int i = 0; i < LE_MELD_RAIN_LANES; ++i) {
    float in = 0.0f;
    o->s.rain.timer[i] -= 1.0f;
    if (o->s.rain.timer[i] <= 0.0f) {
      const float u = fmaxf(mo_uniform(&o->rng), 1e-7f);
      o->s.rain.timer[i] = -logf(u) / lambda * rate;
      const float rho = fabsf(mo_bipolar(&o->rng));
      in = 4.0f * (1.0f - rho) + 12.0f * rho;
    }
    float bp = 0.0f;
    (void)le_meld_svf(&o->s.rain.lane[i], in, o->s.rain.g[i], kd, &bp, 0);
    y += bp;
  }
  /* the background: pink-like noise through a band-pass at f/2 */
  const uint32_t c = ++o->s.rain.counter;
  int row = 0;
  while (row < LE_MELD_VOSS_ROWS - 1 && ((c >> row) & 1u) == 0) row++;
  const float fresh = mo_bipolar(&o->rng);
  o->s.rain.sum += fresh - o->s.rain.rows[row];
  o->s.rain.rows[row] = fresh;
  const float pink = (o->s.rain.sum + mo_bipolar(&o->rng)) / 17.0f;
  o->s.rain.lfo = mo_wrap(o->s.rain.lfo + 0.1 / rate);
  const float swell = 1.0f + 0.5f * mo_sine(o->s.rain.lfo);
  float bg = 0.0f;
  (void)le_meld_svf(&o->s.rain.bg, pink * swell, mo_tan(fminf(0.5f * o->hz, 0.49f * rate), rate),
                    fmaxf(rain_k(0.5f + 0.45f * m1), 0.005f), &bg, 0);
  return 1.7f * (y + bg);
}

/* ---- Noise Loop ---- */

/* Live's Noise Loop, written from the reader's description in
 * segno-re-findings/rng-01-drift-meld.md, section 2 [code]: a two-word
 * xorshift (10, 13, 10) from a fixed seed fills three ring buffers of a
 * tenth of a second with raw noise, backwards, when the oscillator is
 * built; every sample it records one more 2.5 kHz low-passed draw into the
 * writer buffer, two refresh taps half a cycle apart hand the writer's
 * buffer to a reader when they wrap (with a new random level), and each
 * reader plays its buffer backwards from its newest sample through two
 * heads half a loop apart. The noise is the same in every voice and every
 * instance. */
static uint32_t nl_step(le_meld_nloop* l) {
  const uint32_t t = l->gx ^ (l->gx << 10);
  l->gx = l->gy;
  l->gy = l->gy ^ (l->gy >> 10) ^ t ^ (t >> 13);
  return l->gy;
}

static float nl_unit(uint32_t y) { return (float)(y >> 9) / 4194304.0f - 1.0f; }

/* The rational tan the description gives. */
static float nl_tan(float x) {
  const float x2 = x * x;
  return x * (0.99999946f - 0.09652461f * x2) / (1.0f - 0.42986727f * x2 + 0.00998188f * x2 * x2);
}

/* M1 cubed, through the fast log2 and exp2 the description gives. */
static float nl_cube(float m) {
  m = fmaxf(m, 1e-6f);
  int e;
  const float fr = frexpf(m, &e); /* m = fr 2^e, fr in [0.5, 1) */
  const float mm = 2.0f * fr - 1.0f;
  const float lg = (float)(e - 1) + mm * (2.1196218f + mm * (0.3883265f - 0.0384236f * mm)) / (mm + 1.4695246f);
  float z = 3.0f * lg + 127.0f;
  z = mo_clamp(z, 0.0f, 255.0f);
  const float zi = floorf(z), f = z - zi;
  const float p = 1.0f + f * (0.6930501f + f * (0.2412875f + f * (0.0521745f + f * 0.0134879f)));
  return ldexpf(p, (int)zi - 127);
}

/* The construction fill is the same for every oscillator at a rate: it is
 * made once and copied into an oscillator's buffers the first time it
 * plays Noise Loop. */
static float g_nl_fill[3][LE_MELD_LOOP_MAX];
static le_meld_nloop g_nl_after; /* the generator after the fill */
static float g_nl_rate = -1.0f;

static void nl_tables(float rate) {
  if (rate == g_nl_rate) return;
  le_meld_nloop* l = &g_nl_after;
  l->n = (int32_t)floorf(2.0f * rate / 20.0f);
  if (l->n > LE_MELD_LOOP_MAX) l->n = LE_MELD_LOOP_MAX;
  l->gx = 0xFFFFFFFFu;
  l->gy = 0x0103BC47u;
  for (int k = 0; k < 3; ++k) {
    int32_t w = 0;
    for (int32_t i = 0; i < l->n; ++i) {
      if (w == 0) w = l->n;
      w--;
      g_nl_fill[k][w] = nl_unit(nl_step(l));
    }
  }
  g_nl_rate = rate;
}

static void nl_ensure(le_meld_nloop* l) {
  if (l->built) return;
  memcpy(l->buf, g_nl_fill, sizeof(g_nl_fill));
  l->gx = g_nl_after.gx;
  l->gy = g_nl_after.gy;
  l->w[0] = l->w[1] = l->w[2] = 0;
  l->built = 1;
}

static void nl_build(le_meld_nloop* l, float rate) {
  nl_tables(rate);
  l->n = g_nl_after.n;
  l->built = 0;
  l->ra = 1;
  l->rb = 0;
  l->wr = 2;
  l->z = 0.0f;
  l->ga = l->gb = 1.0f;
  const float om = fminf(2.0f * (float)MO_PI * 2500.0f / rate, 3.1337388f);
  const float K = 2.0f * nl_tan(0.5f * om);
  l->b0 = K / (K + 2.0f);
  l->a1 = (K - 2.0f) / (K + 2.0f);
}

static void nl_note(le_meld_nloop* l, float phase) {
  nl_ensure(l);
  l->psi = 0.0f;
  l->a_prev = l->b_prev = 0.0f;
  l->theta = phase;
  l->ic1 = l->ic2 = 0.0f;
  l->countdown = 1;
}

static float nl_window(float t, float w) {
  const float tt = t < 0.5f ? t : 0.5f + 0.5f * w - t;
  const float x = mo_clamp(2.0f * tt / fmaxf(w, 1e-9f), 0.0f, 1.0f);
  return x * (2.0f - x);
}

static float nl_read(const le_meld_nloop* l, int32_t k, float pos) {
  const int32_t i = (int32_t)pos;
  const float ph = pos - (float)i;
  const float* x = l->buf[k];
  const int32_t j0 = (l->w[k] + i) % l->n, j1 = (j0 + 1) % l->n;
  return x[j0] + ph * (x[j1] - x[j0]);
}

static float noise_loop_tick(le_meld_osc* o) {
  le_meld_nloop* l = &o->nloop;
  nl_ensure(l);
  const float rate = o->rate, m2 = o->m2;
  const float h = fminf(0.5f * o->hz, 0.5f * rate);
  /* the output high-pass's coefficient, every 32 samples */
  if (--l->countdown <= 0) {
    l->g = nl_tan(0.5f * fminf(2.0f * (float)MO_PI * h / rate, 3.1337388f));
    l->countdown = 32;
  }
  /* record one low-passed draw, backwards */
  const float u = nl_unit(nl_step(l));
  const float y = l->b0 * u + l->z;
  l->z = l->b0 * u - l->a1 * y;
  if (l->w[l->wr] == 0) l->w[l->wr] = l->n;
  l->buf[l->wr][--l->w[l->wr]] = y;
  /* the refresh taps */
  const float dpsi = 0.5f * (119.76f * nl_cube(o->m1) + 0.24f) / rate;
  float w, s;
  if (m2 < 0.5f) {
    w = (1.0f - 2.0f * m2) + 2.0f * m2 * 0.02f * dpsi;
    s = 0.0f;
  } else {
    w = 0.02f * dpsi;
    s = 2.0f * fminf(m2, 1.0f) - 1.0f;
  }
  const float psi0 = l->psi;
  l->psi = psi0 + dpsi;
  if (l->psi >= 1.0f) l->psi -= 1.0f;
  const float ta = psi0;
  float tb = psi0 + 0.5f;
  if (tb >= 1.0f) tb -= 1.0f;
  if (l->a_prev > ta) {
    const int32_t t = l->ra;
    l->ra = l->wr;
    l->wr = t;
    l->ga = 1.0f - s * nl_unit(nl_step(l));
  }
  if (l->b_prev > tb) {
    const int32_t t = l->rb;
    l->rb = l->wr;
    l->wr = t;
    l->gb = 1.0f - s * nl_unit(nl_step(l));
  }
  const float wa = nl_window(ta, w), wb = nl_window(tb, w);
  l->a_prev = ta;
  l->b_prev = tb;
  /* the readers: two heads half a loop apart, backwards in time */
  const float L = fminf(rate / fmaxf(h, 1e-6f), (float)(l->n - 4));
  const float th0 = l->theta;
  l->theta = th0 + h / rate;
  if (l->theta >= 1.0f) l->theta -= 1.0f;
  float th1 = th0 + 0.5f;
  if (th1 >= 1.0f) th1 -= 1.0f;
  const float t1 = 1.0f - fabsf(2.0f * th0 - 1.0f), t2 = 1.0f - fabsf(2.0f * th1 - 1.0f);
  const float la = t1 * nl_read(l, l->ra, th0 * L) + t2 * nl_read(l, l->ra, th1 * L);
  const float lb = t1 * nl_read(l, l->rb, th0 * L) + t2 * nl_read(l, l->rb, th1 * L);
  const float x = wa * l->ga * la + wb * l->gb * lb;
  /* the output high-pass at f/2 */
  const float k = 1.4144272f, g = l->g;
  const float a = g / (1.0f + g * (g + k));
  const float v3 = x - l->ic2;
  const float d1 = a * (v3 - (g + k) * l->ic1);
  const float d2 = a * (g * v3 + l->ic1);
  const float v1 = l->ic1 + d1, v2 = l->ic2 + d2;
  l->ic1 += 2.0f * d1;
  l->ic2 += 2.0f * d2;
  const float hp = x - k * v1 - v2;
  return (2.0f - m2) * 1.25f * sqrtf(rate / 44100.0f) * hp;
}

/* ---- Chip (10.05 kHz) ---- */

static float chip_internal(le_meld_osc* o) {
  const float rate = fminf(o->rate, 10050.0f);
  const float m1 = o->m1, m2 = o->m2;
  /* the trill: the note and a second up to two octaves above, a fifth of
   * each step silent */
  float tr = 50.0f * m2 * m2;
  if (m2 <= 0.0f && o->s.chip.upper) tr = 500.0f;
  o->s.chip.trill += (double)(tr / rate);
  if (o->s.chip.trill >= 1.0) {
    o->s.chip.trill -= floor(o->s.chip.trill);
    o->s.chip.upper = m2 > 0.0f ? !o->s.chip.upper : 0;
  }
  const float gate = (tr > 0.0f && o->s.chip.trill > 0.8) ? 0.0f : 1.0f;
  float dt = fminf(o->hz / rate, 0.999f);
  if (o->s.chip.upper) {
    const float d2 = o->hz * exp2f(2.0f * m1) / rate;
    if (d2 < 1.0f) dt = d2;
  }
  const float duty = 0.5f * (1.0f - m1) + 0.125f * m1;
  const float fade = mo_clamp(1.0f - (dt - 0.75f) / 0.1f, 0.0f, 1.0f);
  const float pulse = mo_pulse(o->s.chip.ph, duty, fminf(dt, 0.49f));
  o->s.chip.ph = mo_wrap(o->s.chip.ph + dt);
  /* 8 bits, and a hiss 45 dB down */
  const float v = roundf(mo_clamp(128.0f * gate * fade * pulse, -128.0f, 127.0f)) / 128.0f;
  return 0.5f * (v + 0.01f * mo_bipolar(&o->rng));
}

/* ---- Crackle ---- */

static float crackle_tick(le_meld_osc* o) {
  const float rate = o->rate, m1 = o->m1, m2 = o->m2;
  o->s.crackle.timer -= 1.0f;
  if (o->s.crackle.timer <= 0.0f) {
    /* the next event, and this one's level, decay and band */
    const float lambda = 20.0f + 1980.0f * m1 * m1 * m1;
    const float rho = mo_bipolar(&o->rng);
    const float u = mo_clamp(0.5f * (rho + 1.0f), 1e-5f, 0.99999f);
    o->s.crackle.timer += -logf(u) / lambda * rate;
    const float p = fabsf(rho) * 0.99999f;
    const float X = mo_clamp(1.0f / (1.0f - p), 1.0f, 30.0f);
    const float P = (X - 1.0f) / 29.0f;
    const float L = (1.0f - P) * (-40.0f * (1.0f - m2)) + 9.0f * P;
    o->s.crackle.env = powf(10.0f, L / 20.0f);
    const float um = m2 * mo_uniform(&o->rng);
    const float tau = 0.001f + 0.014f * um * um * um;
    o->s.crackle.decay = powf(0.001f, 1.0f / (rate * tau));
    const float fc = o->hz * exp2f(6.0f * m2 * mo_bipolar(&o->rng));
    const float v = mo_uniform(&o->rng);
    const float R = exp2f(0.5f * (0.1f * v + 8.0f * (1.0f - v)));
    o->s.crackle.glp = mo_tan(fminf(R * fc, 18000.0f), rate);
    o->s.crackle.ghp = mo_tan(fminf(fmaxf(fc / R, 50.0f), 0.49f * rate), rate);
  }
  const float x = o->s.crackle.env * mo_bipolar(&o->rng);
  o->s.crackle.env *= o->s.crackle.decay;
  const float lp = le_meld_svf(&o->s.crackle.lp, x, o->s.crackle.glp, 1.4144f, 0, 0);
  float hp = 0.0f;
  (void)le_meld_svf(&o->s.crackle.hp, lp, o->s.crackle.ghp, 2.857f, 0, &hp);
  const float D = powf(10.0f, (20.0f * (1.0f - m2) + 10.0f * (1.0f - m1)) / 20.0f);
  return fmaxf(-1.0f, D * hp) * sqrtf(rate / 44100.0f);
}

/* ---- Shepard's Pi ---- */

static float shepard_tick(le_meld_osc* o) {
  const float rate = o->rate;
  const float s = 2.0f * o->m1 - 1.0f;
  o->s.shepard.shift = mo_wrap(o->s.shepard.shift + (double)(s * s * s / rate));
  const float oct = log2f(fmaxf(o->hz, 20.0f) / 20.0f);
  const double q = mo_wrap(o->s.shepard.shift + (double)(oct - floorf(oct)));
  const int r = 7 - (int)(8.0 * q);
  const float x = (float)(8.0 * q - floor(8.0 * q));
  const float W = 2.0f + 5.5f * o->m2;
  const float lo = oct - 0.5f * W, hi = fminf(oct + 0.5f * W, 7.0f);
  float y = 0.0f;
  for (int k = 0; k < 8; ++k) {
    const float pos = x + (float)(((k - r) % 8 + 8) % 8);
    const float w = fminf(mo_clamp(2.0f * (pos - lo), 0.0f, 1.0f), mo_clamp(2.0f * (hi - pos), 0.0f, 1.0f));
    if (w > 0.0f) y += w * mo_parabolic(o->s.shepard.ph[k]);
    o->s.shepard.ph[k] = mo_wrap(o->s.shepard.ph[k] + fminf(20.0f * exp2f(pos) / rate, 0.5f));
  }
  return 2.2f / W * y;
}

/* ---- Bitgrunge ---- */

/* Macro 2 above 0.5 makes the counter skip: Live's skips come at the same
 * counts on every note and in every instance, at C3 as at C4. [measured]
 * The counts that come twice at Macro 2 1, from the 3 s of osc-20-1010
 * (and grunge-notes, five notes alike), scratchpad meldfit/meas/grunge.py;
 * past the measured span the pattern starts over, and below Macro 2 1 a
 * share 2 M2 - 1 of them is kept, picked by a golden-ratio sequence.
 * [Segno] */
#define MO_GRUNGE_SPAN 12550
static const uint16_t kGrungeGlitch[161] = {1, 3, 194, 374, 460, 499, 517, 521, 552, 585, 636, 683, 747, 756, 896, 943, 951, 961, 1039, 1104, 1249, 1268, 1562, 1575, 1683, 1775, 1851, 1855, 2173, 2236, 2474, 2485, 2799, 2857, 2947, 3064, 3181, 3270, 3484, 3569, 3820, 3846, 3877, 3913, 3998, 4087, 4153, 4278, 4302, 4414, 4446, 4477, 4481, 4520, 4627, 4649, 4757, 4853, 4923, 4990, 5045, 5230, 5236, 5364, 5414, 5479, 5829, 5951, 5991, 6134, 6181, 6205, 6208, 6250, 6343, 6348, 6384, 6525, 6573, 6646, 6650, 6743, 6815, 6881, 6889, 6897, 6938, 6964, 6992, 7012, 7109, 7345, 7383, 7392, 7414, 7593, 7607, 7610, 7654, 7669, 7695, 7838, 7883, 7888, 7954, 7989, 8357, 8523, 8573, 8676, 8774, 8852, 9022, 9046, 9059, 9219, 9260, 9336, 9369, 9394, 9438, 9600, 9636, 9708, 9727, 9908, 9918, 10036, 10187, 10455, 10671, 10783, 10789, 10814, 10837, 10931, 11106, 11116, 11168, 11248, 11290, 11362, 11399, 11403, 11418, 11449, 11472, 11572, 11621, 11629, 11680, 11690, 11694, 11919, 11926, 12067, 12179, 12324, 12352, 12442, 12513};

#define MO_GRUNGE_N ((int32_t)(sizeof(kGrungeGlitch) / sizeof(kGrungeGlitch[0])))

static float grunge_tick(le_meld_osc* o) {
  const int a = (int)(9.0f * (1.0f - o->m1));
  int b = (int)(o->m2 * (float)(a + 1) + 16.0f * (1.0f - o->m2));
  if (b < a + 1) b = a + 1;
  if (b > 16) b = 16;
  o->s.grunge.frac += (double)(32.0f * fminf(o->hz, 0.5f * o->rate) / o->rate);
  const uint32_t before = o->s.grunge.count;
  while (o->s.grunge.frac >= 1.0) {
    o->s.grunge.frac -= 1.0;
    o->s.grunge.count++;
    const int32_t s = (int32_t)(o->s.grunge.step++ % MO_GRUNGE_SPAN);
    if (s == 0) o->s.grunge.gi = 0;
    while (o->s.grunge.gi < MO_GRUNGE_N && kGrungeGlitch[o->s.grunge.gi] < s) o->s.grunge.gi++;
    if (o->m2 > 0.5f && o->s.grunge.gi < MO_GRUNGE_N && kGrungeGlitch[o->s.grunge.gi] == s) {
      const double g = 0.6180339887498949 * (double)o->s.grunge.gi;
      if (o->m2 >= 1.0f || g - floor(g) < 2.0 * o->m2 - 1.0) o->s.grunge.count++;
    }
  }
  if (o->s.grunge.count != before || o->s.grunge.out == 0.0f) {
    /* the parity of counter bits a .. b - 1 */
    uint32_t bits = (o->s.grunge.count >> a) & ((1u << (b - a)) - 1u);
    bits ^= bits >> 16;
    bits ^= bits >> 8;
    bits ^= bits >> 4;
    bits ^= bits >> 2;
    bits ^= bits >> 1;
    o->s.grunge.out = (bits & 1u) ? 0.7f : -0.7f;
  }
  return o->s.grunge.out;
}

/* ---- Bubble ---- */

static float bubble_tick(le_meld_osc* o) {
  const float rate = o->rate, m1 = o->m1, m2 = o->m2;
  o->s.bubble.timer -= 1.0f;
  if (o->s.bubble.timer <= 0.0f) {
    /* a bubble of a random radius about the one that rings at the note */
    const float lambda = 1.5f + 498.5f * m1 * m1 * m1;
    const float rho = mo_bipolar(&o->rng);
    o->s.bubble.timer += -logf(mo_clamp(0.5f * (rho + 1.0f), 1e-5f, 0.99999f)) / lambda * rate;
    const float p = 0.01f + 0.99f * fabsf(rho);
    const float r0 = o->hz < 20.0f ? 0.15f : 3.0f / fminf(o->hz, 0.5f * rate);
    const float sigma = 0.15f + 1.85f * m2;
    const float v = fmaxf(mo_uniform(&o->rng), 1e-7f);
    const float z = mo_clamp(sqrtf(-2.0f * logf(v)) * sinf((float)MO_PI * mo_bipolar(&o->rng) / 2.0f),
                             -10.0f, 10.0f);
    const float R = r0 * (1.0f + sigma * z);
    const int32_t k = o->s.bubble.slot;
    o->s.bubble.slot = (k + 1) % LE_MELD_BUBBLES;
    if (R > 0.0003f && R < 0.15f && o->s.bubble.amp[k] <= 0.01f) {
      /* Minnaert's pitch, rising as the bubble rings down */
      const float delta = 0.13f / R + 0.0072f * powf(R, -1.5f);
      o->s.bubble.amp[k] = fminf(2.0f * sqrtf(R), 0.4f);
      o->s.bubble.decay[k] = 1.0f - delta / rate;
      o->s.bubble.freq[k] = 3.0f / R;
      o->s.bubble.rise[k] = (3.0f / R) * 0.3f * p * delta / rate;
      o->s.bubble.ph[k] = 0.0;
    }
  }
  float y = 0.0f;
  for (int32_t k = 0; k < LE_MELD_BUBBLES; ++k) {
    if (o->s.bubble.amp[k] <= 0.001f) continue;
    y += o->s.bubble.amp[k] * mo_parabolic(o->s.bubble.ph[k]);
    o->s.bubble.ph[k] = mo_wrap(o->s.bubble.ph[k] + o->s.bubble.freq[k] / rate);
    o->s.bubble.freq[k] = fminf(o->s.bubble.freq[k] + o->s.bubble.rise[k], 0.5f * rate);
    o->s.bubble.amp[k] *= o->s.bubble.decay[k];
  }
  return powf(10.0f, 12.0f * (1.0f - m1) / 20.0f) * y;
}

/* ---- the interface ---- */

void le_meld_osc_init(le_meld_osc* o, float rate, uint32_t seed, float (*loop)[LE_MELD_LOOP_MAX]) {
  memset(o, 0, sizeof(*o));
  o->nloop.buf = loop;
  le_meld_osc_tables();
  o->rate = rate;
  o->irate = fminf(rate, 44100.0f);
  o->rng = seed != 0 ? seed : 0x9e3779b9u;
  o->ramp_n = (int32_t)(rate * 0.005f);
  if (o->ramp_n < 1) o->ramp_n = 1;
  o->hz = 261.6256f;
  o->note = 60.0f;
  nl_build(&o->nloop, rate); /* Noise Loop's buffers, filled once */
  le_meld_osc_set_type(o, LE_MELD_OSC_BASIC);
}

void le_meld_osc_set_type(le_meld_osc* o, int32_t type) {
  if (type < 0 || type >= LE_MELD_OSC_TYPES) type = LE_MELD_OSC_BASIC;
  o->type = type;
  memset(&o->s, 0, sizeof(o->s));
  memset(&o->rs, 0, sizeof(o->rs));
  le_meld_osc_snap(o);
  if (type >= LE_MELD_OSC_SWARM_SINE && type <= LE_MELD_OSC_SWARM_SQUARE) {
    for (int k = 0; k < LE_MELD_SWARM_LANES; ++k) o->s.swarm.x[k] = mo_bipolar(&o->rng);
    swarm_retune(o);
    o->s.swarm.left = MO_SWARM_UPDATE;
  } else if (type == LE_MELD_OSC_CHORD) {
    chord_retune(o);
    o->s.chord.left = MO_CHORD_UPDATE;
  } else if (type == LE_MELD_OSC_RAIN) {
    for (int i = 0; i < LE_MELD_RAIN_LANES; ++i) o->s.rain.timer[i] = 1.0f;
    o->s.rain.last_hz = -1.0f;
  }
}

void le_meld_osc_set(le_meld_osc* o, float hz, float note, float m1, float m2) {
  o->hz = hz;
  o->note = note;
  m1 = mo_clamp(m1, 0.0f, 1.0f);
  m2 = mo_clamp(m2, 0.0f, 1.0f);
  if (m1 != o->m1_to || m2 != o->m2_to) {
    o->m1_to = m1;
    o->m2_to = m2;
    o->ramp_left = o->ramp_n;
    o->m1_step = (m1 - o->m1) / (float)o->ramp_n;
    o->m2_step = (m2 - o->m2) / (float)o->ramp_n;
  }
}

void le_meld_osc_snap(le_meld_osc* o) {
  o->m1 = o->m1_to;
  o->m2 = o->m2_to;
  o->ramp_left = 0;
  /* the tones a note starts with come from its own frequency and macros, so
   * the tones two chords share start and stay in phase (fit: the Chord
   * renders, where a shared tone sums at full level) */
  if (o->type == LE_MELD_OSC_CHORD) {
    chord_retune(o);
    o->s.chord.left = MO_CHORD_UPDATE;
  } else if (o->type >= LE_MELD_OSC_SWARM_SINE && o->type <= LE_MELD_OSC_SWARM_SQUARE) {
    swarm_retune(o);
    o->s.swarm.left = MO_SWARM_UPDATE;
  } else if (o->type == LE_MELD_OSC_TARP && o->s.tarp.n == 0) {
    /* a note's sweep takes its time and curve from the note's macros */
    sweep_start(o, tarp_time(o->m1), 7.5f * (0.5f + 0.5f * o->m2));
  }
}

void le_meld_osc_reset(le_meld_osc* o, float phase) {
  switch (o->type) {
    case LE_MELD_OSC_BASIC:
    case LE_MELD_OSC_SQUARE_5TH:
      o->s.basic.ph[0] = phase;
      break;
    case LE_MELD_OSC_DUAL_BASIC:
      o->s.basic.ph[0] = o->s.basic.ph[1] = phase;
      break;
    case LE_MELD_OSC_NOISY_SHAPES:
      memset(&o->s.noisy, 0, sizeof(o->s.noisy));
      o->s.noisy.ph[0] = o->s.noisy.ph[1] = o->s.noisy.half = phase;
      break;
    case LE_MELD_OSC_SQUARE_SYNC:
      memset(&o->s.sync, 0, sizeof(o->s.sync));
      o->s.sync.master = o->s.sync.slave[0] = o->s.sync.slave[1] = phase;
      break;
    case LE_MELD_OSC_SUB:
      o->s.sub.ph = o->s.sub.ph4 = phase;
      break;
    case LE_MELD_OSC_SWARM_SINE:
    case LE_MELD_OSC_SWARM_TRIANGLE:
    case LE_MELD_OSC_SWARM_SAW:
    case LE_MELD_OSC_SWARM_SQUARE:
      /* every lane starts at a phase of its own */
      for (int k = 0; k < 2 * LE_MELD_SWARM_LANES; ++k) o->s.swarm.ph[k] = mo_uniform(&o->rng);
      swarm_retune(o);
      break;
    case LE_MELD_OSC_CHORD:
      for (int t = 0; t < LE_MELD_CHORD_TONES; ++t) o->s.chord.ph[t] = phase;
      chord_retune(o);
      break;
    case LE_MELD_OSC_FILTERED_NOISE:
      memset(&o->s.fnoise, 0, sizeof(o->s.fnoise));
      break;
    case LE_MELD_OSC_SIMPLE_FM:
    case LE_MELD_OSC_HARMONIC_FM:
    case LE_MELD_OSC_FOLD_FM:
      o->s.fm.c = phase;
      o->s.fm.m[0] = o->s.fm.m[1] = 0.0;
      o->s.fm.psi = phase;
      if (o->type != LE_MELD_OSC_SIMPLE_FM) memset(&o->rs, 0, sizeof(o->rs));
      break;
    case LE_MELD_OSC_SQUELCH:
      memset(&o->s.squelch, 0, sizeof(o->s.squelch));
      o->s.squelch.c = phase;
      break;
    case LE_MELD_OSC_TARP:
      memset(&o->s.tarp.lp, 0, sizeof(o->s.tarp.lp));
      o->s.tarp.ph = phase;
      sweep_start(o, tarp_time(o->m1), 7.5f * (0.5f + 0.5f * o->m2));
      break;
    case LE_MELD_OSC_EXTRATONE:
      o->s.tarp.ph = phase;
      o->s.tarp.repeat = 0;
      break;
    case LE_MELD_OSC_RAIN:
      for (int i = 0; i < LE_MELD_RAIN_LANES; ++i) memset(&o->s.rain.lane[i], 0, sizeof(o->s.rain.lane[i]));
      memset(&o->s.rain.bg, 0, sizeof(o->s.rain.bg));
      break;
    case LE_MELD_OSC_NOISE_LOOP:
      nl_note(&o->nloop, phase);
      break;
    case LE_MELD_OSC_CHIP:
      o->s.chip.ph = phase;
      o->s.chip.trill = 0.0;
      memset(&o->rs, 0, sizeof(o->rs));
      break;
    case LE_MELD_OSC_CRACKLE:
      memset(&o->s.crackle.lp, 0, sizeof(o->s.crackle.lp));
      memset(&o->s.crackle.hp, 0, sizeof(o->s.crackle.hp));
      o->s.crackle.timer = 0.0f;
      break;
    case LE_MELD_OSC_SHEPARD:
      o->s.shepard.shift = 0.0;
      for (int k = 0; k < 8; ++k) o->s.shepard.ph[k] = phase;
      break;
    case LE_MELD_OSC_BITGRUNGE:
      o->s.grunge.count = 0;
      o->s.grunge.frac = phase;
      o->s.grunge.out = 0.0f;
      o->s.grunge.step = 0;
      o->s.grunge.gi = 0;
      break;
    case LE_MELD_OSC_BUBBLE:
      memset(o->s.bubble.amp, 0, sizeof(o->s.bubble.amp));
      o->s.bubble.timer = 0.0f;
      break;
    default:
      break;
  }
}

float le_meld_osc_tick(le_meld_osc* o) {
  if (o->ramp_left > 0) {
    o->m1 += o->m1_step;
    o->m2 += o->m2_step;
    if (--o->ramp_left == 0) le_meld_osc_snap(o);
  }
  switch (o->type) {
    case LE_MELD_OSC_BASIC: return basic_tick(o);
    case LE_MELD_OSC_DUAL_BASIC: return dual_tick(o);
    case LE_MELD_OSC_NOISY_SHAPES: return mo_r44(o, noisy_internal);
    case LE_MELD_OSC_SQUARE_SYNC: return sync_tick(o);
    case LE_MELD_OSC_SQUARE_5TH: return sq5_tick(o);
    case LE_MELD_OSC_SUB: return sub_tick(o);
    case LE_MELD_OSC_SWARM_SINE:
    case LE_MELD_OSC_SWARM_TRIANGLE:
    case LE_MELD_OSC_SWARM_SAW:
    case LE_MELD_OSC_SWARM_SQUARE:
      return swarm_tick(o);
    case LE_MELD_OSC_HARMONIC_FM: return mo_r44(o, harmonic_fm_internal);
    case LE_MELD_OSC_FOLD_FM: return mo_r44(o, fold_fm_internal);
    case LE_MELD_OSC_SQUELCH: return mo_r44(o, squelch_internal);
    case LE_MELD_OSC_SIMPLE_FM: return mo_r44(o, simple_fm_internal);
    case LE_MELD_OSC_TARP: return mo_r44(o, tarp_internal);
    case LE_MELD_OSC_EXTRATONE: return mo_r44(o, extratone_internal);
    case LE_MELD_OSC_FILTERED_NOISE: return fnoise_tick(o);
    case LE_MELD_OSC_RAIN: return rain_tick(o);
    case LE_MELD_OSC_NOISE_LOOP: return noise_loop_tick(o);
    case LE_MELD_OSC_CHIP: return mo_resampled(o, fminf(o->rate, 10050.0f), chip_internal);
    case LE_MELD_OSC_CRACKLE: return crackle_tick(o);
    case LE_MELD_OSC_SHEPARD: return shepard_tick(o);
    case LE_MELD_OSC_BITGRUNGE: return grunge_tick(o);
    case LE_MELD_OSC_BUBBLE: return bubble_tick(o);
    case LE_MELD_OSC_CHORD: return chord_tick(o);
    default: return 0.0f;
  }
}
