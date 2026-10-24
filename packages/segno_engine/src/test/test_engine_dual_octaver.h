/* The Dual Octaver's first voice (#887 part 11), against the #891 s5
 * captures. Included by test_engine_core.c after the Mode delay tests. */

#define DO_SR 48000

/* The amplitude of [hz] in [y] over [n] frames. */
static double do_amp(const float* y, int n, double hz) {
  double c = 0.0, s = 0.0, w = 0.0;
  for (int i = 0; i < n; ++i) {
    const double h = 0.5 - 0.5 * cos(2.0 * 3.14159265358979 * i / (n - 1));
    const double ph = 2.0 * 3.14159265358979 * hz * i / DO_SR;
    c += y[i] * h * cos(ph);
    s += y[i] * h * sin(ph);
    w += h;
  }
  return 2.0 * sqrt(c * c + s * s) / w;
}

/* A second of a 1 kHz sine at -12 dBFS through the Dual Octaver at [p];
 * the amplitudes at 500 Hz, 1 kHz, 2 kHz, 250 Hz and 4 kHz over its second
 * half, in dB against the input's. */
static void do_levels(const float* p, double* db) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_DUAL_OCTAVER, DO_SR) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_DUAL_OCTAVER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  const int n = DO_SR;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = 0.2512f * sinf(2.0f * 3.14159265f * 1000.0f * (float)i / DO_SR);
    float r = l;
    fx_apply_chain(fx, DO_SR, DO_SR, &l, &r, 1, types, params, NULL);
    y[i] = l;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  static const double hz[5] = {500.0, 1000.0, 2000.0, 250.0, 4000.0};
  for (int k = 0; k < 5; ++k) {
    db[k] = 20.0 * log10(do_amp(y + n / 2, n / 2, hz[k]) / 0.2512 + 1e-12);
  }
  free(y);
}

/* High mode off: one octave down at -1.5 dB against the dry; on: one
 * octave up at -0.6 dB (s5/4-5, Mix 100 %); Mix 50 %: the dry and the
 * voice each 3 dB down (s5/7, an equal-power mix). */
static void test_dual_octaver_matches_the_capture(void) {
  printf("test_dual_octaver_matches_the_capture\n");
  double db[5];
  const float down[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f};
  do_levels(down, db);
  printf("  off: 500 Hz %+5.1f (capture -1.5), 1 kHz %+5.1f\n", db[0], db[1]);
  CHECK(fabs(db[0] + 1.5) < 0.5);
  CHECK(db[1] < -30.0);
  const float up[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f};
  do_levels(up, db);
  printf("  on: 2 kHz %+5.1f (capture -0.6), 1 kHz %+5.1f\n", db[2], db[1]);
  CHECK(fabs(db[2] + 0.6) < 0.5);
  CHECK(db[1] < -30.0);
  const float half[LE_FX_PARAMS] = {1.0f, 1.0f, 0.5f};
  do_levels(half, db);
  printf("  on at 50 %%: 1 kHz %+5.1f (capture -3.0), 2 kHz %+5.1f (-3.6)\n",
         db[1], db[2]);
  CHECK(fabs(db[1] + 3.0) < 0.5);
  CHECK(fabs(db[2] + 3.6) < 0.5);
  /* Octave 1 Vol scales the voice (its taper unmeasured: linear here). */
  const float quiet[LE_FX_PARAMS] = {0.0f, 0.5f, 1.0f};
  do_levels(quiet, db);
  CHECK(fabs(db[0] - (-1.5 + 20.0 * log10(0.5))) < 0.5);
}

/* Octave 2 (#1464), from the same analysis: two octaves up in high mode,
 * level with Octave 1 (s5/6: both -0.7 dB against the dry); two octaves
 * down without it (inferred), at Octave 1's level; and Octave 1 as it was
 * alone. */
static void test_dual_octaver_second_voice(void) {
  printf("test_dual_octaver_second_voice\n");
  double db[5];
  const float up[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f, 1.0f};
  do_levels(up, db);
  printf("  on: 2 kHz %+5.1f, 4 kHz %+5.1f (capture -0.7, -0.7)\n", db[2],
         db[4]);
  CHECK(fabs(db[2] + 0.7) < 0.5);
  CHECK(fabs(db[4] + 0.7) < 0.5);
  const float down[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 1.0f};
  do_levels(down, db);
  printf("  off: 500 Hz %+5.1f, 250 Hz %+5.1f (inferred: as Octave 1)\n",
         db[0], db[3]);
  CHECK(fabs(db[0] + 1.5) < 0.5);
  CHECK(fabs(db[3] - db[0]) < 1.0);
  const float half[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f, 0.5f};
  do_levels(half, db);
  CHECK(fabs(db[4] - (-0.7 + 20.0 * log10(0.5))) < 0.5);
}

static void run_dual_octaver_tests(void) {
  test_dual_octaver_second_voice();
  test_dual_octaver_matches_the_capture();
}
