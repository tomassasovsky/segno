/* The EQ kind's bands at 44.1, 48 and 96 kHz against their 48 kHz responses
 * (#1436). Included by test_engine_core.c after test_engine_eq.h, whose
 * declarations and helpers it reuses. */

/* The stated tolerances, in dB: the 95th percentile and the worst case of
 * the swept settings, at 44.1 and 96 kHz (48 kHz is exact). The worst cases
 * are settings a single biquad cannot follow at that rate without lifting
 * the band above 24 kHz: at 96 kHz, deep wide cuts (Q under about 0.6)
 * near 2 to 5 kHz, high shelves with Q over about 3 above 14 kHz, and high
 * cuts between about 3 and 8 kHz, whose error is in the stopband. */
#define EQR_BELL_P95_44 0.1
#define EQR_BELL_MAX_44 0.35
#define EQR_BELL_P95_96 0.6
#define EQR_BELL_MAX_96 5.5
#define EQR_HS_P95_44 0.75
#define EQR_HS_MAX_44 9
#define EQR_HS_P95_96 1.3
#define EQR_HS_MAX_96 20.5
#define EQR_LS_P95_44 0.01
#define EQR_LS_MAX_44 0.05
#define EQR_LS_P95_96 0.03
#define EQR_LS_MAX_96 0.16
#define EQR_LP_P95_44 0.11
#define EQR_LP_MAX_44 0.65
#define EQR_LP_P95_96 1.05
#define EQR_LP_MAX_96 3.4
#define EQR_HP_P95_44 0.002
#define EQR_HP_MAX_44 0.005
#define EQR_HP_P95_96 0.005
#define EQR_HP_MAX_96 0.015

/* |H| in dB of one design at f. */
static double eqr_db(const double c[5], double f, int sr) {
  const double w = 2.0 * M_PI * f / sr;
  const double nr = c[0] + c[1] * cos(w) + c[2] * cos(2 * w);
  const double ni = -c[1] * sin(w) - c[2] * sin(2 * w);
  const double dr = 1.0 + c[3] * cos(w) + c[4] * cos(2 * w);
  const double di = -c[3] * sin(w) - c[4] * sin(2 * w);
  return 10.0 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

/* The largest dB difference between band [b]'s design at [sr] and at
 * 48 kHz, over 20 Hz to 20 kHz (or 0.49 fs) where the 48 kHz response is
 * above -40 dB; and whether the design at [sr] is stable. */
/* The plain design (no correction) of band [b], as before #1436. */
static void eqr_plain(int b, int shelves, double hz, double db, double q,
                      int sr, double c[5]) {
  if (b == 0) {
    le_eq_design_for_test(0, hz, 0.0, q, sr, c);
  } else if (b == 5) {
    le_eq_design_for_test(5, hz, 0.0, q, sr, c);
  } else if (shelves && (b == 1 || b == 4)) {
    le_eq_design_for_test(b, hz, db, q, sr, c);
  } else {
    le_eq_bell_for_test(hz, db, q, sr, c);
  }
}

static double eqr_error_of(const double c[5], const double ref[5], int sr) {
  const double top = sr * 0.49 < 20000.0 ? sr * 0.49 : 20000.0;
  double worst = 0.0;
  for (int i = 0; i < 96; ++i) {
    const double f = 20.0 * pow(top / 20.0, i / 95.0);
    const double want = eqr_db(ref, f, 48000);
    if (want < -40.0) continue;
    const double err = fabs(eqr_db(c, f, sr) - want);
    if (err > worst) worst = err;
  }
  return worst;
}

static double eqr_error(int b, int shelves, double hz, double db, double q,
                        int sr, int* stable) {
  double c[5];
  double ref[5];
  le_eq_band_design_for_test(b, shelves, hz, db, q, sr, c);
  le_eq_band_design_for_test(b, shelves, hz, db, q, 48000, ref);
  *stable = fabs(c[4]) < 1.0 && fabs(c[3]) < 1.0 + c[4];
  return eqr_error_of(c, ref, sr);
}

static int eqr_cmp(const void* a, const void* b) {
  const double x = *(const double*)a;
  const double y = *(const double*)b;
  return x < y ? -1 : x > y;
}

/* One shape's sweep: its band, layout, and the ranges its settings take in
 * the EQ kind, swept off the correction grids' points; and the stated
 * tolerance at each rate (dB: the 95th percentile and the worst case). */
typedef struct eqr_shape {
  const char* name;
  int band;
  int shelves;
  double f_lo, f_hi, q_lo, q_hi, g_lo, g_hi;
  double p95[3], worst[3]; /* at 44.1, 48 and 96 kHz */
} eqr_shape;

/* Every band, at every setting swept, reproduces its 48 kHz magnitude
 * response within the shape's stated tolerance at 44.1 and 96 kHz, and
 * exactly at 48 kHz; every design is stable; and at 96 kHz no correction
 * lifts the band above 24 kHz (where the 48 kHz response says nothing) more
 * than 6 dB over the 48 kHz response's level at its top. */
static void test_eq_rate_matches_48k(void) {
  printf("test_eq_rate_matches_48k\n");
  static const eqr_shape shapes[] = {
      {"bell", 2, 0, 20.0, 20000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_BELL_P95_44, 1e-9, EQR_BELL_P95_96},
       {EQR_BELL_MAX_44, 1e-9, EQR_BELL_MAX_96}},
      {"high shelf", 4, 1, 1200.0, 20000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_HS_P95_44, 1e-9, EQR_HS_P95_96},
       {EQR_HS_MAX_44, 1e-9, EQR_HS_MAX_96}},
      {"low shelf", 1, 1, 20.0, 1000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_LS_P95_44, 1e-9, EQR_LS_P95_96},
       {EQR_LS_MAX_44, 1e-9, EQR_LS_MAX_96}},
      {"high cut", 5, 0, 120.0, 20000.0, M_SQRT1_2, M_SQRT1_2, 0.0, 0.0,
       {EQR_LP_P95_44, 1e-9, EQR_LP_P95_96},
       {EQR_LP_MAX_44, 1e-9, EQR_LP_MAX_96}},
      {"low cut", 0, 0, 20.0, 8000.0, M_SQRT1_2, M_SQRT1_2, 0.0, 0.0,
       {EQR_HP_P95_44, 1e-9, EQR_HP_P95_96},
       {EQR_HP_MAX_44, 1e-9, EQR_HP_MAX_96}},
  };
  const int rates[3] = {44100, 48000, 96000};
  enum { NF = 47, NQ = 7, NG = 9 };
  static double errs[NF * NQ * NG];
  static double plain[NF * NQ * NG];
  for (size_t s = 0; s < sizeof(shapes) / sizeof(shapes[0]); ++s) {
    const eqr_shape* sh = &shapes[s];
    const int nq = sh->q_lo == sh->q_hi ? 1 : NQ;
    const int ng = sh->g_lo == sh->g_hi ? 1 : NG;
    for (int r = 0; r < 3; ++r) {
      int n = 0;
      int unstable = 0;
      int ultra = 0;
      for (int i = 0; i < NF; ++i) {
        /* endpoints included; the rest falls between the grid's points */
        const double hz = sh->f_lo * pow(sh->f_hi / sh->f_lo, i / (NF - 1.0));
        for (int j = 0; j < nq; ++j) {
          const double q =
              nq == 1 ? sh->q_lo : sh->q_lo * pow(sh->q_hi / sh->q_lo, j / (nq - 1.0));
          for (int k = 0; k < ng; ++k) {
            const double db =
                ng == 1 ? 0.0 : sh->g_lo + (sh->g_hi - sh->g_lo) * (k + 0.37) / ng;
            int stable = 0;
            const double e =
                eqr_error(sh->band, sh->shelves, hz, db, q, rates[r], &stable);
            double c[5];
            double ref[5];
            eqr_plain(sh->band, sh->shelves, hz, db, q, rates[r], c);
            le_eq_band_design_for_test(sh->band, sh->shelves, hz, db, q, 48000, ref);
            plain[n] = eqr_error_of(c, ref, rates[r]);
            if (rates[r] > 48000) {
              /* Above 24 kHz: no higher than 6 dB over the 48 kHz response
               * at 24 kHz and at 20 kHz (the high cut: over -15 dB at
               * least), or the plain design's own level. */
              double d[5];
              le_eq_band_design_for_test(sh->band, sh->shelves, hz, db, q, rates[r], d);
              double cap = eqr_db(ref, 23990.0, 48000);
              if (cap < -40.0) cap = -40.0;
              const double at20k = eqr_db(ref, 20000.0, 48000);
              if (at20k > cap) cap = at20k;
              if (sh->band == 5 && cap < -15.0) cap = -15.0; /* a cut still */
              cap += 6.0;
              for (double fu = 24000.0; fu < 0.45 * rates[r]; fu += 1000.0) {
                const double own = eqr_db(c, fu, rates[r]);
                const double lim = own > cap ? own : cap;
                if (eqr_db(d, fu, rates[r]) > lim + 0.01) ++ultra;
              }
            }
            errs[n++] = e;
            if (!stable) ++unstable;
          }
        }
      }
      qsort(errs, (size_t)n, sizeof(double), eqr_cmp);
      qsort(plain, (size_t)n, sizeof(double), eqr_cmp);
      const double p95 = errs[(int)(0.95 * (n - 1))];
      const double worst = errs[n - 1];
      int over = 0;
      for (int i = 0; i < n; ++i) over += errs[i] > 0.5;
      printf("  %-10s at %5d Hz: worst %.3f dB, p95 %.3f dB, over 0.5 dB %4.1f%% of %d"
             " (plain design: worst %.3f, p95 %.3f)\n",
             sh->name, rates[r], worst, p95, 100.0 * over / n, n, plain[n - 1],
             plain[(int)(0.95 * (n - 1))]);
      CHECK(unstable == 0);
      CHECK(ultra == 0);
      CHECK(p95 <= sh->p95[r]);
      CHECK(worst <= sh->worst[r]);
      /* and never worse than the plain design */
      CHECK(p95 <= plain[(int)(0.95 * (n - 1))] + 1e-9);
      CHECK(worst <= plain[n - 1] + 1e-9);
    }
  }
}

/* A setting gliding across the correction grid moves the response
 * smoothly: a bell swept from 1 to 20 kHz in 2000 steps at 96 kHz, and a
 * gain swept from -18 to +18 dB, change the response at every probe by
 * little from step to step, so a glide never jumps. */
static void test_eq_rate_glide_is_continuous(void) {
  printf("test_eq_rate_glide_is_continuous\n");
  const double probes[6] = {1000, 4000, 8000, 12000, 16000, 19000};
  double prev[6];
  double worst = 0.0;
  for (int s = 0; s < 2000; ++s) {
    double c[5];
    const double hz = 1000.0 * pow(20.0, s / 1999.0);
    le_eq_band_design_for_test(3, 0, hz, 12.0, 2.0, 96000, c);
    for (int i = 0; i < 6; ++i) {
      const double v = eqr_db(c, probes[i], 96000);
      if (s > 0 && fabs(v - prev[i]) > worst) worst = fabs(v - prev[i]);
      prev[i] = v;
    }
  }
  printf("  frequency sweep: largest step %.3f dB\n", worst);
  CHECK(worst < 0.25);
  worst = 0.0;
  for (int s = 0; s < 2000; ++s) {
    double c[5];
    const double db = -18.0 + 36.0 * s / 1999.0;
    le_eq_band_design_for_test(3, 0, 15000.0, db, 3.0, 96000, c);
    for (int i = 0; i < 6; ++i) {
      const double v = eqr_db(c, probes[i], 96000);
      if (s > 0 && fabs(v - prev[i]) > worst) worst = fabs(v - prev[i]);
      prev[i] = v;
    }
  }
  printf("  gain sweep: largest step %.3f dB\n", worst);
  CHECK(worst < 0.25);
}

/* At 96 kHz the kernel, gliding a bell's frequency across the grid while a
 * sine plays, never steps, and a live owner and an offline render still
 * produce the same samples. */
static void test_eq_rate_kernel_glides(void) {
  printf("test_eq_rate_kernel_glides\n");
  const int sr = 96000;
  const int n = sr / 2;
  float p[LE_FX_PARAMS];
  eq_flat(p, EQL_CUTS);
  p[7] = eq_setting(7, 12.0);
  p[8] = eq_setting(8, 2000.0);
  le_fx_state* live = eq_state();
  le_fx_state* off = eq_state();
  _Atomic uint32_t frame = 0;
  live->clock_src = &frame;
  off->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_EQ};
  float prev = 0.0f;
  float max_step = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (i == n / 4) p[8] = eq_setting(8, 18000.0);
    memcpy(params[0], p, sizeof(p));
    off->clock = atomic_load(&frame);
    const float x = 0.05f * sinf(2.0f * (float)M_PI * 500.0f * i / sr);
    float ll = x, lr = x, ol = x, orr = x;
    fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
    fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
    CHECK(ll == ol && lr == orr);
    if (i > 0 && fabsf(ll - prev) > max_step) max_step = fabsf(ll - prev);
    prev = ll;
    atomic_fetch_add(&frame, 1u);
  }
  /* The 500 Hz sine's own largest step at up to +12 dB is about
   * 0.2 * 2 sin(pi * 500 / 96000) = 0.0065. */
  CHECK(max_step < 0.008f);
  eq_free(live);
  eq_free(off);
}

/* The settings the racks fix, at 44.1 and 96 kHz: the cuts at the ends of
 * their ranges and the Drum Rack's shelves within 0.1 dB, the Vocal
 * family's four bells within 0.5 dB, and Ed's default bells within 3 dB.
 * Ed's High (5.3 kHz, Q 0.4) and Hi Mid (3 kHz, Q 0.66) defaults are wide
 * bells, the case one biquad follows least well at 96 kHz; the plain design
 * misses them by 5.6 and 3.8 dB at +-18 dB. */
static void test_eq_rate_rack_settings(void) {
  printf("test_eq_rate_rack_settings\n");
  static const struct {
    int band, shelves;
    double hz, q, tol;
  } cases[] = {
      {5, 0, 20000.0, M_SQRT1_2, 0.05}, {0, 0, 20.0, M_SQRT1_2, 0.05},
      {1, 0, 300.0, 3.6, 0.5},         {2, 0, 900.0, 1.2, 0.5},
      {3, 0, 2700.0, 1.2, 0.5},        {4, 0, 8100.0, 3.6, 0.5},
      {1, 1, 200.0, 0.5, 0.1},         {4, 1, 4000.0, 0.7, 0.1},
      {1, 0, 90.0, 0.4, 3.0},          {2, 0, 101.5, 0.7, 3.0},
      {3, 0, 3040.0, 0.66, 3.0},       {4, 0, 5298.0, 0.4, 3.0},
  };
  const int rates[2] = {44100, 96000};
  double worst = 0.0;
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    const int cut = cases[c].band == 0 || cases[c].band == 5;
    for (int r = 0; r < 2; ++r) {
      for (double db = cut ? 0.0 : -18.0; db <= (cut ? 0.0 : 18.0); db += 3.0) {
        int stable = 0;
        const double e = eqr_error(cases[c].band, cases[c].shelves, cases[c].hz,
                                   db, cases[c].q, rates[r], &stable);
        if (e > worst) worst = e;
        if (e >= cases[c].tol) {
          printf("  band %d at %.0f Hz Q %.2f %+.0f dB, %d Hz: %.3f dB\n",
                 cases[c].band, cases[c].hz, cases[c].q, db, rates[r], e);
        }
        CHECK(stable);
        CHECK(e < cases[c].tol);
      }
    }
  }
  printf("  worst %.3f dB\n", worst);
}

static void run_eq_rate_tests(void) {
  test_eq_rate_matches_48k();
  test_eq_rate_rack_settings();
  test_eq_rate_glide_is_continuous();
  test_eq_rate_kernel_glides();
}
