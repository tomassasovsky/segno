/* The Room reverb (#1476), against the #891 captures (s6rev, s8). Included
 * by test_engine_core.c after the reverb tests, whose helpers it reuses
 * (verb_t60, verb_energy, verb_first, verb_corr, dyn_run, dyn_state,
 * dyn_free). */

#define RV_SR 48000

/* The Room reverb's impulse response at [sr]: both sides, [n] frames, for
 * an impulse of 1 at frame 0, dry included. */
static verb_ir rv_run_at(const float* p, int n, int sr) {
  float* in = (float*)calloc((size_t)n, sizeof(float));
  verb_ir h = {(float*)calloc((size_t)n, sizeof(float)),
               (float*)calloc((size_t)n, sizeof(float)), n};
  in[0] = 1.0f;
  le_fx_state* fx = dyn_state(LE_FX_ROOM_VERB, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_ROOM_VERB, p, sr, in, h.l, h.r, n, &clock);
  dyn_free(fx);
  free(in);
  return h;
}

static verb_ir rv_run(const float* p, int n) { return rv_run_at(p, n, RV_SR); }

/* The settings: length, mix, room (of 16), bright, lo/hi, tail/ER,
 * density. */
static void rv_params(float* p, float length, float mix, int room,
                      float bright, float lo_hi, float tail_er,
                      float density) {
  memset(p, 0, sizeof(float) * LE_FX_PARAMS);
  p[0] = length;
  p[1] = mix;
  p[2] = (float)room / 15.0f;
  p[3] = bright;
  p[4] = lo_hi;
  p[5] = tail_er;
  p[6] = density;
}

/* Each mode against its own captures (s8std, Mix 100 %, Studio's Bright
 * 75 %), read the same way: the decay (a line through 20 ms energies over
 * the window), the wet energy (whole, and to 50 ms past the first arrival,
 * which is the room's measured taps and does not move with Length), the
 * first arrival on each side to the sample, and left and right
 * uncorrelated. */
static void test_room_verb_modes_match_the_captures(void) {
  printf("test_room_verb_modes_match_the_captures\n");
  static const char* const names[4] = {"HALL", "STADIUM", "ROOM", "BOX"};
  static const struct {
    int mode;
    float length;
    double from_s, to_s, t, e, early;
    int first_l, first_r;
  } c[] = {
      {0, 0.25f, 0.2, 0.8, 1.104, 0.5048, 0.1601, 29, 29},
      {0, 0.75f, 0.3, 2.5, 4.450, 0.8855, 0.1601, 29, 29},
      {1, 0.25f, 0.3, 0.9, 1.306, 0.4142, 0.2859, 3466, 3466},
      {1, 0.75f, 0.4, 2.6, 5.296, 0.5349, 0.2860, 3466, 3466},
      {2, 0.5f, 0.15, 0.7, 1.125, 0.4910, 0.4035, 1054, 1052},
      {2, 0.75f, 0.3, 1.6, 2.470, 0.5510, 0.4035, 1054, 1052},
      {3, 0.75f, 0.1, 0.6, 1.194, 0.4400, 0.3564, 736, 741},
      {3, 0.9f, 0.1, 1.5, 3.001, 0.6220, 0.3564, 736, 741},
  };
  for (size_t k = 0; k < sizeof(c) / sizeof(c[0]); ++k) {
    const int n = (int)((c[k].to_s + 1.0) * RV_SR);
    float p[LE_FX_PARAMS];
    rv_params(p, c[k].length, 1.0f, c[k].mode, 0.75f, 0.5f, 0.3f, 1.0f);
    verb_ir h = rv_run(p, n);
    CHECK(fabsf(h.l[0]) < 1e-6f); /* Mix 100 %: no dry */
    const double t = 0.5 * (verb_t60(h.l, RV_SR, c[k].from_s, c[k].to_s) +
                            verb_t60(h.r, RV_SR, c[k].from_s, c[k].to_s));
    const double e = 0.5 * (verb_energy(h.l, 1, n) + verb_energy(h.r, 1, n));
    const int to = c[k].first_l + RV_SR / 20;
    const double early =
        0.5 * (verb_energy(h.l, 1, to) + verb_energy(h.r, 1, to));
    const int fl = verb_first(h.l, n, 1);
    const int fr = verb_first(h.r, n, 1);
    const double corr = verb_corr(h.l, h.r, 100, RV_SR);
    printf("  %s Length %.2f: decay %.2f s (capture %.2f), energy %+.2f dB, "
           "early %+.2f dB, first %d / %d (capture %d / %d), L/R %.2f\n",
           names[c[k].mode], (double)c[k].length, t, c[k].t,
           10.0 * log10(e / c[k].e), 10.0 * log10(early / c[k].early), fl, fr,
           c[k].first_l, c[k].first_r, corr);
    CHECK(fabs(t - c[k].t) < 0.12 * c[k].t);
    CHECK(fabs(10.0 * log10(e / c[k].e)) < 1.2);
    CHECK(fabs(10.0 * log10(early / c[k].early)) < 0.5);
    CHECK(fl == c[k].first_l && fr == c[k].first_r);
    CHECK(fabs(corr) < 0.2);
    verb_free(h);
  }
}

/* The Drum Rack's LARGE STUDIO at its defaults' Tail/ER 30 % and Mix
 * 100 % (s6rev 11, 19), and each ER room alone (Tail/ER 100 %): the dry
 * and its immediate tap, the decay, the energies, and each room's first
 * arrivals and energy to 60 ms. */
static void test_room_verb_drum_matches_the_captures(void) {
  printf("test_room_verb_drum_matches_the_captures\n");
  static const struct {
    float length;
    double from_s, to_s, t, e, early;
  } d[2] = {{0.16f, 0.2, 0.8, 1.20, 0.1275, 0.1068},
            {0.5f, 0.3, 1.5, 2.57, 0.1394, 0.1075}};
  for (int k = 0; k < 2; ++k) {
    const int n = (int)((d[k].to_s + 1.0) * RV_SR);
    float p[LE_FX_PARAMS];
    rv_params(p, d[k].length, 1.0f, 11, 0.75f, 0.5f, 0.3f, 1.0f);
    verb_ir h = rv_run(p, n);
    /* The dry at 0.707 with the tail's immediate tap (capture 0.6801). */
    CHECK(fabsf(h.l[0] - 0.6801f) < 0.002f);
    h.l[0] = h.r[0] = 0.0f;
    const double t = 0.5 * (verb_t60(h.l, RV_SR, d[k].from_s, d[k].to_s) +
                            verb_t60(h.r, RV_SR, d[k].from_s, d[k].to_s));
    const double e = 0.5 * (verb_energy(h.l, 1, n) + verb_energy(h.r, 1, n));
    const int to = RV_SR / 20;
    const double early =
        0.5 * (verb_energy(h.l, 1, to) + verb_energy(h.r, 1, to));
    printf("  LARGE STUDIO Length %.2f: decay %.2f s (capture %.2f), energy "
           "%+.2f dB, early %+.2f dB\n",
           (double)d[k].length, t, d[k].t, 10.0 * log10(e / d[k].e),
           10.0 * log10(early / d[k].early));
    CHECK(fabs(t - d[k].t) < 0.12 * d[k].t);
    CHECK(fabs(10.0 * log10(e / d[k].e)) < 1.0);
    CHECK(fabs(10.0 * log10(early / d[k].early)) < 0.5);
    verb_free(h);
  }
  static const struct {
    double e60;
    int first_l, first_r;
  } er[12] = {{0.08893, 560, 495},  {0.09415, 736, 741},
              {0.08872, 565, 588},  {0.08308, 1059, 1254},
              {0.09491, 967, 928},  {0.14308, 1022, 926},
              {0.12829, 585, 657},  {0.12383, 1180, 1179},
              {0.11174, 1137, 1105}, {0.10046, 830, 909},
              {0.09927, 1431, 1363}, {0.06839, 1299, 1407}};
  for (int r = 0; r < 12; ++r) {
    const int n = RV_SR / 10;
    float p[LE_FX_PARAMS];
    rv_params(p, 0.16f, 1.0f, 4 + r, 0.75f, 0.5f, 1.0f, 1.0f);
    verb_ir h = rv_run(p, n);
    h.l[0] = h.r[0] = 0.0f;
    const int to = 6 * RV_SR / 100;
    const double e60 =
        0.5 * (verb_energy(h.l, 1, to) + verb_energy(h.r, 1, to));
    const int fl = verb_first(h.l, n, 1);
    const int fr = verb_first(h.r, n, 1);
    printf("  ER room %d alone: to 60 ms %+.2f dB, first %d / %d (capture "
           "%d / %d)\n",
           r, 10.0 * log10(e60 / er[r].e60), fl, fr, er[r].first_l,
           er[r].first_r);
    CHECK(fabs(10.0 * log10(e60 / er[r].e60)) < 0.3);
    CHECK(abs(fl - er[r].first_l) <= 1 && abs(fr - er[r].first_r) <= 1);
    verb_free(h);
  }
}

/* Mix is equal-power over a half turn on the modes and a quarter on the
 * Drum's rooms (dry 0.707 at 100 %, as captured); Tail/ER is equal-power
 * over a quarter turn: the tail's immediate tap falls as sin, the ER's
 * strongest tap rises as cos (s6rev, s8drm 16-20). */
static void test_room_verb_mix_and_tail_er_laws(void) {
  printf("test_room_verb_mix_and_tail_er_laws\n");
  const double pi = 3.14159265358979323846;
  const float mixes[3] = {0.0f, 0.5f, 1.0f};
  for (int k = 0; k < 3; ++k) {
    float p[LE_FX_PARAMS];
    rv_params(p, 0.4f, mixes[k], 0, 0.8f, 0.5f, 0.3f, 1.0f);
    verb_ir h = rv_run(p, 64);
    CHECK(fabs(h.l[0] - cos(mixes[k] * 0.5 * pi)) < 1e-4);
    verb_free(h);
    /* The Drum's: at Tail/ER 100 % nothing of the tail sits on the dry. */
    rv_params(p, 0.16f, mixes[k], 11, 0.8f, 0.5f, 1.0f, 1.0f);
    verb_ir er = rv_run(p, 64);
    CHECK(fabs(er.l[0] - cos(mixes[k] * 0.25 * pi)) < 1e-4);
    verb_free(er);
  }
  const float tes[4] = {0.0f, 0.3f, 0.7f, 1.0f};
  const int er_tap = 1574; /* LARGE STUDIO's strongest early tap, left */
  float imm1 = 0.0f, er1 = 0.0f;
  for (int k = 3; k >= 0; --k) {
    float p[LE_FX_PARAMS];
    rv_params(p, 0.16f, 1.0f, 11, 0.8f, 0.5f, tes[k], 1.0f);
    verb_ir h = rv_run(p, 2048);
    const float imm = h.l[1];
    const float tap = h.l[er_tap];
    if (k == 3) {
      er1 = tap;
      CHECK(fabsf(imm) < 1e-6f); /* no tail at 100 % */
    } else {
      const double th = (1.0 - tes[k]) * 0.25 * pi;
      if (k == 0) imm1 = imm;
      CHECK(fabs(tap / er1 - cos(th)) < 0.01);
      if (imm1 != 0.0f) {
        CHECK(fabs(imm / imm1 - sin(th) / sin(0.25 * pi)) < 0.01);
      }
    }
    verb_free(h);
  }
}

/* Bright sets the wet's low-pass (Ed's HALL, s6rev 38, 42-44): the 8 kHz
 * octave against 1 kHz moves from 80 %'s as captured, -14.0, -4.8 and
 * +1.6 dB at 0, 50 and 100 %. Lo/Hi
 * at 100 % cuts the lows: 31.5 Hz 12.4 dB under the 50 % setting, as
 * captured (s6rev 13 against 11), and at 75 % next to nothing. */
static double rv_band_db(const verb_ir* h, double hz, double width) {
  const int n = 1 << 17;
  double acc = 0.0;
  int cnt = 0;
  for (double f = hz / width; f <= hz * width; f += hz / 40.0) {
    double re = 0.0, im = 0.0;
    for (int i = 0; i < n && i < h->n; ++i) {
      const double w = 2.0 * 3.14159265358979 * f * i / RV_SR;
      const double x = 0.5 * ((double)h->l[i] + (double)h->r[i]);
      re += x * cos(w);
      im -= x * sin(w);
    }
    acc += re * re + im * im;
    cnt++;
  }
  return 10.0 * log10(acc / cnt + 1e-30);
}

static void test_room_verb_bright_and_lo_hi(void) {
  printf("test_room_verb_bright_and_lo_hi\n");
  const float brights[4] = {0.8f, 0.0f, 0.5f, 1.0f};
  const double want[4] = {0.0, -14.0, -4.8, 1.6};
  double at80 = 0.0;
  for (int k = 0; k < 4; ++k) {
    float p[LE_FX_PARAMS];
    rv_params(p, 0.37f, 1.0f, 0, brights[k], 0.5f, 0.3f, 1.0f);
    verb_ir h = rv_run(p, RV_SR);
    const double tilt =
        rv_band_db(&h, 8000.0, 1.41) - rv_band_db(&h, 1000.0, 1.41);
    if (k == 0) at80 = tilt;
    printf("  Bright %.0f %%: 8 kHz against 1 kHz %+.1f dB from 80 %%'s "
           "(capture %+.1f)\n",
           100.0 * brights[k], tilt - at80, want[k]);
    CHECK(fabs(tilt - at80 - want[k]) < 1.0);
    verb_free(h);
  }
  float p[LE_FX_PARAMS];
  rv_params(p, 0.16f, 1.0f, 11, 0.8f, 0.5f, 0.3f, 1.0f);
  verb_ir mid = rv_run(p, RV_SR);
  rv_params(p, 0.16f, 1.0f, 11, 0.8f, 1.0f, 0.3f, 1.0f);
  verb_ir top = rv_run(p, RV_SR);
  rv_params(p, 0.16f, 1.0f, 11, 0.8f, 0.75f, 0.3f, 1.0f);
  verb_ir high = rv_run(p, RV_SR);
  /* Take the dry (0.707 at Mix 100 %) out of the first sample, keeping the
   * wet's own first sample: the cut's lows are small enough for it to
   * matter. */
  const float dry = 0.70710678f;
  mid.l[0] -= dry;
  mid.r[0] -= dry;
  top.l[0] -= dry;
  top.r[0] -= dry;
  high.l[0] -= dry;
  high.r[0] -= dry;
  const double cut =
      rv_band_db(&top, 31.5, 1.12) - rv_band_db(&mid, 31.5, 1.12) -
      (rv_band_db(&top, 1000.0, 1.12) - rv_band_db(&mid, 1000.0, 1.12));
  const double cut75 =
      rv_band_db(&high, 31.5, 1.12) - rv_band_db(&mid, 31.5, 1.12) -
      (rv_band_db(&high, 1000.0, 1.12) - rv_band_db(&mid, 1000.0, 1.12));
  printf("  Lo/Hi 100 %%: 31.5 Hz %+.1f dB (capture -12.4); 75 %%: %+.1f dB\n",
         cut, cut75);
  CHECK(fabs(cut + 12.4) < 1.5);
  CHECK(fabs(cut75) < 1.0);
  verb_free(mid);
  verb_free(top);
  verb_free(high);
}

/* Density scales the network's three diffusers (s8drm 12-15): the
 * immediate tap goes as Density cubed, 0.017, 0.127 and 0.42 of its full
 * value at 25, 50 and 75 %, and none at 0. */
static void test_room_verb_density(void) {
  printf("test_room_verb_density\n");
  const float ds[5] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  const double want[5] = {0.0, 0.017, 0.127, 0.42, 1.0};
  float full = 0.0f;
  for (int k = 4; k >= 0; --k) {
    float p[LE_FX_PARAMS];
    rv_params(p, 0.16f, 1.0f, 11, 0.8f, 0.5f, 0.0f, ds[k]);
    verb_ir h = rv_run(p, 64);
    const float imm = h.l[1];
    if (k == 4) full = imm;
    printf("  Density %.0f %%: immediate tap %.3f of full (capture %.3f)\n",
           100.0 * ds[k], (double)(imm / full), want[k]);
    CHECK(fabs(imm / full - want[k]) < 0.02);
    verb_free(h);
  }
}

/* A room change dips the wet and lays the new room out: nothing steps,
 * and the new room's taps sound after. Settings that glide (Length, Bright,
 * Density) never step either. */
static void test_room_verb_changes_are_smooth(void) {
  printf("test_room_verb_changes_are_smooth\n");
  const int n = 2 * RV_SR;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    in[i] = 0.25f * sinf(2.0f * 3.14159265f * 200.0f * (float)i / RV_SR);
  }
  static const struct {
    int param;
    float from, to;
  } c[4] = {{2, 0.0f, 3.0f / 15.0f},
            {0, 0.2f, 0.8f},
            {3, 0.0f, 1.0f},
            {6, 1.0f, 0.0f}};
  for (int k = 0; k < 4; ++k) {
    float a[LE_FX_PARAMS], b[LE_FX_PARAMS];
    rv_params(a, 0.3f, 0.5f, k == 3 ? 11 : 0, 0.8f, 0.5f, 0.3f, 1.0f);
    a[c[k].param] = c[k].from;
    memcpy(b, a, sizeof b);
    b[c[k].param] = c[k].to;
    le_fx_state* fx = dyn_state(LE_FX_ROOM_VERB, RV_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_ROOM_VERB, a, RV_SR, in, out, NULL, RV_SR, &clock);
    dyn_run(fx, LE_FX_ROOM_VERB, b, RV_SR, in + RV_SR, out + RV_SR, NULL,
            RV_SR, &clock);
    dyn_free(fx);
    float worst = 0.0f, steady = 0.0f;
    for (int i = RV_SR - RV_SR / 5; i < n; ++i) {
      const float bend = fabsf(out[i] - 2.0f * out[i - 1] + out[i - 2]);
      CHECK(isfinite(out[i]));
      if (i >= RV_SR && i < RV_SR + RV_SR / 5) {
        worst = fmaxf(worst, bend);
      } else if (i < RV_SR || i >= n - RV_SR / 5) {
        steady = fmaxf(steady, bend);
      }
    }
    printf("  param %d: largest bend %.5f (steady %.5f)\n", c[k].param,
           (double)worst, (double)steady);
    /* A room change fades over the smoothing time, whose start bends the
     * output as any glide's does; the others never bend it past twice the
     * steady sound's. */
    CHECK(worst < (c[k].param == 2 ? 3.0f : 2.0f) * steady);
  }
  free(in);
  free(out);
}

/* At 96 kHz each room keeps its 48 kHz decay and band levels: the taps sit
 * at the same times, the low-pass at the same corner. */
static void test_room_verb_at_96k(void) {
  printf("test_room_verb_at_96k\n");
  const int rooms[3] = {0, 3, 11};
  for (int k = 0; k < 3; ++k) {
    float p[LE_FX_PARAMS];
    rv_params(p, 0.5f, 1.0f, rooms[k], 0.75f, 0.5f, 0.3f, 1.0f);
    verb_ir a = rv_run_at(p, 3 * RV_SR, RV_SR);
    verb_ir b = rv_run_at(p, 6 * RV_SR, 2 * RV_SR);
    a.l[0] = a.r[0] = b.l[0] = b.r[0] = 0.0f;
    const double ta = 0.5 * (verb_t60(a.l, RV_SR, 0.2, 1.2) +
                             verb_t60(a.r, RV_SR, 0.2, 1.2));
    const double tb = 0.5 * (verb_t60(b.l, 2 * RV_SR, 0.2, 1.2) +
                             verb_t60(b.r, 2 * RV_SR, 0.2, 1.2));
    const int fa = verb_first(a.l, a.n, 1);
    const int fb = verb_first(b.l, b.n, 1);
    printf("  room %d: decay %.2f s at 96 kHz, %.2f at 48; first %d / %d\n",
           rooms[k], tb, ta, fb, fa);
    CHECK(fabs(tb - ta) < 0.08 * ta);
    CHECK(abs(fb - 2 * fa) <= 2);
    verb_free(a);
    verb_free(b);
  }
}

/* With noise in at the longest Length it stays finite and bounded; rings
 * full of old audio and silence in give silence out. */
static void test_room_verb_stable_and_clean(void) {
  printf("test_room_verb_stable_and_clean\n");
  for (int room = 0; room < 16; room += 5) {
    const int n = 12 * RV_SR;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* out = (float*)calloc((size_t)n, sizeof(float));
    uint32_t seed = 12345u;
    for (int i = 0; i < RV_SR; ++i) {
      seed = seed * 1664525u + 1013904223u;
      in[i] = 0.5f * ((float)(seed >> 8) / 8388608.0f - 1.0f);
    }
    float p[LE_FX_PARAMS];
    rv_params(p, 1.0f, 1.0f, room, 1.0f, 1.0f, 0.0f, 1.0f);
    le_fx_state* fx = dyn_state(LE_FX_ROOM_VERB, RV_SR);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_ROOM_VERB, p, RV_SR, in, out, NULL, n, &clock);
    dyn_free(fx);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) {
      CHECK(isfinite(out[i]));
      peak = fmaxf(peak, fabsf(out[i]));
    }
    CHECK(peak < 4.0f);
    /* Stale rings */
    fx = dyn_state(LE_FX_ROOM_VERB, RV_SR);
    for (int c = 0; c < 2; ++c) {
      for (int i = 0; i < RV_SR; ++i) fx->delay[0][c][i] = 0.5f;
    }
    memset(in, 0, sizeof(float) * (size_t)n);
    clock = 0;
    dyn_run(fx, LE_FX_ROOM_VERB, p, RV_SR, in, out, NULL, 2 * RV_SR, &clock);
    dyn_free(fx);
    int loud = 0;
    for (int i = 0; i < 2 * RV_SR; ++i) loud += out[i] != 0.0f;
    CHECK(loud == 0);
    free(in);
    free(out);
  }
}

static void run_room_verb_tests(void) {
  test_room_verb_modes_match_the_captures();
  test_room_verb_drum_matches_the_captures();
  test_room_verb_mix_and_tail_er_laws();
  test_room_verb_bright_and_lo_hi();
  test_room_verb_density();
  test_room_verb_changes_are_smooth();
  test_room_verb_at_96k();
  test_room_verb_stable_and_clean();
}
