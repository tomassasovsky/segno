/* Instrument slots in the engine (#1197 Part 2a): the synth inside
 * le_engine_process, the ordered note rings with the reserved release lane,
 * Cut, the voice limit, the synth epoch. Literal PCM through
 * le_engine_process against offline le_synth renders. Included from
 * test_engine_core.c after test_engine_synth.h (which defines g_syn_a/b and
 * syn_patch); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs only these. */

#include "engine_instruments.h"

#define INS_SR 48000

/* The origin the engine gives a control-thread note (its tag bit set). */
static uint32_t ins_origin(uint32_t o) { return o | LE_INST_CONTROL_ORIGIN; }

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
  CHECK(!le_synth_has_origin(s, ins_origin(7)));
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
  CHECK(!le_synth_has_origin(s, ins_origin(1001))); /* stolen or released, never held */
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
  CHECK(le_synth_has_origin(s, ins_origin(5)));
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

/* ---- Part 2c: MIDI routing from the shared input sink ---- */

/* A capture stand-in: the engine reaches a capture through the le_midi_sink
 * at its start (le_midi_port.h), so no OS MIDI backend is needed. */
typedef struct ins_capture {
  le_midi_sink sink;
} ins_capture;

static void ins_attach(le_engine* e, ins_capture* c, int32_t port) {
  memset(c, 0, sizeof(*c));
  CHECK(le_engine_attach_midi_input(e, (le_midi*)(void*)c, port) == LE_OK);
}

static void ins_send(ins_capture* c, uint8_t status, uint8_t d1, uint8_t d2) {
  CHECK(le_midi_sink_push(&c->sink, status, d1, d2, 1) == 1);
}

/* An empty table with instrument k listening on `port`/`channel` (0: any)
 * over the whole keyboard. */
static void ins_route(le_inst_routes* r, int32_t k, int32_t port,
                      int32_t channel) {
  r->inst[k].midi_enabled = 1;
  r->inst[k].port = port;
  r->inst[k].channel = channel;
  r->inst[k].low = 0;
  r->inst[k].high = 127;
}

static int32_t ins_voices(le_engine* e, int32_t k) {
  return le_synth_active((le_synth*)e->synth, k);
}

static int32_t ins_held(le_engine* e, int32_t k) {
  le_synth* s = (le_synth*)e->synth;
  int32_t n = 0;
  for (int i = 0; i < s->voice_count; ++i) {
    n += s->voices[i].state == 1 && s->voices[i].inst == k;
  }
  return n;
}

static void test_midi_routing_splits_layers_ranges(void) {
  printf("test_midi_routing_splits_layers_ranges\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture c;
  ins_attach(e, &c, 2);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("keys"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("drums"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 2, 1);  /* keys on channel 1 */
  ins_route(&r, 1, 2, 10); /* drums on channel 10 */
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  /* split */
  ins_send(&c, 0x90, 60, 100);
  ins_send(&c, 0x99, 36, 100);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_voices(e, 0) == 1 && ins_voices(e, 1) == 1);
  CHECK(((le_synth*)e->synth)->voices[0].note == 60);
  ins_send(&c, 0x80, 60, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  /* layer: both on any channel */
  ins_route(&r, 1, 2, 0);
  ins_route(&r, 0, 2, 0);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x93, 64, 90);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 1 && ins_held(e, 1) == 1);
  ins_send(&c, 0x93, 64, 0); /* Note On at velocity 0 is a Note Off */
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0 && ins_held(e, 1) == 0);
  /* range 48..72: 47 and 73 are not played */
  r.inst[1].midi_enabled = 0;
  r.inst[0].low = 48;
  r.inst[0].high = 72;
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x90, 47, 90);
  ins_send(&c, 0x90, 73, 90);
  ins_send(&c, 0x90, 48, 90);
  ins_send(&c, 0x90, 72, 90);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2);
  le_engine_destroy(e);
}

/* A Note Off releases its note whatever the routes say by then (review M1). */
static void test_midi_routing_note_off_survives_route_edits(void) {
  printf("test_midi_routing_note_off_survives_route_edits\n");
  for (int edit = 0; edit < 4; ++edit) {
    le_engine* e = ins_engine(INS_SR);
    ins_capture c;
    ins_attach(e, &c, 0);
    CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
    le_inst_routes r;
    memset(&r, 0, sizeof(r));
    ins_route(&r, 0, 0, 1);
    r.inst[0].remap_count = 1;
    r.inst[0].remaps[0] = (le_inst_remap){0, 1, LE_INST_REMAP_NOTE, 40, 2, {52, 55}};
    CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
    ins_run(e, 64, 64, 0, NULL);
    ins_send(&c, 0x90, 60, 100); /* ordinary */
    ins_send(&c, 0x90, 40, 100); /* remapped chord */
    ins_run(e, 64, 64, 0, NULL);
    CHECK(ins_held(e, 0) == 3);
    switch (edit) {
      case 0: r.inst[0].midi_enabled = 0; break;
      case 1: r.inst[0].channel = 5; break;
      case 2: r.inst[0].remap_count = 0; break;
      default: r.inst[0].low = 61; break;
    }
    CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
    ins_run(e, 64, 64, 0, NULL);
    ins_send(&c, 0x80, 60, 0);
    ins_send(&c, 0x80, 40, 0);
    ins_run(e, 64, 64, 0, NULL);
    CHECK(ins_held(e, 0) == 0);
    le_engine_destroy(e);
  }
}

/* A remap plays a chord with one identity, released together, instead of
 * the ordinary note; a remapped CC64 plays its chord and does not sustain,
 * an unmapped CC64 sustains. */
static void test_midi_routing_remaps(void) {
  printf("test_midi_routing_remaps\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 1);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("keys"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 1, 0);
  r.inst[0].remap_count = 5;
  r.inst[0].remaps[0] = (le_inst_remap){1, 10, LE_INST_REMAP_NOTE, 36, 3, {48, 52, 55}};
  r.inst[0].remaps[1] = (le_inst_remap){1, 2, LE_INST_REMAP_CC, 64, 2, {60, 67}};
  r.inst[0].remaps[2] = (le_inst_remap){1, 0, LE_INST_REMAP_NOTE, 37, 1, {90}};
  /* one note, two channels: each channel finds its own remap */
  r.inst[0].remaps[3] = (le_inst_remap){1, 3, LE_INST_REMAP_NOTE, 40, 1, {80}};
  r.inst[0].remaps[4] = (le_inst_remap){1, 5, LE_INST_REMAP_NOTE, 40, 1, {81}};
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x99, 36, 100);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 3);
  int notes = 0;
  for (int i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].state == 1) notes |= 1 << (s->voices[i].note - 48);
  }
  CHECK(notes == ((1 << 0) | (1 << 4) | (1 << 7))); /* 48, 52, 55; never 36 */
  ins_send(&c, 0x89, 36, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  /* note 36 on another channel is not remapped; a remap on All matches any */
  ins_send(&c, 0x90, 36, 100);
  ins_send(&c, 0x9E, 37, 100);
  ins_run(e, 64, 64, 0, NULL);
  notes = 0;
  for (int i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].state == 1) notes += s->voices[i].note;
  }
  CHECK(ins_held(e, 0) == 2 && notes == 36 + 90);
  ins_send(&c, 0x80, 36, 0);
  ins_send(&c, 0x8E, 37, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  ins_send(&c, 0x92, 40, 100); /* channel 3 */
  ins_send(&c, 0x94, 40, 100); /* channel 5 */
  ins_run(e, 64, 64, 0, NULL);
  notes = 0;
  for (int i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].state == 1) notes += s->voices[i].note;
  }
  CHECK(ins_held(e, 0) == 2 && notes == 80 + 81);
  ins_send(&c, 0x82, 40, 0);
  ins_send(&c, 0x84, 40, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  /* remapped CC64 on channel 2: a chord, no sustain */
  ins_send(&c, 0xB1, 64, 127);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2 && s->inst[0].sustain_n == 0);
  ins_send(&c, 0xB1, 64, 127); /* already held: no second strike */
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2 && le_synth_fading(s) == 0);
  ins_send(&c, 0xB1, 64, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  /* unmapped CC64 (channel 1): sustains */
  ins_send(&c, 0xB0, 64, 127);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->inst[0].sustain_n == 1);
  le_engine_destroy(e);
}

/* Released notes ring until every contributor lets go; repeated strikes
 * under sustain stay distinct voices; a 17th contributor is refused. */
static void test_midi_routing_sustain_contributors(void) {
  printf("test_midi_routing_sustain_contributors\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 0);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xB0, 64, 127);                            /* port 0 CC64 */
  CHECK(le_engine_instrument_sustain(e, 0, 77, 1) == LE_OK); /* a pedal */
  ins_send(&c, 0x90, 60, 100);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x80, 60, 0);
  ins_send(&c, 0x90, 60, 100); /* struck again under sustain */
  ins_send(&c, 0x80, 60, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_synth_active(s, 0) == 2); /* two distinct voices, both sustained */
  CHECK(ins_held(e, 0) == 0);
  ins_send(&c, 0xB0, 64, 0); /* the CC64 lets go, the pedal still holds */
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->voices[0].state == 4 && s->voices[1].state == 4);
  CHECK(le_engine_instrument_sustain(e, 0, 77, 0) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->voices[0].state == 2 && s->voices[1].state == 2); /* releasing */
  /* sixteen contributors fit, the seventeenth is refused and counted */
  for (uint32_t o = 1; o <= 17; ++o) le_engine_instrument_sustain(e, 0, o, 1);
  ins_run(e, 64, 64, 0, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(s->inst[0].sustain_n == 16);
  CHECK(snap.instrument_sustain_refused == 1);
  /* drums ignore sustain */
  CHECK(le_engine_set_instrument(e, 1, syn_patch("drums"), NULL) == LE_OK);
  ins_route(&r, 1, 0, 10);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xB9, 64, 127);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->inst[1].sustain_n == 0);
  le_engine_destroy(e);
}

/* Pitch bend and channel pressure reach the voice. */
static void test_midi_routing_expression(void) {
  printf("test_midi_routing_expression\n");
  const int32_t n = INS_SR;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  le_engine* e = ins_engine(INS_SR);
  ins_capture c;
  ins_attach(e, &c, 0);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("sub"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xE0, 0x7F, 0x7F); /* 16383: two semitones up */
  ins_send(&c, 0x90, 69, 127);
  ins_run(e, n, 64, 0, a);
  const int32_t crossings = syn_crossings(a, n);
  const float want = 2.0f * 440.0f * powf(2.0f, 2.0f / 12.0f); /* 987.8 */
  CHECK(fabsf((float)crossings - want) <= 3.0f);
  le_engine_destroy(e);
  /* pressure 127 raises the level by 25 % */
  for (int pass = 0; pass < 2; ++pass) {
    le_engine* f = ins_engine(INS_SR);
    ins_attach(f, &c, 0);
    le_engine_set_instrument(f, 0, syn_patch("sub"), NULL);
    le_engine_set_instrument_routes(f, &r);
    ins_run(f, 64, 64, 0, NULL);
    if (pass) ins_send(&c, 0xD0, 127, 0);
    ins_send(&c, 0x90, 57, 100);
    ins_run(f, n / 4, 64, 0, pass ? b : a);
    le_engine_destroy(f);
  }
  const float ratio = syn_peak(b, n / 4) / syn_peak(a, n / 4);
  CHECK(fabsf(ratio - 1.25f) < 0.0125f);
  free(a);
  free(b);
}

/* A Note On queued before a Note Off lost to a full ring is played, then
 * released with the port's other voices at the loss; nothing sticks, and
 * other ports and control notes are untouched (review H3, delta D2). */
static void test_midi_routing_overflow_releases_after_queue(void) {
  printf("test_midi_routing_overflow_releases_after_queue\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c0, c1;
  ins_attach(e, &c0, 0);
  ins_attach(e, &c1, 1);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("keys"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("keys"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 0, 0);
  ins_route(&r, 1, 1, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c1, 0x90, 50, 100);                                 /* other port */
  CHECK(le_engine_instrument_note_on(e, 1, 9, 52, 100) == LE_OK); /* control */
  ins_send(&c0, 0x90, 60, 100);                                 /* X on */
  for (int i = 0; i < 254; ++i) ins_send(&c0, 0xB0, 7, 100);   /* filler */
  CHECK(le_midi_sink_push(&c0.sink, 0x80, 60, 0, 1) == 0);      /* X off lost */
  ins_run(e, 64, 64, 0, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.midi_in_overflows == 1u);
  CHECK(ins_held(e, 0) == 0);                /* X was played, then released */
  CHECK(le_synth_active(s, 0) == 1);         /* ... and is releasing */
  CHECK(ins_held(e, 1) == 2);                /* port 1 and the control note */
  ins_run(e, INS_SR * 3, 512, 0, NULL);
  CHECK(le_synth_active(s, 0) == 0);         /* nothing stuck */
  le_engine_destroy(e);
}

/* The release happens at the loss's position in the stream: a note queued
 * before the gap is let go, one queued after it keeps sounding. */
static void test_midi_routing_gap_releases_at_its_position(void) {
  printf("test_midi_routing_gap_releases_at_its_position\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 5);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 5, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x90, 60, 100);
  CHECK(le_midi_sink_mark_gap(&c.sink) == 1); /* e.g. an OS overrun */
  ins_send(&c, 0x90, 64, 100);
  ins_run(e, 64, 64, 0, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.midi_in_overflows == 1u);
  CHECK(ins_held(e, 0) == 1);
  for (int i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].note == 60) CHECK(s->voices[i].state == 2);
    if (s->voices[i].note == 64) CHECK(s->voices[i].state == 1);
  }
  le_engine_destroy(e);
}

/* Detach, rebind and loss end the port's notes; a control note rings on; an
 * old binding's queued event never plays; a fresh note after re-attach does. */
static void test_midi_routing_detach_and_loss(void) {
  printf("test_midi_routing_detach_and_loss\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture c;
  ins_attach(e, &c, 3);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 3, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0x90, 60, 100);
  CHECK(le_engine_instrument_note_on(e, 0, 5, 64, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2);
  ins_send(&c, 0x90, 62, 100); /* queued, then the capture is detached */
  CHECK(le_engine_detach_midi_input(e, 3) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 1); /* only the control note */
  CHECK(le_synth_held((le_synth*)e->synth, -1, ins_origin(5)));
  ins_attach(e, &c, 3);
  ins_send(&c, 0x90, 67, 100);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2);
  /* the device goes away */
  CHECK(le_midi_sink_mark_lost(&c.sink) == 1);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 1);
  le_engine_destroy(e);
}

/* A port that goes away takes its sustain and its expression with it; a
 * control-thread sustain on the same instrument holds on. */
static void test_midi_routing_gone_ends_sustain_and_expression(void) {
  printf("test_midi_routing_gone_ends_sustain_and_expression\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 4);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("keys"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 4, 0);
  ins_route(&r, 1, 4, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  CHECK(le_engine_instrument_sustain(e, 0, 3, 1) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xB0, 64, 127);
  ins_send(&c, 0xB0, 1, 127);
  ins_send(&c, 0xE0, 0, 0x60);
  ins_send(&c, 0x90, 60, 100);
  ins_send(&c, 0x80, 60, 0);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->voices[0].state == 4 && s->voices[1].state == 4);
  CHECK(s->inst[1].mod == 1.0f && s->inst[1].bend > 0.4f);
  CHECK(le_engine_detach_midi_input(e, 4) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  int sustained = 0, releasing = 0;
  for (int i = 0; i < 2; ++i) {
    sustained += s->voices[i].state == 4 && s->voices[i].inst == 0;
    releasing += s->voices[i].state == 2 && s->voices[i].inst == 1;
  }
  CHECK(sustained == 1 && releasing == 1);
  CHECK(s->inst[0].sustain_n == 1 && s->inst[1].sustain_n == 0);
  for (int k = 0; k < 2; ++k) {
    CHECK(s->inst[k].mod == 0.0f && s->inst[k].bend == 0.0f);
  }
  le_engine_destroy(e);
}

/* Turning an instrument's MIDI off, or moving it to another port or
 * channel, ends that port's notes on it and its bend, modulation and
 * pressure (review M1, the reference's silenceController). */
static void test_midi_routing_route_change_clears_expression(void) {
  printf("test_midi_routing_route_change_clears_expression\n");
  for (int edit = 0; edit < 3; ++edit) {
    le_engine* e = ins_engine(INS_SR);
    le_synth* s = (le_synth*)e->synth;
    ins_capture c;
    ins_attach(e, &c, 2);
    CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
    CHECK(le_engine_set_instrument(e, 1, syn_patch("keys"), NULL) == LE_OK);
    le_inst_routes r;
    memset(&r, 0, sizeof(r));
    ins_route(&r, 0, 2, 1);
    ins_route(&r, 1, 2, 1); /* a layer that stays as it is */
    CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
    ins_run(e, 64, 64, 0, NULL);
    ins_send(&c, 0xE0, 0x7F, 0x7F);
    ins_send(&c, 0xB0, 1, 127);
    ins_send(&c, 0xD0, 127, 0);
    ins_send(&c, 0x90, 60, 100);
    ins_run(e, 64, 64, 0, NULL);
    CHECK(s->inst[0].bend > 0.99f && s->inst[0].mod == 1.0f);
    CHECK(ins_held(e, 0) == 1);
    switch (edit) {
      case 0: r.inst[0].midi_enabled = 0; break;
      case 1: r.inst[0].port = 3; break;
      default: r.inst[0].channel = 2; break;
    }
    CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
    ins_run(e, 64, 64, 0, NULL);
    CHECK(s->inst[0].bend == 0.0f && s->inst[0].mod == 0.0f &&
          s->inst[0].pressure == 0.0f);
    CHECK(ins_held(e, 0) == 0);
    /* the other instrument on that port keeps its note and expression */
    CHECK(ins_held(e, 1) == 1 && s->inst[1].mod == 1.0f);
    le_engine_destroy(e);
  }
  /* a range edit keeps both: the note ends at its own release */
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 2);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 2, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xB0, 1, 127);
  ins_send(&c, 0x90, 60, 100);
  ins_run(e, 64, 64, 0, NULL);
  r.inst[0].low = 70;
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->inst[0].mod == 1.0f && ins_held(e, 0) == 1);
  le_engine_destroy(e);
}

/* A held remapped controller suppresses its repeat on that instrument only:
 * another instrument's ordinary handling of the same controller goes on
 * (review L1). */
static void test_midi_routing_held_remap_is_per_instrument(void) {
  printf("test_midi_routing_held_remap_is_per_instrument\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 0);
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 1, syn_patch("keys"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 0, 0, 0);
  ins_route(&r, 1, 0, 0);
  /* the remap sits on the lower instrument, so a check that stopped the
   * whole message would also starve the higher one */
  r.inst[0].remap_count = 1;
  r.inst[0].remaps[0] = (le_inst_remap){0, 0, LE_INST_REMAP_CC, 1, 2, {60, 64}};
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  ins_send(&c, 0xB0, 1, 80);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 2);
  CHECK(fabsf(s->inst[1].mod - 80.0f / 127.0f) < 1e-6f);
  ins_send(&c, 0xB0, 1, 127);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(s->inst[1].mod == 1.0f); /* the mod wheel still reaches instrument 1 */
  CHECK(ins_held(e, 0) == 2 && le_synth_fading(s) == 0); /* no re-strike */
  le_engine_destroy(e);
}

/* A patch posted before a MIDI note in the same block plays that note
 * (review L2): the control rings are applied before the MIDI drain. */
static void test_midi_routing_note_meets_patch_posted_before_it(void) {
  printf("test_midi_routing_note_meets_patch_posted_before_it\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  ins_capture c;
  ins_attach(e, &c, 0);
  CHECK(le_engine_set_instrument(e, 2, syn_patch("organ"), NULL) == LE_OK);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  ins_route(&r, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(le_engine_set_instrument(e, 2, syn_patch("lead"), NULL) == LE_OK);
  ins_send(&c, 0x90, 60, 100);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 2) == 1);
  CHECK(le_synth_fading(s) == 0);
  for (int i = 0; i < s->voice_count; ++i) {
    if (s->voices[i].state == 1) CHECK(s->voices[i].patch == syn_patch("lead"));
  }
  le_engine_destroy(e);
}

/* A chord from one control origin sounds every note and ends together;
 * a single note-on for a held origin replaces it (one origin, one sounding
 * note); a chord is all or nothing (#1197 Part 3a review M1). */
static void test_instrument_chord_on(void) {
  printf("test_instrument_chord_on\n");
  le_engine* e = ins_engine(INS_SR);
  le_synth* s = (le_synth*)e->synth;
  CHECK(le_engine_set_instrument(e, 0, syn_patch("pad"), NULL) == LE_OK);
  const int32_t triad[3] = {60, 64, 67};
  CHECK(le_engine_instrument_chord_on(e, 0, 7, triad, 3, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 3);
  CHECK(le_engine_instrument_note_off(e, 7) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 0);
  /* separate note-ons for one origin: the last replaces the first */
  CHECK(le_engine_instrument_note_on(e, 0, 8, 60, 100) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 0, 8, 64, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 1);
  /* a chord for a held origin replaces it too, then sounds whole */
  CHECK(le_engine_instrument_chord_on(e, 0, 8, triad, 3, 100) == LE_OK);
  ins_run(e, 64, 64, 0, NULL);
  CHECK(ins_held(e, 0) == 3 && le_synth_fading(s) >= 1);
  /* refusals */
  const int32_t bad[2] = {60, 128};
  CHECK(le_engine_instrument_chord_on(e, 0, 9, triad, 0, 100) == LE_ERR_INVALID);
  CHECK(le_engine_instrument_chord_on(e, 0, 9, triad, LE_INST_CHORD_NOTES + 1,
                                      100) == LE_ERR_INVALID);
  CHECK(le_engine_instrument_chord_on(e, 0, 9, bad, 2, 100) == LE_ERR_INVALID);
  CHECK(le_engine_instrument_chord_on(e, 3, 9, triad, 3, 100) ==
        LE_ERR_NO_INSTRUMENT);
  /* all or nothing: find how many single notes fit, take two back, and a
   * triad is refused whole while a pair still fits */
  ins_run(e, 64, 64, 0, NULL);
  int32_t fit = 0;
  while (le_engine_instrument_note_on(e, 0, 100u + (uint32_t)fit, 30, 50) ==
         LE_OK) {
    ++fit;
  }
  ins_run(e, 64, 64, 0, NULL); /* drains them */
  for (int32_t n = 0; n < fit - 2; ++n) {
    CHECK(le_engine_instrument_note_on(e, 0, 400u + (uint32_t)n, 30, 50) == LE_OK);
  }
  CHECK(le_engine_instrument_chord_on(e, 0, 9, triad, 3, 100) == LE_ERR_CAPACITY);
  CHECK(le_engine_instrument_chord_on(e, 0, 9, triad, 2, 100) == LE_OK);
  le_engine_destroy(e);
}

/* Route tables switch at a block: a second publish before the callback has
 * acknowledged the first is refused while running; stopped, they switch at
 * once. */
static void test_midi_routing_publish(void) {
  printf("test_midi_routing_publish\n");
  le_engine* e = ins_engine(INS_SR);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK); /* stopped */
  r.inst[0].high = 200;
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_ERR_INVALID);
  r.inst[0].high = 127;
  r.inst[0].remap_count = 1;
  r.inst[0].remaps[0] = (le_inst_remap){0, 0, LE_INST_REMAP_NOTE, 1, 9, {0}};
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_ERR_INVALID);
  r.inst[0].remap_count = 0;
  store_i32(&e->a_running, 1); /* as if the callback ran */
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_ERR_NOT_READY);
  ins_run(e, 64, 64, 0, NULL); /* the callback acknowledges */
  CHECK(le_engine_set_instrument_routes(e, &r) == LE_OK);
  store_i32(&e->a_running, 0);
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
  test_instrument_release_before_note_keeps_it();
  test_instrument_params_stay_with_their_patch();
  test_instrument_reset_drops_queued_events();
  test_source_capture_records_the_bus();
  test_source_monitor_gains();
  test_source_sound_start_is_frame_exact();
  test_source_mix_transaction();
  test_source_perf_tap();
  test_midi_routing_splits_layers_ranges();
  test_midi_routing_note_off_survives_route_edits();
  test_midi_routing_remaps();
  test_midi_routing_sustain_contributors();
  test_midi_routing_expression();
  test_midi_routing_overflow_releases_after_queue();
  test_midi_routing_gap_releases_at_its_position();
  test_midi_routing_detach_and_loss();
  test_midi_routing_gone_ends_sustain_and_expression();
  test_midi_routing_publish();
  test_instrument_chord_on();
  test_midi_routing_route_change_clears_expression();
  test_midi_routing_held_remap_is_per_instrument();
  test_midi_routing_note_meets_patch_posted_before_it();
}
