/*
 * restore_declip.c — offline de-clip DSP (loop-close restoration, #697 S8).
 *
 * Contract and constants: restore_declip.h. Shape of the algorithm:
 *
 *   1. DETECT: scan for runs of consecutive same-polarity samples at or
 *      beyond the rail (seed at clip_level, grow with hysteresis over the
 *      smeared shoulder samples down to clip_level * LE_DECLIP_HYST).
 *   2. CLASSIFY: edge-touching or over-long runs pass through (conservative
 *      bounds, header); short runs -> Hermite spline; long runs -> Burg AR
 *      with spline fallback when context is too poor for a fit.
 *   3. RECONSTRUCT:
 *      - Spline: cubic Hermite between the shoulders, tangents from the two
 *        samples outside each shoulder — the entry slope carries the wave up
 *        past the rail, the exit slope brings it back down.
 *      - AR (Janssen-style, two sweeps folded into one): copy up to
 *        LE_DECLIP_CTX samples of context per side, Hermite-fill any railed
 *        runs inside the COPY (so the model learns the signal, not the
 *        neighboring peaks' flat rails — left of the cursor the buffer is
 *        normally already repaired in place, runs process left to right),
 *        Burg-fit each side, extrapolate forward from the left and backward
 *        from the right (time-reversed fit), and raised-cosine crossfade
 *        across the gap so each seam is continued by the model that
 *        actually saw it.
 *   4. BOUND: every repaired sample is floored at the original rail value it
 *      replaces (the true signal was provably beyond the rail there) and
 *      capped at LE_DECLIP_CLAMP_X * clip_level, so no model output — not
 *      even a diverging AR on pathological input — can exceed +6 dB over
 *      full scale or dip back under the rail.
 *
 * Determinism: straight-line float/double arithmetic, no allocation (the
 * caller's scratch is the only working memory), no globals, no threads.
 */
#include <math.h>
#include <stddef.h>

#include "restore_declip.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Minimum per-side usable context for the AR path; below this the fit would
 * be mush, so the run falls back to the spline. */
#define LE_DECLIP_MIN_CTX 32

/* Floor-and-cap for one repaired sample (header: CONSERVATIVE BOUND). `orig`
 * is the rail-flattened sample being replaced. A non-finite model value
 * (impossible for the spline, defense-in-depth for AR) collapses to `orig` —
 * i.e. that sample passes through. */
static float le_declip_bound(float v, float orig, int positive,
                             float clip_level) {
  const float cap = LE_DECLIP_CLAMP_X * clip_level;
  if (!isfinite(v)) return orig;
  if (positive) {
    if (v < orig) v = orig;
    if (v > cap) v = cap;
  } else {
    if (v > orig) v = orig;
    if (v < -cap) v = -cap;
  }
  return v;
}

/* Cubic Hermite across [start, end] (inclusive), anchored on the shoulder
 * samples just outside the run with tangents taken from their outer
 * neighbors. Caller guarantees start >= 2 and end <= n - 3. */
static void le_declip_hermite(float* buf, uint32_t start, uint32_t end,
                              int positive, float clip_level) {
  const float x0 = buf[start - 1];
  const float x1 = buf[end + 1];
  const float span = (float)(end - start + 2); /* run length + 1 steps */
  const float m0 = (buf[start - 1] - buf[start - 2]) * span;
  const float m1 = (buf[end + 2] - buf[end + 1]) * span;
  uint32_t i;
  for (i = start; i <= end; ++i) {
    const float u = (float)(i - (start - 1)) / span;
    const float u2 = u * u;
    const float u3 = u2 * u;
    const float h = (2.0f * u3 - 3.0f * u2 + 1.0f) * x0 +
                    (u3 - 2.0f * u2 + u) * m0 +
                    (-2.0f * u3 + 3.0f * u2) * x1 + (u3 - u2) * m1;
    buf[i] = le_declip_bound(h, buf[i], positive, clip_level);
  }
}

/* Detects the railed runs inside a context COPY and Hermite-fills the
 * fillable ones, so the AR fit sees a continuous plausible signal instead of
 * flat rails. Runs that lack in-window spline anchors truncate the usable
 * part instead: with keep_suffix (a LEFT window, gap just past the window's
 * end) everything up to and including such a run is dropped; without it (a
 * RIGHT window, gap just before index 0) the window ends in front of it.
 * Returns the usable length; *off_out (keep_suffix only) is its offset. */
static uint32_t le_declip_fill_ctx(float* w, uint32_t len, float clip_level,
                                   int keep_suffix, uint32_t* off_out) {
  const float lo = clip_level * LE_DECLIP_HYST;
  uint32_t off = 0;
  uint32_t usable = len;
  uint32_t wmin = 0;
  uint32_t i = 0;
  while (i < len) {
    const float v = w[i];
    uint32_t s;
    uint32_t e;
    int positive;
    if (v < clip_level && v > -clip_level) {
      ++i;
      continue;
    }
    positive = (v > 0.0f);
    s = i;
    e = i;
    while (s > wmin && (positive ? w[s - 1] >= lo : w[s - 1] <= -lo)) --s;
    while (e + 1 < len && (positive ? w[e + 1] >= lo : w[e + 1] <= -lo)) ++e;
    if (s >= 2 && e + 3 <= len) {
      le_declip_hermite(w, s, e, positive, clip_level);
    } else if (keep_suffix) {
      off = e + 1;
    } else {
      usable = s;
      break;
    }
    wmin = e + 1;
    i = e + 1;
  }
  if (off_out != NULL) *off_out = off;
  return keep_suffix ? len - off : usable;
}

/* Burg's method: fit an AR model to x[0..n-1], writing the polynomial into
 * a[0..order] (a[0] = 1). f/b are caller scratch of length >= n. Returns the
 * effective order actually fitted (< order when the recursion stopped
 * early — see the residual threshold below).
 *
 * Numerics, both load-bearing at 96 kHz:
 * - Everything is DOUBLE. Oversampled low-frequency content has reflection
 *   coefficients within 1e-5 of the unit circle; float resolution there
 *   corrupts stage 1 and every stage after it inherits the error.
 * - Burg guarantees |k| < 1 in exact arithmetic; the clamp only papers over
 *   the last bits of rounding, so it must sit essentially AT 1 (a tighter
 *   clamp like 0.999 would truncate those legitimate near-unit k's). */
static int le_declip_burg(const float* x, int n, int order, double* a,
                          double* f, double* b) {
  int i;
  int m;
  int p = order;
  double e0 = 0.0;
  if (p > n / 2) p = n / 2;
  if (p < 1) return 0;
  for (i = 0; i < n; ++i) {
    f[i] = x[i];
    b[i] = x[i];
    e0 += (double)x[i] * (double)x[i];
  }
  a[0] = 1.0;
  for (i = 1; i <= order; ++i) a[i] = 0.0;
  for (m = 1; m <= p; ++m) {
    double num = 0.0;
    double den = 0.0;
    double k;
    double tmp[LE_DECLIP_ORDER + 1];
    int j;
    for (i = m; i < n; ++i) {
      num += f[i] * b[i - 1];
      den += f[i] * f[i] + b[i - 1] * b[i - 1];
    }
    /* Stop once the residual sits 70 dB below the context energy: the model
     * already explains the signal to far below audibility, and every
     * further stage would fit the data's own float quantization noise
     * (measured: a float-quantized pure sine at 96 k leaves ~-76 dB
     * relative residual after its two true poles), whose noise-fit
     * reflection coefficients near +/-1 compound into an unstable
     * polynomial. Relative, not absolute — "negligible" scales with the
     * signal. */
    if (den <= 1e-30 + e0 * 1e-7) return m - 1;
    k = -2.0 * num / den;
    if (k > 1.0 - 1e-9) k = 1.0 - 1e-9;
    if (k < -(1.0 - 1e-9)) k = -(1.0 - 1e-9);
    for (j = 1; j < m; ++j) tmp[j] = a[j] + k * a[m - j];
    for (j = 1; j < m; ++j) a[j] = tmp[j];
    a[m] = k;
    for (i = n - 1; i >= m; --i) {
      const double fi = f[i];
      const double bi = b[i - 1];
      f[i] = fi + k * bi;
      b[i] = bi + k * fi;
    }
  }
  return p;
}

/* Extrapolate `gap` samples past the end of `ctx` with an order-p AR model:
 * out[0..p-1] is seeded with the last p context samples, out[p..p+gap-1]
 * receives the predictions. */
static void le_declip_predict(const float* ctx, int ctx_len, int p,
                              const double* a, int gap, double* out) {
  int i;
  int j;
  for (i = 0; i < p; ++i) out[i] = ctx[ctx_len - p + i];
  for (i = 0; i < gap; ++i) {
    double acc = 0.0;
    for (j = 1; j <= p; ++j) acc -= a[j] * out[p + i - j];
    out[p + i] = acc;
  }
}

/* Long-run repair: two AR extrapolations crossfaded across the gap.
 * Returns 1 when the run was repaired, 0 when either side lacked usable
 * context (caller falls back to the spline). */
static int le_declip_ar(float* buf, uint32_t n, uint32_t start, uint32_t end,
                        int positive, float clip_level,
                        le_declip_scratch* s) {
  const int len = (int)(end - start + 1);
  uint32_t wl = start > LE_DECLIP_CTX ? LE_DECLIP_CTX : start;
  uint32_t wr =
      (n - 1 - end) > LE_DECLIP_CTX ? LE_DECLIP_CTX : (n - 1 - end);
  uint32_t off = 0;
  uint32_t ctx_l;
  uint32_t ctx_r;
  int p_l;
  int p_r;
  int i;

  /* Forward: copy the window preceding the run, fill residual rails in the
   * copy, fit, extrapolate into the gap. */
  for (i = 0; i < (int)wl; ++i) s->ctx[i] = buf[start - wl + (uint32_t)i];
  ctx_l = le_declip_fill_ctx(s->ctx, wl, clip_level, 1, &off);
  if (ctx_l < LE_DECLIP_MIN_CTX) return 0;
  p_l = le_declip_burg(s->ctx + off, (int)ctx_l, LE_DECLIP_ORDER, s->a, s->f,
                       s->b);
  le_declip_predict(s->ctx + off, (int)ctx_l, p_l, s->a, len, s->fwd);

  /* Backward: same on the window following the run, then time-reverse it —
   * "forward" prediction in reversed time walks backward into the gap. */
  for (i = 0; i < (int)wr; ++i) s->ctx[i] = buf[end + 1 + (uint32_t)i];
  ctx_r = le_declip_fill_ctx(s->ctx, wr, clip_level, 0, NULL);
  if (ctx_r < LE_DECLIP_MIN_CTX) return 0;
  for (i = 0; i < (int)ctx_r; ++i) s->rev[i] = s->ctx[ctx_r - 1 - (uint32_t)i];
  p_r = le_declip_burg(s->rev, (int)ctx_r, LE_DECLIP_ORDER, s->a, s->f, s->b);
  le_declip_predict(s->rev, (int)ctx_r, p_r, s->a, len, s->bwd);

  /* Raised-cosine crossfade: the left model owns the left seam, the right
   * model owns the right seam. bwd[] is in reversed time, so gap index i
   * reads its prediction (len - 1 - i). p_{l,r} can be 0 (constant context
   * fits nothing); the prediction is then 0 everywhere — the bound below
   * floors that at the rail. */
  for (i = 0; i < len; ++i) {
    const double w =
        0.5 * (1.0 - cos(M_PI * (double)(i + 1) / (double)(len + 1)));
    const double v =
        (1.0 - w) * s->fwd[p_l + i] + w * s->bwd[p_r + (len - 1 - i)];
    buf[start + (uint32_t)i] = le_declip_bound(
        (float)v, buf[start + (uint32_t)i], positive, clip_level);
  }
  return 1;
}

int32_t le_declip_process(float* buf, uint32_t n, float clip_level,
                          le_declip_scratch* scratch) {
  int32_t repaired = 0;
  uint32_t i = 0;
  uint32_t min_start = 0;
  float lo;
  if (buf == NULL || scratch == NULL || n == 0 || !(clip_level > 0.0f)) {
    return -1;
  }
  lo = clip_level * LE_DECLIP_HYST;
  while (i < n) {
    const float v = buf[i];
    uint32_t start;
    uint32_t end;
    uint32_t len;
    int positive;
    if (v < clip_level && v > -clip_level) {
      ++i;
      continue;
    }
    /* Seed found: grow with hysteresis over same-polarity shoulders. The
     * left growth stops at min_start so it can never re-enter the previous
     * run's repaired samples (whose values now exceed the rail). */
    positive = (v > 0.0f);
    start = i;
    end = i;
    while (start > min_start &&
           (positive ? buf[start - 1] >= lo : buf[start - 1] <= -lo)) {
      --start;
    }
    while (end + 1 < n &&
           (positive ? buf[end + 1] >= lo : buf[end + 1] <= -lo)) {
      ++end;
    }
    len = end - start + 1;

    if (start == 0 || end == n - 1 || len > LE_DECLIP_MAX_RUN) {
      /* Edge-touching (no context on one side) or sustained clipping:
       * pass through, per the header's conservative bounds. */
    } else {
      int done = 0;
      if (len > LE_DECLIP_SHORT_RUN) {
        done = le_declip_ar(buf, n, start, end, positive, clip_level,
                            scratch);
      }
      if (!done && start >= 2 && end <= n - 3) {
        /* Short run — or a long one without enough usable context for an
         * AR fit — takes the spline, which only needs two samples per
         * side. */
        le_declip_hermite(buf, start, end, positive, clip_level);
        done = 1;
      }
      if (done) ++repaired;
    }

    min_start = end + 1;
    i = end + 1;
  }
  return repaired;
}
