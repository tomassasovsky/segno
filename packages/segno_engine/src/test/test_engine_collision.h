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

/* Every sounding resonator is stable (each mode's poles inside the unit
 * circle, each waveguide losing energy a round trip) and its state finite;
 * the output is clamped, so this is where a blow-up would show. */
static int collision_stable(const le_collision* d) {
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    const le_collision_voice* v = &d->voices[i];
    if (v->state == 0) continue;
    for (int32_t r = 0; r < 2; ++r) {
      const le_collision_res* rs = &v->r[r];
      if (rs->kind == 1) {
        for (int32_t k = 0; k < rs->n; ++k) {
          if (!(fabsf(rs->a2[k]) < 1.0f) || !isfinite(rs->v1[k]) || !isfinite(rs->v2[k])) return 0;
        }
      } else if (rs->kind >= 2) {
        if (!(rs->loss < 1.0f)) return 0;
        for (int32_t k = 0; k < LE_COLLISION_PIPE; ++k) {
          if (!isfinite(rs->fw[k]) || !isfinite(rs->bw[k])) return 0;
        }
      }
    }
  }
  return 1;
}

/* Every control at its ends, on the keyboard's ends, at 44.1, 48 and
 * 96 kHz and at both velocity ends: finite and within the output's +-1,
 * every resonator stable. */
static void test_collision_extremes(void) {
  printf("test_collision_extremes\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const int32_t notes[3] = {0, 60, 127};
  static const int32_t rates[3] = {44100, OPR_SR, 96000};
  for (int32_t p = 0; p < LE_COLLISION_PARAMS; ++p) {
    for (int m = 0; m < 2; ++m) {
      for (int k = 0; k < 3; ++k) {
        CHECK(le_collision_init(&g_collision, rates[(p + k) % 3]) == 0);
        collision_set(&g_collision, LE_COLLISION_NOISE_ON, 1.0f);
        collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_ON), 1.0f);
        collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), (float)(p % 7));
        collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_TYPE), (float)((p / 7) % 6));
        collision_set(&g_collision, p, le_collision_clamp(p, m ? 1e9f : -1e9f));
        CHECK(le_collision_note_on(&g_collision, 1, notes[k], (p + m) % 2 ? 1 : 127, 0) == 0);
        le_collision_render(&g_collision, l, r, N);
        CHECK(opr_finite(l, N) && opr_finite(r, N));
        CHECK(opr_peak(l, N) <= 1.0f && opr_peak(r, N) <= 1.0f);
        CHECK(collision_stable(&g_collision));
        le_collision_note_off(&g_collision, 1);
        le_collision_render(&g_collision, l, r, N);
        CHECK(opr_finite(l, N) && opr_finite(r, N));
        CHECK(collision_stable(&g_collision));
      }
    }
  }
}

/* Renders until no voice is left, at most `seconds`; the seconds taken. */
static float collision_until_free(le_collision* d, float* l, float* r, int32_t n, float seconds) {
  int32_t k = 0;
  const int32_t limit = (int32_t)(seconds * (float)d->sample_rate / (float)n);
  while (k < limit && le_collision_active(d) > 0) {
    le_collision_render(d, l, r, n);
    k++;
  }
  return (float)k * (float)n / (float)d->sample_rate;
}

/* A released voice ends: with every decay route at its ends, the decays
 * at their longest and the off decay keeping them; when Noise is turned
 * off while it sounds. A short series pipe-into-pipe note sounds before
 * it ends. */
static void test_collision_voices_end(void) {
  printf("test_collision_voices_end\n");
  enum { N = 4800 };
  static float l[N], r[N];
  for (int32_t c = 0; c < 8; ++c) {
    collision_reference(&g_collision);
    const float s = c & 1 ? 1.0f : -1.0f;
    for (int32_t q = 0; q < 2; ++q) {
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_ON), 1.0f);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_TYPE), c & 2 ? 5.0f : (float)q * 2.0f);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_DECAY), 1.0f);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_OFF_DECAY), 0.0f);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_DECAY_VEL), 5.0f * s);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_DECAY_KEY), 2.0f * s);
      collision_set(&g_collision, LE_COLLISION_RES(q, LE_COLLISION_R_MATERIAL), c & 4 ? 1.0f : -1.0f);
    }
    collision_set(&g_collision, LE_COLLISION_STRUCTURE, (float)((c >> 2) & 1));
    CHECK(le_collision_note_on(&g_collision, 1, s > 0 ? 120 : 6, s > 0 ? 127 : 1, 0) == 0);
    le_collision_render(&g_collision, l, r, N);
    le_collision_note_off(&g_collision, 1);
    CHECK(collision_until_free(&g_collision, l, r, N, 200.0f) < 200.0f);
  }
  /* Noise turned off while the note sounds */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_NOISE_ON, 1.0f);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_OFF_DECAY), 1.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  collision_set(&g_collision, LE_COLLISION_NOISE_ON, 0.0f);
  le_collision_note_off(&g_collision, 1);
  CHECK(collision_until_free(&g_collision, l, r, N, 10.0f) < 10.0f);
  /* a pipe into a pipe, note 12, released at once: resonator 2 speaks
   * after both lines, and the voice lasts until it has */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), 5.0f);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_VOLUME), 0.0f);
  collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_ON), 1.0f);
  collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_TYPE), 5.0f);
  collision_set(&g_collision, LE_COLLISION_STRUCTURE, 0.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 12, 100, 0) == 0);
  le_collision_note_off(&g_collision, 1);
  le_collision_render(&g_collision, l, r, N);
  CHECK(opr_peak(l, N) > 0.01f);
}

/* The strike is the same whatever the slot played before: two earlier
 * notes of different lengths leave the LFO at different values, and the
 * next strike reads it at its start phase either way. The Hit
 * destination moves the hit. */
static void test_collision_matrix(void) {
  printf("test_collision_matrix\n");
  enum { N = 9600 };
  static float a_l[N], a_r[N], b_l[N], b_r[N];
  for (int32_t k = 0; k < 2; ++k) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_POLYPHONY, 0.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_ON), 1.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_TARGET1), (float)LE_COLLISION_D_STIFFNESS);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_AMOUNT1), 1.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_RATE), 1.0f);
    collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_SHAPE), 3.0f); /* saw: -1 at its start */
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_OFF_DECAY), 0.0f);
    CHECK(le_collision_note_on(&g_collision, 1, 48, 100, 0) == 0);
    le_collision_render(&g_collision, b_l, b_r, k ? 1234 : 3000);
    le_collision_note_off(&g_collision, 1);
    CHECK(collision_until_free(&g_collision, b_l, b_r, 480, 10.0f) < 10.0f);
    CHECK(le_collision_note_on(&g_collision, 2, 60, 100, 0) == 0);
    le_collision_render(&g_collision, k ? b_l : a_l, k ? b_r : a_r, N);
  }
  CHECK(opr_peak(a_l, N) > 0.01f);
  CHECK(memcmp(a_l, b_l, sizeof(a_l)) == 0);
  /* the wheel on Res 1 Hit: a string struck at its middle loses its even
   * partials; moved off the middle, the second comes back */
  double second[2];
  for (int32_t k = 0; k < 2; ++k) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_TYPE), 2.0f);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_HIT), 0.0f);
    collision_set(&g_collision, LE_COLLISION_WHEEL_TARGET1, (float)LE_COLLISION_D_R1_HIT);
    collision_set(&g_collision, LE_COLLISION_WHEEL_AMOUNT1, 0.2f);
    le_collision_expression(&g_collision, LE_SYNTH_MOD, (float)k);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    le_collision_render(&g_collision, a_l, a_r, N);
    second[k] = opr_component(a_l + 2400, 7200, 2.0 * opr_note_hz(60)) /
                opr_component(a_l + 2400, 7200, opr_note_hz(60));
  }
  CHECK(second[1] > 10.0 * second[0]);
}

/* The voice budget: a lower limit fades the oldest, fade_oldest fades one
 * note, release_matching lets go of the matching origins. */
static void test_collision_budget(void) {
  printf("test_collision_budget\n");
  enum { N = 480 };
  static float l[N], r[N];
  collision_reference(&g_collision);
  for (uint32_t o = 1; o <= 4; ++o) CHECK(le_collision_note_on(&g_collision, o, 60 + (int)o, 100, 0) == 0);
  CHECK(le_collision_active(&g_collision) == 4);
  le_collision_set_voice_limit(&g_collision, 2);
  CHECK(le_collision_active(&g_collision) == 2);
  CHECK(le_collision_fading(&g_collision) == 2);
  CHECK(le_collision_held(&g_collision, 4) == 1);
  CHECK(le_collision_fade_oldest(&g_collision) == 1);
  CHECK(le_collision_active(&g_collision) == 1);
  le_collision_render(&g_collision, l, r, N);
  CHECK(le_collision_fading(&g_collision) == 0);
  le_collision_release_matching(&g_collision, 0xffu, 4u);
  CHECK(le_collision_held(&g_collision, 4) == 0);
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
  /* the third note restarts the oldest note's own voice */
  CHECK(le_collision_active(&g_collision) == 2);
  CHECK(le_collision_fading(&g_collision) == 0);
  CHECK(g_collision.stolen == 1);
  CHECK(le_collision_held(&g_collision, 1) == 0 && le_collision_held(&g_collision, 3) == 1);
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
  /* a new note takes a slot never played before an ended one; Retrigger
   * (Smart) takes the ended slot that last played the same key */
  for (int32_t smart = 0; smart < 2; ++smart) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_DECAY), 0.0f);
    collision_set(&g_collision, LE_COLLISION_RETRIGGER, (float)smart);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    le_collision_note_off(&g_collision, 1);
    for (int k = 0; k < 10; ++k) le_collision_render(&g_collision, l, r, N);
    CHECK(le_collision_active(&g_collision) == 0);
    CHECK(le_collision_note_on(&g_collision, 2, 60, 100, 0) == 0);
    CHECK((g_collision.voices[0].state != 0) == smart && (g_collision.voices[1].state != 0) == !smart);
  }
  /* a Random LFO on Res 1 Pan starts a fresh voice off centre: its ramp
   * begins at a value the voice already holds, not at 0 */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_ON), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_SHAPE), 6.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_RATE), 0.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_DEPTH), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_TARGET1), (float)LE_COLLISION_D_R1_PAN);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_AMOUNT1), 1.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  {
    const double pl = opr_peak(l + 2400, 2400), pr = opr_peak(r + 2400, 2400);
    CHECK(pl > 1.05 * pr || pr > 1.05 * pl);
  }
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

/* What the fits against Live pinned: Off Decay 1 cuts a released note to
 * 50 ms and 0 leaves it ringing; a note that would pass full scale is
 * limited to peaks of exactly 1, not clipped; the synced LFO's fifth length
 * is two whole notes (a quarter of a hertz at 120 bpm). */
static void test_collision_fits(void) {
  printf("test_collision_fits\n");
  enum { N = 9600 };
  static float l[N], r[N];
  double tail[2];
  for (int32_t k = 0; k < 2; ++k) {
    collision_reference(&g_collision);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_DECAY), 1.0f);
    collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_OFF_DECAY), (float)k);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    le_collision_render(&g_collision, l, r, N);
    le_collision_note_off(&g_collision, 1);
    le_collision_render(&g_collision, l, r, N); /* 200 ms after the release */
    tail[k] = opr_peak(l + N - 480, 480);
  }
  CHECK(tail[0] > 0.05 && tail[1] < 1e-4);
  /* the limiter: a loud strike into a series string peaks at exactly 1 */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_MALLET_VOLUME, 1.0f);
  collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_ON), 1.0f);
  collision_set(&g_collision, LE_COLLISION_RES(1, LE_COLLISION_R_TYPE), 2.0f);
  collision_set(&g_collision, LE_COLLISION_STRUCTURE, 0.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 127, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  const float pk = opr_peak(l, N);
  int32_t flat = 0;
  for (int32_t i = 0; i < N; ++i) flat += fabsf(l[i]) > 0.999f;
  CHECK(pk <= 1.0f && pk > 0.99f && flat < N / 20);
  /* the limiter looks 1 ms ahead: the output starts 16 samples plus that
   * after the strike; a quiet note through it comes out unchanged */
  CHECK(le_collision_latency(&g_collision) == 48);
  collision_reference(&g_collision);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N);
  int32_t first = 0;
  while (first < N && l[first] == 0.0f) first++;
  CHECK(first == 16 + 48);
  /* a loud strike's gain falls before its peaks and rises back fast to
   * within 0.79 dB, then slowly: 25 ms after the strike of a short beam the
   * output is still 0.5 to 1 dB below the quiet strike scaled up */
  {
    static float ql[N], qr[N];
    for (int32_t k = 0; k < 2; ++k) {
      collision_reference(&g_collision);
      collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_DECAY), 0.0f);
      if (k) collision_set(&g_collision, LE_COLLISION_MALLET_VOLUME, 1.0f);
      CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
      le_collision_render(&g_collision, k ? l : ql, k ? r : qr, N);
    }
    /* the strike's force: Exp(0.001, 1), 1 at full and 0.001 * 1000^(64/127) at half */
    const double scale = 1.0 / (0.001 * pow(1000.0, 64.0 / 127.0));
    double el = 0.0, eq = 0.0;
    for (int32_t i = 1200; i < 1248; ++i) el += (double)l[i] * l[i], eq += (double)ql[i] * ql[i];
    const double db = 10.0 * log10(el / (eq * scale * scale));
    CHECK(db < -0.5 && db > -1.0);
  }
  /* the synced LFO on Res 1 Pan: index 4 swings once in 4 s */
  collision_reference(&g_collision);
  collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_DECAY), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_ON), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_SYNC), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_SYNC_RATE), 4.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_DEPTH), 1.0f);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_TARGET1), (float)LE_COLLISION_D_R1_PAN);
  collision_set(&g_collision, LE_COLLISION_LFO(0, LE_COLLISION_L_AMOUNT1), 1.0f);
  le_collision_set_tempo(&g_collision, 120.0f);
  CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
  le_collision_render(&g_collision, l, r, N); /* 0.2 s: a fifth of the way up */
  const double left = opr_peak(l + N - 480, 480), right = opr_peak(r + N - 480, 480);
  CHECK(right > 1.2 * left && right < 4.0 * left);
  /* a held note ends once it has decayed to about -94 dBFS: the
   * reference beam (T 1.36 s) within 2 s, a 35 s one not */
  for (int32_t k = 0; k < 2; ++k) {
    collision_reference(&g_collision);
    if (k) collision_set(&g_collision, LE_COLLISION_RES(0, LE_COLLISION_R_DECAY), 1.0f);
    CHECK(le_collision_note_on(&g_collision, 1, 60, 100, 0) == 0);
    for (int32_t b = 0; b < 10; ++b) le_collision_render(&g_collision, l, r, N);
    CHECK(le_collision_active(&g_collision) == k);
  }
}

static void run_collision_tests(void) {
  test_collision_types();
  test_collision_extremes();
  test_collision_voices_end();
  test_collision_fits();
  test_collision_matrix();
  test_collision_budget();
  test_collision_voices();
  test_collision_block_size();
  test_engine_collision_slot_matches_offline();
  test_engine_collision_params_and_switching();
  test_engine_collision_midi();
}
