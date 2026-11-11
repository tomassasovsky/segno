/*
 * test_fx_drives_equiv.c — the drives and the amp render as they did before
 * #1755 made them cheaper.
 *
 * WHY: #1755 rewrote the Overdrive's, the Distortion's and the Amp+Cab's
 * kernels for speed under one rule: no loss of quality. Each must render
 * what it rendered before, bit for bit where the arithmetic is the same and
 * otherwise within -120 dBFS (a residual peak under 1e-6). This binary holds
 * the kernels as they were before #1755 (the reference section below,
 * copied from engine_fx.c at the integration trunk's 65f85a3b4 and renamed
 * ref_*; do not edit it) and renders every stimulus through both.
 *
 * It includes engine_fx.c, for its static kernels, and links the units that
 * file needs. Each kind is driven the way the chain drives it: a heap-state
 * kind's update at the start and every LE_FX_UPDATE_FRAMES frames (the first
 * settling, as fx_kind_state does on a fresh block), then its kernel every
 * frame; the Amp+Cab through its own process, which keeps its own update
 * cadence. Both renders get the same updates, so what differs is only the
 * kernel. The settings change at block boundaries, as the engine hands a
 * block's settings to the chain, so the moving programs run at 32- and
 * 64-frame blocks; a still setting renders the same at any block (the
 * kernels run a frame at a time), so it runs once. Denormals are flushed,
 * as the engine runs.
 *
 * The reference is the console's render, on every platform: the console's
 * tanhf and powf (glibc 2.41's) are copied in as ref_tanhf and ref_powf,
 * since a platform's own differ from them by an ulp here and there, and
 * the Overdrive's and the Distortion's float filters turn any such
 * difference into a residual near -90 dBFS at their hardest settings
 * (their rounding noise, which a reordered addition in a tone filter shows
 * as well). On the console, -DEQ_LIBM uses its libm instead: what it renders
 * today, literally.
 *
 * The stimuli, at 44.1, 48, 88.2 and 96 kHz, different on the two channels:
 *   sweeps    exponential sines from 20 Hz to 20 kHz (0.45 of the rate at
 *             most) in one second, at -24, -6 and 0 dBFS;
 *   impulses  single samples from 0.05 to 1, both signs;
 *   guitar    a plucked six-string strum and a line (Karplus-Strong), at
 *             -6 dBFS, with a silent tail;
 *   bass      plucked notes from E1 to G2, at -3 dBFS.
 * The settings: each kind's extremes and defaults on every stimulus; every
 * factory setting of the kind (fx_factory_settings.inc) on the guitar, at
 * 48 kHz (every rate with --full); and each setting swept from 0 to 1 across
 * the guitar, and switched between 0 and 1 every 100 ms (the Amp+Cab's
 * cabinet also stepped through all twelve), so the glides and the cabinet
 * crossfade run.
 *
 *   test_fx_drives_equiv          # the native tests' run
 *   test_fx_drives_equiv --full   # every factory setting at every rate,
 *                                 # 176.4 and 192 kHz as well
 *   test_fx_drives_equiv --detail # every render's residual
 */
#define _GNU_SOURCE
#include "engine_fx.c"

#include <stdio.h>

/* ======================================================================
 * The reference: the kernels before #1755, verbatim but for the ref_
 * names, the Amp+Cab's entry points (an instance pointer instead of the
 * effect state's slot), ref_tanhf and ref_powf for libm's, and the
 * cabinet bank's direct taps, which engine_fx.c now stores last tap first.
 * Their helpers that #1755 does not touch (the designs, the biquads, the
 * glides, the tables) are engine_fx.c's own.
 * ====================================================================== */

/* The console's tanhf: glibc 2.41's, which is CORE-MATH's correctly rounded
 * tanhf (revision b1ecd83, Copyright (c) 2022-2024 Alexei Sibidanov, MIT
 * licence), as glibc has it. Correctly rounded, so it gives the same float
 * on every platform: with it the reference renders here what the console
 * renders, where a platform's own tanhf (macOS's, glibc's before 2.41) is
 * up to 2.2 ulps off. */
static float ref_tanhf(float x) {
#ifdef EQ_LIBM
  /* On the console, its own libm: today's render there, literally. */
  return tanhf(x);
#endif
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
 * TOINT_INTRINSICS: POWF_SCALE 32, round and lround), for the curve's
 * positive x and y. glibc's powf is not correctly rounded, so platforms
 * differ by an ulp here and there; with this the reference renders here
 * what the console renders. The cases glibc treats apart (x not a
 * positive normal float, |y log2 x| past 126) go to the platform's powf,
 * which the audio never reaches. */
/* glibc 2.41's tables for ref_powf (e_powf_log2_data.c, e_exp2f_data.c),
 * copied here apart from engine_fx.c's so that a slip in either shows. */
static const double REF_POWF_INVC[16] = {
    0x1.661ec79f8f3bep+0, 0x1.571ed4aaf883dp+0, 0x1.49539f0f010bp+0,
    0x1.3c995b0b80385p+0, 0x1.30d190c8864a5p+0, 0x1.25e227b0b8eap+0,
    0x1.1bb4a4a1a343fp+0, 0x1.12358f08ae5bap+0, 0x1.0953f419900a7p+0,
    0x1p+0,               0x1.e608cfd9a47acp-1, 0x1.ca4b31f026aap-1,
    0x1.b2036576afce6p-1, 0x1.9c2d163a1aa2dp-1, 0x1.886e6037841edp-1,
    0x1.767dcf5534862p-1};
static const double REF_POWF_LOGC[16] = {
    -0x1.efec65b963019p-2, -0x1.b0b6832d4fca4p-2, -0x1.7418b0a1fb77bp-2,
    -0x1.39de91a6dcf7bp-2, -0x1.01d9bf3f2b631p-2, -0x1.97c1d1b3b7afp-3,
    -0x1.2f9e393af3c9fp-3, -0x1.960cbbf788d5cp-4, -0x1.a6f9db6475fcep-5,
    0x0p+0,                0x1.338ca9f24f53dp-4,  0x1.476a9543891bap-3,
    0x1.e840b4ac4e4d2p-3,  0x1.40645f0c6651cp-2,  0x1.88e9c2c1b9ff8p-2,
    0x1.ce0a44eb17bccp-2};
static const double REF_POWF_POLY[5] = {
    0x1.27616c9496e0bp-2, -0x1.71969a075c67ap-2, 0x1.ec70a6ca7baddp-2,
    -0x1.7154748bef6c8p-1, 0x1.71547652ab82bp0};
static const uint64_t REF_EXP2F_TAB[32] = {
    0x3ff0000000000000, 0x3fefd9b0d3158574, 0x3fefb5586cf9890f, 0x3fef9301d0125b51,
    0x3fef72b83c7d517b, 0x3fef54873168b9aa, 0x3fef387a6e756238, 0x3fef1e9df51fdee1,
    0x3fef06fe0a31b715, 0x3feef1a7373aa9cb, 0x3feedea64c123422, 0x3feece086061892d,
    0x3feebfdad5362a27, 0x3feeb42b569d4f82, 0x3feeab07dd485429, 0x3feea47eb03a5585,
    0x3feea09e667f3bcd, 0x3fee9f75e8ec5f74, 0x3feea11473eb0187, 0x3feea589994cce13,
    0x3feeace5422aa0db, 0x3feeb737b0cdc5e5, 0x3feec49182a3f090, 0x3feed503b23e255d,
    0x3feee89f995ad3ad, 0x3feeff76f2fb5e47, 0x3fef199bdd85529c, 0x3fef3720dcef9069,
    0x3fef5818dcfba487, 0x3fef7c97337b9b5f, 0x3fefa4afa2a490da, 0x3fefd0765b6e4540};
static const double REF_EXP2F_POLY[3] = {
    0x1.c6af84b912394p-5, 0x1.ebfce50fac4f3p-3, 0x1.62e42ff0c52d6p-1};
#define REF_POWF_SCALE 32.0 /* 1 << EXP2F_TABLE_BITS, with TOINT_INTRINSICS */

static float ref_powf(float x, float y) {
#ifdef EQ_LIBM
  return powf(x, y);
#endif
  uint32_t ix;
  memcpy(&ix, &x, sizeof(ix));
  if (ix == 0) return 0.0f;
  if (ix - 0x00800000u >= 0x7f800000u - 0x00800000u) return powf(x, y);
  /* log2_inline */
  const uint32_t tmp = ix - 0x3f330000u;
  const int i = (int)((tmp >> (23 - 4)) % 16);
  const uint32_t top = tmp & 0xff800000u;
  const uint32_t iz = ix - top;
  const int k = (int32_t)top >> (23 - 5);
  const double invc = REF_POWF_INVC[i];
  const double logc = REF_POWF_LOGC[i] * REF_POWF_SCALE;
  float zf;
  memcpy(&zf, &iz, sizeof(zf));
  const double z = (double)zf;
  const double r = z * invc - 1;
  const double y0 = logc + (double)k;
  const double r2 = r * r;
  const double* A = REF_POWF_POLY;
  const double S = REF_POWF_SCALE;
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
  uint64_t t = REF_EXP2F_TAB[ki % 32];
  t += ki << (52 - 5);
  double sc;
  memcpy(&sc, &t, sizeof(sc));
  const double c0 = REF_EXP2F_POLY[0] / S / S / S;
  const double c1 = REF_EXP2F_POLY[1] / S / S;
  const double c2 = REF_EXP2F_POLY[2] / S;
  const double c = c0 * rr + c1;
  const double rr2 = rr * rr;
  double e = c2 * rr + 1;
  e = c * rr2 + e;
  e = e * sc;
  return (float)e;
}

/* [x] through path [p]'s sections (every other coefficient of [c], from
 * [first]), each y = c (x - y') + x' in the path's own rate. */
static inline float ref_os_path_run(const float* c, int n, int first,
                                   le_os_path* p, float x) {
  for (int i = first; i < n; i += 2) {
    const float y = c[i] * (x - p->y[i]) + p->x[i];
    p->x[i] = x;
    p->y[i] = y;
    x = y;
  }
  return x;
}

/* [x] on channel [ch] up to 2^stages samples, in time order, into [out]:
 * each stage's even output is A0's, its odd one A1's. */
static inline int ref_os_up(le_os* o, int ch, float x, float* out) {
  out[0] = x;
  int n = 1;
  for (int s = 0; s < o->stages; ++s) {
    float tmp[1 << LE_OS_MAX_STAGES];
    le_os_path* p = &o->up[ch][s];
    for (int i = 0; i < n; ++i) {
      tmp[2 * i] = ref_os_path_run(o->c[s], o->n[s], 0, p, out[i]);
      tmp[2 * i + 1] = ref_os_path_run(o->c[s], o->n[s], 1, p, out[i]);
    }
    n *= 2;
    for (int i = 0; i < n; ++i) out[i] = tmp[i];
  }
  return n;
}

/* The 2^stages samples in [in] (time order) on channel [ch] back down to
 * one: each pair's newer sample through A0, its older through A1, halved.
 * [in] is used as scratch. */
static inline float ref_os_down(le_os* o, int ch, float* in) {
  int n = 1 << o->stages;
  /* The paths are recursive: a sample that is not finite would stay in
   * them, so it goes in as 0. */
  for (int i = 0; i < n; ++i) in[i] = fx_sanitize(in[i]);
  for (int s = o->stages - 1; s >= 0; --s) {
    n /= 2;
    le_os_path* p = &o->down[ch][s];
    for (int i = 0; i < n; ++i) {
      const float a0 = ref_os_path_run(o->c[s], o->n[s], 0, p, in[2 * i + 1]);
      const float a1 = ref_os_path_run(o->c[s], o->n[s], 1, p, in[2 * i]);
      in[i] = 0.5f * (a0 + a1);
    }
  }
  return in[0];
}

static inline float ref_hb_tick(le_hb* h, int ch, int ph, float x) {
  if (h->n == 0) return x;
  le_os_path* p = &h->p[ch][ph];
  const float y = 0.5f * (ref_os_path_run(h->c, h->n, 0, p, x) + h->a1[ch]);
  h->a1[ch] = ref_os_path_run(h->c, h->n, 1, p, x);
  return y;
}

typedef struct ref_fx_overdrive {
  le_fx_glide g;    /* the clipped part's gain over its ceiling, G / c */
  le_fx_glide level; /* the gain after the tone filter */
  float g_tgt;      /* where g is headed */
  float dlp_g;      /* the glide point dlp_g1 was designed for, -1 for none */
  float tone;       /* the tone setting now, 0..1 */
  float tone_tgt;
  float level_tgt;  /* where level is headed, a gain */
  float hp_g1;
  float dhp_g1, dlp_g1; /* the clipped part's input high-pass and output
                         * low-pass, one-poles at the curve's rate */
  float s_dhp[2], s_dlp[2];
  float pk[5];      /* the 680 Hz rise, RBJ, a0-normalized */
  float tone_lp[5], sh[5], bl[5]; /* the tone: its corner, shelf and bell */
  float lp2[5];     /* the 11 kHz pole */
  float s_hp[2];
  float z_pk[2][LE_RS_PH][2], z_tone[2][LE_RS_PH][2], z_sh[2][LE_RS_PH][2];
  float z_bl[2][LE_RS_PH][2], z_lp2[2][LE_RS_PH][2];
  int32_t ph, nph; /* the sections' phase this frame (le_rs_phases) */
  le_os os; /* the curve's oversampling */
  le_hb hb; /* at 96 kHz, the curve's output under 24 kHz */
} ref_fx_overdrive;

/* The tone's shelf or bell gain at setting [t], dB: [tab] read at Tone 0,
 * 25, 50, 75 and 100 %, linear between. */
static float ref_od_tone_db(const float* tab, float t) {
  const float x = (t < 0.0f ? 0.0f : t > 1.0f ? 1.0f : t) *
                  (float)(LE_OD_TONE_PTS - 1);
  int i = (int)x;
  if (i > LE_OD_TONE_PTS - 2) i = LE_OD_TONE_PTS - 2;
  const float w = x - (float)i;
  return tab[i] + w * (tab[i + 1] - tab[i]);
}

static void ref_od_coefs(float* dst, int kind, double hz, double db, double q,
                        int sr) {
  double c[5];
  le_rate_design(kind, hz, db, q, sr, c);
  for (int i = 0; i < 5; ++i) dst[i] = (float)c[i];
}

static void ref_fx_overdrive_update(void* ks, le_fx_dyn_head* h, const float* p,
                                int sr, int f) {
  ref_fx_overdrive* o = (ref_fx_overdrive*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    le_os_design(&o->os, sr, le_os_stages(LE_FX_OVERDRIVE, sr));
    le_hb_design(&o->hb, sr);
    o->nph = le_rs_phases(sr);
    memset(o->s_dhp, 0, sizeof(o->s_dhp));
    memset(o->s_dlp, 0, sizeof(o->s_dlp));
    memset(o->z_pk, 0, sizeof(o->z_pk));
    memset(o->z_tone, 0, sizeof(o->z_tone));
    memset(o->z_sh, 0, sizeof(o->z_sh));
    memset(o->z_bl, 0, sizeof(o->z_bl));
    memset(o->z_lp2, 0, sizeof(o->z_lp2));
    o->ph = 0;
    o->dlp_g = -1.0f; /* none designed at this rate yet */
    o->hp_g1 = le_onepole_g1(LE_OD_HP_HZ, sr);
    o->dhp_g1 = le_onepole_g1(LE_OD_DHP_HZ, rate << o->os.stages);
    ref_od_coefs(o->lp2, LE_RS_LP1, LE_OD_LP2_HZ, 0.0, 0.0, rate);
    ref_od_coefs(o->pk, LE_EQ_LOMID, LE_OD_PEAK_HZ, LE_OD_PEAK_DB, LE_OD_PEAK_Q,
                rate);
    ref_od_coefs(o->tone_lp, LE_RS_LP1, LE_OD_TONE_HZ, 0.0, 0.0, rate);
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    o->tone_tgt = t;
    o->g_tgt = (float)(exp(LE_OD_LNG0 + d * (LE_OD_LNG1 + d * LE_OD_LNG2)) /
                       LE_OD_C);
    /* 0 dB is a gain of exactly 1, so the default leaves the output as it
     * was. */
    o->level_tgt = le_gain_of_db(
        (float)le_fx_desc_value(&LE_FX_OVERDRIVE_PARAMS[2], p[2]));
  }
  const float k = settle ? 1.0f : h->k;
  int moving = le_fx_glide_step(&o->g, o->g_tgt, k);
  moving |= le_fx_glide_step(&o->level, o->level_tgt, k);
  if (o->dlp_g != o->g.g) {
    /* the low-pass follows the gain the glide is headed for this step */
    o->dlp_g = o->g.g;
    const double gain = (double)o->g.g * LE_OD_C;
    o->dlp_g1 = le_onepole_g1(LE_OD_GBW_HZ / gain, rate << o->os.stages);
  }
  if (o->tone != o->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&o->tone, o->tone_tgt, k);
    ref_od_coefs(o->sh, LE_EQ_HIGH, LE_OD_SH_HZ,
                ref_od_tone_db(LE_OD_SH_DB, o->tone), LE_OD_SH_Q, rate);
    ref_od_coefs(o->bl, LE_EQ_LOMID, LE_OD_BL_HZ,
                ref_od_tone_db(LE_OD_BL_DB, o->tone), LE_OD_BL_Q, rate);
  }
  moving |= o->tone != o->tone_tgt;
  h->moving = moving;
}

static void ref_fx_overdrive_kprocess(void* ks, float* l, float* r) {
  ref_fx_overdrive* o = (ref_fx_overdrive*)ks;
  const float g = le_fx_glide_next(&o->g);
  const float level = le_fx_glide_next(&o->level);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float os[1 << LE_OS_MAX_STAGES];
    const int n = ref_os_up(&o->os, ch, io[ch], os);
    for (int i = 0; i < n; ++i) {
      /* The clipped part: the 434 Hz high-pass before the curve, the
       * drive's low-pass after it, at the curve's rate. */
      const float x = os[i];
      const float xh = x - le_onepole_lp(&o->s_dhp[ch], o->dhp_g1, x);
      const float u = LE_OD_K * x + le_onepole_lp(&o->s_dlp[ch], o->dlp_g1,
                                                  LE_OD_C * ref_tanhf(g * xh));
      os[i] = (ref_tanhf(LE_OD_A * (u + LE_OD_B)) - LE_OD_OFF) * (1.0f / LE_OD_A);
    }
    float v = ref_hb_tick(&o->hb, ch, o->ph, ref_os_down(&o->os, ch, os));
    /* The tone filter: the 17 Hz high-pass, the 680 Hz rise, the tone
     * corner, shelf and bell, and the 11 kHz pole. */
    v = v - le_onepole_lp(&o->s_hp[ch], o->hp_g1, v);
    v = le_biquad_tick(o->pk, o->z_pk[ch][o->ph], v);
    v = le_biquad_tick(o->tone_lp, o->z_tone[ch][o->ph], v);
    v = le_biquad_tick(o->sh, o->z_sh[ch][o->ph], v);
    v = le_biquad_tick(o->bl, o->z_bl[ch][o->ph], v);
    v = le_biquad_tick(o->lp2, o->z_lp2[ch][o->ph], v);
    io[ch] = ((LE_OD_P / (float)LE_OD_TONE_1K) * v) * level;
  }
  if (++o->ph >= o->nph) o->ph = 0;
  *l = io[0];
  *r = io[1];
}

/* The clipper's knee: z / (1 + z^4)^(1/4), limiting at +-1 (two square
 * roots, no powf). */
static inline float ref_amp_knee(float z) {
  const float a = z * z;
  return z / sqrtf(sqrtf(1.0f + a * a));
}

/* One instance (mono). */
typedef struct ref_fx_amp {
  int32_t sr;                 /* what the filters and the bank are for; 0: unset */
  int32_t settle;             /* the next update lands every glide at once */
  int32_t tick;               /* frames to the next update */
  int32_t cab, cab_from;      /* the cabinet index heard, the one fading out */
  int32_t xf;                 /* crossfade frames left */
  int32_t moving;             /* a glide has not landed */
  float last[LE_AMP_PARAMS_N];
  float k;                    /* glide factor per update */
  /* glides, in their own units (dB, octaves, a coefficient) */
  float ga, gb, kq, mpre, mpost, mls, mpk, mhs;
  float bass[3], treble[3], dhs[3]; /* log2 Hz, dB, Q */
  float ga_lin, gb_lin, out_lin, mpre_lin;
  /* filters, a0-normalized biquads and their states */
  float pre_hp[5], pre_pk1[5], pre_pk2[5], dc_b0, dc_a1;
  float m_ls[5], m_pk[5], m_hs[5], d_hs[5];
  float post_hp_b0, post_hp_a1, t_bass[5], t_treb[5], lp1[5], lp2[5];
  /* the sections' state per phase (le_rs_phases); the one-pole couplings
   * run at the rate */
  float z_pre[3][LE_RS_PH][2], z_dc[2], z_m[3][LE_RS_PH][2], z_dhs[LE_RS_PH][2],
      z_post_hp[2], z_tone[2][LE_RS_PH][2], z_lp[2][LE_RS_PH][2];
  int32_t ph, nph;
  /* the cabinet: head history (doubled), the block being filled, the
   * frequency-domain delay line, and the tail each running cabinet adds to
   * the next block */
  const le_cab_bank* bank;
  int32_t hp, j, fpos;
  float hist[2 * LE_CAB_B];
  float frame[2 * LE_CAB_B];
  float tail[2][LE_CAB_B];
  float fre[LE_CAB_MAX_PARTS][LE_CAB_NB], fim[LE_CAB_MAX_PARTS][LE_CAB_NB];
  float wr[LE_CAB_NB], wi[LE_CAB_NB], tmp[2 * LE_CAB_B];
  le_os os; /* the clipper's oversampling (mono: channel 0) */
  le_hb hbq; /* at 96 kHz, the first curve's output under 24 kHz */
  le_hb hb;  /* and the clipper's */
} ref_fx_amp;

static void ref_amp_design(int kind, double hz, double db, double q, int sr,
                          float c[5]) {
  double d[5];
  le_rate_design(kind, hz, db, q, sr, d);
  for (int i = 0; i < 5; ++i) c[i] = (float)d[i];
}

/* A one-pole high-pass's coefficients (bilinear, prewarped). */
static void ref_amp_hp1(double hz, int sr, float* b0, float* a1) {
  const double k = le_prewarp(hz, sr);
  *b0 = (float)(1.0 / (1.0 + k));
  *a1 = (float)((k - 1.0) / (k + 1.0));
}

static inline float ref_amp_hp1_tick(float b0, float a1, float* z, float x) {
  /* y[n] = b0 (x[n] - x[n-1]) - a1 y[n-1]; z = {x[n-1], y[n-1]} */
  const float y = b0 * (x - z[0]) - a1 * z[1];
  z[0] = x;
  z[1] = y;
  return y;
}

/* Clears what the instance plays from (filters, the cabinet's history),
 * keeping its rate and coefficients; the next update settles. */
static void ref_amp_reset(ref_fx_amp* a) {
  memset(a->z_pre, 0, sizeof(a->z_pre));
  memset(a->z_dc, 0, sizeof(a->z_dc));
  memset(a->z_m, 0, sizeof(a->z_m));
  memset(a->z_dhs, 0, sizeof(a->z_dhs));
  memset(a->z_post_hp, 0, sizeof(a->z_post_hp));
  memset(a->z_tone, 0, sizeof(a->z_tone));
  memset(a->z_lp, 0, sizeof(a->z_lp));
  memset(a->hist, 0, sizeof(a->hist));
  memset(a->frame, 0, sizeof(a->frame));
  memset(a->tail, 0, sizeof(a->tail));
  memset(a->fre, 0, sizeof(a->fre));
  memset(a->fim, 0, sizeof(a->fim));
  le_os_clear(&a->os);
  memset(a->hbq.p, 0, sizeof(a->hbq.p));
  memset(a->hbq.a1, 0, sizeof(a->hbq.a1));
  memset(a->hb.p, 0, sizeof(a->hb.p));
  memset(a->hb.a1, 0, sizeof(a->hb.a1));
  a->hp = a->j = a->fpos = 0;
  a->xf = 0;
  a->cab_from = a->cab;
  a->tick = 0;
  a->settle = 1;
}

/* The settings' targets, glided at the update cadence; filters redesigned
 * when a setting they read moved. */
static void ref_amp_update(ref_fx_amp* a, const float* p, int sr) {
  const int new_rate = a->sr != sr;
  /* Settled and unchanged: nothing to do. */
  if (!new_rate && !a->settle && !a->moving &&
      memcmp(a->last, p, sizeof(a->last)) == 0) {
    return;
  }
  memcpy(a->last, p, sizeof(a->last));
  if (new_rate) {
    a->sr = sr;
    a->k = le_fx_smooth_k(sr);
    le_os_design(&a->os, sr, le_os_stages(LE_FX_AMP_CAB, sr));
    le_hb_design(&a->hb, sr);
    le_hb_design(&a->hbq, sr);
    a->nph = le_rs_phases(sr);
    memset(a->z_pre, 0, sizeof(a->z_pre));
    memset(a->z_m, 0, sizeof(a->z_m));
    memset(a->z_dhs, 0, sizeof(a->z_dhs));
    memset(a->z_tone, 0, sizeof(a->z_tone));
    memset(a->z_lp, 0, sizeof(a->z_lp));
    a->ph = 0;
    ref_amp_design(LE_EQ_LOWCUT, LE_AMP_HP_HZ, 0.0, LE_AMP_HP_Q, sr, a->pre_hp);
    ref_amp_design(LE_EQ_LOMID, LE_AMP_PK1_HZ, LE_AMP_PK1_DB, LE_AMP_PK1_Q, sr,
                  a->pre_pk1);
    ref_amp_design(LE_EQ_LOMID, LE_AMP_PK2_HZ, LE_AMP_PK2_DB, LE_AMP_PK2_Q, sr,
                  a->pre_pk2);
    ref_amp_hp1(LE_AMP_DC_HZ, sr, &a->dc_b0, &a->dc_a1);
    ref_amp_hp1(LE_AMP_POST_HP_HZ, sr, &a->post_hp_b0, &a->post_hp_a1);
    ref_amp_design(LE_EQ_HIGHCUT, LE_AMP_LP1_HZ, 0.0, LE_AMP_LP1_Q, sr, a->lp1);
    ref_amp_design(LE_EQ_HIGHCUT, LE_AMP_LP2_HZ, 0.0, LE_AMP_LP2_Q, sr, a->lp2);
    a->bank = le_cab_bank_find(sr);
  }
  const float k = a->settle ? 1.0f : a->k;
  const float drive = p[0], bass = p[1], treble = p[2], modern = p[3];
  int cab = (int)(p[4] * 11.0f + 0.5f);
  cab = cab < 0 ? 0 : cab > 11 ? 11 : cab;
  if (a->settle) {
    a->cab = a->cab_from = cab;
    a->xf = 0;
  } else if (cab != a->cab && a->xf == 0) {
    /* Fade the old one out over the next frames: it keeps its tail, and
     * the new one's builds from the next block. */
    memcpy(a->tail[1], a->tail[0], sizeof(a->tail[0]));
    a->cab_from = a->cab;
    a->cab = cab;
    a->xf = LE_CAB_XF_FRAMES;
  }
  float tb[3], tt[3];
  le_amp_shelf(LE_AMP_BASS, 2, bass, tb);
  le_amp_shelf(LE_AMP_TREBLE, 2, treble, tt);
  float td[3];
  le_amp_shelf(LE_AMP_DRIVE_HS, 0, drive, td);
  const float tgt[8] = {le_amp_lerp(LE_AMP_GA_DB, drive),
                        le_amp_lerp(LE_AMP_GB_DB, drive),
                        le_amp_lerp(LE_AMP_K, modern),
                        le_amp_lerp(LE_AMP_MPRE_DB, modern) +
                            le_amp_lerp2(LE_AMP_DM_DB, drive, modern),
                        le_amp_lerp(LE_AMP_MPOST_DB, modern) +
                            le_amp_lerp(LE_AMP_OUT_DB, drive),
                        le_amp_lerp(LE_AMP_MLS_DB, modern),
                        le_amp_lerp(LE_AMP_MPK_DB, modern),
                        le_amp_lerp(LE_AMP_MHS_DB, modern)};
  float* cur[8] = {&a->ga, &a->gb, &a->kq, &a->mpre, &a->mpost,
                   &a->mls, &a->mpk, &a->mhs};
  int moved_m = new_rate, moved_t = new_rate;
  for (int i = 0; i < 8; ++i) {
    const float before = *cur[i];
    le_fx_step_toward(cur[i], tgt[i], k);
    if (i >= 5 && *cur[i] != before) moved_m = 1;
  }
  int moved_d = new_rate;
  for (int i = 0; i < 3; ++i) {
    const float b0 = a->bass[i], t0 = a->treble[i], d0 = a->dhs[i];
    le_fx_step_toward(&a->bass[i], tb[i], k);
    le_fx_step_toward(&a->treble[i], tt[i], k);
    le_fx_step_toward(&a->dhs[i], td[i], k);
    if (a->bass[i] != b0 || a->treble[i] != t0) moved_t = 1;
    if (a->dhs[i] != d0) moved_d = 1;
  }
  int moving = cab != a->cab; /* a change waiting for a fade to end */
  for (int i = 0; i < 8; ++i) moving |= *cur[i] != tgt[i];
  for (int i = 0; i < 3; ++i) {
    moving |= a->bass[i] != tb[i] || a->treble[i] != tt[i] || a->dhs[i] != td[i];
  }
  a->moving = moving;
  if (a->settle) moved_m = moved_t = moved_d = 1;
  if (moved_d) {
    ref_amp_design(LE_EQ_HIGH, exp2((double)a->dhs[0]), a->dhs[1], a->dhs[2], sr,
                  a->d_hs);
  }
  a->ga_lin = powf(10.0f, a->ga / 20.0f);
  a->gb_lin = powf(10.0f, a->gb / 20.0f);
  a->mpre_lin = powf(10.0f, a->mpre / 20.0f);
  a->out_lin = powf(10.0f, a->mpost / 20.0f);
  if (moved_m) {
    ref_amp_design(LE_EQ_LOW, LE_AMP_MLS_HZ, a->mls, LE_AMP_MLS_Q, sr, a->m_ls);
    ref_amp_design(LE_EQ_LOMID, LE_AMP_MPK_HZ, a->mpk, LE_AMP_MPK_Q, sr, a->m_pk);
    ref_amp_design(LE_EQ_HIGH, LE_AMP_MHS_HZ, a->mhs, LE_AMP_MHS_Q, sr, a->m_hs);
  }
  if (moved_t) {
    ref_amp_design(LE_EQ_LOW, exp2((double)a->bass[0]), a->bass[1], a->bass[2],
                  sr, a->t_bass);
    ref_amp_design(LE_EQ_HIGH, exp2((double)a->treble[0]), a->treble[1],
                  a->treble[2], sr, a->t_treb);
  }
  a->settle = 0;
}

/* One sample through the cabinet, both cabinets while one fades into the
 * other; at a block's end the partitions' spectra make the next block's
 * tails. */
static float ref_amp_cab(ref_fx_amp* a, float x) {
  const le_cab_bank* bk = a->bank;
  const int rn = LE_CAB_ROW[a->cab];
  const int ro = LE_CAB_ROW[a->cab_from];
  if (bk == NULL) return x;
  a->hist[a->hp] = x;
  a->hist[a->hp + LE_CAB_B] = x;
  const float* hx = a->hist + a->hp + LE_CAB_B; /* hx[-t]: t frames ago */
  float yn = 0.0f, yo = 0.0f;
  if (rn < 0) {
    /* The D.I. waits the frames a resampled cabinet starts late, so every
     * cabinet has the latency the table reports (none at 48 and 96 kHz). */
    yn = hx[-bk->pre];
  } else {
    const float* h = bk->head[rn];
    for (int t = 0; t < LE_CAB_B; ++t) yn += h[LE_CAB_B - 1 - t] * hx[-t];
    yn += a->tail[0][a->j];
  }
  const int fading = a->xf > 0;
  if (fading) {
    if (ro < 0) {
      yo = hx[-bk->pre];
    } else {
      const float* h = bk->head[ro];
      for (int t = 0; t < LE_CAB_B; ++t) yo += h[LE_CAB_B - 1 - t] * hx[-t];
      yo += a->tail[1][a->j];
    }
  }
  a->hp = (a->hp + 1) & (LE_CAB_B - 1);
  a->frame[LE_CAB_B + a->j] = x;
  if (++a->j == LE_CAB_B) {
    a->j = 0;
    const int parts = bk->parts;
    a->fpos = a->fpos + 1 >= parts ? 0 : a->fpos + 1;
    le_rfft_fwd(&le_cab_fft, a->frame, a->fre[a->fpos], a->fim[a->fpos]);
    memmove(a->frame, a->frame + LE_CAB_B, sizeof(float) * LE_CAB_B);
    for (int which = 0; which < 2; ++which) {
      const int row = which == 0 ? rn : ro;
      if (which == 1 && a->xf <= 1) break; /* the fade ends on this frame */
      if (row < 0) {
        memset(a->tail[which], 0, sizeof(a->tail[which]));
        continue;
      }
      memset(a->wr, 0, sizeof(a->wr));
      memset(a->wi, 0, sizeof(a->wi));
      for (int pp = 0; pp < parts; ++pp) {
        int s = a->fpos - pp;
        if (s < 0) s += parts;
        const float* xr = a->fre[s];
        const float* xi = a->fim[s];
        const float* hr = bk->re[row][pp];
        const float* hi = bk->im[row][pp];
        for (int q = 0; q < LE_CAB_NB; ++q) {
          a->wr[q] += xr[q] * hr[q] - xi[q] * hi[q];
          a->wi[q] += xr[q] * hi[q] + xi[q] * hr[q];
        }
      }
      le_rfft_inv(&le_cab_fft, a->wr, a->wi, a->tmp);
      memcpy(a->tail[which], a->tmp + LE_CAB_B, sizeof(float) * LE_CAB_B);
    }
  }
  if (!fading) return yn;
  const float w = (float)a->xf / (float)LE_CAB_XF_FRAMES; /* the old one's share */
  if (--a->xf == 0) a->cab_from = a->cab;
  return yn + w * (yo - yn);
}

static void ref_fx_amp_cab_process(ref_fx_amp* a, int sr, float* l, float* r,
                                   const float* p) {
  const int rate = sr > 0 ? sr : 48000;
  if (a->tick <= 0 || a->sr != rate) {
    ref_amp_update(a, p, rate);
    a->tick = LE_FX_UPDATE_FRAMES;
  }
  --a->tick;
  const float x = 0.5f * (fx_sanitize(*l) + fx_sanitize(*r));
  const int ph = a->ph;
  if (++a->ph >= a->nph) a->ph = 0;
  float u = le_biquad_tick(a->pre_hp, a->z_pre[0][ph], x);
  u = le_biquad_tick(a->pre_pk1, a->z_pre[1][ph], u);
  u = le_biquad_tick(a->pre_pk2, a->z_pre[2][ph], u);
  u *= a->ga_lin;
  float v = ref_hb_tick(&a->hbq, 0, ph, u + a->kq * u * u);
  v = ref_amp_hp1_tick(a->dc_b0, a->dc_a1, a->z_dc, v);
  v = le_biquad_tick(a->m_ls, a->z_m[0][ph], v);
  v = le_biquad_tick(a->m_pk, a->z_m[1][ph], v);
  v = le_biquad_tick(a->m_hs, a->z_m[2][ph], v);
  v = le_biquad_tick(a->d_hs, a->z_dhs[ph], v);
  float os[1 << LE_OS_MAX_STAGES];
  const int n = ref_os_up(&a->os, 0, v * a->mpre_lin * a->gb_lin, os);
  for (int i = 0; i < n; ++i) {
    const float w = os[i];
    os[i] = w >= 0.0f ? LE_AMP_CLIP_POS * ref_amp_knee(w / LE_AMP_CLIP_POS)
                      : LE_AMP_CLIP_NEG * ref_amp_knee(w / LE_AMP_CLIP_NEG);
  }
  float y = ref_hb_tick(&a->hb, 0, ph, ref_os_down(&a->os, 0, os));
  y = ref_amp_hp1_tick(a->post_hp_b0, a->post_hp_a1, a->z_post_hp, y);
  y = le_biquad_tick(a->t_bass, a->z_tone[0][ph], y);
  y = le_biquad_tick(a->t_treb, a->z_tone[1][ph], y);
  y = le_biquad_tick(a->lp1, a->z_lp[0][ph], y);
  y = le_biquad_tick(a->lp2, a->z_lp[1][ph], y);
  y = ref_amp_cab(a, y * a->out_lin);
  *l = y;
  *r = y;
}

/* The instance, and the cabinets at this rate (fx_amp_cab_prepare). */
static ref_fx_amp* ref_amp_new(int cap) {
  if (le_cab_bank_get(cap > 0 ? cap : 48000) == NULL) return NULL;
  ref_fx_amp* a = (ref_fx_amp*)calloc(1, sizeof(ref_fx_amp));
  if (a == NULL) return NULL;
  ref_amp_reset(a);
  return a;
}

typedef struct ref_fx_distortion {
  le_fx_glide g;     /* the gain into the curve */
  le_fx_glide level; /* the output level, over the cabinet's 1 kHz gain */
  float norm;        /* 1 / |cabinet at 1 kHz| */
  float tone_db;     /* the shelf now, gliding to tone_tgt */
  float tone_tgt;
  int32_t shelf_on;
  float cab[LE_DIST_SECTIONS][5];
  float shelf[5];
  float z[LE_DIST_SECTIONS + 1][2][LE_RS_PH][2]; /* [section][channel][phase][state] */
  int32_t ph, nph; /* the sections' phase this frame (le_rs_phases) */
  le_os os; /* the curve's oversampling */
  le_hb hb; /* at 96 kHz, the curve's output under 24 kHz */
} ref_fx_distortion;

/* |H(e^jw)| of one a0-normalized biquad. */
static double ref_biquad_mag(const double c[5], double w) {
  const double cr = cos(w), ci = -sin(w), c2r = cos(2.0 * w), c2i = -sin(2.0 * w);
  const double nr = c[0] + c[1] * cr + c[2] * c2r;
  const double ni = c[1] * ci + c[2] * c2i;
  const double dr = 1.0 + c[3] * cr + c[4] * c2r;
  const double di = c[3] * ci + c[4] * c2i;
  return sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

static void ref_fx_distortion_update(void* ks, le_fx_dyn_head* h, const float* p,
                                 int sr, int f) {
  ref_fx_distortion* q = (ref_fx_distortion*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    le_os_design(&q->os, sr, le_os_stages(LE_FX_DISTORTION, sr));
    le_hb_design(&q->hb, sr);
    q->nph = le_rs_phases(sr);
    memset(q->z, 0, sizeof(q->z));
    q->ph = 0;
    double mag = 1.0;
    /* The sections are designed at le_rs_design_rate. */
    const double w1k =
        2.0 * 3.14159265358979323846 * 1000.0 / le_rs_design_rate(rate);
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      double c[5];
      le_rate_design(LE_DIST_CAB[s].kind, LE_DIST_CAB[s].hz, LE_DIST_CAB[s].db,
                   LE_DIST_CAB[s].q, rate, c);
      for (int i = 0; i < 5; ++i) q->cab[s][i] = (float)c[i];
      mag *= ref_biquad_mag(c, w1k);
    }
    q->norm = (float)(1.0 / mag);
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  const float k = settle ? 1.0f : h->k;
  int moving = le_fx_glide_step(
      &q->g,
      (float)exp(-1.0887 + d * (2.3136 + d * (-3.3444 + d * 6.5117))), k);
  moving |= le_fx_glide_step(&q->level, (1.4512f - 0.4823f * d) * q->norm, k);
  if (f & LE_FX_DYN_CHANGED) {
    q->tone_tgt = (float)(LE_DIST_TONE_DB * (2.0 * t - 1.0));
  }
  if (q->tone_db != q->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    /* The shelf glides in dB, redesigned while it moves. */
    le_fx_step_toward(&q->tone_db, q->tone_tgt, k);
    const int on = q->tone_db != 0.0f;
    if (!on && q->shelf_on) {
      memset(q->z[LE_DIST_SECTIONS], 0, sizeof(q->z[LE_DIST_SECTIONS]));
    }
    q->shelf_on = on;
    if (on) {
      double c[5];
      le_rate_design(LE_EQ_HIGH, LE_DIST_TONE_HZ, q->tone_db, 0.70710678, rate,
                     c);
      for (int i = 0; i < 5; ++i) q->shelf[i] = (float)c[i];
    }
  }
  moving |= q->tone_db != q->tone_tgt;
  h->moving = moving;
}

static void ref_fx_distortion_kprocess(void* ks, float* l, float* r) {
  ref_fx_distortion* q = (ref_fx_distortion*)ks;
  const float g = le_fx_glide_next(&q->g);
  const float level = le_fx_glide_next(&q->level);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float os[1 << LE_OS_MAX_STAGES];
    const int n = ref_os_up(&q->os, ch, io[ch], os);
    for (int i = 0; i < n; ++i) {
      const float u = g * os[i];
      const float au = LE_DIST_ALPHA * u;
      const float w = u + LE_DIST_ALPHA * u * u / (1.0f + au * au);
      const float c = w > 0.0f ? LE_DIST_UP : LE_DIST_DOWN;
      os[i] = w / ref_powf(1.0f + ref_powf(fabsf(w / c), LE_DIST_KNEE),
                       1.0f / LE_DIST_KNEE);
    }
    float v = ref_hb_tick(&q->hb, ch, q->ph, ref_os_down(&q->os, ch, os));
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      v = le_biquad_tick(q->cab[s], q->z[s][ch][q->ph], v);
    }
    /* The tone shelf, skipped while flat (the Studio Rack's, and the
     * default); its memory clears so it starts clean when it comes back. */
    if (q->shelf_on) {
      v = le_biquad_tick(q->shelf, q->z[LE_DIST_SECTIONS][ch][q->ph], v);
    }
    io[ch] = level * v;
  }
  if (++q->ph >= q->nph) q->ph = 0;
  *l = io[0];
  *r = io[1];
}

/* ======================================================================
 * The renders.
 * ====================================================================== */

#define EQ_LIMIT 1e-6 /* -120 dBFS */
#define EQ_NRATES 6 /* the native tests' run takes the first four */
static const int k_rates[EQ_NRATES] = {44100, 48000, 88200, 96000, 176400,
                                       192000};

typedef struct {
  const char* name;
  int32_t type;
  float p[LE_FX_PARAMS];
} eq_setting;

static const eq_setting k_factory[] = {
#include "bench/fx_factory_settings.inc"
};

/* Each kind's extremes and defaults (the Distortion's default is no rack's:
 * no factory rack builds it). */
static const eq_setting k_extremes[] = {
    {"overdrive all 0", LE_FX_OVERDRIVE, {0.0f, 0.0f, 0.0f}},
    {"overdrive default", LE_FX_OVERDRIVE, {0.09f, 0.5f, 0.0f}},
    {"overdrive all 1", LE_FX_OVERDRIVE, {1.0f, 1.0f, 1.0f}},
    {"overdrive drive 1 tone 0", LE_FX_OVERDRIVE, {1.0f, 0.0f, 0.5f}},
    {"overdrive Lo-Fi", LE_FX_OVERDRIVE, {0.535f, 0.9f, 0.3402f}},
    {"distortion all 0", LE_FX_DISTORTION, {0.0f, 0.0f}},
    {"distortion default", LE_FX_DISTORTION, {0.2f, 0.5f}},
    {"distortion all 1", LE_FX_DISTORTION, {1.0f, 1.0f}},
    {"distortion drive 1 tone 0", LE_FX_DISTORTION, {1.0f, 0.0f}},
    {"amp D.I. at 0", LE_FX_AMP_CAB, {0.0f, 0.0f, 0.0f, 0.0f, 0.0f}},
    {"amp default", LE_FX_AMP_CAB, {0.5f, 0.5f, 0.5f, 0.5f, 7.0f / 11.0f}},
    {"amp all 1", LE_FX_AMP_CAB, {1.0f, 1.0f, 1.0f, 1.0f, 1.0f}},
    {"amp drive 1 BRIT", LE_FX_AMP_CAB, {1.0f, 0.0f, 1.0f, 0.0f, 1.0f / 11.0f}},
    {"amp Studio Dist D.I.", LE_FX_AMP_CAB, {0.8166f, 0.5f, 0.35f, 0.5f, 0.0f}},
};

/* ---- stimuli: functions of time, a different take on each channel ---- */

typedef struct {
  const char* name;
  int n;
  float* l;
  float* r;
} eq_stim;

static uint32_t g_lcg = 12345u;
static double eq_noise(void) {
  g_lcg = g_lcg * 1664525u + 1013904223u;
  return (double)(g_lcg >> 8) / 8388608.0 - 1.0;
}

static void eq_alloc(eq_stim* s, const char* name, double seconds, int sr) {
  s->name = name;
  s->n = (int)(seconds * sr);
  s->l = (float*)calloc((size_t)s->n, sizeof(float));
  s->r = (float*)calloc((size_t)s->n, sizeof(float));
}

static void eq_free(eq_stim* s) {
  free(s->l);
  free(s->r);
}

static void eq_sweep(eq_stim* s, const char* name, double dbfs, int sr) {
  eq_alloc(s, name, 1.0, sr);
  const double a = pow(10.0, dbfs / 20.0);
  const double f0 = 20.0;
  const double f1 = fmin(20000.0, 0.45 * sr);
  const double k = log(f1 / f0);
  for (int i = 0; i < s->n; ++i) {
    const double t = (double)i / s->n; /* over the one second */
    const double ph = 2.0 * M_PI * f0 * (exp(t * k) - 1.0) / k;
    s->l[i] = (float)(a * sin(ph));
    s->r[i] = (float)(0.7 * a * cos(ph));
  }
}

static void eq_impulses(eq_stim* s, int sr) {
  static const float amp[6] = {1.0f, -0.5f, 0.25f, -1.0f, 0.05f, 0.6f};
  eq_alloc(s, "impulses", 0.35, sr);
  for (int k = 0; k < 6; ++k) {
    const int at = (int)(0.05 * sr) * k + 7;
    s->l[at] = amp[k];
    s->r[at + 11] = -0.8f * amp[k];
  }
}

/* Karplus-Strong plucks of [hz] starting at [at] seconds, into [x]. */
static void eq_pluck(float* x, int n, int sr, double hz, double at,
                     double gain) {
  const int len = (int)(sr / hz + 0.5);
  double* line = (double*)calloc((size_t)len, sizeof(double));
  for (int i = 0; i < len; ++i) line[i] = eq_noise();
  const int start = (int)(at * sr);
  double prev = 0.0;
  for (int i = start, j = 0; i < n; ++i, j = (j + 1) % len) {
    const double y = 0.4975 * (line[j] + prev);
    prev = line[j];
    line[j] = y;
    x[i] += (float)(gain * y);
  }
  free(line);
}

static void eq_normalize(float* x, int n, double peak) {
  double m = 0.0;
  for (int i = 0; i < n; ++i) m = fmax(m, fabs(x[i]));
  if (m <= 0.0) return;
  for (int i = 0; i < n; ++i) x[i] = (float)(x[i] * peak / m);
}

static void eq_guitar(eq_stim* s, int sr, double seconds) {
  static const double strum[6] = {82.41, 110.0, 146.83, 196.0, 246.94, 329.63};
  static const double line[6] = {392.0, 440.0, 493.88, 587.33, 659.26, 1318.5};
  eq_alloc(s, "guitar", seconds, sr);
  const int notes = (int)(seconds * 4.0) - 3; /* a silent tail */
  for (int c = 0; c < 2; ++c) {
    float* x = c == 0 ? s->l : s->r;
    const double detune = c == 0 ? 1.0 : 1.003;
    for (int k = 0; k < 6; ++k) {
      eq_pluck(x, s->n, sr, strum[k] * detune, 0.01 + 0.015 * k, 0.6);
    }
    for (int k = 0; k < notes - 2; ++k) {
      eq_pluck(x, s->n, sr, line[k % 6] * detune, 0.5 + 0.25 * k, 0.8);
    }
    eq_normalize(x, s->n, c == 0 ? 0.5 : 0.35);
    /* the tail: silence from 0.4 s before the end */
    for (int i = s->n - (int)(0.4 * sr); i < s->n; ++i) x[i] = 0.0f;
  }
}

static void eq_bass(eq_stim* s, int sr) {
  static const double notes[4] = {41.2, 55.0, 73.42, 98.0};
  eq_alloc(s, "bass", 1.6, sr);
  for (int k = 0; k < 4; ++k) {
    eq_pluck(s->l, s->n, sr, notes[k], 0.4 * k, 1.0);
    eq_pluck(s->r, s->n, sr, notes[3 - k], 0.4 * k, 1.0);
  }
  eq_normalize(s->l, s->n, 0.7);
  eq_normalize(s->r, s->n, 0.5);
}

/* ---- programs: the settings at each block ---- */

typedef struct {
  float base[LE_FX_PARAMS];
  int param;  /* -1: still; else the setting that moves */
  int mode;   /* 0: swept 0 to 1; 1: switched 0, 1 every 100 ms; 2: the
               * cabinet through all twelve, 120 ms each */
  int n, sr;
} eq_prog;

static void eq_prog_at(const eq_prog* g, int frame, float* p) {
  memcpy(p, g->base, sizeof(float) * LE_FX_PARAMS);
  if (g->param < 0) return;
  if (g->mode == 0) {
    p[g->param] = (float)frame / (float)(g->n - 1);
  } else if (g->mode == 1) {
    p[g->param] = (float)((frame / (g->sr / 10)) & 1);
  } else {
    p[g->param] = (float)((frame / (int)(0.12 * g->sr)) % 12) / 11.0f;
  }
}

/* ---- the drivers ---- */

typedef void (*eq_update_fn)(void* ks, le_fx_dyn_head* h, const float* p,
                             int sr, int f);
typedef void (*eq_kernel_fn)(void* ks, float* l, float* r);

/* [s] through [type]'s kernel (the reference's when [ref]), at [block]
 * frames, into [ol] and [or_]. */
static int eq_render(int32_t type, int ref, const eq_stim* s, const eq_prog* g,
                     int sr, int block, float* ol, float* or_) {
  float p[LE_FX_PARAMS];
  if (type == LE_FX_AMP_CAB) {
    le_fx_state* fx = NULL;
    ref_fx_amp* ra = NULL;
    if (ref) {
      ra = ref_amp_new(sr);
      if (ra == NULL) return 0;
    } else {
      fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
      if (fx == NULL || fx_amp_cab_prepare(fx, 0, sr) != LE_OK) {
        free(fx);
        return 0;
      }
    }
    for (int i = 0; i < s->n; ++i) {
      if (i % block == 0) eq_prog_at(g, i, p);
      float l = s->l[i];
      float r = s->r[i];
      if (ref) {
        ref_fx_amp_cab_process(ra, sr, &l, &r, p);
      } else {
        fx_amp_cab_process(fx, 0, sr, sr, &l, &r, p);
      }
      ol[i] = l;
      or_[i] = r;
    }
    if (ref) {
      free(ra);
    } else {
      le_rt_free(atomic_load_explicit(&fx->amp[0], memory_order_relaxed));
      free(fx);
    }
    return 1;
  }
  size_t size;
  eq_update_fn update;
  eq_kernel_fn kernel;
  if (type == LE_FX_OVERDRIVE) {
    size = ref ? sizeof(ref_fx_overdrive) : LE_FX[type].state_size;
    update = ref ? ref_fx_overdrive_update : LE_FX[type].update;
    kernel = ref ? ref_fx_overdrive_kprocess : LE_FX[type].kprocess;
  } else {
    size = ref ? sizeof(ref_fx_distortion) : LE_FX[type].state_size;
    update = ref ? ref_fx_distortion_update : LE_FX[type].update;
    kernel = ref ? ref_fx_distortion_kprocess : LE_FX[type].kprocess;
  }
  /* A kind block's payload is LE_FX_KIND_ALIGN-aligned. */
  const size_t bytes = (size + LE_FX_KIND_ALIGN - 1) & ~(size_t)(LE_FX_KIND_ALIGN - 1);
  void* st = aligned_alloc(LE_FX_KIND_ALIGN, bytes);
  if (st == NULL) return 0;
  memset(st, 0, bytes);
  le_fx_dyn_head h;
  memset(&h, 0, sizeof(h));
  float last[LE_FX_PARAMS] = {0};
  const size_t width = (size_t)le_fx_param_width(type);
  for (int i = 0; i < s->n; ++i) {
    if (i % block == 0) eq_prog_at(g, i, p);
    if (i % LE_FX_UPDATE_FRAMES == 0) {
      const int settle = i == 0;
      update(st, &h, p, sr, le_fx_dyn_begin(&h, last, p, width, sr, settle));
    }
    float l = s->l[i];
    float r = s->r[i];
    kernel(st, &l, &r);
    ol[i] = l;
    or_[i] = r;
  }
  free(st);
  return 1;
}

typedef struct {
  double worst;   /* the largest residual peak, linear */
  int renders;
  int identical;  /* renders bit-identical to the reference */
  int failed;
} eq_tally;

static int g_detail;

/* Both renders of [s] through [type] under [g]; adds to [t]. */
static void eq_compare(int32_t type, const char* what, const eq_stim* s,
                       const eq_prog* g, int sr, int block, eq_tally* t) {
  float* a = (float*)malloc(sizeof(float) * (size_t)s->n * 4);
  float* al = a;
  float* ar = a + s->n;
  float* bl = a + 2 * s->n;
  float* br = a + 3 * s->n;
  if (a == NULL || !eq_render(type, 1, s, g, sr, block, al, ar) ||
      !eq_render(type, 0, s, g, sr, block, bl, br)) {
    printf("  FAIL %s / %s at %d Hz: could not render\n", what, s->name, sr);
    t->failed++;
    free(a);
    return;
  }
  double worst = 0.0;
  double peak = 0.0;
  int finite = 1;
  for (int i = 0; i < 2 * s->n; ++i) {
    if (!isfinite(al[i]) || !isfinite(bl[i])) finite = 0;
    worst = fmax(worst, fabs((double)al[i] - (double)bl[i]));
    peak = fmax(peak, fabs((double)al[i]));
  }
  t->renders++;
  if (worst == 0.0) t->identical++;
  if (worst > t->worst) t->worst = worst;
  const int bad = !finite || worst >= EQ_LIMIT || peak < 1e-4;
  if (bad) t->failed++;
  if (bad || g_detail) {
    char res[32];
    if (worst > 0.0) {
      snprintf(res, sizeof(res), "%.1f dBFS", 20.0 * log10(worst));
    } else {
      snprintf(res, sizeof(res), "none");
    }
    printf("  %s %s / %s at %d Hz, %d frames: residual %s (peak %.1f dBFS)%s\n",
           bad ? "FAIL" : "    ", what, s->name, sr, block, res,
           20.0 * log10(fmax(peak, 1e-12)), finite ? "" : ", not finite");
  }
  free(a);
}

static const char* eq_kind_name(int32_t type) {
  return type == LE_FX_OVERDRIVE    ? "overdrive"
         : type == LE_FX_DISTORTION ? "distortion"
                                    : "ampcab";
}

int main(int argc, char** argv) {
  int full = 0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--full")) {
      full = 1;
    } else if (!strcmp(argv[i], "--detail")) {
      g_detail = 1;
    } else {
      fprintf(stderr, "usage: %s [--full] [--detail]\n", argv[0]);
      return 2;
    }
  }
  /* The engine renders with denormals flushed, live and offline. */
  le_flush_denormals();
  static const int32_t kinds[3] = {LE_FX_OVERDRIVE, LE_FX_DISTORTION,
                                   LE_FX_AMP_CAB};
  int failed = 0;
  printf("test_fx_drives_equiv: the drives and the amp against their kernels "
         "before #1755, limit %.0f dBFS%s\n",
         20.0 * log10(EQ_LIMIT), full ? ", full" : "");
  for (int k = 0; k < 3; ++k) {
    const int32_t type = kinds[k];
    for (int ri = 0; ri < (full ? EQ_NRATES : 4); ++ri) {
      const int sr = k_rates[ri];
      g_lcg = 12345u + (uint32_t)sr; /* the same takes in either run */
      eq_tally t;
      memset(&t, 0, sizeof(t));
      eq_stim st[6];
      eq_sweep(&st[0], "sweep -24 dBFS", -24.0, sr);
      eq_sweep(&st[1], "sweep -6 dBFS", -6.0, sr);
      eq_sweep(&st[2], "sweep 0 dBFS", 0.0, sr);
      eq_impulses(&st[3], sr);
      eq_guitar(&st[4], sr, 2.0);
      eq_bass(&st[5], sr);
      const eq_stim* guitar = &st[4];
      eq_prog g;
      memset(&g, 0, sizeof(g));
      g.sr = sr;
      /* The extremes on every stimulus. */
      for (size_t e = 0; e < sizeof(k_extremes) / sizeof(k_extremes[0]); ++e) {
        if (k_extremes[e].type != type) continue;
        memcpy(g.base, k_extremes[e].p, sizeof(g.base));
        g.param = -1;
        for (int si = 0; si < 6; ++si) {
          g.n = st[si].n;
          eq_compare(type, k_extremes[e].name, &st[si], &g, sr, 32, &t);
        }
      }
      /* Every factory setting on the guitar. */
      if (full || sr == 48000) {
        for (size_t f = 0; f < sizeof(k_factory) / sizeof(k_factory[0]); ++f) {
          if (k_factory[f].type != type) continue;
          memcpy(g.base, k_factory[f].p, sizeof(g.base));
          g.param = -1;
          g.n = guitar->n;
          eq_compare(type, k_factory[f].name, guitar, &g, sr, 32, &t);
        }
      }
      /* Each setting swept and switched, at 32 and 64 frames, from the
       * kind's default (le_fx_defaults); the cabinet also stepped. */
      float def[LE_FX_PARAMS] = {0};
      le_fx_defaults(type, def);
      const int width = le_fx_param_width(type);
      for (int q = 0; q < width; ++q) {
        for (int mode = 0; mode < 3; ++mode) {
          if (mode == 2 && !(type == LE_FX_AMP_CAB && q == 4)) continue;
          for (int b = 0; b < 2; ++b) {
            char what[64];
            snprintf(what, sizeof(what), "%s setting %d %s", eq_kind_name(type),
                     q, mode == 0 ? "swept" : mode == 1 ? "switched" : "stepped");
            memcpy(g.base, def, sizeof(g.base));
            g.param = q;
            g.mode = mode;
            g.n = guitar->n;
            eq_compare(type, what, guitar, &g, sr, b ? 64 : 32, &t);
          }
        }
      }
      char worst[32];
      if (t.worst > 0.0) {
        snprintf(worst, sizeof(worst), "%.1f dBFS", 20.0 * log10(t.worst));
      } else {
        snprintf(worst, sizeof(worst), "none");
      }
      printf("%-10s %6d Hz: %3d renders, %3d bit-identical, worst residual "
             "%s%s\n",
             eq_kind_name(type), sr, t.renders, t.identical, worst,
             t.failed ? "  FAILED" : "");
      failed += t.failed;
      for (int si = 0; si < 6; ++si) eq_free(&st[si]);
    }
  }
  if (failed) {
    printf("test_fx_drives_equiv: %d renders FAILED\n", failed);
    return 1;
  }
  printf("test_fx_drives_equiv: ALL PASSED\n");
  return 0;
}
