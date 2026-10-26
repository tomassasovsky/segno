/* The EQ kind (LE_FX_EQ, #887 part 4) and the per-kind heap state it is the
 * first user of. Included by test_engine_core.c. */

void le_eq_design_for_test(int kind, double hz, double db, double q, int sr,
                           double c[5]);
void le_eq_bell_for_test(double hz, double db, double q, int sr, double c[5]);
void le_eq_band_design_for_test(int b, int shelves, double hz, double db,
                                double q, int sr, double c[5]);

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

/* The kernel's impulse response through slot 0 at [sr], [n] samples. */
static float* eq_impulse(const float* p, int sr, int n) {
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  le_fx_state* fx = eq_state();
  eq_run(fx, LE_FX_EQ, p, sr, in, h, NULL, n);
  eq_free(fx);
  free(in);
  return h;
}

/* The layout positions (the "layout" row). */
enum { EQL_SHELVES, EQL_CUTS, EQL_BELLS };

/* A flat EQ (every gain 0 dB) in [layout] (EQL_*), the cuts at the ends of
 * their ranges. */
static void eq_flat(float* p, int layout) {
  memset(p, 0, sizeof(float) * LE_FX_PARAMS);
  le_fx_defaults(LE_FX_EQ, p);
  p[0] = 0.0f;
  p[13] = 1.0f;
  p[14] = 0.5f * (float)layout;
}

/* The kernel runs its bands' designs (le_eq_band_design: at 96 kHz,
 * corrected to the 48 kHz responses) within 0.1 dB, at 48 and 96 kHz. The bell is the identity at 0 dB, and a
 * cut is the exact inverse of the same boost. */
static void test_eq_kernel_matches_design(void) {
  printf("test_eq_kernel_matches_design\n");
  const int rates[2] = {48000, 96000};
  const double probes[] = {30, 60, 100, 150, 250, 400, 700, 1000, 2000,
                           3000, 5000, 8000, 12000, 15000, 18000};
  const int n = 1 << 16;
  for (int ri = 0; ri < 2; ++ri) {
    const int sr = rates[ri];
    for (int li = 0; li < 2; ++li) {
      const int layout = li == 0 ? EQL_CUTS : EQL_SHELVES;
      float p[LE_FX_PARAMS];
      eq_flat(p, layout);
      p[0] = eq_setting(0, 60.0);     /* low cut (EQL_CUTS only) */
      p[1] = eq_setting(1, 6.0);      /* low band +6 dB */
      p[2] = eq_setting(2, 150.0);    /*   at 150 Hz */
      p[3] = eq_setting(3, 0.7);
      p[4] = eq_setting(4, -9.0);     /* low-mid -9 dB */
      p[5] = eq_setting(5, 400.0);
      p[6] = eq_setting(6, 2.0);
      p[7] = eq_setting(7, 12.0);     /* high-mid +12 dB */
      p[8] = eq_setting(8, 3000.0);
      p[9] = eq_setting(9, 1.0);
      p[10] = eq_setting(10, -4.0);   /* high band -4 dB */
      p[11] = eq_setting(11, 8000.0);
      p[12] = eq_setting(12, 0.7);
      p[13] = eq_setting(13, 15000.0); /* high cut (EQL_CUTS only) */
      float* h = eq_impulse(p, sr, n);
      double c[6][5];
      int bands = 0;
      const int sh = layout == EQL_SHELVES;
      const double q2 = M_SQRT1_2;
      if (!sh) le_eq_band_design_for_test(0, sh, 60.0, 0.0, q2, sr, c[bands++]);
      le_eq_band_design_for_test(1, sh, 150.0, 6.0, 0.7, sr, c[bands++]);
      le_eq_band_design_for_test(2, sh, 400.0, -9.0, 2.0, sr, c[bands++]);
      le_eq_band_design_for_test(3, sh, 3000.0, 12.0, 1.0, sr, c[bands++]);
      le_eq_band_design_for_test(4, sh, 8000.0, -4.0, 0.7, sr, c[bands++]);
      if (!sh) le_eq_band_design_for_test(5, sh, 15000.0, 0.0, q2, sr, c[bands++]);
      for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); ++i) {
        const double want = eq_design_db(c, bands, probes[i], sr);
        const double got = eq_measured_db(h, n, probes[i], sr);
        if (fabs(want - got) >= 0.1) {
          printf("  sr %d layout %d at %.0f Hz: design %.3f dB, kernel %.3f dB\n",
                 sr, layout, probes[i], want, got);
        }
        CHECK(fabs(want - got) < 0.1);
      }
      free(h);
    }
  }

  /* The bell: its gain at the centre, unity at 0 dB, and a cut the exact
   * inverse of the boost. */
  double up[1][5];
  double down[1][5];
  le_eq_bell_for_test(1000.0, 18.0, 1.0, 48000, up[0]);
  le_eq_bell_for_test(1000.0, -18.0, 1.0, 48000, down[0]);
  CHECK(fabs(eq_design_db(up, 1, 1000.0, 48000) - 18.0) < 1e-6);
  for (double f = 20.0; f < 24000.0; f *= 1.5) {
    CHECK(fabs(eq_design_db(up, 1, f, 48000) + eq_design_db(down, 1, f, 48000)) <
          1e-9);
  }
  double flat[1][5];
  le_eq_bell_for_test(1000.0, 0.0, 1.0, 48000, flat[0]);
  for (double f = 20.0; f < 24000.0; f *= 1.5) {
    CHECK(fabs(eq_design_db(flat, 1, f, 48000)) < 1e-9);
  }
}

/* One measured Looper X band (#891, docs/plan/2026-10-23-looperx-eq-
 * measured.md): the layout and the band's settings (LE_FX_EQ_PARAMS rows
 * gain, frequency, Q), and the response the captures show against the same
 * rack with the band flat, in dB at the probe frequencies. */
typedef struct eq_measured_case {
  const char* name;
  int layout;
  int row; /* the band's gain row; frequency and Q follow it */
  double hz, db, q;
  double tol_db;
  double want[11];
} eq_measured_case;

static const double EQ_MEASURED_HZ[11] = {32,   63,   125,  250,   500,  1000,
                                          2000, 4000, 8000, 12000, 16000};

/* The settings are the captures' fits (or, for the Vocal family, the
 * nominal values the rack variant fixes); the probes are the captures. */
static const eq_measured_case EQ_MEASURED[] = {
    {"Ed's Low +18 @90 Q0.4", EQL_CUTS, 1, 89.99, 18.0, 0.3999, 0.05,
     {15.132, 17.652, 17.704, 15.196, 10.805, 6.054, 2.481, 0.745, 0.172,
      0.058, 0.019}},
    {"Ed's Lo Mid +18 @101.5 Q10", EQL_CUTS, 4, 101.49, 18.0, 9.9993, 0.05,
     {0.318, 2.114, 6.370, 0.593, 0.119, 0.028, 0.007, 0.002, 0.000, 0.000,
      0.000}},
    {"Ed's Hi Mid +18 @16k Q2.02", EQL_CUTS, 7, 16000.0, 18.0, 2.02, 0.05,
     {0.000, 0.002, 0.006, 0.024, 0.093, 0.363, 1.315, 3.966, 9.306, 14.363,
      18.000}},
    {"Ed's High -18 @20k Q2.025", EQL_CUTS, 10, 20000.0, -18.0, 2.025, 0.05,
     {-0.000, -0.001, -0.005, -0.019, -0.075, -0.293, -1.075, -3.335, -7.926,
      -11.890, -15.537}},
    {"Ed's High +9 @20k Q2.025", EQL_CUTS, 10, 20000.0, 9.0, 2.025, 0.05,
     {0.000, 0.000, 0.001, 0.002, 0.008, 0.034, 0.134, 0.528, 1.991, 4.177,
      6.893}},
    {"Drum Low shelf +12 @200 Q0.5", EQL_SHELVES, 1, 200.0, 12.0, 0.5, 0.05,
     {11.677, 10.852, 8.548, 4.731, 1.736, 0.493, 0.127, 0.031, 0.007, 0.002,
      0.001}},
    {"Drum High shelf -12 @4k Q0.7", EQL_SHELVES, 10, 4000.0, -12.0, 0.7, 0.05,
     {-0.000, -0.000, -0.000, -0.001, -0.008, -0.073, -0.891, -6.000, -11.269,
      -11.899, -11.984}},
    {"Drum Mid +18 @565.7 Q0.9", EQL_SHELVES, 4, 565.7, 18.0, 0.9, 0.05,
     {0.955, 2.923, 6.884, 12.517, 17.793, 14.709, 8.707, 3.959, 1.196, 0.435,
      0.150}},
    {"Vocal Low +18", EQL_BELLS, 1, 300.0, 18.0, 3.6, 0.05,
     {0.236, 0.901, 3.414, 13.737, 6.939, 1.804, 0.459, 0.112, 0.024, 0.008,
      0.003}},
    {"Vocal Mid -18", EQL_BELLS, 4, 900.0, -18.0, 1.2, 0.15,
     {-0.231, -0.837, -2.679, -6.664, -13.054, -17.733, -10.845, -5.094,
      -1.637, -0.611, -0.213}},
    {"Vocal High +9", EQL_BELLS, 7, 2700.0, 9.0, 1.2, 0.15,
     {0.004, 0.013, 0.049, 0.223, 0.736, 2.631, 7.440, 6.558, 1.868, 0.664,
      0.227}},
    {"Vocal Air +18", EQL_BELLS, 10, 8100.0, 18.0, 3.6, 0.15,
     {0.001, 0.003, 0.009, 0.066, 0.127, 0.450, 1.413, 4.934, 17.872, 7.584,
      2.846}},
    {"Lo-Fi Para +18 @1386 Q0.8", EQL_CUTS, 4, 1385.92, 17.981, 0.7978, 0.1,
     {0.220, 0.796, 2.538, 6.239, 11.515, 16.936, 16.678, 11.035, 5.382, 2.582,
      1.038}},
    {"Lo-Fi Para +18 @16k Q0.8", EQL_CUTS, 4, 15994.18, 18.003, 0.8013, 0.1,
     {0.002, 0.010, 0.037, 0.148, 0.563, 1.908, 5.034, 9.743, 14.778, 17.175,
      18.000}},
    {"Rhythmic +18 @1384 Q1.0", EQL_CUTS, 4, 1384.37, 18.008, 1.0011, 0.1,
     {0.143, 0.529, 1.798, 4.915, 10.072, 16.448, 16.092, 9.562, 4.113, 1.757,
      0.597}},
};

/* Each measured band, run through the kernel against the same layout with
 * the band flat, lands on the captures within the case's tolerance: 0.05 dB
 * where the captures fit the design exactly, 0.1 to 0.15 dB where a fit or
 * the nominal Vocal centres leave that much. */
static void test_eq_matches_measured(void) {
  printf("test_eq_matches_measured\n");
  const int sr = 48000;
  const int n = 1 << 16;
  double worst = 0.0;
  for (size_t ci = 0; ci < sizeof(EQ_MEASURED) / sizeof(EQ_MEASURED[0]); ++ci) {
    const eq_measured_case* m = &EQ_MEASURED[ci];
    float ref[LE_FX_PARAMS];
    eq_flat(ref, m->layout);
    float p[LE_FX_PARAMS];
    memcpy(p, ref, sizeof(p));
    p[m->row] = eq_setting(m->row, m->db);
    p[m->row + 1] = eq_setting(m->row + 1, m->hz);
    p[m->row + 2] = eq_setting(m->row + 2, m->q);
    float* h = eq_impulse(p, sr, n);
    float* h0 = eq_impulse(ref, sr, n);
    for (int i = 0; i < 11; ++i) {
      const double f = EQ_MEASURED_HZ[i];
      const double got = eq_measured_db(h, n, f, sr) - eq_measured_db(h0, n, f, sr);
      const double err = fabs(got - m->want[i]);
      if (err > worst) worst = err;
      if (err >= m->tol_db) {
        printf("  %s at %.0f Hz: measured %.3f dB, kernel %.3f dB\n", m->name, f,
               m->want[i], got);
      }
      CHECK(err < m->tol_db);
    }
    free(h);
    free(h0);
  }
  printf("  worst error against the captures: %.3f dB\n", worst);
}

/* The cuts never switch off: at the ends of their ranges they are a 20 Hz
 * high-pass and a 20 kHz low-pass, -3.01 dB at 20 Hz and -0.63 dB at 32 Hz,
 * -0.20 dB at 16 kHz and -3.01 dB at 20 kHz (measured). The layouts without
 * cuts (Drum, Vocal) are the identity when flat, sample for sample. */
static void test_eq_cuts_and_layouts(void) {
  printf("test_eq_cuts_and_layouts\n");
  const int sr = 48000;
  const int n = 1 << 16;
  float p[LE_FX_PARAMS];
  eq_flat(p, EQL_CUTS);
  CHECK(fxd_get(LE_FX_EQ, 0).flags == 0 && fxd_get(LE_FX_EQ, 13).flags == 0);
  float* h = eq_impulse(p, sr, n);
  const double hz[4] = {20.0, 32.0, 16000.0, 20000.0};
  const double want[4] = {-3.01, -0.63, -0.20, -3.01};
  for (int i = 0; i < 4; ++i) {
    const double got = eq_measured_db(h, n, hz[i], sr);
    if (fabs(got - want[i]) >= 0.02) {
      printf("  the cuts at %.0f Hz: measured %.2f dB, kernel %.3f dB\n", hz[i],
             want[i], got);
    }
    CHECK(fabs(got - want[i]) < 0.02);
  }
  free(h);
  const int bare[2] = {EQL_SHELVES, EQL_BELLS};
  for (int li = 0; li < 2; ++li) {
    eq_flat(p, bare[li]);
    p[0] = eq_setting(0, 1000.0); /* a cut setting a layout without cuts ignores */
    h = eq_impulse(p, sr, 64);
    CHECK(h[0] == 1.0f);
    for (int i = 1; i < 64; ++i) CHECK(h[i] == 0.0f);
    free(h);
  }
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
  float p[LE_FX_PARAMS];
  eq_flat(p, EQL_BELLS); /* no cuts */
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

/* Switching the cuts in glides too: a 100 Hz sine through a layout without
 * cuts that switches to one with a 1 kHz low cut fades out over the
 * smoothing time instead of dropping in one sample, and a gain sweep through
 * 0 dB never resets the band (its output stays continuous). */
static void test_eq_switches_glide(void) {
  printf("test_eq_switches_glide\n");
  const int sr = 48000;
  const int n = sr / 5;
  float p[LE_FX_PARAMS];
  eq_flat(p, EQL_BELLS); /* no cuts */
  p[0] = eq_setting(0, 1000.0);
  le_fx_state* fx = eq_state();
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_EQ};
  float prev = 0.0f;
  float max_step = 0.0f;
  float tail = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (i == n / 4) p[14] = 0.5f; /* the cuts come in */
    /* A gain sweep from +6 to -6 dB through 0 across the second half. */
    if (i >= n / 2) p[7] = 0.5f + (1.0f / 6.0f) * (1.0f - 4.0f * (float)(i - n / 2) / n);
    memcpy(params[0], p, sizeof(p));
    fx->clock = (uint32_t)i;
    const float x = 0.5f * sinf(2.0f * (float)M_PI * 100.0f * i / sr);
    float l = x, r = x;
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    if (i > 0) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    prev = l;
    if (i > n / 4 + sr / 20 && i < n / 2 && fabsf(l) > tail) tail = fabsf(l);
  }
  /* The sine's own largest step is 0.0065; a switched-in filter would jump
   * by up to 0.5. The cut's amount glides in 32-frame updates. */
  CHECK(max_step < 0.03f);
  /* And the cut did engage: 100 Hz is ~27 dB down a 1 kHz 12 dB/oct cut. */
  CHECK(tail < 0.5f * 0.06f);
  eq_free(fx);
}

/* A layout change that turns the outer bands from bells into shelves never
 * steps: the bands glide to 0 dB, change shape there and glide back (about
 * a quarter of a second in all), and land where an EQ set up in the new
 * layout plays. */
static void test_eq_layout_change_glides(void) {
  printf("test_eq_layout_change_glides\n");
  const int sr = 48000;
  const int n = sr;
  float p[LE_FX_PARAMS];
  eq_flat(p, EQL_BELLS);
  p[1] = eq_setting(1, -12.0); /* low band -12 dB at 1 kHz */
  p[2] = eq_setting(2, 1000.0);
  p[10] = eq_setting(10, -12.0); /* high band -12 dB at 1.2 kHz */
  p[11] = eq_setting(11, 1200.0);
  float shelves[LE_FX_PARAMS];
  memcpy(shelves, p, sizeof(shelves));
  shelves[14] = 0.5f * EQL_SHELVES;
  le_fx_state* fx = eq_state();
  le_fx_state* ref = eq_state();
  fx->clocked = 1;
  ref->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  static float ref_params[LE_FX_MAX][LE_FX_PARAMS];
  memcpy(ref_params[0], shelves, sizeof(shelves));
  const int32_t types[1] = {LE_FX_EQ};
  float prev = 0.0f;
  float max_step = 0.0f;
  float worst = 0.0f;
  for (int i = 0; i < n; ++i) {
    memcpy(params[0], i < n / 4 ? p : shelves, sizeof(p));
    fx->clock = (uint32_t)i;
    ref->clock = (uint32_t)i;
    const float x = 0.1f * sinf(2.0f * (float)M_PI * 100.0f * i / sr);
    float l = x, r = x, rl = x, rr = x;
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    fx_apply_chain(ref, sr, sr, &rl, &rr, 1, types, ref_params, NULL);
    if (i > 0 && fabsf(l - prev) > max_step) max_step = fabsf(l - prev);
    prev = l;
    if (i > n / 2 && fabsf(l - rl) > worst) worst = fabsf(l - rl);
  }
  /* A 100 Hz probe: its own largest step is 0.1 * 2 sin(pi / 480) = 0.0013,
   * and a bell switched to a shelf at once would jump by about 0.07. The
   * glide moves the gain in 32-frame updates, the first of which (0.77 dB)
   * moves the output by about 0.0085. */
  CHECK(max_step < 0.012f);
  CHECK(worst < 1e-4f);
  eq_free(fx);
  eq_free(ref);
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
    if (i == 2000) p[14] = 0.0f; /* and the shelves layout */
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
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 14, 0.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 15, 0.5f) == LE_ERR_INVALID);
  /* The shelves layout (14 = 0, set above, has no cuts), its low shelf
   * -18 dB far below everything: a DC loop drops by about that. */
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
  test_eq_kernel_matches_design();
  test_eq_matches_measured();
  test_eq_cuts_and_layouts();
  test_eq_gain_change_glides();
  test_eq_switches_glide();
  test_eq_layout_change_glides();
  test_eq_retype_is_clean();
  test_eq_offline_equals_live();
  test_eq_on_a_lane();
}
