/* alias_spectrum.h — the aliasing measurement bench_alias (#1540) reads off
 * an effect's output, shared with bench_fx_matrix (#1547).
 *
 * The output is a steady tone that is a whole number of cycles of the
 * analysis window, on an odd bin, so each harmonic and each fold of a
 * harmonic lands on one FFT bin with no window and no leakage, and no fold
 * lands on a harmonic:
 *
 *   - alias dB: the energy on the bins the harmonics above Nyquist fold to
 *     (followed up to ALIAS_FOLD_TOP_HZ), from 1 Hz to ALIAS_TOP_HZ, over
 *     the output's energy in the same band. The other non-harmonic bins
 *     hold mostly the kernel's own noise and are left out.
 *   - worst dBFS: the largest single alias component below ALIAS_TOP_HZ, as
 *     the peak level of a sine.
 *
 * Header-only, included by one TU per bench binary after the system
 * headers (math.h, stdio.h, stdlib.h).
 */
#ifndef SEGNO_ALIAS_SPECTRUM_H
#define SEGNO_ALIAS_SPECTRUM_H

#define ALIAS_TOP_HZ 20000.0
/* Harmonics up to here are followed into their folds: 32 times 48 kHz,
 * the 32nd fold at 48 kHz and the 16th at 96 kHz. */
#define ALIAS_FOLD_TOP_HZ (32.0 * 48000.0)

/* In-place radix-2 complex FFT, double precision ([n] a power of two). */
static void alias_fft(double* re, double* im, int n) {
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      double t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    const double a = -2.0 * M_PI / len;
    for (int k = 0; k < len / 2; ++k) {
      const double wr = cos(a * k), wi = sin(a * k);
      for (int i = k; i < n; i += len) {
        const int j = i + len / 2;
        const double xr = re[j] * wr - im[j] * wi;
        const double xi = re[j] * wi + im[j] * wr;
        re[j] = re[i] - xr;
        im[j] = im[i] - xi;
        re[i] += xr;
        im[i] += xi;
      }
    }
  }
}

typedef struct {
  double alias_db;   /* folded harmonics over all, below ALIAS_TOP_HZ */
  double worst_dbfs; /* the largest folded component */
} alias_spectrum;

/* The five largest alias components of one measurement, on stderr, so a
 * table on stdout stays whole. */
static void alias_print_detail(const char* label, int sr, double hz,
                               const unsigned char* fold, const double* re,
                               const double* im, int win, int top) {
  int best[5] = {0, 0, 0, 0, 0};
  double e_best[5] = {0, 0, 0, 0, 0};
  for (int j = 1; j <= top && j < win / 2; ++j) {
    if (!fold[j]) continue;
    const double e = re[j] * re[j] + im[j] * im[j];
    for (int k = 0; k < 5; ++k) {
      if (e > e_best[k]) {
        for (int m = 4; m > k; --m) {
          e_best[m] = e_best[m - 1];
          best[m] = best[m - 1];
        }
        e_best[k] = e;
        best[k] = j;
        break;
      }
    }
  }
  fprintf(stderr, "%s, %d Hz, %.1f Hz tone:", label, sr, hz);
  for (int k = 0; k < 5 && best[k] > 0; ++k) {
    fprintf(stderr, " %.0f Hz %.1f dBFS%s", (double)best[k] * sr / win,
            20.0 * log10(2.0 * sqrt(e_best[k]) / win), k < 4 ? "," : "");
  }
  fprintf(stderr, "\n");
}

/* Measures [win] samples of [out] at [sr]: a tone on bin [bin] (odd) of a
 * [win]-point window ([win] a power of two). [detail], when not NULL,
 * labels the five largest alias components printed on stderr. */
static alias_spectrum alias_analyze(const float* out, int win, int sr, int bin,
                                    const char* detail) {
  double* re = (double*)calloc((size_t)win, sizeof(double));
  double* im = (double*)calloc((size_t)win, sizeof(double));
  const int half = win / 2;
  unsigned char* fold = (unsigned char*)calloc((size_t)half + 1, 1);
  if (re == NULL || im == NULL || fold == NULL) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  for (int i = 0; i < win; ++i) re[i] = out[i];
  alias_fft(re, im, win);
  /* The bins the tone's folds land on: harmonic k at k x bin, reflected
   * into the half spectrum. The bin is odd and the window a power of two,
   * so a fold of a harmonic below ALIAS_FOLD_TOP_HZ never lands on a
   * harmonic. Only these bins count as aliasing. The other non-harmonic
   * bins hold the kernel's own noise (float rounding in a low corner, a DC
   * blocker still settling) and the folds of harmonics past
   * ALIAS_FOLD_TOP_HZ; counting them too moves no figure above -65 dB by
   * more than 0.6 dB. */
  const double hz = (double)bin * sr / win;
  for (int64_t k = 1; (double)k * hz <= ALIAS_FOLD_TOP_HZ; ++k) {
    if ((double)k * hz <= 0.5 * sr) continue; /* in band: a harmonic */
    int64_t b = (k * bin) % win;
    if (b > half) b = win - b;
    fold[b] = 1;
  }
  /* The alias sum is its own (not the total less the harmonics, which
   * would cancel to nothing at the floor). */
  double total = 0.0, alias = 0.0, worst = 0.0;
  const int top = (int)(ALIAS_TOP_HZ * win / sr);
  for (int j = 1; j <= top && j < half; ++j) {
    const double e = re[j] * re[j] + im[j] * im[j];
    total += e;
    if (fold[j]) {
      alias += e;
      if (e > worst) worst = e;
    }
  }
  alias_spectrum r;
  r.alias_db = 10.0 * log10(alias / total + 1e-30);
  r.worst_dbfs = 20.0 * log10(2.0 * sqrt(worst) / win + 1e-15);
  if (detail != NULL) alias_print_detail(detail, sr, hz, fold, re, im, win, top);
  free(fold);
  free(re);
  free(im);
  return r;
}

#endif /* SEGNO_ALIAS_SPECTRUM_H */
