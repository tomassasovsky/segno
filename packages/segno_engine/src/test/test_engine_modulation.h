/* The Mod kind (#887 part 13): the Guitar Rack's CHORUS, PHASER and
 * FLANGER and the Studio Rack's Tremolo, against the #891 captures (s6trem
 * and s6mod, docs/plan/2026-10-25-looperx-mod-measured.md). Included by
 * test_engine_core.c after the Amp+Cab tests; reuses the dynamics tests'
 * helpers (dyn_state, dyn_run, dyn_free) and the EQ's eq_measured_db. */

#define MOD_SR 48000
#define MOD_CHORUS 0.0f
#define MOD_PHASER (1.0f / 3.0f)
#define MOD_FLANGER (2.0f / 3.0f)
#define MOD_TREMOLO 1.0f

/* Runs [n] samples of [in] through the Mod at [p], left output to [out]. */
static void mod_run(const float* p, const float* in, float* out, int n) {
  le_fx_state* fx = dyn_state(LE_FX_MOD, MOD_SR);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_MOD, p, MOD_SR, in, out, NULL, n, &clock);
  dyn_free(fx);
}

/* A uniform sample in [-1, 1) (xorshift32). */
static float mod_noise(uint32_t* s) {
  *s ^= *s << 13;
  *s ^= *s >> 17;
  *s ^= *s << 5;
  return (float)(int32_t)*s * (1.0f / 2147483648.0f);
}

static void mod_params(float* p, float rate, float depth, float mix,
                       float mode) {
  memset(p, 0, sizeof(float) * LE_FX_PARAMS);
  p[0] = rate;
  p[1] = depth;
  p[2] = mix;
  p[3] = mode;
}

/* A 1 kHz sine through the Mod for [secs]: the gain, dB, of each whole
 * cycle (48 samples) after the first 0.2 s, its lowest and highest, as the
 * captures were read. Returns the cycle gains (the caller frees them) and
 * their count in [*cycles]. */
static double* mod_tone_db(const float* p, double secs, double* lo,
                           double* hi, int* cycles) {
  const int n = (int)(secs * MOD_SR) / 48 * 48;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    x[i] = 0.25f * sinf(2.0f * (float)M_PI * 1000.0f * (float)i / MOD_SR);
  }
  mod_run(p, x, y, n);
  const int skip = MOD_SR / 5 / 48;
  const int m = n / 48 - skip;
  double* g = (double*)malloc(sizeof(double) * (size_t)m);
  *lo = 1e9;
  *hi = -1e9;
  for (int c = 0; c < m; ++c) {
    double yr = 0.0, yi = 0.0, xr = 0.0, xi = 0.0;
    for (int k = 0; k < 48; ++k) {
      const int i = (c + skip) * 48 + k;
      const double ph = 2.0 * M_PI * k / 48.0;
      yr += y[i] * cos(ph);
      yi -= y[i] * sin(ph);
      xr += x[i] * cos(ph);
      xi -= x[i] * sin(ph);
    }
    g[c] = 10.0 * log10((yr * yr + yi * yi) / (xr * xr + xi * xi) + 1e-30);
    if (g[c] < *lo) *lo = g[c];
    if (g[c] > *hi) *hi = g[c];
  }
  free(x);
  free(y);
  *cycles = m;
  return g;
}

/* The lag, in cycles of [g], from [from] to [to], at which [g] best matches
 * itself: the LFO period of a periodic gain track. */
static int mod_period(const double* g, int m, int from, int to) {
  double mean = 0.0;
  for (int i = 0; i < m; ++i) mean += g[i];
  mean /= m;
  int best = from;
  double best_c = -1e300;
  for (int lag = from; lag <= to; ++lag) {
    double c = 0.0;
    for (int i = 0; i + lag < m; ++i) c += (g[i] - mean) * (g[i + lag] - mean);
    c /= (double)(m - lag);
    if (c > best_c) {
      best_c = c;
      best = lag;
    }
  }
  return best;
}

/* ---- Chorus ---- */

/* The chorus mode is the chorus kind: the Guitar Rack's Mod and Ed's
 * Chorus are the same voice (#891). */
static void test_mod_chorus_is_the_chorus(void) {
  printf("test_mod_chorus_is_the_chorus\n");
  const int n = MOD_SR;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* a = (float*)malloc(sizeof(float) * (size_t)n);
  float* b = (float*)malloc(sizeof(float) * (size_t)n);
  uint32_t s = 777u;
  for (int i = 0; i < n; ++i) x[i] = 0.2f * mod_noise(&s);
  const float set[2][3] = {{0.326f, 0.12f, 0.332f}, {0.9f, 0.9f, 0.9f}};
  for (int k = 0; k < 2; ++k) {
    float p[LE_FX_PARAMS];
    mod_params(p, set[k][0], set[k][1], set[k][2], MOD_CHORUS);
    mod_run(p, x, a, n);
    le_fx_state* fx = dyn_state(LE_FX_CHORUS, MOD_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_CHORUS, p, MOD_SR, x, b, NULL, n, &clock);
    dyn_free(fx);
    float worst = 0.0f;
    for (int i = 0; i < n; ++i) {
      if (fabsf(a[i] - b[i]) > worst) worst = fabsf(a[i] - b[i]);
    }
    CHECK(worst < 1e-4f);
  }
  free(x);
  free(a);
  free(b);
}

/* The chorus's swing grows with the square of Depth: the voice's delay over
 * a whole LFO period (Rate 0 %, 2.5 s, read every 16 ms) swings within 5 % of
 * what the Guitar
 * Rack's did at 25, 50, 75 and 100 % (0.638, 2.444, 5.361 and 9.72 ms). */
static void test_mod_chorus_swing_follows_depth(void) {
  printf("test_mod_chorus_swing_follows_depth\n");
  /* An impulse every 16 ms, past the 11.5 ms the voice reaches at 100 %,
   * over a whole LFO period. */
  const int every = MOD_SR / 1000 * 16;
  const int n = 2 * MOD_SR + MOD_SR * 6 / 10;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* out = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < n; i += every) in[i] = 1.0f;
  const double depth[4] = {0.25, 0.5, 0.75, 1.0};
  const double swing_ms[4] = {0.638, 2.444, 5.361, 9.72};
  for (int d = 0; d < 4; ++d) {
    float p[LE_FX_PARAMS];
    mod_params(p, 0.0f, (float)depth[d], 1.0f, MOD_CHORUS);
    mod_run(p, in, out, n);
    double lo = 1e9, hi = -1e9;
    /* Each impulse's voice, as its centre of mass, past the dry spike and
     * before the next impulse. */
    const int win = every - 8;
    for (int i = 0; i + every <= n; i += every) {
      double area = 0.0, moment = 0.0;
      for (int k = 40; k < win; ++k) {
        area += out[i + k];
        moment += (double)k * out[i + k];
      }
      if (area < 0.5) continue;
      const double at = moment / area;
      if (at < lo) lo = at;
      if (at > hi) hi = at;
    }
    const double swing = (hi - lo) * 1000.0 / MOD_SR;
    printf("  depth %.0f %%: swing %.3f ms, the capture's %.3f\n",
           depth[d] * 100.0, swing, swing_ms[d]);
    CHECK(fabs(swing - swing_ms[d]) < 0.05 * swing_ms[d]);
  }
  free(in);
  free(out);
}

/* ---- Phaser ---- */

/* Still (Depth 0 %), the phaser's notches sit where the Guitar Rack's did,
 * 258 and 1652 Hz, and as deep (below -30 dB at Mix 50 %). */
static void test_mod_phaser_notches_match_the_capture(void) {
  printf("test_mod_phaser_notches_match_the_capture\n");
  const int n = 1 << 14;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1.0f;
  float p[LE_FX_PARAMS];
  mod_params(p, 0.5f, 0.0f, 0.5f, MOD_PHASER);
  mod_run(p, in, h, n);
  const double bands[2][3] = {{150.0, 450.0, 258.0}, {1100.0, 2500.0, 1652.0}};
  for (int b = 0; b < 2; ++b) {
    double best = 1e9, at = 0.0;
    for (double f = bands[b][0]; f <= bands[b][1]; f += 1.0) {
      const double db = eq_measured_db(h, n, f, MOD_SR);
      if (db < best) {
        best = db;
        at = f;
      }
    }
    printf("  notch %.0f Hz at %.1f dB, the capture's %.0f Hz\n", at, best,
           bands[b][2]);
    CHECK(fabs(at - bands[b][2]) < 0.02 * bands[b][2]);
    CHECK(best < -30.0);
  }
  free(in);
  free(h);
}

/* Swept, a 1 kHz tone through the phaser at Mix 50 % peaks within 0.3 dB of
 * the capture's +3.99 dB and is notched below -25 dB, and the LFO's period
 * is within 1.5 % of the capture's 0.991 s at Rate 50 % (1.009 Hz; the
 * kernel's 0.1 x 100^Rate Hz runs 1.0 Hz there). */
static void test_mod_phaser_sweep_matches_the_capture(void) {
  printf("test_mod_phaser_sweep_matches_the_capture\n");
  float p[LE_FX_PARAMS];
  mod_params(p, 0.5f, 0.5f, 0.5f, MOD_PHASER);
  double lo, hi;
  int m;
  double* g = mod_tone_db(p, 3.5, &lo, &hi, &m);
  printf("  1 kHz: %.2f to %.2f dB (capture -36.31 to +3.99)\n", lo, hi);
  CHECK(fabs(hi - 3.99) < 0.3);
  CHECK(lo < -25.0);
  const int period = mod_period(g, m, 500, 1500);
  printf("  period %d ms (capture 991)\n", period);
  CHECK(abs(period - 991) <= 15);
  free(g);
  /* Mix: the capture's peaks at 25 and 75 % (+3.09, +3.41 dB). */
  const double mixes[2][2] = {{0.25, 3.09}, {0.75, 3.41}};
  for (int k = 0; k < 2; ++k) {
    mod_params(p, 0.5f, 0.5f, (float)mixes[k][0], MOD_PHASER);
    g = mod_tone_db(p, 1.5, &lo, &hi, &m);
    CHECK(fabs(hi - mixes[k][1]) < 0.3);
    free(g);
  }
}

/* ---- Flanger ---- */

/* The flanger's voice: at Mix 100 % only the delayed copy and its repeats
 * sound, the first copy at 0.88, on a triangle between the delays the
 * capture measured (Depth 50 %: 0.279 to 5.361 ms; 100 %: 0.109 to
 * 6.836 ms). */
static void test_mod_flanger_delay_matches_the_capture(void) {
  printf("test_mod_flanger_delay_matches_the_capture\n");
  const int every = MOD_SR / 100;
  /* Rate 50 %: 0.407 Hz, one period in 2.46 s. */
  const int n = MOD_SR * 26 / 10;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* out = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < n; i += every) in[i] = 1.0f;
  const double cases[2][3] = {{0.5, 0.279, 5.361}, {1.0, 0.109, 6.836}};
  for (int c = 0; c < 2; ++c) {
    float p[LE_FX_PARAMS];
    mod_params(p, 0.5f, (float)cases[c][0], 1.0f, MOD_FLANGER);
    mod_run(p, in, out, n);
    double lo = 1e9, hi = -1e9, first = 0.0;
    for (int i = 0; i + every <= n; i += every) {
      /* The first copy is the largest sample in the impulse's span (its
       * repeats are smaller), read at its centre of mass about it. */
      int at = 0;
      for (int k = 1; k < 400; ++k) {
        if (fabsf(out[i + k]) > fabsf(out[i + at])) at = k;
      }
      const double area = out[i + at - 1] + out[i + at] + out[i + at + 1];
      const double d = (double)at + (out[i + at + 1] - out[i + at - 1]) / area;
      if (d < lo) lo = d;
      if (d > hi) hi = d;
      first += area;
    }
    first /= (double)((n + every - 1) / every);
    lo *= 1000.0 / MOD_SR;
    hi *= 1000.0 / MOD_SR;
    printf("  depth %.0f %%: %.3f to %.3f ms, first copy %.3f\n",
           cases[c][0] * 100.0, lo, hi, first);
    /* The impulses sample the triangle every 10 ms, 0.04 to 0.055 ms of
     * its travel. */
    CHECK(fabs(lo - cases[c][1]) < 0.06);
    CHECK(fabs(hi - cases[c][2]) < 0.1);
    CHECK(fabs(first - 0.88) < 0.03);
  }
  free(in);
  free(out);
}

/* The flanger's repeats, through a 1 kHz tone: at Mix 100 % the capture
 * swung -5.07 to +5.38 dB, at Mix 50 % up to +2.99 dB; within 0.5 dB at
 * the peaks, and the LFO period the capture's 2.47 s at Rate 50 %. */
static void test_mod_flanger_tone_matches_the_capture(void) {
  printf("test_mod_flanger_tone_matches_the_capture\n");
  float p[LE_FX_PARAMS];
  mod_params(p, 0.5f, 0.5f, 1.0f, MOD_FLANGER);
  double lo, hi;
  int m;
  double* g = mod_tone_db(p, 5.5, &lo, &hi, &m);
  printf("  mix 100 %%: %.2f to %.2f dB\n", lo, hi);
  CHECK(fabs(lo - -5.07) < 0.5);
  CHECK(fabs(hi - 5.38) < 0.5);
  const int period = mod_period(g, m, 2000, 3000);
  printf("  period %d ms (capture 2466)\n", period);
  CHECK(abs(period - 2466) <= 25);
  free(g);
  mod_params(p, 0.5f, 0.5f, 0.5f, MOD_FLANGER);
  g = mod_tone_db(p, 3.0, &lo, &hi, &m);
  printf("  mix 50 %%: %.2f to %.2f dB\n", lo, hi);
  CHECK(fabs(hi - 2.99) < 0.5);
  free(g);
}

/* ---- Tremolo ---- */

/* The Studio Rack's tremolo on a steady input: on for 58 % of each cycle,
 * its off part at the gain the capture measured for each Depth (0.880,
 * 0.564, 0.194 and 0 at 25, 50, 75 and 100 %), falling 270-290 dB a
 * second at 100 % (a 30.5 ms time constant) and rising with 13 ms; its
 * cycle 1.467 s at Rate 25 %. */
static void test_mod_tremolo_matches_the_capture(void) {
  printf("test_mod_tremolo_matches_the_capture\n");
  const int n = 4 * MOD_SR;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 1.0f;
  const double depth[4] = {0.25, 0.5, 0.75, 1.0};
  const double off[4] = {0.880, 0.564, 0.194, 0.0};
  for (int d = 0; d < 4; ++d) {
    float p[LE_FX_PARAMS];
    mod_params(p, 0.25f, (float)depth[d], 0.5f, MOD_TREMOLO);
    mod_run(p, in, out, n);
    float least = 1.0f;
    for (int i = 0; i < n; ++i) {
      if (out[i] < least) least = out[i];
    }
    CHECK(fabs(least - off[d]) < 0.01);
    if (depth[d] < 1.0) continue;
    /* The cycle: from one rise to the next. */
    int rise[3];
    int found = 0;
    for (int i = 1; i < n && found < 3; ++i) {
      if (out[i - 1] < 0.5f && out[i] >= 0.5f) rise[found++] = i;
    }
    CHECK(found >= 2);
    if (found < 2) continue;
    const int cycle = rise[1] - rise[0];
    printf("  cycle %d samples (capture 70421)\n", cycle);
    CHECK(abs(cycle - 70421) < 700);
    /* The on part: from a rise through 0.5 to the next fall through it. */
    int fall = rise[0];
    while (fall < n && out[fall] >= 0.5f) ++fall;
    const double on = (double)(fall - rise[0]) / cycle;
    /* 58 % of the cycle, less the rise's 9 ms to 0.5, plus the fall's
     * 21 ms there. */
    const double want = 0.58 + (0.0211 - 0.0090) * MOD_SR / cycle;
    printf("  on %.3f of the cycle (want %.3f)\n", on, want);
    CHECK(fabs(on - want) < 0.01);
    /* The fall from 0.5 to 0.01 (34 dB): 119 ms at a 30.5 ms time
     * constant, the capture's 285 dB a second. */
    int quiet = fall;
    while (quiet < n && out[quiet] > 0.01f) ++quiet;
    const double fall_s = (double)(quiet - fall) / MOD_SR;
    printf("  0.5 to -40 dB in %.1f ms\n", fall_s * 1000.0);
    CHECK(fabs(fall_s - (0.0305 * log(0.5 / 0.01))) < 0.003);
  }
  free(in);
  free(out);
}

/* ---- Every mode ---- */

/* A mode change crossfades: through a 900 Hz sine at 0.2, no sample steps
 * further than 0.06 (the sine's own largest step is 0.024; the same changes
 * made at once step 0.12). */
static void test_mod_change_crossfades(void) {
  printf("test_mod_change_crossfades\n");
  const int n = MOD_SR;
  le_fx_state* fx = dyn_state(LE_FX_MOD, MOD_SR);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  float p[LE_FX_PARAMS];
  mod_params(p, 0.5f, 1.0f, 1.0f, MOD_CHORUS);
  const int32_t types[1] = {LE_FX_MOD};
  float prev = 0.0f;
  float max_step = 0.0f;
  const float modes[5] = {MOD_CHORUS, MOD_FLANGER, MOD_PHASER, MOD_TREMOLO,
                          MOD_CHORUS};
  for (int i = 0; i < n; ++i) {
    p[3] = modes[i / (n / 5)];
    memcpy(params[0], p, sizeof(p));
    fx->clock = (uint32_t)i;
    const float x = 0.2f * sinf(2.0f * (float)M_PI * 900.0f * (float)i / MOD_SR);
    float l = x, r = x;
    fx_apply_chain(fx, MOD_SR, MOD_SR, &l, &r, 1, types, params, NULL);
    CHECK(isfinite(l) && isfinite(r));
    if (i > 0) {
      const float step = fabsf(l - prev);
      if (step > max_step) max_step = step;
    }
    prev = l;
  }
  dyn_free(fx);
  printf("  largest step %.3f\n", max_step);
  CHECK(max_step < 0.06f);
}

/* A change picked during a fade lands once it ends: from the chorus to the
 * phaser, then to the tremolo 100 frames into that fade. On a steady
 * input the phaser holds level, so only the tremolo's off part reaches
 * silence. */
static void test_mod_change_during_a_fade_lands(void) {
  printf("test_mod_change_during_a_fade_lands\n");
  const int n = MOD_SR;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 0.5f;
  le_fx_state* fx = dyn_state(LE_FX_MOD, MOD_SR);
  fx->clocked = 1;
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  float p[LE_FX_PARAMS];
  mod_params(p, 0.5f, 1.0f, 0.5f, MOD_CHORUS);
  const int32_t types[1] = {LE_FX_MOD};
  float least = 1.0f;
  for (int i = 0; i < n; ++i) {
    if (i == 1000) p[3] = MOD_PHASER;
    if (i == 1100) p[3] = MOD_TREMOLO;
    memcpy(params[0], p, sizeof(p));
    fx->clock = (uint32_t)i;
    float l = in[i], r = in[i];
    fx_apply_chain(fx, MOD_SR, MOD_SR, &l, &r, 1, types, params, NULL);
    if (i > n / 3 && fabsf(l) < least) least = fabsf(l);
  }
  dyn_free(fx);
  free(in);
  printf("  quietest %.4f\n", least);
  CHECK(least < 0.01f);
}

/* The Mod is the identity, and a lane holding it prints, where it does
 * nothing: Depth or Mix at 0 % in the chorus, phaser and flanger (no sweep,
 * or no voice), Depth 0 % in the tremolo (whose Mix does nothing). */
static void test_mod_free_running_rule(void) {
  printf("test_mod_free_running_rule\n");
  float p[LE_FX_PARAMS];
  const float modes[3] = {MOD_CHORUS, MOD_PHASER, MOD_FLANGER};
  for (int m = 0; m < 3; ++m) {
    mod_params(p, 0.5f, 0.5f, 0.5f, modes[m]);
    CHECK(le_fx_entry_free_running(LE_FX_MOD, p, MOD_SR));
    p[1] = 0.0f;
    CHECK(!le_fx_entry_free_running(LE_FX_MOD, p, MOD_SR));
    p[1] = 0.5f;
    p[2] = 0.0f;
    CHECK(!le_fx_entry_free_running(LE_FX_MOD, p, MOD_SR));
  }
  mod_params(p, 0.5f, 0.5f, 0.0f, MOD_TREMOLO);
  CHECK(le_fx_entry_free_running(LE_FX_MOD, p, MOD_SR));
  p[1] = 0.0f;
  p[2] = 1.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_MOD, p, MOD_SR));
  /* Still, each is the identity: a steady sine comes back unchanged. */
  const int n = MOD_SR / 4;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) x[i] = 0.3f * sinf(0.05f * (float)i);
  for (int m = 0; m < 3; ++m) {
    mod_params(p, 0.5f, 0.5f, 0.0f, modes[m]);
    mod_run(p, x, y, n);
    for (int i = 0; i < n; ++i) CHECK(y[i] == x[i]);
  }
  mod_params(p, 0.5f, 0.0f, 1.0f, MOD_TREMOLO);
  mod_run(p, x, y, n);
  for (int i = 0; i < n; ++i) CHECK(y[i] == x[i]);
  free(x);
  free(y);
}

/* Every mode runs at 44.1, 96 and 192 kHz at its extremes without a
 * non-finite sample or a runaway. */
static void test_mod_runs_at_every_rate(void) {
  printf("test_mod_runs_at_every_rate\n");
  const int rates[3] = {44100, 96000, 192000};
  for (int r = 0; r < 3; ++r) {
    for (int m = 0; m < 4; ++m) {
      const int n = rates[r] / 2;
      le_fx_state* fx = dyn_state(LE_FX_MOD, rates[r]);
      float p[LE_FX_PARAMS];
      mod_params(p, 1.0f, 1.0f, 1.0f, (float)m / 3.0f);
      float* x = (float*)malloc(sizeof(float) * (size_t)n);
      float* y = (float*)malloc(sizeof(float) * (size_t)n);
      uint32_t s = 99u;
      for (int i = 0; i < n; ++i) x[i] = 0.5f * mod_noise(&s);
      uint32_t clock = 0;
      dyn_run(fx, LE_FX_MOD, p, rates[r], x, y, NULL, n, &clock);
      float peak = 0.0f;
      for (int i = 0; i < n; ++i) {
        CHECK(isfinite(y[i]));
        if (fabsf(y[i]) > peak) peak = fabsf(y[i]);
      }
      CHECK(peak < 4.0f);
      dyn_free(fx);
      free(x);
      free(y);
    }
  }
}

static void run_modulation_tests(void) {
  test_mod_chorus_is_the_chorus();
  test_mod_chorus_swing_follows_depth();
  test_mod_phaser_notches_match_the_capture();
  test_mod_phaser_sweep_matches_the_capture();
  test_mod_flanger_delay_matches_the_capture();
  test_mod_flanger_tone_matches_the_capture();
  test_mod_tremolo_matches_the_capture();
  test_mod_change_crossfades();
  test_mod_change_during_a_fade_lands();
  test_mod_free_running_rule();
  test_mod_runs_at_every_rate();
}
