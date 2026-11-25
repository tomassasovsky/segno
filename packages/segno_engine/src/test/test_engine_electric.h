/* SEG-109: the Electric device. Its own module first (electric_voice.c,
 * driven directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_analog.h (opr_* helpers, drift_run,
 * the ins_* helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the
 * instrument tests. */

#include "electric_voice.h"

/* Slot k's Electric instance in engine e. */
static le_electric* eng_electric(le_engine* e, int32_t k) {
  return (le_electric*)le_instruments_device(e, LE_INST_DEVICE_ELECTRIC, k);
}

static le_electric g_electric;

/* The top of parameter p's range. */
static float param_hi(int32_t p) { return le_electric_clamp(p, 1e9f); }

static void electric_reference(le_electric* d) {
  CHECK(le_electric_init(d, OPR_SR) == 0);
  le_electric_set_voice_limit(d, LE_ELECTRIC_VOICE_SLOTS);
}

/* Sets one parameter, the others as they are. */
static void electric_set(le_electric* d, int32_t p, float v) {
  static float vals[LE_ELECTRIC_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_electric_set_values(d, vals);
}

/* A note strikes one 1 ms block after it arrives, rings at its pitch on
 * the tone bar, the same on both channels, and keeps ringing while held. */
static void test_electric_strike(void) {
  printf("test_electric_strike\n");
  enum { N = 48000 };
  static float l[N], r[N];
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_peak(l, 48) == 0.0f);
  CHECK(opr_peak(l + 48, 480) > 0.05f);
  CHECK(memcmp(l, r, sizeof(l)) == 0);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.03);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) >
        10.0 * opr_component(l + N / 2, N / 2, 1.5 * opr_note_hz(60)));
  CHECK(opr_peak(l + N - 4800, 4800) > 0.03f);
  /* Semitone 24 is an octave up */
  electric_reference(&g_electric);
  electric_set(&g_electric, LE_ELECTRIC_SEMITONE, 24.0f);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(72)) >
        10.0 * opr_component(l + N / 2, N / 2, opr_note_hz(60)));
  /* a released key's ringing dies away and the voice ends */
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, 4800);
  le_electric_note_off(&g_electric, 1);
  le_electric_render(&g_electric, l, r, N);
  CHECK(le_electric_active(&g_electric) == 0);
}

/* Every control at its ends, both pickups: finite on any note, and never
 * past the output stage's ceiling of 4, even where the key and velocity
 * scalings drive the voice without bound. */
static void test_electric_extremes(void) {
  printf("test_electric_extremes\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const int32_t notes[4] = {21, 108, 0, 127};
  for (int32_t p = 0; p < LE_ELECTRIC_PARAMS; ++p) {
    for (int m = 0; m < 2; ++m) {
      for (int model = 0; model < 2; ++model) {
        for (int k = 0; k < 4; ++k) {
          electric_reference(&g_electric);
          electric_set(&g_electric, LE_ELECTRIC_PICKUP_MODEL, (float)model);
          if (p != LE_ELECTRIC_PICKUP_MODEL) electric_set(&g_electric, p, m ? param_hi(p) : 0.0f);
          CHECK(le_electric_note_on(&g_electric, 1, notes[k], 127, 0) == 0);
          le_electric_render(&g_electric, l, r, N);
          CHECK(opr_finite(l, N));
          CHECK(opr_peak(l, N) <= 4.0f);
          le_electric_note_off(&g_electric, 1);
          le_electric_render(&g_electric, l, r, N);
          CHECK(opr_finite(l, N));
          CHECK(opr_peak(l, N) <= 4.0f);
        }
      }
    }
  }
}

/* The output stage passes a quiet note unchanged and bends a loud one's
 * peaks toward 4: full Force < Velocity at velocity 127 would peak past 6
 * without it. */
static void test_electric_output_stage(void) {
  printf("test_electric_output_stage\n");
  enum { N = 4800 };
  static float l[N], r[N];
  electric_reference(&g_electric);
  electric_set(&g_electric, LE_ELECTRIC_FORCE_VEL, 1.0f);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 127, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_peak(l, N) > 3.0f);
  CHECK(opr_peak(l, N) < 4.0f);
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_peak(l, N) < 1.0f);
}

/* A centred Noise Pitch puts the mallet noise exactly half an octave over
 * its base, 519.5 Hz (the line's own midpoint, not 64/127 of the way). */
static void test_electric_centred_noise_pitch(void) {
  printf("test_electric_centred_noise_pitch\n");
  enum { N = 48000 };
  static float l[N], r[N];
  electric_reference(&g_electric);
  electric_set(&g_electric, LE_ELECTRIC_NOISE_AMOUNT, 1.0f);
  electric_set(&g_electric, LE_ELECTRIC_NOISE_DECAY, 1.0f);
  electric_set(&g_electric, LE_ELECTRIC_TONE_VOLUME, 0.0f);
  electric_set(&g_electric, LE_ELECTRIC_TINE_VOLUME, 0.0f);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  const double at = opr_component(l + 480, N - 480, 367.31 * 1.41421356);
  CHECK(at > 3.0 * opr_component(l + 480, N - 480, 533.7));
  CHECK(at > 3.0 * opr_component(l + 480, N - 480, 505.6));
}

/* Notes ended, stolen or struck again before their strike stay silent and
 * finite. */
static void test_electric_before_the_strike(void) {
  printf("test_electric_before_the_strike\n");
  enum { N = 960 };
  static float l[N], r[N];
  /* the same key twice before any render */
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  CHECK(le_electric_note_on(&g_electric, 2, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_finite(l, N) && opr_peak(l, N) > 0.0f);
  /* a three-note chord on two voices steals a voice that never struck */
  electric_reference(&g_electric);
  electric_set(&g_electric, LE_ELECTRIC_VOICES, 0.0f);
  for (int32_t n = 0; n < 3; ++n) CHECK(le_electric_note_on(&g_electric, 7, 60 + 4 * n, 100, 1) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_finite(l, N));
  /* Cut within the first block */
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, 16);
  le_electric_cut(&g_electric);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_finite(l, N) && opr_peak(l, N) == 0.0f);
  CHECK(le_electric_active(&g_electric) == 0 && le_electric_fading(&g_electric) == 0);
}

/* Voice counts, the same key again, sustain and Cut. */
static void test_electric_voices(void) {
  printf("test_electric_voices\n");
  enum { N = 4800 };
  static float l[N], r[N];
  /* two voices: a third note steals the oldest */
  electric_reference(&g_electric);
  electric_set(&g_electric, LE_ELECTRIC_VOICES, 0.0f);
  for (uint32_t o = 1; o <= 2; ++o) CHECK(le_electric_note_on(&g_electric, o, 60 + (int)o, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, 960); /* both struck */
  CHECK(le_electric_note_on(&g_electric, 3, 63, 100, 0) == 0);
  CHECK(le_electric_active(&g_electric) == 2);
  CHECK(le_electric_fading(&g_electric) == 1);
  CHECK(g_electric.stolen == 1);
  /* the same key again takes its own voice, fading it out first */
  electric_reference(&g_electric);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_render(&g_electric, l, r, N);
  CHECK(le_electric_note_on(&g_electric, 2, 60, 100, 0) == 0);
  CHECK(le_electric_active(&g_electric) == 1);
  /* it arrives on a block's edge: that block fades the ringing out, the
   * next one strikes */
  le_electric_render(&g_electric, l, r, 96);
  CHECK(opr_peak(l + 40, 8) < 0.25f * opr_peak(l, 8));
  CHECK(opr_peak(l + 48, 48) > 0.05f);
  le_electric_render(&g_electric, l, r, N);
  CHECK(opr_peak(l, N) > 0.05f);
  /* sustain holds a released key; Cut fades everything */
  electric_reference(&g_electric);
  CHECK(le_electric_sustain(&g_electric, 9, 1) == 0);
  CHECK(le_electric_note_on(&g_electric, 1, 60, 100, 0) == 0);
  le_electric_note_off(&g_electric, 1);
  CHECK(g_electric.voices[0].state == 3);
  CHECK(le_electric_held(&g_electric, 1) == 0);
  CHECK(le_electric_active(&g_electric) == 1);
  le_electric_cut(&g_electric);
  le_electric_render(&g_electric, l, r, N);
  CHECK(le_electric_active(&g_electric) == 0 && le_electric_fading(&g_electric) == 0);
}

/* Rendering in any block size gives the same samples. */
static void test_electric_block_size(void) {
  printf("test_electric_block_size\n");
  enum { N = 24000 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    electric_reference(&g_electric);
    electric_set(&g_electric, LE_ELECTRIC_RELEASE, 0.0f);
    electric_set(&g_electric, LE_ELECTRIC_DAMPER_AMOUNT, 1.0f);
    electric_set(&g_electric, LE_ELECTRIC_NOISE_AMOUNT, 0.8f);
    CHECK(le_electric_note_on(&g_electric, 1, 57, 100, 0) == 0);
    if (b < 0) {
      le_electric_render(&g_electric, ref_l, ref_r, 4000);
      le_electric_note_off(&g_electric, 1);
      le_electric_render(&g_electric, ref_l + 4000, ref_r + 4000, N - 4000);
      CHECK(le_electric_active(&g_electric) == 0); /* it ends inside the render */
      continue;
    }
    for (int32_t i = 0; i < N; i += blocks[b]) {
      if (i <= 4000 && i + blocks[b] > 4000) {
        /* the note-off at 4000, inside this block */
        le_electric_render(&g_electric, l + i, r + i, 4000 - i);
        le_electric_note_off(&g_electric, 1);
        const int32_t rest = N - 4000 < i + blocks[b] - 4000 ? N - 4000 : i + blocks[b] - 4000;
        le_electric_render(&g_electric, l + 4000, r + 4000, rest);
        continue;
      }
      const int32_t n = N - i < blocks[b] ? N - i : blocks[b];
      le_electric_render(&g_electric, l + i, r + i, n);
    }
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
  }
}

/* ---- the engine: a slot playing Electric ---- */

static void test_engine_electric_slot_matches_offline(void) {
  printf("test_engine_electric_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_ELECTRIC_PARAMS];
  for (int p = 0; p < LE_ELECTRIC_PARAMS; ++p) values[p] = le_electric_default(p);
  values[LE_ELECTRIC_DAMPER_AMOUNT] = 0.8f;
  values[LE_ELECTRIC_PICKUP_MODEL] = 1.0f;
  CHECK(le_electric_init(&g_electric, OPR_SR) == 0);
  le_electric_set_values(&g_electric, values);
  le_electric_set_voice_limit(&g_electric, 32); /* the engine's default limit */
  CHECK(le_electric_note_on(&g_electric, ins_origin(1), 57, 100, 0) == 0);
  le_electric_render(&g_electric, ref_l, ref_r, N);
  static const int32_t blocks[] = {48, 64, 1, 127, 512};
  for (int b = 0; b < 5; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_ELECTRIC, values) == LE_OK);
    /* the device's 1 ms blocks start with its first render, as the
     * reference's do */
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_ELECTRIC);
    CHECK(snap.instrument_voices[0] == 1);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

static void test_engine_electric_params_and_switching(void) {
  printf("test_engine_electric_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ELECTRIC, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_electric_active(eng_electric(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ELECTRIC_SEMITONE, 99.0f) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_electric(e, 1)->values[LE_ELECTRIC_SEMITONE] == 24.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ELECTRIC_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ELECTRIC_VOLUME, NAN) == LE_ERR_INVALID);
  /* Analog ends Electric */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ANALOG, NULL) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_ANALOG);
  CHECK(le_electric_active(eng_electric(e, 1)) == 0 && le_electric_fading(eng_electric(e, 1)) == 0);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_COLLISION + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_engine_electric_midi(void) {
  printf("test_engine_electric_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_ELECTRIC, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_electric_active(eng_electric(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_electric(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_electric(e, 2)->voices[0].state == 2); /* released, ringing out */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 4800, 64, 2, NULL, NULL);
  CHECK(le_electric_active(eng_electric(e, 2)) == 0 && le_electric_fading(eng_electric(e, 2)) == 0);
  le_engine_destroy(e);
}

static void run_electric_tests(void) {
  test_electric_strike();
  test_electric_extremes();
  test_electric_output_stage();
  test_electric_centred_noise_pitch();
  test_electric_before_the_strike();
  test_electric_voices();
  test_electric_block_size();
  test_engine_electric_slot_matches_offline();
  test_engine_electric_params_and_switching();
  test_engine_electric_midi();
}
