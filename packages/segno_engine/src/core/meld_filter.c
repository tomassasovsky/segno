/*
 * meld_filter.c — Meld's filters (SEG-109). See meld_filter.h.
 */
#include "meld_filter.h"

#include <math.h>
#include <string.h>

#include "ms2_section.h"
#include "osr_section.h"

#define MF_PI 3.14159265358979323846f

static float mf_clamp(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

static float mf_db(float db) { return powf(10.0f, db / 20.0f); }

/* tan(pi f / rate), the argument clamped below pi/2. */
static float mf_tan(float hz, float rate) {
  return tanf(fminf(MF_PI * fmaxf(hz, 1.0f) / rate, 1.5668f));
}

/* The resonance map the SVF types share: r = m1 clamped to 0.9, q =
 * 4r/(3r + 1), the first section's damping 2(1 - q), the second's 2 - q. */
static void mf_q(float m1, float* k1, float* k2) {
  const float r = mf_clamp(m1, 0.0f, 0.9f);
  const float q = 4.0f * r / (3.0f * r + 1.0f);
  *k1 = 2.0f * (1.0f - q);
  *k2 = 2.0f - q;
}

/* One trapezoidal one-pole low-pass, g = tan(pi f / rate). */
static float mf_onepole(float* s, float x, float g) {
  const float v = g / (1.0f + g) * (x - *s);
  const float y = v + *s;
  *s = y + v;
  return y;
}

/* ---- the morphing SVF ---- */

/* The tap weights for morph position p = 3 m2: low at 0, band at 1, high
 * at 2, low and high (a notch) at 3, near equal power between. */
static void svf_weights(float m2, float w[3]) {
  const float p = 3.0f * m2;
  const float a = mf_clamp(fabsf(p - 1.5f) - 0.5f, 0.0f, 1.0f);
  const float b = mf_clamp(1.5f - fabsf(p - 2.5f), 0.0f, 1.0f);
  const float ab = a + b;
  w[0] = a;
  w[1] = sqrtf(fmaxf(0.0f, 1.0f - ab * ab));
  w[2] = b;
}

static float svf_stage(le_meld_svf_state* s, float x, float g, float k, const float w[3]) {
  float bp = 0.0f, hp = 0.0f;
  const float lp = le_meld_svf(s, x, g, k, &bp, &hp);
  return w[0] * lp + w[1] * bp + w[2] * hp;
}

/* ---- Meld's MS2 section ---- */

/* Meld's variant of the MS-20 section (ms2_section.h): the second
 * integrator's transconductance saturates like the first's, its input
 * offset 0.01 (fit: the Lowpass drive renders, 4.4 -> 1.9 dB rms; the
 * input stage and softer buffers the reading also names changed nothing or
 * fitted worse). */
static float meld_ms2_section(float* s, float x, const le_ms2_coef* c, float kfb) {
  const float g = c->g, he = c->he;
  const float u = LE_MS2_GI * x;
  const float vin = (u - s[0]) * he;
  float L = s[4], T = s[5], L2 = s[6];
  float X = 0.0f, y1 = 0.0f, y2 = 0.0f, b1 = 0.0f, b2 = 0.0f, w = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    if (pass == 1) {
      L = le_ms2_ota_secant(LE_MS2_KAPPA * (vin - b1) + LE_MS2_OTA_OFS);
      T = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
      L2 = le_ms2_ota_secant(LE_MS2_KAPPA * (b1 - y2) + 0.01f);
    }
    const float gl = g * L;
    const float A = 1.0f / (1.0f + gl);
    const float B = (gl * (vin + LE_MS2_OTA_OFS / LE_MS2_KAPPA) + s[1]) * A;
    const float g2 = g * L2;
    const float C1 = g2 / (1.0f + g2);
    const float C0 = s[2] / (1.0f + g2);
    const float F = -s[3] * he;
    const float P = T * kfb;
    const float Q = T * LE_MS2_DIODE_OFS;
    X = (P * (he * (C1 * B + C0) + F) + Q) / (1.0f - P * he * C1 * A);
    X = le_ms2_clamp(X, -LE_MS2_X_LIM, LE_MS2_X_LIM);
    y1 = le_ms2_clamp(A * X + B, -21.0f, 21.0f);
    b1 = le_ms2_clamp(y1, LE_MS2_BUF_LO, LE_MS2_BUF_HI);
    y2 = le_ms2_clamp(C1 * b1 + C0, -21.0f, 21.0f);
    b2 = le_ms2_clamp(y2, LE_MS2_BUF_LO, LE_MS2_BUF_HI);
    w = he * b2 + F;
  }
  s[4] = le_ms2_ota_secant(LE_MS2_KAPPA * (vin - b1) + LE_MS2_OTA_OFS);
  s[5] = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
  s[6] = le_ms2_ota_secant(LE_MS2_KAPPA * (b1 - y2) + 0.01f);
  s[0] = 2.0f * (u - vin) - s[0];
  s[1] = 2.0f * (y1 - X) - s[1];
  s[2] = 2.0f * y2 - s[2];
  s[3] = 2.0f * (b2 - w) - s[3];
  return w / LE_MS2_GI;
}

/* Segno's model of the MS-20 high-pass section, from the same parts: the
 * two capacitors in series in the signal path, the first transconductance
 * from the first node to the feedback node, the second from the second
 * node to ground, buffers after each node, the output DC-blocked and fed
 * back through the diode curve. Each capacitor's voltage is a one-pole
 * low-pass of what drives it (q1 of the input less the feedback, q2 of the
 * first buffer), so v1 = u - q1 and v2 = b1 - q2; the nonlinear elements are
 * linearised at the last estimate and the loop solved in closed form, twice
 * per sample. Small-signal: s^2 / (s^2 + (2 - k) w s + w^2). s: q1, q2 the
 * capacitor states, s[2] the output coupling, s[3..5] the secants. */
static float meld_ms2_hp_section(float* s, float x, const le_ms2_coef* c, float kfb) {
  const float g = c->g, he = c->he;
  const float u = LE_MS2_GI * x;
  float L1 = s[3], L2 = s[4], T = s[5];
  float X = 0.0f, v1 = 0.0f, v2 = 0.0f, b1 = 0.0f, b2 = 0.0f, w = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    if (pass == 1) {
      L1 = le_ms2_ota_secant(LE_MS2_KAPPA * (X - b1) + LE_MS2_OTA_OFS);
      L2 = le_ms2_ota_secant(-LE_MS2_KAPPA * b2 + 0.01f);
      T = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
    }
    const float G1 = g * L1 / (1.0f + g * L1), G2 = g * L2 / (1.0f + g * L2);
    /* v1 = (1 - G1)(u - s0) + G1 X, v2 = (1 - G2)(v1 - s1), w = he v2 + F,
     * X = T (kfb w + ofs) */
    const float F = -s[2] * he;
    const float a1 = (1.0f - G1) * (u - s[0]);
    const float P = T * kfb, Q = T * LE_MS2_DIODE_OFS;
    const float A = 1.0f - G2;
    /* X = P he A (a1 + G1 X - s1) + P F + Q */
    X = (P * (he * A * (a1 - s[1]) + F) + Q) / (1.0f - P * he * A * G1);
    X = le_ms2_clamp(X, -LE_MS2_X_LIM, LE_MS2_X_LIM);
    v1 = le_ms2_clamp(a1 + G1 * X, -21.0f, 21.0f);
    b1 = le_ms2_clamp(v1, LE_MS2_BUF_LO, LE_MS2_BUF_HI);
    v2 = le_ms2_clamp(A * (b1 - s[1]), -21.0f, 21.0f);
    b2 = le_ms2_clamp(v2, LE_MS2_BUF_LO, LE_MS2_BUF_HI);
    w = he * b2 + F;
  }
  s[3] = le_ms2_ota_secant(LE_MS2_KAPPA * (X - b1) + LE_MS2_OTA_OFS);
  s[4] = le_ms2_ota_secant(-LE_MS2_KAPPA * b2 + 0.01f);
  s[5] = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
  /* the capacitors: q1 = u - X - v1's low-pass state, q2 = b1 - v2's */
  const float q1 = u - v1, q2 = b1 - v2;
  s[0] = 2.0f * q1 - s[0];
  s[1] = 2.0f * q2 - s[1];
  s[2] = 2.0f * (b2 - w) - s[2];
  return w / LE_MS2_GI;
}

/* ---- DFM ---- */

/* The DFM's loop: y (1 - a) + (a/3) y^3 = S within |y| <= 1, y - a
 * sign(y) 2/3 = S beyond. The root nearest the last output, so a loop
 * gain past 1 holds its state. */
static float dfm_solve(float S, float a, float prev) {
  float best = 0.0f, dist = INFINITY;
  /* beyond the clip */
  const float hi = S + a * (2.0f / 3.0f), lo = S - a * (2.0f / 3.0f);
  if (hi >= 1.0f && fabsf(hi - prev) < dist) {
    best = hi;
    dist = fabsf(hi - prev);
  }
  if (lo <= -1.0f && fabsf(lo - prev) < dist) {
    best = lo;
    dist = fabsf(lo - prev);
  }
  /* within: y^3 + p y + q = 0 */
  if (a < 1e-6f) {
    const float y = S;
    if (fabsf(y) <= 1.0f && fabsf(y - prev) < dist) return y;
    return dist < INFINITY ? best : mf_clamp(y, -1.0f, 1.0f);
  }
  const double p = 3.0 * (1.0 - a) / a, q = -3.0 * S / a;
  const double disc = q * q / 4.0 + p * p * p / 27.0;
  double roots[3];
  int n = 0;
  if (disc >= 0.0) {
    const double sd = sqrt(disc);
    roots[n++] = cbrt(-q / 2.0 + sd) + cbrt(-q / 2.0 - sd);
  } else {
    const double r = sqrt(-p / 3.0);
    const double phi = acos(fmax(-1.0, fmin(1.0, 3.0 * q / (2.0 * p * r))));
    for (int k = 0; k < 3; ++k) roots[n++] = 2.0 * r * cos((phi - 2.0 * 3.14159265358979 * k) / 3.0);
  }
  for (int i = 0; i < n; ++i) {
    const float y = (float)roots[i];
    if (fabsf(y) <= 1.0f && fabsf(y - prev) < dist) {
      best = y;
      dist = fabsf(y - prev);
    }
  }
  return dist < INFINITY ? best : mf_clamp(S, -1.0f, 1.0f);
}

static float dfm_phi(float v) {
  v = mf_clamp(v, -1.0f, 1.0f);
  return v - v * v * v / 3.0f;
}

/* ---- Filther ---- */

/* The input stage: an RC low-pass (1 kOhm, 33 nF) across an antiparallel
 * diode pair, trapezoidal, solved by Newton. */
#define MF_DIODE_R 1000.0
#define MF_DIODE_C 33e-9
#define MF_DIODE_IS 1e-15
#define MF_DIODE_VT 0.025
static double diode_current(double x, double v) {
  return (x - v) / MF_DIODE_R - 2.0 * MF_DIODE_IS * sinh(v / MF_DIODE_VT);
}

static float filther_diode(le_meld_filter* f, float xin) {
  const double a = 0.5 / ((double)f->rate * MF_DIODE_C);
  const double vp = f->s.filther.v, fp = f->s.filther.x1;
  double v = vp;
  for (int it = 0; it < 9; ++it) {
    const double F = v - vp - a * (diode_current(xin, v) + fp);
    const double dF =
        1.0 + a * (1.0 / MF_DIODE_R + 2.0 * MF_DIODE_IS / MF_DIODE_VT * cosh(v / MF_DIODE_VT));
    const double step = F / dF;
    v -= step;
    if (v > 0.7626) v = 0.7626;
    if (v < -0.7626) v = -0.7626;
    if (fabs(step) < 1e-6 + 1e-3 * fabs(v)) break;
  }
  f->s.filther.v = (float)v;
  f->s.filther.x1 = (float)diode_current(xin, v);
  return (float)v;
}

/* ---- Vowel ---- */

/* Segno's vowels, A E I O U: the first four formants of a bass voice
 * (Hz) and the levels of formants 2..5 relative to the first (dB), from
 * the published averages Csound documents; the fifth formant sits at
 * 4950 Hz for every vowel. */
static const float kVowelHz[5][4] = {
    {600, 1040, 2250, 2450}, {400, 1620, 2400, 2800}, {250, 1750, 2600, 3050},
    {400, 750, 2400, 2600},  {350, 600, 2400, 2675},
};
static const float kVowelDb[5][4] = {
    {-7, -9, -9, -20}, {-12, -9, -12, -18}, {-30, -16, -22, -28},
    {-11, -21, -20, -40}, {-20, -32, -28, -36},
};

/* ---- the modal banks ---- */

/* The membrane's mode ratios: the zeros of the Bessel functions J_m over
 * the first zero of J_0, sorted. Computed once. */
static float g_membrane[LE_MELD_MODES];
static int g_membrane_built;

static double mf_jm(int m, double x) {
  double term = 1.0;
  for (int i = 1; i <= m; ++i) term *= 0.5 * x / (double)i;
  double sum = term;
  const double q = -0.25 * x * x;
  for (int k = 1; k < 80; ++k) {
    term *= q / ((double)k * (double)(k + m));
    sum += term;
    if (fabs(term) < 1e-17 * fabs(sum) && k > 10) break;
  }
  return sum;
}

static void membrane_build(void) {
  if (g_membrane_built) return;
  double zeros[256];
  int n = 0;
  for (int m = 0; m < 24 && n < 250; ++m) {
    double prev = mf_jm(m, 0.5 + (double)m);
    for (double x = 0.5 + (double)m + 0.01; x < 22.0 && n < 250; x += 0.01) {
      const double y = mf_jm(m, x);
      if ((prev < 0.0) != (y < 0.0)) {
        double lo = x - 0.01, hi = x;
        for (int it = 0; it < 50; ++it) {
          const double mid = 0.5 * (lo + hi);
          if ((mf_jm(m, lo) < 0.0) != (mf_jm(m, mid) < 0.0)) hi = mid;
          else lo = mid;
        }
        zeros[n++] = 0.5 * (lo + hi);
      }
      prev = y;
    }
  }
  for (int i = 1; i < n; ++i) {
    const double z = zeros[i];
    int j = i - 1;
    while (j >= 0 && zeros[j] > z) {
      zeros[j + 1] = zeros[j];
      j--;
    }
    zeros[j + 1] = z;
  }
  for (int i = 0; i < LE_MELD_MODES; ++i) g_membrane[i] = (float)(zeros[i] / zeros[0]);
  g_membrane_built = 1;
}

/* The plate's mode n on a 6-wide grid for aspect a. */
static float plate_ratio(int n, float a) {
  const int i = n / 6 + 1, j = n - 6 * (i - 1);
  return sqrtf((float)(j * j) + ((float)i / a) * ((float)i / a)) / sqrtf(1.0f + 1.0f / (a * a));
}

static void modal_coefs(le_meld_filter* f) {
  const float rate = f->rate;
  const float m1 = f->m1, m2 = f->m2;
  const int plate = f->type == LE_MELD_FILTER_PLATE;
  const float T = 0.45f * (0.1f + 19.9f * m1 * m1 * m1);
  const float d = plate ? 0.7f : m2;
  const float a = 1.0f - 0.9f * m2;
  for (int n = 0; n < LE_MELD_MODES; ++n) {
    const float fn = f->hz * (plate ? plate_ratio(n, a) : g_membrane[n]);
    if (fn <= 0.0f || fn >= 0.5f * rate) {
      f->s.modal.g[n] = 0.0f;
      continue;
    }
    f->s.modal.g[n] = mf_tan(fn, rate);
    f->s.modal.k[n] = 1.0f / (T * ((1.0f - d) * fn + 100.0f * d));
  }
}

/* ---- the interface ---- */

void le_meld_filter_init(le_meld_filter* f, float rate) {
  memset(f, 0, sizeof(*f));
  membrane_build();
  f->rate = rate;
  f->glide = expf(-1.0f / (0.005f * rate));
  f->hz = 20000.0f;
  le_meld_filter_set_type(f, LE_MELD_FILTER_SVF12);
}

void le_meld_filter_reset(le_meld_filter* f) {
  memset(&f->s, 0, sizeof(f->s));
  if (f->type == LE_MELD_FILTER_LOWPASS) f->s.ms2.s[6] = 1.0f; /* the second OTA's gain */
  if (f->type == LE_MELD_FILTER_HIGHPASS) f->s.ms2.s[3] = f->s.ms2.s[4] = 1.0f;
  f->gin = f->gin_to;
  f->gout = f->gout_to;
  for (int i = 0; i < 3; ++i) f->w[i] = f->w_to[i];
  le_meld_filter_set(f, f->hz, f->m1, f->m2);
  f->gin = f->gin_to;
  f->gout = f->gout_to;
  for (int i = 0; i < 3; ++i) f->w[i] = f->w_to[i];
  if (f->type == LE_MELD_FILTER_VOWEL) {
    for (int i = 0; i < LE_MELD_FORMANTS; ++i) f->s.vowel.amp[i] = f->s.vowel.amp_to[i];
  }
  if (f->type == LE_MELD_FILTER_PHASER) f->s.phaser.k = f->s.phaser.k_to;
}

void le_meld_filter_snap(le_meld_filter* f) {
  f->gin = f->gin_to;
  f->gout = f->gout_to;
  for (int i = 0; i < 3; ++i) f->w[i] = f->w_to[i];
  if (f->type == LE_MELD_FILTER_VOWEL) {
    for (int i = 0; i < LE_MELD_FORMANTS; ++i) f->s.vowel.amp[i] = f->s.vowel.amp_to[i];
  }
  if (f->type == LE_MELD_FILTER_PHASER) f->s.phaser.k = f->s.phaser.k_to;
}

void le_meld_filter_set_type(le_meld_filter* f, int32_t type) {
  if (type < 0 || type >= LE_MELD_FILTER_TYPES) type = LE_MELD_FILTER_SVF12;
  f->type = type;
  le_meld_filter_reset(f);
}

void le_meld_filter_set(le_meld_filter* f, float hz, float m1, float m2) {
  const float rate = f->rate;
  f->hz = hz = mf_clamp(hz, 20.0f, 20480.0f);
  f->m1 = m1 = mf_clamp(m1, 0.0f, 1.0f);
  f->m2 = m2 = mf_clamp(m2, 0.0f, 1.0f);
  f->g = mf_tan(fminf(hz, 0.49f * rate), rate);
  mf_q(m1, &f->k1, &f->k2);
  f->gin_to = f->gout_to = 1.0f;
  svf_weights(0.0f, f->w_to);
  switch (f->type) {
    case LE_MELD_FILTER_SVF12:
    case LE_MELD_FILTER_SVF24:
      svf_weights(m2, f->w_to);
      break;
    case LE_MELD_FILTER_LOWPASS:
    case LE_MELD_FILTER_HIGHPASS: {
      /* drive: -18 dB in at 0 to +24 at 1, made up by 18 dB falling to 0 at
       * 0.7 */
      f->gin_to = mf_db(42.0f * m2 - 18.0f);
      f->gout_to = mf_db(18.0f * (1.0f - fminf(m2 / 0.7f, 1.0f)));
      const float r = 0.993f * m1;
      {
        const le_ms2_coef c =
            le_ms2_coefs(tanf(fminf(MF_PI * fmaxf(hz, 1.0f) / rate, 1.54f)), rate);
        f->s.ms2.c_g = c.g;
        f->s.ms2.c_he = c.he;
        f->s.ms2.c_c1 = c.c1;
        f->s.ms2.c_inv1g = c.inv1g;
        f->s.ms2.kfb = LE_MS2_FEEDBACK * le_ms2_q(r, hz, rate);
      }
      break;
    }
    case LE_MELD_FILTER_BANDPASS: {
      /* osr_section.h's circuit at its band tap */
      f->gin_to = mf_db(24.0f * m2);
      const float q = le_ms2_q(0.99f * m1, hz, rate);
      f->s.osr.g = LE_OSR_G * tanf(fminf(MF_PI * fmaxf(hz, 1.0f) / rate, 1.54f));
      f->s.osr.k = 2.0f * (1.0f - q) - 0.01f;
      break;
    }
    case LE_MELD_FILTER_DFM: {
      f->gin_to = mf_db(24.0f * m2);
      const float R = 0.99f * m1;
      const float t = tanf(fminf(MF_PI * hz / rate, 1.56765f));
      const float sq = 1.81659f; /* sqrt of the capacitor ratio 3.3 */
      f->s.dfm.g1 = mf_clamp((t / sq) / (1.0f + t / sq), 1e-5f, 0.998f);
      f->s.dfm.g2 = mf_clamp((t * sq) / (1.0f + t * sq), 1e-5f, 0.998f);
      f->s.dfm.kfb =
          1.30303f * fmaxf(0.001f, R / (1.0f + 3.0f * (R - 1.0f) * fmaxf(hz / rate - 0.075f, 0.0f)));
      break;
    }
    case LE_MELD_FILTER_FILTHER:
      f->gin_to = mf_db(-15.0f + 18.0f * m2);
      f->gout_to = mf_db(24.0f - 14.0f * m2);
      f->s.filther.g_bw = mf_tan(42455.5f / (2.0f * MF_PI), rate);
      break;
    case LE_MELD_FILTER_SRF: {
      /* the switched-resistor filter at twice the rate: its integrators
       * conduct at a fixed 21.5 kHz gain for the share of each clock
       * period that gives the cutoff; Lofi lowers the clock from 41 kHz
       * to 160 Hz */
      const float r2 = 2.0f * rate;
      f->s.srf.g_on = tanf(MF_PI * 21500.0f / r2);
      const float g = tanf(MF_PI * fminf(hz, 21000.0f) / r2);
      f->s.srf.duty = mf_clamp(g / f->s.srf.g_on, 0.0f, 0.9999f);
      const float clk = mf_clamp(160.0f * exp2f(8.0f * (1.0f - m2)), 160.0f, 40960.0f);
      f->s.srf.dclk = clk / r2;
      break;
    }
    case LE_MELD_FILTER_EQ_PEAK: {
      /* a bell of up to 24 dB, Q 0.4 .. 18, wide boosts trimmed */
      const float A = mf_db(24.0f * m1);
      const float q = 0.4f + 17.6f * m2 * m2 * m2;
      f->k1 = 1.0f / (q * fminf(A, 1.0f));
      f->k2 = A;
      f->gout_to = mf_db((1.0f - 0.8f * m2) * (-12.0f * m1));
      break;
    }
    case LE_MELD_FILTER_EQ_NOTCH: {
      /* a cut of up to 24 dB, Q 2 .. 24, its width scaling with depth */
      const float A = mf_db(-24.0f * m1);
      const float q = 2.0f + 22.0f * m2;
      f->k1 = 1.0f / (q * A);
      f->k2 = A;
      f->gout_to = mf_db((1.0f - 0.5f * m2) * (6.0f * m1));
      break;
    }
    case LE_MELD_FILTER_PHASER: {
      float q = m2 < 0.5f ? 2.0f - 3.0f * m2 : 0.5f - 0.45f * (2.0f * m2 - 1.0f);
      q = fmaxf(q, 0.01f);
      f->s.phaser.k_to = 1.0f / q;
      f->s.phaser.fb = 0.98f * m1;
      break;
    }
    case LE_MELD_FILTER_REDUX: {
      const int bits = (int)(8.0f - 7.0f * m1);
      f->s.redux.levels = (float)(1 << (bits - 1));
      break;
    }
    case LE_MELD_FILTER_PLATE:
    case LE_MELD_FILTER_MEMBRANE:
      if (hz != f->s.modal.set_hz || m1 != f->s.modal.set_m1 || m2 != f->s.modal.set_m2) {
        f->s.modal.set_hz = hz;
        f->s.modal.set_m1 = m1;
        f->s.modal.set_m2 = m2;
        modal_coefs(f);
      }
      break;
    case LE_MELD_FILTER_VOWEL: {
      const float t = mf_clamp(log2f(hz / 20.0f) / 10.0f, 0.0f, 1.0f);
      const float shift = exp2f(4.0f * t - 2.0f);
      const float p = 4.0f * m2;
      int a = (int)p;
      if (a > 3) a = 3;
      const float fr = p - (float)a;
      f->s.vowel.k = 1.0f / (5.0f + 15.0f * m1);
      for (int i = 0; i < LE_MELD_FORMANTS; ++i) {
        const float fz = i < 4 ? (1.0f - fr) * kVowelHz[a][i] + fr * kVowelHz[a + 1][i] : 4950.0f;
        f->s.vowel.g[i] = mf_tan(fminf(fz * shift, 0.49f * rate), rate);
        /* the first formant at -10 dB, the others their level - 10 */
        const float db = i == 0 ? 0.0f : (1.0f - fr) * kVowelDb[a][i - 1] + fr * kVowelDb[a + 1][i - 1];
        f->s.vowel.amp_to[i] = mf_db(db - 10.0f);
      }
      break;
    }
    case LE_MELD_FILTER_COMB:
    case LE_MELD_FILTER_COMB_INVERTED: {
      const float c = f->type == LE_MELD_FILTER_COMB ? 1.0f : 0.5f;
      const float pol = f->type == LE_MELD_FILTER_COMB ? 1.0f : -1.0f;
            /* fit: the loop is c rate / f samples round (the comb renders) */
      f->s.comb.delay = mf_clamp(c * rate / hz, 2.0f, (float)(LE_MELD_COMB_LEN - 4));
      /* decays 60 dB in T seconds at any pitch */
      const float T = 0.001f + 14.999f * m1 * m1 * m1 * m1;
      f->s.comb.fb = pol * powf(0.001f, c / (T * hz));
      float fc;
      if (m2 < 0.5f) {
        fc = 500.0f + 3500.0f * powf(2.0f * m2, 3.3f);
        f->s.comb.damp_a = 0.5f + m2;
        f->s.comb.damp_b = 0.5f - m2;
      } else {
        const float u = 2.0f * (m2 - 0.5f);
        fc = 100.0f + 900.0f * powf(u, 3.3f);
        f->s.comb.damp_a = 1.0f;
        f->s.comb.damp_b = -0.3f * u;
      }
      f->s.comb.damp_g = mf_tan(fc, rate);
      break;
    }
    default:
      break;
  }
}

float le_meld_filter_tick(le_meld_filter* f, float x) {
  const float gl = f->glide;
  f->gin = f->gin_to + gl * (f->gin - f->gin_to);
  f->gout = f->gout_to + gl * (f->gout - f->gout_to);
  switch (f->type) {
    case LE_MELD_FILTER_SVF12:
    case LE_MELD_FILTER_SVF24: {
      for (int i = 0; i < 3; ++i) f->w[i] = f->w_to[i] + gl * (f->w[i] - f->w_to[i]);
      float y = svf_stage(&f->s.svf.a, x, f->g, f->k1, f->w);
      if (f->type == LE_MELD_FILTER_SVF24) y = svf_stage(&f->s.svf.b, y, f->g, f->k2, f->w);
      return y;
    }
    case LE_MELD_FILTER_LOWPASS: {
      const le_ms2_coef c = {f->s.ms2.c_g, f->s.ms2.c_he, f->s.ms2.c_c1, f->s.ms2.c_inv1g};
      return f->gout * meld_ms2_section(f->s.ms2.s, f->gin * x, &c, f->s.ms2.kfb);
    }
    case LE_MELD_FILTER_HIGHPASS: {
      const le_ms2_coef c = {f->s.ms2.c_g, f->s.ms2.c_he, f->s.ms2.c_c1, f->s.ms2.c_inv1g};
      return f->gout * meld_ms2_hp_section(f->s.ms2.s, f->gin * x, &c, f->s.ms2.kfb);
    }
    case LE_MELD_FILTER_BANDPASS: {
      float o[3];
      le_osr_tick(f->s.osr.st, le_osr_input(LE_OSR_IN * f->gin * x), f->s.osr.g, f->s.osr.k, o);
      /* fit: the band tap leaves at 0.55 (the Bandpass render's level) */
      return 0.55f * o[1] / LE_OSR_IN;
    }
    case LE_MELD_FILTER_PHASER: {
      float* k = &f->s.phaser.k;
      *k = f->s.phaser.k_to + gl * (*k - f->s.phaser.k_to);
      /* the chain is linear in its input: y6 = A u + B, solved with the
       * negative feedback u = x - fb y6 */
      const float g = f->g, kk = *k;
      const float h = 1.0f / (1.0f + g * (g + kk));
      const float a = 1.0f - 2.0f * kk * g * h;
      float A = 1.0f, B = 0.0f;
      for (int i = 0; i < 6; ++i) {
        const le_meld_svf_state* s = &f->s.phaser.stage[i];
        const float b = -2.0f * kk * h * (s->s1 - g * s->s2);
        A *= a;
        B = a * B + b;
      }
      const float u = (x - f->s.phaser.fb * B) / (1.0f + f->s.phaser.fb * A);
      float y = u;
      for (int i = 0; i < 6; ++i) {
        float bp = 0.0f;
        (void)le_meld_svf(&f->s.phaser.stage[i], y, g, kk, &bp, NULL);
        y = y - 2.0f * kk * bp;
      }
      return u - y;
    }
    case LE_MELD_FILTER_REDUX: {
      /* a new sample at the Frequency's rate, crushed; read back cubic,
       * crossfaded to the held sample by Lofi */
      float* hs = f->s.redux.hist;
      f->s.redux.ph += (double)(fminf(f->hz, f->rate - 1.0f) / f->rate);
      if (f->s.redux.ph >= 1.0) {
        f->s.redux.ph -= 1.0;
        const float L = f->s.redux.levels;
        const float q = roundf(mf_clamp(x * L, -L, L - 1.0f)) / L;
        hs[0] = hs[1];
        hs[1] = hs[2];
        hs[2] = hs[3];
        hs[3] = q;
      }
      const float t = (float)f->s.redux.ph;
      const float c1 = 0.5f * (hs[2] - hs[0]);
      const float c2 = hs[0] - 2.5f * hs[1] + 2.0f * hs[2] - 0.5f * hs[3];
      const float c3 = 0.5f * (hs[3] - hs[0]) + 1.5f * (hs[1] - hs[2]);
      const float cubic = ((c3 * t + c2) * t + c1) * t + hs[1];
      const float y = (1.0f - f->m2) * cubic + f->m2 * hs[3];
      const float r = 1.0f - 2.0f * MF_PI * 5.0f / f->rate;
      const float out = y - f->s.redux.dc_x + r * f->s.redux.dc_y;
      f->s.redux.dc_x = y;
      f->s.redux.dc_y = out;
      return out;
    }
    case LE_MELD_FILTER_PLATE:
    case LE_MELD_FILTER_MEMBRANE: {
      float y = 0.0f;
      for (int n = 0; n < LE_MELD_MODES; ++n) {
        if (f->s.modal.g[n] <= 0.0f) continue;
        float bp = 0.0f;
        (void)le_meld_svf(&f->s.modal.mode[n], x, f->s.modal.g[n], f->s.modal.k[n], &bp, NULL);
        y += bp;
      }
      return 0.0125f * y;
    }
    case LE_MELD_FILTER_SRF: {
      const float gp = tanf(MF_PI * 20500.0f / (2.0f * f->rate));
      float y = 0.0f;
      for (int i = 0; i < 2; ++i) {
        /* the input held across both sub-samples, band-limited */
        const float u = le_meld_svf(&f->s.srf.pre, i == 0 ? 0.5f * (x + f->s.srf.last) : x, gp,
                                    1.41421356f, NULL, NULL);
        /* the share of this sub-sample the clock is on: the pulse's
         * integral over [phase, phase + dclk) */
        const double p0 = f->s.srf.clock, dp = f->s.srf.dclk, D = f->s.srf.duty;
        double on = 0.0, a = p0, left = dp;
        while (left > 1e-12) {
          const double cyc = a - floor(a);
          const double step = fmin(left, 1.0 - cyc);
          const double lo = cyc, hi = cyc + step;
          on += fmax(0.0, fmin(hi, D) - lo);
          a += step;
          left -= step;
        }
        f->s.srf.clock = p0 + dp - floor(p0 + dp);
        const float geff = f->s.srf.g_on * (float)(on / dp);
        const float lp = le_meld_svf(&f->s.srf.core, u, geff, f->k1, NULL, NULL);
        y += 0.5f * le_meld_svf(&f->s.srf.post, lp, gp, 1.41421356f, NULL, NULL);
      }
      f->s.srf.last = x;
      return y;
    }
    case LE_MELD_FILTER_DFM: {
      const float u = (2.0f / 3.0f) * f->gin * x;
      const float g1 = f->s.dfm.g1, g2 = f->s.dfm.g2;
      const float s1 = f->s.dfm.s1, s2 = f->s.dfm.s2;
      const float S = s2 + g2 * (s1 + g1 * (u - s1) - s2);
      const float a = f->s.dfm.kfb * g2 * (1.0f - g1);
      const float y = dfm_solve(S, a, f->s.dfm.y);
      const float F = f->s.dfm.kfb * dfm_phi(y);
      const float y1 = s1 + g1 * ((u - F) - s1);
      f->s.dfm.s1 = 2.0f * y1 - s1;
      f->s.dfm.s2 = 2.0f * y - s2;
      f->s.dfm.y = y;
      return 1.5f * dfm_phi(y);
    }
    case LE_MELD_FILTER_FILTHER: {
      const float v = filther_diode(f, f->gin * x);
      float lp = le_meld_svf(&f->s.filther.lp, v, f->g, f->k1, NULL, NULL) * f->gin;
      lp = le_meld_svf(&f->s.filther.bw, lp, f->s.filther.g_bw, 1.41421356f, NULL, NULL);
      const float sat = 0.25f * sinf(0.5f * MF_PI * mf_clamp(4.0f * lp + 0.1f, -1.0f, 1.0f));
      /* the 5 Hz DC blocker takes the bias back out */
      const float r = 1.0f - 2.0f * MF_PI * 5.0f / f->rate;
      const float y = sat - f->s.filther.dc_x + r * f->s.filther.dc_y;
      f->s.filther.dc_x = sat;
      f->s.filther.dc_y = y;
      return f->gout * y;
    }
    case LE_MELD_FILTER_EQ_PEAK:
    case LE_MELD_FILTER_EQ_NOTCH: {
      float bp = 0.0f;
      (void)le_meld_svf(&f->s.svf.a, x, f->g, f->k1, &bp, NULL);
      return f->gout * (x + (f->k2 - 1.0f) * f->k1 * bp);
    }
    case LE_MELD_FILTER_VOWEL: {
      float y = 0.0f;
      for (int i = 0; i < LE_MELD_FORMANTS; ++i) {
        float* amp = &f->s.vowel.amp[i];
        *amp = f->s.vowel.amp_to[i] + gl * (*amp - f->s.vowel.amp_to[i]);
        float bp = 0.0f;
        (void)le_meld_svf(&f->s.vowel.band[i], x, f->s.vowel.g[i], f->s.vowel.k, &bp, NULL);
        y += *amp * bp;
      }
      return 1.7f * y;
    }
    case LE_MELD_FILTER_COMB:
    case LE_MELD_FILTER_COMB_INVERTED: {
      float* buf = f->s.comb.buf;
      const int32_t n = LE_MELD_COMB_LEN;
      const float pos = (float)f->s.comb.w - f->s.comb.delay;
      const float fl = floorf(pos);
      const float t = pos - fl;
      int32_t i = (int32_t)fl;
      i = ((i % n) + n) % n;
      const float h0 = buf[(i + n - 1) % n], h1 = buf[i], h2 = buf[(i + 1) % n],
                  h3 = buf[(i + 2) % n];
      const float c1 = 0.5f * (h2 - h0);
      const float c2 = h0 - 2.5f * h1 + 2.0f * h2 - 0.5f * h3;
      const float c3 = 0.5f * (h3 - h0) + 1.5f * (h1 - h2);
      const float d = ((c3 * t + c2) * t + c1) * t + h1;
      const float damped =
          f->s.comb.damp_a * d + f->s.comb.damp_b * mf_onepole(&f->s.comb.damp_s, d, f->s.comb.damp_g);
      buf[f->s.comb.w] = x + f->s.comb.fb * damped;
      f->s.comb.w = (f->s.comb.w + 1) % n;
      const float pol = f->type == LE_MELD_FILTER_COMB ? 1.0f : -1.0f;
      return 0.5f * (x + pol * d);
    }
    default:
      return x;
  }
}
