/* The Mode delay (#887 part 10), against the #891 captures. Included by
 * test_engine_core.c after the rhythmic tests, whose helpers (rh_tempo,
 * RH_SR) it reuses. */

#define MD_SR 48000

/* A one-slot Mode delay on [t] at [sr], its line ready. */
static le_fx_state* md_state_at(const le_fx_tempo* t, int sr) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_MODE_DELAY, sr) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->tempo = t;
  fx->clocked = 1;
  return fx;
}

static le_fx_state* md_state(const le_fx_tempo* t) {
  return md_state_at(t, MD_SR);
}

/* Runs [n] frames of [in] (both sides) through the Mode delay at [p] and
 * [sr], writing each side's output. */
static void md_run_at(le_fx_state* fx, int sr, const float* p,
                      const float* in, float* out_l, float* out_r, int n) {
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_MODE_DELAY;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, sr, sr, &l, &r, 1, types, params, NULL);
    out_l[i] = l;
    if (out_r) out_r[i] = r;
  }
}

static void md_run(le_fx_state* fx, const float* p, const float* in,
                   float* out_l, float* out_r, int n) {
  md_run_at(fx, MD_SR, p, in, out_l, out_r, n);
}

/* The stored setting of choice position [k] of [n]. */
static float md_choice(int k, int n) { return (float)k / (float)(n - 1); }

/* A 60 ms burst of [hz] at 0.25 from frame 1000 (5 ms ramps); the level
 * of [y] over 40 ms from [at] frames after it starts, in dB against the
 * burst's own. */
static float* md_burst(double hz, int n) {
  float* x = (float*)calloc((size_t)n, sizeof(float));
  const int len = MD_SR * 60 / 1000;
  const int ramp = MD_SR * 5 / 1000;
  for (int i = 0; i < len; ++i) {
    double g = 1.0;
    if (i < ramp) g = (double)i / ramp;
    if (i > len - ramp) g = (double)(len - i) / ramp;
    x[1000 + i] = (float)(0.25 * g * sin(2.0 * 3.14159265358979 * hz * i / MD_SR));
  }
  return x;
}

static double md_level(const float* y, int at) {
  const int from = 1000 + MD_SR * 10 / 1000 + at;
  const int len = MD_SR * 40 / 1000;
  double e = 0.0;
  for (int i = from; i < from + len; ++i) e += (double)y[i] * y[i];
  const double ref = 0.25 * 0.25 / 2.0 * len;
  return 10.0 * log10(e / ref + 1e-30);
}

/* The voicings (#891, s4/4 and s4/12-14 at 1/8D, Feedback 50 %, Mix 30 %):
 * the first echo against the dry, past the mix's 0.36, and the second
 * against the first, past the Feedback's 0.5, at 300 Hz, 1 kHz and 3 kHz,
 * within 0.5 dB of the capture's deconvolved responses. */
static void test_mode_delay_voicings(void) {
  printf("test_mode_delay_voicings\n");
  static const double hz[3] = {300.0, 1000.0, 3000.0};
  /* DIGI, DAMPED, RESO LO, RESO HI: first, then loop, at each tone. */
  static const double want[4][2][3] = {
      {{-0.1, -0.1, -0.3}, {0.0, 0.0, -0.1}},
      {{-0.1, -0.1, -0.4}, {0.0, 0.0, -0.3}},
      {{+0.8, +6.2, +0.7}, {-3.9, +1.0, -3.9}},
      {{+0.0, +1.6, +5.0}, {-4.7, -3.2, +0.8}},
  };
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = 2 * MD_SR;
  const int period = MD_SR * 375 / 1000;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int v = 0; v < 4; ++v) {
    const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.5f, 0.3f,
                                   md_choice(3 * v, 12)};
    for (int k = 0; k < 3; ++k) {
      float* x = md_burst(hz[k], n);
      le_fx_state* fx = md_state(&t);
      md_run(fx, p, x, y, NULL, n);
      le_fx_state_free_buffers(fx);
      free(fx);
      const double e1 = md_level(y, period);
      const double e2 = md_level(y, 2 * period);
      const double first = e1 - 20.0 * log10(0.36);
      const double loop = e2 - e1 - 20.0 * log10(0.5);
      printf("  voicing %d at %4.0f Hz: first %+5.1f (capture %+5.1f), loop "
             "%+5.1f (%+5.1f)\n",
             v, hz[k], first, want[v][0][k], loop, want[v][1][k]);
      CHECK(fabs(first - want[v][0][k]) < 0.5);
      CHECK(fabs(loop - want[v][1][k]) < 0.5);
      free(x);
    }
  }
  free(y);
}

/* The timings (s4/10, s4/11, gC 36/38, s3/8), on 250 Hz bursts against
 * the plain echo's level: L/R puts the right side half the time early
 * (-1.1 dB) and the left on time at 0.219 + 0.666 Feedback (-13.2 dB at
 * 0 %, -5.2 at 50 %); GRV the right at 0.837 of the time (-1.2) and the
 * left on time (-2.5 at 0 %, -1.9 at 50 %). */
static void test_mode_delay_timings(void) {
  printf("test_mode_delay_timings\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = 2 * MD_SR;
  const int period = MD_SR * 375 / 1000;
  float* x = md_burst(250.0, n);
  float* yl = (float*)malloc(sizeof(float) * (size_t)n);
  float* yr = (float*)malloc(sizeof(float) * (size_t)n);
  static const struct {
    int mode;
    float fb;
    double early, r_early, l_on;
  } want[4] = {
      {1, 0.0f, 0.5, -1.1, -13.2},
      {1, 0.5f, 0.5, -1.1, -5.2},
      {2, 0.0f, 0.8368, -1.2, -2.5},
      {2, 0.5f, 0.8368, -1.2, -1.9},
  };
  for (int w = 0; w < 4; ++w) {
    const float p[LE_FX_PARAMS] = {md_choice(8, 20), want[w].fb, 0.3f,
                                   md_choice(want[w].mode, 12)};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, yl, yr, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    const double ref = 20.0 * log10(0.36);
    const double re = md_level(yr, (int)(period * want[w].early + 0.5)) - ref;
    const double lo = md_level(yl, period) - ref;
    printf("  mode %d at %2.0f %%: right early %+5.1f (capture %+5.1f), left on "
           "time %+5.1f (%+5.1f)\n",
           want[w].mode, 100.0 * want[w].fb, re, want[w].r_early, lo,
           want[w].l_on);
    CHECK(fabs(re - want[w].r_early) < 0.6);
    CHECK(fabs(lo - want[w].l_on) < 0.6);
  }
  free(x);
  free(yl);
  free(yr);
}

/* Mix (#891): the dry whole and the wet (2 Mix)^2 up to 50 % (0.0324 at
 * 9 %, s3/8; 0.36 at 30 %); above, the wet whole and the dry falling as
 * 1 - (2 Mix - 1)^2. */
static void test_mode_delay_mix_law(void) {
  printf("test_mode_delay_mix_law\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = MD_SR;
  const int period = MD_SR * 375 / 1000;
  float* x = md_burst(250.0, n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  static const double mixes[4] = {0.09, 0.3, 0.5, 0.75};
  for (int k = 0; k < 4; ++k) {
    const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.0f, (float)mixes[k],
                                   0.0f};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    const double m = mixes[k];
    const double wet = m <= 0.5 ? 4.0 * m * m : 1.0;
    const double dry = m <= 0.5 ? 1.0 : 1.0 - (2.0 * m - 1.0) * (2.0 * m - 1.0);
    CHECK(fabs(md_level(y, 0) - 20.0 * log10(dry)) < 0.1);
    CHECK(fabs(md_level(y, period) - 20.0 * log10(wet)) < 0.3);
  }
  free(x);
  free(y);
}

/* The time is the note value at the song tempo: 1/4 at 120 BPM is 500 ms,
 * 1/16T at 90 BPM 111 ms; 8/4 at 60 BPM (8 s) holds at the line's 4 s. */
static void test_mode_delay_note_values(void) {
  printf("test_mode_delay_note_values\n");
  static const struct {
    int div;
    double bpm, ms;
  } want[3] = {{9, 120.0, 500.0}, {1, 90.0, 1000.0 / 9.0}, {19, 60.0, 4000.0}};
  const int n = 5 * MD_SR;
  float* x = (float*)calloc((size_t)n, sizeof(float));
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  x[100] = 1.0f;
  for (int w = 0; w < 3; ++w) {
    const le_fx_tempo t = rh_tempo(want[w].bpm);
    const float p[LE_FX_PARAMS] = {md_choice(want[w].div, 20), 0.0f, 0.5f, 0.0f};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    int peak = 200;
    for (int i = 200; i < n; ++i) {
      if (fabsf(y[i]) > fabsf(y[peak])) peak = i;
    }
    const double ms = 1000.0 * (peak - 100) / MD_SR;
    printf("  position %d at %.0f BPM: %.1f ms (want %.1f)\n", want[w].div,
           want[w].bpm, ms, want[w].ms);
    CHECK(fabs(ms - want[w].ms) < 0.5);
  }
  free(x);
  free(y);
}

/* A new time crossfades over 20 ms: switching 1/8D to 1/4 under a steady
 * tone never steps the output by more than the tone itself moves. */
static void test_mode_delay_time_change_crossfades(void) {
  printf("test_mode_delay_time_change_crossfades\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = 2 * MD_SR;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    x[i] = 0.25f * sinf(2.0f * 3.14159265f * 200.0f * (float)i / MD_SR);
  }
  le_fx_state* fx = md_state(&t);
  const float a[LE_FX_PARAMS] = {md_choice(8, 20), 0.5f, 0.5f, 0.0f};
  const float b[LE_FX_PARAMS] = {md_choice(9, 20), 0.5f, 0.5f, 0.0f};
  md_run(fx, a, x, y, NULL, MD_SR);
  md_run(fx, b, x + MD_SR, y + MD_SR, NULL, MD_SR);
  le_fx_state_free_buffers(fx);
  free(fx);
  float worst = 0.0f;
  for (int i = MD_SR + 1; i < MD_SR + MD_SR / 10; ++i) {
    worst = fmaxf(worst, fabsf(y[i] - y[i - 1]));
  }
  const float tone = 4.0f * 0.25f * 2.0f * 3.14159265f * 200.0f / MD_SR;
  printf("  largest step %.4f (the tones' own up to %.4f)\n", (double)worst,
         (double)tone);
  CHECK(worst < tone);
  free(x);
  free(y);
}

/* A reset or a ring clear after the first echo leaves nothing old to
 * hear: either is silent at once, and the second echo never comes. */
static void test_mode_delay_clear_reads_nothing_old(void) {
  printf("test_mode_delay_clear_reads_nothing_old\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = MD_SR;
  const int period = MD_SR * 375 / 1000;
  const int at = 1000 + period + MD_SR / 50; /* inside the first echo */
  float* x = md_burst(250.0, n);
  float* z = (float*)calloc((size_t)n, sizeof(float));
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.5f, 0.3f, 0.0f};
  for (int k = 0; k < 2; ++k) {
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, at);
    float heard = 0.0f;
    for (int i = at - 2000; i < at; ++i) heard = fmaxf(heard, fabsf(y[i]));
    CHECK(heard > 0.01f); /* the echo was sounding */
    if (k == 0) {
      le_fx_entry_reset(fx, 0);
    } else {
      le_fx_entry_clear_rings(fx, 0, MD_SR);
    }
    md_run(fx, p, z, y, NULL, n);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) peak = fmaxf(peak, fabsf(y[i]));
    CHECK(peak == 0.0f);
    le_fx_state_free_buffers(fx);
    free(fx);
  }
  free(x);
  free(z);
  free(y);
}

/* The taps on an impulse (#891, s4/10-11, gC 36/38): L/R's early tap is
 * exactly half the time and GRV's 0.837 of it (313.8 ms at 1/8D), and
 * each side carries the other at the capture's ratio to its own: L/R
 * left -17.0 dB, right -16.9; GRV left -17.0, right -16.8 (within
 * 0.5 dB). */
static void test_mode_delay_taps(void) {
  printf("test_mode_delay_taps\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = MD_SR;
  const int period = MD_SR * 375 / 1000;
  float* x = (float*)calloc((size_t)n, sizeof(float));
  float* yl = (float*)malloc(sizeof(float) * (size_t)n);
  float* yr = (float*)malloc(sizeof(float) * (size_t)n);
  x[100] = 1.0f;
  static const struct {
    int mode, early;
    double l_cross, r_cross;
  } want[2] = {{1, 9000, -17.0, -16.9}, {2, 15062, -17.0, -16.8}};
  for (int w = 0; w < 2; ++w) {
    const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.5f, 0.5f,
                                   md_choice(want[w].mode, 12)};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, yl, yr, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    /* Each tap's peak near where it lands. */
    int ri = 200;
    for (int i = 200; i < 100 + period - 500; ++i) {
      if (fabsf(yr[i]) > fabsf(yr[ri])) ri = i;
    }
    float r_main = 0.0f, r_x = 0.0f, l_main = 0.0f, l_x = 0.0f;
    for (int i = -20; i < 20; ++i) {
      r_main = fmaxf(r_main, fabsf(yr[100 + want[w].early + i]));
      l_x = fmaxf(l_x, fabsf(yl[100 + want[w].early + i]));
      r_x = fmaxf(r_x, fabsf(yr[100 + period + i]));
      l_main = fmaxf(l_main, fabsf(yl[100 + period + i]));
    }
    const double lc = 20.0 * log10(l_x / l_main);
    const double rc = 20.0 * log10(r_x / r_main);
    printf("  mode %d: early tap at %d (want %d), left cross %+5.1f (%+5.1f), "
           "right cross %+5.1f (%+5.1f)\n",
           want[w].mode, ri - 100, want[w].early, lc, want[w].l_cross, rc,
           want[w].r_cross);
    CHECK(abs(ri - 100 - want[w].early) <= 2);
    CHECK(fabs(lc - want[w].l_cross) < 0.5);
    CHECK(fabs(rc - want[w].r_cross) < 0.5);
  }
  free(x);
  free(yl);
  free(yr);
}

/* At 100 % Feedback a resonant voicing would grow; the echo's limit holds
 * every echo under its 0.60 ceiling, so the output stays under 0.65 (the
 * ceiling and the output filters' ringing). */
static void test_mode_delay_loop_is_bounded(void) {
  printf("test_mode_delay_loop_is_bounded\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = 4 * MD_SR;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  static const int modes[3] = {0, 6, 9}; /* DIGI, RESO LO, RESO HI */
  static const double hz[3] = {200.0, 981.0, 2425.0};
  for (int k = 0; k < 3; ++k) {
    float* x = md_burst(hz[k], n);
    const float p[LE_FX_PARAMS] = {md_choice(4, 20), 1.0f, 1.0f,
                                   md_choice(modes[k], 12)};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) {
      CHECK(isfinite(y[i]));
      peak = fmaxf(peak, fabsf(y[i]));
    }
    printf("  mode %d at 100 %%: peak %.2f\n", modes[k], (double)peak);
    CHECK(peak < 0.65f);
    free(x);
  }
  /* A sustained full-scale tone, voiced +6 dB: still under 0.65. */
  {
    float* x = (float*)malloc(sizeof(float) * (size_t)n);
    for (int i = 0; i < n; ++i) {
      x[i] = sinf(2.0f * 3.14159265f * 2425.0f * (float)i / MD_SR);
    }
    const float p[LE_FX_PARAMS] = {md_choice(9, 20), 1.0f, 1.0f,
                                   md_choice(9, 12)};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) peak = fmaxf(peak, fabsf(y[i]));
    printf("  RESO HI, sustained full scale: peak %.2f\n", (double)peak);
    CHECK(peak < 0.65f);
    free(x);
  }
  free(y);
}

/* The voicings hold at 96 kHz: RESO LO's peak and loop at 1 kHz. */
static void test_mode_delay_at_96k(void) {
  printf("test_mode_delay_at_96k\n");
  const int sr = 96000;
  le_fx_tempo t = rh_tempo(120.0);
  t.qpf = (float)(2.0 / (double)sr);
  const int n = 2 * sr;
  float* x = (float*)calloc((size_t)n, sizeof(float));
  const int len = sr * 60 / 1000;
  const int ramp = sr * 5 / 1000;
  for (int i = 0; i < len; ++i) {
    double g = 1.0;
    if (i < ramp) g = (double)i / ramp;
    if (i > len - ramp) g = (double)(len - i) / ramp;
    x[1000 + i] = (float)(0.25 * g * sin(2.0 * 3.14159265358979 * 1000.0 * i / sr));
  }
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.5f, 0.3f, md_choice(6, 12)};
  le_fx_state* fx = md_state_at(&t, sr);
  md_run_at(fx, sr, p, x, y, NULL, n);
  le_fx_state_free_buffers(fx);
  free(fx);
  const int period = sr * 375 / 1000;
  double e[3] = {0.0, 0.0, 0.0};
  for (int k = 0; k < 3; ++k) {
    const int from = 1000 + sr / 100 + k * period;
    for (int i = from; i < from + sr / 25; ++i) e[k] += (double)y[i] * y[i];
  }
  const double first = 10.0 * log10(e[1] / e[0]) - 20.0 * log10(0.36);
  const double loop = 10.0 * log10(e[2] / e[1]) - 20.0 * log10(0.5);
  printf("  RESO LO at 1 kHz: first %+5.1f (capture +6.2), loop %+5.1f "
         "(+1.0)\n",
         first, loop);
  CHECK(fabs(first - 6.2) < 0.5);
  CHECK(fabs(loop - 1.0) < 0.5);
  free(x);
  free(y);
}

/* Bypassed, a 2 s delay drains its echo: the quiet that settles the slot is
 * its own line's length, not the one-second ring's. */
static void test_mode_delay_drains_its_whole_line(void) {
  printf("test_mode_delay_drains_its_whole_line\n");
  le_engine* e = make_configured_engine();
  static float cap[4096];
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_MODE_DELAY) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK);
  /* 4/4: 2 s at 120 BPM (the engine's tempo with none set), no feedback. */
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 0, md_choice(16, 20)) ==
        LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 0.0f) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 0.5f) == LE_OK);
  drain(e);
  process_n(e, 1.0f, 64, cap);
  CHECK(le_engine_set_monitor_input_fx_enabled(e, 0, 0, 0) == LE_OK);
  /* Run to just before the echo, then listen for it. */
  const int sr = 48000;
  int done = 64;
  while (done + 4096 < 2 * sr - 2048) {
    process_n(e, 0.0f, 4096, cap);
    done += 4096;
  }
  float peak = 0.0f;
  for (int k = 0; k < 2; ++k) {
    process_n(e, 0.0f, 4096, cap);
    for (int i = 0; i < 4096; ++i) peak = fmaxf(peak, fabsf(cap[i]));
  }
  printf("  the echo 2 s after, bypassed: peak %.3f\n", (double)peak);
  CHECK(peak > 0.1f);
  le_engine_destroy(e);
}

/* On the song's tempo, which a print would not keep: a lane holding one
 * that is heard is never printed. */
static void test_mode_delay_is_not_printed(void) {
  printf("test_mode_delay_is_not_printed\n");
  float p[LE_FX_PARAMS] = {0};
  le_fx_defaults(LE_FX_MODE_DELAY, p);
  CHECK(le_fx_type_free_running(LE_FX_MODE_DELAY));
  CHECK(le_fx_entry_free_running(LE_FX_MODE_DELAY, p, MD_SR));
  p[2] = 0.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_MODE_DELAY, p, MD_SR));
}

/* A Mode delay's re-enable empties its line at once (an O(1) reset), so
 * it neither waits on the ring-clear spacing a stomp leaves nor sets it:
 * with the spacing running, it starts its ramp on the edge's own sample. */
static void test_mode_delay_reenable_skips_the_spacing(void) {
  printf("test_mode_delay_reenable_skips_the_spacing\n");
  const le_fx_tempo t = rh_tempo(120.0);
  le_fx_state* fx = md_state(&t);
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  static int32_t enabled[LE_FX_MAX];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_MODE_DELAY;
  const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.0f, 0.5f, 0.0f};
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  /* Bypassed long enough to have settled. */
  enabled[0] = 0;
  int i = 0;
  for (; i < 5 * MD_SR; ++i) {
    fx->clock = (uint32_t)i;
    float l = i >= 1000 && i < 1100 ? 0.5f : 0.0f;
    float r = l;
    fx_apply_chain(fx, MD_SR, MD_SR, &l, &r, 1, types, params, enabled);
  }
  CHECK(fx->enable_drain[0] == 0);
  fx->enable_clear_cooldown = 128; /* LE_FX_ENABLE_CLEAR_SPACING */
  enabled[0] = 1;
  fx->clock = (uint32_t)i;
  float l = 0.0f, r = 0.0f;
  fx_apply_chain(fx, MD_SR, MD_SR, &l, &r, 1, types, params, enabled);
  CHECK(fx->enable_target[0] == 1);
  CHECK(fx->enable_mix[0] > 0.0f);
  /* The spacing ran on by the one sample, not restarted. */
  CHECK(fx->enable_clear_cooldown == 127);
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* The early tap's voicing starts clean when L/R comes back after a spell
 * of the plain timing: switched in over silence, the right side stays
 * silent (stale state there would ring out). */
static void test_mode_delay_timing_switch_is_clean(void) {
  printf("test_mode_delay_timing_switch_is_clean\n");
  const le_fx_tempo t = rh_tempo(120.0);
  le_fx_state* fx = md_state(&t);
  const int n = 6 * MD_SR;
  float* x = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < MD_SR / 2; ++i) {
    x[i] = 0.5f * sinf(2.0f * 3.14159265f * 981.0f * (float)i / MD_SR);
  }
  float* yl = (float*)malloc(sizeof(float) * (size_t)n);
  float* yr = (float*)malloc(sizeof(float) * (size_t)n);
  const float lr[LE_FX_PARAMS] = {md_choice(8, 20), 0.0f, 0.5f,
                                  md_choice(7, 12)}; /* RES LO L/R */
  const float plain[LE_FX_PARAMS] = {md_choice(8, 20), 0.0f, 0.5f,
                                     md_choice(6, 12)}; /* RESO LO */
  md_run(fx, lr, x, yl, yr, MD_SR / 2 + 100); /* the early tap ringing */
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_MODE_DELAY;
  float peak = 0.0f;
  for (int i = MD_SR / 2 + 100; i < n; ++i) {
    const float* p = i < 5 * MD_SR ? plain : lr;
    for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
    fx->clock = (uint32_t)i;
    float l = x[i];
    float r = x[i];
    fx_apply_chain(fx, MD_SR, MD_SR, &l, &r, 1, types, params, NULL);
    if (i >= 5 * MD_SR) peak = fmaxf(peak, fabsf(r));
  }
  printf("  right side after the switch: peak %.2e\n", (double)peak);
  CHECK(peak < 1e-9f);
  le_fx_state_free_buffers(fx);
  free(fx);
  free(x);
  free(yl);
  free(yr);
}

/* A hot echo saturates (#891 s6v 17, DIGI at Feedback 0 %): a -3 dBFS
 * 1 kHz tone echoes 0.2 dB down and a 0 dBFS one 3.1 dB down (its
 * fundamental), within 0.6 dB; a -6 dBFS one echoes at its own level. */
static void test_mode_delay_hot_echo_saturates(void) {
  printf("test_mode_delay_hot_echo_saturates\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int n = MD_SR;
  const double amp[3] = {0.5012, 0.7079, 1.0};
  const double want[3] = {0.0, -0.2, -3.1};
  for (int k = 0; k < 3; ++k) {
    float* x = (float*)calloc((size_t)n, sizeof(float));
    float* y = (float*)malloc(sizeof(float) * (size_t)n);
    for (int i = 100; i < 100 + MD_SR / 4; ++i) {
      x[i] = (float)(amp[k] * sin(2.0 * 3.14159265358979 * 1000.0 * i / MD_SR));
    }
    const float p[LE_FX_PARAMS] = {md_choice(8, 20), 0.0f, 0.5f, 0.0f};
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    /* The echo of the tone's middle, after the tone has ended. */
    const int period = MD_SR * 375 / 1000;
    const int from = 100 + MD_SR / 8, len = MD_SR / 10;
    double re = 0.0, im = 0.0, xr = 0.0, xi = 0.0;
    for (int i = from; i < from + len; ++i) {
      const double ph = 2.0 * 3.14159265358979 * 1000.0 * i / MD_SR;
      re += y[i + period] * cos(ph);
      im += y[i + period] * sin(ph);
      xr += x[i] * cos(ph);
      xi += x[i] * sin(ph);
    }
    const double db = 10.0 * log10((re * re + im * im) / (xr * xr + xi * xi));
    printf("  %+.1f dBFS: echo %+.2f dB (capture %+.1f)\n",
           20.0 * log10(amp[k]), db, want[k]);
    CHECK(fabs(db - want[k]) < 0.6);
    free(x);
    free(y);
  }
}

/* DIGI at 100 % Feedback (#891 s6v 18): a quiet 500 Hz burst's repeats
 * lose nothing (the second within 1 % of the first; the capture's impulse
 * gave 0.996), and a hot tone's repeats, held by the feedback's limit,
 * are at the fit's level 3 s after the tone stops (0.297, within 0.6 dB;
 * with no limit they would sit at the echo's 0.60). They go on decaying
 * toward the knee after that. */
static void test_mode_delay_full_feedback(void) {
  printf("test_mode_delay_full_feedback\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const int period = MD_SR * 375 / 1000;
  const float p[LE_FX_PARAMS] = {md_choice(8, 20), 1.0f, 0.5f, 0.0f};
  {
    const int n = 3 * period + 1000;
    float* x = (float*)calloc((size_t)n, sizeof(float));
    float* y = (float*)malloc(sizeof(float) * (size_t)n);
    const int len = MD_SR * 40 / 1000;
    for (int i = 0; i < len; ++i) {
      const double w = 0.5 - 0.5 * cos(2.0 * 3.14159265358979 * i / len);
      x[100 + i] = (float)(0.1 * w * sin(2.0 * 3.14159265358979 * 500.0 * i / MD_SR));
    }
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    double e1 = 0.0, e2 = 0.0;
    for (int k = -200; k < len + 400; ++k) {
      e1 += (double)y[100 + period + k] * y[100 + period + k];
      e2 += (double)y[100 + 2 * period + k] * y[100 + 2 * period + k];
    }
    const double ratio = sqrt(e2 / e1);
    printf("  second echo %.4f of the first\n", ratio);
    CHECK(fabs(ratio - 1.0) < 0.01);
    free(x);
    free(y);
  }
  {
    const int n = 6 * MD_SR;
    float* x = (float*)calloc((size_t)n, sizeof(float));
    float* y = (float*)malloc(sizeof(float) * (size_t)n);
    for (int i = 0; i < MD_SR; ++i) {
      x[i] = 0.5f * sinf(2.0f * 3.14159265f * 1000.0f * (float)i / MD_SR);
    }
    le_fx_state* fx = md_state(&t);
    md_run(fx, p, x, y, NULL, n);
    le_fx_state_free_buffers(fx);
    free(fx);
    float peak = 0.0f;
    for (int i = 4 * MD_SR; i < n; ++i) peak = fmaxf(peak, fabsf(y[i]));
    printf("  repeats 3 s after the tone: peak %.3f (fit 0.297)\n", (double)peak);
    CHECK(fabs(20.0 * log10(peak / 0.297)) < 0.6);
    free(x);
    free(y);
  }
}

static void run_mode_delay_tests(void) {
  test_mode_delay_is_not_printed();
  test_mode_delay_voicings();
  test_mode_delay_timings();
  test_mode_delay_mix_law();
  test_mode_delay_note_values();
  test_mode_delay_time_change_crossfades();
  test_mode_delay_clear_reads_nothing_old();
  test_mode_delay_taps();
  test_mode_delay_loop_is_bounded();
  test_mode_delay_at_96k();
  test_mode_delay_reenable_skips_the_spacing();
  test_mode_delay_timing_switch_is_clean();
  test_mode_delay_hot_echo_saturates();
  test_mode_delay_full_feedback();
  test_mode_delay_drains_its_whole_line();
}
