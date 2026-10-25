/* Smart Tune (#1480), against the #891 captures: s6pitch 0-22 (a 50-cent
 * staircase of 0.45 s sines from 440 to 880 Hz, 50 ms apart, after 0.5 s of
 * silence) and s5/8-11 (1 kHz bursts). Included by test_engine_core.c
 * after the Room reverb tests. */

#define ST_SR 48000
static int st_sr = ST_SR; /* the rate st_render runs at */

/* [n] frames of [in] through Smart Tune at [p], from a fresh state, as
 * fx_apply_chain runs it; returns the left output (malloc'd). The right
 * channel must match the left: the input is mono. */
static float* st_render(const float* p, const float* in, int n) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_SMART_TUNE, st_sr) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_SMART_TUNE;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  int same = 1;
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = in[i];
    float r = l;
    fx_apply_chain(fx, st_sr, st_sr, &l, &r, 1, types, params, NULL);
    same &= l == r;
    y[i] = l;
  }
  CHECK(same);
  le_fx_state_free_buffers(fx);
  free(fx);
  return y;
}

/* Smart Tune's settings: [speed] (0..1), the root (0 = C .. 11 = B), the
 * scale type (its position, 0..13) and the reference (0..1). */
static void st_params(float* p, float speed, int root, int type, float ref) {
  for (int q = 0; q < LE_FX_PARAMS; ++q) p[q] = 0.0f;
  p[0] = speed;
  p[1] = (float)root / 11.0f;
  p[2] = (float)type / 13.0f;
  p[3] = ref;
}

/* The frequency of [y] over [n] frames from [a], from its rising zero
 * crossings, interpolated to a fraction of a sample. */
static double st_freq(const float* y, int a, int n) {
  double first = -1.0, last = -1.0;
  int count = 0;
  for (int i = a + 1; i < a + n; ++i) {
    if (y[i - 1] < 0.0f && y[i] >= 0.0f) {
      const double t = (double)(i - 1) + y[i - 1] / (double)(y[i - 1] - y[i]);
      if (first < 0.0) first = t;
      last = t;
      ++count;
    }
  }
  if (count < 2) return 0.0;
  return (double)(count - 1) * (double)st_sr / (last - first);
}

static double st_cents(double hz) { return 1200.0 * log2(hz / 440.0); }

/* The s6pitch staircase: 25 sines, 0 to 1200 cents above 440 Hz in steps of
 * 50, each 0.45 s from 0.5 + 0.5 k s, at -12 dBFS. */
#define ST_STEPS 25
static float* st_staircase(int* frames) {
  const int n = (int)(13.0 * st_sr);
  float* x = (float*)calloc((size_t)n, sizeof(float));
  for (int k = 0; k < ST_STEPS; ++k) {
    const double hz = 440.0 * pow(2.0, 50.0 * k / 1200.0);
    const int a = (int)((0.5 + 0.5 * k) * st_sr);
    const int len = (int)(0.45 * st_sr);
    for (int i = 0; i < len; ++i) {
      x[a + i] = 0.2512f * (float)sin(2.0 * 3.14159265358979 * hz * i / st_sr);
    }
  }
  *frames = n;
  return x;
}

/* What each capture's steps land on, in semitones from A 440 (its steady
 * part, 0.25 to 0.43 s into the step), and the steps the comparison skips:
 * a step exactly between two notes of the scale, which the Looper X's
 * detector tips either way, and the few where its detector lands off the
 * scale (around 620 to 740 Hz; #1480, not modelled). */
typedef struct {
  int capture; /* its s6pitch number */
  int root;    /* 0 = C */
  int type;    /* the scale type's position */
  int note[ST_STEPS];
  int skip[ST_STEPS];
} st_case;

static const st_case ST_CASES[] = {
    {15, 0, 0, {0, 0, 2, 2, 2, 3, 3, 3, 5, 5, 5, 5, 7, 7, 7, 8, 8, 8, 10, 10, 10, 10, 12, 12, 12},
     {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0}}, /* Major (Unworried) */
    {1, 0, 1, {-1, 1, 1, 1, 1, 3, 3, 3, 5, 5, 5, 6, 6, 6, 6, 8, 8, 8, 9, 10, 10, 11, 11, 11, 12},
     {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1}}, /* Minor */
    {2, 0, 2, {-1, -1, 2, 2, 2, 2, 3, 3, 5, 5, 5, 6, 6, 6, 6, 6, 8, 9, 9, 9, 10, 11, 11, 11, 12},
     {0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1}}, /* Harm Min */
    {3, 0, 3, {0, 0, 2, 2, 2, 2, 3, 3, 5, 5, 5, 6, 6, 7, 6, 7, 8, 9, 9, 9, 10, 10, 12, 12, 12},
     {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 1, 0, 0}}, /* Melo Min */
    {4, 0, 4, {0, 1, 1, 1, 1, 3, 3, 3, 5, 5, 5, 6, 6, 7, 6, 7, 9, 8, 8, 10, 10, 10, 12, 12, 12},
     {0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 0}}, /* Dorian */
    {5, 0, 5, {-1, 1, 1, 1, 1, 3, 3, 3, 4, 4, 4, 6, 6, 6, 6, 8, 8, 8, 8, 10, 10, 10, 11, 11, 11},
     {1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1}}, /* Phrygian */
    {6, 0, 6, {0, 0, 2, 2, 2, 2, 3, 3, 5, 5, 5, 5, 5, 7, 7, 7, 9, 9, 9, 9, 10, 10, 12, 12, 12},
     {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0}}, /* Lydian */
    {7, 0, 7, {0, 0, 1, 1, 1, 3, 3, 3, 5, 5, 5, 5, 7, 7, 7, 7, 8, 8, 8, 10, 10, 10, 12, 12, 12},
     {0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0}}, /* Mixo */
    {8, 0, 8, {-1, 1, 1, 1, 1, 3, 3, 3, 4, 4, 4, 6, 6, 6, 6, 8, 8, 8, 8, 10, 10, 11, 11, 11, 11},
     {1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1}}, /* Locrian */
    {9, 0, 9, {0, 1, 1, 1, 2, 2, 3, 4, 4, 4, 5, 6, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12},
     {0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0}}, /* Chromatic */
    {10, 0, 10, {-1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 6, 6, 6, 5, 5, 8, 8, 8, 8, 10, 10, 10, 10, 10, 13},
     {1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}}, /* Penta */
    {11, 0, 11, {-2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 7, 7, 5, 7, 5, 7, 10, 10, 10, 10, 10, 10, 10, 10},
     {0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0}}, /* Maj Triad */
    {12, 9, 0, {0, 0, 2, 2, 2, 2, 4, 4, 4, 4, 5, 5, 6, 6, 7, 7, 9, 9, 9, 9, 9, 11, 11, 12, 12},
     {0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0}}, /* A Major */
};

/* Every captured scale: each step the comparison keeps lands on the
 * capture's note, within 3 cents (the Looper X lands within 8). */
static void test_smart_tune_scales_match_the_captures(void) {
  printf("test_smart_tune_scales_match_the_captures\n");
  int n = 0;
  float* x = st_staircase(&n);
  for (size_t c = 0; c < sizeof(ST_CASES) / sizeof(ST_CASES[0]); ++c) {
    const st_case* sc = &ST_CASES[c];
    float p[LE_FX_PARAMS];
    st_params(p, 0.5f, sc->root, sc->type, 0.5f);
    float* y = st_render(p, x, n);
    int kept = 0, landed = 0;
    double worst = 0.0;
    for (int k = 0; k < ST_STEPS; ++k) {
      if (sc->skip[k]) continue;
      ++kept;
      const int a = (int)((0.75 + 0.5 * k) * st_sr);
      const double off =
          st_cents(st_freq(y, a, (int)(0.18 * st_sr))) - 100.0 * sc->note[k];
      if (fabs(off) < 3.0) ++landed;
      if (fabs(off) > fabs(worst)) worst = off;
    }
    printf("  s6pitch %2d: %2d of %2d steps on the capture's note, worst "
           "%+.1f c\n",
           sc->capture, landed, kept, worst);
    CHECK(landed == kept);
    free(y);
  }
  free(x);
}

/* Min Triad and Root, off the Looper X's screen: their notes from their
 * names (root, minor third and fifth; the root alone). */
static void test_smart_tune_unmeasured_scales(void) {
  printf("test_smart_tune_unmeasured_scales\n");
  int n = 0;
  float* x = st_staircase(&n);
  /* C minor triad: C, Eb, G, 3, 6 and 10 semitones above A; C alone. */
  static const int triad[ST_STEPS] = {
      -2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 6, 6, 6, 6, 6, 6, 10, 10, 10, 10, 10,
      10, 10, 10, 10};
  float p[LE_FX_PARAMS];
  st_params(p, 0.5f, 0, 12, 0.5f);
  float* y = st_render(p, x, n);
  for (int k = 0; k < ST_STEPS; ++k) {
    if (k == 1 || k == 9 || k == 16) continue; /* between two notes */
    const int a = (int)((0.75 + 0.5 * k) * st_sr);
    const double c = st_cents(st_freq(y, a, (int)(0.18 * st_sr)));
    CHECK(fabs(c - 100.0 * triad[k]) < 3.0);
  }
  free(y);
  st_params(p, 0.5f, 0, 13, 0.5f);
  y = st_render(p, x, n);
  /* C, 300 cents above A 440, for the steps up to 300 cents from it: a
   * pure tone moved further reads at its own pitch, PSOLA keeping its one
   * harmonic where it was. */
  for (int k = 0; k <= 12; ++k) {
    const int a = (int)((0.75 + 0.5 * k) * st_sr);
    const double c = st_cents(st_freq(y, a, (int)(0.18 * st_sr)));
    CHECK(fabs(c - 300.0) < 3.0);
  }
  free(y);
  free(x);
}

/* The time from [y]'s pitch reaching half its way from [from] to [to] cents
 * to reaching 80 %, from [a] for [n] frames: ln 2.5 times an exponential
 * glide's time constant, in seconds (-1: it never gets there). The glide's
 * second half, as the start moves while the detection settles. Each
 * reading is one period, between rising zero crossings. */
static double st_glide(const float* y, int a, int n, double from, double to) {
  double t50 = -1.0, prev = -1.0;
  double ring[8] = {0.0};
  int seen = 0;
  for (int i = a + 1; i < a + n; ++i) {
    if (!(y[i - 1] < 0.0f && y[i] >= 0.0f)) continue;
    const double t = (double)(i - 1) + y[i - 1] / (double)(y[i - 1] - y[i]);
    if (prev >= 0.0) {
      /* The mean of the last eight periods' pitch: one period's reading
       * moves a few cents with the grains. */
      ring[seen++ % 8] = st_cents((double)st_sr / (t - prev));
      if (seen >= 8) {
        double c = 0.0;
        for (int k = 0; k < 8; ++k) c += ring[k] / 8.0;
        const double f = (c - from) / (to - from);
        const double at = t / st_sr;
        if (t50 < 0.0 && f >= 0.5) t50 = at;
        if (t50 >= 0.0 && f >= 0.8) return at - t50;
      }
    }
    prev = t;
  }
  return -1.0;
}

/* A [hz] tone at -12 dBFS for [seconds] after 0.1 s of silence. */
static float* st_tone(double hz, double seconds, int* frames) {
  const int n = (int)((0.1 + seconds) * st_sr);
  float* x = (float*)calloc((size_t)n, sizeof(float));
  for (int i = (int)(0.1 * st_sr); i < n; ++i) {
    x[i] = 0.2512f * (float)sin(2.0 * 3.14159265358979 * hz * i / st_sr);
  }
  *frames = n;
  return x;
}

/* Speed: the correction glides with a time constant of half the speed. The
 * captures read 17 ms at 32 ms (s6pitch 0), 78 ms at 179 ms (s6pitch 14)
 * and about 500 ms at 1000 ms (s5/10, where 1 kHz still sits 8.7 of its 21
 * cents from B5 0.45 s into its burst). Speed 1 ms lands at once (s5/9). */
static void test_smart_tune_speed(void) {
  printf("test_smart_tune_speed\n");
  /* 4.1 semitones above A 440, a C# 10 cents sharp: up to D in C major;
   * and 1 kHz, down to B5. */
  static const struct {
    float speed;
    double capture_s;
  } cases[] = {{0.5f, 0.017}, {0.75f, 0.078}, {1.0f, 0.5}};
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    const double hz = cases[c].speed < 1.0f ? 440.0 * pow(2.0, 4.1 / 12.0)
                                            : 1000.0;
    const double from = st_cents(hz);
    const double to = cases[c].speed < 1.0f ? 500.0 : 1400.0; /* D5, B5 */
    int n = 0;
    float* x = st_tone(hz, 2.5, &n);
    float p[LE_FX_PARAMS];
    st_params(p, cases[c].speed, 0, 0, 0.5f);
    float* y = st_render(p, x, n);
    /* From 40 ms into the tone: the output's onset reads no pitch. */
    const int a = (int)(0.14 * st_sr);
    const double tau = st_glide(y, a, n - a, from, to) / log(2.5);
    const double want = 0.0005 * pow(1000.0, cases[c].speed);
    printf("  speed %.0f %%: time constant %.1f ms (half the speed %.1f, "
           "capture %.0f)\n",
           100.0 * cases[c].speed, 1e3 * tau, 1e3 * want,
           1e3 * cases[c].capture_s);
    CHECK(fabs(tau - want) < 0.1 * want);
    free(y);
    free(x);
  }
  /* Speed 1 ms: on the note within 30 ms of the tone's start, as the
   * capture is in its first reading. */
  int n = 0;
  float* x = st_tone(1000.0, 0.5, &n);
  float p[LE_FX_PARAMS];
  st_params(p, 0.0f, 0, 0, 0.5f);
  float* y = st_render(p, x, n);
  const double c = st_cents(st_freq(y, (int)(0.16 * st_sr), st_sr / 50));
  printf("  speed 1 ms: %+.1f c from B5 60 ms in (capture -0.0)\n",
         c - 1400.0);
  CHECK(fabs(c - 1400.0) < 3.0);
  free(y);
  free(x);
}

/* Reference 460 Hz pulls 1 kHz to B5 at A = 460, 1032.7 Hz (s5/11 reads
 * 1032); the level stays the input's (s6pitch: -0.06 dB). */
static void test_smart_tune_reference_and_level(void) {
  printf("test_smart_tune_reference_and_level\n");
  int n = 0;
  float* x = st_tone(1000.0, 1.0, &n);
  float p[LE_FX_PARAMS];
  st_params(p, 0.5f, 0, 0, 1.0f);
  float* y = st_render(p, x, n);
  const int a = (int)(0.6 * st_sr), len = (int)(0.4 * st_sr);
  const double hz = st_freq(y, a, len);
  double si = 0.0, so = 0.0;
  for (int i = a; i < a + len; ++i) {
    si += (double)x[i] * x[i];
    so += (double)y[i] * y[i];
  }
  const double db = 10.0 * log10(so / si);
  printf("  reference 460: %.1f Hz (capture 1032), level %+.2f dB\n", hz, db);
  CHECK(fabs(hz - 987.767 * 460.0 / 440.0) < 1.0);
  CHECK(fabs(db) < 0.5);
  free(y);
  free(x);
}

/* A 220 Hz saw (s6pitch's, harmonic-rich): A3 is in C major, so it passes
 * at its own pitch; silence gives silence; and the kernel stays in step at
 * 96 kHz, where 1 kHz still goes to B5. */
static void test_smart_tune_saw_silence_and_96k(void) {
  printf("test_smart_tune_saw_silence_and_96k\n");
  const int n = st_sr;
  float* x = (float*)calloc((size_t)n, sizeof(float));
  for (int i = 0; i < n; ++i) {
    const double ph = fmod(220.0 * i / st_sr, 1.0);
    x[i] = 0.25f * (float)(2.0 * ph - 1.0);
  }
  float p[LE_FX_PARAMS];
  st_params(p, 0.5f, 0, 0, 0.5f);
  float* y = st_render(p, x, n);
  /* The fundamental's period from its zero crossings after a low-pass. */
  float* lp = (float*)calloc((size_t)n, sizeof(float));
  double z = 0.0;
  const double k = 1.0 - exp(-2.0 * 3.14159265358979 * 300.0 / st_sr);
  for (int i = 0; i < n; ++i) {
    z += k * (y[i] - z);
    lp[i] = (float)z;
  }
  const double c = st_cents(st_freq(lp, n / 2, n / 2));
  printf("  saw 220 Hz: %+.1f c from A3\n", c + 1200.0);
  CHECK(fabs(c + 1200.0) < 3.0);
  free(lp);
  free(y);
  free(x);
  float* s = (float*)calloc((size_t)n, sizeof(float));
  y = st_render(p, s, n);
  float peak = 0.0f;
  for (int i = 0; i < n; ++i) peak = fmaxf(peak, fabsf(y[i]));
  CHECK(peak == 0.0f);
  free(y);
  free(s);
  st_sr = 96000;
  int m = 0;
  float* t = st_tone(1000.0, 0.6, &m);
  y = st_render(p, t, m);
  const double b5 = st_cents(st_freq(y, (int)(0.4 * st_sr), (int)(0.2 * st_sr)));
  printf("  96 kHz: 1 kHz goes to %+.1f c from B5\n", b5 - 1400.0);
  CHECK(fabs(b5 - 1400.0) < 3.0);
  free(y);
  free(t);
  st_sr = ST_SR;
}

static void run_smart_tune_tests(void) {
  test_smart_tune_scales_match_the_captures();
  test_smart_tune_unmeasured_scales();
  test_smart_tune_speed();
  test_smart_tune_reference_and_level();
  test_smart_tune_saw_silence_and_96k();
}
