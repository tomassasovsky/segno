/* The Dual Octaver's first voice (#887 part 11), against the #891 s5
 * captures. Included by test_engine_core.c after the Mode delay tests. */

#define DO_SR 48000
static int do_sr = DO_SR; /* the rate do_levels runs at */

/* The amplitude of [hz] in [y] over [n] frames. */
static double do_amp(const float* y, int n, double hz) {
  double c = 0.0, s = 0.0, w = 0.0;
  for (int i = 0; i < n; ++i) {
    const double h = 0.5 - 0.5 * cos(2.0 * 3.14159265358979 * i / (n - 1));
    const double ph = 2.0 * 3.14159265358979 * hz * i / do_sr;
    c += y[i] * h * cos(ph);
    s += y[i] * h * sin(ph);
    w += h;
  }
  return 2.0 * sqrt(c * c + s * s) / w;
}

/* A second of a [hz] sine at -12 dBFS through the Dual Octaver at [p];
 * returns the output (malloc'd, do_sr frames). */
static float* do_render(const float* p, double hz) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_DUAL_OCTAVER, do_sr) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_DUAL_OCTAVER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  const int n = do_sr;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = 0.2512f * (float)sin(2.0 * 3.14159265358979 * hz * i / do_sr);
    float r = l;
    fx_apply_chain(fx, do_sr, do_sr, &l, &r, 1, types, params, NULL);
    y[i] = l;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  return y;
}

/* do_render's 1 kHz tone with [p] throughout; the amplitudes at 500 Hz,
 * 1 kHz, 2 kHz, 250 Hz and 4 kHz over its second half, in dB against the
 * input's. */
static void do_levels(const float* p, double* db) {
  const int n = do_sr;
  float* y = do_render(p, 1000.0);
  static const double hz[5] = {500.0, 1000.0, 2000.0, 250.0, 4000.0};
  for (int k = 0; k < 5; ++k) {
    db[k] = 20.0 * log10(do_amp(y + n / 2, n / 2, hz[k]) / 0.2512 + 1e-12);
  }
  free(y);
}

/* High mode off: one octave down at -0.3 dB against the dry; on: one
 * octave up at 0.0 dB (s5/4-5 and s6v 25, Mix 100 %, each read at its own
 * frequency); Mix 50 %: the dry and the voice each 3 dB down (s5/7, an
 * equal-power mix). */
static void test_dual_octaver_matches_the_capture(void) {
  printf("test_dual_octaver_matches_the_capture\n");
  double db[5];
  const float down[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f};
  do_levels(down, db);
  printf("  off: 500 Hz %+5.1f (capture -0.3), 1 kHz %+5.1f\n", db[0], db[1]);
  CHECK(fabs(db[0] + 0.26) < 0.1);
  CHECK(db[1] < -30.0);
  const float up[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f};
  do_levels(up, db);
  printf("  on: 2 kHz %+5.1f (capture 0.0), 1 kHz %+5.1f\n", db[2], db[1]);
  CHECK(fabs(db[2] + 0.04) < 0.1);
  CHECK(db[1] < -30.0);
  const float half[LE_FX_PARAMS] = {1.0f, 1.0f, 0.5f};
  do_levels(half, db);
  printf("  on at 50 %%: 1 kHz %+5.1f (capture -3.0), 2 kHz %+5.1f (-3.0)\n",
         db[1], db[2]);
  CHECK(fabs(db[1] + 3.0) < 0.1);
  CHECK(fabs(db[2] + 3.04) < 0.1);
  /* Octave 1 Vol scales the voice (its taper unmeasured: linear here). */
  const float quiet[LE_FX_PARAMS] = {0.0f, 0.5f, 1.0f};
  do_levels(quiet, db);
  CHECK(fabs(db[0] - (-0.26 + 20.0 * log10(0.5))) < 0.1);
}

/* High mode is a switch: flipped under a tone, the voice dips out and comes
 * back an octave pair away, never sweeping through the octaves between. The
 * shift the vocoder runs at is only ever one octave down or up once the
 * start's dip is over, and nothing between 600 and 1800 Hz sounds across
 * the switch (a glide put -14 dB at 1750 Hz there). With Octave 2 up
 * (#1464) its voice switches in the same dip: nothing between 2.2 and
 * 3.8 kHz across the switch, and no 4 kHz while the old voices fade out. */
static void do_switch(float octave2) {
  printf("  Octave 2 at %.0f %%\n", octave2 * 100.0f);
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_DUAL_OCTAVER, DO_SR) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_DUAL_OCTAVER;
  const int n = DO_SR;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  int between = 0;
  for (int i = 0; i < n; ++i) {
    params[0][0] = i < n / 2 ? 0.0f : 1.0f;
    params[0][1] = 1.0f;
    params[0][2] = 1.0f;
    params[0][3] = octave2;
    fx->clock = (uint32_t)i;
    float l = 0.2512f * sinf(2.0f * 3.14159265f * 1000.0f * (float)i / DO_SR);
    float r = l;
    fx_apply_chain(fx, DO_SR, DO_SR, &l, &r, 1, types, params, NULL);
    y[i] = l;
    const float sh = fx->oct[0][0].sm_shift;
    if (i > DO_SR / 10 && sh != 0.25f && sh != 0.75f) ++between;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  CHECK(between == 0);
  /* The worst 25 Hz bin from 600 to 1800 Hz over the 50 ms after the
   * switch (and the vocoder's latency). */
  double worst = -200.0;
  for (double hz = 600.0; hz <= 1800.0; hz += 25.0) {
    const double db =
        20.0 * log10(do_amp(y + n / 2, DO_SR / 20, hz) / 0.2512 + 1e-12);
    if (db > worst) worst = db;
  }
  printf("  600-1800 Hz across the switch: worst %+5.1f dB\n", worst);
  CHECK(worst < -30.0);
  if (octave2 > 0.0f) {
    double high = -200.0;
    for (double hz = 2200.0; hz <= 3800.0; hz += 25.0) {
      const double db =
          20.0 * log10(do_amp(y + n / 2, DO_SR / 20, hz) / 0.2512 + 1e-12);
      if (db > high) high = db;
    }
    const double early =
        20.0 * log10(do_amp(y + n / 2, DO_SR * 15 / 1000, 4000.0) / 0.2512 +
                     1e-12);
    printf("  2.2-3.8 kHz: worst %+5.1f dB; 4 kHz in the fade-out %+5.1f dB\n",
           high, early);
    CHECK(high < -30.0);
    /* A voice 2 that skipped the dip put -31 dB here. */
    CHECK(early < -60.0);
  }
  free(y);
}

static void test_dual_octaver_mode_switch_does_not_sweep(void) {
  printf("test_dual_octaver_mode_switch_does_not_sweep\n");
  do_switch(0.0f);
  do_switch(1.0f);
}

/* Octave 2 (#1464), from the same analysis: two octaves up in high mode
 * (s5/6: 0.0 and -0.2 dB against the dry); two octaves down without it
 * (s6v 25-27: -0.3 and -0.2 dB, and -6.2 dB at Octave 2 Vol 50 %); and
 * Octave 1 as it was alone. */
static void test_dual_octaver_second_voice(void) {
  printf("test_dual_octaver_second_voice\n");
  double db[5];
  const float up[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f, 1.0f};
  do_levels(up, db);
  printf("  on: 2 kHz %+5.1f, 4 kHz %+5.1f (capture -0.0, -0.2)\n", db[2],
         db[4]);
  CHECK(fabs(db[2] + 0.04) < 0.2);
  CHECK(fabs(db[4] + 0.15) < 0.2);
  const float down[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 1.0f};
  do_levels(down, db);
  printf("  off: 500 Hz %+5.1f, 250 Hz %+5.1f (capture -0.3, -0.2)\n",
         db[0], db[3]);
  CHECK(fabs(db[0] + 0.25) < 0.1);
  CHECK(fabs(db[3] + 0.14) < 0.1);
  const float down_half[LE_FX_PARAMS] = {0.0f, 0.0f, 1.0f, 0.5f};
  do_levels(down_half, db);
  printf("  Octave 2 alone at 50 %%: 250 Hz %+5.1f (capture -6.2)\n", db[3]);
  CHECK(fabs(db[3] + 6.18) < 0.15);
  const float half[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f, 0.5f};
  do_levels(half, db);
  CHECK(fabs(db[4] - (-0.15 + 20.0 * log10(0.5))) < 0.2);
  /* s5/7: both voices at Mix 50 %, the dry 3 dB down. */
  const float mixed[LE_FX_PARAMS] = {1.0f, 1.0f, 0.5f, 1.0f};
  do_levels(mixed, db);
  printf("  at 50 %%: 1 kHz %+5.1f (capture -3.0), 2 kHz %+5.1f (-3.1), "
         "4 kHz %+5.1f (-3.2)\n",
         db[1], db[2], db[4]);
  CHECK(fabs(db[1] + 3.02) < 0.2);
  CHECK(fabs(db[2] + 3.05) < 0.2);
  CHECK(fabs(db[4] + 3.16) < 0.2);
}

/* The appliance runs at 96 kHz and the trims were fit at 48 kHz. Both up
 * voices hold their captured level there too. */
static void test_dual_octaver_trims_at_96k(void) {
  printf("test_dual_octaver_trims_at_96k\n");
  do_sr = 96000;
  double db[5];
  const float up[LE_FX_PARAMS] = {1.0f, 1.0f, 1.0f, 1.0f};
  do_levels(up, db);
  do_sr = DO_SR;
  printf("  2 kHz %+.1f, 4 kHz %+.1f (capture -0.0, -0.2)\n", db[2], db[4]);
  CHECK(fabs(db[2] - -0.04) < 0.3);
  CHECK(fabs(db[4] - -0.15) < 0.3);
}

/* The RMS below 15 Hz (a one-pole low-pass) over [y]'s second half. */
static double do_sub15(const float* y, int n) {
  const double a = 1.0 - exp(-2.0 * 3.14159265358979 * 15.0 / do_sr);
  double lp = 0.0, sum = 0.0;
  for (int i = 0; i < n; ++i) {
    lp += a * (y[i] - lp);
    if (i >= n / 2) sum += lp * lp;
  }
  return sqrt(sum / (n / 2));
}

/* Octave 2 down on low bass at the appliance's rate: its target falls
 * below the first bin (41 Hz two down is 10 Hz; a bin is 93.75 Hz), and
 * that region is dropped rather than shifted onto DC, so Octave 2 adds no
 * subsonic content. Octave 1 keeps the shipped octaver's shift. */
static void test_dual_octaver_low_voice_skips_dc(void) {
  printf("test_dual_octaver_low_voice_skips_dc\n");
  do_sr = 96000;
  const int n = do_sr;
  const float off[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 0.0f};
  float* a = do_render(off, 41.0);
  const float on[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 1.0f};
  float* b = do_render(on, 41.0);
  const double sa = do_sub15(a, n), sb = do_sub15(b, n);
  do_sr = DO_SR;
  printf("  below 15 Hz: Octave 2 off %.4f, on %.4f\n", sa, sb);
  /* Shifted onto DC instead, Octave 2 put 0.121 here (against 0.062). */
  CHECK(sb < sa * 1.2 + 1e-6);
  free(a);
  free(b);
}

/* ---- The low band (#1467), against the s15bass capture (#891) ---- */

/* Sample [i] of the test tones at -12 dBFS peak: a sine at [hz], or with
 * [harm] the capture's harmonic bass (harmonics 1 to 10 at 1/k, scaled by
 * [norm] to the same peak). */
static double do_tone(int harm, double hz, int i, double norm) {
  const double t = 2.0 * 3.14159265358979 * hz * i / do_sr;
  if (!harm) return 0.2512 * sin(t);
  double y = 0.0;
  for (int k = 1; k <= 10; ++k) y += sin(k * t) / k;
  return y * norm;
}

/* do_render for the low band: two seconds of the tone through the Dual
 * Octaver at [p], into [y] (do_sr * 2 frames). [am] modulates the tone's
 * level at 3 Hz by +-50 % (0: steady). With [vocoder_only] the slot is
 * prepared as the octaver, which carries no band, so the Dual Octaver
 * runs its vocoder alone. Returns the tone's amplitude at [hz]. */
static double do_render_low(const float* p, int harm, double hz, double am,
                            int vocoder_only, float* y) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, vocoder_only ? LE_FX_OCTAVER : LE_FX_DUAL_OCTAVER,
                      do_sr) == LE_OK);
  CHECK(vocoder_only ? fx->oct[0][0].low == NULL : fx->oct[0][0].low != NULL);
  le_fx_entry_reset(fx, 0);
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_DUAL_OCTAVER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  double peak = 0.0;
  for (int i = 0; i < do_sr; ++i) {
    const double v = fabs(do_tone(harm, hz, i, 1.0));
    if (v > peak) peak = v;
  }
  const double norm = 0.2512 / peak;
  for (int i = 0; i < 2 * do_sr; ++i) {
    fx->clock = (uint32_t)i;
    const double env =
        1.0 + am * sin(2.0 * 3.14159265358979 * 3.0 * i / do_sr);
    float l = (float)(env * do_tone(harm, hz, i, norm));
    float r = l;
    fx_apply_chain(fx, do_sr, do_sr, &l, &r, 1, types, params, NULL);
    y[i] = l;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  return harm ? norm : 0.2512; /* the fundamental's amplitude */
}

/* The level, in dB against the input's fundamental, at [hz] / [div] over
 * the second second of do_render_low. */
static double do_low_level(const float* p, int harm, double hz, double div) {
  float* y = (float*)malloc(sizeof(float) * (size_t)(2 * do_sr));
  CHECK(y != NULL);
  const double a = do_render_low(p, harm, hz, 0.0, 0, y);
  const double db = 20.0 * log10(do_amp(y + do_sr, do_sr, hz / div) / a + 1e-12);
  free(y);
  return db;
}

/* The Looper X's down voices on bass (s15bass, High Mode off, Mix 100 %,
 * each voice alone at 100 %, read at its own frequency against the input's
 * fundamental): Octave 1 at -1.3 dB on 82 Hz and 0.0 on 110 Hz, Octave 2
 * at -3.0 and 0.0, on a sine and on a harmonic bass alike. The vocoder
 * alone gave -45 and -32 dB here at 96 kHz (#1467). The band's floor is fit
 * to Octave 1's 82 Hz point, so Octave 2 sits 1.6 dB above the capture
 * there. Both rates: the appliance runs at 96 kHz. */
static void test_dual_octaver_low_band_matches_the_capture(void) {
  printf("test_dual_octaver_low_band_matches_the_capture\n");
  static const int rates[2] = {48000, 96000};
  static const double hz[2] = {82.0, 110.0};
  static const double cap1[2] = {-1.3, 0.0};
  static const double cap2[2] = {-3.0, 0.0};
  static const double tol2[2] = {2.0, 0.5};
  const float oct1[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 0.0f};
  const float oct2[LE_FX_PARAMS] = {0.0f, 0.0f, 1.0f, 1.0f};
  for (int r = 0; r < 2; ++r) {
    do_sr = rates[r];
    for (int k = 0; k < 2; ++k) {
      for (int harm = 0; harm < 2; ++harm) {
        const double d1 = do_low_level(oct1, harm, hz[k], 2.0);
        const double d2 = do_low_level(oct2, harm, hz[k], 4.0);
        printf("  %d Hz, %3.0f Hz %s: Octave 1 %+5.1f (capture %+.1f), "
               "Octave 2 %+5.1f (%+.1f)\n",
               do_sr, hz[k], harm ? "bass" : "sine", d1, cap1[k], d2, cap2[k]);
        CHECK(fabs(d1 - cap1[k]) < 0.5);
        CHECK(fabs(d2 - cap2[k]) < tol2[k]);
      }
    }
  }
  do_sr = DO_SR;
}

/* At 41 Hz the Looper X shifts nothing (s15bass: no down voice, the input
 * played as it is), and the band, whose floor is 60 Hz, stays out: the
 * Dual Octaver plays its vocoder exactly as it did without the band. So
 * does a tone above the crossover (1 kHz), where the band hears no pitch
 * and the vocoder's own voice is untouched. */
static void test_dual_octaver_low_band_hands_back(void) {
  printf("test_dual_octaver_low_band_hands_back\n");
  static const int rates[2] = {48000, 96000};
  static const double hz[2] = {41.0, 1000.0};
  const float both[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 0.6f};
  const int n = 2 * 96000;
  float* a = (float*)malloc(sizeof(float) * (size_t)n);
  float* b = (float*)malloc(sizeof(float) * (size_t)n);
  CHECK(a != NULL && b != NULL);
  for (int r = 0; r < 2; ++r) {
    do_sr = rates[r];
    for (int k = 0; k < 2; ++k) {
      for (int harm = 0; harm < 2; ++harm) {
        do_render_low(both, harm, hz[k], 0.0, 0, a);
        do_render_low(both, harm, hz[k], 0.0, 1, b);
        int same = 1;
        for (int i = 0; i < 2 * do_sr; ++i) same &= a[i] == b[i];
        printf("  %d Hz, %4.0f Hz %s: %s the vocoder alone\n", do_sr, hz[k],
               harm ? "bass" : "sine", same ? "identical to" : "DIFFERS from");
        CHECK(same);
      }
    }
  }
  do_sr = DO_SR;
  free(a);
  free(b);
}

/* The envelope of [y] (do_sr * 2 frames): its square through a two-pole
 * 15 Hz low-pass, into [e]. */
static void do_envelope(const float* y, double* e) {
  const double a = 1.0 - exp(-2.0 * 3.14159265358979 * 15.0 / do_sr);
  double p1 = 0.0, p2 = 0.0;
  for (int i = 0; i < 2 * do_sr; ++i) {
    p1 += a * (2.0 * y[i] * y[i] - p1);
    p2 += a * (p1 - p2);
    e[i] = p2;
  }
}

/* The lag, in frames (to 4), that best lines envelope [ey] up with [ex]
 * over the second second, each less its mean. */
static int do_envelope_lag(const double* ex, const double* ey) {
  const int span = do_sr / 20;
  double best = -1e300;
  int at = 0;
  for (int lag = 0; lag < span; lag += 4) {
    double mx = 0.0, my = 0.0;
    int n = 0;
    for (int i = do_sr; i < 2 * do_sr - span; i += 8) {
      mx += ex[i];
      my += ey[i + lag];
      ++n;
    }
    mx /= n;
    my /= n;
    double c = 0.0;
    for (int i = do_sr; i < 2 * do_sr - span; i += 8) {
      c += (ex[i] - mx) * (ey[i + lag] - my);
    }
    if (c > best) {
      best = c;
      at = lag;
    }
  }
  return at;
}

/* The band is aligned to the vocoder's voice: its taps centre on the
 * octaver's latency less the crossover's group delay. A 110 Hz tone swells
 * at 3 Hz; the down voice's swell comes out of the band within a
 * millisecond of where the vocoder alone puts it, at both rates. (Each
 * lands about 1.5 ms past LE_PV_LATENCY on this measure, the vocoder too.) */
static void test_dual_octaver_low_band_keeps_the_latency(void) {
  printf("test_dual_octaver_low_band_keeps_the_latency\n");
  static const int rates[2] = {48000, 96000};
  const float oct1[LE_FX_PARAMS] = {0.0f, 1.0f, 1.0f, 0.0f};
  for (int r = 0; r < 2; ++r) {
    do_sr = rates[r];
    const int n = 2 * do_sr;
    float* x = (float*)malloc(sizeof(float) * (size_t)n);
    float* y = (float*)malloc(sizeof(float) * (size_t)n);
    double* ex = (double*)malloc(sizeof(double) * (size_t)n);
    double* ey = (double*)malloc(sizeof(double) * (size_t)n);
    CHECK(x != NULL && y != NULL && ex != NULL && ey != NULL);
    for (int i = 0; i < n; ++i) {
      x[i] = (float)((1.0 + 0.5 * sin(2.0 * 3.14159265358979 * 3.0 * i /
                                      do_sr)) *
                     do_tone(0, 110.0, i, 0.0));
    }
    do_envelope(x, ex);
    do_render_low(oct1, 0, 110.0, 0.5, 0, y);
    do_envelope(y, ey);
    const int band = do_envelope_lag(ex, ey);
    do_render_low(oct1, 0, 110.0, 0.5, 1, y);
    do_envelope(y, ey);
    const int vocoder = do_envelope_lag(ex, ey);
    printf("  %d Hz: the swell lags %d frames through the band, %d through "
           "the vocoder alone (latency %d)\n",
           do_sr, band, vocoder, LE_PV_LATENCY);
    CHECK(abs(band - vocoder) < do_sr / 1000);
    free(x);
    free(y);
    free(ex);
    free(ey);
  }
  do_sr = DO_SR;
}

static void run_dual_octaver_tests(void) {
  test_dual_octaver_low_band_matches_the_capture();
  test_dual_octaver_low_band_hands_back();
  test_dual_octaver_low_band_keeps_the_latency();
  test_dual_octaver_low_voice_skips_dc();
  test_dual_octaver_trims_at_96k();
  test_dual_octaver_mode_switch_does_not_sweep();
  test_dual_octaver_second_voice();
  test_dual_octaver_matches_the_capture();
}
