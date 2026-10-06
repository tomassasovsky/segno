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
  le_engine* e = make_configured_engine();
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
      le_engine* e = make_configured_engine();
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
  le_engine* e = make_configured_engine();
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
      le_engine* e = make_configured_engine();
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
      CHECK(e->tracks[1].playback_offset == 0);
      len_run(e, NULL, out, 12, 64);
      for (int i = 0; i < 12; ++i) want[i] = pcm[8 + ((next - 8 + 8) % 8 + i) % 8];
      len_expect_out(out, want, 12);
      le_engine_destroy(e);
    }
  }
  /* A forward Double from k = 1 after an odd or even number of base loops:
   * the copy follows the current segment, with the origin still zero. */
  for (int lead = 0; lead < 2; ++lead) {
    le_engine* e = make_configured_engine();
    len_take(e, 0, NULL, 4);
    len_take(e, 1, pcm, 4);
    len_run(e, NULL, NULL, 4 * lead + 2, 64);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int cur = (s.tracks[1].position_frames + 1) % 4;
    CHECK(len_edit(e, 1, LE_LENGTH_DOUBLE) == LE_OK);
    CHECK(e->tracks[1].playback_offset == 0);
    len_run(e, NULL, out, 1, 64);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[1].position_frames == cur);
    le_engine_destroy(e);
  }
  /* Reversed Double: the next read index is kept, in the first copy. */
  for (int steps = 1; steps <= 7; steps += 2) {
    le_engine* e = make_configured_engine();
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
    le_engine* e = make_configured_engine();
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
  le_engine* e = make_configured_engine();
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
  e = make_configured_engine();
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
  le_engine* e = make_configured_engine();
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
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(t->queued_undo == 0);
  CHECK(t->undo_count == 2 && t->undo_stack[1].kind == LE_HIST_LENGTH);
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
  e = make_configured_engine();
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
  le_engine* e = make_configured_engine();
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
  CHECK(le_engine_clear(e, 1) == LE_OK);
  drain(e);
  CHECK(le_engine_history_mode_gate(e, 1u, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  le_engine_get_snapshot(e, &s);
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
  le_engine* e = make_configured_engine();
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

  e = make_configured_engine();
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
  e = make_configured_engine();
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
  e = make_configured_engine();
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
  e = make_configured_engine();
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
  le_engine* e = make_configured_engine();
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
}
