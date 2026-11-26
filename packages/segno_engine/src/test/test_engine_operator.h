/* SEG-109: the Operator device. Its own module first (operator_voice.c,
 * driven directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_drift.h (drift_run, the ins_*
 * helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the instrument
 * tests. */

#include "operator_voice.h"

/* Slot k's Operator instance in engine e. */
static le_operator* eng_op(le_engine* e, int32_t k) {
  return (le_operator*)le_instruments_device(e, LE_INST_DEVICE_OPERATOR, k);
}

#define OPR_SR 48000

static le_operator g_opr;

static void opr_init(le_operator* d) {
  CHECK(le_operator_init(d, OPR_SR) == 0);
  le_operator_set_voice_limit(d, LE_OPERATOR_VOICE_SLOTS);
}

/* Sets one parameter, the others as they are. */
static void opr_set(le_operator* d, int32_t p, float v) {
  static float vals[LE_OPERATOR_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_operator_set_values(d, vals);
}

static void opr_op(le_operator* d, int32_t op, int32_t field, float v) {
  opr_set(d, LE_OPERATOR_OP(op, field), v);
}

/* A reference patch: operator A alone, a sine at 0 dB held at full level,
 * filter off, Tone open, no antialiasing. */
static void opr_reference(le_operator* d) {
  opr_init(d);
  opr_set(d, LE_OPERATOR_TONE, 1.0f);
  opr_set(d, LE_OPERATOR_ANTIALIAS, 0.0f);
  opr_set(d, LE_OPERATOR_RETRIGGER_MODE, 0.0f);
}

static float opr_peak(const float* x, int32_t n) {
  float p = 0.0f;
  for (int32_t i = 0; i < n; ++i) p = fabsf(x[i]) > p ? fabsf(x[i]) : p;
  return p;
}

static int opr_finite(const float* x, int32_t n) {
  for (int32_t i = 0; i < n; ++i) {
    if (!isfinite(x[i])) return 0;
  }
  return 1;
}

/* The magnitude of x's component at `hz` (a single-bin DFT, Hann
 * windowed), as a sine's amplitude. */
static double opr_component(const float* x, int32_t n, double hz) {
  double re = 0.0, im = 0.0, wsum = 0.0;
  for (int32_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (n - 1));
    re += w * x[i] * cos(2.0 * M_PI * hz * i / OPR_SR);
    im += w * x[i] * sin(2.0 * M_PI * hz * i / OPR_SR);
    wsum += w;
  }
  return 2.0 * sqrt(re * re + im * im) / wsum;
}

static double opr_note_hz(int32_t note) { return 440.0 * pow(2.0, (note - 69) / 12.0); }

/* One sine carrier at 0 dB with the global volume at 0 dB peaks at 1.0 on
 * each channel at centre pan; both volumes are linear gains. */
static void test_operator_sine_level(void) {
  printf("test_operator_sine_level\n");
  enum { N = 9600 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 1.0f) < 0.01f);
  CHECK(memcmp(l, r, sizeof(l)) == 0);
  CHECK(fabs(opr_component(l + N / 2, N / 2, opr_note_hz(60)) - 1.0) < 0.02);
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_VOLUME, 0.5f);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_VOLUME, 0.5f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 0.25f) < 0.005f);
}

/* Every waveform and every algorithm, all four operators on, renders
 * finite, audible and bounded, antialiased or not. */
static void test_operator_every_wave_and_algorithm(void) {
  printf("test_operator_every_wave_and_algorithm\n");
  enum { N = 4800 };
  static float l[N], r[N];
  for (int32_t aa = 0; aa < 2; ++aa) {
    for (int32_t w = 0; w < 23; ++w) {
      opr_reference(&g_opr);
      opr_set(&g_opr, LE_OPERATOR_ANTIALIAS, (float)aa);
      opr_op(&g_opr, 0, LE_OPERATOR_OP_WAVE, (float)w);
      CHECK(le_operator_note_on(&g_opr, 1, 84, 127, 0) == 0);
      le_operator_render(&g_opr, l, r, N);
      CHECK(opr_finite(l, N));
      CHECK(opr_peak(l, N) > 0.3f && opr_peak(l, N) < 2.0f);
    }
    for (int32_t alg = 0; alg < 11; ++alg) {
      opr_reference(&g_opr);
      opr_set(&g_opr, LE_OPERATOR_ANTIALIAS, (float)aa);
      opr_set(&g_opr, LE_OPERATOR_ALGORITHM, (float)alg);
      for (int32_t op = 1; op < 4; ++op) {
        opr_op(&g_opr, op, LE_OPERATOR_OP_ON, 1.0f);
        opr_op(&g_opr, op, LE_OPERATOR_OP_COARSE, (float)(op + 1));
        opr_op(&g_opr, op, LE_OPERATOR_OP_VOLUME, 0.5f);
        opr_op(&g_opr, op, LE_OPERATOR_OP_FEEDBACK, 50.0f);
      }
      CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
      le_operator_render(&g_opr, l, r, N);
      CHECK(opr_finite(l, N));
      CHECK(opr_peak(l, N) > 0.3f && opr_peak(l, N) < 4.0f);
    }
  }
}

/* A modulator's output phase-modulates its carrier by 2 cycles per unit,
 * below the Tone cutoff: carrier ratio 8, modulator ratio 1 at volume 0.1
 * gives index 4 pi x 0.1, and the first sideband stands at J1/J0 of it. */
static void test_operator_fm_depth(void) {
  printf("test_operator_fm_depth\n");
  enum { N = 24000 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_COARSE, 8.0f);
  opr_op(&g_opr, 1, LE_OPERATOR_OP_ON, 1.0f);
  opr_op(&g_opr, 1, LE_OPERATOR_OP_VOLUME, 0.1f);
  CHECK(le_operator_note_on(&g_opr, 1, 36, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  const double f = opr_note_hz(36);
  const double c = opr_component(l + 4800, N - 4800, 8.0 * f);
  const double s1 = opr_component(l + 4800, N - 4800, 9.0 * f);
  const double idx = 4.0 * M_PI * 0.1;
  /* J0 and J1 by their series */
  double j0 = 0.0, j1 = 0.0, term0 = 1.0, term1 = idx / 2.0;
  for (int k = 0; k < 20; ++k) {
    j0 += term0;
    j1 += term1;
    term0 *= -(idx * idx / 4.0) / ((k + 1.0) * (k + 1.0));
    term1 *= -(idx * idx / 4.0) / ((k + 1.0) * (k + 2.0));
  }
  CHECK(fabs(c - j0) < 0.02);
  CHECK(fabs(s1 - j1) < 0.02);
}

/* Feedback acts only on operators nothing modulates: in algorithm 0, A's
 * feedback changes nothing, D's does; in algorithm 10, A's does. */
static void test_operator_feedback_only_on_unmodulated(void) {
  printf("test_operator_feedback_only_on_unmodulated\n");
  enum { N = 4800 };
  static float a[N], b[N], r[N];
  opr_reference(&g_opr);
  CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
  le_operator_render(&g_opr, a, r, N);
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_FEEDBACK, 100.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
  le_operator_render(&g_opr, b, r, N);
  CHECK(memcmp(a, b, sizeof(a)) == 0);
  opr_set(&g_opr, LE_OPERATOR_ALGORITHM, 10.0f);
  le_operator_cut(&g_opr);
  le_operator_render(&g_opr, b, r, N);
  CHECK(le_operator_note_on(&g_opr, 2, 48, 127, 0) == 0);
  le_operator_render(&g_opr, b, r, N);
  CHECK(opr_component(b + N / 2, N / 2, 2.0 * opr_note_hz(48)) > 0.05);
}

/* Slope 0 is linear, slope 1 a one-pole that lands on its target as its
 * time runs out; any other slope holds the start and jumps at the end (as
 * Live 12.2.7 renders). */
static void test_operator_envelope_slopes(void) {
  printf("test_operator_envelope_slopes\n");
  enum { N = 48000 };
  static float l[N], r[N];
  const int32_t at = LE_OPERATOR_OP(0, LE_OPERATOR_OP_ENV + LE_OPERATOR_ENV_ATTACK_TIME);
  const int32_t as = LE_OPERATOR_OP(0, LE_OPERATOR_OP_ENV + LE_OPERATOR_ENV_ATTACK_SLOPE);
  const float slopes[3] = {0.0f, 1.0f, 0.5f};
  for (int k = 0; k < 3; ++k) {
    opr_reference(&g_opr);
    opr_set(&g_opr, at, 500.0f);
    opr_set(&g_opr, as, slopes[k]);
    CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
    le_operator_render(&g_opr, l, r, N);
    /* the level a quarter of the way in, and after the attack */
    const float q = opr_peak(l + 6000 - 200, 400);
    const float end = opr_peak(l + 30000, 2000);
    CHECK(fabsf(end - 1.0f) < 0.01f);
    if (k == 0) CHECK(fabsf(q - 0.25f) < 0.02f);
    if (k == 1) CHECK(q > 0.85f && q < 0.95f); /* 1 - e^(-9.7 x 0.25) */
    if (k == 2) CHECK(q < 0.001f);
  }
}

/* Spread plays each note twice, 0.1 x Spread semitones apart, one voice on
 * each channel at a single voice's level. */
static void test_operator_spread_pair(void) {
  printf("test_operator_spread_pair\n");
  enum { N = 48000 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_SPREAD, 100.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_active(&g_opr) == 2);
  le_operator_render(&g_opr, l, r, N);
  const double f = opr_note_hz(60);
  CHECK(fabs(opr_component(l + 4800, N - 4800, f * pow(2.0, -0.1 / 12.0)) - 1.0) < 0.05);
  CHECK(fabs(opr_component(r + 4800, N - 4800, f * pow(2.0, 0.1 / 12.0)) - 1.0) < 0.05);
  CHECK(opr_component(l + 4800, N - 4800, f * pow(2.0, 0.1 / 12.0)) < 0.2);
}

/* Voices: a count of 1 plays one note at a time; Retrigger Mode gives a
 * repeated note its own voice back; beyond the count the oldest released
 * note goes first. */
static void test_operator_voices(void) {
  printf("test_operator_voices\n");
  enum { N = 960 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_VOICES, 0.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_note_on(&g_opr, 2, 64, 127, 0) == 0);
  CHECK(le_operator_active(&g_opr) == 1);
  le_operator_render(&g_opr, l, r, N);
  CHECK(le_operator_fading(&g_opr) == 0);
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_VOICES, 1.0f); /* 2 */
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_note_on(&g_opr, 2, 64, 127, 0) == 0);
  le_operator_note_off(&g_opr, 1);
  CHECK(le_operator_note_on(&g_opr, 3, 67, 127, 0) == 0);
  CHECK(le_operator_active(&g_opr) == 2);
  CHECK(le_operator_held(&g_opr, 2) && le_operator_held(&g_opr, 3));
  opr_set(&g_opr, LE_OPERATOR_RETRIGGER_MODE, 1.0f);
  le_operator_note_off(&g_opr, 3);
  CHECK(le_operator_note_on(&g_opr, 4, 67, 127, 0) == 0);
  CHECK(le_operator_active(&g_opr) == 2);
  CHECK(le_operator_held(&g_opr, 2) && le_operator_held(&g_opr, 4));
}

/* The render is the same at any block size. */
static void test_operator_block_size_invariant(void) {
  printf("test_operator_block_size_invariant\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    opr_reference(&g_opr);
    opr_set(&g_opr, LE_OPERATOR_ALGORITHM, 1.0f);
    opr_set(&g_opr, LE_OPERATOR_LFO_ON, 1.0f);
    opr_op(&g_opr, 0, LE_OPERATOR_OP_LFO_ON, 1.0f);
    opr_set(&g_opr, LE_OPERATOR_LFO_AMOUNT, 0.2f);
    opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
    opr_set(&g_opr, LE_OPERATOR_FILTER_FREQ, 2000.0f);
    opr_set(&g_opr, LE_OPERATOR_FILTER_RES, 0.5f);
    opr_set(&g_opr, LE_OPERATOR_SHAPER_TYPE, 1.0f);
    opr_op(&g_opr, 1, LE_OPERATOR_OP_ON, 1.0f);
    opr_op(&g_opr, 1, LE_OPERATOR_OP_VOLUME, 0.4f);
    CHECK(le_operator_note_on(&g_opr, 1, 55, 100, 0) == 0);
    float* ol = b < 0 ? ref_l : l;
    float* orr = b < 0 ? ref_r : r;
    const int32_t blk = b < 0 ? N : blocks[b];
    for (int32_t done = 0; done < N; done += blk) {
      const int32_t n = N - done < blk ? N - done : blk;
      le_operator_render(&g_opr, ol + done, orr + done, n);
    }
    if (b >= 0) {
      CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
      CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    }
  }
}

/* Routes: velocity at 127 through -50 % to Volume halves the level, and at
 * velocity 64 takes off a quarter; a positive amount takes it off at low
 * velocities instead. */
static void test_operator_velocity_route(void) {
  printf("test_operator_velocity_route\n");
  enum { N = 4800 };
  static float l[N], r[N];
  const float amounts[3] = {-50.0f, -50.0f, 50.0f};
  const int32_t vels[3] = {127, 64, 64};
  const float want[3] = {0.5f, 0.75f, 0.75f};
  for (int k = 0; k < 3; ++k) {
    opr_reference(&g_opr);
    opr_set(&g_opr, LE_OPERATOR_ROUTE, 20.0f); /* velocity, route 0: Volume */
    opr_set(&g_opr, LE_OPERATOR_ROUTE + 1, amounts[k]);
    CHECK(le_operator_note_on(&g_opr, 1, 60, vels[k], 0) == 0);
    le_operator_render(&g_opr, l, r, N);
    CHECK(fabsf(opr_peak(l + N / 2, N / 2) - want[k]) < 0.01f);
  }
}

/* A user wave of the second harmonic alone plays an octave up, and is
 * rebuilt when its harmonics change. */
static void test_operator_user_wave(void) {
  printf("test_operator_user_wave\n");
  enum { N = 9600 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_WAVE, 22.0f);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_USER_HARMONIC, 0.0f);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_USER_HARMONIC + 1, 1.0f);
  le_operator_render(&g_opr, l, r, 64); /* rebuilds the wave */
  CHECK(g_opr.user_dirty == 0);
  CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  const double f = opr_note_hz(48);
  CHECK(opr_component(l + N / 2, N / 2, 2.0 * f) > 0.95);
  CHECK(opr_component(l + N / 2, N / 2, f) < 0.01);
}

/* The filter: a Clean low-pass well below a saw's harmonics takes them
 * off; with the filter off the shaper is bypassed too. */
static void test_operator_filter_and_shaper(void) {
  printf("test_operator_filter_and_shaper\n");
  enum { N = 9600 };
  static float l[N], r[N], dry[N];
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_WAVE, 9.0f); /* Saw 64 */
  CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
  le_operator_render(&g_opr, dry, r, N);
  const double f = opr_note_hz(48);
  opr_set(&g_opr, LE_OPERATOR_SHAPER_TYPE, 2.0f); /* Hard, filter off: no effect */
  le_operator_cut(&g_opr);
  le_operator_render(&g_opr, l, r, N);
  CHECK(le_operator_note_on(&g_opr, 2, 48, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(fabs(opr_component(l + N / 2, N / 2, 8.0 * f) -
             opr_component(dry + N / 2, N / 2, 8.0 * f)) < 0.002);
  opr_set(&g_opr, LE_OPERATOR_SHAPER_TYPE, 0.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_FREQ, 300.0f);
  le_operator_cut(&g_opr);
  le_operator_render(&g_opr, l, r, N);
  CHECK(le_operator_note_on(&g_opr, 3, 48, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  /* 12 dB an octave from 300 Hz, Q 0.5: the eighth harmonic (1046 Hz) at
   * about (300 / 1046)^2, the fundamental (131 Hz) at about 0.84 */
  const double h8 = opr_component(l + N / 2, N / 2, 8.0 * f) /
                    opr_component(dry + N / 2, N / 2, 8.0 * f);
  const double h1 = opr_component(l + N / 2, N / 2, f) / opr_component(dry + N / 2, N / 2, f);
  CHECK(h8 > 0.06 && h8 < 0.1);
  CHECK(h1 > 0.78 && h1 < 0.9);
}

/* Every circuit, type and slope, at full resonance and drive, stays finite
 * and bounded, and passes a saw; MS2 and PRD resonate at their cutoff. */
static void test_operator_circuits_bounded(void) {
  printf("test_operator_circuits_bounded\n");
  enum { N = 24000 };
  static float l[N], r[N];
  for (int32_t circuit = 0; circuit < 5; ++circuit) {
    for (int32_t type = 0; type < 5; ++type) {
      for (int32_t slope = 0; slope < 2; ++slope) {
        opr_reference(&g_opr);
        opr_op(&g_opr, 0, LE_OPERATOR_OP_WAVE, 9.0f);
        opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
        opr_set(&g_opr, LE_OPERATOR_FILTER_TYPE, (float)type);
        opr_set(&g_opr, LE_OPERATOR_FILTER_CIRCUIT_LPHP, (float)circuit);
        opr_set(&g_opr, LE_OPERATOR_FILTER_CIRCUIT_BPNOMO, (float)(circuit == 1));
        opr_set(&g_opr, LE_OPERATOR_FILTER_SLOPE, (float)slope);
        opr_set(&g_opr, LE_OPERATOR_FILTER_FREQ, 800.0f);
        opr_set(&g_opr, LE_OPERATOR_FILTER_RES, 1.25f);
        opr_set(&g_opr, LE_OPERATOR_FILTER_DRIVE, 24.0f);
        CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
        le_operator_render(&g_opr, l, r, N);
        CHECK(opr_finite(l, N));
        CHECK(opr_peak(l, N) > 0.01f && opr_peak(l, N) < 40.0f);
      }
    }
  }
}

/* Controller routes at rest: aftertouch at 0 through +100 % to Volume
 * silences, through -100 % leaves full level, and moves no filter. */
static void test_operator_controllers_rest(void) {
  printf("test_operator_controllers_rest\n");
  enum { N = 4800 };
  static float l[N], r[N], ref[N];
  const float amounts[2] = {100.0f, -100.0f};
  const float want[2] = {0.0f, 1.0f};
  for (int k = 0; k < 2; ++k) {
    opr_reference(&g_opr);
    opr_set(&g_opr, LE_OPERATOR_ROUTE + 8, 20.0f); /* aftertouch, route 0: Volume */
    opr_set(&g_opr, LE_OPERATOR_ROUTE + 9, amounts[k]);
    CHECK(le_operator_note_on(&g_opr, 1, 60, 100, 0) == 0);
    le_operator_render(&g_opr, l, r, N);
    CHECK(fabsf(opr_peak(l + N / 2, N / 2) - want[k]) < 0.01f);
  }
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_FREQ, 500.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 100, 0) == 0);
  le_operator_render(&g_opr, ref, r, N);
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_FREQ, 500.0f);
  opr_set(&g_opr, LE_OPERATOR_ROUTE + 8, 10.0f); /* aftertouch: Filter Freq */
  opr_set(&g_opr, LE_OPERATOR_ROUTE + 9, 100.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 100, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(memcmp(l, ref, sizeof(l)) == 0);
}

/* Fits against the strict score: Spread under 1 % is off; an operator
 * envelope's -70 dB floor is silence, so a sustain there is 0; Noise White
 * never repeats. */
static void test_operator_strict_fits(void) {
  printf("test_operator_strict_fits\n");
  enum { N = 16384 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_SPREAD, 0.5f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_active(&g_opr) == 1);
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_ENV + LE_OPERATOR_ENV_DECAY_TIME, 10.0f);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_ENV + LE_OPERATOR_ENV_SUSTAIN, 0.00031622799f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(opr_peak(l, 240) > 0.2f);
  CHECK(opr_peak(l + N / 2, N / 2) < 1e-6f); /* not 0.000316 */
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_WAVE, 21.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  double c0 = 0.0, c1 = 0.0;
  for (int32_t i = 0; i < N - 4096; ++i) {
    c0 += (double)l[i] * l[i];
    c1 += (double)l[i] * l[i + 4096];
  }
  CHECK(c0 > 0.0 && fabs(c1 / c0) < 0.1);
}

/* Round 8's fits: the Volume route scales the voice's output and leaves
 * the modulators whole (an FM pair's sideband against its carrier is the
 * same at velocity 64 as at 127 with velocity +100 % on Volume). */
static void test_operator_round8_fits(void) {
  printf("test_operator_round8_fits\n");
  enum { N = 16384 };
  static float l[N], r[N];
  double ratio[2], level[2];
  const int32_t vels[2] = {127, 64};
  for (int k = 0; k < 2; ++k) {
    opr_reference(&g_opr);
    opr_set(&g_opr, LE_OPERATOR_ALGORITHM, 0.0f);
    opr_op(&g_opr, 1, LE_OPERATOR_OP_ON, 1.0f);
    opr_op(&g_opr, 1, LE_OPERATOR_OP_COARSE, 2.0f);
    opr_op(&g_opr, 1, LE_OPERATOR_OP_VOLUME, 0.3f);
    opr_set(&g_opr, LE_OPERATOR_ROUTE, 20.0f); /* velocity, route 0: Volume */
    opr_set(&g_opr, LE_OPERATOR_ROUTE + 1, 100.0f);
    CHECK(le_operator_note_on(&g_opr, 1, 60, vels[k], 0) == 0);
    le_operator_render(&g_opr, l, r, N);
    const double c = opr_component(l + N / 2, N / 2, opr_note_hz(60));
    const double sb = opr_component(l + N / 2, N / 2, 3.0 * opr_note_hz(60));
    ratio[k] = sb / c;
    level[k] = c;
  }
  CHECK(fabs(ratio[1] / ratio[0] - 1.0) < 0.01);
  CHECK(fabs(level[1] / level[0] - 64.0 / 127.0) < 0.01);
  /* round 9: the mod wheel at rest with +100 % on Aux Env silences the
   * pitch envelope (a gain destination); a +12 semitone level then plays
   * the note's own pitch */
  opr_reference(&g_opr);
  opr_op(&g_opr, 0, LE_OPERATOR_OP_PITCH_ENV_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_PITCH_ENV_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_PITCH_ENV + LE_OPERATOR_ENV_ATTACK_LEVEL, 12.0f);
  opr_set(&g_opr, LE_OPERATOR_PITCH_ENV + LE_OPERATOR_ENV_DECAY_LEVEL, 12.0f);
  opr_set(&g_opr, LE_OPERATOR_PITCH_ENV + LE_OPERATOR_ENV_SUSTAIN, 12.0f);
  opr_set(&g_opr, LE_OPERATOR_ROUTE + 16, 19.0f); /* mod wheel, route 0: Aux Env */
  opr_set(&g_opr, LE_OPERATOR_ROUTE + 17, 100.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.9);
}

/* Round 10: each of Spread's two voices draws its own random pan, so the
 * two channels' power summed over a note varies from note to note (with
 * one pan for both it would stay put). */
static void test_operator_round10_fits(void) {
  printf("test_operator_round10_fits\n");
  enum { N = 2400 };
  static float l[N], r[N];
  double lo = 1e30, hi = 0.0;
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_SPREAD, 100.0f);
  opr_set(&g_opr, LE_OPERATOR_PAN_RANDOM, 100.0f);
  for (int k = 0; k < 12; ++k) {
    CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
    le_operator_render(&g_opr, l, r, N);
    double p = 0.0;
    for (int32_t i = N / 2; i < N; ++i) p += (double)l[i] * l[i] + (double)r[i] * r[i];
    lo = p < lo ? p : lo;
    hi = p > hi ? p : hi;
    le_operator_note_off(&g_opr, 1);
    le_operator_render(&g_opr, l, r, N);
  }
  CHECK(hi / lo > 1.5);
}

/* A note that takes a sounding voice's place waits for that voice's 1 ms
 * fade, then starts; a mono chord's middle note, taken before it sounds,
 * never plays (measured: Rhythmic Pong Bass's triad). */
static void test_operator_steal_waits(void) {
  printf("test_operator_steal_waits\n");
  enum { N = 480 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_VOICES, 0.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 1) == 0);
  CHECK(le_operator_note_on(&g_opr, 1, 64, 127, 1) == 0);
  CHECK(le_operator_note_on(&g_opr, 1, 67, 127, 1) == 0);
  int32_t waiting = 0;
  le_operator_voice* last = NULL;
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    le_operator_voice* v = &g_opr.voices[i];
    if (v->state == 0) continue;
    if (v->wait > 0) {
      waiting++;
      last = v;
    }
  }
  CHECK(waiting == 1 && last != NULL && last->note == 67 && last->wait == OPR_SR / 1000);
  CHECK(le_operator_fading(&g_opr) == 1);
  le_operator_render(&g_opr, l, r, OPR_SR / 1000);
  CHECK(opr_peak(l, OPR_SR / 1000) > 0.01f); /* the first note sounds through its fade */
  CHECK(last->phase[0] == 0.0);  /* the last has not started */
  le_operator_render(&g_opr, l, r, N);
  CHECK(last->phase[0] != 0.0 && le_operator_fading(&g_opr) == 0);
  CHECK(opr_component(l, N, opr_note_hz(67)) > 0.5);
}

/* Voice bookkeeping: a mono legato note whose held voice was taken still
 * sounds; glide starts only while a voice sounds; fading a Spread note
 * reports its two voices; a Trigger-mode voice frees once it is silent,
 * key held; a circuit change mid-note starts that circuit clean. */
static void test_operator_voice_bookkeeping(void) {
  printf("test_operator_voice_bookkeeping\n");
  enum { N = 48000 };
  static float l[N], r[N];
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_VOICES, 0.0f);
  opr_set(&g_opr, LE_OPERATOR_GLIDE_ON, 1.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_fade_oldest(&g_opr) == 1); /* the voice budget takes it */
  CHECK(le_operator_note_on(&g_opr, 2, 64, 127, 0) == 0);
  CHECK(le_operator_held(&g_opr, 2));
  /* glide only while a voice sounds: after silence the note starts on pitch */
  le_operator_cut(&g_opr);
  le_operator_render(&g_opr, l, r, 4800);
  CHECK(le_operator_active(&g_opr) == 0 && le_operator_fading(&g_opr) == 0);
  CHECK(le_operator_note_on(&g_opr, 3, 72, 127, 0) == 0);
  for (int32_t i = 0; i < LE_OPERATOR_VOICE_SLOTS; ++i) {
    if (g_opr.voices[i].state == 1) CHECK(g_opr.voices[i].glide_chunks == 0);
  }
  /* a Spread note fades as two voices */
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_SPREAD, 50.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  CHECK(le_operator_fade_oldest(&g_opr) == 2);
  /* Trigger mode: silent after its decay and release, the key still down */
  opr_reference(&g_opr);
  const int32_t env = LE_OPERATOR_OP(0, LE_OPERATOR_OP_ENV);
  opr_set(&g_opr, env + LE_OPERATOR_ENV_LOOP_MODE, 4.0f);
  opr_set(&g_opr, env + LE_OPERATOR_ENV_DECAY_TIME, 50.0f);
  opr_set(&g_opr, env + LE_OPERATOR_ENV_RELEASE_TIME, 50.0f);
  CHECK(le_operator_note_on(&g_opr, 1, 60, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, 24000);
  CHECK(le_operator_active(&g_opr) == 0);
  /* a circuit change mid-note: the new circuit's state starts at zero */
  opr_reference(&g_opr);
  opr_set(&g_opr, LE_OPERATOR_FILTER_ON, 1.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_CIRCUIT_LPHP, 2.0f);
  opr_set(&g_opr, LE_OPERATOR_FILTER_RES, 1.2f);
  CHECK(le_operator_note_on(&g_opr, 1, 48, 127, 0) == 0);
  le_operator_render(&g_opr, l, r, 9600);
  const float before = opr_peak(l + 4800, 4800);
  opr_set(&g_opr, LE_OPERATOR_FILTER_CIRCUIT_LPHP, 4.0f);
  le_operator_render(&g_opr, l, r, 9600);
  CHECK(opr_finite(l, 9600));
  CHECK(opr_peak(l, 960) < 3.0f * fmaxf(before, opr_peak(l + 4800, 4800)));
}

/* ---- the engine: a slot playing Operator ---- */

/* The engine's slot renders what the module renders offline, sample for
 * sample, at any block size; the snapshot names the device. */
static void test_engine_operator_slot_matches_offline(void) {
  printf("test_engine_operator_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_OPERATOR_PARAMS];
  for (int p = 0; p < LE_OPERATOR_PARAMS; ++p) values[p] = le_operator_default(p);
  values[LE_OPERATOR_SPREAD] = 60.0f; /* two different sides */
  values[LE_OPERATOR_OP(1, LE_OPERATOR_OP_ON)] = 1.0f;
  values[LE_OPERATOR_OP(1, LE_OPERATOR_OP_VOLUME)] = 0.3f;
  opr_init(&g_opr);
  le_operator_set_values(&g_opr, values);
  le_operator_set_voice_limit(&g_opr, 32); /* the engine's default limit */
  CHECK(le_operator_note_on(&g_opr, ins_origin(1), 57, 100, 0) == 0);
  le_operator_render(&g_opr, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_OPERATOR, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_OPERATOR);
    CHECK(snap.instrument_voices[0] == 2);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

/* A parameter reaches the device and is clamped; switching to Drift and
 * back ends each device in turn; bad parameters are refused. */
static void test_engine_operator_params_and_switching(void) {
  printf("test_engine_operator_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_OPERATOR, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_operator_active(eng_op(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_OPERATOR_ALGORITHM, 99.0f) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_op(e, 1)->values[LE_OPERATOR_ALGORITHM] == 10.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_OPERATOR_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_OPERATOR_VOLUME, NAN) == LE_ERR_INVALID);
  /* Drift ends Operator */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_DRIFT);
  CHECK(le_operator_active(eng_op(e, 1)) == 0 && le_operator_fading(eng_op(e, 1)) == 0);
  /* a Drift parameter past Drift's count is refused, Operator's taken */
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_DRIFT_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_OPERATOR, NULL) == LE_OK);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_DRIFT_PARAMS, 0.0f) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ELECTRIC + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* MIDI routed to an Operator slot plays it; sustain holds it; Cut fades
 * it. */
static void test_engine_operator_midi(void) {
  printf("test_engine_operator_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_OPERATOR, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_operator_active(eng_op(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_op(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_op(e, 2)->voices[0].state == 2 || eng_op(e, 2)->voices[0].state == 0);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 4800, 64, 2, NULL, NULL);
  CHECK(le_operator_active(eng_op(e, 2)) == 0 && le_operator_fading(eng_op(e, 2)) == 0);
  le_engine_destroy(e);
}

static void run_operator_tests(void) {
  test_operator_sine_level();
  test_operator_every_wave_and_algorithm();
  test_operator_fm_depth();
  test_operator_feedback_only_on_unmodulated();
  test_operator_envelope_slopes();
  test_operator_spread_pair();
  test_operator_voices();
  test_operator_block_size_invariant();
  test_operator_velocity_route();
  test_operator_user_wave();
  test_operator_filter_and_shaper();
  test_operator_circuits_bounded();
  test_operator_controllers_rest();
  test_operator_voice_bookkeeping();
  test_operator_steal_waits();
  test_operator_strict_fits();
  test_operator_round8_fits();
  test_operator_round10_fits();
  test_engine_operator_slot_matches_offline();
  test_engine_operator_params_and_switching();
  test_engine_operator_midi();
}
