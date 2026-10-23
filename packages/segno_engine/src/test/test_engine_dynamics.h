/* The dynamics kinds (#887 part 5): Compressor, Transient and HP/Gate,
 * against the Looper X's measured behaviour (#891,
 * docs/plan/2026-10-23-looperx-dynamics-measured.md). Included by
 * test_engine_core.c after the EQ tests, whose helper eq_measured_db and the
 * descriptor helpers (fxd_state, fxd_get) it reuses. */

float le_comp_static_gr_for_test(const float* p, float in_db);

/* The setting that gives `value` on descriptor row [p] of [type]. */
static float dyn_setting(int32_t type, int32_t p, double value) {
  const le_fx_param_desc d = fxd_get(type, p);
  double v;
  if (d.curve == LE_FX_CURVE_EXPONENTIAL) {
    v = log(value / d.at_min) / log((double)d.at_max / d.at_min);
  } else if (d.curve == LE_FX_CURVE_RECIPROCAL) {
    const double lo = 1.0 / d.at_min;
    v = (1.0 / value - lo) / (1.0 / d.at_max - lo);
  } else {
    v = (value - d.at_min) / ((double)d.at_max - d.at_min);
  }
  return (float)v;
}

/* Runs [n] samples through slot 0 of [fx] as [type], clocked like an offline
 * render so the update cadence is real. The input is in[i] on both channels,
 * or in[i] left and -in[i] right when [mirror] is set; out_r may be NULL. */
static void dyn_run(le_fx_state* fx, int32_t type, const float* p, int sr,
                    const float* in, float* out_l, float* out_r, int n,
                    uint32_t* clock) {
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  memcpy(params[0], p, sizeof(float) * LE_FX_PARAMS);
  const int32_t types[1] = {type};
  fx->clocked = 1;
  for (int i = 0; i < n; ++i) {
    fx->clock = (*clock)++;
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    out_l[i] = l;
    if (out_r) out_r[i] = r;
  }
}

static le_fx_state* dyn_state(int32_t type, int sr) {
  return fxd_state(type, sr);
}

static void dyn_free(le_fx_state* fx) {
  le_fx_state_free_buffers(fx);
  free(fx);
}

static float dyn_db(float x) { return 20.0f * log10f(fabsf(x)); }

/* ---- The #891 stimulus ----
 *
 * The measured passes (docs/plan/2026-10-23-looperx-dynamics-measured.md)
 * ran a 1 kHz sine through each module in level steps. Every step here is
 * a whole number of cycles (24 samples at 48 kHz), so the sine's crests sit
 * at samples 12 + 24k throughout, and the gain is read there, as the
 * captures were. */

#define DYN_SR 48000

typedef struct dyn_step {
  float db; /* peak dBFS */
  float s;  /* seconds */
} dyn_step;

/* Fills a new buffer with [k] steps; *n gets its length. */
static float* dyn_steps(const dyn_step* st, int k, int* n) {
  int total = 0;
  for (int i = 0; i < k; ++i) total += (int)(st[i].s * DYN_SR);
  float* x = (float*)malloc(sizeof(float) * (size_t)total);
  int at = 0;
  for (int i = 0; i < k; ++i) {
    const float a = powf(10.0f, st[i].db / 20.0f);
    const int len = (int)(st[i].s * DYN_SR);
    for (int j = 0; j < len; ++j, ++at) {
      x[at] = a * sinf(2.0f * (float)M_PI * 1000.0f * (float)at / DYN_SR);
    }
  }
  *n = total;
  return x;
}

/* The gain in dB at the crest nearest [ms] after sample [from]. */
static float dyn_crest_db(const float* x, const float* y, int from, double ms) {
  int i = from + (int)lround(ms * DYN_SR / 1000.0);
  i = 12 + 24 * (int)lround((double)(i - 12) / 24.0);
  return dyn_db(y[i] / x[i]);
}

/* The mean crest gain over [from, to). */
static float dyn_mean_db(const float* x, const float* y, int from, int to) {
  double sum = 0.0;
  int k = 0;
  for (int i = 12 + 24 * ((from + 11) / 24); i < to; i += 24, ++k) {
    sum += dyn_db(y[i] / x[i]);
  }
  return (float)(sum / (k > 0 ? k : 1));
}

/* The first crest time in ms after [from] where the gain has gone [frac]
 * of the way from [a] to [b] dB. */
static double dyn_cross_ms(const float* x, const float* y, int from, int to,
                           float a, float b, float frac) {
  const float tgt = a + frac * (b - a);
  for (int i = 12 + 24 * ((from + 11) / 24); i < to; i += 24) {
    const float g = dyn_db(y[i] / x[i]);
    if ((b < a && g <= tgt) || (b > a && g >= tgt)) {
      return (double)(i - from) * 1000.0 / DYN_SR;
    }
  }
  return -1.0;
}

/* ---- Compressor ---- */

/* The static curve: a steady level settles to the design's gain reduction
 * within 0.5 dB, across thresholds and ratios, and make-up adds as set. A DC
 * level keeps the envelope free of ripple, so what is measured is the gain
 * computer. The design is the quadratic soft knee 15 dB wide that every
 * Looper X rack measured. */
static void test_comp_static_curve(void) {
  printf("test_comp_static_curve\n");
  const int sr = 48000;
  const int n = sr / 4;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  const double cases[][3] = {
      /* threshold dB, ratio, make-up dB */
      {-20.0, 4.0, 0.0}, {-40.0, 100.0, 0.0}, {-10.0, 1.5, 0.0},
      {-30.0, 4.0, 12.0}, {0.0, 8.0, 0.0},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, cases[c][0]);
    p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, cases[c][1]);
    p[2] = 0.0f; /* attack 0.01 ms */
    p[3] = 0.0f; /* release 5 ms */
    p[4] = dyn_setting(LE_FX_COMPRESSOR, 4, cases[c][2]);
    for (float level = -60.0f; level <= 0.0f; level += 5.0f) {
      const float a = powf(10.0f, level / 20.0f);
      for (int i = 0; i < n; ++i) in[i] = a;
      le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, sr);
      uint32_t clock = 0;
      dyn_run(fx, LE_FX_COMPRESSOR, p, sr, in, out, NULL, n, &clock);
      dyn_free(fx);
      const float got = level - dyn_db(out[n - 1]) + (float)cases[c][2];
      const float want = le_comp_static_gr_for_test(p, level);
      if (fabsf(got - want) >= 0.5f) {
        printf("  thr %.0f ratio %.1f at %.0f dB: design %.2f, kernel %.2f\n",
               cases[c][0], cases[c][1], level, want, got);
      }
      CHECK(fabsf(got - want) < 0.5f);
    }
  }
  /* The design: 4:1 at -20 dB takes 3/4 of the excess above the knee
   * (-12.5 dB), nothing below it (-27.5 dB), and 3/4 of 15/8 dB at the
   * threshold. */
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, -20.0);
  p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, 4.0);
  CHECK(fabsf(le_comp_static_gr_for_test(p, -8.0f) - 9.0f) < 1e-3f);
  CHECK(le_comp_static_gr_for_test(p, -28.0f) == 0.0f);
  CHECK(fabsf(le_comp_static_gr_for_test(p, -20.0f) - 0.75f * 15.0f / 8.0f) <
        1e-4f);
  /* The ratio taper is the Looper X's, 1 / (1 - v / 1.0101): its default
   * 0.76 is 4.0 : 1 and its ends 1 and 100. */
  const le_fx_param_desc ratio = fxd_get(LE_FX_COMPRESSOR, 1);
  for (double v = 0.0; v <= 1.0; v += 0.05) {
    CHECK(fabs(fxd_value(&ratio, v) - 1.0 / (1.0 - v / 1.0101)) < 1e-3);
  }
  CHECK(fabs(fxd_value(&ratio, 0.76) - 4.0) < 0.05);
  free(in);
  free(out);
}

/* Ed's Rack's measured ladders: a 1 kHz sine stepping up 3 dB every 0.4 s,
 * at Ed's default attack and release and no make-up. Each step's settled
 * gain is the capture's within 0.4 dB (the envelope reads a steady sine
 * 0.3 to 0.4 dB higher than the Looper X's does). */
static void test_comp_matches_measured_ladders(void) {
  printf("test_comp_matches_measured_ladders\n");
  static const struct {
    double thr, ratio;
    float want[13]; /* -36 .. 0 dBFS */
  } cases[] = {
      {-21.0, 4.0, {0.01f, 0.01f, 0.01f, 0.00f, -0.32f, -1.09f, -2.31f, -3.98f,
                    -6.09f, -8.34f, -10.59f, -12.84f, -15.09f}},
      {-30.2, 4.0, {-0.01f, -0.36f, -1.16f, -2.41f, -4.11f, -6.24f, -8.49f,
                    -10.74f, -12.99f, -15.24f, -17.49f, -19.74f, -21.99f}},
      {-21.0, 100.0, {0.01f, 0.01f, 0.01f, -0.00f, -0.43f, -1.44f, -3.05f,
                      -5.26f, -8.05f, -11.02f, -13.99f, -16.96f, -19.93f}},
      {-21.0, 2.0, {0.01f, 0.01f, 0.01f, 0.00f, -0.21f, -0.72f, -1.54f, -2.65f,
                    -4.06f, -5.56f, -7.06f, -8.56f, -10.06f}},
  };
  dyn_step st[21];
  for (int i = 0; i < 21; ++i) st[i] = (dyn_step){-60.0f + 3.0f * i, 0.4f};
  int n = 0;
  float* x = dyn_steps(st, 21, &n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  float worst = 0.0f;
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    le_fx_defaults(LE_FX_COMPRESSOR, p);
    p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, cases[c].thr);
    p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, cases[c].ratio);
    p[2] = dyn_setting(LE_FX_COMPRESSOR, 2, 1.732);
    p[3] = dyn_setting(LE_FX_COMPRESSOR, 3, 141.4);
    p[4] = 0.0f;
    le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, DYN_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_COMPRESSOR, p, DYN_SR, x, y, NULL, n, &clock);
    dyn_free(fx);
    for (int k = 0; k < 13; ++k) {
      const int end = (int)((8 + k + 1) * 0.4f * DYN_SR);
      const float got = dyn_mean_db(x, y, end - DYN_SR / 1000 * 120,
                                    end - DYN_SR / 1000 * 20);
      const float err = fabsf(got - cases[c].want[k]);
      if (err > worst) worst = err;
      if (err >= 0.4f) {
        printf("  thr %.1f ratio %.0f at %d dBFS: measured %.2f, kernel %.2f\n",
               cases[c].thr, cases[c].ratio, -36 + 3 * k, cases[c].want[k], got);
      }
      CHECK(err < 0.4f);
    }
  }
  printf("  worst ladder error: %.2f dB\n", worst);
  free(x);
  free(y);
}

/* Ed's Rack's measured bursts: a 1 kHz sine at -40 dBFS, -10 dBFS for 1 s,
 * then -40 dBFS again, threshold -30.2 dB at 4:1. The reduction at -10 dBFS
 * is the capture's within 0.5 dB, and the times to half and 90 % of each
 * change are the capture's within a factor: 1.6 for the attack and 1.9 for
 * the release (the one-pole envelope the measurements recommend; its worst
 * cases are the 29.68 ms attack, about 1.45 times slow, and the 5 ms
 * release, about 1.85 times fast). */
static void test_comp_matches_measured_bursts(void) {
  printf("test_comp_matches_measured_bursts\n");
  static const struct {
    double att, rel;
    double gr, a50, a90, r50, r90;
  } cases[] = {
      {1.732, 141.4, 14.5, 1.75, 7.25, 96.8, 191.8},
      {29.68, 141.4, 12.9, 10.75, 42.75, 86.2, 174.8},
      {29.68, 993.0, 14.3, 12.25, 60.25, 546.2, 1089.2},
      {0.01, 993.0, 15.1, 0.25, 0.25, 579.2, 1142.2},
      {0.01, 5.0, 14.9, 0.25, 0.25, 5.2, 9.8},
  };
  const dyn_step st[3] = {{-40.0f, 1.0f}, {-10.0f, 1.0f}, {-40.0f, 1.5f}};
  int n = 0;
  float* x = dyn_steps(st, 3, &n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  const int hi = DYN_SR;
  const int lo2 = 2 * DYN_SR;
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, -30.2);
    p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, 4.0);
    p[2] = dyn_setting(LE_FX_COMPRESSOR, 2, cases[c].att);
    p[3] = dyn_setting(LE_FX_COMPRESSOR, 3, cases[c].rel);
    p[4] = 0.0f;
    le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, DYN_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_COMPRESSOR, p, DYN_SR, x, y, NULL, n, &clock);
    dyn_free(fx);
    const float pre = dyn_mean_db(x, y, hi - DYN_SR / 10, hi);
    const float fin = dyn_mean_db(x, y, lo2 - DYN_SR / 10, lo2);
    const double a50 = dyn_cross_ms(x, y, hi, lo2, pre, fin, 0.5f);
    const double a90 = dyn_cross_ms(x, y, hi, lo2, pre, fin, 0.9f);
    const double r50 = dyn_cross_ms(x, y, lo2, n, fin, pre, 0.5f);
    const double r90 = dyn_cross_ms(x, y, lo2, n, fin, pre, 0.9f);
    printf("  %.2f / %.0f ms: GR %.1f (%.1f), attack %.2f / %.2f (%.2f / %.2f),"
           " release %.1f / %.1f (%.1f / %.1f)\n",
           cases[c].att, cases[c].rel, pre - fin, cases[c].gr, a50, a90,
           cases[c].a50, cases[c].a90, r50, r90, cases[c].r50, cases[c].r90);
    CHECK(fabs((pre - fin) - cases[c].gr) < 0.5);
    /* Within a factor, or within one crest (0.5 ms) for the instant ones. */
    const double got[4] = {a50, a90, r50, r90};
    const double want[4] = {cases[c].a50, cases[c].a90, cases[c].r50,
                            cases[c].r90};
    const double factor[4] = {1.6, 1.6, 1.9, 1.9};
    for (int k = 0; k < 4; ++k) {
      CHECK(got[k] > 0.0);
      CHECK(fabs(got[k] - want[k]) <= 0.5 ||
            (got[k] <= want[k] * factor[k] && got[k] >= want[k] / factor[k]));
    }
  }
  free(x);
  free(y);
}

/* A make-up change glides instead of stepping, and both channels take one
 * gain (stereo-linked): a loud left side compresses a quiet right side by
 * the same amount. */
static void test_comp_glides_and_links(void) {
  printf("test_comp_glides_and_links\n");
  const int sr = 48000;
  const int n = sr / 5;
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_COMPRESSOR, p);
  p[0] = 0.0f; /* threshold 0 dB: nothing compresses */
  p[4] = 0.0f;
  le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, sr);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_COMPRESSOR};
  float prev = 0.0f;
  float max_step = 0.0f;
  float peak = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (i == n / 2) p[4] = 1.0f; /* +30 dB */
    memcpy(params[0], p, sizeof(p));
    fx->clock = (uint32_t)i;
    const float x = 0.01f * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
    float l = x;
    float r = x;
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    if (i > n / 2 - 10 && i < n / 2 + sr / 100) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    if (i > n / 2 + 3 * sr / 50 && fabsf(l) > peak) peak = fabsf(l);
    prev = l;
  }
  /* At +30 dB the sine is 0.316 peak; its own largest step at 48 kHz is
   * 0.316 * 2 sin(pi / 48) = 0.0413. */
  CHECK(max_step < 0.045f);
  CHECK(fabsf(dyn_db(peak / 0.01f) - 30.0f) < 0.2f);
  dyn_free(fx);

  /* Linked: left at 0 dB, right at -40 dB, threshold -20 dB at 4:1. The
   * right side is reduced by the left side's 15 dB. */
  le_fx_defaults(LE_FX_COMPRESSOR, p);
  p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, -20.0);
  p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, 4.0);
  p[4] = 0.0f;
  fx = dyn_state(LE_FX_COMPRESSOR, sr);
  memcpy(params[0], p, sizeof(p));
  float l = 0.0f;
  float r = 0.0f;
  for (int i = 0; i < sr / 2; ++i) {
    fx->clock = (uint32_t)i;
    l = 1.0f;
    r = 0.01f;
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
  }
  CHECK(fabsf(dyn_db(l) + 15.0f) < 0.1f);
  CHECK(fabsf(dyn_db(r) + 55.0f) < 0.1f);
  dyn_free(fx);
}

/* ---- Transient ---- */

/* A burst at -12 dB starting from silence. */
static void tr_burst(float* in, int n, int start, float decay_s, float hz,
                     int sr) {
  for (int i = 0; i < n; ++i) {
    if (i < start) {
      in[i] = 0.0f;
      continue;
    }
    const float t = (float)(i - start) / (float)sr;
    const float env = decay_s > 0.0f ? expf(-t / decay_s) : 1.0f;
    in[i] = 0.25f * env * sinf(2.0f * (float)M_PI * hz * t);
  }
}

static float tr_peak(const float* x, int from, int to) {
  float m = 0.0f;
  for (int i = from; i < to; ++i) {
    if (fabsf(x[i]) > m) m = fabsf(x[i]);
  }
  return m;
}

/* At 50 % everywhere the shaper is the identity, sample for sample. Attack
 * at 100 % lifts an onset and at 0 % cuts it, while a held tone settles back
 * to its own level; sustain at 100 % lifts a decay and at 0 % shortens it. */
static void test_transient_shapes(void) {
  printf("test_transient_shapes\n");
  const int sr = 48000;
  const int n = sr / 2;
  const int start = sr / 20;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_TRANSIENT, p);
  CHECK(p[0] == 0.5f && p[1] == 0.5f && p[2] == 0.5f);

  /* Neutral. */
  for (int i = 0; i < n; ++i) in[i] = (float)((i * 7919) % 2001 - 1000) / 1000.0f;
  le_fx_state* fx = dyn_state(LE_FX_TRANSIENT, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_TRANSIENT, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  for (int i = 0; i < n; ++i) CHECK(out[i] == in[i]);

  /* Attack, on a held 1 kHz burst: the first 5 ms against the input's. */
  tr_burst(in, n, start, 0.0f, 1000.0f, sr);
  const float onset_in = tr_peak(in, start, start + sr / 200);
  float onset[2];
  for (int k = 0; k < 2; ++k) {
    le_fx_defaults(LE_FX_TRANSIENT, p);
    p[0] = k == 0 ? 1.0f : 0.0f;
    fx = dyn_state(LE_FX_TRANSIENT, sr);
    clock = 0;
    dyn_run(fx, LE_FX_TRANSIENT, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    onset[k] = dyn_db(tr_peak(out, start, start + sr / 200) / onset_in);
  }
  printf("  attack 100%%: onset %+.1f dB; 0%%: onset %+.1f dB\n", onset[0],
         onset[1]);
  CHECK(onset[0] > 6.0f);
  CHECK(onset[1] < -6.0f);

  /* A held tone keeps its level 300 ms in, whatever the settings: within
   * 0.2 dB at 1 kHz, and within 1 dB on a 100 Hz note, where the peak
   * envelope ripples. */
  const float hzs[2] = {1000.0f, 100.0f};
  const float tol[2] = {0.2f, 1.0f};
  for (int f = 0; f < 2; ++f) {
    tr_burst(in, n, start, 0.0f, hzs[f], sr);
    const int at = start + 3 * sr / 10;
    const float held_in = tr_peak(in, at, at + sr / 20);
    for (int k = 0; k < 4; ++k) {
      le_fx_defaults(LE_FX_TRANSIENT, p);
      p[k < 2 ? 0 : 2] = (k % 2 == 0) ? 1.0f : 0.0f;
      fx = dyn_state(LE_FX_TRANSIENT, sr);
      clock = 0;
      dyn_run(fx, LE_FX_TRANSIENT, p, sr, in, out, NULL, n, &clock);
      dyn_free(fx);
      const float held = dyn_db(tr_peak(out, at, at + sr / 20) / held_in);
      if (fabsf(held) >= tol[f]) {
        printf("  %.0f Hz, %s %s: held %+.2f dB\n", hzs[f],
               k < 2 ? "attack" : "sustain", k % 2 == 0 ? "100%" : "0%", held);
      }
      CHECK(fabsf(held) < tol[f]);
    }
  }

  /* Sustain, on a burst decaying with a 100 ms time constant: the tail
   * 200 ms in. */
  tr_burst(in, n, start, 0.1f, 1000.0f, sr);
  const int tail = start + sr / 5;
  const float tail_in = tr_peak(in, tail, tail + sr / 50);
  float tails[2];
  for (int k = 0; k < 2; ++k) {
    le_fx_defaults(LE_FX_TRANSIENT, p);
    p[2] = k == 0 ? 1.0f : 0.0f;
    fx = dyn_state(LE_FX_TRANSIENT, sr);
    clock = 0;
    dyn_run(fx, LE_FX_TRANSIENT, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    tails[k] = dyn_db(tr_peak(out, tail, tail + sr / 50) / tail_in);
  }
  printf("  sustain 100%%: tail %+.1f dB; 0%%: tail %+.1f dB\n", tails[0],
         tails[1]);
  CHECK(tails[0] > 3.0f);
  CHECK(tails[1] < -3.0f);

  /* A longer attack length lifts more of the onset: the second 5 ms. */
  float second[2];
  tr_burst(in, n, start, 0.0f, 1000.0f, sr);
  for (int k = 0; k < 2; ++k) {
    le_fx_defaults(LE_FX_TRANSIENT, p);
    p[0] = 1.0f;
    p[1] = k == 0 ? 0.0f : 1.0f;
    fx = dyn_state(LE_FX_TRANSIENT, sr);
    clock = 0;
    dyn_run(fx, LE_FX_TRANSIENT, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    second[k] = tr_peak(out, start + sr / 200, start + sr / 100);
  }
  CHECK(second[1] > second[0] * 1.5f);
  free(in);
  free(out);
}

/* The Drum Rack's measured transient shaper (#891): crest gains after a
 * 30 dB step (-40 to -10 dBFS) or a 60 dB one (-80 to -20 dBFS), up or back
 * down, at Attack / Attack Length / Sustain in percent. The kernel lands on
 * every capture point within 2 dB (its worst are about 1.5 dB on the onsets
 * and 1.7 dB on the decays; over the whole captured traces its RMS error is
 * 0.4 dB or less on the onsets and under 1 dB on the decays). */
static void test_transient_matches_measured(void) {
  printf("test_transient_matches_measured\n");
  /* step: 0 = 30 dB up, 1 = 60 dB up, 2 = 30 dB down, 3 = 60 dB down */
  static const struct {
    float a, len, s;
    int step;
    double ms[8];
    double want[8];
    int count;
  } cases[] = {
      {0.0f, 0.5f, 0.5f, 0, {2, 5, 10, 20}, {-14.5, -11.8, -7.8, -2.9}, 4},
      {1.0f, 0.0f, 0.5f, 1, {2, 5, 10}, {12.0, 6.5, 1.8}, 3},
      {1.0f, 0.5f, 0.5f, 1, {2, 5, 10, 20}, {14.1, 11.8, 8.1, 3.0}, 4},
      {1.0f, 1.0f, 0.5f, 1, {2, 5, 10, 20, 50}, {15.6, 14.2, 12.6, 10.0, 3.4},
       5},
      {0.75f, 0.5f, 0.5f, 1, {2, 5, 10}, {9.6, 7.8, 5.0}, 3},
      {0.25f, 0.5f, 0.5f, 1, {2, 5, 10}, {-9.9, -7.7, -4.8}, 3},
      {0.6f, 0.5f, 0.6f, 0, {2, 5, 10, 20}, {4.7, 3.9, 2.2, 0.7}, 4},
      {0.5f, 0.5f, 1.0f, 2, {20, 100, 200, 286, 400, 500, 600, 700},
       {5.6, 15.4, 17.7, 18.3, 17.2, 11.6, 5.7, 2.3}, 8},
      {0.5f, 0.5f, 0.0f, 2, {20, 100, 200, 286, 400, 500, 600, 700},
       {-5.6, -15.4, -17.7, -18.3, -17.2, -11.6, -5.7, -2.3}, 8},
      {0.5f, 0.5f, 0.75f, 2, {20, 100, 286, 500, 700},
       {3.2, 10.8, 13.3, 7.6, 1.2}, 5},
      {0.6f, 0.5f, 0.6f, 2, {100, 286, 500}, {5.9, 7.8, 3.9}, 3},
      {0.5f, 0.5f, 1.0f, 3, {100, 286, 600, 800}, {15.7, 20.1, 22.3, 16.1}, 4},
  };
  const dyn_step steps[4][3] = {
      {{-40.0f, 1.0f}, {-10.0f, 1.0f}, {-40.0f, 0.5f}},
      {{-80.0f, 1.0f}, {-20.0f, 1.0f}, {-80.0f, 0.5f}},
      {{-40.0f, 1.0f}, {-10.0f, 1.0f}, {-40.0f, 1.5f}},
      {{-80.0f, 1.0f}, {-20.0f, 1.0f}, {-80.0f, 1.5f}},
  };
  float worst[2] = {0.0f, 0.0f};
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    const int s = cases[c].step;
    int n = 0;
    float* x = dyn_steps(steps[s], 3, &n);
    float* y = (float*)malloc(sizeof(float) * (size_t)n);
    float p[LE_FX_PARAMS] = {0};
    p[0] = cases[c].a;
    p[1] = cases[c].len;
    p[2] = cases[c].s;
    le_fx_state* fx = dyn_state(LE_FX_TRANSIENT, DYN_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_TRANSIENT, p, DYN_SR, x, y, NULL, n, &clock);
    dyn_free(fx);
    const int from = s < 2 ? DYN_SR : 2 * DYN_SR;
    const int decay = s >= 2;
    const float tol = 2.0f;
    for (int k = 0; k < cases[c].count; ++k) {
      const float got = dyn_crest_db(x, y, from, cases[c].ms[k]);
      const float err = fabsf(got - (float)cases[c].want[k]);
      if (err > worst[decay]) worst[decay] = err;
      if (err >= 1.0f) {
        printf("  %.0f/%.0f/%.0f %%, step %d, %.0f ms: measured %+.1f dB, "
               "kernel %+.1f dB\n",
               100 * cases[c].a, 100 * cases[c].len, 100 * cases[c].s, s,
               cases[c].ms[k], cases[c].want[k], got);
      }
      CHECK(err < tol);
    }
    free(x);
    free(y);
  }
  printf("  worst error: onsets %.2f dB, decays %.2f dB\n", worst[0], worst[1]);
}

/* ---- HP/Gate ---- */

/* The high-pass lands on the Vocal Rack's measured responses (#891) within
 * 0.15 dB from 20 Hz to 4 kHz, at the three settings captured (shown there
 * as 31.6, 177.8 and 1000 Hz, which apply corners of half that). The gate,
 * at -120 dB, lets the whole response through. Just above off it is still a
 * filter: DC goes, 20 Hz stays. At off it passes everything as it is. */
static void test_hp_gate_highpass_matches_measured(void) {
  printf("test_hp_gate_highpass_matches_measured\n");
  static const struct {
    double shown;
    double want[9];
  } cases[] = {
      {31.6228, {-1.955, -0.502, -0.075, -0.006, 0.009, 0.013, 0.013, 0.014,
                 0.014}},
      {177.828, {-26.098, -18.080, -7.478, -1.406, -0.142, 0.035, 0.067, 0.075,
                 0.076}},
      {1000.0, {-55.857, -47.756, -36.007, -24.185, -12.622, -3.521, -0.219,
                0.326, 0.419}},
  };
  const double probes[9] = {20, 32, 63, 125, 250, 500, 1000, 2000, 4000};
  const int sr = 48000;
  const int n = 1 << 17;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  double worst = 0.0;
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_HP_GATE, 0, 0.5 * cases[c].shown);
    p[1] = 0.0f; /* gate at -120 dB */
    le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_HP_GATE, p, sr, in, h, NULL, n, &clock);
    dyn_free(fx);
    for (int i = 0; i < 9; ++i) {
      const double got = eq_measured_db(h, n, probes[i], sr);
      const double err = fabs(got - cases[c].want[i]);
      if (err > worst) worst = err;
      if (err >= 0.15) {
        printf("  shown %.1f Hz at %.0f Hz: measured %.3f, kernel %.3f\n",
               cases[c].shown, probes[i], cases[c].want[i], got);
      }
      CHECK(err < 0.15);
    }
  }
  printf("  worst error against the captures: %.3f dB\n", worst);
  free(in);
  free(h);

  /* Just above off, at 0.5 Hz: a DC offset under a 20 Hz tone is gone
   * within three seconds and the tone is untouched. */
  const int sr2 = 96000;
  const int m = 4 * sr2;
  float* x = (float*)malloc(sizeof(float) * (size_t)m);
  float* y = (float*)malloc(sizeof(float) * (size_t)m);
  for (int i = 0; i < m; ++i) {
    x[i] = 0.3f + 0.25f * sinf(2.0f * (float)M_PI * 20.0f * i / sr2);
  }
  float p[LE_FX_PARAMS] = {0};
  p[0] = 1e-6f;
  le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr2);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, sr2, x, y, NULL, m, &clock);
  dyn_free(fx);
  double mean = 0.0;
  float peak = 0.0f;
  for (int i = m - sr2 / 2; i < m; ++i) {
    mean += y[i];
    if (fabsf(y[i]) > peak) peak = fabsf(y[i]);
  }
  mean /= sr2 / 2;
  CHECK(fabs(mean) < 0.003);
  CHECK(fabsf(dyn_db(peak / 0.25f)) < 0.05f);
  p[0] = 0.0f;
  CHECK(fxd_get(LE_FX_HP_GATE, 0).flags & LE_FX_PARAM_OFF_AT_MIN);
  fx = dyn_state(LE_FX_HP_GATE, sr2);
  clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, sr2, x, y, NULL, sr2, &clock);
  dyn_free(fx);
  for (int i = 0; i < sr2; ++i) CHECK(y[i] == x[i]);
  free(x);
  free(y);
}

/* The Vocal Rack's measured gate timing (#891), at a -40 dB threshold: a
 * 1 kHz sine at -20 dBFS dropping to -80 dBFS holds the gate open for
 * 250 ms and then falls 2.7 dB/ms, within 1 dB of every capture point while
 * open and 2 dB on the fall (one 0.25 ms crest is 0.7 dB of it). Coming back
 * it opens by the first crest. And the detector is the peak: a sine whose
 * peak is at the threshold opens it; one 1 dB under it does not. */
static void test_hp_gate_matches_measured(void) {
  printf("test_hp_gate_matches_measured\n");
  const dyn_step st[4] = {
      {-20.0f, 1.0f}, {-80.0f, 1.0f}, {-20.0f, 0.5f}, {-80.0f, 0.5f}};
  int n = 0;
  float* x = dyn_steps(st, 4, &n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  float p[LE_FX_PARAMS] = {0};
  p[1] = dyn_setting(LE_FX_HP_GATE, 1, -40.0);
  le_fx_state* fx = dyn_state(LE_FX_HP_GATE, DYN_SR);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, DYN_SR, x, y, NULL, n, &clock);
  dyn_free(fx);
  static const double ms[8] = {1, 100, 240, 248, 250, 252, 256, 260};
  static const double want[8] = {0.0, 0.0, 0.0, 0.0, -0.7, -6.1, -16.9, -26.4};
  for (int k = 0; k < 8; ++k) {
    const float got = dyn_crest_db(x, y, DYN_SR, ms[k]);
    const float tol = want[k] > -1.0 ? 1.0f : 2.0f;
    if (fabsf(got - (float)want[k]) >= tol) {
      printf("  %.0f ms after the drop: measured %.1f dB, kernel %.1f dB\n",
             ms[k], want[k], got);
    }
    CHECK(fabsf(got - (float)want[k]) < tol);
  }
  /* Shut by 300 ms, and open again at the first crest of the return. */
  CHECK(dyn_crest_db(x, y, DYN_SR, 300) < -100.0f);
  CHECK(fabsf(dyn_crest_db(x, y, 2 * DYN_SR, 0.25)) < 1.0f);
  free(x);
  free(y);

  /* The peak decides: after silence, a -42 dBFS sine opens a gate half a
   * dB under its peak and not one half a dB over it. */
  const dyn_step st2[2] = {{-120.0f, 0.5f}, {-42.0f, 0.5f}};
  x = dyn_steps(st2, 2, &n);
  y = (float*)malloc(sizeof(float) * (size_t)n);
  const double thr[2] = {-42.5, -41.5};
  for (int k = 0; k < 2; ++k) {
    p[1] = dyn_setting(LE_FX_HP_GATE, 1, thr[k]);
    fx = dyn_state(LE_FX_HP_GATE, DYN_SR);
    clock = 0;
    dyn_run(fx, LE_FX_HP_GATE, p, DYN_SR, x, y, NULL, n, &clock);
    dyn_free(fx);
    const float g = dyn_crest_db(x, y, DYN_SR / 2, 100);
    CHECK(k == 0 ? fabsf(g) < 0.1f : g < -100.0f);
  }
  free(x);
  free(y);
}

/* The gate at -40 dB: a -30 dB tone passes at unity, a -43 dB one that
 * follows it keeps the gate open (hysteresis), a -50 dB one is shut out by
 * more than 40 dB within 300 ms (the 250 ms hold, then the fall), and the
 * -30 dB tone coming back opens it again within 2 ms. */
static void test_hp_gate_gates(void) {
  printf("test_hp_gate_gates\n");
  const int sr = 48000;
  const int seg = sr * 3 / 10;
  const int n = 4 * seg;
  const float levels[4] = {-30.0f, -43.0f, -50.0f, -30.0f};
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    const float a = powf(10.0f, levels[i / seg] / 20.0f);
    in[i] = a * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
  }
  float p[LE_FX_PARAMS] = {0};
  p[0] = 0.0f; /* the high-pass off */
  p[1] = dyn_setting(LE_FX_HP_GATE, 1, -40.0);
  le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  const int w = sr / 50;
  /* Open at unity. */
  CHECK(fabsf(dyn_db(tr_peak(out, seg - w, seg) / tr_peak(in, seg - w, seg))) < 0.05f);
  /* Held open between the thresholds. */
  CHECK(fabsf(dyn_db(tr_peak(out, 2 * seg - w, 2 * seg) /
                     tr_peak(in, 2 * seg - w, 2 * seg))) < 0.05f);
  /* Shut. */
  CHECK(dyn_db(tr_peak(out, 3 * seg - w, 3 * seg) / tr_peak(in, 3 * seg - w, 3 * seg)) <
        -40.0f);
  /* Open again within 2 ms. */
  const int back = 3 * seg + sr / 500;
  CHECK(fabsf(dyn_db(tr_peak(out, back, back + w) / tr_peak(in, back, back + w))) < 0.5f);
  free(in);
  free(out);
}

/* The hold restarts whenever the level comes back within the hysteresis:
 * after a dip that ran part of the hold down, a return to between the two
 * thresholds and a second dip keep the gate open for a whole hold again. */
static void test_hp_gate_hold_restarts(void) {
  printf("test_hp_gate_hold_restarts\n");
  const int sr = 48000;
  /* -30 dB, then -60 dB for 150 ms (150 ms of the 250 ms hold run down),
   * -43 dB for 30 ms, then -60 dB again. */
  const int a = sr / 10;
  const int b = a + 3 * sr / 20;
  const int c = b + 3 * sr / 100;
  const int n = c + 2 * sr / 5;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    const float db = i < a ? -30.0f : i < b ? -60.0f : i < c ? -43.0f : -60.0f;
    in[i] = powf(10.0f, db / 20.0f) * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
  }
  float p[LE_FX_PARAMS] = {0};
  p[1] = dyn_setting(LE_FX_HP_GATE, 1, -40.0);
  le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  /* 200 to 240 ms into the second dip it is still open; a hold left at
   * 100 ms would have closed it 100 ms in. */
  const int from = c + 200 * sr / 1000;
  const int to = c + 240 * sr / 1000;
  CHECK(fabsf(dyn_db(tr_peak(out, from, to) / tr_peak(in, from, to))) < 0.3f);
  /* And it does close after that. */
  const int late = c + 300 * sr / 1000;
  CHECK(dyn_db(tr_peak(out, late, late + sr / 100) / tr_peak(in, late, late + sr / 100)) <
        -40.0f);
  free(in);
  free(out);
}

/* A glide the slot stops processing part-way (the chain skipped for a
 * while, the engine clock running on) resumes from where it stood, never
 * jumping: the compressor's make-up rising 0 -> 30 dB, paused for 1000
 * frames after 40 samples. */
static void test_dynamics_paused_glide_resumes_smoothly(void) {
  printf("test_dynamics_paused_glide_resumes_smoothly\n");
  const int sr = 48000;
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_COMPRESSOR, p);
  p[0] = 0.0f;
  p[4] = 0.0f;
  le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, sr);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  const int32_t types[1] = {LE_FX_COMPRESSOR};
  uint32_t clock = 0;
  float prev = 0.0f;
  float max_step = 0.0f;
  const float a = 0.01f;
  for (int i = 0; i < sr / 5; ++i) {
    if (i == 4800) p[4] = 1.0f;
    if (i == 4840) clock += 1000; /* not processed for 1000 frames */
    memcpy(params[0], p, sizeof(p));
    fx->clock = clock++;
    /* A constant level, so any change sample to sample is the gain's. */
    float l = a;
    float r = a;
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    if (i > 4790) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    prev = l;
  }
  /* The gain moves at most one ramp step a sample: 30 dB over ~10 ms
   * starts at about 0.06 dB per sample (0.007 x the level at most). */
  CHECK(max_step < 0.002f);
  CHECK(fabsf(dyn_db(prev / a) - 30.0f) < 0.05f);
  dyn_free(fx);
}

/* ---- all three ---- */

/* A live owner and an offline render update on the same frames and produce
 * the same samples while the settings move; none of the three drains on
 * bypass. */
static void test_dynamics_offline_equals_live(void) {
  printf("test_dynamics_offline_equals_live\n");
  const int32_t kinds[3] = {LE_FX_COMPRESSOR, LE_FX_TRANSIENT, LE_FX_HP_GATE};
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
      if (i == 777) p[0] = 0.9f; /* a move mid-run */
      if (i == 2222) p[1] = 0.2f;
      memcpy(params[0], p, sizeof(p));
      const float x = 0.5f * sinf((float)i * 0.05f) * (i % 1500 < 700 ? 1.0f : 0.01f);
      float ll = x, lr = -x, ol = x, orr = -x;
      off->clock = atomic_load(&frame);
      fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
      fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
      CHECK(ll == ol && lr == orr);
      atomic_fetch_add(&frame, 1u);
    }
    CHECK(!le_fx_type_drains(ty));
    dyn_free(live);
    dyn_free(off);
  }
}

/* Each kind runs on a lane through the engine's setters, takes exactly its
 * own parameters, and a non-finite sample does not latch. */
static void test_dynamics_on_a_lane(void) {
  printf("test_dynamics_on_a_lane\n");
  const int32_t kinds[3] = {LE_FX_COMPRESSOR, LE_FX_TRANSIENT, LE_FX_HP_GATE};
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

    /* NaN in, then a clean signal: the output is finite again at once. */
    le_fx_state* fx = dyn_state(ty, 48000);
    float p[LE_FX_PARAMS] = {0};
    le_fx_defaults(ty, p);
    float in[256];
    float o[256];
    for (int i = 0; i < 256; ++i) in[i] = i == 10 ? NAN : 0.3f * sinf(0.1f * i);
    uint32_t clock = 0;
    dyn_run(fx, ty, p, 48000, in, o, NULL, 256, &clock);
    for (int i = 0; i < 256; ++i) CHECK(isfinite(o[i]));
    dyn_free(fx);
  }
}

static void run_dynamics_tests(void) {
  test_comp_static_curve();
  test_comp_matches_measured_ladders();
  test_comp_matches_measured_bursts();
  test_comp_glides_and_links();
  test_transient_shapes();
  test_transient_matches_measured();
  test_hp_gate_highpass_matches_measured();
  test_hp_gate_matches_measured();
  test_hp_gate_gates();
  test_hp_gate_hold_restarts();
  test_dynamics_paused_glide_resumes_smoothly();
  test_dynamics_offline_equals_live();
  test_dynamics_on_a_lane();
}
