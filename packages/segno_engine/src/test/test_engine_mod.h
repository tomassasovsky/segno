/* The modulation and filter kinds (#887 part 6): Doubler, Chorus and Wah.
 * Included by test_engine_core.c after the dynamics tests, whose helpers
 * (dyn_setting, dyn_run, dyn_state, dyn_free, dyn_db, tr_peak) and the EQ's
 * (eq_measured_db, eq_design_db, le_eq_design_for_test) it reuses. */

/* The wet path's delay, in samples, at an impulse: the largest sample past
 * the dry spike at [at] (a chorus's dry spike sits at 0). */
static int mod_peak_after(const float* y, int from, int to) {
  int best = from;
  for (int i = from; i < to; ++i) {
    if (fabsf(y[i]) > fabsf(y[best])) best = i;
  }
  return best;
}

/* ---- Chorus ---- */

/* The chorus at the Guitar Rack capture's settings (Rate 32.6 %, Depth 12 %,
 * Mix 33.2 %, #891 s3/4) reproduces what the capture measured: dry gain
 * 0.904, voice gain 0.276, a triangle delay about 1.875 ms swinging
 * +-0.0704 ms at 1.313 Hz, and the voice's low-pass. */
static void test_chorus_matches_the_capture(void) {
  printf("test_chorus_matches_the_capture\n");
  const int sr = 96000;
  float p[LE_FX_PARAMS] = {0};
  p[0] = 0.326f;
  p[1] = 0.12f;
  p[2] = 0.332f;
  /* Impulses every 10 ms over two LFO periods: each one's voice lands at
   * the delay of that moment. */
  const int every = sr / 100;
  const int n = 2 * (int)(sr / 1.313) + every;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* out = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < n; i += every) in[i] = 1.0f;
  le_fx_state* fx = dyn_state(LE_FX_CHORUS, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_CHORUS, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  CHECK(fabsf(out[0] - 0.904f) < 0.002f);
  double lo = 1e9;
  double hi = -1e9;
  double area_sum = 0.0;
  int impulses = 0;
  int first_hi = -1;
  int second_hi = -1;
  double prev = 0.0;
  int rising = 1;
  for (int i = 0; i + every <= n; i += every) {
    /* The voice's centre of mass is its delay (the low-pass is symmetric
     * enough about its peak for this to land within a fraction of a
     * sample of the group delay, which is the same at every impulse). */
    double area = 0.0;
    double moment = 0.0;
    for (int k = 120; k < 260; ++k) {
      area += out[i + k];
      moment += (double)k * out[i + k];
    }
    const double d = moment / area;
    area_sum += area;
    impulses++;
    if (d < lo) lo = d;
    if (d > hi) hi = d;
    if (impulses > 1) {
      if (rising && d < prev) {
        if (first_hi < 0) {
          first_hi = i - every;
        } else if (second_hi < 0) {
          second_hi = i - every;
        }
      }
      rising = d >= prev;
    }
    prev = d;
  }
  /* +-0.0704 ms is +-6.76 samples at 96 kHz. */
  const double swing = 0.5 * (hi - lo);
  printf("  swing %.2f samples, voice area %.4f, period %d samples\n", swing,
         area_sum / impulses, second_hi - first_hi);
  CHECK(fabs(swing - 6.76) < 0.3);
  CHECK(fabs(area_sum / impulses - 0.276) < 0.005);
  /* The period: 96000 / 1.313 = 73115 samples, within one impulse spacing
   * either side of a turning point. */
  CHECK(first_hi >= 0 && second_hi > first_hi);
  CHECK(abs((second_hi - first_hi) - 73115) <= 2 * every);
  free(in);
  free(out);

  /* The rate line passes through both captures' rates. (The kernel's own
   * period was checked above at 32.6 %.) */
  const le_fx_param_desc rate = fxd_get(LE_FX_CHORUS, 0);
  CHECK(rate.flags & LE_FX_PARAM_TAPER_UNVERIFIED);
  CHECK(fabs((0.3959 + 2.8132 * 0.797) - 2.638) < 0.001 * 2.638);
  CHECK(fabs((0.3959 + 2.8132 * 0.326) - 1.313) < 0.001 * 1.313);

  /* The voice's response, from one impulse at a whole-sample delay
   * (depth 0): the capture's wet path was -2.0 dB at 4 kHz, -11.2 dB at
   * 8 kHz and -23 dB at 12 kHz. */
  p[1] = 0.0f;
  p[2] = 1.0f;
  const int m = 1 << 14;
  float* x = (float*)calloc((size_t)m, sizeof(float));
  float* y = (float*)calloc((size_t)m, sizeof(float));
  x[0] = 1.0f;
  fx = dyn_state(LE_FX_CHORUS, sr);
  clock = 0;
  dyn_run(fx, LE_FX_CHORUS, p, sr, x, y, NULL, m, &clock);
  dyn_free(fx);
  y[0] = 0.0f; /* the dry spike */
  const double dc = eq_measured_db(y, m, 0.0, sr);
  const double want[4][2] = {{1000, -0.1}, {4000, -1.97}, {8000, -11.15},
                             {12000, -23.0}};
  for (int i = 0; i < 4; ++i) {
    const double got = eq_measured_db(y, m, want[i][0], sr) - dc;
    if (fabs(got - want[i][1]) >= 0.5) {
      printf("  voice at %.0f Hz: %.2f dB, capture %.2f dB\n", want[i][0], got,
             want[i][1]);
    }
    CHECK(fabs(got - want[i][1]) < 0.5);
  }
  free(x);
  free(y);
}

/* ---- Doubler ---- */

/* At 0 % mix the doubler is the identity. At 100 % separation a mono
 * impulse comes back as one copy on the left about 11 ms later and one on
 * the right about 17 ms later, each at -3 dB; at 0 % both copies sit in the
 * centre, each at -6 dB a side. The copies drift by no more than 0.6 ms. */
static void test_doubler_places_its_copies(void) {
  printf("test_doubler_places_its_copies\n");
  const int sr = 48000;
  const int n = sr / 20;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* ol = (float*)calloc((size_t)n, sizeof(float));
  float* orr = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < n; ++i) in[i] = 0.3f * sinf(0.01f * (float)i * (float)i);
  float p[LE_FX_PARAMS] = {0};
  le_fx_state* fx = dyn_state(LE_FX_DOUBLER, sr);
  uint32_t clock = 0;
  p[0] = 0.0f;
  p[1] = 1.0f;
  dyn_run(fx, LE_FX_DOUBLER, p, sr, in, ol, orr, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(ol[i] == in[i] && orr[i] == in[i]);

  memset(in, 0, sizeof(float) * (size_t)n);
  in[0] = 1.0f;
  for (int sep = 0; sep < 2; ++sep) {
    p[0] = 1.0f;
    p[1] = sep ? 1.0f : 0.0f;
    fx = dyn_state(LE_FX_DOUBLER, sr);
    clock = 0;
    dyn_run(fx, LE_FX_DOUBLER, p, sr, in, ol, orr, n, &clock);
    dyn_free(fx);
    CHECK(ol[0] == 1.0f && orr[0] == 1.0f); /* the dry signal, untouched */
    double el_a = 0.0, er_a = 0.0, el_b = 0.0, er_b = 0.0;
    const int a0 = (int)(0.0104 * sr);
    const int a1 = (int)(0.0116 * sr) + 2;
    const int b0 = (int)(0.0164 * sr);
    const int b1 = (int)(0.0176 * sr) + 2;
    for (int i = a0; i < a1; ++i) { el_a += ol[i]; er_a += orr[i]; }
    for (int i = b0; i < b1; ++i) { el_b += ol[i]; er_b += orr[i]; }
    /* Nothing outside the two copies' windows. */
    for (int i = 1; i < n; ++i) {
      if ((i >= a0 && i < a1) || (i >= b0 && i < b1)) continue;
      CHECK(ol[i] == 0.0f && orr[i] == 0.0f);
    }
    if (sep) {
      CHECK(fabs(el_a - 0.7071) < 1e-3 && fabs(er_a) < 1e-3);
      CHECK(fabs(er_b - 0.7071) < 1e-3 && fabs(el_b) < 1e-3);
    } else {
      for (int k = 0; k < 4; ++k) {
        const double g = k == 0 ? el_a : k == 1 ? er_a : k == 2 ? el_b : er_b;
        CHECK(fabs(g - 0.5) < 1e-3);
      }
    }
  }
  free(in);
  free(ol);
  free(orr);
}

/* ---- Wah ---- */

/* The pedal sweeps the band-pass's peak from 350 Hz (heel) to 2.5 kHz
 * (toe), where the response peaks at +6 dB, and a pedal swept heel to toe in
 * 20 ms moves the output smoothly. */
static void test_wah_sweeps(void) {
  printf("test_wah_sweeps\n");
  const int sr = 48000;
  const int n = 1 << 15;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  const double hz[3] = {350.0, 350.0 * sqrt(2500.0 / 350.0), 2500.0};
  for (int k = 0; k < 3; ++k) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = 0.5f * (float)k;
    le_fx_state* fx = dyn_state(LE_FX_WAH, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_WAH, p, sr, in, h, NULL, n, &clock);
    dyn_free(fx);
    const double at = eq_measured_db(h, n, hz[k], sr);
    const double below = eq_measured_db(h, n, hz[k] / 2.0, sr);
    const double above = eq_measured_db(h, n, hz[k] * 2.0, sr);
    CHECK(fabs(at - 6.0) < 0.1);
    CHECK(below < at - 9.0 && above < at - 9.0);
  }
  free(h);
  /* A fast sweep: no sample-to-sample jump beyond what the filtered signal
   * itself does. */
  float* x = (float*)malloc(sizeof(float) * (size_t)(sr / 5));
  for (int i = 0; i < sr / 5; ++i) x[i] = 0.2f * sinf(2.0f * (float)M_PI * 900.0f * i / sr);
  le_fx_state* fx = dyn_state(LE_FX_WAH, sr);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_WAH};
  float prev = 0.0f;
  float max_step = 0.0f;
  for (int i = 0; i < sr / 5; ++i) {
    params[0][0] = i < sr / 10 ? 0.0f : (i < sr / 10 + sr / 50 ? (float)(i - sr / 10) / (sr / 50) : 1.0f);
    fx->clock = (uint32_t)i;
    float l = x[i];
    float r = x[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    if (i > sr / 20) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    prev = l;
  }
  /* A 900 Hz sine at 0.2, at most +6 dB (0.4): its own largest step is
   * 0.4 * 2 sin(pi * 900 / 48000) = 0.047. */
  CHECK(max_step < 0.05f);
  dyn_free(fx);
  free(x);
  free(in);
}

/* ---- all three ---- */

static void test_mod_offline_equals_live(void) {
  printf("test_mod_offline_equals_live\n");
  const int32_t kinds[3] = {LE_FX_DOUBLER, LE_FX_CHORUS, LE_FX_WAH};
  const int sr = 48000;
  const int n = 4096;
  for (int k = 0; k < 3; ++k) {
    const int32_t ty = kinds[k];
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
      if (i == 777) p[0] = 0.1f;
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
    CHECK(le_fx_type_free_running(ty) == (ty != LE_FX_WAH));
    dyn_free(live);
    dyn_free(off);
  }
}

/* A chain holding a chorus or a doubler sounds different each lap, so the
 * lane stays live and says why, until that entry is bypassed; a wah
 * prints. */
static void test_cache_free_running_stays_live(void) {
  printf("test_cache_free_running_stays_live\n");
  const int32_t kinds[3] = {LE_FX_CHORUS, LE_FX_DOUBLER, LE_FX_WAH};
  for (int k = 0; k < 3; ++k) {
    le_engine* a = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
    cache_record_loop(a, CACHE_LOOP, 1.0f);
    CHECK(le_engine_set_lane_fx(a, 0, 0, 0, kinds[k]) == LE_OK);
    CHECK(le_engine_set_lane_fx_count(a, 0, 0, 1, 1) == LE_OK);
    drain(a);
    le_lane_cache_info info;
    le_engine_get_lane_cache(a, 0, 0, &info); /* a scheduler tick */
    pump_frames(a, 0.0f, CACHE_SETTLE);
    if (kinds[k] == LE_FX_WAH) {
      CHECK(cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000));
    } else {
      pump_frames(a, 0.0f, CACHE_LOOP);
      le_engine_get_lane_cache(a, 0, 0, &info);
      CHECK(info.state == LE_CACHE_GAVE_UP);
      CHECK(info.reason == LE_CACHE_REASON_FREE_RUNNING);
      CHECK(info.renders == 0);
      /* Bypassed, it passes the signal through, so the lane prints. */
      CHECK(le_engine_set_lane_fx_enabled(a, 0, 0, 0, 0) == LE_OK);
      drain(a);
      le_engine_get_lane_cache(a, 0, 0, &info); /* sees the new key */
      pump_frames(a, 0.0f, CACHE_SETTLE);
      CHECK(cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000));
    }
    le_engine_destroy(a);
  }
}

static void test_mod_on_a_lane(void) {
  printf("test_mod_on_a_lane\n");
  const int32_t kinds[3] = {LE_FX_DOUBLER, LE_FX_CHORUS, LE_FX_WAH};
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
    for (int b = 0; b < 200; ++b) process_const(e, 0.0f, 64, out);
    for (int i = 0; i < 64; ++i) CHECK(isfinite(out[i]));
    le_engine_destroy(e);
  }
}

static void run_mod_tests(void) {
  test_chorus_matches_the_capture();
  test_doubler_places_its_copies();
  test_wah_sweeps();
  test_mod_offline_equals_live();
  test_cache_free_running_stays_live();
  test_mod_on_a_lane();
}
