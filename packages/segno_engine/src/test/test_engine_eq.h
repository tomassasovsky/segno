/* The EQ kind (LE_FX_EQ, #887 part 4) and the per-kind heap state it is the
 * first user of. Included by test_engine_core.c. */

void le_eq_design_for_test(int kind, double hz, double db, double q, int sr,
                           double c[5]);

/* The setting that gives `value` on EQ descriptor row [p]. */
static float eq_setting(int32_t p, double value) {
  le_fx_param_desc d;
  CHECK(le_fx_param_info(LE_FX_EQ, p, &d) == LE_OK);
  if (d.curve == LE_FX_CURVE_EXPONENTIAL) {
    return (float)(log(value / d.at_min) / log((double)d.at_max / d.at_min));
  }
  return (float)((value - d.at_min) / ((double)d.at_max - d.at_min));
}

/* A standalone state with slot 0 prepared as an EQ and settled on. */
static le_fx_state* eq_state(void) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(le_fx_prepare(fx, 0, LE_FX_EQ, 48000) == LE_OK);
  le_fx_enable_seed_settled(fx, 0);
  return fx;
}

static void eq_free(le_fx_state* fx) {
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* Runs [n] samples of `in` (left and right alike) through slot 0. */
static void eq_run(le_fx_state* fx, int32_t type, const float* p, int sr,
                   const float* in, float* out_l, float* out_r, int n) {
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  memset(params, 0, sizeof(params));
  memcpy(params[0], p, sizeof(float) * LE_FX_PARAMS);
  const int32_t types[1] = {type};
  for (int i = 0; i < n; ++i) {
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    out_l[i] = l;
    if (out_r) out_r[i] = r;
  }
}

/* |H(f)| of a biquad cascade, in dB. */
static double eq_design_db(const double c[][5], int bands, double f, int sr) {
  const double w = 2.0 * M_PI * f / sr;
  double mag = 1.0;
  for (int b = 0; b < bands; ++b) {
    const double nr = c[b][0] + c[b][1] * cos(-w) + c[b][2] * cos(-2 * w);
    const double ni = c[b][1] * sin(-w) + c[b][2] * sin(-2 * w);
    const double dr = 1.0 + c[b][3] * cos(-w) + c[b][4] * cos(-2 * w);
    const double di = c[b][3] * sin(-w) + c[b][4] * sin(-2 * w);
    mag *= sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
  }
  return 20.0 * log10(mag);
}

/* The response of an impulse response at f, in dB (a single DFT bin). */
static double eq_measured_db(const float* h, int n, double f, int sr) {
  double re = 0.0;
  double im = 0.0;
  for (int i = 0; i < n; ++i) {
    re += h[i] * cos(2.0 * M_PI * f * i / sr);
    im -= h[i] * sin(2.0 * M_PI * f * i / sr);
  }
  return 10.0 * log10(re * re + im * im);
}

/* The kernel's magnitude response is the RBJ design's within 0.1 dB at every
 * band, at 48 and 96 kHz, and its bands land where the settings say: a peak's
 * gain at its centre, a shelf's gain far into its shelf, a cut's -3 dB at its
 * corner. */
static void test_eq_magnitude_matches_design(void) {
  printf("test_eq_magnitude_matches_design\n");
  const int rates[2] = {48000, 96000};
  for (int ri = 0; ri < 2; ++ri) {
    const int sr = rates[ri];
    float p[LE_FX_PARAMS] = {0};
    p[0] = eq_setting(0, 60.0);     /* low cut */
    p[1] = eq_setting(1, 6.0);      /* low shelf +6 dB */
    p[2] = eq_setting(2, 150.0);    /*   at 150 Hz */
    p[3] = eq_setting(3, 0.7);
    p[4] = eq_setting(4, -9.0);     /* low-mid -9 dB */
    p[5] = eq_setting(5, 400.0);
    p[6] = eq_setting(6, 2.0);
    p[7] = eq_setting(7, 12.0);     /* high-mid +12 dB */
    p[8] = eq_setting(8, 3000.0);
    p[9] = eq_setting(9, 1.0);
    p[10] = eq_setting(10, -4.0);   /* high shelf -4 dB */
    p[11] = eq_setting(11, 8000.0);
    p[12] = eq_setting(12, 0.7);
    p[13] = eq_setting(13, 15000.0); /* high cut */
    p[14] = eq_setting(14, 3.0);    /* air +3 dB */
    const int n = 1 << 16;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* h = (float*)calloc((size_t)n, sizeof(float));
    in[0] = 1.0f;
    le_fx_state* fx = eq_state();
    eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, n);
    eq_free(fx);

    double c[7][5];
    le_eq_design_for_test(0, 60.0, 0.0, M_SQRT1_2, sr, c[0]);
    le_eq_design_for_test(1, 150.0, 6.0, 0.7, sr, c[1]);
    le_eq_design_for_test(2, 400.0, -9.0, 2.0, sr, c[2]);
    le_eq_design_for_test(3, 3000.0, 12.0, 1.0, sr, c[3]);
    le_eq_design_for_test(4, 8000.0, -4.0, 0.7, sr, c[4]);
    le_eq_design_for_test(5, 12000.0, 3.0, M_SQRT1_2, sr, c[5]);
    le_eq_design_for_test(6, 15000.0, 0.0, M_SQRT1_2, sr, c[6]);
    const double probes[] = {30, 60, 100, 150, 250, 400, 700, 1000, 2000,
                             3000, 5000, 8000, 12000, 15000, 18000};
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); ++i) {
      const double want = eq_design_db(c, 7, probes[i], sr);
      const double got = eq_measured_db(h, n, probes[i], sr);
      if (fabs(want - got) >= 0.1) {
        printf("  sr %d at %.0f Hz: design %.3f dB, kernel %.3f dB\n", sr,
               probes[i], want, got);
      }
      CHECK(fabs(want - got) < 0.1);
    }
    free(in);
    free(h);
  }

  /* Each band alone lands where its setting says (independent of the
   * design function above). */
  const int sr = 48000;
  const int n = 1 << 16;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  float flat[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_EQ, flat);
  flat[0] = 0.0f; /* low cut off */
  flat[13] = 1.0f; /* high cut off */
  float p[LE_FX_PARAMS];
  /* A flat EQ (every gain 0 dB, both cuts off) is the identity. */
  memcpy(p, flat, sizeof(p));
  le_fx_state* fx = eq_state();
  eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, 64);
  eq_free(fx);
  CHECK(h[0] == 1.0f);
  for (int i = 1; i < 64; ++i) CHECK(h[i] == 0.0f);
  /* A peak: +12 dB at its centre. */
  memcpy(p, flat, sizeof(p));
  p[7] = eq_setting(7, 12.0);
  p[8] = eq_setting(8, 1000.0);
  fx = eq_state();
  eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, n);
  eq_free(fx);
  CHECK(fabs(eq_measured_db(h, n, 1000.0, sr) - 12.0) < 0.1);
  /* A low shelf: -6 dB far below it. */
  memcpy(p, flat, sizeof(p));
  p[1] = eq_setting(1, -6.0);
  p[2] = eq_setting(2, 200.0);
  fx = eq_state();
  eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, n);
  eq_free(fx);
  CHECK(fabs(eq_measured_db(h, n, 10.0, sr) + 6.0) < 0.1);
  /* A low cut: -3 dB at its corner (Butterworth). */
  memcpy(p, flat, sizeof(p));
  p[0] = eq_setting(0, 100.0);
  fx = eq_state();
  eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, n);
  eq_free(fx);
  CHECK(fabs(eq_measured_db(h, n, 100.0, sr) + 3.0103) < 0.1);
  free(in);
  free(h);
}

/* A gain change glides over about 10 ms instead of stepping: a sine through
 * a peak whose gain jumps 0 -> +18 dB changes sample to sample by no more
 * than the sine itself does at that level, and arrives within 60 ms. */
static void test_eq_gain_change_glides(void) {
  printf("test_eq_gain_change_glides\n");
  const int sr = 48000;
  const int n = sr / 5;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 0.1f * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_EQ, p);
  p[0] = 0.0f;
  p[13] = 1.0f;
  p[8] = eq_setting(8, 1000.0);
  le_fx_state* fx = eq_state();
  /* Clock it like an offline render, so the update cadence is real. */
  fx->clocked = 1;
  const int half = n / 2;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_EQ};
  float max_step = 0.0f;
  float prev = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (i == half) p[7] = 1.0f; /* +18 dB */
    memcpy(params[0], p, sizeof(p));
    fx->clock = (uint32_t)i;
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    out[i] = l;
    if (i > half - 10 && i < half + sr / 100) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    prev = l;
  }
  /* At +18 dB the 1 kHz sine is 0.794 peak; its own largest step at 48 kHz
   * is 0.794 * 2 sin(pi * 1000 / 48000) = 0.104. */
  CHECK(max_step < 0.11f);
  /* 60 ms after the change the level is the target's. */
  float peak = 0.0f;
  for (int i = half + 3 * sr / 50; i < n; ++i) {
    if (fabsf(out[i]) > peak) peak = fabsf(out[i]);
  }
  CHECK(fabsf(20.0f * log10f(peak / 0.1f) - 18.0f) < 0.2f);
  eq_free(fx);
  free(in);
  free(out);
}

/* A slot keeps one block per kind it has held, never reads another kind's
 * bytes, and starts its own clean when it comes back to it: EQ -> delay ->
 * EQ sounds exactly like a fresh EQ from the second EQ on, and the slot's
 * arena does not grow. */
static void test_eq_retype_is_clean(void) {
  printf("test_eq_retype_is_clean\n");
  const int sr = 48000;
  const int n = 2048;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* a = (float*)malloc(sizeof(float) * (size_t)n);
  float* b = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = (float)((i * 7919) % 2001 - 1000) / 1000.0f;
  float eq[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_EQ, eq);
  eq[7] = 0.9f;
  float dl[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_DELAY, dl);

  le_fx_state* fresh = eq_state();
  eq_run(fresh, LE_FX_EQ, eq, sr, in, a, NULL, n);

  le_fx_state* fx = eq_state();
  CHECK(le_fx_prepare(fx, 0, LE_FX_DELAY, sr) == LE_OK);
  eq_run(fx, LE_FX_EQ, eq, sr, in, b, NULL, n);
  le_fx_kinds* k = atomic_load(&fx->kinds);
  CHECK(k != NULL);
  const size_t used = k->slot[0].arena.used;
  CHECK(used > 0);
  /* The ring handler resets the slot on each type change. */
  le_fx_entry_reset(fx, 0);
  eq_run(fx, LE_FX_DELAY, dl, sr, in, b, NULL, n);
  le_fx_entry_reset(fx, 0);
  CHECK(le_fx_prepare(fx, 0, LE_FX_EQ, sr) == LE_OK); /* already there */
  eq_run(fx, LE_FX_EQ, eq, sr, in, b, NULL, n);
  CHECK(k->slot[0].arena.used == used);
  for (int i = 0; i < n; ++i) CHECK(a[i] == b[i]);
  /* An EQ the control thread never prepared passes through. */
  le_fx_state* bare = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  le_fx_enable_seed_settled(bare, 0);
  eq_run(bare, LE_FX_EQ, eq, sr, in, b, NULL, 64);
  for (int i = 0; i < 64; ++i) CHECK(b[i] == in[i]);
  free(bare);
  eq_free(fresh);
  eq_free(fx);
  free(in);
  free(a);
  free(b);
}

/* The update cadence follows the engine clock, so a live owner (clock read
 * through clock_src) and an offline render (clock set per frame) recompute
 * on the same frames and produce the same samples while a setting moves. */
static void test_eq_offline_equals_live(void) {
  printf("test_eq_offline_equals_live\n");
  const int sr = 48000;
  const int n = 4096;
  _Atomic uint32_t frame = 1000;
  le_fx_state* live = eq_state();
  live->clock_src = &frame;
  le_fx_state* off = eq_state();
  off->clocked = 1;
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_EQ, p);
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_EQ};
  for (int i = 0; i < n; ++i) {
    if (i == 777) p[4] = 0.95f; /* a move mid-run */
    memcpy(params[0], p, sizeof(p));
    const float x = sinf((float)i * 0.05f);
    float ll = x, lr = x, ol = x, orr = x;
    off->clock = atomic_load(&frame);
    fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
    fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
    CHECK(ll == ol && lr == orr);
    atomic_fetch_add(&frame, 1u);
  }
  CHECK(!le_fx_type_drains(LE_FX_EQ));
  eq_free(live);
  eq_free(off);
}

/* An EQ on a lane, through the engine's own setters and a recipe. */
static void test_eq_on_a_lane(void) {
  printf("test_eq_on_a_lane\n");
  le_engine* e = make_configured_engine();
  establish_loop(e, 0.5f);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_EQ) == LE_OK);
  /* Every cell the EQ reads takes a write; the next does not. */
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 14, 0.5f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 15, 0.5f) == LE_ERR_INVALID);
  /* Low shelf -18 dB far below everything: a DC loop drops by about that. */
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
  float out[64];
  for (int k = 0; k < 600; ++k) process_const(e, 0.0f, 64, out);
  CHECK(fabsf(out[63]) < 0.5f * 0.2f);
  CHECK(fabsf(out[63]) > 0.0f);
  le_engine_destroy(e);

  /* A recipe takes the EQ too. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 2, 1000) == LE_OK);
  le_fx_recipe r = {.count = 1, .enabled = 1};
  r.type[0] = LE_FX_EQ;
  r.slot_enabled[0] = 1;
  r.level[0] = 1.0f;
  le_fx_defaults(LE_FX_EQ, r.params[0]);
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 7, &r) == LE_OK);
  float in[64] = {0};
  float o2[128];
  le_engine_process(e, o2, in, 64);
  le_engine_drain_events(e);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 7);
  le_engine_destroy(e);
}

static void run_eq_tests(void) {
  test_eq_magnitude_matches_design();
  test_eq_gain_change_glides();
  test_eq_retype_is_clean();
  test_eq_offline_equals_live();
  test_eq_on_a_lane();
}
