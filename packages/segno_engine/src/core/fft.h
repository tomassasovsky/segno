/*
 * fft.h — header-only real FFT for the phase vocoder.
 *
 * A pure, self-contained transform with no engine coupling: every function is
 * `static` and the caller owns all buffers (no malloc, no platform headers).
 * Header-only means no new translation unit — it is #included by exactly one
 * engine TU (the phase vocoder's engine_fx.c; the native test and the pitch
 * bench include it too), so the static functions never multiply-define and
 * never sit unused.
 *
 * WHY IT IS BUILT THIS WAY (#1410). The octaver runs four length-1024 real
 * transforms per channel in one sample tick, so their whole cost lands in one
 * callback. A full-length complex FFT whose twiddles came from a running
 * rotation cost ~30 us per transform on the console's Cortex-A76: one stereo
 * octaver frame was ~290 us of a 667 us period, and two sharing a callback
 * missed the deadline. This uses the two standard reductions (FFTW, KissFFT's
 * kiss_fftr and pffft all make them):
 *   - a real length-n signal is transformed as a length-n/2 COMPLEX one (even
 *     samples real, odd samples imaginary) and split into the half spectrum
 *     in one O(n) pass, which halves the butterflies;
 *   - every twiddle comes from a table built once off the audio thread
 *     (le_rfft_plan_init), laid out stage by stage so each butterfly loop
 *     reads it contiguously: no serial rotation chain, and the loop
 *     vectorises.
 *
 * THE NEON PATH (#1755). The phase vocoder's decisions (which bins are
 * peaks, which region sets a bin's phase) read the spectrum, so a transform
 * that rounds one bin differently changes what it plays: a faster FFT has to
 * give the same floats. On arm64 under Clang (the console's compiler) the
 * transforms run on NEON, four butterflies at a time, with each butterfly,
 * split and merge computing exactly what the scalar code below computes,
 * fused where Clang fuses it (-ffp-contract=on: in a sum or difference of
 * two products the first product is fused, the second rounded; noted at
 * each) and nowhere else. What changes is only the order in which
 * independent butterflies run: the bit reversal from a table, folded into
 * the forward's load; the first two stages done together on groups of four
 * points; and the later stages two at a time on groups of four quarter
 * blocks, so each point is loaded once a pair of stages. The scalar code is
 * the other compilers' path and the reference the native tests compare the
 * NEON one to (test_fft_neon_matches_scalar).
 *
 * Pure C11; compiles under MSVC (/std:c11), Clang, and GCC.
 */
#ifndef SEGNO_FFT_H
#define SEGNO_FFT_H

#include <math.h>
#include <stdint.h>

#if defined(__aarch64__) && defined(__clang__)
#include <arm_neon.h>
#define LE_FFT_NEON 1
#else
#define LE_FFT_NEON 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define LE_FFT_PI 3.14159265358979323846f

/* Upper bound on the real transform length a plan can hold. The phase vocoder
 * uses n = 1024. The inverse's stack scratch is LE_FFT_MAX_N floats. A TU that
 * needs longer transforms off the audio thread (the pitch bench's analysis)
 * defines a larger bound before including this header; the plan type is
 * private to each TU, so the bounds never have to agree. */
#ifndef LE_FFT_MAX_N
#define LE_FFT_MAX_N 4096
#endif
_Static_assert(LE_FFT_MAX_N / 2 <= 65536, "the bit reversal table is 16-bit");

/* The tables for one real transform length. Filled by le_rfft_plan_init on a
 * non-real-time thread and read-only afterwards, so one plan serves any number
 * of instances and threads. */
typedef struct le_rfft_plan {
  int n; /* real length; 0 = not built */
  /* Twiddles of the length-n/2 complex FFT, stage by stage: the stage whose
   * butterflies span 2h points reads exp(-2 pi i k / 2h), k < h, from offset
   * h - 1. n/2 - 1 entries in all. st_imn is st_im negated. */
  float st_re[LE_FFT_MAX_N / 2];
  float st_im[LE_FFT_MAX_N / 2];
  float st_imn[LE_FFT_MAX_N / 2];
  /* The split twiddles W^k = exp(-2 pi i k / n), k = 0 .. n/2. */
  float sp_re[LE_FFT_MAX_N / 2 + 1];
  float sp_im[LE_FFT_MAX_N / 2 + 1];
  /* rev[i]: i with its log2(n/2) bits reversed. */
  uint16_t rev[LE_FFT_MAX_N / 2];
} le_rfft_plan;

/* Builds [p] for real length [n] (a power of two, 4 .. LE_FFT_MAX_N). A no-op
 * when [p] already holds n. Returns 1 when [p] holds a plan for n, 0 for a bad
 * n. Not real-time safe (double-precision trig), and not synchronised: a plan
 * shared between threads must be built once before any of them reads it
 * (engine_fx.c builds its plan under pthread_once). */
static int le_rfft_plan_init(le_rfft_plan* p, int n) {
  if (n < 4 || n > LE_FFT_MAX_N || (n & (n - 1)) != 0) return 0;
  if (p->n == n) return 1;
  const double pi = 3.14159265358979323846;
  const int m = n / 2;
  for (int h = 1; h < m; h <<= 1) {
    for (int k = 0; k < h; ++k) {
      const double a = -pi * (double)k / (double)h;
      p->st_re[h - 1 + k] = (float)cos(a);
      p->st_im[h - 1 + k] = (float)sin(a);
      p->st_imn[h - 1 + k] = -p->st_im[h - 1 + k];
    }
  }
  for (int k = 0; k <= m; ++k) {
    const double a = -2.0 * pi * (double)k / (double)n;
    p->sp_re[k] = (float)cos(a);
    p->sp_im[k] = (float)sin(a);
  }
  /* The bit-reversal counter le_fft_half's swap walked before the table. */
  p->rev[0] = 0;
  for (int i = 1, j = 0; i < m; ++i) {
    int bit = m >> 1;
    for (; j & bit; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    p->rev[i] = (uint16_t)j;
  }
  p->n = n;
  return 1;
}

/* The Danielson–Lanczos butterflies of the length-m complex FFT on input
 * already in bit-reversed order, doubling the sub-transform length each
 * pass; the inverse conjugates the twiddles. The scalar path. */
static void le_fft_stages_scalar(const le_rfft_plan* p, float* re, float* im,
                                 int inverse) {
  const int m = p->n / 2;
  const float sgn = inverse ? -1.0f : 1.0f;
  for (int h = 1; h < m; h <<= 1) {
    const float* wr = p->st_re + (h - 1);
    const float* wi = p->st_im + (h - 1);
    for (int i = 0; i < m; i += 2 * h) {
      float* ar = re + i;
      float* ai = im + i;
      float* br = ar + h;
      float* bi = ai + h;
      for (int k = 0; k < h; ++k) {
        const float c = wr[k];
        const float s = sgn * wi[k];
        const float vr = br[k] * c - bi[k] * s;
        const float vi = br[k] * s + bi[k] * c;
        br[k] = ar[k] - vr;
        bi[k] = ai[k] - vi;
        ar[k] += vr;
        ai[k] += vi;
      }
    }
  }
}

#if LE_FFT_NEON
/* One butterfly on four lanes, as the scalar one: v = b * w (vr = br c -
 * bi s, the br c product fused; vi = br s + bi c, the br s product fused),
 * then b = a - v and a = a + v. [sn] is -s: bi (-s) is -(bi s) exactly. */
#define LE_FFT_BFLY(ar, ai, br, bi, c, s, sn)                       \
  do {                                                              \
    const float32x4_t vr_ = vfmaq_f32(vmulq_f32((bi), (sn)), (br), (c)); \
    const float32x4_t vi_ = vfmaq_f32(vmulq_f32((bi), (c)), (br), (s));  \
    (br) = vsubq_f32((ar), vr_);                                    \
    (bi) = vsubq_f32((ai), vi_);                                    \
    (ar) = vaddq_f32((ar), vr_);                                    \
    (ai) = vaddq_f32((ai), vi_);                                    \
  } while (0)

/* le_fft_stages_scalar's butterflies, the same ones on the same points, run
 * four at a time: stages 1 and 2 on groups of four points (m >= 16), then
 * stages h and 2h together on groups of four h-long quarters, and a last
 * stage alone when the count is odd. */
static void le_fft_stages_neon(const le_rfft_plan* p, float* re, float* im,
                               int inverse) {
  const int m = p->n / 2;
  /* The twiddle's imaginary part s and -s: the forward's s is st_im, the
   * inverse's -st_im (the scalar sgn * wi, exact either way). */
  const float* ts = inverse ? p->st_imn : p->st_im;
  const float* tsn = inverse ? p->st_im : p->st_imn;
  {
    /* Stage 1 (h = 1, k = 0) and stage 2 (h = 2, k = 0 and 1); lane g of
     * val[q] is point q of the g-th group of four. */
    const float32x4_t c1 = vdupq_n_f32(p->st_re[0]);
    const float32x4_t s1 = vdupq_n_f32(ts[0]);
    const float32x4_t n1 = vdupq_n_f32(tsn[0]);
    const float32x4_t c20 = vdupq_n_f32(p->st_re[1]);
    const float32x4_t s20 = vdupq_n_f32(ts[1]);
    const float32x4_t n20 = vdupq_n_f32(tsn[1]);
    const float32x4_t c21 = vdupq_n_f32(p->st_re[2]);
    const float32x4_t s21 = vdupq_n_f32(ts[2]);
    const float32x4_t n21 = vdupq_n_f32(tsn[2]);
    for (int b = 0; b < m; b += 16) {
      float32x4x4_t R = vld4q_f32(re + b);
      float32x4x4_t I = vld4q_f32(im + b);
      LE_FFT_BFLY(R.val[0], I.val[0], R.val[1], I.val[1], c1, s1, n1);
      LE_FFT_BFLY(R.val[2], I.val[2], R.val[3], I.val[3], c1, s1, n1);
      LE_FFT_BFLY(R.val[0], I.val[0], R.val[2], I.val[2], c20, s20, n20);
      LE_FFT_BFLY(R.val[1], I.val[1], R.val[3], I.val[3], c21, s21, n21);
      vst4q_f32(re + b, R);
      vst4q_f32(im + b, I);
    }
  }
  int h = 4;
  for (; 2 * h < m; h <<= 2) {
    /* Stages h and 2h: in each 4h block, points a = i + k, b = a + h,
     * c = a + 2h, d = a + 3h; stage h pairs (a, b) and (c, d) at its k,
     * stage 2h pairs (a, c) at its k and (b, d) at its k + h. */
    const float* w1r = p->st_re + (h - 1);
    const float* w1s = ts + (h - 1);
    const float* w1n = tsn + (h - 1);
    const float* w2r = p->st_re + (2 * h - 1);
    const float* w2s = ts + (2 * h - 1);
    const float* w2n = tsn + (2 * h - 1);
    for (int i = 0; i < m; i += 4 * h) {
      for (int k = 0; k < h; k += 4) {
        float* r0 = re + i + k;
        float* i0 = im + i + k;
        float32x4_t ar = vld1q_f32(r0), ai = vld1q_f32(i0);
        float32x4_t br = vld1q_f32(r0 + h), bi = vld1q_f32(i0 + h);
        float32x4_t cr = vld1q_f32(r0 + 2 * h), ci = vld1q_f32(i0 + 2 * h);
        float32x4_t dr = vld1q_f32(r0 + 3 * h), di = vld1q_f32(i0 + 3 * h);
        const float32x4_t c1 = vld1q_f32(w1r + k);
        const float32x4_t s1 = vld1q_f32(w1s + k);
        const float32x4_t n1 = vld1q_f32(w1n + k);
        LE_FFT_BFLY(ar, ai, br, bi, c1, s1, n1);
        LE_FFT_BFLY(cr, ci, dr, di, c1, s1, n1);
        const float32x4_t c2 = vld1q_f32(w2r + k);
        const float32x4_t s2 = vld1q_f32(w2s + k);
        const float32x4_t n2 = vld1q_f32(w2n + k);
        LE_FFT_BFLY(ar, ai, cr, ci, c2, s2, n2);
        const float32x4_t c3 = vld1q_f32(w2r + h + k);
        const float32x4_t s3 = vld1q_f32(w2s + h + k);
        const float32x4_t n3 = vld1q_f32(w2n + h + k);
        LE_FFT_BFLY(br, bi, dr, di, c3, s3, n3);
        vst1q_f32(r0, ar);
        vst1q_f32(i0, ai);
        vst1q_f32(r0 + h, br);
        vst1q_f32(i0 + h, bi);
        vst1q_f32(r0 + 2 * h, cr);
        vst1q_f32(i0 + 2 * h, ci);
        vst1q_f32(r0 + 3 * h, dr);
        vst1q_f32(i0 + 3 * h, di);
      }
    }
  }
  if (h < m) { /* the last stage, alone */
    const float* wr = p->st_re + (h - 1);
    const float* ws = ts + (h - 1);
    const float* wn = tsn + (h - 1);
    for (int i = 0; i < m; i += 2 * h) {
      for (int k = 0; k < h; k += 4) {
        float* r0 = re + i + k;
        float* i0 = im + i + k;
        float32x4_t ar = vld1q_f32(r0), ai = vld1q_f32(i0);
        float32x4_t br = vld1q_f32(r0 + h), bi = vld1q_f32(i0 + h);
        LE_FFT_BFLY(ar, ai, br, bi, vld1q_f32(wr + k), vld1q_f32(ws + k),
                    vld1q_f32(wn + k));
        vst1q_f32(r0, ar);
        vst1q_f32(i0, ai);
        vst1q_f32(r0 + h, br);
        vst1q_f32(i0 + h, bi);
      }
    }
  }
}

/* [v]'s lanes in reverse order. */
static inline float32x4_t le_fft_rev4(float32x4_t v) {
  const float32x4_t r = vrev64q_f32(v);
  return vextq_f32(r, r, 2);
}
#endif /* LE_FFT_NEON */

/* Whether this plan's transforms take the NEON path (m = n/2 of 16 and up,
 * so a group of four groups of four fits). */
static inline int le_fft_neon(const le_rfft_plan* p) {
  return LE_FFT_NEON && p->n >= 32;
}

/* In-place iterative radix-2 complex FFT of length m = p->n / 2.
 * inverse == 0: forward; inverse != 0: inverse WITHOUT 1/m scaling. */
static void le_fft_half(const le_rfft_plan* p, float* re, float* im,
                        int inverse) {
  const int m = p->n / 2;
  /* Bit-reversal permutation: reorder samples into butterfly order in place. */
  for (int i = 1; i < m; ++i) {
    const int j = p->rev[i];
    if (i < j) {
      float tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      float ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
#if LE_FFT_NEON
  if (le_fft_neon(p)) {
    le_fft_stages_neon(p, re, im, inverse);
    return;
  }
#endif
  le_fft_stages_scalar(p, re, im, inverse);
}

/* Real input x[n] -> half spectrum re/im[0..n/2] (n/2+1 bins), n = p->n.
 * re/im sized >= n/2+1; they double as the transform's scratch. */
static void le_rfft_fwd(const le_rfft_plan* p, const float* x, float* re,
                        float* im) {
  const int m = p->n / 2;
#if LE_FFT_NEON
  if (le_fft_neon(p)) {
    /* The even and odd samples straight to their bit-reversed places. */
    for (int j = 0; j < m; ++j) {
      re[p->rev[j]] = x[2 * j];
      im[p->rev[j]] = x[2 * j + 1];
    }
    le_fft_stages_neon(p, re, im, 0);
  } else
#endif
  {
    for (int j = 0; j < m; ++j) {
      re[j] = x[2 * j];
      im[j] = x[2 * j + 1];
    }
    le_fft_half(p, re, im, 0);
  }

  /* Split Z = FFT(even + i odd) into X[k] = E[k] + W^k O[k], where
   * E[k] = (Z[k] + conj Z[m-k]) / 2 and O[k] = (Z[k] - conj Z[m-k]) / 2i.
   * Bins k and m - k read each other, so each pair is done together; bin
   * m - k has E and O conjugated. */
  const float z0r = re[0];
  const float z0i = im[0];
  re[0] = z0r + z0i;
  im[0] = 0.0f;
  re[m] = z0r - z0i;
  im[m] = 0.0f;
  int k = 1;
#if LE_FFT_NEON
  if (le_fft_neon(p)) {
    /* Four pairs at a time while the k and m - k runs cannot meet (bins k
     * .. k + 3 and m - k - 3 .. m - k), as the scalar loop: re[k] = er +
     * (wr or - wi oi), im[k] = ei + (wr oi + wi or), re[q] = er + (vr or +
     * vi oi), im[q] = -ei + (vi or - vr oi), each inner sum's first
     * product fused. */
    const float32x4_t half = vdupq_n_f32(0.5f);
    const float32x4_t nhalf = vdupq_n_f32(-0.5f);
    for (; 2 * (k + 3) < m; k += 4) {
      const int q = m - k - 3; /* the lowest bin of the q run */
      const float32x4_t ar = vld1q_f32(re + k), ai = vld1q_f32(im + k);
      const float32x4_t br = le_fft_rev4(vld1q_f32(re + q));
      const float32x4_t bi = le_fft_rev4(vld1q_f32(im + q));
      const float32x4_t er = vmulq_f32(half, vaddq_f32(ar, br));
      const float32x4_t ei = vmulq_f32(half, vsubq_f32(ai, bi));
      const float32x4_t orr = vmulq_f32(half, vaddq_f32(ai, bi));
      const float32x4_t oi = vmulq_f32(nhalf, vsubq_f32(ar, br));
      const float32x4_t wr = vld1q_f32(p->sp_re + k);
      const float32x4_t wi = vld1q_f32(p->sp_im + k);
      const float32x4_t vr = le_fft_rev4(vld1q_f32(p->sp_re + q));
      const float32x4_t vi = le_fft_rev4(vld1q_f32(p->sp_im + q));
      const float32x4_t xr =
          vaddq_f32(er, vfmaq_f32(vnegq_f32(vmulq_f32(wi, oi)), wr, orr));
      const float32x4_t xi =
          vaddq_f32(ei, vfmaq_f32(vmulq_f32(wi, orr), wr, oi));
      const float32x4_t yr =
          vaddq_f32(er, vfmaq_f32(vmulq_f32(vi, oi), vr, orr));
      const float32x4_t yi = vaddq_f32(
          vnegq_f32(ei), vfmaq_f32(vnegq_f32(vmulq_f32(vr, oi)), vi, orr));
      vst1q_f32(re + k, xr);
      vst1q_f32(im + k, xi);
      vst1q_f32(re + q, le_fft_rev4(yr));
      vst1q_f32(im + q, le_fft_rev4(yi));
    }
  }
#endif
  for (; k <= m / 2; ++k) {
    const int q = m - k;
    const float ar = re[k], ai = im[k];
    const float br = re[q], bi = im[q];
    const float er = 0.5f * (ar + br), ei = 0.5f * (ai - bi);
    const float or_ = 0.5f * (ai + bi), oi = -0.5f * (ar - br);
    const float wr = p->sp_re[k], wi = p->sp_im[k];
    re[k] = er + (wr * or_ - wi * oi);
    im[k] = ei + (wr * oi + wi * or_);
    const float vr = p->sp_re[q], vi = p->sp_im[q];
    re[q] = er + (vr * or_ + vi * oi);
    im[q] = -ei + (vi * or_ - vr * oi);
  }
}

/* Half spectrum re/im[0..n/2] -> real output y[n], normalized by 1/n, n = p->n.
 * The spectrum is read as Hermitian: the imaginary parts of the DC and Nyquist
 * bins are ignored, as a real signal has none. */
static void le_rfft_inv(const le_rfft_plan* p, const float* re,
                        const float* im, float* y) {
  float zr[LE_FFT_MAX_N / 2];
  float zi[LE_FFT_MAX_N / 2];
  const int m = p->n / 2;

  /* Rebuild Z[k] = E[k] + i O[k] from E[k] = (X[k] + conj X[m-k]) / 2 and
   * O[k] = (X[k] - conj X[m-k]) / 2 * conj(W^k), a pair of bins at a time. */
  zr[0] = 0.5f * (re[0] + re[m]);
  zi[0] = 0.5f * (re[0] - re[m]);
  int k = 1;
#if LE_FFT_NEON
  if (le_fft_neon(p)) {
    /* Four pairs at a time, as the scalar loop: or = dr wr + di wi, oi =
     * di wr - dr wi, qr = -dr vr + di vi, qi = di vr + dr vi, each first
     * product fused. */
    const float32x4_t half = vdupq_n_f32(0.5f);
    for (; 2 * (k + 3) < m; k += 4) {
      const int q = m - k - 3;
      const float32x4_t ar = vld1q_f32(re + k), ai = vld1q_f32(im + k);
      const float32x4_t br = le_fft_rev4(vld1q_f32(re + q));
      const float32x4_t bi = le_fft_rev4(vld1q_f32(im + q));
      const float32x4_t er = vmulq_f32(half, vaddq_f32(ar, br));
      const float32x4_t ei = vmulq_f32(half, vsubq_f32(ai, bi));
      const float32x4_t dr = vmulq_f32(half, vsubq_f32(ar, br));
      const float32x4_t di = vmulq_f32(half, vaddq_f32(ai, bi));
      const float32x4_t wr = vld1q_f32(p->sp_re + k);
      const float32x4_t wi = vld1q_f32(p->sp_im + k);
      const float32x4_t orr = vfmaq_f32(vmulq_f32(di, wi), dr, wr);
      const float32x4_t oi =
          vfmaq_f32(vnegq_f32(vmulq_f32(dr, wi)), di, wr);
      vst1q_f32(zr + k, vsubq_f32(er, oi));
      vst1q_f32(zi + k, vaddq_f32(ei, orr));
      const float32x4_t vr = le_fft_rev4(vld1q_f32(p->sp_re + q));
      const float32x4_t vi = le_fft_rev4(vld1q_f32(p->sp_im + q));
      const float32x4_t qr =
          vfmaq_f32(vmulq_f32(di, vi), vnegq_f32(dr), vr);
      const float32x4_t qi = vfmaq_f32(vmulq_f32(dr, vi), di, vr);
      vst1q_f32(zr + q, le_fft_rev4(vsubq_f32(er, qi)));
      vst1q_f32(zi + q, le_fft_rev4(vaddq_f32(vnegq_f32(ei), qr)));
    }
  }
#endif
  for (; k <= m / 2; ++k) {
    const int q = m - k;
    const float ar = re[k], ai = im[k];
    const float br = re[q], bi = im[q];
    const float er = 0.5f * (ar + br), ei = 0.5f * (ai - bi);
    const float dr = 0.5f * (ar - br), di = 0.5f * (ai + bi);
    const float wr = p->sp_re[k], wi = p->sp_im[k];
    const float or_ = dr * wr + di * wi, oi = di * wr - dr * wi;
    zr[k] = er - oi;
    zi[k] = ei + or_;
    if (q != k) {
      /* Bin m - k: E conjugated, D negated and conjugated. */
      const float vr = p->sp_re[q], vi = p->sp_im[q];
      const float qr = -dr * vr + di * vi, qi = di * vr + dr * vi;
      zr[q] = er - qi;
      zi[q] = -ei + qr;
    }
  }
  le_fft_half(p, zr, zi, 1);
  const float scale = 1.0f / (float)m;
  for (int j = 0; j < m; ++j) {
    y[2 * j] = zr[j] * scale;
    y[2 * j + 1] = zi[j] * scale;
  }
}

/* Fills table[0..n-1] with a periodic Hann window once, then short-circuits on
 * later calls via *ready. The table is read-only shared state owned by the
 * caller, sized to its own n, so fft.h stays free of engine constants. The
 * flag is not synchronised: a table shared between threads must be built once
 * before any of them reads it (engine_fx.c builds its own under pthread_once).
 * Periodic form (divide by n, not n-1) gives correct constant-overlap-add for
 * the STFT. */
static void le_hann_init(float* table, int n, int* ready) {
  if (*ready) {
    return;
  }
  for (int i = 0; i < n; ++i) {
    table[i] = 0.5f - 0.5f * cosf(2.0f * LE_FFT_PI * (float)i / (float)n);
  }
  *ready = 1;
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_FFT_H */
