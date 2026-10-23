/*
 * fft.h — header-only real FFT for the phase vocoder.
 *
 * A pure, self-contained transform with no engine coupling: every function is
 * `static` and the caller owns all buffers (no malloc, no platform headers).
 * Header-only means no new translation unit — it is #included by exactly one TU
 * (the phase vocoder's engine_fx.c; the native test here), so the static
 * functions never multiply-define and never sit unused.
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
 * Pure C11; compiles under MSVC (/std:c11), Clang, and GCC.
 */
#ifndef SEGNO_FFT_H
#define SEGNO_FFT_H

#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LE_FFT_PI 3.14159265358979323846f

/* Upper bound on the real transform length a plan can hold. The phase vocoder
 * uses n = 1024. The inverse's stack scratch is LE_FFT_MAX_N floats. */
#define LE_FFT_MAX_N 4096

/* The tables for one real transform length. Filled by le_rfft_plan_init on a
 * non-real-time thread and read-only afterwards, so one plan serves any number
 * of instances and threads. */
typedef struct le_rfft_plan {
  int n; /* real length; 0 = not built */
  /* Twiddles of the length-n/2 complex FFT, stage by stage: the stage whose
   * butterflies span 2h points reads exp(-2 pi i k / 2h), k < h, from offset
   * h - 1. n/2 - 1 entries in all. */
  float st_re[LE_FFT_MAX_N / 2];
  float st_im[LE_FFT_MAX_N / 2];
  /* The split twiddles W^k = exp(-2 pi i k / n), k = 0 .. n/2. */
  float sp_re[LE_FFT_MAX_N / 2 + 1];
  float sp_im[LE_FFT_MAX_N / 2 + 1];
} le_rfft_plan;

/* Builds [p] for real length [n] (a power of two, 4 .. LE_FFT_MAX_N). A no-op
 * when [p] already holds n. Returns 1 when [p] holds a plan for n, 0 for a bad
 * n. Not real-time safe (double-precision trig): call it where the effect is
 * prepared, as le_hann_init is. */
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
    }
  }
  for (int k = 0; k <= m; ++k) {
    const double a = -2.0 * pi * (double)k / (double)n;
    p->sp_re[k] = (float)cos(a);
    p->sp_im[k] = (float)sin(a);
  }
  p->n = n;
  return 1;
}

/* In-place iterative radix-2 complex FFT of length m = p->n / 2.
 * inverse == 0: forward; inverse != 0: inverse WITHOUT 1/m scaling. */
static void le_fft_half(const le_rfft_plan* p, float* re, float* im,
                        int inverse) {
  const int m = p->n / 2;
  /* Bit-reversal permutation: reorder samples into butterfly order in place. */
  for (int i = 1, j = 0; i < m; ++i) {
    int bit = m >> 1;
    for (; j & bit; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      float tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      float ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  /* Danielson–Lanczos butterflies, doubling the sub-transform length each
   * pass; the inverse conjugates the twiddles. */
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

/* Real input x[n] -> half spectrum re/im[0..n/2] (n/2+1 bins), n = p->n.
 * re/im sized >= n/2+1; they double as the transform's scratch. */
static void le_rfft_fwd(const le_rfft_plan* p, const float* x, float* re,
                        float* im) {
  const int m = p->n / 2;
  for (int j = 0; j < m; ++j) {
    re[j] = x[2 * j];
    im[j] = x[2 * j + 1];
  }
  le_fft_half(p, re, im, 0);

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
  for (int k = 1; k <= m / 2; ++k) {
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
  for (int k = 1; k <= m / 2; ++k) {
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
 * caller (the phase vocoder keeps a file-scope table + ready flag, sized to its
 * own LE_PV_N), so fft.h stays free of engine constants. Periodic form
 * (divide by n, not n-1) gives correct constant-overlap-add for the STFT. */
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
