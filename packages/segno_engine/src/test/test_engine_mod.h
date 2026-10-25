/* The modulation and filter kinds (#887 part 6): Doubler, Chorus and Wah,
 * the doubler and the wah against the Phase 0 gap captures (#1445).
 * Included by test_engine_core.c after the dynamics tests, whose helpers
 * (dyn_setting, dyn_run, dyn_state, dyn_free, dyn_db, tr_peak) and the EQ's
 * (eq_measured_db, eq_design_db, le_eq_design_for_test) it reuses. */

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

  /* The rate line passes within 1 % of every capture's rate: s6 at 0, 25,
   * 50 and 100 %, s3 at 32.6 and 79.7 %. (The kernel's own period was
   * checked above at 32.6 %.) */
  const le_fx_param_desc rate = fxd_get(LE_FX_CHORUS, 0);
  CHECK(!(rate.flags & LE_FX_PARAM_TAPER_UNVERIFIED));
  const double rates[6][2] = {{0.0, 0.4005}, {0.25, 1.1107}, {0.5, 1.7998},
                              {1.0, 3.1994}, {0.326, 1.313},  {0.797, 2.638}};
  for (int i = 0; i < 6; ++i) {
    const double got = 0.4005 + 2.799 * rates[i][0]; /* the kernel's line */
    CHECK(fabs(got - rates[i][1]) < 0.01 * rates[i][1]);
  }

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

/* White noise through the doubler, read in windows of [win] samples: in
 * each, the gain at lag 0 (the dry signal) and the strongest other lag up
 * to [maxlag] and its gain (the copy), per side. Returns the window count. */
static int dbl_windows(const float* p, int sr, int n, int win, int maxlag,
                       int* lag_l, int* lag_r, double* dry, double* voice) {
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* yl = (float*)malloc(sizeof(float) * (size_t)n);
  float* yr = (float*)malloc(sizeof(float) * (size_t)n);
  uint32_t s = 12345u;
  for (int i = 0; i < n; ++i) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    x[i] = (float)(int32_t)s * (0.25f / 2147483648.0f);
  }
  le_fx_state* fx = dyn_state(LE_FX_DOUBLER, sr);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  memcpy(params[0], p, sizeof(float) * LE_FX_PARAMS);
  const int32_t types[1] = {LE_FX_DOUBLER};
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = x[i];
    float r = x[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    yl[i] = l;
    yr[i] = r;
  }
  dyn_free(fx);
  int w = 0;
  for (int at = maxlag; at + win <= n; at += win, ++w) {
    for (int ch = 0; ch < 2; ++ch) {
      const float* y = ch ? yr : yl;
      double best = 0.0;
      int best_lag = 0;
      double g0 = 0.0;
      for (int lag = 0; lag <= maxlag; ++lag) {
        double c = 0.0;
        double e = 0.0;
        for (int i = at; i < at + win; ++i) {
          c += (double)y[i] * x[i - lag];
          e += (double)x[i - lag] * x[i - lag];
        }
        const double g = c / e;
        if (lag == 0) {
          g0 = g;
        } else if (g > best) {
          best = g;
          best_lag = lag;
        }
      }
      if (ch == 0) {
        lag_l[w] = best_lag;
        dry[2 * w] = g0;
        voice[2 * w] = best;
      } else {
        lag_r[w] = best_lag;
        dry[2 * w + 1] = g0;
        voice[2 * w + 1] = best;
      }
    }
  }
  free(x);
  free(yl);
  free(yr);
  return w;
}

/* The doubler against the Dub, Studio and Vocal racks' captures (#1445):
 * the dry signal at 0.31 and one copy a side at 0.95, at a random delay
 * that holds 125 to 175 ms between 25 ms crossfades, drawn independently
 * left and right, up to 1 ms at 0 % separation, 51 ms at 50 % and 100 ms at
 * 100 %; at 0 % mix the copy collapses to within 1 ms. */
static void test_doubler_matches_the_capture(void) {
  printf("test_doubler_matches_the_capture\n");
  const int sr = 48000;
  const int n = 2 * sr;
  /* mix, separation, window, longest lag looked at, then the longest delay
   * the capture saw, the shortest the longest should reach. */
  const double cases[4][6] = {
      {1.0, 0.5, 1024, 2600, 51.2, 30.0}, /* Studio and Vocal */
      {1.0, 0.0, 1024, 100, 1.0, 0.6},    /* Dub, Sep 0 % */
      {1.0, 1.0, 2048, 4900, 100.8, 60.0}, /* Dub, Sep 100 % */
      {0.0, 1.0, 1024, 100, 1.0, 0.6},    /* Mix 0 %: collapsed */
  };
  enum { MAXW = 256 };
  static int lag_l[MAXW];
  static int lag_r[MAXW];
  static double dry[2 * MAXW];
  static double voice[2 * MAXW];
  for (int c = 0; c < 4; ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = (float)cases[c][0];
    p[1] = (float)cases[c][1];
    const int win = (int)cases[c][2];
    const int maxlag = (int)cases[c][3];
    const int w = dbl_windows(p, sr, n, win, maxlag, lag_l, lag_r, dry, voice);
    int clean = 0;
    int differ = 0;
    int longest = 0;
    double dry_sum = 0.0;
    for (int i = 0; i < w; ++i) {
      for (int ch = 0; ch < 2; ++ch) {
        /* A window inside a hold shows the whole copy at one lag. */
        if (voice[2 * i + ch] > 0.85) {
          dry_sum += dry[2 * i + ch];
          ++clean;
          CHECK(voice[2 * i + ch] < 1.05);
          const int lag = ch ? lag_r[i] : lag_l[i];
          if (lag > longest) longest = lag;
          CHECK(lag >= (int)(0.0002 * sr) - 1);
          CHECK(lag <= (int)(cases[c][4] * 1e-3 * sr) + 2);
        }
      }
      if (lag_l[i] != lag_r[i]) ++differ;
    }
    const double dry_mean = clean ? dry_sum / clean : 0.0;
    printf("  mix %.0f %%, sep %.0f %%: %d of %d windows clean, dry %.3f, "
           "longest %.1f ms, sides differ in %d\n",
           100 * cases[c][0], 100 * cases[c][1], clean, 2 * w, dry_mean,
           1e3 * longest / sr, differ);
    CHECK(clean > w); /* most of both sides' windows */
    CHECK(longest > (int)(cases[c][5] * 1e-3 * sr));
    CHECK(differ > w / 2);
    /* The dry gain, apart from the copy, is 0.31. */
    CHECK(fabs(dry_mean - 0.31) < 0.02);
  }
  /* The holds: count the copy's moves on the left over 2 s at 50 %
   * separation, in 10 ms windows; 2 s holds 10 to 13 hold-and-fade
   * cycles. */
  {
    float p[LE_FX_PARAMS] = {0};
    p[0] = 1.0f;
    p[1] = 0.5f;
    const int w = dbl_windows(p, sr, n, 480, 2600, lag_l, lag_r, dry, voice);
    int moves = 0;
    int last = -1;
    for (int i = 0; i < w; ++i) {
      if (voice[2 * i] < 0.85) continue; /* fading */
      if (last >= 0 && abs(lag_l[i] - last) > 2) ++moves;
      last = lag_l[i];
    }
    printf("  %d moves in %.1f s\n", moves, (double)w * 480 / sr);
    CHECK(moves >= 9 && moves <= 14);
  }
}

/* A rate change in the middle of the doubler's holds and fades (96 kHz,
 * then 44.1 kHz, then 192 kHz) keeps its output bounded by its gains. */
static void test_doubler_survives_a_rate_change(void) {
  printf("test_doubler_survives_a_rate_change\n");
  const int rates[3] = {96000, 44100, 192000};
  le_fx_state* fx = dyn_state(LE_FX_DOUBLER, rates[0]);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_DOUBLER};
  params[0][0] = 1.0f;
  params[0][1] = 1.0f;
  uint32_t s = 777u;
  uint32_t clock = 0;
  float worst = 0.0f;
  for (int k = 0; k < 3; ++k) {
    /* 0.37 s: past the first hold, so some fades are under way. */
    const int n = (int)(0.37 * rates[k]);
    for (int i = 0; i < n; ++i) {
      s ^= s << 13;
      s ^= s >> 17;
      s ^= s << 5;
      const float x = (float)(int32_t)s * (0.5f / 2147483648.0f);
      float l = x;
      float r = -x;
      fx->clock = clock++;
      fx_apply_chain(fx, rates[k], rates[k], &l, &r, 1, types, params, NULL);
      CHECK(isfinite(l) && isfinite(r));
      if (fabsf(l) > worst) worst = fabsf(l);
      if (fabsf(r) > worst) worst = fabsf(r);
    }
  }
  dyn_free(fx);
  /* 0.31 + 0.95 of a 0.5 input. */
  printf("  largest output %.3f (bound 0.630)\n", worst);
  CHECK(worst <= 0.63f);
}

/* ---- Wah ---- */

/* The wah against the Guitar and Ed's racks' captures (#1445): the peak's
 * level at the captured pedal positions, and the floor below 100 Hz and
 * the skirt at 10 kHz; a pedal swept heel to toe in 20 ms moves the output
 * smoothly. */
static void test_wah_matches_the_capture(void) {
  printf("test_wah_matches_the_capture\n");
  const int sr = 48000;
  const int n = 1 << 15;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  /* pedal, peak Hz, peak dB, 50 Hz dB, 10 kHz dB */
  const double cases[6][5] = {
      {0.0, 439, 13.1, -17.0, -33.7},  {0.25, 459, 13.9, -16.6, -32.2},
      {0.5, 536, 11.1, -17.4, -29.3},  {0.619, 749, 12.4, -15.7, -23.0},
      {0.75, 1208, 10.9, -15.4, -17.0}, {1.0, 2313, 13.2, -16.4, -4.7},
  };
  for (int k = 0; k < 6; ++k) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = (float)cases[k][0];
    le_fx_state* fx = dyn_state(LE_FX_WAH, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_WAH, p, sr, in, h, NULL, n, &clock);
    dyn_free(fx);
    const double pk = eq_measured_db(h, n, cases[k][1], sr);
    const double lo = eq_measured_db(h, n, 50.0, sr);
    const double hi = eq_measured_db(h, n, 10000.0, sr);
    printf("  pedal %.3f: %.0f Hz %.1f dB (%.1f), 50 Hz %.1f (%.1f), 10 kHz %.1f (%.1f)\n",
           cases[k][0], cases[k][1], pk, cases[k][2], lo, cases[k][3], hi,
           cases[k][4]);
    CHECK(fabs(pk - cases[k][2]) < 0.7);
    CHECK(fabs(lo - cases[k][3]) < 1.5);
    CHECK(fabs(hi - cases[k][4]) < 1.5);
    /* The peak is the peak: an eighth of an octave either side is lower. */
    CHECK(eq_measured_db(h, n, cases[k][1] * 1.09, sr) < pk);
    CHECK(eq_measured_db(h, n, cases[k][1] / 1.09, sr) < pk);
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
  /* A 900 Hz sine at 0.2, at most +14 dB (1.0): its own largest step is
   * 1.0 * 2 sin(pi * 900 / 48000) = 0.118. */
  CHECK(max_step < 0.13f);
  dyn_free(fx);
  free(x);
  free(in);
}

/* ---- all four, the Mod kind (test_engine_modulation.h) included ---- */

static void test_mod_offline_equals_live(void) {
  printf("test_mod_offline_equals_live\n");
  const int32_t kinds[4] = {LE_FX_DOUBLER, LE_FX_CHORUS, LE_FX_WAH, LE_FX_MOD};
  const int sr = 48000;
  const int n = 4096;
  for (int k = 0; k < 4; ++k) {
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

/* A chain holding a chorus, a doubler or the Mod sounds different each
 * lap, so the lane stays live and says why, until that entry is bypassed
 * (or, for the chorus and the Mod's chorus, its mix is at 0 %; the
 * doubler's copy wanders even then); a wah prints. */
static void test_cache_free_running_stays_live(void) {
  printf("test_cache_free_running_stays_live\n");
  const int32_t kinds[4] = {LE_FX_CHORUS, LE_FX_DOUBLER, LE_FX_WAH, LE_FX_MOD};
  for (int k = 0; k < 4; ++k) {
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
      /* A chorus at 0 % mix is the identity, so the lane prints; and
       * bypassed at full mix, the same. */
      if (kinds[k] == LE_FX_CHORUS || kinds[k] == LE_FX_MOD) {
        CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 0.0f) == LE_OK);
        drain(a);
        le_engine_get_lane_cache(a, 0, 0, &info); /* sees the new key */
        pump_frames(a, 0.0f, CACHE_SETTLE);
        CHECK(cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000));
        CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 1.0f) == LE_OK);
      }
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
  const int32_t kinds[4] = {LE_FX_DOUBLER, LE_FX_CHORUS, LE_FX_WAH, LE_FX_MOD};
  for (int k = 0; k < 4; ++k) {
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
  test_doubler_matches_the_capture();
  test_doubler_survives_a_rate_change();
  test_wah_matches_the_capture();
  test_mod_offline_equals_live();
  test_cache_free_running_stays_live();
  test_mod_on_a_lane();
}
