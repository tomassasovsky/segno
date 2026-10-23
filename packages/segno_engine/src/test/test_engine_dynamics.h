/* The dynamics kinds (#887 part 5): Compressor, Transient and HP/Gate.
 * Included by test_engine_core.c after the EQ tests, whose helpers
 * (eq_measured_db, le_eq_design_for_test) and the descriptor helpers
 * (fxd_state, fxd_get) it reuses. */

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

/* ---- Compressor ---- */

/* The static curve: a steady level settles to the design's gain reduction
 * within 0.5 dB, across thresholds and ratios, and make-up adds as set. A DC
 * level keeps the detector free of ripple, so what is measured is the gain
 * computer. */
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
  /* The design itself is the hard-knee line: 4:1 above -20 dB takes 3/4 of
   * the excess. */
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, -20.0);
  p[1] = dyn_setting(LE_FX_COMPRESSOR, 1, 4.0);
  CHECK(fabsf(le_comp_static_gr_for_test(p, -8.0f) - 9.0f) < 1e-3f);
  CHECK(le_comp_static_gr_for_test(p, -25.0f) == 0.0f);
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

/* Attack and release are time constants of the gain reduction, within 10 %:
 * a step from under the threshold to 40 dB over it reaches 63 % of its final
 * reduction in the attack time, and back under it, falls to 37 % in the
 * release time. */
static void test_comp_attack_release_times(void) {
  printf("test_comp_attack_release_times\n");
  const int sr = 48000;
  const double times[][2] = {{10.0, 100.0}, {1.0, 50.0}, {50.0, 1000.0}};
  for (size_t c = 0; c < sizeof(times) / sizeof(times[0]); ++c) {
    const double att_ms = times[c][0];
    const double rel_ms = times[c][1];
    float p[LE_FX_PARAMS] = {0};
    p[0] = dyn_setting(LE_FX_COMPRESSOR, 0, -40.0);
    p[1] = 1.0f; /* 100 : 1 */
    p[2] = dyn_setting(LE_FX_COMPRESSOR, 2, att_ms);
    p[3] = dyn_setting(LE_FX_COMPRESSOR, 3, rel_ms);
    p[4] = 0.0f;
    const int pre = sr / 10;
    const int on = (int)(10.0 * att_ms * sr / 1000.0) + sr / 10;
    const int off = (int)(10.0 * rel_ms * sr / 1000.0) + sr / 10;
    const int n = pre + on + off;
    float* in = (float*)malloc(sizeof(float) * (size_t)n);
    float* out = (float*)malloc(sizeof(float) * (size_t)n);
    const float lo = powf(10.0f, -60.0f / 20.0f);
    for (int i = 0; i < n; ++i) in[i] = (i >= pre && i < pre + on) ? 1.0f : lo;
    le_fx_state* fx = dyn_state(LE_FX_COMPRESSOR, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_COMPRESSOR, p, sr, in, out, NULL, n, &clock);
    dyn_free(fx);
    /* The reduction in dB, sample by sample. */
    const float full = le_comp_static_gr_for_test(p, 0.0f);
    int t_att = -1;
    for (int i = pre; i < pre + on; ++i) {
      const float gr = -dyn_db(out[i]);
      if (gr >= 0.6321f * full) {
        t_att = i - pre + 1;
        break;
      }
    }
    int t_rel = -1;
    const float start = -dyn_db(out[pre + on - 1]);
    CHECK(fabsf(start - full) < 0.05f);
    for (int i = pre + on; i < n; ++i) {
      const float gr = dyn_db(lo) - dyn_db(out[i]);
      if (gr <= 0.3679f * start) {
        t_rel = i - (pre + on) + 1;
        break;
      }
    }
    const double want_att = att_ms * sr / 1000.0;
    const double want_rel = rel_ms * sr / 1000.0;
    if (fabs(t_att - want_att) > 0.1 * want_att ||
        fabs(t_rel - want_rel) > 0.1 * want_rel) {
      printf("  attack %d vs %.0f, release %d vs %.0f samples\n", t_att,
             want_att, t_rel, want_rel);
    }
    CHECK(fabs(t_att - want_att) <= 0.1 * want_att);
    CHECK(fabs(t_rel - want_rel) <= 0.1 * want_rel);
    free(in);
    free(out);
  }
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

/* ---- HP/Gate ---- */

/* The high-pass is the RBJ 12 dB/octave Butterworth design within 0.1 dB,
 * at 48 and 96 kHz, and at the bottom of its range it is still a filter
 * (DC goes, 20 Hz stays). The gate, at -120 dB, lets the whole response
 * through. */
static void test_hp_gate_highpass_matches_design(void) {
  printf("test_hp_gate_highpass_matches_design\n");
  const int rates[2] = {48000, 96000};
  const double corners[3] = {40.0, 100.0, 1000.0};
  const int n = 1 << 16;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  for (int ri = 0; ri < 2; ++ri) {
    for (int ci = 0; ci < 3; ++ci) {
      const int sr = rates[ri];
      float p[LE_FX_PARAMS] = {0};
      p[0] = dyn_setting(LE_FX_HP_GATE, 0, corners[ci]);
      p[1] = 0.0f; /* gate at -120 dB */
      le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr);
      uint32_t clock = 0;
      dyn_run(fx, LE_FX_HP_GATE, p, sr, in, h, NULL, n, &clock);
      dyn_free(fx);
      double c[1][5];
      le_eq_design_for_test(0, corners[ci], 0.0, M_SQRT1_2, sr, c[0]);
      const double probes[] = {10, 20, 40, 70, 100, 200, 500, 1000, 2000, 5000, 15000};
      for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); ++i) {
        const double want = eq_design_db(c, 1, probes[i], sr);
        if (want < -60.0) continue; /* below the impulse's resolution */
        const double got = eq_measured_db(h, n, probes[i], sr);
        if (fabs(want - got) >= 0.1) {
          printf("  sr %d corner %.0f at %.0f Hz: design %.3f, kernel %.3f\n",
                 sr, corners[ci], probes[i], want, got);
        }
        CHECK(fabs(want - got) < 0.1);
      }
    }
  }
  free(in);
  free(h);

  /* At 1 Hz: a DC offset under a 20 Hz tone is gone within a second and the
   * tone is untouched. */
  const int sr = 96000;
  const int m = 2 * sr;
  float* x = (float*)malloc(sizeof(float) * (size_t)m);
  float* y = (float*)malloc(sizeof(float) * (size_t)m);
  for (int i = 0; i < m; ++i) {
    x[i] = 0.3f + 0.25f * sinf(2.0f * (float)M_PI * 20.0f * i / sr);
  }
  float p[LE_FX_PARAMS] = {0};
  le_fx_state* fx = dyn_state(LE_FX_HP_GATE, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_HP_GATE, p, sr, x, y, NULL, m, &clock);
  dyn_free(fx);
  double mean = 0.0;
  float peak = 0.0f;
  for (int i = m - sr / 2; i < m; ++i) {
    mean += y[i];
    if (fabsf(y[i]) > peak) peak = fabsf(y[i]);
  }
  mean /= sr / 2;
  CHECK(fabs(mean) < 0.003);
  CHECK(fabsf(dyn_db(peak / 0.25f)) < 0.05f);
  free(x);
  free(y);
}

/* The gate at -40 dB: a -30 dB tone passes at unity, a -43 dB one that
 * follows it keeps the gate open (hysteresis), a -50 dB one is shut out by
 * more than 40 dB within 300 ms, and the -30 dB tone coming back opens it
 * again within 2 ms. */
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
  p[0] = 0.0f; /* 1 Hz */
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
  test_comp_attack_release_times();
  test_comp_glides_and_links();
  test_transient_shapes();
  test_hp_gate_highpass_matches_design();
  test_hp_gate_gates();
  test_dynamics_offline_equals_live();
  test_dynamics_on_a_lane();
}
