/* #1707: le_track_snapshot.history_seq numbers the edit the next Undo takes
 * back, in one order across tracks, so the host can tell whether a track's
 * Undo is newer than a clear. Included by test_engine_core.c after
 * test_engine_peel.h (reuses its passes and fixture). */

static int32_t history_seq(le_engine* e, int32_t channel) {
  le_track_snapshot s;
  le_engine_get_track(e, channel, &s);
  return s.history_seq;
}

static void test_history_seq_orders_edits(void) {
  printf("test_history_seq_orders_edits\n");
  le_engine* e = make_configured_engine();
  record_base_loop(e, 1.0f);
  /* The base take files no undo entry. */
  CHECK(history_seq(e, 0) == 0);

  peel_pass(e, .5f);
  const int32_t first = history_seq(e, 0);
  CHECK(first > 0);
  peel_pass(e, .5f);
  const int32_t second = history_seq(e, 0);
  CHECK(second > first);

  /* Undo goes back to the older edit's number. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(history_seq(e, 0) == first);

  /* A Redo files it again as the newest edit. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  const int32_t redone = history_seq(e, 0);
  CHECK(redone > second);

  /* A Peel is an edit of its own, though the undo depth stays the same. */
  CHECK(le_engine_peel(e, 0) == LE_OK);
  drain(e);
  const int32_t peeled = history_seq(e, 0);
  CHECK(peeled > redone);

  /* Undoing the Peel gives the layer back its own number. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(history_seq(e, 0) == redone);

  /* A clear's restore point is newer than everything before it, and its
   * Undo returns to the layer beneath. */
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  const int32_t cleared = history_seq(e, 0);
  CHECK(cleared > peeled);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(history_seq(e, 0) == redone);
  le_engine_destroy(e);
}

static void run_history_seq_tests(void) { test_history_seq_orders_edits(); }
