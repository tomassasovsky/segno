/*
 * restore_halfband.c — 2:1 half-band decimate/interpolate (#697 S8).
 *
 * Contract: restore_halfband.h. The kernel is a 63-tap Blackman-windowed
 * ideal half-band lowpass (cutoff fs/4), DC-normalized to exactly unit gain;
 * the outermost tap pair lands on the window's zeros, leaving 61 effective
 * taps. Half-band symmetry makes every even-offset tap exactly zero, so the
 * kernel is stored as its center value plus the 15 positive odd-offset taps
 * (the filter is symmetric). Offline-only code: the convolutions below run
 * the full tap list per output sample for clarity, not speed.
 */
#include <stddef.h>

#include "restore_halfband.h"

/* Center tap and positive odd-offset taps (offsets 1, 3, ..., 29), Blackman
 * window, DC gain normalized to 1.0 exactly (hence center != 0.5 in the last
 * digits). Regenerate by re-windowing sin(pi m / 2) / (pi m) if the length
 * ever changes. */
#define LE_HB_NODD 15
static const float le_hb_center = 5.000002944e-01f;
static const float le_hb_odd[LE_HB_NODD] = {
    3.169722345e-01f,  -1.021489604e-01f, 5.726337293e-02f,
    -3.690092669e-02f, 2.496968478e-02f,  -1.710854712e-02f,
    1.163982900e-02f,  -7.761143136e-03f, 5.017221556e-03f,
    -3.110169595e-03f, 1.823256800e-03f,  -9.890393174e-04f,
    4.762262428e-04f,  -1.843657572e-04f, 4.117894336e-05f,
};

/* x[t] with zero padding outside [0, n). */
static float le_hb_at(const float* x, uint32_t n, int64_t t) {
  if (t < 0 || t >= (int64_t)n) return 0.0f;
  return x[t];
}

/* Zero-stuffed upsample of x read at rate-2 index t (length 2n virtual). */
static float le_hb_up_at(const float* x, uint32_t n, int64_t t) {
  if (t < 0 || t >= 2 * (int64_t)n || (t & 1)) return 0.0f;
  return x[t >> 1];
}

int32_t le_halfband_decimate(const float* x, uint32_t n, float* y) {
  uint32_t out_len;
  uint32_t i;
  if (x == NULL || y == NULL || n == 0) return -1;
  /* (n + 1) / 2 without the n == UINT32_MAX wrap; reject lengths whose
   * output count cannot ride the int32 return (header contract). */
  out_len = n / 2 + (n & 1u);
  if (out_len > (uint32_t)INT32_MAX) return -1;
  for (i = 0; i < out_len; ++i) {
    const int64_t t = 2 * (int64_t)i;
    double acc = (double)le_hb_center * (double)le_hb_at(x, n, t);
    int j;
    for (j = 0; j < LE_HB_NODD; ++j) {
      const int64_t d = 2 * (int64_t)j + 1;
      acc += (double)le_hb_odd[j] *
             ((double)le_hb_at(x, n, t - d) + (double)le_hb_at(x, n, t + d));
    }
    y[i] = (float)acc;
  }
  return (int32_t)out_len;
}

int32_t le_halfband_interpolate(const float* x, uint32_t n, float* y) {
  uint32_t i;
  /* 2 * n must fit the int32 return (header contract) — and the guard also
   * keeps the uint32 loop bound below from wrapping. Rejected before y is
   * written. */
  if (x == NULL || y == NULL || n == 0 || n > (uint32_t)INT32_MAX / 2u) {
    return -1;
  }
  for (i = 0; i < 2 * n; ++i) {
    const int64_t t = (int64_t)i;
    double acc = (double)le_hb_center * (double)le_hb_up_at(x, n, t);
    int j;
    for (j = 0; j < LE_HB_NODD; ++j) {
      const int64_t d = 2 * (int64_t)j + 1;
      acc += (double)le_hb_odd[j] * ((double)le_hb_up_at(x, n, t - d) +
                                     (double)le_hb_up_at(x, n, t + d));
    }
    y[i] = 2.0f * (float)acc; /* restore unit passband gain after stuffing */
  }
  return (int32_t)(2 * n);
}
