/* SEG-109: the Tension device. Its own module first (tension_voice.c,
 * driven directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_electric.h (opr_* helpers,
 * drift_run, the ins_* helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these
 * with the instrument tests. */

#include "tension_voice.h"

/* Slot k's Tension instance in engine e. */
static le_tension* eng_tension(le_engine* e, int32_t k) {
  return (le_tension*)le_instruments_device(e, LE_INST_DEVICE_TENSION, k);
}

static le_tension g_tension;

static void tension_reference(le_tension* d) {
  CHECK(le_tension_init(d, OPR_SR) == 0);
  le_tension_set_voice_limit(d, LE_TENSION_VOICE_SLOTS);
}

/* Sets one parameter, the others as they are. */
static void tension_set(le_tension* d, int32_t p, float v) {
  static float vals[LE_TENSION_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_tension_set_values(d, vals);
}

/* Renders until the device is silent (voices and body), at most `limit`
 * blocks of n. Returns the blocks it took. */
static int32_t tension_until_silent(le_tension* d, float* l, float* r, int32_t n, int32_t limit) {
  int32_t k = 0;
  while (k < limit && (le_tension_active(d) > 0 || le_tension_fading(d) > 0)) {
    le_tension_render(d, l, r, n);
    k++;
  }
  return k;
}

/* Each exciter sounds at the note's pitch, mono; the hammer, bouncing
 * hammer and plectrum ring out while held, the bow keeps sounding until
 * the key is let go; every one then ends. */
static void test_tension_exciters(void) {
  printf("test_tension_exciters\n");
  enum { N = 48000 };
  static float l[N], r[N];
  for (int32_t type = 0; type < 4; ++type) {
    tension_reference(&g_tension);
    tension_set(&g_tension, LE_TENSION_EXC_TYPE, (float)type);
    tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
    CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
    le_tension_render(&g_tension, l, r, N);
    CHECK(opr_finite(l, N));
    CHECK(memcmp(l, r, sizeof(l)) == 0);
    CHECK(opr_peak(l, N) > 0.05f);
    CHECK(opr_component(l + 2400, 9600, opr_note_hz(60)) >
          10.0 * opr_component(l + 2400, 9600, 1.5 * opr_note_hz(60)));
    if (type == 0) {
      CHECK(opr_peak(l + N - 4800, 4800) > 0.05f); /* bowed on */
    } else {
      CHECK(opr_peak(l + N - 4800, 4800) < 0.1f * opr_peak(l, N)); /* rung out */
    }
    le_tension_note_off(&g_tension, 1);
    CHECK(tension_until_silent(&g_tension, l, r, 4800, 100) < 100);
  }
  /* the string is in tune across the keyboard (the hammer) */
  for (int32_t note = 36; note <= 96; note += 12) {
    tension_reference(&g_tension);
    tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
    CHECK(le_tension_note_on(&g_tension, 1, note, 100, 0) == 0);
    le_tension_render(&g_tension, l, r, N);
    const double f = opr_note_hz(note);
    const double c0 = opr_component(l + 4800, 24000, f);
    CHECK(c0 > opr_component(l + 4800, 24000, f * pow(2.0, 10.0 / 1200.0)));
    CHECK(c0 > opr_component(l + 4800, 24000, f * pow(2.0, -10.0 / 1200.0)));
  }
}

/* Every control at its ends on the keyboard's ends, with every exciter,
 * the damper and the termination on: finite, and no louder than a string
 * struck at the fastest hammer speed rings (the string is linear, so the
 * fastest strikes are loud, about +47 dB at worst). */
static void test_tension_extremes(void) {
  printf("test_tension_extremes\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const int32_t notes[3] = {0, 60, 127};
  for (int32_t p = 0; p < LE_TENSION_PARAMS; ++p) {
    for (int32_t type = 0; type < 4; ++type) {
      if (p == LE_TENSION_EXC_TYPE && type > 0) continue;
      for (int m = 0; m < 2; ++m) {
        for (int k = 0; k < 3; ++k) {
          tension_reference(&g_tension);
          tension_set(&g_tension, LE_TENSION_EXC_TYPE, (float)type);
          tension_set(&g_tension, LE_TENSION_DAMPER_ON, 1.0f);
          tension_set(&g_tension, LE_TENSION_TERM_ON, 1.0f);
          tension_set(&g_tension, p, le_tension_clamp(p, m ? 1e9f : -1e9f));
          CHECK(le_tension_note_on(&g_tension, 1, notes[k], k == 1 ? 1 : 127, 0) == 0);
          le_tension_render(&g_tension, l, r, N);
          CHECK(opr_finite(l, N) && opr_finite(r, N));
          CHECK(opr_peak(l, N) < 1000.0f && opr_peak(r, N) < 1000.0f);
          le_tension_note_off(&g_tension, 1);
          le_tension_render(&g_tension, l, r, N);
          CHECK(opr_finite(l, N) && opr_peak(l, N) < 1000.0f);
        }
      }
    }
  }
}

/* Keyboard Stretch scales the key about A4: at full (1.008 times) C2 sounds
 * 26 cents flat. The fastest hammer's strike bends softly toward the
 * output's full scale of 4 and never passes it. The body's first line
 * answers the string 210 samples later at 48 kHz (type 0, size 1: its
 * all-pass side, 257 - 47), never sooner. */
static void test_tension_stretch_clip_body(void) {
  printf("test_tension_stretch_clip_body\n");
  enum { N = 48000 };
  static float l[N], r[N], dry[N];
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
  tension_set(&g_tension, LE_TENSION_STRETCH, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 36, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  const double f = opr_note_hz(36);
  CHECK(opr_component(l + 4800, 24000, f * pow(2.0, -26.4 / 1200.0)) > opr_component(l + 4800, 24000, f));
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
  tension_set(&g_tension, LE_TENSION_EXC_VEL, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 127, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  CHECK(opr_peak(l, N) <= 4.0f && opr_peak(l, N) > 3.5f);
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, dry, r, 4800);
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 1.0f);
  tension_set(&g_tension, LE_TENSION_BODY_MIX, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, 4800);
  int32_t a = 0, b = 0;
  while (a < 4800 && fabsf(dry[a]) < 1e-4f) a++;
  while (b < 4800 && fabsf(l[b]) < 1e-4f) b++;
  CHECK(b - a >= 209 && b - a <= 214);
}

/* A hammer driven on into the string stays on it and damps it, as Live's
 * does (Slap Bass's hard C5): 100 ms after the strike the string is 15 dB
 * under its first 10 ms (a hammer let go while it pressed left the string
 * ringing at full). A light finger on a stiff fret keeps the string
 * ringing at its pitch. */
static void test_tension_hammer_on_string(void) {
  printf("test_tension_hammer_on_string\n");
  enum { N = 9600 };
  static float l[N], r[N];
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
  tension_set(&g_tension, LE_TENSION_EXC_X, 1.0f);
  tension_set(&g_tension, LE_TENSION_EXC_VEL, 0.703125f);
  tension_set(&g_tension, LE_TENSION_EXC_VEL_VEL, 0.7619048f);
  tension_set(&g_tension, LE_TENSION_EXC_STIFF, 0.5317460f);
  tension_set(&g_tension, LE_TENSION_EXC_STIFF_KEY, 0.46875f);
  tension_set(&g_tension, LE_TENSION_EXC_STIFF_VEL, 0.46875f);
  tension_set(&g_tension, LE_TENSION_EXC_DAMPING, 0.40625f);
  CHECK(le_tension_note_on(&g_tension, 1, 72, 127, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  CHECK(opr_finite(l, N));
  CHECK(opr_peak(l + 4800, 480) < 0.18f * opr_peak(l, 480));
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 0.0f);
  tension_set(&g_tension, LE_TENSION_TERM_ON, 1.0f);
  tension_set(&g_tension, LE_TENSION_TERM_FINGER_STIFF, 0.0f);
  tension_set(&g_tension, LE_TENSION_TERM_FINGER_FORCE, 0.1953125f);
  tension_set(&g_tension, LE_TENSION_TERM_FRET_STIFF, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  CHECK(opr_finite(l, N));
  const double f = opr_note_hz(60);
  CHECK(opr_component(l + 2400, 7200, f) > 3.0 * opr_component(l + 2400, 7200, 1.5 * f));
}

/* The body rings on after the last string and is reported fading while it
 * does; then it ends, and the device is silent. */
static void test_tension_body_tail(void) {
  printf("test_tension_body_tail\n");
  enum { N = 4800 };
  static float l[N], r[N];
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_BODY_ON, 1.0f);
  tension_set(&g_tension, LE_TENSION_BODY_MIX, 1.0f);
  tension_set(&g_tension, LE_TENSION_BODY_DECAY, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  le_tension_cut(&g_tension);
  le_tension_render(&g_tension, l, r, N); /* the strings end */
  CHECK(le_tension_active(&g_tension) == 0);
  CHECK(le_tension_fading(&g_tension) == 1); /* the body alone */
  CHECK(opr_peak(l + N / 2, N / 2) > 0.0f);
  CHECK(tension_until_silent(&g_tension, l, r, N, 100) < 100);
  le_tension_render(&g_tension, l, r, N);
  CHECK(opr_peak(l, N) == 0.0f && opr_peak(r, N) == 0.0f);
}

/* Voice counts, unison, the same key again, sustain and Cut. */
static void test_tension_voices(void) {
  printf("test_tension_voices\n");
  enum { N = 4800 };
  static float l[N], r[N];
  /* two voices: a third note steals the oldest */
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_POLYPHONY, 1.0f);
  for (uint32_t o = 1; o <= 3; ++o) CHECK(le_tension_note_on(&g_tension, o, 60 + (int)o, 100, 0) == 0);
  CHECK(le_tension_active(&g_tension) == 2);
  CHECK(g_tension.stolen == 1);
  /* four unison strings a note, each a voice of the budget */
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_UNISON_ON, 1.0f);
  tension_set(&g_tension, LE_TENSION_UNISON, 1.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  CHECK(le_tension_active(&g_tension) == 4);
  CHECK(le_tension_fade_oldest(&g_tension) == 4);
  /* a unison copy, started its delay after the key, lets go its delay
   * after it too */
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_UNISON_ON, 1.0f);
  tension_set(&g_tension, LE_TENSION_UNISON_DELAY, 0.5f);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  le_tension_note_off(&g_tension, 1);
  {
    le_tension_voice* c1 = NULL;
    for (int32_t i = 0; i < LE_TENSION_VOICE_SLOTS; ++i) {
      if (g_tension.voices[i].copy == 1) c1 = &g_tension.voices[i];
    }
    CHECK(c1 != NULL && c1->delay > 100 && c1->off_wait == c1->delay);
    if (c1 != NULL) {
      const int32_t wait = c1->delay;
      le_tension_render(&g_tension, l, r, wait - 10);
      CHECK(c1->off_wait == 10 && c1->fenv.seg != LE_AAS_SEG_RELEASE);
      le_tension_render(&g_tension, l, r, 20);
      CHECK(c1->off_wait == 0 && c1->state == 2); /* released */
    }
  }
  /* the same key again strikes its sounding string */
  tension_reference(&g_tension);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_render(&g_tension, l, r, N);
  CHECK(le_tension_note_on(&g_tension, 2, 60, 100, 0) == 0);
  CHECK(le_tension_active(&g_tension) == 1);
  le_tension_render(&g_tension, l, r, N);
  CHECK(opr_finite(l, N) && opr_peak(l, N) > 0.05f);
  /* mono: a second key moves the string */
  tension_reference(&g_tension);
  tension_set(&g_tension, LE_TENSION_POLYPHONY, 0.0f);
  CHECK(le_tension_note_on(&g_tension, 1, 48, 100, 0) == 0);
  CHECK(le_tension_note_on(&g_tension, 2, 60, 100, 0) == 0);
  CHECK(le_tension_active(&g_tension) == 1);
  /* sustain holds a released key; Cut ends everything, the body's tail too */
  tension_reference(&g_tension);
  CHECK(le_tension_sustain(&g_tension, 9, 1) == 0);
  CHECK(le_tension_note_on(&g_tension, 1, 60, 100, 0) == 0);
  le_tension_note_off(&g_tension, 1);
  CHECK(g_tension.voices[0].state == 3);
  CHECK(le_tension_held(&g_tension, 1) == 0);
  le_tension_render(&g_tension, l, r, N);
  le_tension_cut(&g_tension);
  CHECK(tension_until_silent(&g_tension, l, r, N, 100) < 100);
}

/* Rendering in any block size gives the same samples: a strike, a
 * release inside a block, a stolen note, bend, vibrato, glide and a knob
 * moved while sounding. */
static void tension_play(le_tension* d, float* l, float* r, int32_t n, int32_t block) {
  static const int32_t at[2] = {4000, 6000};
  int32_t i = 0, ev = 0;
  while (i < n) {
    int32_t m = n - i < block ? n - i : block;
    if (ev < 2 && i + m > at[ev]) m = at[ev] - i;
    if (m > 0) le_tension_render(d, l + i, r + i, m);
    i += m;
    if (ev < 2 && i == at[ev]) {
      if (ev == 0) {
        CHECK(le_tension_note_on(d, 2, 64, 100, 0) == 0);
        le_tension_expression(d, LE_SYNTH_BEND, 0.5f);
        tension_set(d, LE_TENSION_BODY_LEVEL, 0.3f);
      } else {
        le_tension_note_off(d, 2);
      }
      ev++;
    }
  }
}

static void test_tension_block_size(void) {
  printf("test_tension_block_size\n");
  enum { N = 12000 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    tension_reference(&g_tension);
    tension_set(&g_tension, LE_TENSION_POLYPHONY, 1.0f);
    tension_set(&g_tension, LE_TENSION_UNISON_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_UNISON_DELAY, 0.4f);
    tension_set(&g_tension, LE_TENSION_FILTER_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_LFO_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_FILTER_LFO_CUTOFF, 0.5f);
    tension_set(&g_tension, LE_TENSION_DAMPER_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_VIBRATO_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_VIBRATO_AMOUNT, 0.5f);
    tension_set(&g_tension, LE_TENSION_GLIDE_ON, 1.0f);
    tension_set(&g_tension, LE_TENSION_GLIDE_TIME, 0.4f);
    le_tension_set_voice_limit(&g_tension, 2); /* one two-string note */
    CHECK(le_tension_note_on(&g_tension, 1, 57, 100, 0) == 0);
    tension_play(&g_tension, b < 0 ? ref_l : l, b < 0 ? ref_r : r, N, b < 0 ? N : blocks[b]);
    if (b < 0) {
      CHECK(g_tension.stolen == 1);
      continue;
    }
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
  }
}

/* ---- the engine: a slot playing Tension ---- */

static void test_engine_tension_slot_matches_offline(void) {
  printf("test_engine_tension_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_TENSION_PARAMS];
  for (int p = 0; p < LE_TENSION_PARAMS; ++p) values[p] = le_tension_default(p);
  values[LE_TENSION_EXC_TYPE] = 3.0f;
  values[LE_TENSION_PICKUP_ON] = 1.0f;
  CHECK(le_tension_init(&g_tension, OPR_SR) == 0);
  le_tension_set_values(&g_tension, values);
  le_tension_set_voice_limit(&g_tension, 32); /* the engine's default limit */
  CHECK(le_tension_note_on(&g_tension, ins_origin(1), 57, 100, 0) == 0);
  le_tension_render(&g_tension, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_TENSION, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_TENSION);
    CHECK(snap.instrument_voices[0] == 1);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

static void test_engine_tension_params_and_switching(void) {
  printf("test_engine_tension_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_TENSION, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_tension_active(eng_tension(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_TENSION_EXC_TYPE, 99.0f) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_tension(e, 1)->values[LE_TENSION_EXC_TYPE] == 3.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_TENSION_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_TENSION_BODY_LEVEL, NAN) == LE_ERR_INVALID);
  /* Electric ends Tension */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ELECTRIC, NULL) == LE_OK);
  drift_run(e, 48000, 512, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_ELECTRIC);
  CHECK(le_tension_active(eng_tension(e, 1)) == 0 && le_tension_fading(eng_tension(e, 1)) == 0);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_TENSION + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_engine_tension_midi(void) {
  printf("test_engine_tension_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_TENSION, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_tension_active(eng_tension(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_tension(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_tension(e, 2)->voices[0].state == 2); /* released, ringing out */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 48000, 512, 2, NULL, NULL);
  CHECK(le_tension_active(eng_tension(e, 2)) == 0 && le_tension_fading(eng_tension(e, 2)) == 0);
  le_engine_destroy(e);
}

static void run_tension_tests(void) {
  test_tension_exciters();
  test_tension_extremes();
  test_tension_stretch_clip_body();
  test_tension_body_tail();
  test_tension_hammer_on_string();
  test_tension_voices();
  test_tension_block_size();
  test_engine_tension_slot_matches_offline();
  test_engine_tension_params_and_switching();
  test_engine_tension_midi();
}
