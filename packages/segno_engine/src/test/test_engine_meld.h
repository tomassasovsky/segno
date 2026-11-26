/* SEG-109: the Meld device. Its own module first (meld_voice.c, driven
 * directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_operator.h (opr_* helpers, drift_run,
 * the ins_* helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the
 * instrument tests. */

#include "meld_voice.h"

/* Slot k's Meld instance in engine e. */
static le_meld* eng_meld(le_engine* e, int32_t k) {
  return (le_meld*)le_instruments_device(e, LE_INST_DEVICE_MELD, k);
}

static le_meld g_meld;

static void meld_init_ref(le_meld* d) {
  CHECK(le_meld_init(d, OPR_SR) == 0);
  le_meld_set_voice_limit(d, LE_MELD_VOICE_SLOTS * LE_MELD_COPIES);
}

/* Sets one parameter, the others as they are. */
static void meld_set(le_meld* d, int32_t p, float v) {
  static float vals[LE_MELD_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_meld_set_values(d, vals);
}

static void meld_eng(le_meld* d, int32_t e, int32_t field, float v) {
  meld_set(d, LE_MELD_ENGINE(e, field), v);
}

/* A reference patch: engine A's Basic Shapes sine at 0 dB held at full
 * level, the limiter off, attack immediate. */
static void meld_reference(le_meld* d) {
  meld_init_ref(d);
  meld_set(d, LE_MELD_LIMITER, 0.0f);
  meld_eng(d, 0, LE_MELD_E_AMP_ATTACK, 0.0f);
}

/* A sine at 0 dB peaks at 0.5 x 0.707 per channel at centre pan: the
 * device's output is half the voice sum and the pan law constant power. */
static void test_meld_sine_level(void) {
  printf("test_meld_sine_level\n");
  enum { N = 9600 };
  static float l[N], r[N];
  meld_reference(&g_meld);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 0.3536f) < 0.005f);
  CHECK(memcmp(l, r, sizeof(l)) == 0);
  CHECK(fabs(opr_component(l + N / 2, N / 2, opr_note_hz(60)) - 0.3536) < 0.01);
  /* engine volume in dB, the global volume linear, pan constant power */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_VOLUME, -6.0206f);
  meld_set(&g_meld, LE_MELD_VOLUME, 0.5f);
  meld_eng(&g_meld, 0, LE_MELD_E_PAN, -1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 0.125f) < 0.003f);
  CHECK(opr_peak(r + N / 2, N / 2) < 1e-4f);
}

/* Every oscillator at three macro settings and every filter at full
 * resonance and drive stays finite and bounded, on both engines. */
static void test_meld_every_osc_and_filter(void) {
  printf("test_meld_every_osc_and_filter\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const float macros[3] = {0.0f, 0.5f, 1.0f};
  for (int32_t t = 0; t < LE_MELD_OSC_TYPES; ++t) {
    for (int m = 0; m < 3; ++m) {
      meld_reference(&g_meld);
      meld_eng(&g_meld, 0, LE_MELD_E_OSC_TYPE, (float)t);
      meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO1, macros[m]);
      meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO2, macros[2 - m]);
      CHECK(le_meld_note_on(&g_meld, 1, m == 1 ? 96 : 36, 127, 0) == 0);
      le_meld_render(&g_meld, l, r, N);
      CHECK(opr_finite(l, N) && opr_finite(r, N));
      /* Rain's drops ring louder as the pitch rises */
      CHECK(opr_peak(l, N) < (t == LE_MELD_OSC_RAIN ? 32.0f : 4.0f));
    }
  }
  for (int32_t t = 0; t < LE_MELD_FILTER_TYPES; ++t) {
    for (int m = 0; m < 3; ++m) {
      meld_reference(&g_meld);
      meld_eng(&g_meld, 1, LE_MELD_E_ON, 1.0f);
      for (int32_t e = 0; e < 2; ++e) {
        meld_eng(&g_meld, e, LE_MELD_E_OSC_MACRO1, 2.0f / 3.0f); /* a saw */
        meld_eng(&g_meld, e, LE_MELD_E_FILTER_ON, 1.0f);
        meld_eng(&g_meld, e, LE_MELD_E_FILTER_TYPE, (float)t);
        meld_eng(&g_meld, e, LE_MELD_E_FILTER_FREQ, m == 0 ? 20.0f : m == 1 ? 1000.0f : 20480.0f);
        meld_eng(&g_meld, e, LE_MELD_E_FILTER_MACRO1, 1.0f);
        meld_eng(&g_meld, e, LE_MELD_E_FILTER_MACRO2, macros[m]);
      }
      CHECK(le_meld_note_on(&g_meld, 1, 36, 127, 0) == 0);
      le_meld_render(&g_meld, l, r, N);
      CHECK(opr_finite(l, N) && opr_finite(r, N));
      /* the Phaser's negative feedback near 0.98 rings up to 2 / (1 - fb) */
      CHECK(opr_peak(l, N) < (t == LE_MELD_FILTER_PHASER ? 32.0f : 8.0f));
    }
  }
}

/* The matrix: an adding target takes amount x the bipolar source, a gain
 * target only attenuates, by 1 - a+ + a u. */
static void test_meld_matrix(void) {
  printf("test_meld_matrix\n");
  enum { N = 9600 };
  static float l[N], r[N];
  /* velocity 127 into Pitch Mod at 0.25: an octave up (48 semitones per
   * unit) */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 1, 10), 0.25f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, 2.0 * opr_note_hz(60)) > 0.3);
  /* velocity into Volume at +1: velocity 1 is nearly silent, 127 full */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 24, 10), 1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 1, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  const float soft = opr_peak(l + N / 2, N / 2);
  CHECK(soft > 0.002f && soft < 0.004f);
  /* at -1 it is the other way round: velocity 1 nearly full */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 24, 10), -1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 1, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(opr_peak(l + N / 2, N / 2) > 0.34f);
  /* the mod wheel at rest moves nothing */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 1, 16), 1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.34);
}

/* A linear attack is halfway at half its time; a Trigger-mode envelope
 * ends with the key held. */
static void test_meld_envelopes(void) {
  printf("test_meld_envelopes\n");
  enum { N = 48000 };
  static float l[N], r[N];
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_ATTACK, 0.5f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  const float half = opr_peak(l + 11800, 400) / 0.3536f;
  CHECK(half > 0.47f && half < 0.53f);
  CHECK(opr_peak(l + 26000, 2000) > 0.35f);
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_LOOP, 1.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_DECAY, 0.05f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_SUSTAIN, 0.5f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_RELEASE, 0.05f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_LOOP, 1.0f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_DECAY, 0.05f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_RELEASE, 0.05f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 24000);
  CHECK(le_meld_active(&g_meld) == 0);
}

/* Unison copies sum coherently at 1 / sqrt(N); Spread fans them by the
 * matrix. */
static void test_meld_unison(void) {
  printf("test_meld_unison\n");
  enum { N = 9600 };
  static float l[N], r[N];
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_UNISON, 2.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  CHECK(le_meld_active(&g_meld) == 3);
  le_meld_render(&g_meld, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 0.3536f * sqrtf(3.0f)) < 0.01f);
  /* two copies panned hard apart by Spread */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_UNISON, 1.0f);
  meld_set(&g_meld, LE_MELD_SPREAD, 1.0f);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 23, 18), 0.5f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - 0.3536f) < 0.01f);
  CHECK(fabsf(opr_peak(r + N / 2, N / 2) - 0.3536f) < 0.01f);
  CHECK(le_meld_fade_oldest(&g_meld) == 2);
}

/* Poly counts, stealing, mono legato and the voice end. */
static void test_meld_voices(void) {
  printf("test_meld_voices\n");
  enum { N = 4800 };
  static float l[N], r[N];
  /* Poly at 2 voices: a third note steals the oldest */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_POLY_VOICES, 0.0f);
  for (uint32_t o = 1; o <= 3; ++o) CHECK(le_meld_note_on(&g_meld, o, 60 + (int)o, 100, 0) == 0);
  CHECK(le_meld_active(&g_meld) == 2);
  CHECK(le_meld_fading(&g_meld) == 1);
  CHECK(g_meld.stolen == 1);
  /* Mono legato: one voice moves from key to key and back */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MONO_POLY, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_RELEASE, 0.01f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_RELEASE, 0.01f);
  CHECK(le_meld_note_on(&g_meld, 1, 48, 100, 0) == 0);
  CHECK(le_meld_note_on(&g_meld, 2, 60, 100, 0) == 0);
  CHECK(le_meld_active(&g_meld) == 1 && le_meld_fading(&g_meld) == 0);
  le_meld_note_off(&g_meld, 2);
  CHECK(le_meld_active(&g_meld) == 1);
  le_meld_render(&g_meld, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(48)) > 0.3);
  /* a released voice ends after its release and 10 ms of silence */
  le_meld_note_off(&g_meld, 1);
  le_meld_render(&g_meld, l, r, N);
  le_meld_render(&g_meld, l, r, N);
  CHECK(le_meld_active(&g_meld) == 0);
  /* a note released before engine B's delay still ends */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 1, LE_MELD_E_ON, 1.0f);
  meld_set(&g_meld, LE_MELD_ENGINE_B_DELAY, 0.05f);
  for (int32_t e = 0; e < 2; ++e) meld_eng(&g_meld, e, LE_MELD_E_AMP_RELEASE, 0.01f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 100, 0) == 0);
  le_meld_render(&g_meld, l, r, 480);
  le_meld_note_off(&g_meld, 1);
  for (int k = 0; k < 4; ++k) le_meld_render(&g_meld, l, r, N);
  CHECK(le_meld_active(&g_meld) == 0);
  /* a Poly patch the voice budget squeezes to one note steals, not legato */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_UNISON, 2.0f);
  le_meld_set_voice_limit(&g_meld, 3);
  CHECK(le_meld_note_on(&g_meld, 1, 48, 100, 0) == 0);
  CHECK(le_meld_note_on(&g_meld, 2, 60, 100, 0) == 0);
  CHECK(g_meld.stolen == 1 && le_meld_active(&g_meld) == 3);
  /* a chord's notes start at their own pitch, without glide */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_GLIDE_TIME, 0.2f);
  CHECK(le_meld_note_on(&g_meld, 7, 60, 100, 0) == 0);
  CHECK(le_meld_note_on(&g_meld, 7, 64, 100, 1) == 0);
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (g_meld.voices[i].state == 1) CHECK(g_meld.voices[i].c[0].e[0].glide_left == 0);
  }
  /* sustain holds a released note; Cut fades everything */
  meld_reference(&g_meld);
  CHECK(le_meld_sustain(&g_meld, 9, 1) == 0);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 100, 0) == 0);
  le_meld_note_off(&g_meld, 1);
  CHECK(g_meld.voices[0].state == 3);
  CHECK(le_meld_held(&g_meld, 1) == 0);
  le_meld_cut(&g_meld);
  le_meld_render(&g_meld, l, r, N);
  CHECK(le_meld_active(&g_meld) == 0 && le_meld_fading(&g_meld) == 0);
}

/* Rendering in any block size gives the same samples; Engine B waits out
 * its delay. */
static void test_meld_block_size_and_delay(void) {
  printf("test_meld_block_size_and_delay\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    meld_reference(&g_meld);
    meld_eng(&g_meld, 0, LE_MELD_E_OSC_TYPE, 13.0f); /* Simple FM */
    meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO1, 0.6f);
    meld_eng(&g_meld, 0, LE_MELD_E_FILTER_ON, 1.0f);
    meld_eng(&g_meld, 0, LE_MELD_E_FILTER_FREQ, 800.0f);
    meld_eng(&g_meld, 1, LE_MELD_E_ON, 1.0f);
    meld_set(&g_meld, LE_MELD_ENGINE_B_DELAY, 0.05f);
    meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 5, 4), 0.2f); /* LFO 2 into the filter */
    CHECK(le_meld_note_on(&g_meld, 1, 57, 100, 0) == 0);
    if (b < 0) {
      le_meld_render(&g_meld, ref_l, ref_r, N);
      continue;
    }
    for (int32_t i = 0; i < N; i += blocks[b]) {
      const int32_t n = N - i < blocks[b] ? N - i : blocks[b];
      le_meld_render(&g_meld, l + i, r + i, n);
    }
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
  }
  /* engine B alone: silent until its 50 ms (2400 samples, a multiple of 16) */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_ON, 0.0f);
  meld_eng(&g_meld, 1, LE_MELD_E_ON, 1.0f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_ATTACK, 0.0f);
  meld_set(&g_meld, LE_MELD_ENGINE_B_DELAY, 0.05f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  CHECK(opr_peak(l, 2400) == 0.0f);
  CHECK(opr_peak(l + 2416, 400) > 0.3f);
}

/* ---- the engine: a slot playing Meld ---- */

static void test_engine_meld_slot_matches_offline(void) {
  printf("test_engine_meld_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_MELD_PARAMS];
  for (int p = 0; p < LE_MELD_PARAMS; ++p) values[p] = le_meld_default(p);
  values[LE_MELD_UNISON] = 1.0f;
  values[LE_MELD_SPREAD] = 1.0f;
  values[LE_MELD_MOD_AMOUNT(0, 23, 18)] = 0.3f;
  values[LE_MELD_ENGINE(0, LE_MELD_E_OSC_TYPE)] = 8.0f; /* Swarm Saw */
  meld_init_ref(&g_meld);
  le_meld_set_values(&g_meld, values);
  le_meld_set_voice_limit(&g_meld, 32); /* the engine's default limit */
  CHECK(le_meld_note_on(&g_meld, ins_origin(1), 57, 100, 0) == 0);
  le_meld_render(&g_meld, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_MELD, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_MELD);
    CHECK(snap.instrument_voices[0] == 2);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

static void test_engine_meld_params_and_switching(void) {
  printf("test_engine_meld_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_MELD, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_meld_active(eng_meld(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_MELD_ENGINE(0, LE_MELD_E_OSC_TYPE), 99.0f) ==
        LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_meld(e, 1)->values[LE_MELD_ENGINE(0, LE_MELD_E_OSC_TYPE)] == 24.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_MELD_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_MELD_VOLUME, NAN) == LE_ERR_INVALID);
  /* a matrix amount reaches the device's routes */
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_MELD_MOD_AMOUNT(1, 24, 10), 0.5f) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_meld(e, 1)->route_n[1] == 1);
  /* Operator ends Meld */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_OPERATOR, NULL) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_OPERATOR);
  CHECK(le_meld_active(eng_meld(e, 1)) == 0 && le_meld_fading(eng_meld(e, 1)) == 0);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_OPERATOR_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_MELD, NULL) == LE_OK);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_OPERATOR_PARAMS, 0.0f) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ELECTRIC + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_engine_meld_midi(void) {
  printf("test_engine_meld_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_MELD, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_meld_active(eng_meld(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_meld(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_meld(e, 2)->voices[0].state == 2 || eng_meld(e, 2)->voices[0].state == 0);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 4800, 64, 2, NULL, NULL);
  CHECK(le_meld_active(eng_meld(e, 2)) == 0 && le_meld_fading(eng_meld(e, 2)) == 0);
  le_engine_destroy(e);
}

/* What the strict fit settled (SEG-109): linked envelopes carry engine A's
 * modulated times to B, the Note source reaches Tone in octaves from C3,
 * and the Quantizer is symmetric about 0. */
static void test_meld_fits(void) {
  printf("test_meld_fits\n");
  enum { N = 48000 };
  static float l[N], r[N];
  /* engine B alone sounding, its release linked to A's, which velocity
   * stretches from 0.05 s to about 0.3 s: B still sounds 0.1 s after the
   * note ends */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_ON, 0.0f);
  meld_eng(&g_meld, 1, LE_MELD_E_ON, 1.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_RELEASE, 0.05f);
  meld_eng(&g_meld, 1, LE_MELD_E_AMP_RELEASE, 0.05f);
  meld_set(&g_meld, LE_MELD_LINK_ENVELOPES, 1.0f);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 16, 10), 0.109375f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 9600);
  const float held = opr_peak(l + 4800, 4800);
  le_meld_note_off(&g_meld, 1);
  le_meld_render(&g_meld, l, r, 9600);
  CHECK(opr_peak(l + 4800, 480) > 0.2f * held);
  /* Note into Tone at 0.5 plays C1 as Tone -1 does */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO1, 0.67f);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 22, 11), 0.5f);
  CHECK(le_meld_note_on(&g_meld, 1, 24, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 9600);
  const float by_note = opr_peak(l + 4800, 4800);
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO1, 0.67f);
  meld_eng(&g_meld, 0, LE_MELD_E_TONE, -1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 24, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 9600);
  CHECK(fabsf(by_note - opr_peak(l + 4800, 4800)) < 1e-4f);
  /* LFO 1 through the Quantizer at 0.8 into Pan at 0.5: the steps include
   * both ends, so each channel falls silent once a cycle */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX1_TYPE, 7.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX1_MACRO, 0.8f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX2_TYPE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_RATE, 2.0f);
  meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 23, 3), 0.5f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  float lmin = 1.0f, rmin = 1.0f;
  for (int32_t i = 0; i + 480 <= N; i += 480) {
    lmin = fminf(lmin, opr_peak(l + i, 480));
    rmin = fminf(rmin, opr_peak(r + i, 480));
  }
  CHECK(lmin < 0.01f && rmin < 0.01f);
  /* Mono without legato, three keys at once: the second steals the first
   * and starts after its 1 ms fade, the third finds nothing to steal and
   * is dropped */
  meld_reference(&g_meld);
  meld_set(&g_meld, LE_MELD_MONO_POLY, 0.0f);
  meld_set(&g_meld, LE_MELD_MONO_LEGATO, 0.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  CHECK(le_meld_note_on(&g_meld, 2, 64, 127, 0) == 0);
  CHECK(le_meld_note_on(&g_meld, 3, 67, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 4800);
  int sounding = 0, note = -1;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (g_meld.voices[i].state != 0) sounding++, note = g_meld.voices[i].note;
  }
  CHECK(sounding == 1 && note == 64);
  CHECK(fabs(opr_component(l + 2400, 2400, opr_note_hz(64)) - 0.3536) < 0.01);
  /* LFO 1's Pulsate draws the same pulses on every retriggered note */
  {
    static float a[4800], b[4800];
    meld_reference(&g_meld);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_TYPE, 5.0f);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO1, 0.34f);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO2, 1.0f);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX1_TYPE, 0.0f);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX2_TYPE, 0.0f);
    meld_eng(&g_meld, 0, LE_MELD_E_LFO1_RATE, 20.0f);
    meld_set(&g_meld, LE_MELD_MOD_AMOUNT(0, 1, 2), 0.02f);
    CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
    le_meld_render(&g_meld, a, r, 4800);
    le_meld_note_off(&g_meld, 1);
    le_meld_render(&g_meld, l, r, 24000);
    CHECK(le_meld_note_on(&g_meld, 2, 60, 127, 0) == 0);
    le_meld_render(&g_meld, b, r, 4800);
    float diff = 0.0f;
    for (int32_t i = 0; i < 4800; ++i) diff = fmaxf(diff, fabsf(a[i] - b[i]));
    /* the tone filter's state carries a trace of the first note (0.007);
     * a different pulse sequence would detune the second by up to two
     * semitones */
    CHECK(diff < 0.02f);
  }
}

/* The values measured from Live's renders: LFO 1's Pulsate heights, LFO
 * 2's S&H steps, Wander's targets, Fold FM's intervals. */
static void test_meld_measured(void) {
  printf("test_meld_measured\n");
  enum { N = 24000 };
  static float l[N], r[N];
  /* Pulsate at 4 Hz, every chance taken, pulses a fifth of a cycle: the
   * first quarter's pulse +0.971, the second's -0.462 (pul-c100) */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_TYPE, 5.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO1, 1.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO2, 0.252f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX1_TYPE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX2_TYPE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_RATE, 4.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_WAVE, 5.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_RATE, 8.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_RETRIGGER, 1.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_voice* v = NULL;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (g_meld.voices[i].state != 0) v = &g_meld.voices[i];
  }
  CHECK(v != NULL);
  const le_meld_engine* en = &v->c[0].e[0];
  le_meld_render(&g_meld, l, r, 1440); /* 30 ms */
  CHECK(fabsf(en->lfo1.gen - 0.971f) < 1e-3f);
  CHECK(fabsf(en->lfo2_sh - 0.152f) < 1e-3f); /* S&H's first step (sh-8hz) */
  le_meld_render(&g_meld, l, r, 3000); /* 92.5 ms */
  CHECK(fabsf(en->lfo1.gen + 0.462f) < 1e-3f);
  le_meld_render(&g_meld, l, r, 4800); /* 192.5 ms: S&H's second step */
  CHECK(fabsf(en->lfo2_sh + 0.600f) < 1e-3f);
  /* Wander as plain random steps (Morph 0.5, Step 1): the first cycle
   * holds -0.998, the second +0.974 (wander-step) */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_TYPE, 2.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO1, 0.5f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_MACRO2, 1.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX1_TYPE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_FX2_TYPE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO1_RATE, 4.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (g_meld.voices[i].state != 0) v = &g_meld.voices[i];
  }
  en = &v->c[0].e[0];
  le_meld_render(&g_meld, l, r, 6000);
  CHECK(fabsf(en->lfo1.gen + 0.998f) < 1e-3f);
  le_meld_render(&g_meld, l, r, 12000);
  CHECK(fabsf(en->lfo1.gen - 0.974f) < 1e-3f);
  /* a free LFO 2 (no retrigger) at 2 Hz runs on through the silence
   * between notes: a note 1.25 s after the first starts it at phase 0.5
   * (free2-poly) */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_WAVE, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_RATE, 2.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_LFO2_RETRIGGER, 0.0f);
  meld_eng(&g_meld, 0, LE_MELD_E_AMP_RELEASE, 0.05f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, 24000);
  le_meld_note_off(&g_meld, 1);
  le_meld_render(&g_meld, l, r, 24000);
  le_meld_render(&g_meld, l, r, 12000); /* 1.25 s */
  CHECK(le_meld_note_on(&g_meld, 2, 60, 127, 0) == 0);
  v = NULL;
  for (int32_t i = 0; i < LE_MELD_VOICE_SLOTS; ++i) {
    if (g_meld.voices[i].state != 0) v = &g_meld.voices[i];
  }
  CHECK(v != NULL);
  CHECK(fabs(v->c[0].e[0].lfo2_ph - 0.5) < 1e-3);
  /* Fold FM at Macro 1 squared = 3/7, on 7 semitones alone: a line at G4
   * (1.498 f0), none at 1.26 f0 where the neighbouring 4 semitones would
   * sit */
  meld_reference(&g_meld);
  meld_eng(&g_meld, 0, LE_MELD_E_OSC_TYPE, (float)LE_MELD_OSC_FOLD_FM);
  meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO1, sqrtf(3.0f / 7.0f));
  meld_eng(&g_meld, 0, LE_MELD_E_OSC_MACRO2, 0.0f);
  CHECK(le_meld_note_on(&g_meld, 1, 60, 127, 0) == 0);
  le_meld_render(&g_meld, l, r, N);
  const double f0 = opr_note_hz(60);
  const double fund = opr_component(l + N / 2, N / 2, f0);
  CHECK(opr_component(l + N / 2, N / 2, f0 * 1.4983071) > 0.003 * fund);
  CHECK(opr_component(l + N / 2, N / 2, f0 * 1.2599210) < 0.0003 * fund);
}

static void run_meld_tests(void) {
  test_meld_sine_level();
  test_meld_fits();
  test_meld_measured();
  test_meld_every_osc_and_filter();
  test_meld_matrix();
  test_meld_envelopes();
  test_meld_unison();
  test_meld_voices();
  test_meld_block_size_and_delay();
  test_engine_meld_slot_matches_offline();
  test_engine_meld_params_and_switching();
  test_engine_meld_midi();
}
