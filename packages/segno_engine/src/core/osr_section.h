/*
 * osr_section.h — Segno's model of a state-variable circuit (the one
 * Operator's OSR filter and Meld's Bandpass use, SEG-109).
 *
 * A two-integrator loop whose transconductances both saturate (on the node
 * voltages scaled by 0.19 per volt), damped by 2 (1 - q) - 0.01 and by a
 * diode across the band node that conducts above a knee: so from about
 * resonance 1 the loop rings at the level where the diode's damping makes
 * up the negative linear damping. The input passes an op-amp stage that
 * saturates softly. Linearised at the last estimate and solved in closed
 * form, twice per sample; one core gives the low, band and high outputs.
 * Levels are in the circuit's volts: the signal enters at x LE_OSR_IN.
 *
 * Header-only and static inline: each device's translation unit gets its
 * own copy, so the two never share state.
 */
#ifndef SEGNO_OSR_SECTION_H
#define SEGNO_OSR_SECTION_H

#include <math.h>

#define LE_OSR_IN 2.59076f    /* the signal into the circuit, in volts */
#define LE_OSR_G 1.00934f     /* the cutoff calibration */
#define LE_OSR_VK 0.5f        /* fit: the diode's knee, volts */
#define LE_OSR_DK 1.0f        /* fit: its conductance above the knee */
#define LE_OSR_KAPPA 0.1915f
#define LE_OSR_RAIL 20.0f     /* fit: the input stage saturates far above
                               * the 5 V rails the reading names */
#define LE_OSR_STATES 5

static inline float le_osr_clamp(float x, float lo, float hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

static inline float le_osr_input(float u) { return LE_OSR_RAIL * tanhf(u / LE_OSR_RAIL); }

static inline float le_osr_ota_secant(float v) {
  const float z = le_osr_clamp(LE_OSR_KAPPA * v, -2.0f, 2.0f);
  const float az = fabsf(z);
  return 1.0f - 0.25f * z * z + 0.0625f * az * az * az;
}

static inline float le_osr_diode_secant(float v) {
  const float a = fabsf(v);
  return a <= LE_OSR_VK ? 0.0f : LE_OSR_DK * (a - LE_OSR_VK) / a;
}

/* One core: st[0], st[1] the integrators, st[2..4] the last secants (the
 * two transconductances and the diode). Writes high, band and low to
 * o[0..2]. */
static inline void le_osr_tick(float* st, float u, float g, float k, float* o) {
  float s1 = st[2], s2 = st[3], sd = st[4];
  float vh = 0.0f, vb = 0.0f, vl = 0.0f;
  for (int pass = 0; pass < 2; ++pass) {
    const float g1 = g * s1, g2 = g * s2, kk = k + sd;
    vh = (u - (kk + g2) * st[0] - st[1]) / (1.0f + kk * g1 + g1 * g2);
    vh = le_osr_clamp(vh, -5.2f * LE_OSR_IN, 5.2f * LE_OSR_IN);
    vb = g1 * vh + st[0];
    vl = g2 * vb + st[1];
    s1 = le_osr_ota_secant(vh);
    s2 = le_osr_ota_secant(vb);
    sd = le_osr_diode_secant(vb);
  }
  st[2] = s1;
  st[3] = s2;
  st[4] = sd;
  st[0] = 2.0f * vb - st[0];
  st[1] = 2.0f * vl - st[1];
  o[0] = vh;
  o[1] = vb;
  o[2] = vl;
}

#endif /* SEGNO_OSR_SECTION_H */
