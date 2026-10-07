/* #1143 Part 1: exact provenance for callback-applied history images. Every
 * layer Undo/Redo, Clear Undo and recovery from empty admitted during an armed
 * capture is replayed sample-exactly from a staged image named by a callback
 * fact (322), and every case without exact provenance fails the stem (323/0)
 * while the master stays usable. Patterned literal PCM, distinct per layer,
 * through production entry points only. Included by test_engine_core.c after
 * test_engine_fade.h (shares fade_finalize_manifest / fade_render_status). */

#define HR_LEN 128

/* Three distinguishable layers on track 0: base ramp A (imported), then two
 * overdub passes adding B (constant) and C (a 7-periodic ramp). After this the
 * live content is A+B+C, the undo stack holds [A, A+B]. */
static void history_layer_patterns(float* a, float* b, float* c) {
  for (int i = 0; i < HR_LEN; ++i) {
    a[i] = (float)(i + 1) / 256;
    b[i] = .25f;
    c[i] = (float)((i % 7) + 1) / 64;
  }
}

static void history_overdub_pass(le_engine* e, const float* input) {
  float out[HR_LEN], zero[HR_LEN] = {0};
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  le_engine_process(e, out, input, HR_LEN); /* one complete pass */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  le_engine_process(e, out, zero, HR_LEN);
  le_engine_drain_events(e);
  drain(e);
}

static le_engine* history_fixture(void) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  float a[HR_LEN], b[HR_LEN], c[HR_LEN], pcm[HR_LEN], zero[HR_LEN] = {0};
  history_layer_patterns(a, b, c);
  CHECK(le_engine_import_track(e, 0, a, HR_LEN) == LE_OK);
  /* A silent sibling keeps the master grid running while track 0 is EMPTY, so
   * every swap below lands at a nonzero, checkable phase. */
  CHECK(le_engine_import_track(e, 1, zero, HR_LEN) == LE_OK);
  CHECK(le_engine_commit_session(e, HR_LEN, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  drain(e);
  history_overdub_pass(e, b);
  CHECK(e->tracks[0].undo_count == 1);
  history_overdub_pass(e, c);
  CHECK(e->tracks[0].undo_count == 2);
  CHECK(le_engine_export_track(e, 0, pcm, HR_LEN) == HR_LEN);
  for (int i = 0; i < HR_LEN; ++i) CHECK(fabsf(pcm[i] - (a[i] + b[i] + c[i])) < 1e-6f);
  return e;
}

/* Every 322/323 fact for `channel`, in file order. */
static int history_source_facts(const char* dir, int32_t channel,
                                le_perf_log_entry* out, int cap) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[1 << 20];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  int found = 0;
  for (size_t i = 0; i < count && found < cap; ++i) {
    le_perf_log_entry entry;
    decode_log_entry_at(buf, i, &entry);
    if ((entry.cmd.code == LE_PLOG_SOURCE_APPLIED ||
         entry.cmd.code == LE_PLOG_SOURCE_TRANSPORT) &&
        entry.cmd.restore_log.channel == channel) {
      out[found++] = entry;
    }
  }
  return found;
}

static int history_count_code(const char* dir, int32_t code, int32_t channel) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[1 << 20];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  return count_log_entries_for_channel(buf, log_entry_count(n), code, channel);
}

static int history_manifest_count(const char* dir, const char* needle) {
  char path[700];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  char* json = malloc(1024 * 1024);
  CHECK(json != NULL);
  if (!json) return -1;
  int count = 0;
  if (read_file_for_test(path, json, 1024 * 1024) > 0) {
    for (const char* p = json; (p = strstr(p, needle)) != NULL; p += strlen(needle)) ++count;
  }
  free(json);
  return count;
}

/* Writes track 0's current content as the arm image the Dart side would have
 * captured (test_fade_actual_arm_render's pattern); returns the manifest's
 * armSnapshot naming it. Call BEFORE le_perf_arm. */
static const char* history_arm_image(le_engine* e, const char* dir) {
  float pcm[HR_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, HR_LEN) == HR_LEN);
  char path[700]; snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, HR_LEN, 48000);
  return "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
         "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}";
}

#define HISTORY_ARM_EMPTY "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}"

/* Finalize the capture with `arm` (the arm snapshot JSON), render, and require
 * the wet stem of track 0 to equal `live` sample for sample. */
static void history_render_parity(le_engine* e, const char* dir, const char* arm,
                                  const float* live, int frames) {
  static float replay[1 << 16];
  CHECK(frames <= (int)(sizeof(replay) / sizeof(replay[0])));
  fade_finalize_manifest(dir, arm);
  fade_render_status(e, dir, 1);
  CHECK(test_read_wet_stem(dir, 0, replay, frames) == frames);
  int shown = 0;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) >= 1e-6f && shown++ < 4)
      printf("  parity mismatch at %d: replay %g live %g\n", i, replay[i], live[i]);
    CHECK(fabsf(replay[i] - live[i]) < 1e-6f);
  }
}

static int history_process(le_engine* e, float* live, int at, int frames, int block) {
  float input[512] = {0};
  for (int done = 0; done < frames;) {
    int n = frames - done;
    if (n > block) n = block;
    le_engine_process(e, live + at + done, input, (uint32_t)n);
    done += n;
  }
  return at + frames;
}

/* Clear/Undo, layer Undo, layer Undo, Redo, Redo, Stop, Play: literal parity,
 * one 322 per swap at the exact frame with a nonzero phase, 323 for Stop and
 * Play. Block 1 proves the frame; block 128 (review E2) proves the fact lands
 * on the first frame of the block that first mixes the slot. */
static void test_history_undo_redo_literal_parity(void) {
  printf("test_history_undo_redo_literal_parity\n");
  const int blocks[] = {1, 128};
  for (int b = 0; b < 2; ++b) {
    const int block = blocks[b];
    le_engine* e = history_fixture();
    float a[HR_LEN], bb[HR_LEN], c[HR_LEN];
    history_layer_patterns(a, bb, c);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    const char* dir = render_test_dir(block == 1 ? "history-parity-1" : "history-parity-128");
    CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
    static float live[4096];
    int at = 0;
    uint64_t swaps[5];
    at = history_process(e, live, at, 37, block); /* 37 frames of silence (EMPTY) */
    CHECK(le_engine_undo(e, 0) == LE_OK); swaps[0] = (uint64_t)at; /* Clear Undo: A+B+C */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_undo(e, 0) == LE_OK); swaps[1] = (uint64_t)at; /* layer Undo: A+B */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_undo(e, 0) == LE_OK); swaps[2] = (uint64_t)at; /* layer Undo: A */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_redo(e, 0) == LE_OK); swaps[3] = (uint64_t)at; /* Redo: A+B */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_redo(e, 0) == LE_OK); swaps[4] = (uint64_t)at; /* Redo: A+B+C */
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_engine_stop_track(e, 0) == LE_OK);
    const uint64_t stop_at = (uint64_t)at;
    at = history_process(e, live, at, 2 * block, block);
    CHECK(le_engine_play(e, 0) == LE_OK);
    const uint64_t play_at = (uint64_t)at;
    at = history_process(e, live, at, 3 * block, block);
    CHECK(le_perf_disarm(e) == LE_OK);

    /* Literal content at each span (phase 37 + offset into the loop). */
    for (int i = 0; i < 37; ++i) CHECK(live[i] == 0);
    const int p0 = 37;
    CHECK(fabsf(live[p0] - (a[p0] + bb[p0] + c[p0])) < 1e-6f);
    const int p1 = (int)swaps[1];
    CHECK(fabsf(live[p1] - (a[p1 % HR_LEN] + bb[p1 % HR_LEN])) < 1e-6f);
    const int p2 = (int)swaps[2];
    CHECK(fabsf(live[p2] - a[p2 % HR_LEN]) < 1e-6f);
    for (uint64_t f = stop_at; f < play_at; ++f) CHECK(live[f] == 0);

    le_perf_log_entry facts[16];
    const int n = history_source_facts(dir, 0, facts, 16);
    CHECK(n == 7);
    if (n == 7) {
      uint32_t ids[5];
      for (int i = 0; i < 5; ++i) {
        CHECK(facts[i].cmd.code == LE_PLOG_SOURCE_APPLIED);
        CHECK(facts[i].frame == swaps[i]);
        CHECK(facts[i].cmd.restore_log.state == LE_TRACK_PLAYING);
        CHECK(facts[i].cmd.restore_log.phase == (int32_t)(swaps[i] % HR_LEN));
        CHECK(facts[i].cmd.restore_log.phase != 0);
        ids[i] = facts[i].cmd.restore_log.image_id;
        CHECK(ids[i] == (uint32_t)(i + 1));
      }
      CHECK(facts[5].cmd.code == LE_PLOG_SOURCE_TRANSPORT && facts[5].frame == stop_at);
      CHECK(facts[5].cmd.restore_log.state == LE_TRACK_STOPPED && facts[5].cmd.restore_log.image_id == ids[4]);
      CHECK(facts[6].cmd.code == LE_PLOG_SOURCE_TRANSPORT && facts[6].frame == play_at);
      CHECK(facts[6].cmd.restore_log.state == LE_TRACK_PLAYING && facts[6].cmd.restore_log.image_id == ids[4]);
    }
    CHECK(history_manifest_count(dir, "\"kind\": 1") == 5);
    history_render_parity(e, dir, HISTORY_ARM_EMPTY, live, at);
    le_engine_destroy(e);
  }
}

/* Undo-to-empty is exact silence from its raw 39; Redo-from-empty resumes with
 * the staged image at the restored phase; a muted lane stays muted through the
 * emptying and comes back unmuted; Fade is unchanged across layer swaps and
 * reset across emptying. */
static void test_history_redo_from_empty_parity(void) {
  printf("test_history_redo_from_empty_parity\n");
  le_engine* e = history_fixture();
  uint64_t id = fade_install_at(e, .5f, .5f, 0); drain(e); fade_result(e, id, LE_OK);
  const char* dir = render_test_dir("history-redo-empty");
  const char* arm = history_arm_image(e, dir);
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  static float live[2048];
  int at = history_process(e, live, at = 0, 41, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* layer Undo keeps Fade */
  at = history_process(e, live, at, 5, 1);
  fade_check_stationary(e, .5f);
  CHECK(fabsf(live[41] - .5f * ((float)42 / 256 + .25f)) < 1e-6f);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  at = history_process(e, live, at, 5, 1);
  CHECK(live[at - 1] == 0);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* layer Undo: base A, still muted */
  at = history_process(e, live, at, 5, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo-to-empty */
  const uint64_t empty_at = (uint64_t)at;
  at = history_process(e, live, at, 7, 1);
  fade_check_stationary(e, 1);
  le_track_snapshot s; le_engine_get_track(e, 0, &s);
  CHECK(s.state == LE_TRACK_EMPTY && s.muted);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* Redo-from-empty: unmuted, Fade 1 */
  const uint64_t redo_at = (uint64_t)at;
  at = history_process(e, live, at, 9, 1);
  le_engine_get_track(e, 0, &s);
  CHECK(s.state == LE_TRACK_PLAYING && !s.muted);
  fade_check_stationary(e, 1);
  CHECK(fabsf(live[redo_at] - (float)((redo_at % HR_LEN) + 1) / 256) < 1e-6f);
  for (uint64_t f = empty_at; f < redo_at; ++f) CHECK(live[f] == 0);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(history_count_code(dir, LE_CMD_UNDO_TO_EMPTY, 0) == 1);
  le_perf_log_entry facts[8];
  const int n = history_source_facts(dir, 0, facts, 8);
  CHECK(n == 3);
  if (n == 3) {
    CHECK(facts[2].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[2].frame == redo_at);
    CHECK(facts[2].cmd.restore_log.image_id == 3);
    CHECK(facts[2].cmd.restore_log.phase == (int32_t)(redo_at % HR_LEN));
  }
  history_render_parity(e, dir, arm, live, at);
  le_engine_destroy(e);
}

/* Several admissions before one callback: exactly one 322, for the slot the
 * callback mixes first, with that slot's latest id. The batch's images are
 * byte-distinct (A+B, then A), so parity proves the renderer resolved the
 * fact's id. A -> B -> A within one block produces no fact; its images are
 * listed but unreferenced, and deleting the one with the mixed slot's content
 * (id 4) changes nothing: the renderer resolves exact ids, never content. */
static void test_history_batch_before_callback(void) {
  printf("test_history_batch_before_callback\n");
  le_engine* e = history_fixture();
  const char* dir = render_test_dir("history-batch");
  const char* arm = history_arm_image(e, dir);
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  static float live[64];
  int at = history_process(e, live, 0, 5, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* id 1: A+B */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* id 2: A, the slot mixed first */
  const uint64_t swap_at = (uint64_t)at;
  at = history_process(e, live, at, 5, 1);
  CHECK(fabsf(live[swap_at] - (float)(swap_at + 1) / 256) < 1e-6f);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* id 3: A+B */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* id 4: back to the mixed slot (A) */
  at = history_process(e, live, at, 5, 1);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry facts[8];
  const int n = history_source_facts(dir, 0, facts, 8);
  CHECK(n == 1);
  if (n == 1) {
    CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[0].frame == swap_at);
    CHECK(facts[0].cmd.restore_log.image_id == 2);
  }
  CHECK(history_manifest_count(dir, "\"kind\": 1") == 4);
  for (int i = 1; i <= 4; ++i) {
    char name[32]; snprintf(name, sizeof(name), "restore-0-%d.pcm", i);
    CHECK(history_manifest_count(dir, name) == 1);
  }
  char path[700]; snprintf(path, sizeof(path), "%s/restore-0-4.pcm", dir);
  CHECK(remove(path) == 0);
  history_render_parity(e, dir, arm, live, at);
  le_engine_destroy(e);
}

/* Review finding 1: a swap admitted after le_perf_arm returned and before the
 * callback applied LE_CMD_PERF_ARM. The arm image predates the swap, so the
 * handler must not adopt the swapped slot as snapshot provenance: the first
 * mixed frame (capture frame 0) logs 322 for the staged image. */
static void test_history_arm_window_swap(void) {
  printf("test_history_arm_window_swap\n");
  le_engine* e = history_fixture();
  float a[HR_LEN], b[HR_LEN], c[HR_LEN];
  history_layer_patterns(a, b, c);
  const char* dir = render_test_dir("history-arm-window");
  const char* arm = history_arm_image(e, dir);
  CHECK(perf_arm_dir(e, dir) == LE_OK); /* ARM queued, not yet applied */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* id 1: A+B, published before ARM applies */
  static float live[64];
  const int at = history_process(e, live, 0, 8, 8);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(fabsf(live[0] - (a[0] + b[0])) < 1e-6f);
  le_perf_log_entry facts[4];
  const int n = history_source_facts(dir, 0, facts, 4);
  CHECK(n == 1);
  if (n == 1) {
    CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[0].frame == 0);
    CHECK(facts[0].cmd.restore_log.image_id == 1);
    CHECK(facts[0].cmd.restore_log.state == LE_TRACK_PLAYING);
  }
  history_render_parity(e, dir, arm, live, at);
  le_engine_destroy(e);
}

/* Review finding 3: the leg that tells a per-frame application boundary from
 * a per-block one. The swap is admitted from the stage-5 test hook, which
 * mix_tracks_frame fires AFTER this frame's live-slot loads, at frame f of a
 * 128-frame block: the mixer applies it, and the fact lands, at frame f + 1 of
 * the same block. A per-block load would place both at the next block start. */
static int history_hook_countdown;
static void history_hook_undo_mid_block(le_engine* e, int stage) {
  if (stage != 5 || history_hook_countdown-- > 0) return;
  le_test_fade_hook = NULL;
  CHECK(le_engine_undo(e, 0) == LE_OK);
}

static void test_history_mid_block_swap_frame(void) {
  printf("test_history_mid_block_swap_frame\n");
  le_engine* e = history_fixture();
  float a[HR_LEN], b[HR_LEN], c[HR_LEN];
  history_layer_patterns(a, b, c);
  const char* dir = render_test_dir("history-mid-block");
  const char* arm = history_arm_image(e, dir);
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  static float live[512];
  int at = history_process(e, live, 0, 128, 128); /* one block, no swap */
  const int f = 37;
  history_hook_countdown = f;
  le_test_fade_hook = history_hook_undo_mid_block;
  at = history_process(e, live, at, 128, 128); /* swap admitted at frame 128 + f */
  CHECK(le_test_fade_hook == NULL);
  at = history_process(e, live, at, 128, 128);
  CHECK(le_perf_disarm(e) == LE_OK);
  const int swap_at = 128 + f + 1;
  CHECK(fabsf(live[swap_at - 1] - (a[f] + b[f] + c[f])) < 1e-6f); /* still A+B+C */
  CHECK(fabsf(live[swap_at] - (a[f + 1] + b[f + 1])) < 1e-6f);     /* A+B from f+1 */
  le_perf_log_entry facts[4];
  const int n = history_source_facts(dir, 0, facts, 4);
  CHECK(n == 1);
  if (n == 1) {
    CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED);
    CHECK(facts[0].frame == (uint64_t)swap_at);
    CHECK(facts[0].cmd.restore_log.image_id == 1);
    CHECK(facts[0].cmd.restore_log.phase == (f + 1) % HR_LEN);
  }
  history_render_parity(e, dir, arm, live, at);
  le_engine_destroy(e);
}

/* G7: Clear Undo then Undo-to-empty before any mixed frame renders silence
 * and succeeds; the never-mixed restore image is listed but unreferenced. */
static void test_history_restore_then_empty_same_block(void) {
  printf("test_history_restore_then_empty_same_block\n");
  le_engine* e = fade_fixture(48000);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
  const char* dir = render_test_dir("history-restore-empty");
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* Clear Undo: image 1, never mixed */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo-to-empty in the same block */
  float live[8];
  int at = history_process(e, live, 0, 4, 1);
  for (int i = 0; i < 4; ++i) CHECK(live[i] == 0);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* Redo-from-empty: image 2 */
  at = history_process(e, live, at, 4, 1);
  CHECK(live[4] == .5f);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry facts[2];
  CHECK(history_source_facts(dir, 0, facts, 2) == 1);
  CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[0].frame == 4);
  CHECK(facts[0].cmd.restore_log.image_id == 2);
  CHECK(history_count_code(dir, LE_CMD_UNDO_TO_EMPTY, 0) == 1);
  CHECK(history_manifest_count(dir, "restore-0-1.pcm") == 1);
  history_render_parity(e, dir, HISTORY_ARM_EMPTY, live, at);
  le_engine_destroy(e);
}

/* Undo on a STOPPED track: 322 STOPPED at the observed frame (silent), 323
 * PLAYING at Play with the resumed phase. */
static void test_history_stopped_swap_then_play(void) {
  printf("test_history_stopped_swap_then_play\n");
  le_engine* e = history_fixture();
  float out[HR_LEN], zero[HR_LEN] = {0};
  le_engine_process(e, out, zero, 23);
  CHECK(le_engine_stop_track(e, 0) == LE_OK); drain(e);
  const char* dir = render_test_dir("history-stopped-swap");
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  static float live[256];
  int at = history_process(e, live, 0, 11, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  const uint64_t swap_at = (uint64_t)at;
  at = history_process(e, live, at, 6, 1);
  CHECK(le_engine_play(e, 0) == LE_OK);
  const uint64_t play_at = (uint64_t)at;
  at = history_process(e, live, at, 40, 1);
  CHECK(le_perf_disarm(e) == LE_OK);
  for (uint64_t f = 0; f < play_at; ++f) CHECK(live[f] == 0);
  CHECK(live[play_at] != 0);
  le_perf_log_entry facts[8];
  const int n = history_source_facts(dir, 0, facts, 8);
  CHECK(n == 2);
  if (n == 2) {
    CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[0].frame == swap_at);
    CHECK(facts[0].cmd.restore_log.state == LE_TRACK_STOPPED);
    CHECK(facts[1].cmd.code == LE_PLOG_SOURCE_TRANSPORT && facts[1].frame == play_at);
    CHECK(facts[1].cmd.restore_log.state == LE_TRACK_PLAYING);
    CHECK(facts[1].cmd.restore_log.image_id == facts[0].cmd.restore_log.image_id);
  }
  history_render_parity(e, dir, HISTORY_ARM_EMPTY, live, at);
  le_engine_destroy(e);
}

/* Staging refusal (ring held full) never refuses the Undo; the callback logs
 * 323/0 at the application frame and the stem fails, with the master intact
 * and the overrun reported. Leg 0: snapshot provenance (review E1: content
 * live at arm, no Clear first, arm image supplied). Leg 1: image provenance
 * (Clear Undo first, as test_fade_restore_staging_and_manifest_capacity). */
static void test_history_staging_refusal_fails_stem_keeps_undo(void) {
  printf("test_history_staging_refusal_fails_stem_keeps_undo\n");
  for (int snapshot = 1; snapshot >= 0; --snapshot) {
    le_engine* e = history_fixture();
    float a[HR_LEN], b[HR_LEN], c[HR_LEN];
    history_layer_patterns(a, b, c);
    if (!snapshot) { CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e); }
    fade_drain_gate gate = {0};
    const char* dir = render_test_dir(snapshot ? "history-refusal-snapshot" : "history-refusal-image");
    const char* arm = snapshot ? history_arm_image(e, dir) : HISTORY_ARM_EMPTY;
    if (snapshot) le_perf_drain_set_mid_cycle_hook_for_test(fade_hold_drain, &gate);
    CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
    float input = 0, output[8] = {0};
    int frames = 0;
    if (!snapshot) {
      /* An exact restoration first, so the refusal below replaces a staged
       * image rather than the arm snapshot. The drain is still running here
       * and consumes (writes and frees) that image; only then is it parked, so
       * the ring re-initialized below is empty and no staged copy is orphaned. */
      CHECK(le_engine_undo(e, 0) == LE_OK);
      le_engine_process(e, output + frames++, &input, 1);
      for (int i = 0; i < 5000 && atomic_load(&e->perf.layer_staging_ring.head) !=
           atomic_load(&e->perf.layer_staging_ring.tail); ++i) test_sleep_ms(1);
      CHECK(atomic_load(&e->perf.layer_staging_ring.head) ==
            atomic_load(&e->perf.layer_staging_ring.tail));
      le_perf_drain_set_mid_cycle_hook_for_test(fade_hold_drain, &gate);
    }
    for (int i = 0; i < 5000 && !atomic_load(&gate.entered); ++i) test_sleep_ms(1);
    CHECK(atomic_load(&gate.entered));
    /* Consumer parked and the ring empty: a small valid ring proves refusal
     * without exhausting the manifest. */
    CHECK(le_layer_staging_ring_init(&e->perf.layer_staging_ring,
        e->perf.layer_staging_ring.buffer, 2) == 1);
    le_staged_layer entry = {.channel = 1, .slot = 0, .frame = 0, .frame_count = 1, .lane_count = 1};
    entry.lane_pcm[0] = malloc(sizeof(float)); CHECK(entry.lane_pcm[0] != NULL);
    if (entry.lane_pcm[0]) entry.lane_pcm[0][0] = .5f;
    CHECK(le_layer_staging_ring_push(&e->perf.layer_staging_ring, entry) == 1);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* layer Undo: A+B, staging refused */
    const int swap_at = frames;
    le_engine_process(e, output + frames++, &input, 1);
    CHECK(fabsf(output[swap_at] - (a[swap_at] + b[swap_at])) < 1e-6f);
    CHECK(atomic_load(&e->a_perf_layer_overruns) == 1);
    atomic_store(&gate.release, 1);
    CHECK(le_perf_disarm(e) == LE_OK);
    le_perf_drain_set_mid_cycle_hook_for_test(NULL, NULL);
    le_perf_log_entry facts[4];
    const int n = history_source_facts(dir, 0, facts, 4);
    CHECK(n == (snapshot ? 1 : 2));
    if (n > 0) {
      const le_perf_log_entry* lost = &facts[n - 1];
      CHECK(lost->cmd.code == LE_PLOG_SOURCE_TRANSPORT && lost->frame == (uint64_t)swap_at);
      CHECK(lost->cmd.restore_log.image_id == 0 && lost->cmd.restore_log.state == LE_TRACK_EMPTY);
    }
    CHECK(history_manifest_count(dir, "\"layer_overruns\": 1") == 1);
    char path[700]; snprintf(path, sizeof(path), "%s/master-001.wav", dir);
    float recorded[8] = {0};
    CHECK(read_payload_file_for_test(path, (unsigned char*)recorded,
        sizeof(float) * frames) == sizeof(float) * frames);
    for (int i = 0; i < frames; ++i) CHECK(recorded[i] == output[i]);
    fade_finalize_manifest(dir, arm);
    fade_render_status(e, dir, 0);
    le_engine_destroy(e);
  }
}

/* A deleted image file fails the stem that names it; a full manifest drops a
 * later Undo image (counted) and fails that stem while the capture continues. */
static void test_history_missing_image_and_manifest_full(void) {
  printf("test_history_missing_image_and_manifest_full\n");
  for (int manifest_full = 0; manifest_full < 2; ++manifest_full) {
    le_engine* e = history_fixture();
    fade_drain_gate gate = {0};
    if (manifest_full) le_perf_drain_set_mid_cycle_hook_for_test(fade_hold_drain, &gate);
    const char* dir = render_test_dir(manifest_full ? "history-manifest-full" : "history-missing-image");
    const char* arm = history_arm_image(e, dir);
    CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
    if (manifest_full) {
      for (int i = 0; i < 5000 && !atomic_load(&gate.entered); ++i) test_sleep_ms(1);
      CHECK(atomic_load(&gate.entered));
      for (unsigned i = 0; i < LE_LAYER_STAGING_RING_CAPACITY - 1; ++i) {
        le_staged_layer entry = {.channel = 1, .slot = 0, .frame = i, .frame_count = 1, .lane_count = 1};
        entry.lane_pcm[0] = malloc(sizeof(float)); CHECK(entry.lane_pcm[0] != NULL);
        if (entry.lane_pcm[0]) entry.lane_pcm[0][0] = .5f;
        CHECK(le_layer_staging_ring_push(&e->perf.layer_staging_ring, entry) == 1);
      }
      atomic_store(&gate.release, 1);
      for (int i = 0; i < 5000 && atomic_load(&e->perf.layer_staging_ring.head) !=
           atomic_load(&e->perf.layer_staging_ring.tail); ++i) test_sleep_ms(1);
    }
    static float live[64];
    int at = history_process(e, live, 0, 3, 1);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* image 1: the last manifest entry */
    at = history_process(e, live, at, 3, 1);
    CHECK(le_engine_redo(e, 0) == LE_OK); /* image 2: dropped when full */
    at = history_process(e, live, at, 3, 1);
    CHECK(le_perf_disarm(e) == LE_OK);
    le_perf_drain_set_mid_cycle_hook_for_test(NULL, NULL);
    le_perf_log_entry facts[4];
    CHECK(history_source_facts(dir, 0, facts, 4) == 2);
    CHECK(history_manifest_count(dir, "\"stopped_early\"") == 0);
    if (manifest_full) {
      CHECK(history_manifest_count(dir, "\"layers_dropped\": 1,") == 1);
      CHECK(history_manifest_count(dir, "restore-0-1.pcm") == 1);
      CHECK(history_manifest_count(dir, "restore-0-2.pcm") == 0);
      fade_finalize_manifest(dir, arm);
      fade_render_status(e, dir, 0);
    } else {
      history_render_parity(e, dir, arm, live, at);
      char path[700]; snprintf(path, sizeof(path), "%s/restore-0-1.pcm", dir);
      CHECK(remove(path) == 0);
      fade_render_status(e, dir, 0);
    }
    char path[700]; snprintf(path, sizeof(path), "%s/master-001.wav", dir);
    float recorded[64] = {0};
    CHECK(read_payload_file_for_test(path, (unsigned char*)recorded,
        sizeof(float) * at) == sizeof(float) * at);
    for (int i = 0; i < at; ++i) CHECK(recorded[i] == live[i]);
    le_engine_destroy(e);
  }
}

/* arm, Undo (id 1), disarm, rearm, Redo (id 1 again in the new namespace):
 * each capture renders only its own image. */
static void test_history_capture_namespace(void) {
  printf("test_history_capture_namespace\n");
  le_engine* e = history_fixture();
  float a[HR_LEN], b[HR_LEN], c[HR_LEN];
  history_layer_patterns(a, b, c);
  const char* dirs[2];
  const char* arms[2];
  static float live[2][64];
  int frames[2];
  for (int capture = 0; capture < 2; ++capture) {
    char name[32]; snprintf(name, sizeof(name), "history-namespace-%d", capture);
    dirs[capture] = strdup(render_test_dir(name));
    arms[capture] = history_arm_image(e, dirs[capture]);
    CHECK(perf_arm_dir(e, dirs[capture]) == LE_OK); drain(e);
    int at = history_process(e, live[capture], 0, 5, 1);
    CHECK((capture ? le_engine_redo(e, 0) : le_engine_undo(e, 0)) == LE_OK);
    at = history_process(e, live[capture], at, 5, 1);
    frames[capture] = at;
    CHECK(le_perf_disarm(e) == LE_OK);
    le_perf_log_entry facts[4];
    CHECK(history_source_facts(dirs[capture], 0, facts, 4) == 1);
    CHECK(facts[0].cmd.restore_log.image_id == 1 && facts[0].frame == 5);
    CHECK(history_manifest_count(dirs[capture], "restore-0-1.pcm") == 1);
    CHECK(history_manifest_count(dirs[capture], "restore-0-2.pcm") == 0);
  }
  /* The two restore-0-1.pcm files hold different layers. */
  float image[2][HR_LEN];
  for (int capture = 0; capture < 2; ++capture) {
    char path[700]; snprintf(path, sizeof(path), "%s/restore-0-1.pcm", dirs[capture]);
    CHECK(read_binary_file_for_test(path, (unsigned char*)image[capture], sizeof(image[capture])) == sizeof(image[capture]));
  }
  for (int i = 0; i < HR_LEN; ++i) {
    CHECK(fabsf(image[0][i] - (a[i] + b[i])) < 1e-6f);
    CHECK(fabsf(image[1][i] - (a[i] + b[i] + c[i])) < 1e-6f);
  }
  for (int capture = 0; capture < 2; ++capture) {
    history_render_parity(e, dirs[capture], arms[capture], live[capture], frames[capture]);
    free((void*)dirs[capture]);
  }
  le_engine_destroy(e);
}

/* A loop-close restoration commit during capture publishes processed material
 * with no staged image: 323/0, the stem fails, the master is intact. */
static void test_history_loop_close_restore_fails_truthfully(void) {
  printf("test_history_loop_close_restore_fails_truthfully\n");
  le_engine* e = history_fixture();
  const char* dir = render_test_dir("history-loop-close");
  const char* arm = history_arm_image(e, dir);
  CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
  static float live[64];
  int at = history_process(e, live, 0, 4, 1);
  static float restored_pcm[HR_LEN];
  for (int i = 0; i < HR_LEN; ++i) restored_pcm[i] = .125f;
  float* restored[LE_MAX_LANES] = {restored_pcm};
  const uint32_t rev = atomic_load(&e->tracks[0].a_audio_rev);
  CHECK(le_restore_commit_layer(e, 0, 0x1u, rev, HR_LEN, restored) == LE_OK);
  at = history_process(e, live, at, 4, 1);
  CHECK(live[4] == .125f);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry facts[4];
  CHECK(history_source_facts(dir, 0, facts, 4) == 1);
  CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_TRANSPORT && facts[0].frame == 4);
  CHECK(facts[0].cmd.restore_log.image_id == 0);
  fade_finalize_manifest(dir, arm);
  fade_render_status(e, dir, 0);
  le_engine_destroy(e);
}

/* Review E3: a session import during capture rewrites a slot whose image an
 * earlier Undo staged (slot X, id 1), then Undo-to-empty keeps X live. The
 * imported PCM must not be logged as image 1: the callback logs 323/0 and the
 * stem fails. Leg 1 is the layered import (le_engine_finalize_history). */
static void test_history_import_during_capture_fails_truthfully(void) {
  printf("test_history_import_during_capture_fails_truthfully\n");
  for (int layered = 0; layered < 2; ++layered) {
    le_engine* e = history_fixture();
    const char* dir = render_test_dir(layered ? "history-import-layered" : "history-import");
    const char* arm = history_arm_image(e, dir);
    CHECK(perf_arm_dir(e, dir) == LE_OK); drain(e);
    static float live[64];
    int at = history_process(e, live, 0, 3, 1);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* layer Undo: image 1 in slot X */
    at = history_process(e, live, at, 3, 1);
    CHECK(le_engine_undo(e, 0) == LE_OK); /* layer Undo: image 2 */
    CHECK(le_engine_undo(e, 0) == LE_OK); /* undo-to-empty: a_live stays */
    at = history_process(e, live, at, 3, 1);
    float pcm[HR_LEN];
    for (int i = 0; i < HR_LEN; ++i) pcm[i] = .0625f;
    if (layered) {
      CHECK(le_engine_import_layer(e, 0, 0, 0, pcm, HR_LEN) == LE_OK);
      CHECK(finalize_layer_history(e, 0, 0, 0) == LE_OK);
    } else {
      CHECK(le_engine_import_track(e, 0, pcm, HR_LEN) == LE_OK);
    }
    CHECK(le_engine_commit_session(e, HR_LEN, 0) == LE_OK);
    drain(e);
    CHECK(le_engine_play(e, 0) == LE_OK);
    const uint64_t play_at = (uint64_t)at;
    at = history_process(e, live, at, 3, 1);
    CHECK(live[play_at] == .0625f);
    CHECK(le_perf_disarm(e) == LE_OK);
    /* Image 1 was mixed (322); image 2 was emptied in the same block it was
     * admitted (no fact); the imported PCM is provenance lost (323/0). */
    le_perf_log_entry facts[8];
    const int n = history_source_facts(dir, 0, facts, 8);
    CHECK(n == 2);
    if (n == 2) {
      CHECK(facts[0].cmd.code == LE_PLOG_SOURCE_APPLIED && facts[0].cmd.restore_log.image_id == 1);
      CHECK(facts[1].cmd.code == LE_PLOG_SOURCE_TRANSPORT && facts[1].frame == play_at);
      CHECK(facts[1].cmd.restore_log.image_id == 0);
    }
    CHECK(history_manifest_count(dir, "restore-0-2.pcm") == 1);
    fade_finalize_manifest(dir, arm);
    fade_render_status(e, dir, 0);
    le_engine_destroy(e);
  }
}

static void run_history_replay_tests(void) {
  test_history_undo_redo_literal_parity();
  test_history_redo_from_empty_parity();
  test_history_batch_before_callback();
  test_history_arm_window_swap();
  test_history_mid_block_swap_frame();
  test_history_restore_then_empty_same_block();
  test_history_stopped_swap_then_play();
  test_history_staging_refusal_fails_stem_keeps_undo();
  test_history_missing_image_and_manifest_full();
  test_history_capture_namespace();
  test_history_loop_close_restore_fails_truthfully();
  test_history_import_during_capture_fails_truthfully();
}
