/* The reverb kinds (#887 part 8): Spring. Included by test_engine_core.c
 * after the lo-fi tests, whose helpers it reuses (dyn_setting, dyn_run,
 * dyn_state, dyn_free, eq_measured_db). */

/* The decay of [h] (n samples at sr) from [from_s] to [to_s], as the time to
 * fall 60 dB: a line through the energies of 20 ms windows, in dB. */
static double verb_t60(const float* h, int sr, double from_s, double to_s) {
  const int win = sr / 50;
  double sx = 0, sy = 0, sxx = 0, sxy = 0;
  int n = 0;
  for (int a = (int)(from_s * sr); a + win <= (int)(to_s * sr); a += win) {
    double e = 0.0;
    for (int i = a; i < a + win; ++i) e += (double)h[i] * h[i];
    const double x = (double)a / sr;
    const double y = 10.0 * log10(e / win + 1e-30);
    sx += x; sy += y; sxx += x * x; sxy += x * y;
    n++;
  }
  const double slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
  return -60.0 / slope;
}

/* ---- Spring ---- */

/* The spring reproduces what its Phase 0 captures measured (#891, s3/6 and
 * s3/7): the decay at Time 2.00 and 7.9 s, the 38 ms echo, and the
 * band-limited wet spectrum. At 0 % mix it is the identity. */
static void test_spring_matches_the_capture(void) {
  printf("test_spring_matches_the_capture\n");
  const int sr = 96000;
  const int n = 3 * sr;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_SPRING, 0, 2.0);
  p[1] = 1.0f;
  le_fx_state* fx = dyn_state(LE_FX_SPRING, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_SPRING, p, sr, in, h, NULL, n, &clock);
  dyn_free(fx);
  h[0] = 0.0f; /* the dry spike */
  /* Measured the same way on the capture's impulse response (0.3 to 1.0 s
   * after it): 1.82 s at Time 2.00 s, 4.79 s at 7.9 s. */
  const double t2 = verb_t60(h, sr, 0.3, 1.0);
  printf("  Time 2.00 s: decay %.2f s (capture 1.82)\n", t2);
  CHECK(fabs(t2 - 1.82) < 0.1 * 1.82);

  /* The 38 ms echo: the envelope's autocorrelation peaks there. */
  {
    const int m = (int)(0.6 * sr);
    const int sm = sr / 1000;
    double* env = (double*)calloc((size_t)m, sizeof(double));
    double mean = 0.0;
    for (int i = 0; i < m; ++i) {
      double acc = 0.0;
      for (int k = i; k < i + sm && k < m; ++k) acc += fabs(h[k]);
      env[i] = acc / sm;
      mean += env[i];
    }
    mean /= m;
    int best = 0;
    double best_v = -1e30;
    for (int lag = (int)(0.02 * sr); lag < (int)(0.06 * sr); lag += 8) {
      double acc = 0.0;
      for (int i = 0; i + lag < m; i += 4) acc += (env[i] - mean) * (env[i + lag] - mean);
      if (acc > best_v) {
        best_v = acc;
        best = lag;
      }
    }
    printf("  echo at %.1f ms (capture 38.0)\n", 1000.0 * best / sr);
    CHECK(fabs(1000.0 * best / sr - 38.0) < 0.5);
    free(env);
  }

  /* The wet spectrum against the capture's, relative to 1 kHz (the
   * capture's impulse response, smoothed): within 4 dB at 318 Hz, 1.96 kHz
   * and 3.77 kHz, and the steep edge past 4.7 kHz. */
  const int len = sr;
  const double ref = eq_measured_db(h, len, 1000.0, sr);
  /* A single DFT bin rides the comb of the 38 ms loop; average a few bins
   * either side, the way the capture's spectrum was smoothed. */
  const double want[4][2] = {{318, -10.6}, {1958, -7.2}, {3765, -23.4},
                             {4681, -46.3}};
  for (int i = 0; i < 4; ++i) {
    double acc = 0.0;
    int cnt = 0;
    for (double f = want[i][0] / 1.06; f <= want[i][0] * 1.06; f += 2.0) {
      acc += pow(10.0, (eq_measured_db(h, len, f, sr)) / 10.0);
      cnt++;
    }
    double accr = 0.0;
    int cntr = 0;
    for (double f = 1000.0 / 1.06; f <= 1000.0 * 1.06; f += 2.0) {
      accr += pow(10.0, eq_measured_db(h, len, f, sr) / 10.0);
      cntr++;
    }
    const double got = 10.0 * log10(acc / cnt) - 10.0 * log10(accr / cntr);
    (void)ref;
    printf("  %.0f Hz: %.1f dB (capture %.1f)\n", want[i][0], got, want[i][1]);
    CHECK(fabs(got - want[i][1]) < (want[i][1] < -40.0 ? 8.0 : 4.0));
  }

  /* Time 7.9 s: longer, within the model's known difference. */
  p[0] = dyn_setting(LE_FX_SPRING, 0, 7.94);
  memset(h, 0, sizeof(float) * (size_t)n);
  fx = dyn_state(LE_FX_SPRING, sr);
  clock = 0;
  dyn_run(fx, LE_FX_SPRING, p, sr, in, h, NULL, n, &clock);
  dyn_free(fx);
  h[0] = 0.0f;
  const double t8 = verb_t60(h, sr, 0.3, 1.0);
  /* Broadband, the model holds a little more low end at long Times (it
   * matches the capture within 0.4 s in each of four bands, by the fit's
   * scratch analysis): within 20 %. */
  printf("  Time 7.9 s: decay %.2f s (capture 4.79)\n", t8);
  CHECK(fabs(t8 - 4.79) < 0.2 * 4.79);

  /* At 0 % mix: the identity. */
  for (int i = 0; i < n; ++i) in[i] = 0.3f * sinf(0.01f * i);
  p[1] = 0.0f;
  fx = dyn_state(LE_FX_SPRING, sr);
  clock = 0;
  dyn_run(fx, LE_FX_SPRING, p, sr, in, h, NULL, sr / 10, &clock);
  dyn_free(fx);
  for (int i = 0; i < sr / 10; ++i) CHECK(h[i] == in[i]);
  free(in);
  free(h);
}

/* ---- all ---- */

static void test_verb_offline_equals_live(void) {
  printf("test_verb_offline_equals_live\n");
  const int sr = 48000;
  const int n = 4096;
  const int32_t ty = LE_FX_SPRING;
  _Atomic uint32_t frame = 1000;
  le_fx_state* live = dyn_state(ty, sr);
  live->clock_src = &frame;
  le_fx_state* off = dyn_state(ty, sr);
  off->clocked = 1;
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(ty, p);
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {ty};
  for (int i = 0; i < n; ++i) {
    if (i == 777) p[0] = 0.8f;
    if (i == 2222) p[1] = 0.2f;
    memcpy(params[0], p, sizeof(p));
    const float x = 0.5f * sinf((float)i * 0.05f);
    float ll = x, lr = -x, ol = x, orr = -x;
    off->clock = atomic_load(&frame);
    fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
    fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
    CHECK(ll == ol && lr == orr);
    atomic_fetch_add(&frame, 1u);
  }
  CHECK(le_fx_type_drains(ty));
  CHECK(!le_fx_type_free_running(ty));
  dyn_free(live);
  dyn_free(off);
}

static void test_verb_on_a_lane(void) {
  printf("test_verb_on_a_lane\n");
  const int32_t ty = LE_FX_SPRING;
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

static void run_verb_tests(void) {
  test_spring_matches_the_capture();
  test_verb_offline_equals_live();
  test_verb_on_a_lane();
}
