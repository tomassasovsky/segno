/* SEG-109: the Collision device. Its own module first (collision_voice.c,
 * driven directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_tension.h (opr_* helpers,
 * drift_run, the ins_* helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these
 * with the instrument tests. */

#include "collision_voice.h"

/* Slot k's Collision instance in engine e. */
static le_collision* eng_collision(le_engine* e, int32_t k) {
  return (le_collision*)le_instruments_device(e, LE_INST_DEVICE_COLLISION, k);
}

static le_collision g_collision;

static void collision_reference(le_collision* d) {
  CHECK(le_collision_init(d, OPR_SR) == 0);
  le_collision_set_voice_limit(d, LE_COLLISION_VOICE_SLOTS);
}

static void collision_set(le_collision* d, int32_t p, float v) {
  static float vals[LE_COLLISION_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_collision_set_values(d, vals);
}

/* Every resonator type rings at the note's pitch: the string's harmonic,
 * the beam's 2.76, the tube's odd partials only. */
static void test_collision_types(void) {
  printf("test_collision_types\n");
  enum { N = 24000 };
  static float l[N], r[N];
  for (int32_t type = 0; type < 7; ++type) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), (float)type);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    le_collision_render(&g_collision, l, r, N);
    CHECK(opr_finite(l, N) && opr_finite(r, N));
    CHECK(opr_peak(l, N) > 0.001f);
    const double f0 = opr_note_hz(60);
    CHECK(opr_component(l + 2400, 9600, f0) > 4.0 * opr_component(l + 2400, 9600, 1.5 * f0));
  }
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), 2.0f); /* string */
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_HIT), 1.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  CHECK(opr_component(l + 2400, 9600, 2.0 * opr_note_hz(60)) > 0.01 * opr_component(l + 2400, 9600, opr_note_hz(60)));
  /* the pipe has every harmonic, the tube (its far end closed) the odd ones */
  double second[2];
  for (int32_t k = 0; k < 2; ++k) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), 5.0f + (float)k);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    le_collision_render(&g_collision, l, r, N);
    second[k] = opr_component(l + 2400, 9600, 2.0 * opr_note_hz(60)) / opr_component(l + 2400, 9600, opr_note_hz(60));
  }
  CHECK(second[0] > 0.01 && second[1] < 0.001);
}

/* Every control at its ends, on the keyboard's ends: finite and within
 * the output's +-1. */
static void test_collision_extremes(void) {
  printf("test_collision_extremes\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const int32_t notes[3] = {0, 60, 127};
  for (int32_t p = 0; p < LE_COLLISION_PARAMS; ++p) {
    for (int m = 0; m < 2; ++m) {
      for (int k = 0; k < 3; ++k) {
        collision_reference(&g_collision);
        collision_set(&g_collision, LE_COLLISION_NOISE_ON, 1.0f);
        collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_ON), 1.0f);
        collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), (float)(p % 7));
        collision_set(&g_collision, p, le_collision_clamp(p, m ? 1e9f : -1e9f));
        CHECK(le_collision_note_on(&g_collision, 1, notes[k], 127, 0) == 0);
        le_collision_render(&g_collision, l, r, N);
        CHECK(opr_finite(l, N) && opr_finite(r, N));
        CHECK(opr_peak(l, N) <= 1.0f && opr_peak(r, N) <= 1.0f);
        le_collision_note_off(&g_collision, 1);
        le_collision_render(&g_collision, l, r, N);
        CHECK(opr_finite(l, N) && opr_finite(r, N));
      }
    }
  }
}

/* Voice counts, a key struck again, mono, sustain, the release and Cut. */
static void test_collision_voices(void) {
  printf("test_collision_voices\n");
  enum { N = 4800 };
  static float l[N], r[N];
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_POLYPHONY, 1.0f); /* 2 voices */
  collision_set(&g_collision, LE_COLLISION_RETRIGGER, 0.0f);
  for (uint32_t o = 1; o <= 3; ++o) CHECK(le_collision_note_on(&g_collision, o, 60 + (int)o, 100, 0) == 0);
  CHECK(le_collision_active(&g_collision) == 2);
  CHECK(le_collision_fading(&g_collision) == 1);
  CHECK(g_collision.stolen == 1);
  /* Retrigger: the same key strikes its own voice again */
  collision_reference(&g_collision);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  CHECK(le_collision_note_on(&g_collision, 2, 60, 100, 0) == 0);
  CHECK(le_collision_active(&g_collision) == 1);
  /* mono: one voice moves to each key */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_POLYPHONY, 0.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 48, 100, 0) == 0);
  CHECK(le_collision_note_on(&g_collision, 2, 60, 100, 0) == 0);
  CHECK(le_collision_active(&g_collision) == 1);
  /* a short off decay: the voice ends after the release */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_OFF_DECAY), 0.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  le_collision_note_off(&g_collision, 1);
  for (int k = 0; k < 20 && le_collision_active(&g_collision) > 0; ++k) le_collision_render(&g_collision, l, r, N);
  CHECK(le_collision_active(&g_collision) == 0);
  /* sustain holds it; Cut fades everything */
  collision_reference(&g_collision);
  CHECK(le_collision_sustain(&g_collision, 9, 1) == 0);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_note_off(&g_collision, 1);
  CHECK(g_collision.voices[0].state == 3);
  CHECK(le_collision_held(&g_collision, 1) == 0);
  le_collision_cut(&g_collision);
  le_collision_render(&g_collision, l, r, N);
  CHECK(le_collision_active(&g_collision) == 0 && le_collision_fading(&g_collision) == 0);
}

/* Rendering in any block size gives the same samples. */
static void collision_play(le_collision* d, float* l, float* r, int32_t n, int32_t block) {
  static const int32_t at[2] = {4000, 6000};
  int32_t i = 0, ev = 0;
  while (i < n) {
    int32_t m = n - i < block ? n - i : block;
    if (ev < 2 && i + m > at[ev]) m = at[ev] - i;
    if (m > 0) le_collision_render(d, l + i, r + i, m);
    i += m;
    if (ev < 2 && i == at[ev]) {
      if (ev == 0) CHECK(le_collision_note_on(d, 2, 64, 100, 0) == 0);
      else le_collision_note_off(d, 2);
      ev++;
    }
  }
}

static void test_collision_block_size(void) {
  printf("test_collision_block_size\n");
  enum { N = 12000 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_POLYPHONY, 0.0f);
    collision_set(&g_collision, LE_COLLISION_NOISE_ON, 1.0f);
    collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_ON), 1.0f);
    collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_TYPE), 5.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_ON), 1.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_TARGET1), (float)LE_COLLISION_D_R1_PITCH);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_AMOUNT1), 0.2f);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_PITCH_ENV), 0.5f);
    CHECK(le_collision_note_on(&g_collision, 1, 57, 100, 0) == 0);
    collision_play(&g_collision, b < 0 ? ref_l : l, b < 0 ? ref_r : r, N, b < 0 ? N : blocks[b]);
    if (b < 0) continue;
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
  }
}

/* ---- the engine: a slot playing Collision ---- */

static void test_engine_collision_slot_matches_offline(void) {
  printf("test_engine_collision_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_COLLISION_PARAMS];
  for (int p = 0; p < LE_COLLISION_PARAMS; ++p) values[p] = le_collision_default(p);
  values[LE_COLLISION_RES(0, LE_COLLISION_R_TYPE)] = 4.0f;
  values[LE_COLLISION_NOISE_ON] = 1.0f;
  CHECK(le_collision_init(&g_collision, OPR_SR) == 0);
  le_collision_set_values(&g_collision, values);
  le_collision_set_voice_limit(&g_collision, 32); /* the engine's default limit */
  CHECK(le_collision_note_on(&g_collision, ins_origin(1), 57, 100, 0) == 0);
  le_collision_render(&g_collision, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_COLLISION, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_COLLISION);
    CHECK(snap.instrument_voices[0] == 1);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

static void test_engine_collision_params_and_switching(void) {
  printf("test_engine_collision_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_COLLISION, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_collision_active(eng_collision(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_COLLISION_RES(0, LE_COLLISION_R_TUNE), 99.0f) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_collision(e, 1)->values[LE_COLLISION_RES(0, LE_COLLISION_R_TUNE)] == 48.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_COLLISION_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_COLLISION_VOLUME, NAN) == LE_ERR_INVALID);
  /* Tension ends Collision */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_TENSION, NULL) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_TENSION);
  CHECK(le_collision_active(eng_collision(e, 1)) == 0 && le_collision_fading(eng_collision(e, 1)) == 0);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_COLLISION + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_engine_collision_midi(void) {
  printf("test_engine_collision_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_COLLISION, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_collision_active(eng_collision(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_collision(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_collision(e, 2)->voices[0].state == 2); /* released, ringing out */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 4800, 64, 2, NULL, NULL);
  CHECK(le_collision_active(eng_collision(e, 2)) == 0 && le_collision_fading(eng_collision(e, 2)) == 0);
  le_engine_destroy(e);
}

static void run_collision_tests(void) {
  test_collision_types();
  test_collision_extremes();
  test_collision_voices();
  test_collision_block_size();
  test_engine_collision_slot_matches_offline();
  test_engine_collision_params_and_switching();
  test_engine_collision_midi();
}
