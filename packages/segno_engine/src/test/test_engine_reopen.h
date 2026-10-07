/* Device reopen with retained material (#1140): literal-PCM oracles through the
 * production entry points. Included by test_engine_core.c after
 * test_engine_fade.h (reuses its fixture, fade_process and fade_install_at). */

/* Same device shape as make_configured_engine: the retained path. The mask
 * names the tracks dropped for a state command the callback never applied. */
static int32_t reopen_same_mask(le_engine* e, int32_t* mask) {
  int32_t outcome = -99;
  *mask = -99;
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 1000, &outcome, mask) ==
        LE_OK);
  return outcome;
}

static int32_t reopen_same(le_engine* e) {
  int32_t mask;
  const int32_t outcome = reopen_same_mask(e, &mask);
  CHECK(mask == 0);
  return outcome;
}

/* Pumps silence until the master playhead reads 0. */
static void reopen_align_head(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  const int32_t len = s.master_length_frames;
  const int32_t pos = s.master_position_frames;
  if (len > 0 && pos != 0) pump_frames(e, 0.0f, len - pos);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
}

/* One complete overdub pass of `value` on track 0, retired and settled. */
static void reopen_overdub_pass(le_engine* e, float value) {
  float out[64];
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, value, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  settle_dub(e);
}

static void reopen_check_track_pcm(le_engine* e, int32_t ch, int32_t lane,
                                   const float* want, int32_t n) {
  float got[8192];
  CHECK(n <= 8192);
  CHECK(le_engine_export_track_lane(e, ch, lane, got, n) == n);
  for (int i = 0; i < n; ++i) CHECK(got[i] == want[i]);
}

static void reopen_check_const(le_engine* e, int32_t ch, float want,
                               int32_t n) {
  float got[8192];
  CHECK(n <= 8192);
  CHECK(le_engine_export_track(e, ch, got, n) == n);
  for (int i = 0; i < n; ++i) CHECK(got[i] == want);
}

/* Same-rate reopen keeps every lane's PCM, the undo/redo history and depths,
 * multiples, take ids and the crown; content comes back STOPPED at the head,
 * silent until Play, then plays from frame 0; history and overdub still work. */
static void test_reopen_same_rate_retains_material(void) {
  printf("test_reopen_same_rate_retains_material\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot before;
  le_snapshot s;

  record_base_loop(e, 1.0f);   /* track 0 = 1.0 x4 */
  reopen_overdub_pass(e, 0.5f); /* 1.5, layer 0 = 1.0 */
  reopen_overdub_pass(e, 0.25f); /* 1.75, layer 1 = 1.5 */
  /* Track 1: two base loops of 2.0 over the 4-frame master (multiple 2). */
  reopen_align_head(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, 2 * LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &before);
  CHECK(before.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(before.tracks[0].undo_depth == 2);
  CHECK(before.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(before.tracks[1].multiple == 2);
  CHECK(before.tracks[1].length_frames == 2 * LOOP_N);
  CHECK(before.primary_track == 0);
  CHECK(before.tracks[0].settled_take_id > 0);
  CHECK(before.tracks[1].settled_take_id > 0);
  float t1[2 * LOOP_N];
  CHECK(le_engine_export_track(e, 1, t1, 2 * LOOP_N) == 2 * LOOP_N);
  process_const(e, 0.0f, 3, out); /* leave the heads mid-loop */

  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);

  le_engine_get_snapshot(e, &s);
  CHECK(s.sample_rate == 48000);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(s.master_position_frames == 0);
  CHECK(s.primary_track == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].length_frames == LOOP_N);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[0].undo_depth == 2);
  CHECK(s.tracks[0].redo_depth == 0);
  CHECK(s.tracks[0].settled_take_id == before.tracks[0].settled_take_id);
  CHECK(s.tracks[1].settled_take_id == before.tracks[1].settled_take_id);
  CHECK(s.tracks[0].position_frames == 0);
  {
    le_lane_snapshot l0;
    le_engine_get_lane(e, 0, 0, &l0);
    CHECK(l0.recoverable == 1);
  }
  reopen_check_const(e, 0, 1.75f, LOOP_N);
  float layer[LOOP_N];
  CHECK(le_engine_export_layer(e, 0, 0, 0, layer, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(layer[i] == 1.0f);
  CHECK(le_engine_export_layer(e, 0, 0, 1, layer, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(layer[i] == 1.5f);
  reopen_check_track_pcm(e, 1, 0, t1, 2 * LOOP_N);

  /* Stopped: silent, and the head does not move. */
  process_const(e, 0.0f, 2 * LOOP_N, out);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(out[i] == 0.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);

  /* Play unparks the loop from frame 0: the exact sum of both tracks' heads. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  process_const(e, 0.0f, 2 * LOOP_N, out);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(out[i] == 1.75f + t1[i]);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  /* History survived as history: undo peels the exact layer, redo returns it. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  reopen_check_const(e, 0, 1.5f, LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1 && s.tracks[0].redo_depth == 1);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  reopen_check_const(e, 0, 1.75f, LOOP_N);
  /* And the per-pass capture re-arms after the reopen. */
  reopen_overdub_pass(e, 0.25f);
  reopen_check_const(e, 0, 2.0f, LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 3);
  le_engine_destroy(e);
}

/* A first recording still capturing at the loss is dropped: EMPTY, nothing
 * recoverable, and a defining take leaves the clock unset. */
static void test_reopen_drops_partial_first_take(void) {
  printf("test_reopen_drops_partial_first_take\n");
  float out[64];
  le_snapshot s;
  /* Defining take. */
  le_engine* e = make_configured_engine();
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 1.0f, 2, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  {
    le_lane_snapshot l0;
    le_engine_get_lane(e, 0, 0, &l0);
    CHECK(l0.recoverable == 0);
  }
  CHECK(s.master_length_frames == 0);
  CHECK(s.primary_track == -1);
  /* The rig records again from scratch. */
  record_base_loop(e, 0.5f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.master_length_frames == LOOP_N);
  reopen_check_const(e, 0, 0.5f, LOOP_N);
  le_engine_destroy(e);

  /* Non-defining take: only that track is dropped; the master stays. */
  e = make_configured_engine();
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, 2, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].length_frames == 0);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(s.primary_track == 0);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  le_engine_destroy(e);
}

/* An in-progress overdub pass is reverted to the pre-pass image sample-exactly
 * on every lane, including a pass that started mid-loop; the committed layer
 * beneath it stays undoable. */
static void test_reopen_reverts_partial_overdub_pass(void) {
  printf("test_reopen_reverts_partial_overdub_pass\n");
  le_engine* e = make_two_lane_engine(); /* lanes 0/1 <- inputs 0/1 */
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};
  float in[2 * LOOP_N];
  le_snapshot s;
  record_two_lane(e, 1.0f, 2.0f);
  /* One complete pass: lane 0 -> 1.25, lane 1 -> 2.5, one layer. */
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 0.25f;
    in[i * 2 + 1] = 0.5f;
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.master_position_frames == 0);
  /* Move the head to 2, then punch in for three frames: positions 2, 3, 0. */
  le_engine_process(e, out, zin, 2);
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 1.0f;
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_process(e, out, in, 3);
  const float torn0[LOOP_N] = {2.25f, 1.25f, 2.25f, 2.25f};
  const float torn1[LOOP_N] = {3.5f, 2.5f, 3.5f, 3.5f};
  reopen_check_track_pcm(e, 0, 0, torn0, LOOP_N);
  reopen_check_track_pcm(e, 0, 1, torn1, LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, 48000, 2, 2, 1000, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  const float pre0[LOOP_N] = {1.25f, 1.25f, 1.25f, 1.25f};
  const float pre1[LOOP_N] = {2.5f, 2.5f, 2.5f, 2.5f};
  reopen_check_track_pcm(e, 0, 0, pre0, LOOP_N);
  reopen_check_track_pcm(e, 0, 1, pre1, LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 0);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  const float base0[LOOP_N] = {1.0f, 1.0f, 1.0f, 1.0f};
  const float base1[LOOP_N] = {2.0f, 2.0f, 2.0f, 2.0f};
  reopen_check_track_pcm(e, 0, 0, base0, LOOP_N);
  reopen_check_track_pcm(e, 0, 1, base1, LOOP_N);
  le_engine_destroy(e);
}

/* A pass of a multiple-2 track that straddles the segment boundary reverts
 * through the same trajectory walk (segment math, not just position). */
static void test_reopen_reverts_partial_pass_across_segments(void) {
  printf("test_reopen_reverts_partial_pass_across_segments\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  record_base_loop(e, 1.0f); /* 4-frame master on track 0 */
  reopen_align_head(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, 2 * LOOP_N, out); /* track 1: 8 frames, k = 2 */
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  /* Head at segment 0 position 2; punch in for four frames: indices 2,3,4,5. */
  process_const(e, 0.0f, 2, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.5f, 4, out);
  const float torn[2 * LOOP_N] = {2.0f, 2.0f, 2.5f, 2.5f, 2.5f, 2.5f, 2.0f, 2.0f};
  reopen_check_track_pcm(e, 1, 0, torn, 2 * LOOP_N);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  reopen_check_const(e, 1, 2.0f, 2 * LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].undo_depth == 0);
  CHECK(s.tracks[1].multiple == 2);
  le_engine_destroy(e);
}

/* A punched-out pass whose post-punch drain is still running (loop longer than
 * one drain chunk) reverts to the image captured before the punch-in. */
static void test_reopen_reverts_pass_mid_drain(void) {
  printf("test_reopen_reverts_pass_mid_drain\n");
  le_engine* e = le_engine_create();
  const int32_t len = LE_DRAIN_CHUNK + 8000; /* > one drain block */
  CHECK(le_engine_configure(e, 48000, 1, 1, len + 60000) == LE_OK);
  le_snapshot s;
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_frames(e, 1.0f, len);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  pump_frames(e, 1.0f, 600); /* the deferred seam crossfade completes */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == len);
  float* image = (float*)malloc((size_t)len * sizeof(float));
  CHECK(le_engine_export_track(e, 0, image, len) == len);

  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  pump_frames(e, 0.5f, 1000);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  int draining = 0;
  for (int k = 0; k < 64 && !draining; ++k) {
    pump_frames(e, 0.0f, 64);
    draining = e->tracks[0].dub_draining;
  }
  CHECK(draining); /* the drain is mid-flight: count < len */
  CHECK(e->tracks[0].dub_count > 0 && e->tracks[0].dub_count < len);

  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, len + 60000, &outcome, NULL) ==
        LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  float* back = (float*)malloc((size_t)len * sizeof(float));
  CHECK(le_engine_export_track(e, 0, back, len) == len);
  CHECK(memcmp(image, back, (size_t)len * sizeof(float)) == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].layer_in_flight == 0);
  free(image);
  free(back);
  le_engine_destroy(e);
}

/* A complete pass parked because the event ring was full is a committed layer
 * and is filed as one. */
static void test_reopen_files_parked_retire(void) {
  printf("test_reopen_files_parked_retire\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in (its own drain ran) */
  le_command junk = {0};
  junk.code = 9999; /* no handler: ignored by the control-side drain */
  int pushed = 0;
  while (le_ring_push(&e->evt_ring, junk)) pushed++;
  CHECK(pushed == (int)LE_RING_CAPACITY - 1);
  process_const(e, 0.5f, LOOP_N, out); /* the pass completes, cannot retire */
  CHECK(e->tracks[0].dub_retire_slot >= 0);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  CHECK(e->tracks[0].dub_retire_slot < 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].undo_depth == 1);
  reopen_check_const(e, 0, 1.5f, LOOP_N);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  le_engine_destroy(e);
}

/* A take still in its seam crossfade (defining) or trailing fold (later
 * track) is dropped like any partial pass. */
static void test_reopen_drops_seam_take(void) {
  printf("test_reopen_drops_seam_take\n");
  le_snapshot s;
  const int32_t cap = 4000;
  /* Defining master, finalize press landed, crossfade overlap still capturing. */
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, cap) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_frames(e, 1.0f, 1000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(e->tracks[0].xfade_capture > 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, cap, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);
  CHECK(e->tracks[0].xfade_capture == 0);
  le_engine_destroy(e);

  /* Later track, finalized, trailing seam fold (#728) still capturing. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, cap) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_frames(e, 1.0f, 1000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  pump_frames(e, 1.0f, 600);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.master_length_frames == 1000);
  reopen_align_head(e); /* the fold arms only on a whole, head-aligned take */
  CHECK(le_engine_record(e, 1) == LE_OK);
  pump_frames(e, 0.5f, 1000);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  CHECK(e->tracks[1].seam_capture > 0);
  pump_frames(e, 0.5f, 100);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, cap, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].length_frames == 1000);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].length_frames == 0);
  CHECK(s.master_length_frames == 1000);
  CHECK(e->tracks[1].seam_capture == 0);
  reopen_check_const(e, 0, 1.0f, 1000);
  le_engine_destroy(e);
}

/* The Fade image freezes at the loss and resumes toward its target at the
 * original full-travel rate from the frozen amount; admissions made against
 * the old device cannot apply. */
static void test_reopen_fade_frozen_then_resumes(void) {
  printf("test_reopen_fade_frozen_then_resumes\n");
  const int sr = 8000;
  le_engine* e = fade_fixture(sr); /* 128 x 0.5, PLAYING */
  uint64_t id = fade_install_at(e, 1.0f, 0.0f, 1.0f); /* 1 -> 0 over 8000 frames */
  fade_process(e, 2000, 128, 1.0, -1.0 / sr, 0.5f);
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(fabs(snap.fade.amount - 0.75) < 1e-6);
  const le_fade_image stale = snap.fade;
  uint64_t pending = 0;
  CHECK(le_engine_toggle_fade(e, 0, 1.0f, &pending) == LE_OK); /* unapplied */

  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, sr, 1, 1, 1000, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  int32_t result = 0;
  CHECK(le_engine_read_request_result(e, pending, &result) == LE_ERR_INVALID);
  uint64_t again = 0;
  CHECK(le_engine_install_fade(e, 0, &stale, &again) == LE_ERR_INVALID);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED);
  CHECK(fabs(snap.fade.amount - 0.75) < 1e-6);
  CHECK(snap.fade.target == 0.0f);
  CHECK(snap.fade.full_travel_seconds == 1.0f);
  CHECK(snap.fade.lifetime == stale.lifetime + 1);
  CHECK(snap.fade.generation == stale.generation);
  /* Silent while stopped; the envelope keeps its rate once callbacks run. */
  float input[128] = {0}, output[128];
  for (int at = 0; at < 400; at += 128) {
    const int n = at + 128 > 400 ? 400 - at : 128;
    le_engine_process(e, output, input, n);
    for (int i = 0; i < n; ++i) CHECK(output[i] == 0.0f);
  }
  CHECK(le_engine_play(e, 0) == LE_OK);
  fade_process(e, 1000, 128, 0.75 - 400.0 / sr, -1.0 / sr, 0.5f);
  le_engine_get_track(e, 0, &snap);
  CHECK(fabs(snap.fade.amount - (0.75 - 1400.0 / sr)) < 1e-6);
  /* A fresh admission under the new lifetime is accepted. */
  le_fade_image fresh = snap.fade;
  fresh.amount = fresh.target = 0.25f;
  fresh.full_travel_seconds = 0;
  CHECK(le_engine_install_fade(e, 0, &fresh, &again) == LE_OK);
  drain(e);
  fade_result(e, again, LE_OK);
  le_engine_destroy(e);
}

/* A cleared take whose restore point is on the history survives the reopen,
 * including one whose Clear applied but whose report was never collected. */
static void test_reopen_keeps_clear_history(void) {
  printf("test_reopen_keeps_clear_history\n");
  le_snapshot s;
  for (int collected = 0; collected < 2; ++collected) {
    le_engine* e = make_configured_engine();
    record_base_loop(e, 1.0f);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
    drain(e); /* the CLEAR applies */
    if (collected) le_engine_get_snapshot(e, &s); /* collects the report */
    CHECK(e->tracks[0].undo_count == 1);
    CHECK(e->tracks[0].undo_stack[0].fade_ready == collected);
    CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
    CHECK(e->tracks[0].undo_stack[0].fade_ready == 1);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
    CHECK(s.tracks[0].clear_restore == 1);
    CHECK(s.tracks[0].undo_depth == 0);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    drain(e);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state != LE_TRACK_EMPTY);
    CHECK(s.tracks[0].length_frames == LOOP_N);
    reopen_check_const(e, 0, 1.0f, LOOP_N);
    le_engine_destroy(e);
  }
}

/* Another sample rate or loop cap clears the material with the matching
 * outcome and leaves the engine exactly as le_engine_configure does. */
static void test_reopen_mismatch_clears(void) {
  printf("test_reopen_mismatch_clears\n");
  le_snapshot s;
  le_engine* e = make_configured_engine();
  record_base_loop(e, 1.0f);
  reopen_overdub_pass(e, 0.5f);
  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, 44100, 1, 1, 1000, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_CLEARED_RATE);
  le_engine_get_snapshot(e, &s);
  CHECK(s.sample_rate == 44100);
  CHECK(s.master_length_frames == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].settled_take_id == 0);
  CHECK(s.primary_track == -1);
  CHECK(e->tracks[0].undo_count == 0 && e->tracks[0].redo_count == 0);
  le_engine_destroy(e);

  e = make_configured_engine();
  record_base_loop(e, 1.0f);
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 2000, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_CLEARED_CAP);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, 0) == 2000);
  le_engine_destroy(e);

  /* The default cap (0) names the same buffers: still retained. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 0) == LE_OK);
  record_base_loop(e, 1.0f);
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 0, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  le_engine_destroy(e);
}

/* A press made while the device is away (the ring is configured-gated) on
 * ONE track never costs the others: that track is dropped and reported, every
 * other loop stays byte-exact. The reviewer's repro for #1140. */
static void test_reopen_pending_press_drops_only_that_track(void) {
  printf("test_reopen_pending_press_drops_only_that_track\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  int32_t mask;
  record_base_loop(e, 1.0f);
  reopen_align_head(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  /* Device lost here; no more callbacks. One undo press on track 1 (no
   * layers: UNDO_TO_EMPTY posted, never applied). */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x2);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].length_frames == LOOP_N);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].length_frames == 0);
  CHECK(s.tracks[1].undo_depth == 0 && s.tracks[1].redo_depth == 0);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(s.primary_track == 0);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  CHECK(le_engine_play(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(out[i] == 1.0f); /* track 0 alone */
  le_engine_destroy(e);
}

/* Each unapplied state shape drops its own track with RETAINED_PARTIAL and
 * the matching mask bit; a drop that empties the rig resets the master as a
 * clear does; only a rate or cap mismatch clears the whole engine. */
static void test_reopen_pending_state_drops_track(void) {
  printf("test_reopen_pending_state_drops_track\n");
  le_snapshot s;
  float out[64];
  int32_t mask;
  float pcm[LOOP_N] = {0.5f, 0.5f, 0.5f, 0.5f};

  le_engine* e = make_configured_engine(); /* unapplied CLEAR, only content */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].length_frames == 0);
  CHECK(s.master_length_frames == 0); /* the rig is empty: master reset */
  CHECK(s.primary_track == -1);
  record_base_loop(e, 0.5f); /* a new defining take works */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N);
  le_engine_destroy(e);

  e = make_configured_engine(); /* unapplied UNDO_TO_EMPTY */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].redo_depth == 0);
  CHECK(s.master_length_frames == 0);
  le_engine_destroy(e);

  e = make_configured_engine(); /* unapplied REDO_FROM_EMPTY */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].redo_depth == 1);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].redo_depth == 0);
  CHECK(s.master_length_frames == 0);
  le_engine_destroy(e);

  e = make_configured_engine(); /* cancelled take, event not yet filed */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, 2, out);
  CHECK(le_engine_undo(e, 1) == LE_OK);
  CHECK(e->tracks[1].cancel_pending);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x2);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY && s.tracks[1].redo_depth == 0);
  CHECK(s.master_length_frames == LOOP_N);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  le_engine_destroy(e);

  e = make_configured_engine(); /* Session import without its commit */
  CHECK(le_engine_import_track(e, 0, pcm, LOOP_N) == LE_OK);
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 0);
  le_engine_destroy(e);

  e = make_configured_engine(); /* ...and the committed Session is retained */
  CHECK(le_engine_import_track(e, 0, pcm, LOOP_N) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  drain(e);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  reopen_check_const(e, 0, 0.5f, LOOP_N);
  le_engine_destroy(e);

  e = make_configured_engine(); /* a pending press never widens a rate clear */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  int32_t outcome = -1;
  mask = -99;
  CHECK(le_engine_reopen_configured(e, 44100, 1, 1, 1000, &outcome, &mask) ==
        LE_OK);
  CHECK(outcome == LE_REOPEN_CLEARED_RATE);
  CHECK(mask == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.sample_rate == 44100 && s.tracks[0].state == LE_TRACK_EMPTY);
  le_engine_destroy(e);
}

/* Two complete passes at the loss — the older parked on a full event ring,
 * the newer frozen complete in the armed slot — are BOTH filed, oldest first. */
static void test_reopen_files_two_complete_passes(void) {
  printf("test_reopen_files_two_complete_passes\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in: two shadows posted */
  le_command junk = {0};
  junk.code = 9999;
  while (le_ring_push(&e->evt_ring, junk)) {
  }
  process_const(e, 0.5f, LOOP_N, out); /* pass 1 completes, parks */
  CHECK(e->tracks[0].dub_retire_slot >= 0);
  const int32_t parked = e->tracks[0].dub_retire_slot;
  process_const(e, 0.5f, LOOP_N, out); /* pass 2 completes, frozen */
  CHECK(e->tracks[0].dub_slot >= 0 && e->tracks[0].dub_slot != parked);
  CHECK(e->tracks[0].dub_count >= e->tracks[0].dub_len);
  CHECK(e->tracks[0].dub_retire_slot == parked);
  reopen_check_const(e, 0, 2.0f, LOOP_N);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].undo_depth == 2);
  reopen_check_const(e, 0, 2.0f, LOOP_N);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  reopen_check_const(e, 0, 1.5f, LOOP_N); /* the newer pass peels first */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  le_engine_destroy(e);
}

/* Builds [L0(base), PEEL] with a redo marker on track 0: two passes, two
 * peels, one undo. Live = base + one pass. */
static void reopen_peel_history(le_engine* e, float pass) {
  reopen_overdub_pass(e, pass);
  reopen_overdub_pass(e, pass);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  const le_track* t = &e->tracks[0];
  CHECK(t->undo_count == 2 && t->undo_stack[0].kind == LE_HIST_LAYER &&
        t->undo_stack[1].kind == LE_HIST_PEEL);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_PEEL &&
        t->redo_stack[0].slot == -1 && t->redo_stack[0].skipped == 1);
}

/* #1164 Part 2: Peel history is material. A retained track keeps its PEEL
 * entries and redo markers across a reopen, so Undo restores the peeled layer
 * and Redo re-peels; a track dropped for a Session commit the device never
 * applied loses them with its material. */
static void test_reopen_keeps_peel_history(void) {
  printf("test_reopen_keeps_peel_history\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  record_base_loop(e, 1.0f);
  reopen_peel_history(e, 0.5f); /* [L0(1.0), Pa(2.0)], live 1.5, [M] */
  /* Track 1 is a Session recall of the same history shape whose commit the
   * device never applied: finalized, still EMPTY with a length. */
  const float images[3] = {2.0f, 2.5f, 2.25f};
  for (int32_t o = 0; o < 3; ++o) {
    float pcm[LOOP_N];
    for (int i = 0; i < LOOP_N; ++i) pcm[i] = images[o];
    CHECK(le_engine_import_layer(e, 1, 0, o, pcm, LOOP_N) == LE_OK);
  }
  const int32_t kinds[3] = {LE_HIST_LAYER, LE_HIST_PEEL, LE_HIST_PEEL};
  const int32_t skipped[3] = {0, 0, 1};
  CHECK(finalize_uniform(e, 1, kinds, skipped, 3, 2, LOOP_N) == LE_OK);
  CHECK(e->tracks[1].undo_count == 2 && e->tracks[1].redo_count == 1 &&
        e->tracks[1].redo_stack[0].slot == -1);
  int32_t mask;
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x2);

  const le_track* t = &e->tracks[0];
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].undo_depth == 2 && s.tracks[0].redo_depth == 1);
  CHECK(s.tracks[0].peel_depth == 1);
  CHECK(t->undo_count == 2 && t->undo_stack[1].kind == LE_HIST_PEEL);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_PEEL &&
        t->redo_stack[0].slot == -1);
  reopen_check_const(e, 0, 1.5f, LOOP_N);
  /* Undo after the reopen restores the peeled layer ... */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  reopen_check_const(e, 0, 2.0f, LOOP_N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].peel_depth == 2 && s.tracks[0].redo_depth == 2);
  /* ... and both markers re-peel in order, down to the original. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  reopen_check_const(e, 0, 1.5f, LOOP_N);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);

  /* The dropped track lost its history with its material. */
  const le_track* t1 = &e->tracks[1];
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY && s.tracks[1].length_frames == 0);
  CHECK(s.tracks[1].undo_depth == 0 && s.tracks[1].redo_depth == 0 &&
        s.tracks[1].peel_depth == 0 && s.tracks[1].clear_restore == 0);
  CHECK(t1->undo_count == 0 && t1->redo_count == 0);
  CHECK(le_engine_peel(e, 1) == LE_ERR_INVALID);
  CHECK(le_engine_redo(e, 1) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* #1168 Part 2: length edits are material. A retained track keeps its LENGTH
 * entries with their lengths and playhead maps (Undo restores the original
 * length, Redo re-applies the edit); a track whose edit was posted but never
 * applied at the loss is dropped alone, reported in the mask, and its pinned
 * slot goes with its material. */
static void test_reopen_keeps_length_history(void) {
  printf("test_reopen_keeps_length_history\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  drain(e);
  float out[64];
  const float pcm[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_seq(e, pcm, 8, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  uint64_t id = 0;
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id) == LE_OK);
  drain(e);
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_LAST_HALF, &id) == LE_OK);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s); /* files the Undo */
  const le_track* t = &e->tracks[0];
  CHECK(t->undo_count == 1 && t->redo_count == 1);
  const le_hist_entry undo = t->undo_stack[0];
  const le_hist_entry redo = t->redo_stack[0];
  CHECK(undo.kind == LE_HIST_LENGTH && undo.len == 8);
  CHECK(redo.kind == LE_HIST_LENGTH && redo.len == 8 && redo.start == 8);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  CHECK(t->undo_count == 1 && t->redo_count == 1);
  CHECK(memcmp(&t->undo_stack[0], &undo, sizeof(undo)) == 0);
  CHECK(memcmp(&t->redo_stack[0], &redo, sizeof(redo)) == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].length_frames == 16 && s.master_length_frames == 16);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 8 && s.master_length_frames == 8);
  reopen_check_track_pcm(e, 0, 0, pcm, 8);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 8 && s.tracks[0].undo_depth == 0);
  reopen_check_track_pcm(e, 0, 0, pcm, 8);
  le_engine_destroy(e);

  /* The edit posted, the device lost before it applied. */
  e = make_configured_engine();
  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  drain(e);
  record_base_loop(e, 1.0f);
  reopen_align_head(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  t = &e->tracks[1];
  CHECK(le_engine_edit_length(e, 1, LE_LENGTH_DOUBLE, &id) == LE_OK);
  CHECK(t->length_pending != 0 && t->outstanding_count >= 1);
  int32_t mask;
  CHECK(reopen_same_mask(e, &mask) == LE_REOPEN_RETAINED_PARTIAL);
  CHECK(mask == 0x2);
  CHECK(t->length_pending == 0 && t->outstanding_count == 0);
  CHECK(t->undo_count == 0 && t->redo_count == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY && s.tracks[1].length_frames == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  /* Nothing on the dropped track waits any more: a new take records. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  reopen_align_head(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 3.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].length_frames == LOOP_N);
  le_engine_destroy(e);
}

/* A device with fewer channels keeps the material; a lane routed to an input
 * or output the device lacks records silence and writes nothing (an output
 * buffer sized exactly to the device makes any stray write an ASAN error). */
static void test_reopen_fewer_channels_keeps_material(void) {
  printf("test_reopen_fewer_channels_keeps_material\n");
  le_engine* e = make_two_lane_engine(); /* 2 in, 2 out */
  le_snapshot s;
  record_two_lane(e, 1.0f, 2.0f);
  int32_t outcome = -1;
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 1000, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.input_channels == 1 && s.output_channels == 1);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  const float lane1[LOOP_N] = {2.0f, 2.0f, 2.0f, 2.0f};
  reopen_check_track_pcm(e, 0, 1, lane1, LOOP_N);
  /* Lane 1 keeps its default route (input 1, outputs 0+1): make the output
   * route the missing channel ONLY, so nothing of it may reach `out`. */
  CHECK(le_engine_set_lane_output(e, 0, 1, 0x2) == LE_OK);
  CHECK(le_engine_set_lane_input(e, 0, 1, 1) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  float out[LOOP_N];
  float in[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) in[i] = 0.0f;
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(out[i] == 1.0f); /* lane 0 alone */
  /* Overdub through the one input: lane 0 layers it, lane 1 hears silence. */
  for (int i = 0; i < LOOP_N; ++i) in[i] = 0.5f;
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  settle_dub(e);
  const float lane0[LOOP_N] = {1.5f, 1.5f, 1.5f, 1.5f};
  reopen_check_track_pcm(e, 0, 0, lane0, LOOP_N);
  reopen_check_track_pcm(e, 0, 1, lane1, LOOP_N);
  le_engine_destroy(e);
}

/* ---- le_engine_reopen through a fake device backend ---- */

static int32_t fake_open_result = LE_OK;
static int32_t fake_start_result = LE_OK;
static int32_t fake_rate = 48000;
static int fake_opens = 0;
static int fake_starts = 0;
static int fake_closes = 0;

static int32_t fake_open(le_engine* e, const le_config* cfg,
                         le_device_open_result* out) {
  (void)e;
  (void)cfg;
  fake_opens++;
  if (fake_open_result != LE_OK) return fake_open_result;
  memset(out, 0, sizeof(*out));
  out->sample_rate = fake_rate;
  out->input_channels = 1;
  out->output_channels = 1;
  out->buffer_frames = 64;
  out->active_backend = LE_BACKEND_MINIAUDIO;
  strncpy(out->device_name, "fake device", sizeof(out->device_name) - 1);
  return LE_OK;
}
static int32_t fake_start(le_engine* e) {
  fake_starts++;
  if (fake_start_result != LE_OK) return fake_start_result;
  le_engine_mark_started(e);
  return LE_OK;
}
static int32_t fake_stop(le_engine* e) {
  (void)e;
  return LE_OK;
}
static void fake_close(le_engine* e) {
  (void)e;
  fake_closes++;
}
static const le_device_backend fake_backend = {fake_open, fake_start,
                                              fake_stop, fake_close};

/* Preconditions, a failed open (nothing changes), a failed start after
 * retention (material retained and stopped), then a working reopen, and a
 * rate change through the real negotiated-parameter path. */
static void test_reopen_device_lifecycle(void) {
  printf("test_reopen_device_lifecycle\n");
  le_test_backend_override = &fake_backend;
  fake_open_result = LE_OK;
  fake_start_result = LE_OK;
  fake_rate = 48000;
  le_config cfg = {0};
  cfg.sample_rate = 48000;
  cfg.input_channels = 1;
  cfg.output_channels = 1;
  cfg.max_loop_frames = 1000;
  le_snapshot s;
  int32_t outcome = 77;

  le_engine* cold = le_engine_create();
  CHECK(le_engine_reopen(cold, &cfg, &outcome, NULL) == LE_ERR_NOT_RUNNING);
  CHECK(le_engine_reopen_configured(cold, 48000, 1, 1, 1000, &outcome, NULL) ==
        LE_ERR_NOT_RUNNING);
  CHECK(outcome == 77);
  le_engine_destroy(cold);

  le_engine* e = le_engine_create();
  CHECK(le_engine_start(e, &cfg) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 1 && s.device_present == 1);
  record_base_loop(e, 1.0f);
  CHECK(le_engine_reopen(e, &cfg, &outcome, NULL) == LE_ERR_ALREADY_RUNNING);
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 1000, &outcome, NULL) ==
        LE_ERR_ALREADY_RUNNING);
  CHECK(le_engine_stop(e) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* stop alone changes nothing */

  /* Open failure: untouched, still PLAYING-with-content, no outcome. */
  fake_open_result = LE_ERR_DEVICE;
  fake_closes = 0;
  CHECK(le_engine_reopen(e, &cfg, &outcome, NULL) == LE_ERR_DEVICE);
  CHECK(outcome == 77);
  CHECK(fake_closes == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  /* Presses are still accepted while stopped (the ring is configured-gated);
   * the reopen below discards them rather than firing a surprise overdub. */
  CHECK(le_engine_record(e, 0) == LE_OK);

  /* Start failure after retention: retained, stopped, device closed. */
  fake_open_result = LE_OK;
  fake_start_result = LE_ERR_DEVICE;
  CHECK(le_engine_reopen(e, &cfg, &outcome, NULL) == LE_ERR_DEVICE);
  CHECK(outcome == LE_REOPEN_RETAINED);
  CHECK(fake_closes == 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.master_length_frames == LOOP_N);
  reopen_check_const(e, 0, 1.0f, LOOP_N);

  /* The retry retains again and runs. */
  fake_start_result = LE_OK;
  outcome = 77;
  int32_t mask = -99;
  CHECK(le_engine_reopen(e, &cfg, &outcome, &mask) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  CHECK(mask == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 1 && s.device_present == 1);
  CHECK(s.sample_rate == 48000 && s.buffer_frames == 64);
  CHECK(strcmp(le_engine_device_name(e), "fake device") == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  float out[64];
  CHECK(le_engine_play(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(out[i] == 1.0f);

  /* The device comes back at another rate: cleared, explicitly. */
  CHECK(le_engine_stop(e) == LE_OK);
  fake_rate = 44100;
  CHECK(le_engine_reopen(e, &cfg, &outcome, NULL) == LE_OK);
  CHECK(outcome == LE_REOPEN_CLEARED_RATE);
  le_engine_get_snapshot(e, &s);
  CHECK(s.running == 1);
  CHECK(s.sample_rate == 44100);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);
  CHECK(le_engine_stop(e) == LE_OK);
  le_engine_destroy(e);
  le_test_backend_override = NULL;
}

/* A running performance capture ends at the drop with DEVICE_CHANGED, on the
 * retained path too; the loops themselves are kept. */
static void test_reopen_ends_performance_capture(void) {
  printf("test_reopen_ends_performance_capture\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  CHECK(perf_arm_dir(e, perf_test_dir()) == LE_OK);
  drain(e);
  record_base_loop(e, 1.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);
  CHECK(reopen_same(e) == LE_REOPEN_RETAINED);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  reopen_check_const(e, 0, 1.0f, LOOP_N);
  char json[4096];
  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
           perf_test_dir());
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(strstr(json, "\"stopped_early\": \"device_changed\"") != NULL);
  le_engine_destroy(e);
}
