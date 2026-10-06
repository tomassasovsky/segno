/* Instrument slots in the engine (#1197 Part 2a): the synth inside
 * le_engine_process, the ordered note rings with the reserved release lane,
 * Cut, the voice limit, the synth epoch. Literal PCM through
 * le_engine_process against offline le_synth renders. Included from
 * test_engine_core.c after test_engine_synth.h (which defines g_syn_a/b and
 * syn_patch); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs only these. */

#include "engine_instruments.h"

#define INS_SR 48000

static le_engine* ins_engine(int32_t sr) {
  le_engine* e = le_engine_create();
  CHECK(e != NULL);
  CHECK(le_engine_configure(e, sr, 2, 2, sr * 4) == LE_OK);
  return e;
}

/* Processes `frames` in blocks of `block`, appending each block's bus of
 * `slot` to `out` (NULL: discarded). */
static void ins_run(le_engine* e, int32_t frames, int32_t block, int32_t slot,
                    float* out) {
  static float in[2 * 9000], o[2 * 9000];
  memset(in, 0, sizeof(in));
  int32_t done = 0;
  while (done < frames) {
    int32_t n = frames - done;
    if (n > block) n = block;
    le_engine_process(e, o, in, (uint32_t)n);
    if (out != NULL) memcpy(out + done, le_instrument_bus(e, slot), sizeof(float) * (size_t)n);
    done += n;
  }
}

/* The engine's synth configuration, offline. */
static void ins_offline(le_synth* s, int32_t sr) {
  le_synth_init(s, sr, LE_SYNTH_MAX_VOICES, LE_INST_SYNTH_SEED);
  le_synth_set_voice_limit(s, 32);
}

static void test_instrument_bus_matches_offline_render(void) {
  printf("test_instrument_bus_matches_offline_render\n");
  const int32_t n = 9600;
  float* ref = (float*)calloc((size_t)n, sizeof(float));
  float* got = (float*)calloc((size_t)n, sizeof(float));
  ins_offline(&g_syn_a, INS_SR);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("pad"));
  le_synth_note_on(&g_syn_a, 0, 1, 60, 100);
  le_synth_note_on(&g_syn_a, 0, 2, 67, 90);
  float* r[1] = {ref};
  syn_render(&g_syn_a, r, 1, n, 64);
  CHECK(syn_peak(ref, n) > 0.01f);
  static const int32_t blocks[] = {1, 64, 127, 512};
  for (int k = 0; k < 4; ++k) {
    le_engine* e = ins_engine(INS_SR);
    ins_run(e, 640, 64, 0, NULL); /* silent blocks first: no render, no cost */
    CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 60, 100) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 2, 67, 90) == LE_OK);
    memset(got, 0, sizeof(float) * (size_t)n);
    ins_run(e, n, blocks[k], 0, got);
    CHECK(memcmp(ref, got, sizeof(float) * (size_t)n) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_patch[0] == syn_patch("pad"));
    CHECK(snap.instrument_patch[1] == -1);
    CHECK(snap.instrument_voices[0] == 2);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    CHECK(snap.voice_limit == 32);
    le_engine_destroy(e);
  }
  free(ref);
  free(got);
}

/* Custom parameters given with the patch reach the first note. */
static void test_instrument_params_reach_first_note(void) {
  printf("test_instrument_params_reach_first_note\n");
  const int32_t n = 4800;
  float* ref = (float*)calloc((size_t)n, sizeof(float));
  float* got = (float*)calloc((size_t)n, sizeof(float));
  ins_offline(&g_syn_a, INS_SR);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("lead"));
  le_synth_set_param(&g_syn_a, 0, 0, 5.0f);
  le_synth_set_param(&g_syn_a, 0, 1, 40.0f);
  le_synth_note_on(&g_syn_a, 0, 1, 72, 110);
  float* r[1] = {ref};
  syn_render(&g_syn_a, r, 1, n, 64);
  le_engine* e = ins_engine(INS_SR);
  const float params[3] = {5.0f, 40.0f, 25.0f};
  CHECK(le_engine_set_instrument(e, 0, syn_patch("lead"), params) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 72, 110) == LE_OK);
  ins_run(e, n, 64, 0, got);
  CHECK(memcmp(ref, got, sizeof(float) * (size_t)n) == 0);
  /* a later parameter change applies from the next block */
  CHECK(le_engine_set_instrument_param(e, 0, 0, 100.0f) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(((le_synth*)e->synth)->inst[0].params[0] == 100.0f);
  le_engine_destroy(e);
  free(ref);
  free(got);
}

/* A note-on and its note-off posted before one block apply in that order,
 * so the note ends; releases ride their own lane and are never refused when
 * note-ons fill theirs. */
static void test_instrument_rings_order_and_release_lane(void) {
  printf("test_instrument_rings_order_and_release_lane\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  CHECK(le_engine_set_instrument(e, 0, syn_patch("sub"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 7, 50, 100) == LE_OK);
  CHECK(le_engine_instrument_note_off(e, 7) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_synth_active(s, 0) == 1); /* releasing, not held */
  ins_run(e, 38400 + 128, 64, 0, NULL); /* sub's 0.80 s release */
  CHECK(!le_synth_has_origin(s, 7));
  CHECK(le_synth_active(s, 0) == 0);

  /* 300 note-ons: 255 fit (one slot kept empty), 45 are refused and counted;
   * the release of the first is still accepted and applied */
  int ok = 0, full = 0;
  for (uint32_t o = 1; o <= 300; ++o) {
    const int32_t rc = le_engine_instrument_note_on(e, 0, 1000 + o, 30 + (int32_t)(o % 60), 100);
    if (rc == LE_OK) ok++;
    if (rc == LE_ERR_CAPACITY) full++;
  }
  CHECK(ok == 255 && full == 45);
  CHECK(le_engine_instrument_note_off(e, 1001) == LE_OK);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_events_refused == 45);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_synth_active(s, -1) == 32); /* the voice limit holds the rest */
  CHECK(!le_synth_has_origin(s, 1001)); /* stolen or released, never held */
  ins_run(e, 38400 + 128, 64, 0, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.voices_stolen > 0);

  /* the release lane holds 1023 */
  int lane = 0;
  for (uint32_t o = 1; o <= 1024; ++o) {
    if (le_engine_instrument_note_off(e, o) == LE_OK) lane++;
  }
  CHECK(lane == 1023);
  CHECK(le_engine_instrument_note_off(e, 5) == LE_ERR_CAPACITY);
  ins_run(e, 64, 64, 0, NULL);
  ins_run(e, 64, 64, 0, NULL);
  ins_run(e, 64, 64, 0, NULL); /* 512 per block: drained in order */
  CHECK(le_engine_instrument_note_off(e, 5) == LE_OK);
  le_engine_destroy(e);
}

static void test_instrument_cut_limit_and_isolation(void) {
  printf("test_instrument_cut_limit_and_isolation\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  CHECK(le_engine_set_instrument(e, 0, syn_patch("organ"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("sub"), NULL) == LE_OK);
  for (uint32_t o = 1; o <= 16; ++o) le_engine_instrument_note_on(e, 0, o, 48 + (int32_t)o, 100);
  le_engine_instrument_note_on(e, 1, 100, 40, 100);
  ins_run(e, 960, 64, 0, NULL);
  /* the voice limit fades the excess oldest-first */
  CHECK(le_engine_set_voice_limit(e, 8) == LE_OK);
  CHECK(le_engine_set_voice_limit(e, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_voice_limit(e, 65) == LE_ERR_INVALID);
  ins_run(e, 64, 64, 0, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.voice_limit == 8);
  CHECK(snap.instrument_voices[0] + snap.instrument_voices[1] == 8);
  CHECK(snap.instrument_voices[1] == 1); /* the oldest are slot 0's */
  /* Cut all sound: every bus exactly zero 144 frames into the next block */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  float b0[256], b1[256];
  ins_run(e, 256, 256, 0, b0);
  memcpy(b1, le_instrument_bus(e, 1), sizeof(b1));
  CHECK(syn_peak(b0, 144) > 0.0f);
  int silent = 1;
  for (int i = 144; i < 256; ++i) silent &= b0[i] == 0.0f && b1[i] == 0.0f;
  CHECK(silent);
  CHECK(le_synth_active(s, -1) == 0);
  ins_run(e, 64, 64, 0, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_peaks[0] == 0.0f && snap.instrument_peaks[1] == 0.0f);
  le_engine_destroy(e);
}

/* A patch change fades only that slot: the other slot's bus is exactly its
 * solo render. */
static void test_instrument_patch_change_isolated(void) {
  printf("test_instrument_patch_change_isolated\n");
  const int32_t n = 4800;
  float* ref = (float*)calloc((size_t)n, sizeof(float));
  float* got = (float*)calloc((size_t)n, sizeof(float));
  ins_offline(&g_syn_b, INS_SR);
  le_synth_set_instrument(&g_syn_b, 1, syn_patch("sub"));
  g_syn_b.serial++; /* slot 0's note was struck first in the engine */
  le_synth_note_on(&g_syn_b, 1, 100, 40, 100);
  float* r[2] = {NULL, ref};
  syn_render(&g_syn_b, r, 2, n, 64);
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("keys"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("sub"), NULL) == LE_OK);
  le_engine_instrument_note_on(e, 0, 1, 60, 100);
  le_engine_instrument_note_on(e, 1, 100, 40, 100);
  ins_run(e, 960, 64, 1, got);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("piano"), NULL) == LE_OK);
  ins_run(e, n - 960, 64, 1, got + 960);
  CHECK(memcmp(ref, got, sizeof(float) * (size_t)n) == 0);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_patch[0] == syn_patch("piano"));
  CHECK(snap.instrument_voices[0] == 0);
  CHECK(((le_synth*)e->synth)->inst[0].params[0] == 68.0f); /* piano defaults */
  le_engine_destroy(e);
  free(ref);
  free(got);
}

static void test_instrument_refusals(void) {
  printf("test_instrument_refusals\n");
  le_engine* raw = le_engine_create();
  CHECK(le_engine_set_instrument(raw, 0, 0, NULL) == LE_ERR_NOT_RUNNING);
  CHECK(le_engine_instrument_note_on(raw, 0, 1, 60, 100) == LE_ERR_NOT_RUNNING);
  CHECK(le_engine_instrument_note_off(raw, 1) == LE_ERR_NOT_RUNNING);
  le_engine_destroy(raw);
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument(e, 0, 19, NULL) == LE_ERR_UNKNOWN_PATCH);
  CHECK(le_engine_set_instrument(e, 8, 0, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument(e, 0, -2, NULL) == LE_ERR_INVALID);
  const float bad[3] = {NAN, 0.0f, 0.0f};
  CHECK(le_engine_set_instrument(e, 0, 0, bad) == LE_ERR_INVALID);
  CHECK(le_engine_instrument_note_on(e, 2, 1, 60, 100) == LE_ERR_NO_INSTRUMENT);
  CHECK(le_engine_set_instrument_param(e, 2, 0, 50.0f) == LE_ERR_NO_INSTRUMENT);
  CHECK(le_engine_set_instrument(e, 2, 0, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 1, 128, 100) == LE_ERR_INVALID);
  CHECK(le_engine_instrument_note_on(e, 2, 1, 60, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_param(e, 2, 3, 50.0f) == LE_ERR_INVALID);
  CHECK(le_engine_reset_instrument(e, 8) == LE_ERR_INVALID);
  /* a patch change refused by a full note ring changes nothing: the slot
   * keeps its patch and its parameters */
  const float mine[3] = {11.0f, 22.0f, 33.0f};
  CHECK(le_engine_set_instrument(e, 3, syn_patch("keys"), mine) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  for (uint32_t o = 1; o <= 255; ++o) {
    CHECK(le_engine_instrument_note_on(e, 3, o, 40 + (int32_t)(o % 40), 100) == LE_OK);
  }
  const float other[3] = {90.0f, 90.0f, 90.0f};
  CHECK(le_engine_set_instrument(e, 3, syn_patch("lead"), other) == LE_ERR_CAPACITY);
  CHECK(le_engine_set_instrument_param(e, 3, 2, 44.0f) == LE_OK); /* still keys */
  ins_run(e, 64, 64, 0, NULL);
  le_synth* s = (le_synth*)e->synth;
  CHECK(s->inst[3].patch == syn_patch("keys"));
  CHECK(s->inst[3].params[0] == 11.0f && s->inst[3].params[1] == 22.0f &&
        s->inst[3].params[2] == 44.0f);
  /* removing the patch: notes are refused again */
  CHECK(le_engine_set_instrument(e, 2, -1, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 1, 60, 100) == LE_ERR_NO_INSTRUMENT);
  ins_run(e, 64, 64, 0, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_patch[2] == -1);
  le_engine_destroy(e);
}

/* Reset of one slot fades only its voices. */
static void test_instrument_reset_slot(void) {
  printf("test_instrument_reset_slot\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  le_engine_set_instrument(e, 0, syn_patch("organ"), NULL);
  le_engine_set_instrument(e, 1, syn_patch("organ"), NULL);
  le_engine_instrument_note_on(e, 0, 1, 60, 100);
  le_engine_instrument_note_on(e, 1, 2, 64, 100);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_engine_reset_instrument(e, 0) == LE_OK);
  ins_run(e, 256, 256, 0, NULL);
  CHECK(le_synth_active(s, 0) == 0);
  CHECK(le_synth_active(s, 1) == 1);
  le_engine_destroy(e);
}

/* Configure re-initialises the synth: no voice survives, patches clear and
 * the epoch moves; an oversized block renders nothing and is counted. */
static void test_instrument_configure_epoch_and_fallback(void) {
  printf("test_instrument_configure_epoch_and_fallback\n");
  le_engine* e = ins_engine(INS_SR);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  const uint32_t epoch = snap.synth_epoch;
  CHECK(epoch >= 1);
  le_engine_set_instrument(e, 0, syn_patch("pad"), NULL);
  le_engine_instrument_note_on(e, 0, 1, 60, 100);
  ins_run(e, 64, 64, 0, NULL);
  ins_run(e, 9000, 9000, 0, NULL); /* above LE_COND_SCRATCH_FRAMES */
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_fallback_blocks == 1);
  CHECK(le_engine_configure(e, 44100, 2, 2, 44100 * 4) == LE_OK);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.synth_epoch == epoch + 1);
  CHECK(snap.instrument_patch[0] == -1);
  CHECK(snap.voice_limit == 32);
  CHECK(snap.instrument_fallback_blocks == 0);
  CHECK(le_synth_active((le_synth*)e->synth, -1) == 0);
  CHECK(((le_synth*)e->synth)->sample_rate == 44100);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 60, 100) == LE_ERR_NO_INSTRUMENT);
  le_engine_destroy(e);
}

static void run_instrument_tests(void) {
  test_instrument_bus_matches_offline_render();
  test_instrument_params_reach_first_note();
  test_instrument_rings_order_and_release_lane();
  test_instrument_cut_limit_and_isolation();
  test_instrument_patch_change_isolated();
  test_instrument_refusals();
  test_instrument_reset_slot();
  test_instrument_configure_epoch_and_fallback();
}
