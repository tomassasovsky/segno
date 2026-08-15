/*
 * engine_cond.c — the per-input conditioning stage (input conditioning, S1).
 *
 * One fixed utility stage per hardware input: 2nd-order Butterworth high-pass
 * -> mains-hum notch bank (up to LE_COND_HUM_MAX fixed-Q notches at integer
 * multiples of the mains base) -> downward expander (abs -> one-pole envelope
 * -> polynomial under-threshold gain law). Applied once per block into the
 * engine's conditioned input copy, upstream of BOTH the lane fan-out and the
 * monitor split (engine_process.c owns the placement; this TU owns the DSP).
 *
 * Hard design rule: ZERO added buffering latency. Everything here is IIR or a
 * no-lookahead envelope follower — no FIR, no delay line — so the stage never
 * contributes to fx_added_latency_frames and record_offset semantics are
 * untouched.
 *
 * Threading: le_cond_seed_defaults runs on the control thread at configure
 * (device closed). le_cond_prepare / le_cond_update_param run ON the audio
 * thread (apply_command), which is the sole owner of the derived DSP state;
 * the published atomics exist so the control side (and, in S2, the snapshot)
 * can read back the stage's config without touching that state.
 */
#include <math.h>

#include "engine_core.h"
#include "engine_private.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Notch selectivity: fixed Q ~30 => ~1.7 Hz bandwidth at a 50 Hz base — deep
 * on the hum, inaudible one semitone away. */
#define LE_COND_NOTCH_Q 30.0f

/* HPF selectivity: Butterworth (maximally flat passband). */
#define LE_COND_HPF_Q 0.70710678f

static void le_cond_biquad_clear(le_cond_biquad* q) {
  q->s1 = 0.0f;
  q->s2 = 0.0f;
}

/* RBJ cookbook high-pass, a0-normalized. */
static void le_cond_hpf_coeffs(le_cond_biquad* q, float fc, float sr) {
  const float w0 = 2.0f * (float)M_PI * fc / sr;
  const float cw = cosf(w0);
  const float sw = sinf(w0);
  const float alpha = sw / (2.0f * LE_COND_HPF_Q);
  const float a0 = 1.0f + alpha;
  q->b0 = (1.0f + cw) * 0.5f / a0;
  q->b1 = -(1.0f + cw) / a0;
  q->b2 = (1.0f + cw) * 0.5f / a0;
  q->a1 = -2.0f * cw / a0;
  q->a2 = (1.0f - alpha) / a0;
}

/* RBJ cookbook notch, a0-normalized. */
static void le_cond_notch_coeffs(le_cond_biquad* q, float fc, float sr) {
  const float w0 = 2.0f * (float)M_PI * fc / sr;
  const float cw = cosf(w0);
  const float sw = sinf(w0);
  const float alpha = sw / (2.0f * LE_COND_NOTCH_Q);
  const float a0 = 1.0f + alpha;
  q->b0 = 1.0f / a0;
  q->b1 = -2.0f * cw / a0;
  q->b2 = 1.0f / a0;
  q->a1 = -2.0f * cw / a0;
  q->a2 = (1.0f - alpha) / a0;
}

static inline float le_cond_biquad_run(le_cond_biquad* q, float x) {
  const float y = q->b0 * x + q->s1;
  q->s1 = q->b1 * x - q->a1 * y + q->s2;
  q->s2 = q->b2 * x - q->a2 * y;
  return y;
}

/* One-pole coefficient for a time constant of [ms] at [sr]. */
static float le_cond_pole(float ms, float sr) {
  if (ms <= 0.0f || sr <= 0.0f) return 1.0f;
  const float c = 1.0f - expf(-1.0f / (ms * 0.001f * sr));
  return c > 1.0f ? 1.0f : (c < 1e-6f ? 1e-6f : c);
}

/* ---- per-section recompute (audio thread; also control at configure) ---- */

static void le_cond_update_hpf(le_input_cond* c, float sr) {
  float fc = load_f32(&c->a_hpf_hz_bits);
  c->hpf_on = fc > 0.0f && sr > 0.0f;
  if (c->hpf_on) {
    /* Keep the section well inside Nyquist whatever the rate. */
    const float cap = 0.45f * sr;
    if (fc > cap) fc = cap;
    le_cond_hpf_coeffs(&c->hpf, fc, sr);
  }
  le_cond_biquad_clear(&c->hpf);
}

static void le_cond_update_hum(le_input_cond* c, float sr) {
  const float base = load_f32(&c->a_hum_hz_bits);
  int32_t harmonics = load_i32(&c->a_hum_harmonics);
  if (harmonics < 1) harmonics = 1;
  if (harmonics > LE_COND_HUM_MAX) harmonics = LE_COND_HUM_MAX;
  c->hum_n = 0;
  if (base > 0.0f && sr > 0.0f) {
    for (int32_t k = 1; k <= harmonics; ++k) {
      const float fc = base * (float)k;
      if (fc >= 0.45f * sr) break; /* notches above ~Nyquist are dropped */
      le_cond_notch_coeffs(&c->hum[c->hum_n], fc, sr);
      ++c->hum_n;
    }
  }
  for (int k = 0; k < LE_COND_HUM_MAX; ++k) le_cond_biquad_clear(&c->hum[k]);
}

static void le_cond_update_exp(le_input_cond* c, float sr) {
  const float thr_db = load_f32(&c->a_exp_threshold_db_bits);
  const float ratio = load_f32(&c->a_exp_ratio_bits);
  const float rel_ms = load_f32(&c->a_exp_release_ms_bits);
  c->thr_lin = powf(10.0f, thr_db / 20.0f);
  c->thr_inv = c->thr_lin > 0.0f ? 1.0f / c->thr_lin : 0.0f;
  c->atk_coef = le_cond_pole(LE_COND_ATTACK_MS, sr);
  c->rel_coef = le_cond_pole(rel_ms, sr);
  /* Under-threshold gain law: for ratio 1:R the settled output level is
   * thr * u^R where u = env/thr in (0, 1] — i.e. gain = u^(R-1), quadratic
   * OUTPUT under threshold at the default R = 2. Split R-1 into integer
   * powers + a linear blend for the fractional part so the per-sample cost
   * is a handful of multiplies (no log/exp per sample), exact at integer
   * ratios and monotone everywhere. R <= 1 turns the section off (unity). */
  float rm1 = ratio - 1.0f;
  c->exp_on = rm1 > 0.0f && c->thr_lin > 0.0f;
  if (rm1 < 0.0f) rm1 = 0.0f;
  c->exp_pow = (int)rm1; /* ratio is clamped to <= 10 on apply */
  c->exp_frac = rm1 - (float)c->exp_pow;
  /* NOT resetting env here: a live threshold/ratio/release tweak retunes the
   * gain law but the follower keeps tracking the signal it already sees. */
}

/* ---- public seams (engine_core.h) ---- */

void le_cond_prepare(le_input_cond* c, int sample_rate) {
  const float sr = (float)(sample_rate > 0 ? sample_rate : 48000);
  le_cond_update_hpf(c, sr);
  le_cond_update_hum(c, sr);
  le_cond_update_exp(c, sr);
  c->env = 0.0f;
}

void le_cond_seed_defaults(le_input_cond* c, int sample_rate) {
  store_i32(&c->a_enabled, 0);
  store_f32(&c->a_hpf_hz_bits, LE_COND_DEF_HPF_HZ);
  store_f32(&c->a_hum_hz_bits, LE_COND_DEF_HUM_HZ);
  store_i32(&c->a_hum_harmonics, LE_COND_DEF_HUM_HARMONICS);
  store_f32(&c->a_exp_threshold_db_bits, LE_COND_DEF_EXP_THRESHOLD_DB);
  store_f32(&c->a_exp_ratio_bits, LE_COND_DEF_EXP_RATIO);
  store_f32(&c->a_exp_release_ms_bits, LE_COND_DEF_EXP_RELEASE_MS);
  le_cond_prepare(c, sample_rate);
}

void le_cond_update_param(le_input_cond* c, int32_t param, float value,
                          int sample_rate) {
  const float sr = (float)(sample_rate > 0 ? sample_rate : 48000);
  switch (param) {
    case LE_COND_HPF_HZ:
      if (value < 0.0f) value = 0.0f;
      if (value > 2000.0f) value = 2000.0f;
      store_f32(&c->a_hpf_hz_bits, value);
      le_cond_update_hpf(c, sr);
      break;
    case LE_COND_HUM_HZ:
      if (value < 0.0f) value = 0.0f;
      if (value > 500.0f) value = 500.0f;
      store_f32(&c->a_hum_hz_bits, value);
      le_cond_update_hum(c, sr);
      break;
    case LE_COND_HUM_HARMONICS: {
      int32_t n = (int32_t)value;
      if (n < 1) n = 1;
      if (n > LE_COND_HUM_MAX) n = LE_COND_HUM_MAX;
      store_i32(&c->a_hum_harmonics, n);
      le_cond_update_hum(c, sr);
      break;
    }
    case LE_COND_EXP_THRESHOLD_DB:
      if (value < -120.0f) value = -120.0f;
      if (value > 0.0f) value = 0.0f;
      store_f32(&c->a_exp_threshold_db_bits, value);
      le_cond_update_exp(c, sr);
      break;
    case LE_COND_EXP_RATIO:
      if (value < 1.0f) value = 1.0f;
      if (value > 10.0f) value = 10.0f;
      store_f32(&c->a_exp_ratio_bits, value);
      le_cond_update_exp(c, sr);
      break;
    case LE_COND_EXP_RELEASE_MS:
      if (value < 1.0f) value = 1.0f;
      if (value > 5000.0f) value = 5000.0f;
      store_f32(&c->a_exp_release_ms_bits, value);
      le_cond_update_exp(c, sr);
      break;
    default:
      break; /* unknown param: dropped (control side validates too) */
  }
}

void le_cond_process_block(le_input_cond* c, float* buf, uint32_t frames,
                           int32_t stride) {
  const int hpf_on = c->hpf_on;
  const int hum_n = c->hum_n;
  const int exp_on = c->exp_on;
  for (uint32_t f = 0; f < frames; ++f) {
    float x = buf[(size_t)f * (size_t)stride];
    if (hpf_on) x = le_cond_biquad_run(&c->hpf, x);
    for (int k = 0; k < hum_n; ++k) x = le_cond_biquad_run(&c->hum[k], x);
    if (exp_on) {
      const float a = fabsf(x);
      c->env += (a > c->env ? c->atk_coef : c->rel_coef) * (a - c->env);
      if (c->env < c->thr_lin) {
        float u = c->env * c->thr_inv; /* (0, 1) under threshold */
        if (u < 0.0f) u = 0.0f;
        float p = 1.0f;
        for (int k = 0; k < c->exp_pow; ++k) p *= u; /* u^floor(R-1) */
        float g = p * (1.0f - c->exp_frac + c->exp_frac * u);
        if (g > 1.0f) g = 1.0f;
        x *= g;
      }
    }
    buf[(size_t)f * (size_t)stride] = x;
  }
}
