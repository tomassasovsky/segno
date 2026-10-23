/* The lo-fi kinds (#887 part 7): Vinyl, Degrade and LPF. Included by
 * test_engine_core.c after the drive tests, whose helpers it reuses
 * (dyn_setting, dyn_run, dyn_state, dyn_free, drive_h1, eq_measured_db). */

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

/* ---- Vinyl ---- */

/* Noise down, the vinyl is a band-pass: the high-pass at its frequency and
 * the 7 kHz roll-off. With noise up, silence comes back as surface noise,
 * different on each channel and for each owner, and the same in an offline
 * render of the same owner. */
static void test_vinyl(void) {
  printf("test_vinyl\n");
  const int sr = 48000;
  float p[LE_FX_PARAMS] = {0};
  p[0] = 0.0f;
  p[1] = dyn_setting(LE_FX_VINYL, 1, 200.0);
  p[2] = 0.0f;
  CHECK(fabs(lofi_db(LE_FX_VINYL, p, sr, 1000.0)) < 0.5);
  CHECK(fabs(lofi_db(LE_FX_VINYL, p, sr, 200.0) + 3.0) < 0.5);
  CHECK(lofi_db(LE_FX_VINYL, p, sr, 50.0) < -20.0);
  CHECK(fabs(lofi_db(LE_FX_VINYL, p, sr, 7000.0) + 3.0) < 0.5);

  /* Noise. */
  p[2] = 1.0f;
  p[3] = 0.9f;
  const int n = sr;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* a_l = (float*)calloc((size_t)n, sizeof(float));
  float* a_r = (float*)calloc((size_t)n, sizeof(float));
  float* b_l = (float*)calloc((size_t)n, sizeof(float));
  le_fx_state* a = dyn_state(LE_FX_VINYL, sr);
  le_fx_state* b = dyn_state(LE_FX_VINYL, sr);
  b->hop_seed = 77; /* another owner */
  uint32_t ca = 0;
  uint32_t cb = 0;
  dyn_run(a, LE_FX_VINYL, p, sr, in, a_l, a_r, n, &ca);
  dyn_run(b, LE_FX_VINYL, p, sr, in, b_l, NULL, n, &cb);
  double el = 0.0;
  int same_lr = 1;
  int same_ab = 1;
  for (int i = 0; i < n; ++i) {
    el += (double)a_l[i] * a_l[i];
    if (a_l[i] != a_r[i]) same_lr = 0;
    if (a_l[i] != b_l[i]) same_ab = 0;
  }
  const double rms = sqrt(el / n);
  printf("  noise at 100 %%: %.1f dBFS rms\n", 20.0 * log10(rms));
  CHECK(rms > 1e-3 && rms < 0.1);
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

/* Holding at 4 kHz, a 3 kHz tone folds to 1 kHz; at 0 % mix the degrade is
 * the identity. */
static void test_degrade(void) {
  printf("test_degrade\n");
  const int sr = 48000;
  const int n = sr / 2;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 0.5f * sinf(2.0f * (float)M_PI * 3000.0f * i / sr);
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_DEGRADE, 0, 4000.0);
  p[1] = 0.0f;
  p[2] = 1.0f;
  le_fx_state* fx = dyn_state(LE_FX_DEGRADE, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_DEGRADE, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  const double tone = eq_measured_db(out + sr / 10, sr / 4, 3000.0, sr);
  const double fold = eq_measured_db(out + sr / 10, sr / 4, 1000.0, sr);
  printf("  3 kHz %.1f dB, 1 kHz fold %.1f dB\n", tone, fold);
  CHECK(fold > tone - 12.0);
  p[2] = 0.0f;
  fx = dyn_state(LE_FX_DEGRADE, sr);
  clock = 0;
  dyn_run(fx, LE_FX_DEGRADE, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(out[i] == in[i]);
  free(in);
  free(out);
}

/* ---- LPF ---- */

/* At 0 % resonance the low-pass is -3 dB at its cutoff; at 100 % it peaks
 * there at Q 3 (+9.5 dB); two octaves above, it is down 12 dB/oct. */
static void test_lpf(void) {
  printf("test_lpf\n");
  const int sr = 48000;
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_LPF, 0, 1000.0);
  p[1] = 0.0f;
  CHECK(fabs(lofi_db(LE_FX_LPF, p, sr, 1000.0) + 3.01) < 0.2);
  CHECK(fabs(lofi_db(LE_FX_LPF, p, sr, 100.0)) < 0.1);
  CHECK(lofi_db(LE_FX_LPF, p, sr, 4000.0) < -23.0);
  p[1] = 1.0f;
  CHECK(fabs(lofi_db(LE_FX_LPF, p, sr, 1000.0) - 9.54) < 0.3);
  /* At the top of its range, as a fresh filter is, it is off: the
   * identity, and its descriptor says so. */
  CHECK(fxd_get(LE_FX_LPF, 0).flags & LE_FX_PARAM_OFF_AT_MAX);
  le_fx_defaults(LE_FX_LPF, p);
  const int n = 512;
  float in[512];
  float out[512];
  for (int i = 0; i < n; ++i) in[i] = 0.4f * sinf(0.3f * (float)i);
  le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_LPF, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(out[i] == in[i]);
}

/* A vinyl at 0 % noise and a degrade that does not hold print; with the
 * noise up the lane stays live. */
static void test_lofi_cache(void) {
  printf("test_lofi_cache\n");
  for (int k = 0; k < 3; ++k) {
    const int32_t ty = k == 2 ? LE_FX_DEGRADE : LE_FX_VINYL;
    le_engine* a = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
    cache_record_loop(a, CACHE_LOOP, 1.0f);
    CHECK(le_engine_set_lane_fx(a, 0, 0, 0, ty) == LE_OK);
    if (k == 0) CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 0.0f) == LE_OK);
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
    if (ty == LE_FX_DEGRADE) p[0] = 0.4f;
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
    CHECK(le_fx_type_free_running(ty) == (ty != LE_FX_LPF));
    dyn_free(live);
    dyn_free(off);
  }
  /* What keeps a chain live: vinyl noise, a degrade that holds and is
   * heard. */
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
  test_vinyl();
  test_degrade();
  test_lpf();
  test_lofi_cache();
  test_lofi_offline_equals_live();
  test_lofi_on_a_lane();
}
