/* #1168 Part 1: Double, First half and Last half as one recoverable length
 * edit. Literal positional PCM through le_engine_process and the checked
 * producers; the stacks are read directly (control-thread state the test
 * owns between calls). Included by test_engine_core.c after
 * test_engine_peel.h (reuses its stack helpers). */

/* Feeds `n` frames of `in` (NULL: silence) in calls of `block` frames,
 * writing the mono output to `out` (NULL: discarded). */
static void len_run(le_engine* e, const float* in, float* out, int n,
                    int block) {
  static float zeros[512];
  static float scratch[512];
  for (int at = 0; at < n; at += block) {
    const int m = n - at < block ? n - at : block;
    le_engine_process(e, out ? out + at : scratch, in ? in + at : zeros,
                      (uint32_t)m);
  }
}

/* A take of `n` frames of `pcm` (NULL: silence) on [ch], started now. */
static void len_take(le_engine* e, int32_t ch, const float* pcm, int n) {
  CHECK(le_engine_record(e, ch) == LE_OK);
  len_run(e, pcm, NULL, n, 64);
  CHECK(le_engine_record(e, ch) == LE_OK);
  drain(e);
}

/* Lets the callback apply what was posted, then files it (the snapshot read
 * drains the control side). */
static void len_settle(le_engine* e) {
  le_snapshot s;
  drain(e);
  le_engine_get_snapshot(e, &s);
}

/* The fixture engine, grid-free: with loop<->grid sync off a re-clocked
 * only track keeps no bar count, so these tests measure the image and the
 * clock alone. test_length_reclock_keeps_tempo covers the grid. */
static le_engine* len_engine(void) {
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  drain(e);
  return e;
}

/* Admits an edit; on LE_OK lets the callback decide and returns its verdict,
 * otherwise the admission refusal. */
static int32_t len_edit(le_engine* e, int32_t ch, int32_t edit) {
  uint64_t id = 0;
  const int32_t rc = le_engine_edit_length(e, ch, edit, &id);
  if (rc != LE_OK) {
    CHECK(id == 0);
    return rc;
  }
  CHECK(id != 0);
  len_settle(e);
  int32_t verdict = 99;
  CHECK(le_engine_read_request_result(e, id, &verdict) == LE_OK);
  return verdict;
}

static void len_expect_track(le_engine* e, int32_t ch, int32_t len,
                             int32_t multiple, int32_t divisor, int32_t undo,
                             int32_t redo, int line) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  const le_track_snapshot* t = &s.tracks[ch];
  if (t->length_frames != len || t->multiple != multiple ||
      t->sync_divisor != divisor || t->undo_depth != undo ||
      t->redo_depth != redo) {
    printf("  FAIL: track %d len %d k %d n %d undo %d redo %d, expected "
           "%d %d %d %d %d (line %d)\n", ch, t->length_frames, t->multiple,
           t->sync_divisor, t->undo_depth, t->redo_depth, len, multiple,
           divisor, undo, redo, line);
    g_failures++;
  }
}
#define len_expect(e, ch, len, k, n, undo, redo) \
  len_expect_track(e, ch, len, k, n, undo, redo, __LINE__)

/* Every output frame equals `want`; failures name the caller's line. */
static void len_expect_out_at(const float* out, const float* want, int n,
                              int line) {
  for (int i = 0; i < n; ++i) {
    if (out[i] != want[i]) {
      printf("  FAIL: out[%d] %g, expected %g (line %d)\n", i, out[i],
             want[i], line);
      g_failures++;
      return;
    }
  }
}
#define len_expect_out(out, want, n) len_expect_out_at(out, want, n, __LINE__)

/* The live image of [ch] lane 0 equals `want`. */
static void len_expect_image(le_engine* e, int32_t ch, const float* want,
                             int n) {
  static float pcm[4096];
  CHECK(n <= 4096);
  CHECK(le_engine_export_track_lane(e, ch, 0, pcm, n) == n);
  len_expect_out(pcm, want, n);
}

/* Plan section 1.7: positional PCM i + 1 over 8 frames on track 1 under a
 * silent 8-frame master (Multi). Double keeps the playhead and repeats the
 * image; First half keeps the first; a second First half would make a half
 * base in Multi and is refused; Undo and Redo walk the exact images; an
 * overdub above the edit peels, the edit itself does not; and once track 1
 * is the only content its First half re-clocks the master. */
static void test_length_worked_example(void) {
  printf("test_length_worked_example\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[1];
  le_snapshot s;
  float pcm[8], out[64], want[64];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, NULL, 8);
  len_take(e, 1, pcm, 8);
  len_run(e, NULL, out, 5, 64);
  len_expect_out(out, pcm, 5);

  /* 1. Double at index 5: 6, 7, 8 continue, then both copies. */
  const int32_t original = load_i32(&t->lanes[0].a_live);
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
  len_expect(e, 1, 16, 2, 0, 1, 0);
  CHECK(t->undo_stack[0].kind == LE_HIST_LENGTH &&
        t->undo_stack[0].slot == original && t->undo_stack[0].len == 8);
  CHECK(t->outstanding_count == 0);
  len_run(e, NULL, out, 11, 64);
  for (int i = 0; i < 11; ++i) want[i] = pcm[(5 + i) % 8];
  len_expect_out(out, want, 11);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].position_frames == 15); /* the copy, segment 1 */
  CHECK(s.tracks[1].peel_depth == 0);       /* a Double is not a layer */
  float doubled[16];
  for (int i = 0; i < 16; ++i) doubled[i] = pcm[i % 8];
  len_expect_image(e, 1, doubled, 16);
  /* Export names each image at its own length. */
  float img[32];
  CHECK(le_engine_export_layer(e, 1, 0, 0, img, 32) == 8);
  len_expect_out(img, pcm, 8);
  CHECK(le_engine_export_layer(e, 1, 0, 1, img, 32) == 16);

  /* 2. First half of the doubled image, at index 0 of its first copy. */
  CHECK(len_edit(e, 1, LE_LENGTH_FIRST_HALF) == LE_OK);
  len_expect(e, 1, 8, 1, 0, 2, 0);
  CHECK(t->undo_stack[1].kind == LE_HIST_LENGTH && t->undo_stack[1].len == 16);
  len_run(e, NULL, out, 16, 64);
  for (int i = 0; i < 16; ++i) want[i] = pcm[i % 8];
  len_expect_out(out, want, 16);

  /* 3. A half base is not a Multi span while track 0 holds content. */
  peel_history_image h = peel_history_snapshot(t);
  CHECK(len_edit(e, 1, LE_LENGTH_FIRST_HALF) == LE_ERR_MODE_MISMATCH);
  CHECK(len_edit(e, 1, LE_LENGTH_LAST_HALF) == LE_ERR_MODE_MISMATCH);
  peel_expect_unchanged(t, &h);
  CHECK(t->outstanding_count == 0);

  /* 4. Undo, Undo, Redo, Redo through the command, each image exact. */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 16, 2, 0, 1, 1);
  len_expect_image(e, 1, doubled, 16);
  CHECK(t->redo_stack[0].kind == LE_HIST_LENGTH && t->redo_stack[0].len == 8);
  CHECK(le_engine_export_layer(e, 1, 0, 2, img, 32) == 8); /* the redo image */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 8, 1, 0, 0, 2);
  CHECK(load_i32(&t->lanes[0].a_live) == original);
  len_expect_image(e, 1, pcm, 8);
  CHECK(le_engine_export_layer(e, 1, 0, 1, img, 32) == 16);
  CHECK(le_engine_export_layer(e, 1, 0, 2, img, 32) == 8);
  CHECK(le_engine_redo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 16, 2, 0, 1, 1);
  CHECK(le_engine_redo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 8, 1, 0, 2, 0);
  len_expect_image(e, 1, pcm, 8);

  /* 5. An overdub above the edits peels; the edit beneath it does not. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  float half[8];
  for (int i = 0; i < 8; ++i) half[i] = .5f;
  len_run(e, half, NULL, 8, 64);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  settle_layers(e);
  for (int i = 0; i < 8; ++i) want[i] = pcm[i] + .5f;
  len_expect_image(e, 1, want, 8);
  CHECK(le_engine_peel(e, 1) == LE_OK);
  len_expect_image(e, 1, pcm, 8);
  CHECK(le_engine_peel(e, 1) == LE_ERR_INVALID);

  /* 6. The only content re-clocks the rig: record two bars, keep the first. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  len_run(e, NULL, NULL, 3, 64);
  le_engine_get_snapshot(e, &s);
  const int next = (s.tracks[1].position_frames + 1) % 8;
  CHECK(len_edit(e, 1, LE_LENGTH_FIRST_HALF) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4);
  len_expect(e, 1, 4, 1, 0, 4, 0); /* [LEN, LEN, PEEL, LEN] */
  len_run(e, NULL, out, 12, 64);
  for (int i = 0; i < 12; ++i) want[i] = pcm[(next % 4 + i) % 4];
  len_expect_out(out, want, 12);
  le_engine_destroy(e);
}

/* Multi, base 4: a k = 2 track keeps its segment through a Double, and a half
 * maps a playhead in the omitted region to the same phase of the kept one. */
static void test_length_multiple_segments(void) {
  printf("test_length_multiple_segments\n");
  float pcm[8], out[64], want[64];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  for (int edit = LE_LENGTH_FIRST_HALF; edit <= LE_LENGTH_LAST_HALF; ++edit) {
    for (int skip = 2; skip <= 6; skip += 4) {
      le_engine* e = len_engine();
      len_take(e, 0, NULL, 4);
      len_take(e, 1, pcm, 8);
      len_expect(e, 1, 8, 2, 0, 0, 0);
      len_run(e, NULL, out, skip, 64); /* next index: skip (2 or 6) */
      CHECK(len_edit(e, 1, edit) == LE_OK);
      len_expect(e, 1, 4, 1, 0, 1, 0);
      const int start = edit == LE_LENGTH_LAST_HALF ? 4 : 0;
      len_run(e, NULL, out, 10, 64);
      for (int i = 0; i < 10; ++i) {
        want[i] = pcm[start + (((skip - start) % 4 + 4) % 4 + i) % 4];
      }
      len_expect_out(out, want, 10);
      /* Undo maps back into the full image: the kept region continues
       * where the half was about to read. */
      const int next = (((skip - start) % 4 + 4) % 4 + 10) % 4;
      CHECK(le_engine_undo(e, 1) == LE_OK);
      len_settle(e);
      len_expect(e, 1, 8, 2, 0, 0, 1);
      len_run(e, NULL, out, 12, 64);
      for (int i = 0; i < 12; ++i) want[i] = pcm[(start + next + i) % 8];
      len_expect_out(out, want, 12);
      le_engine_destroy(e);
    }
  }
  /* Double at index 6 (segment 1): 7, 8, then the 16-frame image runs on. */
  le_engine* e = len_engine();
  len_take(e, 0, NULL, 4);
  float seq[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  len_take(e, 1, seq, 8);
  len_run(e, NULL, out, 6, 64);
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
  len_expect(e, 1, 16, 4, 0, 1, 0);
  len_run(e, NULL, out, 2, 64);
  CHECK(out[0] == 7 && out[1] == 8);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].position_frames == 7);
  len_run(e, NULL, out, 8, 64);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].position_frames == 15);
  for (int i = 0; i < 8; ++i) CHECK(out[i] == seq[i]);
  le_engine_destroy(e);
}

/* Multi, base 4, a k = 4 track: Last half keeps segments 2-3 as k = 2, so a
 * playhead in segment 1 or 3 must land in the kept segment at the same phase
 * (the new segment origin, start_iter). And a reversed track keeps its read
 * index through a Double: the origin is re-derived for the new length. */
static void test_length_segment_and_origin(void) {
  printf("test_length_segment_and_origin\n");
  float pcm[16], out[64], want[64];
  for (int i = 0; i < 16; ++i) pcm[i] = (float)(i + 1);
  for (int next = 5; next <= 13; next += 8) {
    for (int lead = 0; lead < 2; ++lead) {
      le_engine* e = len_engine();
      len_take(e, 0, NULL, 4);
      len_run(e, NULL, NULL, 4 * lead, 64); /* vary the loop iteration */
      len_take(e, 1, pcm, 16);
      len_expect(e, 1, 16, 4, 0, 0, 0);
      le_snapshot s;
      for (int guard = 0; guard < 64; ++guard) {
        len_run(e, NULL, NULL, 1, 1);
        le_engine_get_snapshot(e, &s);
        if ((s.tracks[1].position_frames + 1) % 16 == next) break;
      }
      CHECK((s.tracks[1].position_frames + 1) % 16 == next);
      CHECK(len_edit(e, 1, LE_LENGTH_LAST_HALF) == LE_OK);
      len_expect(e, 1, 8, 2, 0, 1, 0);
      /* The segment moved, not the origin: the read stays on the segment
       * grid the overdub write head uses. */
      CHECK(e->tracks[1].head.origin == 0.0);
      len_run(e, NULL, out, 12, 64);
      for (int i = 0; i < 12; ++i) want[i] = pcm[8 + ((next - 8 + 8) % 8 + i) % 8];
      len_expect_out(out, want, 12);
      le_engine_destroy(e);
    }
  }
  /* A forward Double from k = 1 after an odd or even number of base loops:
   * the copy follows the current segment, with the origin still zero. */
  for (int lead = 0; lead < 2; ++lead) {
    le_engine* e = len_engine();
    len_take(e, 0, NULL, 4);
    len_take(e, 1, pcm, 4);
    len_run(e, NULL, NULL, 4 * lead + 2, 64);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int cur = (s.tracks[1].position_frames + 1) % 4;
    CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
    CHECK(e->tracks[1].head.origin == 0.0);
    len_run(e, NULL, out, 1, 64);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[1].position_frames == cur);
    le_engine_destroy(e);
  }
  /* Reversed Double: the next read index is kept, in the first copy. */
  for (int steps = 1; steps <= 7; steps += 2) {
    le_engine* e = len_engine();
    len_take(e, 0, NULL, 8);
    len_take(e, 1, pcm, 8);
    uint64_t rid = 0;
    CHECK(le_engine_toggle_reverse(e, 1, &rid) == LE_OK);
    drain(e);
    len_run(e, NULL, NULL, steps, 64);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int cur = (s.tracks[1].position_frames + 7) % 8; /* reading down */
    CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
    len_run(e, NULL, out, 1, 64);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[1].position_frames == cur);
    CHECK(out[0] == pcm[cur]);
    le_engine_destroy(e);
  }
}

/* Sync, silent 16-frame primary: a division 2 halves to a division 4 that
 * stays phase-locked to the primary top, Doubles to one base loop, refuses a
 * division 8, and the crowned primary with a dependent is refused; alone it
 * re-clocks and stays one base loop, so Sync quantization keeps holding. */
static void test_length_sync_division(void) {
  printf("test_length_sync_division\n");
  float out[64], want[64];
  const float pattern[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  for (int edit = LE_LENGTH_FIRST_HALF; edit <= LE_LENGTH_LAST_HALF; ++edit) {
    le_engine* e = len_engine();
    CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
    drain(e);
    sb_make_primary(e, 0.0f);
    sb_arm_and_start(e, 1);
    process_seq(e, pattern, 8, out);
    le_engine_record(e, 1);
    drain(e);
    len_expect(e, 1, 8, 1, 2, 0, 0);
    len_run(e, NULL, out, 5, 64);
    CHECK(len_edit(e, 1, edit) == LE_OK);
    len_expect(e, 1, 4, 1, 4, 1, 0);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    len_run(e, NULL, NULL, (SB_BASE - s.master_position_frames) % SB_BASE, 64);
    len_run(e, NULL, out, 2 * SB_BASE, 64);
    const int start = edit == LE_LENGTH_LAST_HALF ? 4 : 0;
    for (int i = 0; i < 2 * SB_BASE; ++i) want[i] = pattern[start + i % 4];
    len_expect_out(out, want, 2 * SB_BASE);
    /* 16 / 2 frames would be a division 8: no such Sync span. */
    CHECK(len_edit(e, 1, LE_LENGTH_FIRST_HALF) == LE_ERR_MODE_MISMATCH);
    /* Double the division 4 to a division 2, then to one base loop. */
    CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
    len_expect(e, 1, 8, 1, 2, 2, 0);
    CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
    len_expect(e, 1, 16, 1, 0, 3, 0);
    le_engine_get_snapshot(e, &s);
    len_run(e, NULL, NULL, (SB_BASE - s.master_position_frames) % SB_BASE, 64);
    len_run(e, NULL, out, SB_BASE, 64);
    for (int i = 0; i < SB_BASE; ++i) want[i] = pattern[start + i % 4];
    len_expect_out(out, want, SB_BASE);
    /* The crowned primary with a dependent is refused either way. */
    CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_MODE_MISMATCH);
    CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_ERR_MODE_MISMATCH);
    /* Alone it re-clocks and stays exactly one base loop. */
    CHECK(le_engine_clear(e, 1) == LE_OK);
    drain(e);
    CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
    le_engine_get_snapshot(e, &s);
    CHECK(s.master_length_frames == 2 * SB_BASE);
    len_expect(e, 0, 2 * SB_BASE, 1, 0, 1, 0);
    CHECK(le_sync_quantize_active(e, 1));
    le_engine_destroy(e);
  }
}

/* Free: an odd length halves to ceil(len / 2), the halves sharing the middle
 * frame; a playhead in the omitted half keeps its phase; Undo maps back. */
static void test_length_free_odd_halves(void) {
  printf("test_length_free_odd_halves\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float out[64], want[64];
  const float pcm[7] = {1, 2, 3, 4, 5, 6, 7};
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  drain(e);
  len_take(e, 0, pcm, 7);
  len_run(e, NULL, out, 5, 64); /* next index 5, in the second half */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].position_frames == 4);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  len_expect(e, 0, 4, 1, 0, 1, 0);
  const float first[4] = {1, 2, 3, 4};
  len_expect_image(e, 0, first, 4);
  len_run(e, NULL, out, 6, 64);
  for (int i = 0; i < 6; ++i) want[i] = first[(1 + i) % 4];
  len_expect_out(out, want, 6);
  CHECK(t->free_clock.length == 4);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  len_expect(e, 0, 7, 1, 0, 0, 1);
  len_expect_image(e, 0, pcm, 7);
  CHECK(len_edit(e, 0, LE_LENGTH_LAST_HALF) == LE_OK);
  const float last[4] = {4, 5, 6, 7};
  len_expect_image(e, 0, last, 4);
  CHECK(t->redo_count == 0); /* an edit retires Redo */
  /* Undo maps the half's index i back to i + 3 of the original (the kept
   * region continues): next index 1 of [4..7] reads 5, index 4 of 1..7. */
  le_engine_get_snapshot(e, &s);
  len_run(e, NULL, NULL, (4 - (s.tracks[0].position_frames + 1) % 4 + 1) % 4,
          64);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  len_run(e, NULL, out, 9, 64);
  for (int i = 0; i < 9; ++i) want[i] = pcm[(4 + i) % 7];
  len_expect_out(out, want, 9);
  le_engine_destroy(e);
}

/* The equal-gain fold of both halves at 48 kHz, bit-exact against the seam's
 * fold law: Last half folds the kept head from the folded original head (the
 * continuation of the original's last frame), First half from the region it
 * omits. Frame F onward is the kept region verbatim. Playback continues
 * through the edit at the mapped index at blocks of 1, 127 and 512 frames. */
#define LEN_L 48000
#define LEN_H (LEN_L / 2)
#define LEN_F 480
static float len_pattern(int i) {
  return (i < LEN_H ? .25f : .75f) + (float)(i % 1000) / 4000.0f;
}

static void test_length_fold_48k(void) {
  printf("test_length_fold_48k\n");
  static float in[LEN_L + LEN_F], old[LEN_L], want[LEN_L], got[LEN_L];
  static float out[2048];
  for (int i = 0; i < LEN_L + LEN_F; ++i) in[i] = len_pattern(i % LEN_L);
  const int blocks[3] = {1, 127, 512};
  for (int b = 0; b < 3; ++b) {
    for (int edit = LE_LENGTH_FIRST_HALF; edit <= LE_LENGTH_LAST_HALF; ++edit) {
      if (blocks[b] != 512 && edit == LE_LENGTH_FIRST_HALF) continue;
      le_engine* e = le_engine_create();
      CHECK(le_engine_configure(e, 48000, 1, 1, 2 * LEN_L) == LE_OK);
      CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
      drain(e);
      CHECK(le_engine_record(e, 0) == LE_OK);
      len_run(e, in, NULL, LEN_L, 512);
      CHECK(le_engine_record(e, 0) == LE_OK);
      len_run(e, in + LEN_L, NULL, LEN_F, 512); /* the master's seam capture */
      len_run(e, NULL, NULL, 30000 - LEN_F, blocks[b]);
      CHECK(le_engine_export_track(e, 0, old, LEN_L) == LEN_L);
      le_snapshot s;
      le_engine_get_snapshot(e, &s);
      CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
      const int next = (s.tracks[0].position_frames + 1) % LEN_L;
      const int start = edit == LE_LENGTH_LAST_HALF ? LEN_L - LEN_H : 0;
      for (int i = 0; i < LEN_H; ++i) want[i] = old[start + i];
      const float* cont = edit == LE_LENGTH_LAST_HALF ? old : old + LEN_H;
      for (int i = 0; i < LEN_F; ++i) {
        const float x = (float)i / (float)LEN_F;
        want[i] = cont[i] * (1.0f - x) + want[i] * x;
      }
      CHECK(len_edit(e, 0, edit) == LE_OK);
      le_engine_get_snapshot(e, &s);
      CHECK(s.master_length_frames == LEN_H); /* the only content re-clocks */
      CHECK(le_engine_export_track(e, 0, got, LEN_H) == LEN_H);
      int bad = -1;
      for (int i = 0; i < LEN_H && bad < 0; ++i) if (got[i] != want[i]) bad = i;
      CHECK(bad < 0);
      CHECK(want[LEN_F] == old[start + LEN_F]); /* verbatim past the fold */
      len_run(e, NULL, out, 2000, blocks[b]);
      const int from = ((next - start) % LEN_H + LEN_H) % LEN_H;
      bad = -1;
      for (int i = 0; i < 2000 && bad < 0; ++i) {
        if (out[i] != want[(from + i) % LEN_H]) bad = i;
      }
      CHECK(bad < 0);
      /* Undo restores the full image, unfolded, at the mapped index. */
      CHECK(le_engine_undo(e, 0) == LE_OK);
      len_settle(e);
      CHECK(le_engine_export_track(e, 0, got, LEN_L) == LEN_L);
      CHECK(memcmp(got, old, sizeof(old)) == 0);
      le_engine_get_snapshot(e, &s);
      CHECK(s.master_length_frames == LEN_L);
      le_engine_destroy(e);
    }
  }
  /* Under 2F there is no room for a fold: the half is a plain copy (the
   * 8-frame halves of test_length_worked_example). */
}

/* Refusals before any change: arguments, state, capacity. */
static void test_length_capacity_and_arguments(void) {
  printf("test_length_capacity_and_arguments\n");
  uint64_t id = 7;
  le_engine* e = le_engine_create();
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id) ==
        LE_ERR_NOT_RUNNING);
  CHECK(id == 0);
  le_engine_destroy(e);
  e = len_engine();
  le_track* t = &e->tracks[0];
  CHECK(le_engine_edit_length(NULL, 0, 0, &id) == LE_ERR_INVALID);
  CHECK(le_engine_edit_length(e, 0, 0, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_edit_length(e, LE_MAX_TRACKS, 0, &id) == LE_ERR_INVALID);
  CHECK(le_engine_edit_length(e, 0, 3, &id) == LE_ERR_INVALID);
  CHECK(le_engine_edit_length(e, 0, -1, &id) == LE_ERR_INVALID);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_INVALID); /* empty */
  const float one = 1.0f;
  len_take(e, 0, &one, 1);
  len_expect(e, 0, 1, 1, 0, 0, 0);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_ERR_INVALID);
  CHECK(len_edit(e, 0, LE_LENGTH_LAST_HALF) == LE_ERR_INVALID);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  static float pcm[600];
  for (int i = 0; i < 600; ++i) pcm[i] = (float)i;
  len_take(e, 0, pcm, 600);
  peel_history_image h = peel_history_snapshot(t);
  const int outstanding = t->outstanding_count;
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_CAPACITY); /* 1200 > 1000 */
  peel_expect_unchanged(t, &h);
  CHECK(t->outstanding_count == outstanding);
  len_expect(e, 0, 600, 1, 0, 0, 0);
  len_expect_image(e, 0, pcm, 600);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK); /* 300 -> 600 fits */
  le_engine_destroy(e);
}

/* While writing, draining, armed, pending a command or an unfiled edit, the
 * edit is refused untouched; while an edit is pending every other motion on
 * the track waits. */
static void test_length_refusals_while_busy(void) {
  printf("test_length_refusals_while_busy\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float out[64];
  le_snapshot s;
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 1.0f, 2, out);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_INVALID); /* RECORDING */
  process_const(e, 1.0f, 2, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  process_const(e, .5f, 2, out);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_INVALID); /* OVERDUBBING */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out mid-pass */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].layer_in_flight == 1);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_NOT_READY); /* draining */
  settle_layers(e);
  peel_history_image h = peel_history_snapshot(t);
  /* A quantized punch-in armed on the track. */
  CHECK(timing_gate(e, 1) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  /* Posted, not yet applied: only control's own arm flag knows. */
  CHECK(e->armed[0] && !load_i32(&t->a_pending));
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_NOT_READY);
  drain(e);
  CHECK(load_i32(&t->a_pending));
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_NOT_READY);
  CHECK(le_engine_cancel_arm(e, 0) == LE_OK);
  drain(e);
  CHECK(timing_gate(e, 0) == LE_OK);
  /* A clock command in flight (a crown change). */
  CHECK(le_engine_crown_primary(e, 1) == LE_OK);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_ERR_NOT_READY);
  drain(e);
  peel_expect_unchanged(t, &h);
  /* An edit pending: everything else on the track waits for it. */
  uint64_t id = 0;
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id) == LE_OK);
  uint64_t id2 = 0;
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id2) ==
        LE_ERR_NOT_READY);
  CHECK(le_engine_undo(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_redo(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_clear_undoable(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_clear(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_record(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_peel(e, 0) == LE_ERR_NOT_READY);
  CHECK(le_engine_history_mode_gate(e, 1u, 0) == LE_ERR_NOT_READY);
  static float restored_pcm[LOOP_N];
  float* restored[LE_MAX_LANES] = {restored_pcm};
  CHECK(le_restore_commit_layer(e, 0, 0x1u, atomic_load(&t->a_audio_rev),
                                LOOP_N, restored) == LE_ERR_INVALID);
  int32_t verdict = 99;
  CHECK(le_engine_read_request_result(e, id, &verdict) == LE_ERR_NOT_READY);
  len_settle(e);
  CHECK(le_engine_read_request_result(e, id, &verdict) == LE_OK);
  CHECK(verdict == LE_OK);
  CHECK(t->length_pending == 0);
  len_expect(e, 0, 2 * LOOP_N, 1, 0, 2, 0); /* [LAYER, LENGTH], re-clocked */
  /* Queued taps never undo a length edit from the drain. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, .25f, 3, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* queued behind the drain */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* would reach the LENGTH entry */
  CHECK(t->queued_undo == 2);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 0);
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(t->queued_undo == 0);
  CHECK(t->undo_count == 2 && t->undo_stack[1].kind == LE_HIST_LENGTH);
  /* The tap that stopped at the edit is reported once (#1168 Part 3). */
  CHECK(s.tracks[0].length_history_refusals == 1);
  CHECK(t->length_pending == 0);
  CHECK(s.tracks[0].length_frames == 2 * LOOP_N);
  le_engine_destroy(e);
}

/* The callback recomputes the verdict on the applied rig: a later take's
 * trailing seam fold still writing, or a sibling capture that started before
 * the edit landed, refuses it — receipt NOT_READY, pin released, image,
 * length and history untouched. */
static void test_length_callback_refusals(void) {
  printf("test_length_callback_refusals\n");
  float out[64];
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  le_track* t = &e->tracks[1];
  static float pcm[1000];
  for (int i = 0; i < 1000; ++i) pcm[i] = (float)(i % 50) / 50.0f;
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1000, 64);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1000, 64); /* seam capture, then back at the top */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  len_run(e, NULL, NULL, (1000 - s.master_position_frames) % 1000, 64);
  CHECK(le_engine_record(e, 1) == LE_OK);
  len_run(e, pcm, NULL, 1000, 64);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e); /* finalized; its trailing seam fold now writes F frames */
  CHECK(t->seam_capture > 0);
  const int32_t live = load_i32(&t->lanes[0].a_live);
  peel_history_image h = peel_history_snapshot(t);
  const int outstanding = t->outstanding_count;
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_ERR_NOT_READY);
  CHECK(t->outstanding_count == outstanding);
  CHECK(t->length_pending == 0);
  CHECK(load_i32(&t->lanes[0].a_live) == live);
  peel_expect_unchanged(t, &h);
  len_expect(e, 1, 1000, 1, 0, 0, 0);
  len_run(e, NULL, NULL, 2 * 480, 64);
  CHECK(t->seam_capture == 0);
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
  len_expect(e, 1, 2000, 2, 0, 1, 0);
  le_engine_destroy(e);

  /* A sibling's capture posted just before the edit: control still counts
   * track 0 as the only content (a re-clock), the callback does not. */
  e = len_engine();
  t = &e->tracks[0];
  const float base[4] = {1, 2, 3, 4};
  len_take(e, 0, base, 4);
  h = peel_history_snapshot(t);
  CHECK(le_engine_record(e, 1) == LE_OK);
  uint64_t id = 0;
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id) == LE_OK);
  CHECK(e->tracks[0].length_file.kind == LE_HIST_LENGTH);
  len_settle(e);
  int32_t verdict = 99;
  CHECK(le_engine_read_request_result(e, id, &verdict) == LE_OK);
  CHECK(verdict == LE_ERR_NOT_READY);
  peel_expect_unchanged(t, &h);
  len_expect(e, 0, 4, 1, 0, 0, 0);
  len_expect_image(e, 0, base, 4);
  le_engine_destroy(e);
}

/* Undo and Redo of a LENGTH entry go through the same verdict: after a sibling
 * is recorded at the doubled master, undoing the re-clocked Double would make a
 * half span in Multi and is refused (as is the gate's projection); with the
 * sibling cleared it re-clocks back. */
static void test_length_history_gate(void) {
  printf("test_length_history_gate\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float out[64];
  float pcm[8];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, pcm, 8);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 16);
  len_run(e, NULL, NULL, (16 - s.master_position_frames) % 16, 64);
  len_take(e, 1, NULL, 16);
  len_expect(e, 1, 16, 1, 0, 0, 0);
  peel_history_image h = peel_history_snapshot(t);
  CHECK(le_engine_history_mode_gate(e, 1u, 0) == LE_ERR_MODE_MISMATCH);
  CHECK(le_engine_undo(e, 0) == LE_ERR_MODE_MISMATCH);
  peel_expect_unchanged(t, &h);
  le_engine_get_snapshot(e, &s);
  /* Returned to the tap, which reports it: not counted again (M1). */
  CHECK(s.tracks[0].length_history_refusals == 0);
  CHECK(le_engine_clear(e, 1) == LE_OK);
  drain(e);
  CHECK(le_engine_history_mode_gate(e, 1u, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 0); /* accepted: no count */
  CHECK(s.master_length_frames == 8);
  len_expect(e, 0, 8, 1, 0, 0, 1);
  len_expect_image(e, 0, pcm, 8);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 16);
  len_expect(e, 0, 16, 1, 0, 1, 0);
  len_run(e, NULL, out, 16, 64);
  le_engine_destroy(e);
}

/* Clear above LENGTH entries keeps them under the restore point: Undo of the
 * Clear restores the edited length, the next Undo the edit. Pool eviction may
 * evict a LENGTH entry from the bottom, keeping every slot referenced once. */
static void test_length_clear_and_eviction(void) {
  printf("test_length_clear_and_eviction\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  le_snapshot s;
  float pcm[LOOP_N] = {1, 2, 3, 4};
  len_take(e, 0, pcm, LOOP_N);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.tracks[0].clear_restore == 1);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* restores the doubled take */
  drain(e);
  len_expect(e, 0, 2 * LOOP_N, 1, 0, 1, 1);
  CHECK(t->undo_stack[0].kind == LE_HIST_LENGTH);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undoes the Double */
  len_settle(e);
  len_expect(e, 0, LOOP_N, 1, 0, 0, 2);
  len_expect_image(e, 0, pcm, LOOP_N);
  le_engine_destroy(e);

  e = len_engine();
  t = &e->tracks[0];
  len_take(e, 0, pcm, LOOP_N);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  float out[64];
  int passes = 0;
  while (t->undo_count > 0 && t->undo_stack[0].kind == LE_HIST_LENGTH &&
         passes < 400) {
    CHECK(le_engine_record(e, 0) == LE_OK);
    process_const(e, .0625f, 2 * LOOP_N, out);
    CHECK(le_engine_record(e, 0) == LE_OK);
    drain(e);
    settle_layers(e);
    ++passes;
    if (passes == 1) CHECK(t->undo_stack[1].kind == LE_HIST_LAYER);
  }
  CHECK(passes < 400);
  CHECK(t->undo_stack[0].kind == LE_HIST_LAYER);
  CHECK(peel_slots_unique(t));
  /* Every surviving entry is at the doubled length: Undo walks them all. */
  for (int guard = 0; t->undo_count > 0 && guard < 400; ++guard) {
    CHECK(le_engine_undo(e, 0) == LE_OK);
  }
  CHECK(t->undo_count == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 2 * LOOP_N);
  CHECK(peel_slots_unique(t));
  le_engine_destroy(e);
}

/* Two lanes resize in lockstep; a running Fade continues; a reversed track
 * keeps reading reversed from the mapped index; a STOPPED track stays silent
 * and maps its held position. Export refuses a slot shorter than its image. */
static void test_length_lanes_fade_reverse_stopped(void) {
  printf("test_length_lanes_fade_reverse_stopped\n");
  le_engine* e = make_two_lane_engine();
  le_track* t = &e->tracks[0];
  record_two_lane(e, 1.0f, 2.0f);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  CHECK(load_i32(&t->lanes[0].a_live) == load_i32(&t->lanes[1].a_live));
  CHECK(load_i32(&t->lanes[1].a_len) == 2 * LOOP_N);
  const float lane1[2 * LOOP_N] = {2, 2, 2, 2, 2, 2, 2, 2};
  reopen_check_track_pcm(e, 0, 1, lane1, 2 * LOOP_N);
  /* A redo image whose slot is shorter than its length is refused. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  float img[16];
  CHECK(le_engine_export_layer(e, 0, 1, 1, img, 16) == 2 * LOOP_N);
  const int32_t redo_slot = t->redo_stack[0].slot;
  le_lane_shrink_slot(&t->lanes[1], redo_slot, LOOP_N);
  CHECK(le_engine_export_layer(e, 0, 1, 1, img, 16) == LE_ERR_INVALID);
  le_engine_destroy(e);

  /* Fade through an edit. */
  e = len_engine();
  float out[64];
  le_snapshot s;
  float pcm[16];
  for (int i = 0; i < 16; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, pcm, 16);
  uint64_t id;
  CHECK(le_engine_toggle_fade(e, 0, 1.0f, &id) == LE_OK);
  len_run(e, NULL, NULL, 2400, 64);
  le_engine_get_snapshot(e, &s);
  const float before = s.tracks[0].fade.amount;
  CHECK(before < .96f && before > .94f);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  len_run(e, NULL, NULL, 2400, 64);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].fade.amount < before - .04f);
  CHECK(s.tracks[0].fade.target == 0);
  le_engine_destroy(e);

  /* Reverse: playing backward at index 12 (the omitted second half), First
   * half continues backward from index 4. */
  e = len_engine();
  t = &e->tracks[1];
  len_take(e, 0, NULL, 8);
  len_take(e, 1, pcm, 16);
  len_expect(e, 1, 16, 2, 0, 0, 0);
  uint64_t rid = 0;
  CHECK(le_engine_toggle_reverse(e, 1, &rid) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].reversed == 1);
  for (int guard = 0; guard < 64; ++guard) {
    le_engine_get_snapshot(e, &s);
    if (s.tracks[1].position_frames == 13) break;
    len_run(e, NULL, NULL, 1, 1);
  }
  CHECK(s.tracks[1].position_frames == 13); /* next read: index 12 */
  CHECK(len_edit(e, 1, LE_LENGTH_FIRST_HALF) == LE_OK);
  len_run(e, NULL, out, 10, 64);
  float want[10];
  for (int i = 0; i < 10; ++i) want[i] = pcm[((4 - i) % 8 + 8) % 8];
  len_expect_out(out, want, 10);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].reversed == 1);
  le_engine_destroy(e);

  /* STOPPED: silent before and after, the held position mapped. */
  e = len_engine();
  len_take(e, 0, NULL, 8);
  len_take(e, 1, pcm, 16);
  len_run(e, NULL, NULL, 13, 64);
  CHECK(le_engine_stop_track(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  const int held = s.tracks[1].position_frames;
  CHECK(len_edit(e, 1, LE_LENGTH_LAST_HALF) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].position_frames == (held - 8 + 8) % 8);
  len_run(e, NULL, out, 16, 64);
  for (int i = 0; i < 16; ++i) CHECK(out[i] == 0.0f);
  le_engine_destroy(e);
}

/* The 326 fact names the slot made live, its length and the staged image the
 * callback's 322 names at the same frame; Undo and Redo of the edit log their
 * own 326 plus 304/305. */
static void test_length_perf_fact(void) {
  printf("test_length_perf_fact\n");
  le_engine* e = len_engine();
  float pcm[8];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, NULL, 8);
  len_take(e, 1, pcm, 8);
  const char* dir = render_test_dir("length-fact");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  len_run(e, NULL, NULL, 8, 64);
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
  const int32_t doubled = load_i32(&e->tracks[1].lanes[0].a_live);
  len_run(e, NULL, NULL, 8, 64);
  CHECK(le_engine_undo(e, 1) == LE_OK);
  len_settle(e);
  len_run(e, NULL, NULL, 8, 64);
  CHECK(le_engine_redo(e, 1) == LE_OK);
  len_settle(e);
  len_run(e, NULL, NULL, 8, 64);
  CHECK(le_perf_disarm(e) == LE_OK);
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[1 << 20];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  int facts = 0;
  uint32_t last_id = 0;
  for (size_t i = 0; i < count; ++i) {
    le_perf_log_entry entry;
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code != LE_PLOG_LENGTH) continue;
    ++facts;
    CHECK(entry.cmd.length_log.channel == 1);
    CHECK(entry.cmd.length_log.len == (facts == 2 ? 8 : 16));
    if (facts != 2) CHECK(entry.cmd.length_log.slot == doubled);
    CHECK(entry.cmd.length_log.image_id > last_id);
    last_id = entry.cmd.length_log.image_id;
    /* The callback names the same staged image at the same frame. */
    int named = 0;
    for (size_t k = 0; k < count; ++k) {
      le_perf_log_entry other;
      decode_log_entry_at(buf, k, &other);
      if (other.cmd.code == LE_PLOG_SOURCE_APPLIED &&
          other.cmd.restore_log.channel == 1 &&
          other.cmd.restore_log.image_id == entry.cmd.length_log.image_id &&
          other.frame == entry.frame) named = 1;
    }
    CHECK(named);
  }
  CHECK(facts == 3);
  CHECK(count_log_entries_for_channel(buf, count, LE_PLOG_UNDO, 1) == 1);
  CHECK(count_log_entries_for_channel(buf, count, LE_PLOG_REDO, 1) == 1);
  le_engine_destroy(e);
}

/* PR #1212 review M1: an edit's image is read from the live slot on the
 * control thread. Admission refuses while the callback may still write it (a
 * later take's trailing seam fold), and the payload names the content
 * revision it read, so a fold that slips in between admission and the
 * callback's drain refuses the edit there. The interleaving is replayed
 * deterministically: the command is held off the ring for the one block in
 * which the fold runs. */
static void test_length_seam_race(void) {
  printf("test_length_seam_race\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  le_track* t = &e->tracks[1];
  static float pcm[1000], folded[1000], doubled[2000];
  for (int i = 0; i < 1000; ++i) pcm[i] = (float)(i % 50) / 50.0f;
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1000, 64);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1000, 64);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  len_run(e, NULL, NULL, (1000 - s.master_position_frames) % 1000, 64);
  CHECK(le_engine_record(e, 1) == LE_OK);
  len_run(e, pcm, NULL, 1000, 64);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  while (t->seam_capture > 1) len_run(e, NULL, NULL, 1, 1);
  CHECK(t->seam_capture == 1);
  /* The callback's view says the slot is still being written. */
  uint64_t id = 0;
  CHECK(le_engine_edit_length(e, 1, LE_LENGTH_DOUBLE, &id) ==
        LE_ERR_NOT_READY);
  /* A stale readable view (a write posted but not yet applied): admitted,
   * then the fold lands before the command is applied. */
  const int32_t live = load_i32(&t->lanes[0].a_live);
  peel_history_image h = peel_history_snapshot(t);
  const int outstanding = t->outstanding_count;
  atomic_store(&t->a_cache_source_readable, 1);
  CHECK(le_engine_edit_length(e, 1, LE_LENGTH_DOUBLE, &id) == LE_OK);
  le_command held;
  CHECK(le_ring_pop(&e->ring, &held));
  CHECK(held.code == LE_CMD_SET_LENGTH);
  const uint32_t before = atomic_load(&t->a_audio_rev);
  len_run(e, NULL, NULL, 1, 1); /* the fold runs in this block */
  CHECK(t->seam_capture == 0);
  CHECK(atomic_load(&t->a_audio_rev) != before);
  CHECK(le_ring_push(&e->ring, held));
  len_settle(e);
  int32_t verdict = 99;
  CHECK(le_engine_read_request_result(e, id, &verdict) == LE_OK);
  CHECK(verdict == LE_ERR_NOT_READY);
  CHECK(load_i32(&t->lanes[0].a_live) == live);
  CHECK(t->outstanding_count == outstanding);
  peel_expect_unchanged(t, &h);
  len_expect(e, 1, 1000, 1, 0, 0, 0);
  /* Edited now, both copies carry the folded head. */
  CHECK(le_engine_export_track(e, 1, folded, 1000) == 1000);
  CHECK(memcmp(folded, pcm, sizeof(pcm)) != 0); /* the fold changed it */
  CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
  CHECK(le_engine_export_track(e, 1, doubled, 2000) == 2000);
  CHECK(memcmp(doubled, folded, sizeof(folded)) == 0);
  CHECK(memcmp(doubled + 1000, folded, sizeof(folded)) == 0);
  le_engine_destroy(e);
}

/* PR #1212 review M2, owner decision 2026-10-06: a re-clocked only track
 * keeps its tempo, and the grid counts the loop in beats. With loop<->grid
 * sync on, a half keeps half the beats (1 bar of 4/4 halves to 2 beats, 3
 * bars to 6, with no whole bar count) and a Double twice the beats, all at
 * the unchanged tempo; only a half that would leave a fraction of a beat (one
 * beat, or one bar of 3/4) is refused as incompatible. Undo restores the
 * bar count. */
static void test_length_reclock_keeps_tempo(void) {
  printf("test_length_reclock_keeps_tempo\n");
  const int32_t bar = 96000; /* 4/4 at 120 BPM, 48 kHz: 24000 a beat */
  for (int bars = 1; bars <= 3; ++bars) {
    le_engine* e = le_engine_create();
    CHECK(le_engine_configure(e, 48000, 1, 1, 6 * bar) == LE_OK);
    CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
    drain(e);
    CHECK(le_engine_record(e, 0) == LE_OK);
    len_run(e, NULL, NULL, bars * bar, 512);
    CHECK(le_engine_record(e, 0) == LE_OK);
    len_run(e, NULL, NULL, 1024, 512);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    CHECK(s.master_length_frames == bars * bar);
    CHECK(s.loop_bars == bars && s.loop_beats == 4 * bars);
    for (int edit = LE_LENGTH_FIRST_HALF; edit <= LE_LENGTH_LAST_HALF;
         ++edit) {
      CHECK(len_edit(e, 0, edit) == LE_OK);
      le_engine_get_snapshot(e, &s);
      CHECK(s.master_length_frames == bars * bar / 2);
      CHECK(s.loop_beats == 2 * bars);
      CHECK(s.loop_bars == (bars % 2 == 0 ? bars / 2 : 0));
      CHECK(s.tempo_bpm == 120.0f);
      CHECK(le_engine_undo(e, 0) == LE_OK);
      len_settle(e);
      le_engine_get_snapshot(e, &s);
      CHECK(s.master_length_frames == bars * bar);
      CHECK(s.loop_bars == bars && s.loop_beats == 4 * bars);
    }
    if (bars <= 2) {
      CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
      le_engine_get_snapshot(e, &s);
      CHECK(s.master_length_frames == 2 * bars * bar);
      CHECK(s.loop_bars == 2 * bars && s.loop_beats == 8 * bars);
      CHECK(s.tempo_bpm == 120.0f);
    }
    le_engine_destroy(e);
  }

  /* One bar halves to 2 beats, then to 1; a further half would leave half a
   * beat and is refused. The sub-bar loop still publishes its beats. */
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 6 * bar) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, bar, 512);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1024, 512);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == bar / 4);
  CHECK(s.loop_beats == 1 && s.loop_bars == 0 && s.tempo_bpm == 120.0f);
  CHECK(len_edit(e, 0, LE_LENGTH_LAST_HALF) == LE_ERR_MODE_MISMATCH);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == bar / 4 && s.loop_beats == 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_beats == 2 && s.loop_bars == 0);
  /* Beat 1 of the 2-beat loop is published half way through it. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  len_run(e, NULL, NULL, (bar / 2 - s.master_position_frames) % (bar / 2),
          512);
  len_run(e, NULL, NULL, bar / 4 + 10, 512);
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);
  le_engine_destroy(e);

  /* One bar of 3/4 is three beats: its half would be a beat and a half. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 6 * bar) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  CHECK(le_engine_set_time_signature(e, 3, 4) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 3 * bar / 4, 512);
  CHECK(le_engine_record(e, 0) == LE_OK);
  len_run(e, NULL, NULL, 1024, 512);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 1 && s.loop_beats == 3);
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_ERR_MODE_MISMATCH);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2 && s.loop_beats == 6);
  le_engine_destroy(e);

  /* A Session commit restores a sub-bar grid exactly. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 6 * bar) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  static float half[48000];
  CHECK(le_engine_import_track(e, 0, half, bar / 2) == LE_OK);
  CHECK(le_engine_commit_session(e, bar / 2, 2) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == bar / 2);
  CHECK(s.loop_beats == 2 && s.loop_bars == 0 && s.tempo_bpm == 120.0f);
  /* Undo to empty keeps the master; a tempo change then regrids it to the
   * nearest whole beats, never to a bar it does not hold: at 60 BPM the
   * 48000-frame loop is one beat. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  CHECK(le_engine_set_tempo(e, 60.0f) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == bar / 2 && s.tempo_bpm == 60.0f);
  CHECK(s.loop_beats == 1 && s.loop_bars == 0);
  le_engine_destroy(e);
}

/* PR #1212 review L1: while a re-clock is posted, every other track's history
 * decision measures the master it will set. Multi, tracks A and B of 8 frames,
 * B cleared: a Double of A re-clocks to 16, and B's restore must be refused
 * in the window too, or it would land as a half-span in Multi. */
static void test_length_pending_reclock_master(void) {
  printf("test_length_pending_reclock_master\n");
  le_engine* e = len_engine();
  float pcm[8];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, pcm, 8);
  len_take(e, 1, pcm, 8);
  CHECK(le_engine_clear_undoable(e, 1) == LE_OK);
  len_settle(e);
  uint64_t id = 0;
  CHECK(le_engine_edit_length(e, 0, LE_LENGTH_DOUBLE, &id) == LE_OK);
  CHECK(le_engine_history_mode_gate(e, 1u << 1, 0) == LE_ERR_MODE_MISMATCH);
  CHECK(le_engine_undo(e, 1) == LE_ERR_MODE_MISMATCH);
  len_settle(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 16);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY && s.tracks[1].clear_restore == 1);
  le_engine_destroy(e);
}

/* PR #1212 review L2, the accepted race: an Undo of a LENGTH entry returns
 * LE_OK when it is posted, like Undo to empty and a Clear restore; when the
 * callback finds the rig changed (here a sibling capture posted just before)
 * it refuses, and the history is exactly as before — the next Undo meets the
 * same verdict at admission. */
static void test_length_refused_history_motion(void) {
  printf("test_length_refused_history_motion\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float pcm[8];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, pcm, 8);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK); /* re-clocks to 16 */
  peel_history_image h = peel_history_snapshot(t);
  CHECK(le_engine_record(e, 1) == LE_OK); /* posted, not yet applied */
  CHECK(le_engine_undo(e, 0) == LE_OK);   /* admitted as a re-clock */
  len_settle(e);
  CHECK(load_i32(&t->a_length_result) == LE_ERR_MODE_MISMATCH);
  CHECK(t->length_pending == 0);
  peel_expect_unchanged(t, &h);
  len_expect(e, 0, 16, 1, 0, 1, 0);
  /* Posted as OK, refused after: the host is told (#1168 Part 3). */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 1);
  CHECK(s.tracks[1].length_history_refusals == 0);
  /* Refused at the tap: the caller sees the result, so no second count
   * (#1168 review M1: one tap, one notice). */
  CHECK(le_engine_undo(e, 0) == LE_ERR_MODE_MISMATCH);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 1);
  le_engine_destroy(e);
}

/* #1168 delta review: an Undo or Redo of a LENGTH entry with the command
 * ring full is refused up front as LE_ERR_NOT_READY (the edit's own rule),
 * changing nothing and counting nothing, rather than failing the push as
 * LE_ERR_INVALID after the checks. */
static void test_length_history_full_ring(void) {
  printf("test_length_history_full_ring\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float pcm[8];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  len_take(e, 0, pcm, 8);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  len_expect(e, 0, 16, 1, 0, 1, 0);
  peel_history_image h = peel_history_snapshot(t);
  int pushed = 0;
  while (le_engine_set_master_gain(e, 1.0f) == LE_OK) ++pushed;
  CHECK(pushed > 0);
  CHECK(le_engine_undo(e, 0) == LE_ERR_NOT_READY);
  CHECK(t->length_pending == 0);
  peel_expect_unchanged(t, &h);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 0);
  /* Once the callback drains the ring, the same tap undoes the Double. */
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  len_expect(e, 0, 8, 1, 0, 0, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_history_refusals == 0);
  le_engine_destroy(e);
}

/* #1168 Part 2: the history a Session saves, lengths and playhead maps
 * included. Exports every entry and image of track 1 the way the Session
 * capture does: export_history for the kinds, skipped counts and maps, then
 * export_layer per ordinal, first as a size query (each image has its own
 * length), then for the PCM. */
typedef struct {
  int32_t kinds[16], skipped[16], starts[16];
  int32_t lens[16];
  float images[16][64];
  int32_t count, undo_count, image_count;
} len_saved;

static void len_save(le_engine* e, int32_t ch, len_saved* h) {
  h->count = le_engine_export_history(e, ch, h->kinds, h->skipped, h->starts,
                                      16, &h->undo_count);
  CHECK(h->count >= 0 && h->count <= 16);
  h->image_count = h->undo_count + 1;
  for (int32_t i = h->undo_count; i < h->count; ++i) {
    if (h->kinds[i] != LE_HIST_PEEL) h->image_count++;
  }
  for (int32_t o = 0; o < h->image_count; ++o) {
    h->lens[o] = le_engine_export_layer(e, ch, 0, o, NULL, 0);
    CHECK(h->lens[o] > 0 && h->lens[o] <= 64);
    CHECK(le_engine_export_layer(e, ch, 0, o, h->images[o], 64) == h->lens[o]);
  }
}

/* Stages a saved history on [ch] of a fresh engine (the Session load). */
static int32_t len_recall(le_engine* e, int32_t ch, const len_saved* h) {
  for (int32_t o = 0; o < h->image_count; ++o) {
    CHECK(le_engine_import_layer(e, ch, 0, o, h->images[o], h->lens[o]) ==
          LE_OK);
  }
  return le_engine_finalize_history(e, ch, h->kinds, h->skipped, h->starts,
                                    h->count, h->undo_count, h->lens,
                                    h->image_count);
}

/* A Double, a Last half and an Undo leave LENGTH entries on both stacks with
 * images of 8 and 16 frames; saved and recalled, the stacks come back with
 * their lengths and playhead maps, the live image at its own length, and
 * Redo and Undo reproduce every image exactly — the Last half's Redo keeps
 * the playhead's phase in the kept half. */
static void test_length_session_round_trip(void) {
  printf("test_length_session_round_trip\n");
  float pcm[8], out[64], want[64];
  for (int i = 0; i < 8; ++i) pcm[i] = (float)(i + 1);
  le_engine* live = len_engine();
  len_take(live, 0, NULL, 8);
  len_take(live, 1, pcm, 8);
  CHECK(len_edit(live, 1, LE_LENGTH_DOUBLE) == LE_OK);
  float doubled[16];
  CHECK(le_engine_export_track(live, 1, doubled, 16) == 16);
  CHECK(len_edit(live, 1, LE_LENGTH_LAST_HALF) == LE_OK);
  CHECK(le_engine_undo(live, 1) == LE_OK);
  len_settle(live);
  len_expect(live, 1, 16, 2, 0, 1, 1);
  static len_saved h;
  len_save(live, 1, &h);
  CHECK(h.count == 2 && h.undo_count == 1 && h.image_count == 3);
  CHECK(h.kinds[0] == LE_HIST_LENGTH && h.kinds[1] == LE_HIST_LENGTH);
  CHECK(h.lens[0] == 8 && h.lens[1] == 16 && h.lens[2] == 8);
  CHECK(h.starts[0] == 0 && h.starts[1] == 8);
  le_engine_destroy(live);

  le_engine* e = len_engine();
  le_track* t = &e->tracks[1];
  float silence[8] = {0};
  CHECK(le_engine_import_track(e, 0, silence, 8) == LE_OK);
  CHECK(len_recall(e, 1, &h) == LE_OK);
  CHECK(le_engine_commit_session(e, 8, 0) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 16, 2, 0, 1, 1);
  len_expect_image(e, 1, doubled, 16);
  CHECK(t->undo_stack[0].kind == LE_HIST_LENGTH && t->undo_stack[0].len == 8 &&
        t->undo_stack[0].start == 0);
  CHECK(t->redo_stack[0].kind == LE_HIST_LENGTH && t->redo_stack[0].len == 8 &&
        t->redo_stack[0].start == 8);
  /* Redo re-applies the Last half: playing at index 3 of the doubled image,
   * it continues at index (3 - 8) mod 8 = 3 of the kept half. */
  CHECK(le_engine_play(e, 1) == LE_OK);
  len_run(e, NULL, out, 3, 64);
  CHECK(le_engine_redo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 8, 1, 0, 2, 0);
  len_expect_image(e, 1, pcm, 8);
  len_run(e, NULL, out, 5, 64);
  for (int i = 0; i < 5; ++i) want[i] = pcm[3 + i];
  len_expect_out(out, want, 5);
  /* Undo twice walks back to the original 8 frames. */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  len_settle(e);
  len_expect_image(e, 1, doubled, 16);
  CHECK(le_engine_undo(e, 1) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 8, 1, 0, 0, 2);
  len_expect_image(e, 1, pcm, 8);
  le_engine_destroy(e);

  /* The playhead map survives too: a 7-frame only track, Last half (start 3)
   * undone, saved and recalled; its Redo at index 1 continues at index
   * (1 - 3) mod 4 = 2 of the kept half, exactly as the live engine would. */
  const float odd[7] = {1, 2, 3, 4, 5, 6, 7};
  live = len_engine();
  len_take(live, 0, odd, 7);
  CHECK(len_edit(live, 0, LE_LENGTH_LAST_HALF) == LE_OK);
  CHECK(le_engine_undo(live, 0) == LE_OK);
  len_settle(live);
  static len_saved g;
  len_save(live, 0, &g);
  CHECK(g.count == 1 && g.undo_count == 0 && g.starts[0] == 3);
  CHECK(g.lens[0] == 7 && g.lens[1] == 4);
  le_engine_destroy(live);
  e = len_engine();
  CHECK(len_recall(e, 0, &g) == LE_OK);
  CHECK(le_engine_commit_session(e, 7, 0) == LE_OK);
  len_settle(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  len_run(e, NULL, out, 1, 64); /* reads index 0; next is 1 */
  CHECK(out[0] == odd[0]);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  len_settle(e);
  len_run(e, NULL, out, 4, 64);
  const float last[4] = {4, 5, 6, 7};
  for (int i = 0; i < 4; ++i) want[i] = last[(2 + i) % 4];
  len_expect_out(out, want, 4);
  le_engine_destroy(e);
}

/* The lineage decides every image's length: a layer at another length than
 * the LENGTH entry above it, a map on a kind that has none, an image count
 * that disagrees with the entries, or an image longer than its staged slot
 * is refused before anything is published. */
static void test_length_finalize_lineage(void) {
  printf("test_length_finalize_lineage\n");
  le_engine* e = len_engine();
  le_track* t = &e->tracks[0];
  float pcm[16] = {0};
  /* [LAYER, LENGTH] under live, a LAYER above: images 8, 8, 16, 16. */
  const int32_t lens8[4] = {8, 8, 16, 16};
  for (int32_t o = 0; o < 4; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, pcm, lens8[o]) == LE_OK);
  }
  int32_t kinds[3] = {LE_HIST_LAYER, LE_HIST_LENGTH, LE_HIST_LAYER};
  int32_t skipped[3] = {0, 0, 0};
  int32_t starts[3] = {0, 0, 0};
  int32_t lens[4] = {8, 8, 16, 16};
  /* The layer beneath the edit is as long as the edit's image. */
  lens[0] = 16;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  lens[0] = 8;
  /* The redo layer is as long as live. */
  lens[3] = 8;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  lens[3] = 16;
  /* A map on a layer; the image count; no lengths; NULL maps. */
  starts[0] = 4;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  starts[0] = 0;
  starts[1] = -1001; /* beyond the loop cap */
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  starts[1] = -8;
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   3) == LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, NULL,
                                   4) == LE_ERR_INVALID);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, NULL, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  /* An image longer than the slot staged for it is torn. */
  le_lane_shrink_slot(&t->lanes[0], 3, 8);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_ERR_INVALID);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(t->undo_count == 0 && t->redo_count == 0);
  CHECK(le_engine_import_layer(e, 0, 0, 3, pcm, 16) == LE_OK);
  CHECK(le_engine_finalize_history(e, 0, kinds, skipped, starts, 3, 2, lens,
                                   4) == LE_OK);
  CHECK(t->undo_stack[1].kind == LE_HIST_LENGTH && t->undo_stack[1].len == 8 &&
        t->undo_stack[1].start == -8);
  CHECK(load_i32(&t->lanes[0].a_len) == 16);
  le_engine_destroy(e);
}

/* A saved Sync division recalls as that division and plays phase-locked to
 * the primary top (the commit used to make every track a whole multiple). */
static void test_length_division_recall(void) {
  printf("test_length_division_recall\n");
  float out[64], want[64];
  const float pattern[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  le_engine* e = len_engine();
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  float silence[SB_BASE] = {0};
  CHECK(le_engine_import_track(e, 0, silence, SB_BASE) == LE_OK);
  CHECK(le_engine_import_track(e, 1, pattern, 8) == LE_OK);
  CHECK(le_engine_commit_session(e, SB_BASE, 0) == LE_OK);
  len_settle(e);
  len_expect(e, 1, 8, 1, 2, 0, 0);
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  len_run(e, NULL, NULL, (SB_BASE - s.master_position_frames) % SB_BASE, 64);
  len_run(e, NULL, out, 2 * SB_BASE, 64);
  for (int i = 0; i < 2 * SB_BASE; ++i) want[i] = pattern[i % 8];
  len_expect_out(out, want, 2 * SB_BASE);
  le_engine_destroy(e);

  /* PR #1244 review L1: a staged length that is neither a whole multiple of
   * the base nor half or a quarter of it is refused before anything is
   * posted; it would recall as a division and the mixer would read past its
   * slot. A quarter and a whole multiple are accepted. */
  static const struct { int32_t len; int32_t verdict; } cases[] = {
      {5, LE_ERR_INVALID},  {24, LE_ERR_INVALID}, {12, LE_ERR_INVALID},
      {4, LE_OK},           {48, LE_OK},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    e = len_engine();
    float stem[48] = {0};
    CHECK(le_engine_import_track(e, 0, silence, SB_BASE) == LE_OK);
    CHECK(le_engine_import_track(e, 1, stem, cases[c].len) == LE_OK);
    CHECK(le_engine_commit_session(e, SB_BASE, 0) == cases[c].verdict);
    le_snapshot sc;
    le_engine_get_snapshot(e, &sc);
    if (cases[c].verdict != LE_OK) {
      CHECK(sc.master_length_frames == 0);
      CHECK(sc.tracks[1].state == LE_TRACK_EMPTY);
    }
    le_engine_destroy(e);
  }
}

static void run_length_tests(void) {
  test_length_worked_example();
  test_length_multiple_segments();
  test_length_segment_and_origin();
  test_length_sync_division();
  test_length_free_odd_halves();
  test_length_fold_48k();
  test_length_capacity_and_arguments();
  test_length_refusals_while_busy();
  test_length_callback_refusals();
  test_length_history_gate();
  test_length_clear_and_eviction();
  test_length_lanes_fade_reverse_stopped();
  test_length_perf_fact();
  test_length_seam_race();
  test_length_reclock_keeps_tempo();
  test_length_pending_reclock_master();
  test_length_refused_history_motion();
  test_length_history_full_ring();
  test_length_session_round_trip();
  test_length_finalize_lineage();
  test_length_division_recall();
}
