/*
 * fx_console_libm.h — the console's tanhf and powf, for bench_fx_equiv
 * (#1755).
 *
 * The console runs glibc 2.41. Its tanhf is CORE-MATH's correctly rounded
 * one, and its powf is not correctly rounded, so other platforms' libms
 * (macOS's, glibc's before 2.41, glibc's x86 build) differ from both by an
 * ulp here and there. The Overdrive's and the Distortion's float filters
 * turn any such difference into a residual near -90 dBFS at their hardest
 * settings (their own rounding noise), so a reference rendered on such a
 * platform is not what the console renders. bench_fx_equiv.sh includes this
 * header (-include) into both libraries it builds, so on every platform
 * both render with the console's arithmetic. On the console itself
 * FX_EQUIV_LIBM=1 leaves it out, and both use the console's own libm.
 *
 * It includes <math.h> first, defines the two functions (whose fallbacks
 * still reach the platform's powf), then maps the names onto them, so the
 * effects island's calls take them.
 */
#ifndef SEGNO_FX_CONSOLE_LIBM_H
#define SEGNO_FX_CONSOLE_LIBM_H

#include <math.h>
#include <stdint.h>
#include <string.h>

/* The console's tanhf: glibc 2.41's, which is CORE-MATH's correctly rounded
 * tanhf (revision b1ecd83, Copyright (c) 2022-2024 Alexei Sibidanov, MIT
 * licence), as glibc has it. Correctly rounded, so it gives the same float
 * on every platform, where a platform's own tanhf (macOS's, glibc's before
 * 2.41) is up to 2.2 ulps off. */
static inline float le_console_tanhf(float x) {
  double z = x;
  uint32_t ux;
  memcpy(&ux, &x, sizeof(ux));
  int e = (ux >> 23) & 0xff;
  if (e == 0xff) {
    if (ux << 9) return x + x; /* x = nan */
    static const float ir[] = {1.0f, -1.0f};
    return ir[ux >> 31]; /* x = +-inf */
  }
  if (e < 115) {
    if (e < 102) {
      if ((ux << 1) == 0) return x;
      return fmaf(-x, fabsf(x), x);
    }
    float x2 = x * x;
    return fmaf(x, -0x1.555556p-2f * x2, x);
  }
  if ((ux << 1) > (0x41102cb3u << 1)) {
    return copysignf(1.0f, x) - copysignf(0x1p-25f, x);
  }
  double z2 = z * z;
  double z4 = z2 * z2;
  double z8 = z4 * z4;
  static const double cn[] = {0x1p+0,                0x1.30877b8b72d33p-3,
                              0x1.694aa09ae9e5ep-8,  0x1.4101377abb729p-14,
                              0x1.e0392b1db0018p-22, 0x1.2533756e546f7p-30,
                              0x1.d62e5abe6ae8ap-41, 0x1.b06be534182dep-54};
  static const double cd[] = {0x1p+0,                0x1.ed99131b0ebeap-2,
                              0x1.0d27ed6c95a69p-5,  0x1.7cbdaca0e9fccp-11,
                              0x1.b4e60b892578ep-18, 0x1.a6f707c5c71abp-26,
                              0x1.35a8b6e2cd94cp-35, 0x1.ca8230677aa01p-47};
  double n0 = cn[0] + z2 * cn[1];
  double n2 = cn[2] + z2 * cn[3];
  double n4 = cn[4] + z2 * cn[5];
  double n6 = cn[6] + z2 * cn[7];
  n0 += z4 * n2;
  n4 += z4 * n6;
  n0 += z8 * n4;
  double d0 = cd[0] + z2 * cd[1];
  double d2 = cd[2] + z2 * cd[3];
  double d4 = cd[4] + z2 * cd[5];
  double d6 = cd[6] + z2 * cd[7];
  d0 += z4 * d2;
  d4 += z4 * d6;
  d0 += z8 * d4;
  double r = z * n0 / d0;
  return r;
}

/* The console's powf, for the Distortion: glibc 2.41's as it builds for
 * aarch64 (sysdeps/ieee754/flt-32/e_powf.c, LGPL-2.1-or-later;
 * TOINT_INTRINSICS: POWF_SCALE 32, round and lround), for a positive
 * normal x. glibc's powf is not correctly rounded, so platforms differ by an
 * ulp here and there. The cases glibc treats apart (x zero, negative,
 * subnormal or not finite, |y log2 x| past 126) go to the platform's powf,
 * which agrees with glibc there. */
/* glibc 2.41's tables for le_console_powf (e_powf_log2_data.c,
 * e_exp2f_data.c), copied here apart from engine_fx.c's so that a slip in
 * either shows. */
static const double LE_CONSOLE_POWF_INVC[16] = {
    0x1.661ec79f8f3bep+0, 0x1.571ed4aaf883dp+0, 0x1.49539f0f010bp+0,
    0x1.3c995b0b80385p+0, 0x1.30d190c8864a5p+0, 0x1.25e227b0b8eap+0,
    0x1.1bb4a4a1a343fp+0, 0x1.12358f08ae5bap+0, 0x1.0953f419900a7p+0,
    0x1p+0,               0x1.e608cfd9a47acp-1, 0x1.ca4b31f026aap-1,
    0x1.b2036576afce6p-1, 0x1.9c2d163a1aa2dp-1, 0x1.886e6037841edp-1,
    0x1.767dcf5534862p-1};
static const double LE_CONSOLE_POWF_LOGC[16] = {
    -0x1.efec65b963019p-2, -0x1.b0b6832d4fca4p-2, -0x1.7418b0a1fb77bp-2,
    -0x1.39de91a6dcf7bp-2, -0x1.01d9bf3f2b631p-2, -0x1.97c1d1b3b7afp-3,
    -0x1.2f9e393af3c9fp-3, -0x1.960cbbf788d5cp-4, -0x1.a6f9db6475fcep-5,
    0x0p+0,                0x1.338ca9f24f53dp-4,  0x1.476a9543891bap-3,
    0x1.e840b4ac4e4d2p-3,  0x1.40645f0c6651cp-2,  0x1.88e9c2c1b9ff8p-2,
    0x1.ce0a44eb17bccp-2};
static const double LE_CONSOLE_POWF_POLY[5] = {
    0x1.27616c9496e0bp-2, -0x1.71969a075c67ap-2, 0x1.ec70a6ca7baddp-2,
    -0x1.7154748bef6c8p-1, 0x1.71547652ab82bp0};
static const uint64_t LE_CONSOLE_EXP2F_TAB[32] = {
    0x3ff0000000000000, 0x3fefd9b0d3158574, 0x3fefb5586cf9890f, 0x3fef9301d0125b51,
    0x3fef72b83c7d517b, 0x3fef54873168b9aa, 0x3fef387a6e756238, 0x3fef1e9df51fdee1,
    0x3fef06fe0a31b715, 0x3feef1a7373aa9cb, 0x3feedea64c123422, 0x3feece086061892d,
    0x3feebfdad5362a27, 0x3feeb42b569d4f82, 0x3feeab07dd485429, 0x3feea47eb03a5585,
    0x3feea09e667f3bcd, 0x3fee9f75e8ec5f74, 0x3feea11473eb0187, 0x3feea589994cce13,
    0x3feeace5422aa0db, 0x3feeb737b0cdc5e5, 0x3feec49182a3f090, 0x3feed503b23e255d,
    0x3feee89f995ad3ad, 0x3feeff76f2fb5e47, 0x3fef199bdd85529c, 0x3fef3720dcef9069,
    0x3fef5818dcfba487, 0x3fef7c97337b9b5f, 0x3fefa4afa2a490da, 0x3fefd0765b6e4540};
static const double LE_CONSOLE_EXP2F_POLY[3] = {
    0x1.c6af84b912394p-5, 0x1.ebfce50fac4f3p-3, 0x1.62e42ff0c52d6p-1};
/* 1 << EXP2F_TABLE_BITS, with TOINT_INTRINSICS */
#define LE_CONSOLE_POWF_SCALE 32.0

static inline float le_console_powf(float x, float y) {
  uint32_t ix;
  memcpy(&ix, &x, sizeof(ix));
  if (ix - 0x00800000u >= 0x7f800000u - 0x00800000u) return powf(x, y);
  /* log2_inline */
  const uint32_t tmp = ix - 0x3f330000u;
  const int i = (int)((tmp >> (23 - 4)) % 16);
  const uint32_t top = tmp & 0xff800000u;
  const uint32_t iz = ix - top;
  const int k = (int32_t)top >> (23 - 5);
  const double invc = LE_CONSOLE_POWF_INVC[i];
  const double logc = LE_CONSOLE_POWF_LOGC[i] * LE_CONSOLE_POWF_SCALE;
  float zf;
  memcpy(&zf, &iz, sizeof(zf));
  const double z = (double)zf;
  const double r = z * invc - 1;
  const double y0 = logc + (double)k;
  const double r2 = r * r;
  const double* A = LE_CONSOLE_POWF_POLY;
  const double S = LE_CONSOLE_POWF_SCALE;
  double v = A[0] * S * r + A[1] * S;
  const double p = A[2] * S * r + A[3] * S;
  const double r4 = r2 * r2;
  double q = A[4] * S * r + y0;
  q = p * r2 + q;
  v = v * r4 + q;
  const double ylogx = (double)y * v;
  uint64_t u;
  memcpy(&u, &ylogx, sizeof(u));
  if ((u >> 47 & 0xffff) >= (0x40af800000000000ull >> 47)) return powf(x, y);
  /* exp2_inline */
  const double kd = round(ylogx);
  const uint64_t ki = (uint64_t)lround(ylogx);
  const double rr = ylogx - kd;
  uint64_t t = LE_CONSOLE_EXP2F_TAB[ki % 32];
  t += ki << (52 - 5);
  double sc;
  memcpy(&sc, &t, sizeof(sc));
  const double c0 = LE_CONSOLE_EXP2F_POLY[0] / S / S / S;
  const double c1 = LE_CONSOLE_EXP2F_POLY[1] / S / S;
  const double c2 = LE_CONSOLE_EXP2F_POLY[2] / S;
  const double c = c0 * rr + c1;
  const double rr2 = rr * rr;
  double e = c2 * rr + 1;
  e = c * rr2 + e;
  e = e * sc;
  return (float)e;
}

#define tanhf le_console_tanhf
#define powf le_console_powf

#endif /* SEGNO_FX_CONSOLE_LIBM_H */
