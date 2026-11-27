/*
 * ms2_section.h — one section of Segno's MS-20 low-pass model, shared by
 * Drift's filter II and Operator's MS2 circuit (SEG-109).
 *
 * A Sallen-Key model of the later MS-20 low-pass circuit (Segno's own model
 * of it, from a reading of Live's): a DC-blocked input drives a first
 * integrator through a transconductance that saturates; its capacitor's
 * lower plate is the feedback node X; a unity buffer follows each of the two
 * integrators and clips; the second buffer's output, DC-blocked, is the
 * section's output w, and the resonance feeds it back through a diode-like
 * curve to X. Small-signal Q is 1 / (2 - k) for a loop gain k, unity DC gain
 * at every resonance. The two nonlinear elements are linearised at the last
 * estimate and the loop solved in closed form, twice per sample. Levels are
 * in the circuit's volts: the signal enters at x 2.69 and leaves at 1/2.69.
 *
 * Header-only and static inline: each device's translation unit gets its
 * own copy, so the two never share state.
 */
#ifndef SEGNO_MS2_SECTION_H
#define SEGNO_MS2_SECTION_H

#include <math.h>

#define LE_MS2_GI 2.69154f     /* into a section, in circuit volts */
#define LE_MS2_KAPPA 0.4165f   /* the first integrator's input scale, per volt */
#define LE_MS2_OTA_OFS 0.015f  /* its input offset (normalised) */
#define LE_MS2_DIODE_OFS 0.009f
#define LE_MS2_BUF_LO -4.987f  /* the buffers' clip */
#define LE_MS2_BUF_HI 4.806f
#define LE_MS2_X_LIM 5.1f
#define LE_MS2_FEEDBACK 0.91351f /* the loop gain per unit of q */
#define LE_MS2_STATES 6

static inline float le_ms2_clamp(float x, float lo, float hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

/* The diode curve in the feedback: a slope of 2.21 at 0, a sharp knee near
 * 1, and a slope of 0.62 beyond, slightly larger above 0 than below.
 * Segno's own form, fitted to a description of Live's within 0.04; the
 * slope at 0 sets the small-signal resonance: fitted, Drift's filter II
 * resonant peaks on noise within 0.3 dB of Live's at resonance 0.5 to 1. */
#define LE_MS2_DIODE_SLOPE 2.21f
static inline float le_ms2_diode(float a) {
  const float gm = a >= 0.0f ? 1.0449f : 1.1195f;
  const float u = gm * a;
  return 0.62f * a + 1.59f * a / sqrtf(sqrtf(1.0f + u * u * u * u));
}

/* The first integrator's transconductance z (1 - z^2/4 + |z|^3/16) on its
 * normalised input z (clamped to +-2), saturating at 1: its secant. */
static inline float le_ms2_ota_secant(float z) {
  z = le_ms2_clamp(z, -2.0f, 2.0f);
  const float az = fabsf(z);
  return 1.0f - 0.25f * z * z + 0.0625f * az * az * az;
}

static inline float le_ms2_diode_secant(float a) {
  return fabsf(a) < 1e-4f ? LE_MS2_DIODE_SLOPE : le_ms2_diode(a) / a;
}

/* The per-sample coefficients sections share: g, 1/(1+gh), g/(1+g),
 * 1/(1+g). */
typedef struct le_ms2_coef {
  float g, he, c1, inv1g;
} le_ms2_coef;

/* `tan_w` is the prewarped cutoff, tan(pi fc / rate) (clamped by the
 * caller); `rate` sets the 10 uF / 10 kOhm couplings. */
static inline le_ms2_coef le_ms2_coefs(float tan_w, float rate) {
  le_ms2_coef c;
  c.g = 1.02038f * tan_w;
  c.he = 1.0f / (1.0f + 3.14159265f * 1.5915f / rate);
  c.inv1g = 1.0f / (1.0f + c.g);
  c.c1 = c.g * c.inv1g;
  return c;
}

/* q for resonance r: 4r / (3r + 1), plus 4 (r - 1)^2 above 1, the excess
 * above 1 pulled back as the cutoff nears the top of the range. */
static inline float le_ms2_q(float r, float fc, float rate) {
  float q = 4.0f * r / (3.0f * r + 1.0f);
  if (r > 1.0f) q += 4.0f * (r - 1.0f) * (r - 1.0f);
  const float lim = fminf(10000.0f / rate + 0.25f, 0.5f);
  const float t = 1.0f - fminf(fc / rate, lim) / lim;
  return fminf(q, 1.0f + (fmaxf(q, 1.0f) - 1.0f) * t * t * t);
}

/* One section with loop gain kfb; s holds s[0] the input coupling, s[1] the
 * first integrator, s[2] the second, s[3] the output coupling, and the last
 * sample's secant gains s[4] (the transconductance) and s[5] (the diode). */
static inline float le_ms2_section(float* s, float x, const le_ms2_coef* c, float kfb) {
  const float g = c->g, he = c->he, C1 = c->c1;
  const float u = LE_MS2_GI * x;
  const float vin = (u - s[0]) * he; /* the input coupling's high-pass */
  float L = s[4], T = s[5];
  float X = 0.0f, y1 = 0.0f, y2 = 0.0f, b1 = 0.0f, b2 = 0.0f, w = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    if (pass == 1) {
      L = le_ms2_ota_secant(LE_MS2_KAPPA * (vin - b1) + LE_MS2_OTA_OFS);
      T = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
    }
    /* y1 = A X + B, y2 = C1 y1 + C0, w = he y2 + F, X = P w + Q */
    const float gl = g * L;
    const float A = 1.0f / (1.0f + gl);
    const float B = (gl * (vin + LE_MS2_OTA_OFS / LE_MS2_KAPPA) + s[1]) * A;
    const float C0 = s[2] * c->inv1g;
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
  /* the next sample's first pass starts from this operating point */
  s[4] = le_ms2_ota_secant(LE_MS2_KAPPA * (vin - b1) + LE_MS2_OTA_OFS);
  s[5] = le_ms2_diode_secant(kfb * w + LE_MS2_DIODE_OFS);
  /* trapezoidal state updates */
  s[0] = 2.0f * (u - vin) - s[0];
  s[1] = 2.0f * (y1 - X) - s[1];
  s[2] = 2.0f * y2 - s[2];
  s[3] = 2.0f * (b2 - w) - s[3];
  return w / LE_MS2_GI;
}

#endif /* SEGNO_MS2_SECTION_H */
