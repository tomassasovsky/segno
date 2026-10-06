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

  /* 300 note-ons: 247 fit (one slot kept empty, eight kept for patch
   * changes), 53 are refused and counted; a patch change for every slot and
   * the release of the first note are still accepted */
  int ok = 0, full = 0;
  for (uint32_t o = 1; o <= 300; ++o) {
    const int32_t rc = le_engine_instrument_note_on(e, 0, 1000 + o, 30 + (int32_t)(o % 60), 100);
    if (rc == LE_OK) ok++;
    if (rc == LE_ERR_CAPACITY) full++;
  }
  CHECK(ok == 247 && full == 53);
  for (int k = 1; k < LE_MAX_INSTRUMENTS; ++k) {
    CHECK(le_engine_set_instrument(e, k, syn_patch("keys"), NULL) == LE_OK);
  }
  CHECK(le_engine_set_instrument(e, 0, syn_patch("sub"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("pad"), NULL) == LE_ERR_CAPACITY);
  CHECK(le_engine_instrument_note_off(e, 1001) == LE_OK);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_events_refused == 53);
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
  for (uint32_t o = 1; o <= 247; ++o) {
    CHECK(le_engine_instrument_note_on(e, 3, o, 40 + (int32_t)(o % 40), 100) == LE_OK);
  }
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) { /* the reserved room */
    CHECK(le_engine_set_instrument(e, 4, syn_patch("keys"), NULL) == LE_OK);
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
  CHECK(snap.instrument_peaks[0] == 0.0f); /* the oversized block is silent */
  int zero = 1;
  for (int i = 0; i < LE_COND_SCRATCH_FRAMES; ++i) zero &= le_instrument_bus(e, 0)[i] == 0.0f;
  CHECK(zero);
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

/* A release posted before a note-on of the same origin applies first, so
 * the note it does not belong to keeps sounding. */
static void test_instrument_release_before_note_keeps_it(void) {
  printf("test_instrument_release_before_note_keeps_it\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_off(e, 5) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 5, 60, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_synth_has_origin(s, 5));
  CHECK(s->voices[0].state == 1 /* held */);
  le_engine_destroy(e);
}

/* Values stamped for the next patch are never applied to the patch still
 * playing: with more than one block of releases queued ahead of the patch
 * change, the old patch keeps its own parameters until the change drains. */
static void test_instrument_params_stay_with_their_patch(void) {
  printf("test_instrument_params_stay_with_their_patch\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  const float first[3] = {11.0f, 22.0f, 33.0f};
  CHECK(le_engine_set_instrument(e, 0, syn_patch("lead"), first) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 60, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  for (uint32_t o = 100; o < 700; ++o) CHECK(le_engine_instrument_note_off(e, o) == LE_OK);
  const float next[3] = {90.0f, 80.0f, 70.0f};
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), next) == LE_OK);
  ins_run(e, 64, 64, 0, NULL); /* 512 releases: the change still waits */
  CHECK(s->inst[0].patch == syn_patch("lead"));
  CHECK(s->inst[0].params[0] == 11.0f && s->inst[0].params[1] == 22.0f &&
        s->inst[0].params[2] == 33.0f);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->inst[0].patch == syn_patch("pad"));
  CHECK(s->inst[0].params[0] == 90.0f && s->inst[0].params[1] == 80.0f &&
        s->inst[0].params[2] == 70.0f);
  le_engine_destroy(e);
}

/* Configure and reopen drop every queued event and bump the epoch: nothing
 * posted before them plays after them. */
static void test_instrument_reset_drops_queued_events(void) {
  printf("test_instrument_reset_drops_queued_events\n");
  le_engine* e = ins_engine(INS_SR);
  le_snapshot snap;
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 60, 100) == LE_OK);
  le_engine_get_snapshot(e, &snap);
  const uint32_t epoch = snap.synth_epoch;
  CHECK(le_engine_configure(e, INS_SR, 2, 2, INS_SR * 4) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.synth_epoch == epoch + 1);
  CHECK(snap.instrument_patch[0] == -1);
  CHECK(le_synth_active((le_synth*)e->synth, -1) == 0);
  /* new events after the reset never let the old ones through */
  CHECK(le_engine_set_instrument(e, 2, syn_patch("keys"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 9, 62, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_patch[0] == -1);
  CHECK(snap.instrument_patch[2] == syn_patch("keys"));
  CHECK(le_synth_active((le_synth*)e->synth, 0) == 0);
  CHECK(le_synth_active((le_synth*)e->synth, 2) == 1);
  /* the reopen path, material retained */
  CHECK(le_engine_set_instrument(e, 1, syn_patch("keys"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 2, 64, 100) == LE_OK);
  int32_t outcome = -99, mask = -99;
  CHECK(le_engine_reopen_configured(e, INS_SR, 2, 2, INS_SR * 4, &outcome, &mask) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.synth_epoch == epoch + 2);
  CHECK(snap.instrument_patch[1] == -1);
  CHECK(le_synth_active((le_synth*)e->synth, -1) == 0);
  le_engine_destroy(e);
}

/* ---- Part 2b: instruments as sources 32-39 ---- */

/* Processes `frames` with silent input in blocks of `block`, writing the
 * interleaved stereo output to `out` (NULL: discarded). */
static void ins_pump(le_engine* e, int32_t frames, int32_t block, float* out) {
  static float in[2 * 512], o[2 * 512];
  memset(in, 0, sizeof(in));
  int32_t done = 0;
  while (done < frames) {
    int32_t n = frames - done;
    if (n > block) n = block;
    if (n > 512) n = 512;
    le_engine_process(e, o, in, (uint32_t)n);
    if (out != NULL) memcpy(out + 2 * done, o, sizeof(float) * 2 * (size_t)n);
    done += n;
  }
}

static void ins_drain(le_engine* e) {
  float z[2] = {0.0f, 0.0f};
  le_engine_process(e, z, z, 0);
}

/* A lane routed to source 32 records the instrument's bus sample for sample,
 * with Hear live Off (nothing reaches the outputs). */
static void test_source_capture_records_the_bus(void) {
  printf("test_source_capture_records_the_bus\n");
  const int32_t n = 9600;
  float* ref = (float*)calloc((size_t)(n + 64), sizeof(float));
  ins_offline(&g_syn_a, INS_SR);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("pad"));
  le_synth_note_on(&g_syn_a, 0, 1, 60, 100);
  float* r[1] = {ref};
  syn_render(&g_syn_a, r, 1, n + 64, 64);

  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_lane_input(e, 0, 0, 32) == LE_OK);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 60, 100) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  float* out = (float*)calloc((size_t)2 * n, sizeof(float));
  ins_pump(e, n, 64, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize */
  ins_pump(e, 64, 64, NULL);
  int silent = 1;
  for (int32_t i = 0; i < 2 * n; ++i) silent &= out[i] == 0.0f;
  CHECK(silent); /* Hear live Off: monitor 32 never enabled */
  float* lane = (float*)calloc((size_t)n, sizeof(float));
  const int32_t len = le_engine_export_track_lane(e, 0, 0, lane, n);
  CHECK(len >= n - 64 && len <= n);
  /* away from the seam crossfade, the take is the bus */
  int same = 1;
  for (int32_t i = 1000; i < len - 1000; ++i) same &= lane[i] == ref[i];
  CHECK(same);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].input_mask == 0u); /* no legacy bit for a source */
  le_engine_destroy(e);
  free(ref);
  free(out);
  free(lane);
}

/* Monitor 32 plays the bus at its volume and pan, and its peak and the
 * source's input peak are published. */
static void test_source_monitor_gains(void) {
  printf("test_source_monitor_gains\n");
  const int32_t n = 4800;
  float* ref = (float*)calloc((size_t)n, sizeof(float));
  ins_offline(&g_syn_a, INS_SR);
  le_synth_set_instrument(&g_syn_a, 3, syn_patch("sub"));
  le_synth_note_on(&g_syn_a, 3, 1, 48, 60);
  float* r[4] = {NULL, NULL, NULL, ref};
  syn_render(&g_syn_a, r, 4, n, 64);

  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_monitor_input(e, 35, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_volume(e, 35, 0.5f) == LE_OK);
  CHECK(le_engine_set_instrument(e, 3, syn_patch("sub"), NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 3, 1, 48, 60) == LE_OK);
  float* out = (float*)calloc((size_t)2 * n, sizeof(float));
  ins_pump(e, n, 64, out);
  float worst = 0.0f;
  for (int32_t i = 0; i < n; ++i) {
    const float dl = fabsf(out[2 * i] - 0.5f * ref[i]);
    const float dr = fabsf(out[2 * i + 1] - 0.5f * ref[i]);
    if (dl > worst) worst = dl;
    if (dr > worst) worst = dr;
  }
  CHECK(worst < 1e-6f);
  CHECK(syn_peak(ref, n) > 0.05f);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.monitor_peaks[35] > 0.0f);
  CHECK(snap.input_peaks[35] == snap.instrument_peaks[3]);
  CHECK(snap.input_peaks[35] > 0.0f);
  CHECK(snap.input_trim[35] == 1.0f);
  /* an oversized block: the sources read silence, never past the bus (slot
   * 7 is the last bus: reading frame 8192 on would leave the allocation) */
  CHECK(le_engine_set_instrument(e, 7, syn_patch("organ"), NULL) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 39, 1) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 7, 2, 60, 100) == LE_OK);
  ins_pump(e, 64, 64, NULL);
  float big[2 * 9000], bin[2 * 9000];
  memset(bin, 0, sizeof(bin));
  le_engine_process(e, big, bin, 9000);
  int silent = 1;
  for (int i = 0; i < 2 * 9000; ++i) silent &= big[i] == 0.0f;
  CHECK(silent);
  le_engine_destroy(e);
  free(ref);
  free(out);
}

/* A track armed to start on sound starts at the first frame the instrument's
 * bus passes the threshold, with the note struck in an earlier block. */
static void test_source_sound_start_is_frame_exact(void) {
  printf("test_source_sound_start_is_frame_exact\n");
  const int32_t n = 9600;
  float* ref = (float*)calloc((size_t)n, sizeof(float));
  ins_offline(&g_syn_a, INS_SR);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("organ"));
  le_synth_note_on(&g_syn_a, 0, 1, 64, 40);
  float* r[1] = {ref};
  syn_render(&g_syn_a, r, 1, n, 64);
  int32_t f0 = -1;
  for (int32_t i = 0; i < n && f0 < 0; ++i) {
    if (fabsf(ref[i]) > LE_AUTO_RECORD_THRESHOLD) f0 = i;
  }
  CHECK(f0 > 64); /* the threshold falls in a later block than the strike */

  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_lane_input(e, 0, 0, 32) == LE_OK);
  CHECK(record_start_sound(e, 1) == LE_OK);
  ins_drain(e);
  /* a sound start needs a usable source: an empty slot is not one */
  CHECK(le_engine_record(e, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("organ"), NULL) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK); /* armed: waits for sound */
  ins_pump(e, 64, 64, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(le_engine_instrument_note_on(e, 0, 1, 64, 40) == LE_OK);
  ins_pump(e, f0, 64, NULL); /* up to, not including, the crossing frame */
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].state == LE_TRACK_EMPTY);
  ins_pump(e, 1, 1, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].state == LE_TRACK_RECORDING);
  ins_pump(e, 4000, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ins_pump(e, 64, 64, NULL);
  float lane[4100];
  const int32_t len = le_engine_export_track_lane(e, 0, 0, lane, 4100);
  CHECK(len > 3000);
  int same = 1;
  for (int32_t i = 600; i < len - 600; ++i) same &= lane[i] == ref[f0 + i];
  CHECK(same);
  le_engine_destroy(e);
  free(ref);
}

/* The mix transaction takes sources 32-39 whole: an empty slot is silence,
 * never a refused batch; 40 is out of range; a stray physical route beyond
 * the device's inputs is still accepted as before. */
static void test_source_mix_transaction(void) {
  printf("test_source_mix_transaction\n");
  le_engine* e = ins_engine(INS_SR);
  le_mix_settings mix;
  memset(&mix, 0, sizeof(mix));
  mix.revision = 7;
  mix.routing_input_mask = (UINT64_C(1) << 0) | (UINT64_C(1) << 8);
  mix.lane_input[0] = 33;   /* track 0 lane 0: an empty slot */
  mix.lane_input[8] = 5;    /* track 1 lane 0: a stray jack on a 2-in device */
  mix.monitor_mask = (UINT64_C(1) << 39) | (UINT64_C(1) << 1);
  mix.monitor_gain[39] = 0.25f;
  mix.monitor_pan[39] = -1.0f;
  mix.monitor_gain[1] = 1.0f;
  CHECK(le_engine_set_mix(e, &mix) == LE_OK);
  ins_pump(e, 64, 64, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.mix_revision == 7);
  CHECK(load_i32(&e->tracks[0].lanes[0].a_input_channel) == 33);
  CHECK(load_i32(&e->tracks[1].lanes[0].a_input_channel) == 5);
  CHECK(load_f32(&e->monitors[39].a_vol_bits) == 0.25f);
  CHECK(load_f32(&e->monitors[39].a_pan_bits) == -1.0f);
  le_mix_settings bad = mix;
  bad.revision = 8;
  bad.lane_input[0] = 40;
  CHECK(le_engine_set_mix(e, &bad) == LE_ERR_INVALID);
  bad = mix;
  bad.revision = 9;
  bad.monitor_mask = UINT64_C(1) << 40;
  CHECK(le_engine_set_mix(e, &bad) == LE_ERR_INVALID);
  /* single commands: 39 accepted with an empty slot, the tuner and
   * conditioning stay physical */
  CHECK(le_engine_set_lane_input(e, 2, 0, 39) == LE_OK);
  CHECK(le_engine_set_tuner_input(e, 32) == LE_OK);
  CHECK(le_engine_set_input_conditioning(e, 32, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_input_trim(e, 32, 0.5f) == LE_ERR_INVALID);
  ins_pump(e, 64, 64, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(load_i32(&e->tracks[2].lanes[0].a_input_channel) == 39);
  CHECK(snap.tuner_input == -1);
  CHECK(snap.input_cond_mask == 0u && snap.input_clip_mask == 0u);
  le_engine_destroy(e);
}

/* The performance capture taps a monitored instrument source like an input. */
static void test_source_perf_tap(void) {
  printf("test_source_perf_tap\n");
  const int32_t n = 960;
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("sub"), NULL) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 33, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 34, 1) == LE_OK); /* empty slot: not captured */
  CHECK(le_engine_set_monitor_input_volume(e, 33, 0.5f) == LE_OK);
  ins_pump(e, 64, 64, NULL);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  CHECK(e->perf.input_mask == (UINT64_C(1) << 33));
  ins_drain(e);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 52, 80) == LE_OK);
  float* out = (float*)calloc((size_t)2 * n, sizeof(float));
  ins_pump(e, n, 64, out);
  float captured[2 * 960];
  const int32_t got = le_engine_perf_monitor_pop_for_test(e, 33, captured, n);
  CHECK(got > 0);
  int same = 1;
  for (int32_t i = 0; i < got; ++i) same &= captured[2 * i] == out[2 * (n - got + i)];
  CHECK(same);
  CHECK(syn_peak(out, 2 * n) > 0.01f);
  CHECK(le_engine_perf_monitor_pop_for_test(e, 34, captured, n) == 0);
  le_perf_disarm(e);
  le_engine_destroy(e);
  free(out);
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
  test_instrument_release_before_note_keeps_it();
  test_instrument_params_stay_with_their_patch();
  test_instrument_reset_drops_queued_events();
  test_source_capture_records_the_bus();
  test_source_monitor_gains();
  test_source_sound_start_is_frame_exact();
  test_source_mix_transaction();
  test_source_perf_tap();
}
