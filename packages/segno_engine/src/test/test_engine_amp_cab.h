/* The Amp+Cab (#887 part 12), against the #891 s6 captures. Included by
 * test_engine_core.c after the Dual Octaver tests. */

#define AMP_SR 96000

/* [n] frames of [in] (mono) through one Amp+Cab at [p] and [sr]; both
 * outputs to [l] and [r] (either may be NULL). */
static void amp_run(const float* p, int sr, const float* in, float* l, float* r,
                    int n) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_AMP_CAB, sr) == LE_OK);
  le_fx_entry_reset(fx, 0);
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_AMP_CAB;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float a = in[i], b = in[i];
    fx_apply_chain(fx, sr, sr, &a, &b, 1, types, params, NULL);
    if (l != NULL) l[i] = a;
    if (r != NULL) r[i] = b;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* The amplitude of [hz] in [y] over [n] frames at [sr], Hann-weighted. */
static double amp_tone(const float* y, int n, double hz, int sr) {
  double c = 0.0, s = 0.0, w = 0.0;
  for (int i = 0; i < n; ++i) {
    const double h = 0.5 - 0.5 * cos(2.0 * M_PI * i / (n - 1));
    const double ph = 2.0 * M_PI * hz * i / sr;
    c += y[i] * h * cos(ph);
    s += y[i] * h * sin(ph);
    w += h;
  }
  return 2.0 * sqrt(c * c + s * s) / w;
}

/* The level of a [hz] sine at [dbfs] through the amp at [p], dBFS, over the
 * last half of half a second. */
static double amp_level(const float* p, double hz, double dbfs) {
  const int n = AMP_SR / 2;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  const double a = pow(10.0, dbfs / 20.0);
  for (int i = 0; i < n; ++i) x[i] = (float)(a * sin(2.0 * M_PI * hz * i / AMP_SR));
  amp_run(p, AMP_SR, x, y, NULL, n);
  const double v = 20.0 * log10(amp_tone(y + n / 2, n / 2, hz, AMP_SR) + 1e-12);
  free(x);
  free(y);
  return v;
}

/* Drive: the 1 kHz fundamental at -48, -24 and 0 dBFS in, at every captured
 * drive (D.I., the tone controls at 50 %), within 1.5 dB of s6. */
static void test_amp_drive_matches_the_capture(void) {
  printf("test_amp_drive_matches_the_capture\n");
  static const double want[5][3] = {{-55.57, -31.57, -7.27},
                                    {-52.32, -28.34, -17.32},
                                    {-46.81, -23.02, -17.55},
                                    {-41.20, -19.43, -17.91},
                                    {-27.84, -18.91, -18.49}};
  static const double in[3] = {-48.0, -24.0, 0.0};
  double worst = 0.0;
  for (int d = 0; d < 5; ++d) {
    const float p[LE_FX_PARAMS] = {0.25f * (float)d, 0.5f, 0.5f, 0.5f, 0.0f};
    for (int k = 0; k < 3; ++k) {
      const double got = amp_level(p, 1000.0, in[k]);
      const double e = fabs(got - want[d][k]);
      if (e > worst) worst = e;
      if (e >= 1.5) {
        printf("  drive %d %%, %.0f dBFS in: %.1f, capture %.1f\n", 25 * d,
               in[k], got, want[d][k]);
      }
      CHECK(e < 1.5);
    }
  }
  printf("  worst %.2f dB\n", worst);
}

/* Bass, Treble and Modern at their ends, drive 0 (clean), D.I.: the level
 * at [hz] relative to every control at 50 %, within 1 dB of s6. */
static void test_amp_tone_matches_the_capture(void) {
  printf("test_amp_tone_matches_the_capture\n");
  static const struct {
    int ctl;
    float v;
    double hz, want;
  } c[] = {{1, 0.0f, 63.0, -12.6},  {1, 1.0f, 63.0, 11.8},
           {1, 0.0f, 250.0, -3.5},  {1, 1.0f, 250.0, 7.0},
           {2, 0.0f, 8000.0, -8.8}, {2, 1.0f, 8000.0, 12.3},
           {2, 0.0f, 3000.0, -5.8}, {2, 1.0f, 3000.0, 0.5},
           {3, 0.0f, 1000.0, -5.9}, {3, 1.0f, 1000.0, 8.2},
           {3, 0.0f, 4000.0, -11.3}, {3, 1.0f, 4000.0, 12.9}};
  for (size_t i = 0; i < sizeof(c) / sizeof(c[0]); ++i) {
    float p[LE_FX_PARAMS] = {0.0f, 0.5f, 0.5f, 0.5f, 0.0f};
    const double flat = amp_level(p, c[i].hz, -40.0);
    p[c[i].ctl] = c[i].v;
    const double got = amp_level(p, c[i].hz, -40.0) - flat;
    if (fabs(got - c[i].want) >= 1.0) {
      printf("  control %d at %.0f %%, %.0f Hz: %+.1f dB, capture %+.1f\n",
             c[i].ctl, 100.0f * c[i].v, c[i].hz, got, c[i].want);
    }
    CHECK(fabs(got - c[i].want) < 1.0);
  }
}

#include "../core/engine_fx_cabs.inc"

/* A cabinet is its measured response: at 48 kHz (the captures' rate, where
 * the bank holds the 48 kHz response as it is), the 4x12" output equals the
 * D.I. output convolved with the 4x12" row, to -80 dB. */
static void test_amp_cabinet_is_the_measured_response(void) {
  printf("test_amp_cabinet_is_the_measured_response\n");
  const int sr = 48000;
  const int n = sr / 2;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* di = (float*)malloc(sizeof(float) * (size_t)n);
  float* cab = (float*)malloc(sizeof(float) * (size_t)n);
  uint32_t seed = 1468;
  for (int i = 0; i < n; ++i) {
    seed = seed * 1664525u + 1013904223u;
    x[i] = 0.05f * ((float)(seed >> 8) / 8388608.0f - 1.0f);
  }
  const float pd[LE_FX_PARAMS] = {0.0f, 0.5f, 0.5f, 0.5f, 0.0f};
  const float pc[LE_FX_PARAMS] = {0.0f, 0.5f, 0.5f, 0.5f, 7.0f / 11.0f};
  amp_run(pd, sr, x, di, NULL, n);
  amp_run(pc, sr, x, cab, NULL, n);
  const float* h = LE_CAB_IR48[LE_CAB_ROW[7]];
  double err = 0.0, ref = 0.0;
  for (int i = sr / 10; i < n; ++i) {
    double v = 0.0;
    for (int t = 0; t < LE_CAB_TAPS48 && t <= i; ++t) v += (double)h[t] * di[i - t];
    err += (cab[i] - v) * (cab[i] - v);
    ref += v * v;
  }
  const double db = 10.0 * log10(err / ref + 1e-30);
  printf("  4x12\": %.1f dB from the convolution\n", db);
  CHECK(db < -80.0);
  free(x);
  free(di);
  free(cab);
}

/* The first 4x10" (6) plays the 2x12" (5), as the Looper X does (s6: the
 * two passes are bit-identical); the second 4x10" (10) is its own. */
static void test_amp_first_4x10_is_the_2x12(void) {
  printf("test_amp_first_4x10_is_the_2x12\n");
  CHECK(LE_CAB_ROW[6] == LE_CAB_ROW[5]);
  CHECK(LE_CAB_ROW[10] != LE_CAB_ROW[5]);
  CHECK(LE_CAB_ROW[0] < 0);
}

/* A cabinet change crossfades: no sample jumps further than the tone itself
 * moves in one frame. */
static void test_amp_cabinet_change_does_not_click(void) {
  printf("test_amp_cabinet_change_does_not_click\n");
  const int sr = AMP_SR;
  const int n = sr / 2;
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_AMP_CAB, sr) == LE_OK);
  le_fx_entry_reset(fx, 0);
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_AMP_CAB;
  const float p[LE_FX_PARAMS] = {0.0f, 0.5f, 0.5f, 0.5f, 7.0f / 11.0f};
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  float prev = 0.0f, worst = 0.0f, steady = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (i == n / 2) params[0][4] = 9.0f / 11.0f; /* 4x12" to BASS */
    fx->clock = (uint32_t)i;
    float a = 0.25f * sinf(2.0f * (float)M_PI * 220.0f * i / sr), b = a;
    fx_apply_chain(fx, sr, sr, &a, &b, 1, types, params, NULL);
    const float d = fabsf(a - prev);
    if (i > n / 4 && i < n / 2 && d > steady) steady = d;
    if (i >= n / 2 && d > worst) worst = d;
    prev = a;
    CHECK(a == b); /* mono */
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  printf("  largest step %.4f across the change, %.4f before it\n", worst,
         steady);
  CHECK(worst < 2.0f * steady);
}

static void run_amp_cab_tests(void) {
  test_amp_first_4x10_is_the_2x12();
  test_amp_cabinet_is_the_measured_response();
  test_amp_cabinet_change_does_not_click();
  test_amp_drive_matches_the_capture();
  test_amp_tone_matches_the_capture();
}
