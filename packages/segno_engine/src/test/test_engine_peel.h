/* #1164 Part 1: Peel removes the newest overdub layer as one recoverable
 * history entry. Literal PCM through le_engine_process and the checked
 * producers; the undo/redo stacks are read directly (control-thread state the
 * test owns between calls). Included by test_engine_core.c after
 * test_engine_history_replay.h (shares its fixture, arm image and parity
 * oracle for the armed-capture leg). */
/* cspell:ignore llpl llpp lppp pppp */

/* One overdub pass of `frames` frames of constant `value` on track 0, retired
 * (settle_layers pumps whole loops, so every pass starts at the loop top).
 * A partial pass (frames < LOOP_N) differs from its predecessor at exactly
 * `frames` positions, so positions distinguish images. */
static void peel_pass_frames(le_engine* e, float value, int frames) {
  float out[64];
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  process_const(e, value, frames, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);
  settle_layers(e);
}

static void peel_pass(le_engine* e, float value) {
  peel_pass_frames(e, value, LOOP_N);
}

static void peel_export(le_engine* e, float* pcm) {
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
}

static void peel_expect_image(le_engine* e, const float* want) {
  float pcm[LOOP_N];
  peel_export(e, pcm);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - want[i]) < 1e-6f);
}

static void peel_expect_depths(le_engine* e, int32_t ch, int peel, int undo,
                               int redo) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[ch].peel_depth == peel);
  CHECK(s.tracks[ch].undo_depth == undo);
  CHECK(s.tracks[ch].redo_depth == redo);
}

/* The undo stack's kinds, bottom first; failures name the caller's line. */
static void peel_expect_stack_at(le_engine* e, const int32_t* kinds, int count,
                                 int line) {
  const le_track* t = &e->tracks[0];
  if (t->undo_count != count) {
    printf("  FAIL: undo_count %d, expected %d (line %d)\n", t->undo_count,
           count, line);
    g_failures++;
  }
  for (int i = 0; i < count && i < t->undo_count; ++i) {
    if (t->undo_stack[i].kind != kinds[i]) {
      printf("  FAIL: undo_stack[%d].kind %d, expected %d (line %d)\n", i,
             t->undo_stack[i].kind, kinds[i], line);
      g_failures++;
    }
  }
}
#define peel_expect_stack(e, kinds, count) \
  peel_expect_stack_at(e, kinds, count, __LINE__)

/* Every pool slot referenced exactly once across live, the undo stack and the
 * redo images; a redo marker (slot -1) is only ever a PEEL. A redo-side CLEAR
 * point is left out: it pins the slot its restore republished live (or that
 * a later undo moved onto the undo stack), by design (le_restore_clear). */
static int peel_slots_unique(le_track* t) {
  unsigned char seen[LE_POOL_SLOTS] = {0};
  seen[load_i32(&t->lanes[0].a_live)] = 1;
  for (int i = 0; i < t->undo_count; ++i) {
    const int32_t s = t->undo_stack[i].slot;
    if (s < 0 || s >= LE_POOL_SLOTS || seen[s]) return 0;
    seen[s] = 1;
  }
  for (int i = 0; i < t->redo_count; ++i) {
    const int32_t s = t->redo_stack[i].slot;
    if (t->redo_stack[i].kind == LE_HIST_CLEAR) continue;
    if (s < 0) {
      if (t->redo_stack[i].kind != LE_HIST_PEEL) return 0;
      continue;
    }
    if (s >= LE_POOL_SLOTS || seen[s]) return 0;
    seen[s] = 1;
  }
  return 1;
}

/* A refusal must leave the stacks and the live slot exactly as they were. */
typedef struct {
  le_hist_entry undo[LE_POOL_SLOTS];
  le_hist_entry redo[LE_POOL_SLOTS];
  int undo_count, redo_count;
  int32_t live;
} peel_history_image;

static peel_history_image peel_history_snapshot(le_track* t) {
  peel_history_image h;
  memcpy(h.undo, t->undo_stack, sizeof(h.undo));
  memcpy(h.redo, t->redo_stack, sizeof(h.redo));
  h.undo_count = t->undo_count;
  h.redo_count = t->redo_count;
  h.live = load_i32(&t->lanes[0].a_live);
  return h;
}

static void peel_expect_unchanged(le_track* t, const peel_history_image* h) {
  CHECK(t->undo_count == h->undo_count);
  CHECK(t->redo_count == h->redo_count);
  CHECK(load_i32(&t->lanes[0].a_live) == h->live);
  CHECK(memcmp(t->undo_stack, h->undo,
               sizeof(le_hist_entry) * (size_t)h->undo_count) == 0);
  CHECK(memcmp(t->redo_stack, h->redo,
               sizeof(le_hist_entry) * (size_t)h->redo_count) == 0);
}

/* Plan section 1.7, with the overdub between peels a patterned partial pass
 * so positions distinguish images. Base 1.0, three passes of +0.5. */
static void test_peel_worked_example(void) {
  printf("test_peel_worked_example\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  record_base_loop(e, 1.0f);
  for (int i = 0; i < 3; ++i) peel_pass(e, .5f);
  check_content(e, 2.5f);
  peel_expect_depths(e, 0, 3, 3, 0);
  const int32_t lll[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_LAYER};
  peel_expect_stack(e, lll, 3);

  /* 1. Peel: live 2.0, [L0, L1, Pa(2.5, 0)]. */
  const int32_t live_before = load_i32(&t->lanes[0].a_live);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 2.0f);
  const int32_t llp[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_PEEL};
  peel_expect_stack(e, llp, 3);
  CHECK(t->undo_stack[2].slot == live_before);
  CHECK(t->undo_stack[2].skipped == 0);
  peel_expect_depths(e, 0, 2, 3, 0);
  CHECK(peel_slots_unique(t));

  /* 2. A partial +0.25 pass: [L0, L1, Pa, L3(2.0)], two positions differ. */
  peel_pass_frames(e, .25f, 2);
  float partial[LOOP_N];
  peel_export(e, partial);
  int raised = 0;
  for (int i = 0; i < LOOP_N; ++i) {
    if (fabsf(partial[i] - 2.25f) < 1e-6f) ++raised;
    else CHECK(fabsf(partial[i] - 2.0f) < 1e-6f);
  }
  CHECK(raised == 2);
  const int32_t llpl[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_PEEL,
                          LE_HIST_LAYER};
  peel_expect_stack(e, llpl, 4);
  peel_expect_depths(e, 0, 3, 4, 0);

  /* 3. Peel: live 2.0, [L0, L1, Pa, Pb(partial, 0)]. */
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 2.0f);
  const int32_t llpp[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_PEEL,
                          LE_HIST_PEEL};
  peel_expect_stack(e, llpp, 4);
  CHECK(t->undo_stack[3].skipped == 0);
  peel_expect_depths(e, 0, 2, 4, 0);

  /* 4. Peel through two PEEL entries: live 1.5, [L0, Pa, Pb, Pc(2.0, 2)]. */
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 1.5f);
  const int32_t lppp[] = {LE_HIST_LAYER, LE_HIST_PEEL, LE_HIST_PEEL,
                          LE_HIST_PEEL};
  peel_expect_stack(e, lppp, 4);
  CHECK(t->undo_stack[3].skipped == 2);
  peel_expect_depths(e, 0, 1, 4, 0);

  /* 5. Peel: live 1.0 (the original), [Pa, Pb, Pc, Pd(1.5, 3)]. */
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 1.0f);
  const int32_t pppp[] = {LE_HIST_PEEL, LE_HIST_PEEL, LE_HIST_PEEL,
                          LE_HIST_PEEL};
  peel_expect_stack(e, pppp, 4);
  CHECK(t->undo_stack[3].skipped == 3);
  peel_expect_depths(e, 0, 0, 4, 0);
  CHECK(peel_slots_unique(t));

  /* A sixth Peel is refused and the original plays. */
  const peel_history_image h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  peel_expect_unchanged(t, &h);
  check_content(e, 1.0f);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* 6. Undo x4 restores 1.5, 2.0, the partial pass and 2.0, and rebuilds
   * [L0, L1, Pa, L3] exactly. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  peel_expect_stack(e, lppp, 4);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_PEEL &&
        t->redo_stack[0].slot == -1 && t->redo_stack[0].skipped == 3);
  peel_expect_depths(e, 0, 1, 4, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  peel_expect_stack(e, llpp, 4);
  peel_expect_depths(e, 0, 2, 4, 2);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  peel_expect_image(e, partial);
  peel_expect_stack(e, llpl, 4);
  peel_expect_depths(e, 0, 3, 4, 3);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  peel_expect_stack(e, llp, 3);
  peel_expect_depths(e, 0, 2, 3, 4);
  CHECK(peel_slots_unique(t));
  /* Two more: 2.5 ([L0, L1, L2]) and 2.0; then to 1.0 and to empty. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.5f);
  peel_expect_stack(e, lll, 3);
  peel_expect_depths(e, 0, 3, 3, 5);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);
  peel_expect_depths(e, 0, 0, 0, 8);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* to empty */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].redo_depth == 9);

  /* Redo climbs back through every image, including the four re-peels. */
  const float climb[] = {1.0f, 1.5f, 2.0f, 2.5f, 2.0f, -1.0f, 2.0f, 1.5f, 1.0f};
  for (int i = 0; i < 9; ++i) {
    CHECK(le_engine_redo(e, 0) == LE_OK);
    drain(e);
    if (climb[i] < 0) peel_expect_image(e, partial);
    else check_content(e, climb[i]);
  }
  peel_expect_stack(e, pppp, 4);
  CHECK(t->undo_stack[0].skipped == 0 && t->undo_stack[1].skipped == 0 &&
        t->undo_stack[2].skipped == 2 && t->undo_stack[3].skipped == 3);
  peel_expect_depths(e, 0, 0, 4, 0);
  CHECK(peel_slots_unique(t));
  CHECK(le_engine_redo(e, 0) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* Peel is an edit: the redo branch dies with it. */
static void test_peel_drops_redo_branch(void) {
  printf("test_peel_drops_redo_branch\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* 1.5, redo holds 2.0 */
  peel_expect_depths(e, 0, 1, 1, 1);
  CHECK(le_engine_peel(e, 0) == LE_OK); /* 1.0 */
  check_content(e, 1.0f);
  CHECK(t->redo_count == 0 && t->empty_len == 0);
  peel_expect_depths(e, 0, 0, 1, 0);
  CHECK(le_engine_redo(e, 0) == LE_ERR_INVALID);
  check_content(e, 1.0f);
  le_engine_destroy(e);
}

/* Every refusal returns the specified code and mutates nothing. */
static void test_peel_refusals(void) {
  printf("test_peel_refusals\n");
  float out[64];
  le_snapshot s;
  CHECK(le_engine_peel(NULL, 0) == LE_ERR_INVALID);
  {
    le_engine* e = le_engine_create();
    CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_RUNNING);
    le_engine_destroy(e);
  }
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  CHECK(le_engine_peel(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_peel(e, LE_MAX_TRACKS) == LE_ERR_INVALID);
  /* EMPTY: nothing to peel. */
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  /* RECORDING. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 1.0f, 2, out);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  process_const(e, 1.0f, LOOP_N - 2, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  peel_pass(e, .5f);
  check_content(e, 1.5f);
  /* OVERDUBBING. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, .5f, 1, out);
  peel_history_image h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  /* The punch-out drain window: the layer is still in flight. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(load_i32(&t->a_layer_in_flight) == 1);
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  settle_layers(e);
  peel_expect_depths(e, 0, 2, 2, 0);
  /* A pending Count-in launch (the audio thread's publication; set here
   * directly, as the single-threaded test owns both sides). */
  store_i32(&t->a_pending_launch, 3);
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  store_i32(&t->a_pending_launch, 0);
  /* Behind an unapplied undo-to-empty, then on the emptied track. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* to empty: posted, not applied */
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  /* Behind an unapplied redo-from-empty; then with only the base live. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  drain(e);
  check_content(e, 1.0f);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  const float one_frame_pass[LOOP_N] = {2.0f, 1.5f, 1.5f, 1.5f};
  peel_expect_image(e, one_frame_pass);
  /* A cleared track, then restored. The Clear report is collected by the
   * control drain, which completes the restore point; collect it before the
   * snapshot so the comparison sees only what Peel did (nothing). */
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_drain_events(e);
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  peel_expect_unchanged(t, &h);
  peel_expect_depths(e, 0, 0, 0, 0);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  peel_expect_image(e, one_frame_pass);
  peel_expect_depths(e, 0, 2, 2, 1);
  /* A frozen Clear whose point is still to be filed. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, .5f, 1, out);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  CHECK(t->clear_restore_pending == 1);
  h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  drain(e);
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  le_engine_destroy(e);
}

/* Clear over PEEL entries keeps them beneath the restore point: after Clear
 * and Undo, the next Undo still restores the last peel. */
static void test_peel_under_clear(void) {
  printf("test_peel_under_clear\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 1.5f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  const int32_t lpc[] = {LE_HIST_LAYER, LE_HIST_PEEL, LE_HIST_CLEAR};
  peel_expect_stack(e, lpc, 3);
  peel_expect_depths(e, 0, 0, 0, 0);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  check_content(e, 1.5f);
  peel_expect_depths(e, 0, 1, 2, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  const int32_t ll[] = {LE_HIST_LAYER, LE_HIST_LAYER};
  peel_expect_stack(e, ll, 2);
  CHECK(peel_slots_unique(t));
  le_engine_destroy(e);
}

/* A STOPPED track stays STOPPED and silent through a peel; a PLAYING one is
 * continuous: the sample after the swap is the new image at that position. */
static void test_peel_stopped_and_playing(void) {
  printf("test_peel_stopped_and_playing\n");
  float out[64];
  le_snapshot s;
  le_engine* e = make_configured_engine();
  /* A patterned base so positions are visible in the output. */
  const float base[LOOP_N] = {1.0f, 2.0f, 3.0f, 4.0f};
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int i = 0; i < LOOP_N; ++i) process_const(e, base[i], 1, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  peel_pass(e, .5f);
  float dubbed[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) dubbed[i] = base[i] + .5f;
  peel_expect_image(e, dubbed);

  /* PLAYING: the next frame after the swap reads the pre-pass image. */
  process_const(e, 0.0f, 1, out);
  le_engine_get_snapshot(e, &s);
  const int next = (s.tracks[0].position_frames + 1) % LOOP_N;
  CHECK(le_engine_peel(e, 0) == LE_OK);
  process_const(e, 0.0f, 1, out);
  CHECK(fabsf(out[0] - base[next]) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].position_frames == next);

  /* STOPPED: the peel changes the image, not the transport. */
  peel_pass(e, .5f);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  drain(e);
  process_const(e, 0.0f, 2, out);
  CHECK(out[0] == 0 && out[1] == 0);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  peel_expect_image(e, base);
  process_const(e, 0.0f, 2, out);
  CHECK(out[0] == 0 && out[1] == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - base[i]) < 1e-6f);
  le_engine_destroy(e);
}

/* Two lanes swap together (one undo span); a multiple of two keeps its
 * multiple. */
static void test_peel_lanes_and_multiple(void) {
  printf("test_peel_lanes_and_multiple\n");
  {
    le_engine* e = le_engine_create();
    le_engine_configure(e, 48000, 2, 2, 1000);
    set_lane_count_and_publish(e, 0, 2);
    le_engine_set_lane_input(e, 0, 0, 0);
    le_engine_set_lane_input(e, 0, 1, 1);
    drain(e);
    le_engine_record(e, 0);
    pump_two_lane(e, .25f, .5f, LOOP_N, NULL, NULL);
    le_engine_record(e, 0);
    drain(e);
    le_engine_record(e, 0); /* punch in */
    pump_two_lane(e, .25f, .5f, LOOP_N, NULL, NULL);
    le_engine_record(e, 0); /* punch out */
    drain(e);
    settle_layers(e);
    le_track* t = &e->tracks[0];
    CHECK(t->undo_count == 1);
    float pcm[LOOP_N];
    CHECK(le_engine_export_track_lane(e, 0, 0, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - .5f) < 1e-6f);
    CHECK(le_engine_export_track_lane(e, 0, 1, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
    CHECK(le_engine_peel(e, 0) == LE_OK);
    CHECK(load_i32(&t->lanes[0].a_live) == load_i32(&t->lanes[1].a_live));
    CHECK(le_engine_export_track_lane(e, 0, 0, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - .25f) < 1e-6f);
    CHECK(le_engine_export_track_lane(e, 0, 1, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - .5f) < 1e-6f);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    CHECK(load_i32(&t->lanes[0].a_live) == load_i32(&t->lanes[1].a_live));
    CHECK(le_engine_export_track_lane(e, 0, 1, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
    le_engine_destroy(e);
  }
  {
    le_engine* e = make_configured_engine();
    float out[64];
    le_snapshot s;
    le_engine_record(e, 0);
    process_const(e, 1.0f, LOOP_N, out);
    le_engine_record(e, 0);
    drain(e);
    le_engine_record(e, 1);
    process_const(e, 2.0f, LOOP_N, out);
    process_const(e, 3.0f, LOOP_N, out);
    le_engine_record(e, 1);
    drain(e);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[1].multiple == 2);
    CHECK(le_engine_record(e, 1) == LE_OK);
    process_const(e, .5f, 2 * LOOP_N, out);
    CHECK(le_engine_record(e, 1) == LE_OK);
    drain(e);
    settle_layers(e);
    peel_expect_depths(e, 1, 1, 1, 0);
    CHECK(le_engine_peel(e, 1) == LE_OK);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[1].multiple == 2);
    CHECK(s.tracks[1].length_frames == 2 * LOOP_N);
    float pcm[2 * LOOP_N];
    CHECK(le_engine_export_track(e, 1, pcm, 2 * LOOP_N) == 2 * LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f);
    for (int i = LOOP_N; i < 2 * LOOP_N; ++i) CHECK(fabsf(pcm[i] - 3.0f) < 1e-6f);
    peel_expect_depths(e, 1, 0, 1, 0);
    le_engine_destroy(e);
  }
}

/* The restoration commit files PROCESSED: Peel never consumes it, Undo swaps
 * it and Redo re-files it as PROCESSED. */
static void test_peel_processed_restoration(void) {
  printf("test_peel_processed_restoration\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  static float restored_pcm[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) restored_pcm[i] = .125f;
  float* restored[LE_MAX_LANES] = {restored_pcm};
  const uint32_t rev = atomic_load(&t->a_audio_rev);
  CHECK(le_restore_commit_layer(e, 0, 0x1u, rev, LOOP_N, restored) == LE_OK);
  check_content(e, .125f);
  const int32_t lr[] = {LE_HIST_LAYER, LE_HIST_PROCESSED};
  peel_expect_stack(e, lr, 2);
  peel_expect_depths(e, 0, 0, 2, 0);
  peel_history_image h = peel_history_snapshot(t);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  peel_expect_unchanged(t, &h);
  int32_t kinds[4], skipped[4], undo_count = -1;
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 4, &undo_count) == 2);
  CHECK(kinds[0] == LE_HIST_LAYER && kinds[1] == LE_HIST_PROCESSED);
  CHECK(undo_count == 2);
  /* Undo swaps the raw take back and keeps the kind on the redo side. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_PROCESSED);
  peel_expect_depths(e, 0, 1, 1, 1);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, .125f);
  peel_expect_stack(e, lr, 2);
  peel_expect_depths(e, 0, 0, 2, 0);
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  /* With the restoration undone, the overdub beneath peels as usual. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  check_content(e, 1.0f);
  CHECK(t->redo_count == 0);
  le_engine_destroy(e);
}

/* Pool eviction with PEEL entries keeps every slot referenced exactly once,
 * and Undo of a surviving peel lands correctly — including the clamp once
 * everything beneath the peel's insertion point has been evicted. */
static void test_peel_pool_eviction(void) {
  printf("test_peel_pool_eviction\n");
  float out[64];
  le_snapshot s;
  {
    /* Leg 1: peels near the top of a nearly full pool survive eviction. */
    le_engine* e = make_configured_engine();
    le_track* t = &e->tracks[0];
    record_base_loop(e, 1.0f);
    const int passes = LE_POOL_SLOTS - 10;
    CHECK(le_engine_record(e, 0) == LE_OK);
    for (int pass = 0; pass < passes; ++pass) {
      process_const(e, .5f, LOOP_N, out);
      le_engine_get_snapshot(e, &s);
    }
    le_engine_record(e, 0);
    drain(e);
    settle_layers(e);
    CHECK(t->undo_count == passes);
    const float top = 1.0f + .5f * (float)passes;
    check_content(e, top);
    CHECK(le_engine_peel(e, 0) == LE_OK);
    CHECK(le_engine_peel(e, 0) == LE_OK);
    check_content(e, top - 1.0f);
    CHECK(t->undo_stack[passes - 1].kind == LE_HIST_PEEL);
    CHECK(t->undo_stack[passes - 1].skipped == 1);
    CHECK(peel_slots_unique(t));
    /* Twenty more passes evict from the bottom. */
    CHECK(le_engine_record(e, 0) == LE_OK);
    for (int pass = 0; pass < 20; ++pass) {
      process_const(e, .5f, LOOP_N, out);
      le_engine_get_snapshot(e, &s);
    }
    le_engine_record(e, 0);
    drain(e);
    settle_layers(e);
    CHECK(t->undo_count < passes + 20);
    CHECK(t->undo_count >= LE_POOL_SLOTS - 6);
    CHECK(peel_slots_unique(t));
    check_content(e, top - 1.0f + 10.0f);
    for (int i = 0; i < 20; ++i) CHECK(le_engine_undo(e, 0) == LE_OK);
    check_content(e, top - 1.0f);
    const int p = t->undo_count - 1;
    CHECK(t->undo_stack[p].kind == LE_HIST_PEEL && t->undo_stack[p].skipped == 1);
    CHECK(t->undo_stack[p - 1].kind == LE_HIST_PEEL);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* the surviving peel */
    check_content(e, top - .5f);
    CHECK(t->undo_stack[p].kind == LE_HIST_PEEL && t->undo_stack[p].skipped == 0);
    CHECK(t->undo_stack[p - 1].kind == LE_HIST_LAYER);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    check_content(e, top);
    CHECK(t->undo_stack[p].kind == LE_HIST_LAYER);
    CHECK(peel_slots_unique(t));
    le_engine_destroy(e);
  }
  {
    /* Leg 2: everything beneath a peel's insertion point is evicted, so the
     * re-inserted LAYER clamps to the bottom. */
    le_engine* e = make_configured_engine();
    le_track* t = &e->tracks[0];
    record_base_loop(e, 1.0f);
    peel_pass(e, .5f);
    peel_pass(e, .5f);
    CHECK(le_engine_peel(e, 0) == LE_OK);
    CHECK(le_engine_peel(e, 0) == LE_OK); /* [Pa(2.0, 0), Pb(1.5, 1)], live 1.0 */
    check_content(e, 1.0f);
    CHECK(t->undo_count == 2 && t->undo_stack[1].skipped == 1);
    CHECK(le_engine_record(e, 0) == LE_OK);
    int passes = 0;
    while (passes < LE_POOL_SLOTS + 10 &&
           !(t->undo_stack[0].kind == LE_HIST_PEEL &&
             t->undo_stack[0].skipped == 1)) {
      process_const(e, .5f, LOOP_N, out);
      le_engine_get_snapshot(e, &s);
      ++passes;
    }
    le_engine_record(e, 0);
    drain(e);
    settle_layers(e);
    CHECK(t->undo_stack[0].kind == LE_HIST_PEEL && t->undo_stack[0].skipped == 1);
    CHECK(peel_slots_unique(t));
    for (int i = 0; i < passes; ++i) {
      if (t->undo_count <= 1) break;
      CHECK(le_engine_undo(e, 0) == LE_OK);
    }
    check_content(e, 1.0f);
    CHECK(t->undo_count == 1 && t->undo_stack[0].kind == LE_HIST_PEEL);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* Pb: insert clamps to 0 */
    check_content(e, 1.5f);
    CHECK(t->undo_count == 1 && t->undo_stack[0].kind == LE_HIST_LAYER);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    check_content(e, 1.0f);
    CHECK(t->undo_count == 0);
    CHECK(peel_slots_unique(t));
    le_engine_destroy(e);
  }
}

/* Export ordinals enumerate image-bearing entries only (a redo marker is
 * skipped) and return exact images; export_history lists every kind. */
static void test_peel_export_ordinals_and_history(void) {
  printf("test_peel_export_ordinals_and_history\n");
  le_engine* e = make_configured_engine();
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f);
  CHECK(le_engine_peel(e, 0) == LE_OK); /* [L0, Pa], live 1.5 */
  peel_pass(e, .25f);                   /* [L0, Pa, L3(1.5)], live 1.75 */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* [L0, Pa], live 1.5, redo [L(1.75)] */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* [L0, L1], live 2.0, redo [L(1.75), M] */
  /* The marker is the newest redo entry, so it sits BETWEEN the live image
   * and the redo image in ordinal order and must be skipped, not torn on. */
  float pcm[LOOP_N];
  const float want[] = {1.0f, 1.5f, 2.0f, 1.75f};
  for (int ordinal = 0; ordinal < 4; ++ordinal) {
    CHECK(le_engine_export_layer(e, 0, 0, ordinal, pcm, LOOP_N) == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - want[ordinal]) < 1e-6f);
  }
  CHECK(le_engine_export_layer(e, 0, 0, 4, pcm, LOOP_N) == LE_ERR_INVALID);
  int32_t kinds[8], skipped[8], undo_count = -1;
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 8, &undo_count) == 4);
  CHECK(undo_count == 2);
  CHECK(kinds[0] == LE_HIST_LAYER && kinds[1] == LE_HIST_LAYER &&
        kinds[2] == LE_HIST_PEEL && kinds[3] == LE_HIST_LAYER);
  CHECK(skipped[0] == 0 && skipped[1] == 0 && skipped[2] == 0 && skipped[3] == 0);
  /* The count is the total even when fewer fit. */
  kinds[1] = -7;
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 1, &undo_count) == 4);
  CHECK(kinds[0] == LE_HIST_LAYER && kinds[1] == -7);
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 0, &undo_count) == 4);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* re-peel: [L0, Pa], redo [L(1.75)] */
  CHECK(le_engine_redo(e, 0) == LE_OK); /* [L0, Pa, L3], live 1.75 */
  check_content(e, 1.75f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* [L0, L1], live 2.0 */
  check_content(e, 2.0f);
  CHECK(le_engine_export_history(e, 0, NULL, skipped, 8, &undo_count) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 8, NULL) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_history(e, 0, kinds, skipped, -1, &undo_count) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_history(e, LE_MAX_TRACKS, kinds, skipped, 8,
                                 &undo_count) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_history(NULL, 0, kinds, skipped, 8, &undo_count) ==
        LE_ERR_INVALID);
  /* A skipped count rides along. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* [L0, Pa, L3], live 1.75 */
  CHECK(le_engine_peel(e, 0) == LE_OK); /* [L0, Pa, Pb(0)], live 1.5 */
  CHECK(le_engine_peel(e, 0) == LE_OK); /* [Pa, Pb, Pc(2)], live 1.0 */
  check_content(e, 1.0f);
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 8, &undo_count) == 3);
  CHECK(undo_count == 3);
  CHECK(kinds[0] == LE_HIST_PEEL && kinds[1] == LE_HIST_PEEL &&
        kinds[2] == LE_HIST_PEEL);
  CHECK(skipped[0] == 0 && skipped[1] == 0 && skipped[2] == 2);
  le_engine_destroy(e);
}

/* A running Fade continues through a peel: the envelope lives on the track,
 * not on the image. */
static void test_peel_keeps_fade(void) {
  printf("test_peel_keeps_fade\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  uint64_t id;
  CHECK(le_engine_toggle_fade(e, 0, 1.0f, &id) == LE_OK);
  for (int i = 0; i < 2400 / 64; ++i) process_const(e, 0.0f, 64, out);
  le_engine_get_snapshot(e, &s);
  const float before = s.tracks[0].fade.amount;
  CHECK(before < .96f && before > .94f);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  for (int i = 0; i < 2400 / 64; ++i) process_const(e, 0.0f, 64, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].fade.amount < before - .04f);
  CHECK(s.tracks[0].fade.amount > before - .06f);
  CHECK(s.tracks[0].fade.target == 0);
  check_content(e, 1.0f);
  le_engine_destroy(e);
}

/* The 325 fact carries the slot now live, the slot filed as PEEL and the
 * generation; the peel itself logs no 304. */
static void test_peel_perf_fact(void) {
  printf("test_peel_perf_fact\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  float out[64];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f);
  const char* dir = render_test_dir("peel-fact");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  const int32_t previous = load_i32(&t->lanes[0].a_live);
  const int32_t slot = t->undo_stack[t->undo_count - 1].slot;
  const uint32_t generation = t->dub_generation;
  CHECK(le_engine_peel(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(le_perf_disarm(e) == LE_OK);
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[1 << 20];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  int peels = 0;
  for (size_t i = 0; i < count; ++i) {
    le_perf_log_entry entry;
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code != LE_PLOG_PEEL) continue;
    ++peels;
    CHECK(entry.cmd.peel_log.channel == 0);
    CHECK(entry.cmd.peel_log.slot == slot);
    CHECK(entry.cmd.peel_log.previous == previous);
    CHECK(entry.cmd.peel_log.generation == generation);
    CHECK(entry.frame == (uint64_t)LOOP_N);
  }
  CHECK(peels == 1);
  CHECK(count_log_entries_for_channel(buf, count, LE_PLOG_UNDO, 0) == 1);
  CHECK(count_log_entries_for_channel(buf, count, LE_PLOG_REDO, 0) == 1);
  le_engine_destroy(e);
}

/* A peel during an armed capture stages its image like a layer Undo: the
 * stem replays peel, peel, Undo and Redo sample for sample, one 322 each. */
static void test_peel_stem_parity(void) {
  printf("test_peel_stem_parity\n");
  const int blocks[] = {1, 128};
  for (int b = 0; b < 2; ++b) {
    const int block = blocks[b];
    le_engine* e = history_fixture();
    float a[HR_LEN], bb[HR_LEN], c[HR_LEN];
    history_layer_patterns(a, bb, c);
    const char* dir = render_test_dir(block == 1 ? "peel-parity-1" : "peel-parity-128");
    const char* arm = history_arm_image(e, dir);
    CHECK(perf_arm_dir(e, dir) == LE_OK);
    drain(e);
    static float live[4096];
    int at = history_process(e, live, 0, 37, block);
    uint64_t swaps[4];
    CHECK(le_engine_peel(e, 0) == LE_OK); swaps[0] = (uint64_t)at; /* A+B */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_peel(e, 0) == LE_OK); swaps[1] = (uint64_t)at; /* A */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_undo(e, 0) == LE_OK); swaps[2] = (uint64_t)at; /* A+B */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_redo(e, 0) == LE_OK); swaps[3] = (uint64_t)at; /* A */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_perf_disarm(e) == LE_OK);
    CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID); /* the original plays */
    const int p0 = (int)swaps[0], p1 = (int)swaps[1], p2 = (int)swaps[2];
    CHECK(fabsf(live[p0 - 1] - (a[(p0 - 1) % HR_LEN] + bb[(p0 - 1) % HR_LEN] +
                               c[(p0 - 1) % HR_LEN])) < 1e-6f);
    CHECK(fabsf(live[p0] - (a[p0 % HR_LEN] + bb[p0 % HR_LEN])) < 1e-6f);
    CHECK(fabsf(live[p1] - a[p1 % HR_LEN]) < 1e-6f);
    CHECK(fabsf(live[p2] - (a[p2 % HR_LEN] + bb[p2 % HR_LEN])) < 1e-6f);
    le_perf_log_entry facts[8];
    const int n = history_source_facts(dir, 0, facts, 8);
    CHECK(n == 4);
    for (int i = 0; i < n && i < 4; ++i) {
      CHECK(facts[i].cmd.code == LE_PLOG_SOURCE_APPLIED);
      CHECK(facts[i].frame == swaps[i]);
      CHECK(facts[i].cmd.restore_log.image_id == (uint32_t)(i + 1));
    }
    CHECK(history_count_code(dir, LE_PLOG_PEEL, 0) == 2);
    history_render_parity(e, dir, arm, live, at);
    le_engine_destroy(e);
  }
}

/* PR #1180 review, finding 1: the audio thread pushes a layer's final retire
 * event BEFORE clearing a_layer_in_flight, so a retire can land between
 * le_engine_peel's first drain and its flag load. The hook runs the audio side
 * in exactly that window: the punch-out drain of a partial third pass retires
 * the layer and clears the flag while the event is still in the ring. Without
 * the second drain, Peel would consume the SECOND pass (live 1.5) and the late
 * retire would file a LAYER on top of the PEEL, out of chronological order. */
static int g_peel_race_fired;
static void peel_race_hook(le_engine* e, int stage) {
  if (stage != 1) return;
  le_test_peel_hook = NULL;
  g_peel_race_fired = 1;
  float out[64];
  le_track* t = &e->tracks[0];
  for (int i = 0; i < 64 && load_i32(&t->a_layer_in_flight); ++i) {
    process_const(e, 0.0f, LOOP_N, out);
  }
  CHECK(load_i32(&t->a_layer_in_flight) == 0);
  CHECK(t->undo_count == 2); /* the retire is still in the event ring */
}

static void test_peel_late_retire_race(void) {
  printf("test_peel_late_retire_race\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  float out[64];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f);
  check_content(e, 2.0f);
  /* A partial third pass: punch out, apply it, leave the layer in flight. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, .5f, 2, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(load_i32(&t->a_layer_in_flight) == 1);
  g_peel_race_fired = 0;
  le_test_peel_hook = peel_race_hook;
  CHECK(le_engine_peel(e, 0) == LE_OK);
  CHECK(le_test_peel_hook == NULL);
  CHECK(g_peel_race_fired == 1);
  /* The peel removed the third pass: live 2.0, [L0, L1, PEEL(partial)]. */
  check_content(e, 2.0f);
  const int32_t llp[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_PEEL};
  peel_expect_stack(e, llp, 3);
  CHECK(t->undo_stack[2].skipped == 0);
  peel_expect_depths(e, 0, 2, 3, 0);
  CHECK(peel_slots_unique(t));
  /* Undo restores the partial pass exactly, with the stack in order. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  float pcm[LOOP_N];
  peel_export(e, pcm);
  int raised = 0;
  for (int i = 0; i < LOOP_N; ++i) {
    if (fabsf(pcm[i] - 2.5f) < 1e-6f) ++raised;
    else CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f);
  }
  CHECK(raised == 2);
  const int32_t lll[] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_LAYER};
  peel_expect_stack(e, lll, 3);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  le_engine_destroy(e);
}

/* #1164 Part 2: the history a Session saves. Exports every image and entry of
 * track 0 the way the Session capture does (le_engine_export_history, then one
 * le_engine_export_layer per image ordinal). */
typedef struct {
  int32_t kinds[2 * LE_POOL_SLOTS];
  int32_t skipped[2 * LE_POOL_SLOTS];
  float images[8][LOOP_N];
  int32_t count, undo_count, image_count;
} peel_saved_history;

static void peel_save_history(le_engine* e, peel_saved_history* h) {
  const le_track* t = &e->tracks[0];
  h->count = le_engine_export_history(e, 0, h->kinds, h->skipped,
                                      2 * LE_POOL_SLOTS, &h->undo_count);
  CHECK(h->count == t->undo_count + t->redo_count);
  CHECK(h->undo_count == t->undo_count);
  h->image_count = h->undo_count + 1;
  for (int32_t i = h->undo_count; i < h->count; ++i) {
    if (h->kinds[i] != LE_HIST_PEEL) h->image_count++;
  }
  CHECK(h->image_count <= 8);
  for (int32_t o = 0; o < h->image_count; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, h->images[o], LOOP_N) == LOOP_N);
  }
  float past[LOOP_N];
  CHECK(le_engine_export_layer(e, 0, 0, h->image_count, past, LOOP_N) ==
        LE_ERR_INVALID);
}

/* Recalls a saved history into a fresh engine, stopped (the Session load). */
static le_engine* peel_recall_history(const peel_saved_history* h) {
  le_engine* e = make_configured_engine();
  for (int32_t o = 0; o < h->image_count; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, h->images[o], LOOP_N) == LE_OK);
  }
  CHECK(le_engine_finalize_history(e, 0, h->kinds, h->skipped, h->count,
                                   h->undo_count) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  drain(e);
  return e;
}

/* Review finding 2 of #1180: a redo-side PEEL marker and a PROCESSED entry
 * survive save and recall. The marker takes no image (so the lane is not torn)
 * and every kind comes back as it was (nothing flattens to LAYER), so the
 * recalled track answers Undo, Redo and Peel exactly as the live one did. */
static void test_peel_history_session_round_trip(void) {
  printf("test_peel_history_session_round_trip\n");
  le_engine* live = make_configured_engine();
  record_base_loop(live, 1.0f);
  peel_pass(live, .5f); /* [L0(1.0)], live 1.5 */
  static float restored_pcm[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) restored_pcm[i] = .125f;
  float* restored[LE_MAX_LANES] = {restored_pcm};
  CHECK(le_restore_commit_layer(live, 0, 0x1u,
                                atomic_load(&live->tracks[0].a_audio_rev),
                                LOOP_N, restored) == LE_OK);
  peel_pass(live, .5f);                    /* [L0, R(1.5), L2(.125)], .625 */
  CHECK(le_engine_peel(live, 0) == LE_OK); /* [L0, R, P(.625)], .125 */
  CHECK(le_engine_undo(live, 0) == LE_OK); /* [L0, R, L2], .625, redo [M] */
  check_content(live, .625f);
  peel_expect_depths(live, 0, 1, 3, 1);

  static peel_saved_history h;
  peel_save_history(live, &h);
  CHECK(h.count == 4 && h.undo_count == 3 && h.image_count == 4);
  CHECK(h.kinds[0] == LE_HIST_LAYER && h.kinds[1] == LE_HIST_PROCESSED &&
        h.kinds[2] == LE_HIST_LAYER && h.kinds[3] == LE_HIST_PEEL);
  le_engine_destroy(live);

  le_engine* e = peel_recall_history(&h);
  le_track* t = &e->tracks[0];
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  check_content(e, .625f);
  const int32_t lrl[] = {LE_HIST_LAYER, LE_HIST_PROCESSED, LE_HIST_LAYER};
  peel_expect_stack(e, lrl, 3);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_PEEL &&
        t->redo_stack[0].slot == -1);
  peel_expect_depths(e, 0, 1, 3, 1);
  CHECK(peel_slots_unique(t));

  /* Redo re-peels the overdub above the restoration ... */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, .125f);
  const int32_t lrp[] = {LE_HIST_LAYER, LE_HIST_PROCESSED, LE_HIST_PEEL};
  peel_expect_stack(e, lrp, 3);
  peel_expect_depths(e, 0, 0, 3, 0);
  /* ... and the restoration beneath still blocks Peel. */
  CHECK(le_engine_peel(e, 0) == LE_ERR_INVALID);
  /* Undo restores the peeled layer, then walks every saved image back. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, .625f);
  peel_expect_depths(e, 0, 1, 3, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, .125f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  peel_expect_depths(e, 0, 1, 1, 3);
  /* The restoration redoes as PROCESSED, not as a peelable layer. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, .125f);
  const int32_t lr[] = {LE_HIST_LAYER, LE_HIST_PROCESSED};
  peel_expect_stack(e, lr, 2);
  peel_expect_depths(e, 0, 0, 2, 2);
  CHECK(peel_slots_unique(t));
  le_engine_destroy(e);
}

/* le_engine_finalize_history is strict: every malformed history is refused
 * before anything is published, and the track stays EMPTY and importable. A
 * redo-side CLEAR point is accepted and redoes as a re-clear. */
static void test_peel_finalize_history_strict(void) {
  printf("test_peel_finalize_history_strict\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  le_snapshot s;
  float pcm[LOOP_N] = {.5f, .5f, .5f, .5f};
  for (int32_t o = 0; o < 3; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, pcm, LOOP_N) == LE_OK);
  }
  int32_t kinds[4] = {LE_HIST_LAYER, LE_HIST_PEEL, LE_HIST_LAYER, LE_HIST_PEEL};
  int32_t skipped[4] = {0, 0, 0, 0};
  /* Shape: handle, channel, counts and arrays. */
  CHECK(le_engine_finalize_history(NULL, 0, kinds, skipped, 2, 1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, LE_MAX_TRACKS, kinds, skipped, 2, 1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 1, 2) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, -1, 0) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 2, -1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, NULL, skipped, 2, 1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, NULL, 2, 1) == LE_ERR_INVALID);
  /* Kinds and payloads. */
  kinds[0] = 7;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 2, 2) ==
        LE_ERR_INVALID);
  kinds[0] = LE_HIST_LAYER;
  skipped[1] = -1; /* a negative peel payload */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 2, 2) ==
        LE_ERR_INVALID);
  skipped[1] = 0;
  skipped[0] = 1; /* a payload on a kind that has none */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 2, 2) ==
        LE_ERR_INVALID);
  skipped[0] = 0;
  kinds[0] = LE_HIST_CLEAR; /* a restore point beneath the live image */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 2, 2) ==
        LE_ERR_INVALID);
  kinds[0] = LE_HIST_LAYER;
  /* Images: [L, P] under live is 3 staged images; a redo LAYER above them
   * would be a fourth, never staged, so the reconstruction is torn. */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 3, 2) ==
        LE_ERR_INVALID);
  /* Capacity: an undo stack as deep as the pool, a redo side past it. */
  static int32_t many_kinds[LE_POOL_SLOTS + 1];
  static int32_t many_skipped[LE_POOL_SLOTS + 1];
  for (int i = 0; i <= LE_POOL_SLOTS; ++i) many_kinds[i] = LE_HIST_PEEL;
  CHECK(le_engine_finalize_history(e, 0, many_kinds, many_skipped,
                                   LE_POOL_SLOTS, LE_POOL_SLOTS) ==
        LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, many_kinds, many_skipped,
                                   LE_POOL_SLOTS + 1, 0) == LE_ERR_INVALID);
  /* Lanes at different lengths are torn. */
  CHECK(set_lane_count_and_publish(e, 0, 2) == LE_OK);
  for (int32_t o = 0; o < 3; ++o) {
    CHECK(le_engine_import_layer(e, 0, 1, o, pcm, LOOP_N - 1) == LE_OK);
  }
  kinds[2] = LE_HIST_PEEL;
  skipped[2] = 1;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 3, 2) ==
        LE_ERR_INVALID);
  for (int32_t o = 0; o < 3; ++o) {
    CHECK(le_engine_import_layer(e, 0, 1, o, pcm, LOOP_N) == LE_OK);
  }
  /* Nothing was published by any refusal. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(t->undo_count == 0 && t->redo_count == 0);
  CHECK(s.tracks[0].undo_depth == 0 && s.tracks[0].redo_depth == 0);
  /* [L, P] under live and a redo marker: 3 images, both lanes. */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, 3, 2) == LE_OK);
  CHECK(t->undo_count == 2 && t->undo_stack[0].slot == 0 &&
        t->undo_stack[1].kind == LE_HIST_PEEL && t->undo_stack[1].slot == 1);
  CHECK(t->redo_count == 1 && t->redo_stack[0].slot == -1 &&
        t->redo_stack[0].skipped == 1);
  CHECK(load_i32(&t->lanes[0].a_live) == 2 &&
        load_i32(&t->lanes[1].a_live) == 2);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 2 && s.tracks[0].redo_depth == 1 &&
        s.tracks[0].peel_depth == 1);
  le_engine_destroy(e);

  /* A redo-side CLEAR point is an image-bearing entry that re-clears. */
  e = make_configured_engine();
  t = &e->tracks[0];
  const float values[3] = {1.0f, 1.5f, 1.5f};
  for (int32_t o = 0; o < 3; ++o) {
    float v[LOOP_N];
    for (int i = 0; i < LOOP_N; ++i) v[i] = values[o];
    CHECK(le_engine_import_layer(e, 0, 0, o, v, LOOP_N) == LE_OK);
  }
  const int32_t lc[2] = {LE_HIST_LAYER, LE_HIST_CLEAR};
  const int32_t zero[2] = {0, 0};
  CHECK(le_engine_finalize_history(e, 0, lc, zero, 2, 1) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  drain(e);
  check_content(e, 1.5f);
  CHECK(t->redo_count == 1 && t->redo_stack[0].kind == LE_HIST_CLEAR &&
        t->redo_stack[0].slot == 2);
  CHECK(le_engine_redo_reclears(e, 0) == 1);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].clear_restore == 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  check_content(e, 1.5f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);
  le_engine_destroy(e);
}

/* Review finding 3 of PR #1194: finalize refuses the histories the live
 * engine cannot produce, each before anything is published — a CLEAR point
 * that is not the deepest redo entry, a redo marker with no layer to peel when
 * Redo reaches it, and an oversized skipped count — and accepts the shapes it
 * can produce, including the one pool eviction leaves behind. */
static int32_t peel_finalize_shape(const int32_t* kinds, const int32_t* skipped,
                                   int32_t count, int32_t undo_count,
                                   int32_t images) {
  le_engine* e = make_configured_engine();
  float pcm[LOOP_N] = {.5f, .5f, .5f, .5f};
  for (int32_t o = 0; o < images; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, pcm, LOOP_N) == LE_OK);
  }
  const int32_t result =
      le_engine_finalize_history(e, 0, kinds, skipped, count, undo_count);
  const le_track* t = &e->tracks[0];
  if (result != LE_OK) {
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
    CHECK(t->undo_count == 0 && t->redo_count == 0);
  }
  le_engine_destroy(e);
  return result;
}

static void test_peel_finalize_history_shapes(void) {
  printf("test_peel_finalize_history_shapes\n");
  const int32_t z[4] = {0, 0, 0, 0};
  /* A CLEAR above a redo LAYER: its Redo would re-clear and discard it. */
  const int32_t clear_mid[3] = {LE_HIST_LAYER, LE_HIST_CLEAR, LE_HIST_LAYER};
  CHECK(peel_finalize_shape(clear_mid, z, 3, 1, 4) == LE_ERR_INVALID);
  const int32_t two_clears[2] = {LE_HIST_CLEAR, LE_HIST_CLEAR};
  CHECK(peel_finalize_shape(two_clears, z, 2, 0, 3) == LE_ERR_INVALID);
  const int32_t clear_last[3] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_CLEAR};
  CHECK(peel_finalize_shape(clear_last, z, 3, 1, 4) == LE_OK);
  /* A marker under a restoration, or with nothing beneath the original:
   * Redo would refuse forever and strand the layer below it. */
  const int32_t blocked[3] = {LE_HIST_PROCESSED, LE_HIST_PEEL, LE_HIST_LAYER};
  CHECK(peel_finalize_shape(blocked, z, 3, 1, 3) == LE_ERR_INVALID);
  const int32_t bare[1] = {LE_HIST_PEEL};
  CHECK(peel_finalize_shape(bare, z, 1, 0, 1) == LE_ERR_INVALID);
  /* A redo LAYER re-filed first makes the marker beneath it reachable. */
  const int32_t reached[3] = {LE_HIST_PROCESSED, LE_HIST_LAYER, LE_HIST_PEEL};
  CHECK(peel_finalize_shape(reached, z, 3, 1, 3) == LE_OK);
  /* An undo-side PEEL claiming a skipped PEEL that is not beneath it. */
  const int32_t llp[3] = {LE_HIST_LAYER, LE_HIST_LAYER, LE_HIST_PEEL};
  const int32_t skip1[3] = {0, 0, 1};
  CHECK(peel_finalize_shape(llp, skip1, 3, 3, 4) == LE_ERR_INVALID);
  CHECK(peel_finalize_shape(llp, z, 3, 3, 4) == LE_OK);
  /* No stack holds LE_POOL_SLOTS entries above a layer. */
  const int32_t lone[1] = {LE_HIST_PEEL};
  const int32_t huge[1] = {LE_POOL_SLOTS};
  CHECK(peel_finalize_shape(lone, huge, 1, 1, 2) == LE_ERR_INVALID);
  /* Eviction: a PEEL run that reaches the bottom may be shorter than the
   * skipped count above it (Undo clamps the re-insertion there). */
  const int32_t pp[2] = {LE_HIST_PEEL, LE_HIST_PEEL};
  const int32_t skip3[2] = {0, 3};
  CHECK(peel_finalize_shape(pp, skip3, 2, 2, 3) == LE_OK);
}

/* Review finding 1 of PR #1194: the published undo depth reads 0 after an
 * Undo restores a Clear until the control side drains, while the stacks
 * already hold the restored layers. export_history reports the raw split, so
 * a capture taken in that window still finds the live image's ordinal. */
static void test_peel_export_history_raw_split(void) {
  printf("test_peel_export_history_raw_split\n");
  le_engine* e = make_configured_engine();
  le_track* t = &e->tracks[0];
  record_base_loop(e, 1.0f);
  peel_pass(e, .5f);
  peel_pass(e, .5f); /* [L0(1.0), L1(1.5)], live 2.0 */
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* the restore is posted */
  drain(e); /* the callback applies it; no control-side drain follows */
  CHECK(load_i32(&t->a_state) != LE_TRACK_EMPTY);
  CHECK(load_i32(&t->a_undo_depth) == 0); /* gated, not yet republished */
  int32_t kinds[4], skipped[4], undo_count = -1;
  CHECK(le_engine_export_history(e, 0, kinds, skipped, 4, &undo_count) == 3);
  CHECK(undo_count == 2);
  CHECK(kinds[0] == LE_HIST_LAYER && kinds[1] == LE_HIST_LAYER &&
        kinds[2] == LE_HIST_CLEAR);
  /* Ordinal undo_count is the live image, the one that plays. */
  float pcm[LOOP_N];
  CHECK(le_engine_export_layer(e, 0, 0, undo_count, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f);
  le_engine_destroy(e);
}

static void run_peel_tests(void) {
  test_peel_late_retire_race();
  test_peel_worked_example();
  test_peel_drops_redo_branch();
  test_peel_refusals();
  test_peel_under_clear();
  test_peel_stopped_and_playing();
  test_peel_lanes_and_multiple();
  test_peel_processed_restoration();
  test_peel_pool_eviction();
  test_peel_export_ordinals_and_history();
  test_peel_keeps_fade();
  test_peel_perf_fact();
  test_peel_stem_parity();
  test_peel_history_session_round_trip();
  test_peel_finalize_history_strict();
  test_peel_finalize_history_shapes();
  test_peel_export_history_raw_split();
}
