/* The lo-fi kinds (#887 part 7): Vinyl, Degrade and LPF, against the
 * Looper X's Phase 0 gap captures (#1445,
 * docs/plan/2026-10-23-looperx-gaps-measured.md). Included by
 * test_engine_core.c after the drive tests, whose helpers it reuses
 * (dyn_setting, dyn_run, dyn_state, dyn_free, eq_measured_db). */

/* The response at [hz] of [type] at [p], from a small impulse (the curves
 * stay linear), in dB. */
static double lofi_db(int32_t type, const float* p, int sr, double hz) {
  const int n = 1 << 15;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1e-3f;
  le_fx_state* fx = dyn_state(type, sr);
  uint32_t clock = 0;
  dyn_run(fx, type, p, sr, in, h, NULL, n, &clock);
  dyn_free(fx);
  const double db = eq_measured_db(h, n, hz, sr) + 60.0;
  free(in);
  free(h);
  return db;
}

/* A [hz] sine of peak [amp] through [type] at [p] for [n] samples at [sr];
 * the output's left side, which the caller frees. */
static float* lofi_tone(int32_t type, const float* p, int sr, double hz,
                        double amp, int n) {
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = (float)(amp * sin(2.0 * M_PI * hz * i / sr));
  le_fx_state* fx = dyn_state(type, sr);
  uint32_t clock = 0;
  dyn_run(fx, type, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  free(in);
  return out;
}

/* The amplitude of [y]'s component at [hz] over [len] samples from [from]
 * (whole cycles), or its mean at 0 Hz. */
static double lofi_amp(const float* y, int from, int len, double hz, int sr) {
  double re = 0.0;
  double im = 0.0;
  for (int i = from; i < from + len; ++i) {
    re += y[i] * cos(2.0 * M_PI * hz * i / sr);
    im += y[i] * sin(2.0 * M_PI * hz * i / sr);
  }
  return hz == 0.0 ? re / len : 2.0 * sqrt(re * re + im * im) / len;
}

/* ---- Vinyl ---- */

/* The vinyl's ladder (#1445): a 1 kHz tone at -30 and -12 dBFS, against the
 * Looper X's fundamental, DC and 2nd and 4th harmonics, each over the
 * tone's amplitude, at Drive 0, 40 (Freq 251, 50, 1256 and 5000 Hz) and
 * 100 %, and the limiter's hold at 0 dBFS. */
static void test_vinyl_drive(void) {
  printf("test_vinyl_drive\n");
  const int sr = 48000;
  const int n = sr / 2;
  const int from = sr / 4;
  const int len = sr / 5;
  /* drive, Freq, dBFS, then the capture's H1, DC, H2, H4 over A. */
  const double cases[][8] = {
      {0.0, 251, -12, 0.500, 0.0, 0.0, 0.0},
      {0.4, 251, -30, 0.500, 0.439, 0.307, 0.053},
      {0.4, 251, -12, 0.500, 0.739, 0.607, 0.053},
      {0.4, 50, -30, 0.500, 0.425, 0.296, 0.051},
      {0.4, 1256, -30, 0.500, 0.324, 0.224, 0.040},
      {0.4, 5000, -30, 0.500, 0.016, 0.010, 0.002},
      {1.0, 251, -30, 0.500, 2.746, 1.920, 0.329},
      /* Limited: everything scales down together. */
      {0.4, 251, -6, 0.201, 0.0, 0.0, 0.0},
      {0.4, 251, 0, 0.065, 0.0, 0.0, 0.0},
      {1.0, 251, -12, 0.114, 0.0, 0.0, 0.0},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = (float)cases[c][0];
    p[1] = dyn_setting(LE_FX_VINYL, 1, cases[c][1]);
    p[2] = 0.0f;
    p[3] = 0.9f;
    const double a = pow(10.0, cases[c][2] / 20.0);
    float* y = lofi_tone(LE_FX_VINYL, p, sr, 1000.0, a, n);
    const double h1 = lofi_amp(y, from, len, 1000.0, sr) / a;
    const double dc = lofi_amp(y, from, len, 0.0, sr) / a;
    const double h2 = lofi_amp(y, from, len, 2000.0, sr) / a;
    const double h4 = lofi_amp(y, from, len, 4000.0, sr) / a;
    printf("  drive %.0f %%, %4.0f Hz, %3.0f dBFS: H1 %.3f (%.3f) DC %.3f (%.3f) "
           "H2 %.3f (%.3f) H4 %.4f (%.4f)\n",
           100 * cases[c][0], cases[c][1], cases[c][2], h1, cases[c][3], dc,
           cases[c][4], h2, cases[c][5], h4, cases[c][6]);
    if (cases[c][4] == 0.0 && cases[c][0] > 0.0) {
      /* Limited: the fundamental within 15 %. */
      CHECK(fabs(h1 / cases[c][3] - 1.0) < 0.15);
    } else {
      CHECK(fabs(h1 - cases[c][3]) < 0.005);
      CHECK(fabs(dc - cases[c][4]) < 0.06 * cases[c][4] + 0.005);
      CHECK(fabs(h2 - cases[c][5]) < 0.06 * cases[c][5] + 0.005);
      CHECK(fabs(h4 - cases[c][6]) < 0.12 * cases[c][6] + 0.002);
    }
    free(y);
  }
}

/* The limiter's recovery after a loud tone stops (#1445): the Looper X's
 * gain was 0.229 under the tone, 0.458 100 ms after it and 0.842 after
 * 280 ms, at Drive 100 %. */
static void test_vinyl_limiter_release(void) {
  printf("test_vinyl_limiter_release\n");
  const int sr = 48000;
  const int n = sr;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  /* -12 dBFS for 0.5 s, then -48 dBFS: the quiet tone reads the gain. */
  for (int i = 0; i < n; ++i) {
    const double a = i < sr / 2 ? 0.2512 : 0.003981;
    in[i] = (float)(a * sin(2.0 * M_PI * 1000.0 * i / sr));
  }
  float p[LE_FX_PARAMS] = {0};
  p[0] = 1.0f;
  p[1] = dyn_setting(LE_FX_VINYL, 1, 251.0);
  p[3] = 0.9f;
  le_fx_state* fx = dyn_state(LE_FX_VINYL, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_VINYL, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  const double want[3][2] = {{-0.02, 0.229}, {0.10, 0.458}, {0.28, 0.842}};
  for (int k = 0; k < 3; ++k) {
    const int at = sr / 2 + (int)(want[k][0] * sr) - 240;
    const double a = k == 0 ? 0.2512 : 0.003981;
    const double g = lofi_amp(out, at, 480, 1000.0, sr) / a / 0.5;
    printf("  %+.2f s: gain %.3f (capture %.3f)\n", want[k][0], g, want[k][1]);
    CHECK(fabs(g - want[k][1]) < 0.06);
  }
  free(in);
  free(out);
}

static int lofi_cmp_double(const void* a, const void* b) {
  const double x = *(const double*)a;
  const double y = *(const double*)b;
  return x < y ? -1 : x > y;
}

/* Octave band [f]'s power in [y], dB, in the median 20 ms frame (the bed
 * between the clicks): 12 dB/octave high-pass at f / sqrt 2 and low-pass at
 * f sqrt 2, the first 0.1 s skipped (the bands the capture was read with). */
static double lofi_band(const float* y, int n, double f, int sr) {
  double hp[5];
  double lp[5];
  le_eq_design_for_test(0 /* low cut */, f / sqrt(2.0), 0.0, 0.70710678, sr, hp);
  double top = f * sqrt(2.0);
  if (top > 0.45 * sr) top = 0.45 * sr;
  le_eq_design_for_test(5 /* high cut */, top, 0.0, 0.70710678, sr, lp);
  double z1[2] = {0}, z2[2] = {0};
  const int frame = sr / 50;
  const int frames = (n - sr / 10) / frame;
  double* e = (double*)calloc((size_t)frames, sizeof(double));
  for (int i = 0; i < n; ++i) {
    double v = hp[0] * y[i] + z1[0];
    z1[0] = hp[1] * y[i] - hp[3] * v + z1[1];
    z1[1] = hp[2] * y[i] - hp[4] * v;
    const double w = lp[0] * v + z2[0];
    z2[0] = lp[1] * v - lp[3] * w + z2[1];
    z2[1] = lp[2] * v - lp[4] * w;
    const int k = (i - sr / 10) / frame;
    if (i >= sr / 10 && k < frames) e[k] += w * w / frame;
  }
  qsort(e, (size_t)frames, sizeof(double), lofi_cmp_double);
  const double med = e[frames / 2];
  free(e);
  return 10.0 * log10(med + 1e-30);
}

/* The noise bed in silence against the capture (#1445): the octave bands
 * of the bed between the clicks (each band's median 20 ms frame), the
 * clicks' rate and sizes, and the decorrelation: different on each channel
 * and for each owner. */
static void test_vinyl_noise(void) {
  printf("test_vinyl_noise\n");
  const int sr = 48000;
  const int n = 4 * sr;
  /* noise, tone, then the capture's bands at 63, 250, 1k, 4k, 16k and the
   * tolerance. */
  const double cases[][8] = {
      {1.0, 0.9, -63.5, -69.7, -79.3, -74.7, -69.5, 4.0},
      {1.0, 0.0, -64.6, -72.7, -80.4, -74.1, -90.1, 4.0},
      {1.0, 0.5, -64.4, -71.1, -80.6, -73.1, -77.6, 4.0},
      {0.5, 0.5, -84.0, -91.8, -101.4, -95.0, -99.5, 4.5},
      {0.3, 0.9, -95.8, -104.5, -112.9, -107.6, -102.8, 4.5},
  };
  const double bands[5] = {63, 250, 1000, 4000, 16000};
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* a_l = (float*)calloc((size_t)n, sizeof(float));
  float* a_r = (float*)calloc((size_t)n, sizeof(float));
  float* b_l = (float*)calloc((size_t)n, sizeof(float));
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = 0.4f;
    p[1] = 0.35f;
    p[2] = (float)cases[c][0];
    p[3] = (float)cases[c][1];
    le_fx_state* a = dyn_state(LE_FX_VINYL, sr);
    uint32_t ca = 0;
    dyn_run(a, LE_FX_VINYL, p, sr, in, a_l, a_r, n, &ca);
    dyn_free(a);
    printf("  noise %.0f %%, tone %.0f %%:", 100 * cases[c][0], 100 * cases[c][1]);
    for (int b = 0; b < 5; ++b) {
      const double got = lofi_band(a_l, n, bands[b], sr);
      printf(" %.0f:%.1f(%.1f)", bands[b], got, cases[c][2 + b]);
      CHECK(fabs(got - cases[c][2 + b]) < cases[c][7]);
    }
    printf("\n");
  }
  /* The clicks at 100 %, tone 90 %: the capture's peaks over 0.1 came at
   * 1.1 to 1.6 a second, the largest 0.12 to 0.5. */
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_VINYL, p);
  p[2] = 1.0f;
  const int long_n = 10 * sr;
  float* c_l = (float*)calloc((size_t)long_n, sizeof(float));
  float* silence = (float*)calloc((size_t)long_n, sizeof(float));
  le_fx_state* a = dyn_state(LE_FX_VINYL, sr);
  uint32_t ca = 0;
  dyn_run(a, LE_FX_VINYL, p, sr, silence, c_l, NULL, long_n, &ca);
  dyn_free(a);
  int over_big = 0;
  float largest = 0.0f;
  for (int i = 1; i + 1 < long_n; ++i) {
    const float v = fabsf(c_l[i]);
    if (v < fabsf(c_l[i - 1]) || v < fabsf(c_l[i + 1])) continue;
    if (v > 0.1f) ++over_big;
    if (v > largest) largest = v;
  }
  free(c_l);
  free(silence);
  const double secs = (double)long_n / sr;
  printf("  clicks over 0.1: %.1f/s (1.1 to 1.6), largest %.2f\n",
         over_big / secs, largest);
  CHECK(over_big / secs > 0.7 && over_big / secs < 3.0);
  CHECK(largest > 0.15f && largest <= 0.5f);
  /* At 96 kHz, the appliance's rate, the clicks come at the same rate and
   * level: each lasts 1/48000 s whatever the rate. */
  {
    const int sr96 = 96000;
    const int n96 = 10 * sr96;
    float* y96 = (float*)calloc((size_t)n96, sizeof(float));
    float* zero96 = (float*)calloc((size_t)n96, sizeof(float));
    le_fx_state* f96 = dyn_state(LE_FX_VINYL, sr96);
    uint32_t c96 = 0;
    dyn_run(f96, LE_FX_VINYL, p, sr96, zero96, y96, NULL, n96, &c96);
    dyn_free(f96);
    int big96 = 0;
    for (int i = 1; i + 1 < n96; ++i) {
      const float v = fabsf(y96[i]);
      if (v < fabsf(y96[i - 1]) || v < fabsf(y96[i + 1])) continue;
      if (v > 0.1f) ++big96;
    }
    printf("  at 96 kHz: clicks over 0.1: %.1f/s\n", big96 / 10.0);
    CHECK(big96 / 10.0 > 0.7 && big96 / 10.0 < 3.0);
    free(y96);
    free(zero96);
  }
  /* Two owners differ, and so do the two sides. */
  a = dyn_state(LE_FX_VINYL, sr);
  le_fx_state* b = dyn_state(LE_FX_VINYL, sr);
  b->hop_seed = 77; /* another owner */
  ca = 0;
  uint32_t cb = 0;
  dyn_run(a, LE_FX_VINYL, p, sr, in, a_l, a_r, n, &ca);
  dyn_run(b, LE_FX_VINYL, p, sr, in, b_l, NULL, n, &cb);
  double ll = 0.0, rr = 0.0, lr = 0.0;
  int same_ab = 1;
  int same_lr = 1;
  for (int i = sr / 10; i < n; ++i) {
    ll += (double)a_l[i] * a_l[i];
    rr += (double)a_r[i] * a_r[i];
    lr += (double)a_l[i] * a_r[i];
    if (a_l[i] != b_l[i]) same_ab = 0;
    if (a_l[i] != a_r[i]) same_lr = 0;
  }
  const double corr = lr / sqrt(ll * rr);
  printf("  L/R correlation %.2f (capture 0.89 to 0.99)\n", corr);
  CHECK(corr > 0.85 && corr < 0.999);
  CHECK(!same_lr);
  CHECK(!same_ab);
  dyn_free(a);
  dyn_free(b);
  free(in);
  free(a_l);
  free(a_r);
  free(b_l);
}

/* ---- Degrade ---- */

/* The held path's response, from tones, against the Looper X's (#1445):
 * at 1 kHz from its 1 kHz tone, elsewhere from its noise responses (which
 * the hold's images ripple by a few dB). Filter 0 % at holds of 5000 and
 * 1581 Hz is the steep low-pass at 0.194 of the hold; Filter 50 % has moved
 * it up past 1 kHz; Filter 100 % is no filter. The Looper X's hold droops
 * less than a sample-and-hold does (-3.1 dB at 1 kHz on a 1581 Hz hold,
 * against -6.8). The hold puts images at the hold rate +- 1 kHz. At 0 %
 * mix the degrade is the identity. */
static void test_degrade(void) {
  printf("test_degrade\n");
  const int sr = 48000;
  const int n = sr / 2;
  const int from = sr / 5;
  const int len = sr / 4;
  /* hold, filter, tone, capture dB, tolerance */
  const double cases[][5] = {
      {5000, 0.0, 400, 2.6, 2.5},    {5000, 0.0, 1000, 3.13, 0.6},
      {5000, 0.0, 1400, -13.7, 5.0}, {5000, 0.0, 2000, -26.4, 2.0},
      {5000, 0.0, 3000, -44.6, 2.0}, {1581, 0.0, 500, -15.2, 2.0},
      {1581, 0.0, 1000, -47.6, 1.0}, {5000, 0.5, 1000, 0.79, 1.5},
      {5000, 1.0, 1000, 0.06, 1.0},  {1581, 1.0, 1000, -3.06, 4.0},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_DEGRADE, 0, cases[c][0]);
    p[1] = (float)cases[c][1];
    p[2] = 1.0f;
    float* y = lofi_tone(LE_FX_DEGRADE, p, sr, cases[c][2], 0.25, n);
    const double got = 20.0 * log10(lofi_amp(y, from, len, cases[c][2], sr) / 0.25);
    printf("  hold %4.0f Hz, filter %3.0f %%, %4.0f Hz: %6.1f dB (capture %6.1f)\n",
           cases[c][0], 100 * cases[c][1], cases[c][2], got, cases[c][3]);
    CHECK(fabs(got - cases[c][3]) < cases[c][4]);
    free(y);
  }
  /* The images of a 1 kHz tone held at 5000 Hz, no filter: at 4 and 6 kHz,
   * 12 to 17 dB under the tone (the capture). */
  {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_DEGRADE, 0, 5000.0);
    p[1] = 1.0f;
    p[2] = 1.0f;
    float* y = lofi_tone(LE_FX_DEGRADE, p, sr, 1000.0, 0.25, n);
    const double h = lofi_amp(y, from, len, 1000.0, sr);
    const double lo = 20.0 * log10(lofi_amp(y, from, len, 4000.0, sr) / h);
    const double hi = 20.0 * log10(lofi_amp(y, from, len, 6000.0, sr) / h);
    printf("  images %.1f and %.1f dBc\n", lo, hi);
    CHECK(lo > -18.0 && lo < -11.0 && hi > -18.0 && hi < -11.0);
    free(y);
  }
  /* 0 % mix: the identity. */
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 0.5f * sinf(2.0f * (float)M_PI * 3000.0f * i / sr);
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_DEGRADE, 0, 4000.0);
  p[1] = 0.0f;
  p[2] = 0.0f;
  le_fx_state* fx = dyn_state(LE_FX_DEGRADE, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_DEGRADE, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(out[i] == in[i]);
  free(in);
  free(out);
}

/* ---- LPF ---- */

/* The ladder's small-signal response against the Looper X's noise
 * responses (#1445) at cutoffs of 112, 632 and 3557 Hz, resonance 0 and
 * 50 %, with the 25 Hz high-pass in front. */
static void test_lpf_response(void) {
  printf("test_lpf_response\n");
  const int sr = 48000;
  /* cutoff, resonance, Hz, capture dB, tolerance */
  const double cases[][5] = {
      {632, 0.0, 20, -3.9, 0.4},     {632, 0.0, 50, -1.1, 0.4},
      {632, 0.0, 500, -5.6, 0.4},    {632, 0.0, 1000, -19.1, 0.4},
      {632, 0.0, 2000, -38.8, 0.6},  {632, 0.5, 500, 7.9, 0.6},
      {632, 0.5, 632, 5.3, 1.8},     {632, 0.5, 1000, -10.3, 0.6},
      {632, 0.5, 2000, -31.0, 0.6},  {112, 0.0, 100, -7.7, 0.6},
      {112, 0.0, 200, -21.9, 0.6},   {112, 0.0, 500, -49.3, 1.0},
      {3557, 0.0, 2000, -2.0, 0.6},  {3557, 0.0, 3000, -5.6, 1.2},
      {3557, 0.0, 4000, -10.1, 1.8}, {3557, 0.0, 5000, -15.0, 2.0},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_LPF, 0, cases[c][0]);
    p[1] = (float)cases[c][1];
    const double got = lofi_db(LE_FX_LPF, p, sr, cases[c][2]);
    printf("  %4.0f Hz, reso %2.0f %%, at %4.0f Hz: %6.1f dB (capture %6.1f)\n",
           cases[c][0], 100 * cases[c][1], cases[c][2], got, cases[c][3]);
    CHECK(fabs(got - cases[c][3]) < cases[c][4]);
  }
}

/* At 100 % resonance the ladder oscillates on its own: excited, it keeps
 * a sine near the cutoff in silence at about the Looper X's level (0.25
 * peak at 632 Hz shown, 0.28 at 3557; at 644.5 and 3575.5 Hz). A loud
 * tone above the corner loses some of the resonance's lift, as the Looper
 * X's does (1 kHz at 632 Hz, 50 %: -9.7 dB at -48 dBFS, -17.1 at 0). At
 * the top of the range it is off: the identity. */
static void test_lpf_oscillates(void) {
  printf("test_lpf_oscillates\n");
  const int sr = 48000;
  const double want[2][3] = {{632, 644.5, 0.251}, {3557, 3575.5, 0.279}};
  for (int k = 0; k < 2; ++k) {
    const int n = sr;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* out = (float*)calloc((size_t)n, sizeof(float));
    in[0] = 0.1f;
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_LPF, 0, want[k][0]);
    p[1] = 1.0f;
    le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_LPF, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    float peak = 0.0f;
    int ups = 0;
    const int from = n / 2;
    for (int i = from; i < n; ++i) {
      if (fabsf(out[i]) > peak) peak = fabsf(out[i]);
      if (out[i - 1] < 0.0f && out[i] >= 0.0f) ++ups;
    }
    const double hz = ups / ((double)(n - from) / sr);
    printf("  %4.0f Hz shown: %.1f Hz (capture %.1f), peak %.3f (capture %.3f)\n",
           want[k][0], hz, want[k][1], peak, want[k][2]);
    CHECK(fabs(hz / want[k][1] - 1.0) < 0.012);
    CHECK(peak > 0.22f && peak < 0.32f);
    CHECK(le_fx_entry_free_running(LE_FX_LPF, p, sr));
    free(in);
    free(out);
  }
  /* From digital silence it starts on its own, within about a second. */
  {
    const int n = 2 * sr;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* out = (float*)calloc((size_t)n, sizeof(float));
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_LPF, 0, 632.0);
    p[1] = 1.0f;
    le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_LPF, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    float peak = 0.0f;
    int at = -1;
    for (int i = 0; i < n; ++i) {
      if (fabsf(out[i]) > peak) peak = fabsf(out[i]);
      if (at < 0 && fabsf(out[i]) > 0.2f) at = i;
    }
    printf("  from silence: 0.2 reached at %.2f s, peak %.3f\n",
           at < 0 ? -1.0 : (double)at / sr, peak);
    CHECK(at >= 0 && at < (int)(1.5 * sr));
    CHECK(peak < 0.32f);
    free(in);
    free(out);
  }
  /* A filter that sat in silence until its state left it, then turned past
   * the oscillation point, starts on its own too. */
  {
    const int n = 3 * sr;
    le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
    fx->clocked = 1;
    static float params[LE_FX_MAX][LE_FX_PARAMS];
    const int32_t types[1] = {LE_FX_LPF};
    params[0][0] = dyn_setting(LE_FX_LPF, 0, 632.0);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) {
      params[0][1] = i < sr ? 0.0f : 1.0f;
      fx->clock = (uint32_t)i;
      float l = 0.0f;
      float r = 0.0f;
      fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
      if (i >= 2 * sr && fabsf(l) > peak) peak = fabsf(l);
    }
    dyn_free(fx);
    printf("  after 1 s of silence at 0 %%: peak %.3f a second after 100 %%\n", peak);
    CHECK(peak > 0.2f);
  }
  /* Level: a loud tone above the corner. */
  const double lvl[2][2] = {{-48, -9.7}, {0, -17.1}};
  for (int k = 0; k < 2; ++k) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_LPF, 0, 632.0);
    p[1] = 0.5f;
    const double a = pow(10.0, lvl[k][0] / 20.0);
    float* y = lofi_tone(LE_FX_LPF, p, sr, 1000.0, a, sr / 2);
    const double got = 20.0 * log10(lofi_amp(y, sr / 5, sr / 4, 1000.0, sr) / a);
    printf("  1 kHz at %.0f dBFS: %.1f dB (capture %.1f)\n", lvl[k][0], got, lvl[k][1]);
    CHECK(fabs(got - lvl[k][1]) < 3.0);
    free(y);
  }
  /* Off at the top, as a fresh filter is: the identity, and its descriptor
   * says so; under the oscillation point it prints. */
  float p[LE_FX_PARAMS] = {0};
  CHECK(fxd_get(LE_FX_LPF, 0).flags & LE_FX_PARAM_OFF_AT_MAX);
  le_fx_defaults(LE_FX_LPF, p);
  CHECK(!le_fx_entry_free_running(LE_FX_LPF, p, sr));
  const int n = 512;
  float in[512];
  float out[512];
  for (int i = 0; i < n; ++i) in[i] = 0.4f * sinf(0.3f * (float)i);
  le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_LPF, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(out[i] == in[i]);
  p[0] = 0.5f;
  p[1] = 0.9f;
  CHECK(!le_fx_entry_free_running(LE_FX_LPF, p, sr));
  p[1] = 0.93f;
  CHECK(le_fx_entry_free_running(LE_FX_LPF, p, sr));
}

/* A vinyl at 0 % noise, a degrade that does not hold and an LPF under its
 * oscillation point print; with the noise up the lane stays live. */
static void test_lofi_cache(void) {
  printf("test_lofi_cache\n");
  for (int k = 0; k < 4; ++k) {
    const int32_t ty = k == 2 ? LE_FX_DEGRADE : k == 3 ? LE_FX_LPF : LE_FX_VINYL;
    le_engine* a = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
    cache_record_loop(a, CACHE_LOOP, 1.0f);
    CHECK(le_engine_set_lane_fx(a, 0, 0, 0, ty) == LE_OK);
    if (k == 0) CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 0.0f) == LE_OK);
    if (k == 3) {
      CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 0, 0.5f) == LE_OK);
      CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 1, 0.5f) == LE_OK);
    }
    CHECK(le_engine_set_lane_fx_count(a, 0, 0, 1, 1) == LE_OK);
    drain(a);
    le_lane_cache_info info;
    le_engine_get_lane_cache(a, 0, 0, &info);
    pump_frames(a, 0.0f, CACHE_SETTLE);
    if (k == 1) {
      pump_frames(a, 0.0f, CACHE_LOOP);
      le_engine_get_lane_cache(a, 0, 0, &info);
      CHECK(info.state == LE_CACHE_GAVE_UP);
      CHECK(info.reason == LE_CACHE_REASON_FREE_RUNNING);
    } else {
      CHECK(cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000));
    }
    le_engine_destroy(a);
  }
}

/* ---- all ---- */

static void test_lofi_offline_equals_live(void) {
  printf("test_lofi_offline_equals_live\n");
  const int32_t kinds[3] = {LE_FX_VINYL, LE_FX_DEGRADE, LE_FX_LPF};
  const int sr = 48000;
  const int n = 4096;
  for (int k = 0; k < 3; ++k) {
    const int32_t ty = kinds[k];
    _Atomic uint32_t frame = 1000;
    le_fx_state* live = dyn_state(ty, sr);
    live->clock_src = &frame;
    live->hop_seed = 5;
    le_fx_state* off = dyn_state(ty, sr);
    off->clocked = 1;
    off->hop_seed = 5; /* a render copies the owner's seed */
    float p[LE_FX_PARAMS] = {0};
    le_fx_defaults(ty, p);
    if (ty == LE_FX_DEGRADE) {
      p[0] = 0.4f;
      p[1] = 0.0f;
    }
    if (ty == LE_FX_LPF) p[0] = 0.5f; /* on, and oscillating */
    if (ty == LE_FX_VINYL) p[2] = 1.0f;
    static float params[LE_FX_MAX][LE_FX_PARAMS];
    const int32_t types[1] = {ty};
    for (int i = 0; i < n; ++i) {
      if (i == 777) p[1] = 0.2f;
      memcpy(params[0], p, sizeof(p));
      const float x = 0.5f * sinf((float)i * 0.05f);
      float ll = x, lr = -x, ol = x, orr = -x;
      off->clock = atomic_load(&frame);
      fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
      fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
      CHECK(ll == ol && lr == orr);
      atomic_fetch_add(&frame, 1u);
    }
    CHECK(!le_fx_type_drains(ty));
    CHECK(le_fx_type_free_running(ty));
    dyn_free(live);
    dyn_free(off);
  }
  /* What keeps a chain live: vinyl noise, a degrade that holds and is
   * heard, an oscillating LPF (test_lpf_oscillates). */
  float v[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_VINYL, v);
  CHECK(le_fx_entry_free_running(LE_FX_VINYL, v, 48000));
  v[2] = 0.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_VINYL, v, 48000));
  le_fx_defaults(LE_FX_DEGRADE, v);
  /* 50 kHz: not holding at 48 kHz, holding every other sample at 96. */
  CHECK(!le_fx_entry_free_running(LE_FX_DEGRADE, v, 48000));
  CHECK(le_fx_entry_free_running(LE_FX_DEGRADE, v, 96000));
  v[0] = dyn_setting(LE_FX_DEGRADE, 0, 46000.0);
  CHECK(!le_fx_entry_free_running(LE_FX_DEGRADE, v, 44100));
  v[0] = 0.4f;
  CHECK(le_fx_entry_free_running(LE_FX_DEGRADE, v, 48000));
  v[2] = 0.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_DEGRADE, v, 48000));
}

static void test_lofi_on_a_lane(void) {
  printf("test_lofi_on_a_lane\n");
  const int32_t kinds[3] = {LE_FX_VINYL, LE_FX_DEGRADE, LE_FX_LPF};
  for (int k = 0; k < 3; ++k) {
    const int32_t ty = kinds[k];
    const int32_t count = le_fx_param_count(ty);
    le_engine* e = make_configured_engine();
    establish_loop(e, 0.5f);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 0, ty) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, count - 1, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, count, 0.5f) == LE_ERR_INVALID);
    CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
    float out[64];
    for (int b = 0; b < 200; ++b) {
      process_const(e, 0.0f, 64, out);
      for (int i = 0; i < 64; ++i) CHECK(isfinite(out[i]));
    }
    le_engine_destroy(e);
  }
}

static void run_lofi_tests(void) {
  test_vinyl_drive();
  test_vinyl_limiter_release();
  test_vinyl_noise();
  test_degrade();
  test_lpf_response();
  test_lpf_oscillates();
  test_lofi_cache();
  test_lofi_offline_equals_live();
  test_lofi_on_a_lane();
}
