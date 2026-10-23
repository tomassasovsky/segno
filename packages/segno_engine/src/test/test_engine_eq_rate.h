/* The EQ kind's bands at 44.1, 48 and 96 kHz against their 48 kHz responses
 * (#1436). Included by test_engine_core.c after test_engine_eq.h, whose
 * declarations and helpers it reuses. */

/* The stated tolerances, in dB, over 8000 random settings across each
 * band's whole range (1000 per cut), scored on 480 frequencies: the 95th
 * percentile and the worst case at 44.1 and 96 kHz (48 kHz is exact). The
 * worst cases are this sample's, with a margin; the grid is checked to be no
 * worse than the plain design, not bounded. The worst cases are settings a
 * single biquad cannot follow at that rate without lifting the band above
 * 24 kHz: at 96 kHz, deep wide cuts (Q under about 0.6) near 2 to 5 kHz,
 * high shelves with Q over about 3 above 14 kHz, and high cuts between
 * about 3 and 8 kHz, whose error is in the stopband. */
#define EQR_BELL_P95_44 0.12
#define EQR_BELL_MAX_44 1.8
#define EQR_BELL_P95_96 0.75
#define EQR_BELL_MAX_96 6
#define EQR_HS_P95_44 0.95
#define EQR_HS_MAX_44 10.5
#define EQR_HS_P95_96 5.2
#define EQR_HS_MAX_96 21
#define EQR_LS_P95_44 0.01
#define EQR_LS_MAX_44 0.04
#define EQR_LS_P95_96 0.02
#define EQR_LS_MAX_96 0.15
#define EQR_LP_P95_44 0.2
#define EQR_LP_MAX_44 1.1
#define EQR_LP_P95_96 2.6
#define EQR_LP_MAX_96 3.8
#define EQR_HP_P95_44 0.002
#define EQR_HP_MAX_44 0.005
#define EQR_HP_P95_96 0.008
#define EQR_HP_MAX_96 0.015
/* The share of settings whose design is more than 0.1 dB worse than the
 * plain design's: the correction grid is checked to be no worse at 27
 * points inside every cell, not at every setting. */
#define EQR_WORSE_SHARE 0.5 /* percent */
/* The largest response step between neighbouring designs of a sweep. */
#define EQR_GLIDE_STEP 1.0
/* The rack settings' bounds. */
#define EQR_RACK_CUTS 0.1
#define EQR_RACK_VOCAL 0.6
#define EQR_RACK_EDS 5.7

/* |H| in dB of one design at f. */
static double eqr_db(const double c[5], double f, int sr) {
  const double w = 2.0 * M_PI * f / sr;
  const double nr = c[0] + c[1] * cos(w) + c[2] * cos(2 * w);
  const double ni = -c[1] * sin(w) - c[2] * sin(2 * w);
  const double dr = 1.0 + c[3] * cos(w) + c[4] * cos(2 * w);
  const double di = -c[3] * sin(w) - c[4] * sin(2 * w);
  return 10.0 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

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

/* The largest dB difference between design [c] at [sr] and [ref] at 48 kHz,
 * on 480 frequencies from 20 Hz to 20 kHz (or 0.49 fs) where the 48 kHz
 * response is above -40 dB. */
static double eqr_error_of(const double c[5], const double ref[5], int sr) {
  const double top = sr * 0.49 < 20000.0 ? sr * 0.49 : 20000.0;
  double worst = 0.0;
  for (int i = 0; i < 480; ++i) {
    const double f = 20.0 * pow(top / 20.0, i / 479.0);
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
  eqr_plain(b, shelves, hz, db, q, 48000, ref);
  *stable = fabs(c[4]) < 1.0 && fabs(c[3]) < 1.0 + c[4];
  return eqr_error_of(c, ref, sr);
}

static int eqr_cmp(const void* a, const void* b) {
  const double x = *(const double*)a;
  const double y = *(const double*)b;
  return x < y ? -1 : x > y;
}

/* A fixed pseudo-random sequence in [0, 1). */
static double eqr_rand(uint32_t* s) {
  *s = *s * 1664525u + 1013904223u;
  return (double)(*s >> 8) / 16777216.0;
}

/* One shape: its band, layout, and the ranges its settings take in the EQ
 * kind; and the stated tolerance at each rate (dB: the 95th percentile and
 * the worst case). */
typedef struct eqr_shape {
  const char* name;
  int band;
  int shelves;
  double f_lo, f_hi, q_lo, q_hi, g_lo, g_hi;
  double p95[3], worst[3]; /* at 44.1, 48 and 96 kHz */
} eqr_shape;

/* Every band, at random settings across its whole range, reproduces its
 * 48 kHz magnitude response within the shape's stated tolerance at 44.1 and
 * 96 kHz, and runs exactly the plain 48 kHz design at 48 kHz. Every design
 * is stable. At 96 kHz, past the scored band, none rises from 20 to 24 kHz
 * more than 3 dB over both the 48 kHz response and the plain design, nor
 * above 24 kHz, up to the Nyquist frequency, more than 6 dB over the 48 kHz
 * response's level at the top of its band (or the plain design's own level
 * there); and few are worse than the plain design. */
static void test_eq_rate_matches_48k(void) {
  printf("test_eq_rate_matches_48k\n");
  static const eqr_shape shapes[] = {
      {"bell", 2, 0, 20.0, 20000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_BELL_P95_44, 0.0, EQR_BELL_P95_96},
       {EQR_BELL_MAX_44, 0.0, EQR_BELL_MAX_96}},
      {"high shelf", 4, 1, 1200.0, 20000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_HS_P95_44, 0.0, EQR_HS_P95_96},
       {EQR_HS_MAX_44, 0.0, EQR_HS_MAX_96}},
      {"low shelf", 1, 1, 20.0, 1000.0, 0.4, 10.0, -18.0, 18.0,
       {EQR_LS_P95_44, 0.0, EQR_LS_P95_96},
       {EQR_LS_MAX_44, 0.0, EQR_LS_MAX_96}},
      {"high cut", 5, 0, 120.0, 20000.0, M_SQRT1_2, M_SQRT1_2, 0.0, 0.0,
       {EQR_LP_P95_44, 0.0, EQR_LP_P95_96},
       {EQR_LP_MAX_44, 0.0, EQR_LP_MAX_96}},
      {"low cut", 0, 0, 20.0, 8000.0, M_SQRT1_2, M_SQRT1_2, 0.0, 0.0,
       {EQR_HP_P95_44, 0.0, EQR_HP_P95_96},
       {EQR_HP_MAX_44, 0.0, EQR_HP_MAX_96}},
  };
  const int rates[3] = {44100, 48000, 96000};
  enum { N = 8000 };
  static double errs[N];
  static double plain[N];
  for (size_t s = 0; s < sizeof(shapes) / sizeof(shapes[0]); ++s) {
    const eqr_shape* sh = &shapes[s];
    const int cut = sh->q_lo == sh->q_hi;
    const int n = cut ? N / 8 : N;
    for (int r = 0; r < 3; ++r) {
      const int sr = rates[r];
      uint32_t seed = 1436u + (uint32_t)s;
      int unstable = 0;
      int ultra = 0;
      int worse = 0;
      for (int i = 0; i < n; ++i) {
        const double hz = sh->f_lo * pow(sh->f_hi / sh->f_lo, eqr_rand(&seed));
        const double q = cut ? sh->q_lo : sh->q_lo * pow(sh->q_hi / sh->q_lo, eqr_rand(&seed));
        const double db = cut ? 0.0 : sh->g_lo + (sh->g_hi - sh->g_lo) * eqr_rand(&seed);
        double c[5];
        double p[5];
        double ref[5];
        le_eq_band_design_for_test(sh->band, sh->shelves, hz, db, q, sr, c);
        eqr_plain(sh->band, sh->shelves, hz, db, q, sr, p);
        eqr_plain(sh->band, sh->shelves, hz, db, q, 48000, ref);
        if (!(fabs(c[4]) < 1.0 && fabs(c[3]) < 1.0 + c[4])) ++unstable;
        errs[i] = eqr_error_of(c, ref, sr);
        plain[i] = eqr_error_of(p, ref, sr);
        if (errs[i] > plain[i] + 0.1) ++worse;
        if (sr == 48000) {
          for (int k = 0; k < 5; ++k) CHECK(c[k] == p[k]);
        }
        if (sr > 48000) {
          /* From 20 to 24 kHz (past the scored band): no more than 3 dB
           * over both the 48 kHz response and the plain design. */
          for (int k = 0; k <= 24; ++k) {
            const double fb = 20000.0 + 3990.0 * k / 24.0;
            const double want = eqr_db(ref, fb, 48000);
            const double own = eqr_db(p, fb, sr);
            if (eqr_db(c, fb, sr) > (want > own ? want : own) + 3.0 + 0.01) {
              ++ultra;
              break;
            }
          }
          /* Above 24 kHz, to the Nyquist frequency: no higher than 6 dB
           * over the larger of the 48 kHz response at 24 kHz and at 20 kHz
           * (for the high cut, -15 dB at least), or the plain design's own
           * level. */
          double cap = eqr_db(ref, 23990.0, 48000);
          if (cap < -40.0) cap = -40.0;
          const double at20k = eqr_db(ref, 20000.0, 48000);
          if (at20k > cap) cap = at20k;
          if (sh->band == 5 && cap < -15.0) cap = -15.0;
          cap += 6.0;
          for (int k = 0; k <= 64; ++k) {
            const double fu = 24000.0 + (0.5 * sr - 24000.0) * k / 64.0;
            const double own = eqr_db(p, fu, sr);
            if (eqr_db(c, fu, sr) > (own > cap ? own : cap) + 0.01) {
              ++ultra;
              break;
            }
          }
        }
      }
      qsort(errs, (size_t)n, sizeof(double), eqr_cmp);
      qsort(plain, (size_t)n, sizeof(double), eqr_cmp);
      const double p95 = errs[(int)(0.95 * (n - 1))];
      const double worst = errs[n - 1];
      printf("  %-10s at %5d Hz: worst %.3f dB, p95 %.3f dB, worse than plain %.1f%% of %d"
             " (plain design: worst %.3f, p95 %.3f)\n",
             sh->name, sr, worst, p95, 100.0 * worse / n, n, plain[n - 1],
             plain[(int)(0.95 * (n - 1))]);
      CHECK(unstable == 0);
      CHECK(ultra == 0);
      CHECK(p95 <= sh->p95[r] + 1e-12);
      CHECK(worst <= sh->worst[r] + 1e-12);
      CHECK(100.0 * worse / n <= EQR_WORSE_SHARE);
    }
  }
}

/* The largest change of band [b]'s response, at 48 probes over the band
 * where it is above -60 dB, between neighbouring designs while one setting
 * sweeps in 4000 steps. */
static double eqr_sweep(int b, int shelves, const double from[3],
                        const double to[3], int sr) {
  double prev[48];
  double worst = 0.0;
  for (int s = 0; s < 4000; ++s) {
    const double t = s / 3999.0;
    const double hz = from[0] * pow(to[0] / from[0], t);
    const double q = from[1] * pow(to[1] / from[1], t);
    const double db = from[2] + (to[2] - from[2]) * t;
    double c[5];
    le_eq_band_design_for_test(b, shelves, hz, db, q, sr, c);
    for (int i = 0; i < 48; ++i) {
      const double v = eqr_db(c, 20.0 * pow(1000.0, i / 47.0), sr);
      /* where the band passes more than -60 dB: deeper in a cut's stopband
       * a step of a few dB moves nothing anyone hears */
      if (s > 0 && (v > -60.0 || prev[i] > -60.0) && fabs(v - prev[i]) > worst) {
        worst = fabs(v - prev[i]);
      }
      prev[i] = v;
    }
  }
  return worst;
}

/* A setting gliding across the correction grid moves the response
 * smoothly: from step to step of 4000-step sweeps of frequency, gain and Q,
 * at 96 kHz and 44.1 kHz, the response changes at no probe by more than
 * the stated bound, so a glide never jumps. */
static void test_eq_rate_glide_is_continuous(void) {
  printf("test_eq_rate_glide_is_continuous\n");
  static const struct {
    const char* name;
    int band, shelves;
    double from[3], to[3];
  } sweeps[] = {
      {"bell frequency", 3, 0, {1000.0, 2.0, 12.0}, {20000.0, 2.0, 12.0}},
      {"wide cut frequency", 3, 0, {1000.0, 0.5, -14.0}, {20000.0, 0.5, -14.0}},
      {"bell gain", 3, 0, {15000.0, 3.0, -18.0}, {15000.0, 3.0, 18.0}},
      {"bell Q", 3, 0, {6000.0, 0.4, 9.0}, {6000.0, 10.0, 9.0}},
      {"high shelf gain", 4, 1, {17710.0, 5.23, -18.0}, {17710.0, 5.23, 18.0}},
      {"high shelf frequency", 4, 1, {1200.0, 5.0, 9.0}, {20000.0, 5.0, 9.0}},
      {"high cut frequency", 5, 0, {120.0, M_SQRT1_2, 0.0}, {20000.0, M_SQRT1_2, 0.0}},
      {"low cut frequency", 0, 0, {20.0, M_SQRT1_2, 0.0}, {8000.0, M_SQRT1_2, 0.0}},
  };
  const int rates[2] = {44100, 96000};
  for (size_t i = 0; i < sizeof(sweeps) / sizeof(sweeps[0]); ++i) {
    for (int r = 0; r < 2; ++r) {
      const double w = eqr_sweep(sweeps[i].band, sweeps[i].shelves, sweeps[i].from,
                                 sweeps[i].to, rates[r]);
      printf("  %-20s at %5d Hz: largest step %.3f dB\n", sweeps[i].name, rates[r], w);
      CHECK(w < EQR_GLIDE_STEP);
    }
  }
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

/* The settings the racks fix, at 44.1 and 96 kHz, across their gains: the
 * cuts at the ends of their ranges and the Drum Rack's shelves within
 * 0.1 dB, the Vocal family's four bells within 0.6 dB, Ed's default bells
 * within 5.7 dB. Ed's High default (5.3 kHz, Q 0.4) is a wide bell: cut
 * deeper than about 10 dB, no biquad at 96 kHz follows it without lifting
 * the band above 24 kHz, so it keeps the plain design (5.6 dB off at
 * -18 dB, as before). */
static void test_eq_rate_rack_settings(void) {
  printf("test_eq_rate_rack_settings\n");
  static const struct {
    int band, shelves;
    double hz, q, tol;
  } cases[] = {
      {5, 0, 20000.0, M_SQRT1_2, EQR_RACK_CUTS}, {0, 0, 20.0, M_SQRT1_2, EQR_RACK_CUTS},
      {1, 0, 300.0, 3.6, EQR_RACK_VOCAL},        {2, 0, 900.0, 1.2, EQR_RACK_VOCAL},
      {3, 0, 2700.0, 1.2, EQR_RACK_VOCAL},       {4, 0, 8100.0, 3.6, EQR_RACK_VOCAL},
      {1, 1, 200.0, 0.5, EQR_RACK_CUTS},         {4, 1, 4000.0, 0.7, EQR_RACK_CUTS},
      {1, 0, 90.0, 0.4, EQR_RACK_EDS},           {2, 0, 101.5, 0.7, EQR_RACK_EDS},
      {3, 0, 3040.0, 0.66, EQR_RACK_EDS},        {4, 0, 5298.0, 0.4, EQR_RACK_EDS},
  };
  const int rates[2] = {44100, 96000};
  double worst = 0.0;
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    const int cut = cases[c].band == 0 || cases[c].band == 5;
    for (int r = 0; r < 2; ++r) {
      for (double db = cut ? 0.0 : -18.0; db <= (cut ? 0.0 : 18.0); db += 1.5) {
        int stable = 0;
        const double e = eqr_error(cases[c].band, cases[c].shelves, cases[c].hz,
                                   db, cases[c].q, rates[r], &stable);
        if (e > worst) worst = e;
        if (e >= cases[c].tol) {
          printf("  band %d at %.0f Hz Q %.2f %+.1f dB, %d Hz: %.3f dB\n",
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
