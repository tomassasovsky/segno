/* Takes keep the lap they were played on (#854). Included by
 * test_engine_core.c after test_engine_reopen.h and test_engine_render.h.
 *
 * The owner's example: a 1-bar master, a 4-bar chord take started on bar 1
 * and a 4-bar melody started on bar 3. Live, the melody's first bar lands on
 * the chords' third. Every reset path used to start both takes' first bar on
 * bar 1, two bars off from each other. */

/* Each lap of the takes holds one constant, so the mix names the segment
 * each one plays. The values stay far below the limiter. */
static const float anchor_chords[4] = {0.01f, 0.02f, 0.03f, 0.04f};
static const float anchor_melody[4] = {0.1f, 0.2f, 0.3f, 0.4f};

/* Pumps silence to the top of the next lap whose count is `bar` mod 4. */
static void anchor_to_bar(le_engine* e, int bar) {
  float out[1];
  while (e->clock.position != 0 || e->loop_iteration % 4 != (uint64_t)bar) {
    process_const(e, 0.0f, 1, out);
  }
}

/* Records a 4-bar take on `ch` from the current lap top, one lap per value. */
static void anchor_record_4(le_engine* e, int32_t ch, const float* laps) {
  float out[LOOP_N];
  CHECK(le_engine_record(e, ch) == LE_OK);
  for (int lap = 0; lap < 4; ++lap) process_const(e, laps[lap], LOOP_N, out);
  CHECK(le_engine_record(e, ch) == LE_OK);
  drain(e);
}

/* Plays four laps from a lap top. Returns the chords' segment on the first
 * lap, or -1 unless every lap mixed chord segment s with melody segment
 * s + 2 (mod 4): the two bars the melody was recorded after the chords. */
static int anchor_play_laps(le_engine* e) {
  float out[4 * LOOP_N];
  CHECK(e->clock.position == 0);
  process_const(e, 0.0f, 4 * LOOP_N, out);
  int first = -1;
  for (int lap = 0; lap < 4; ++lap) {
    int found = -1;
    for (int s = 0; s < 4; ++s) {
      const float want = anchor_chords[s] + anchor_melody[(s + 2) % 4];
      int all = 1;
      for (int i = 0; i < LOOP_N; ++i) {
        all &= fabsf(out[lap * LOOP_N + i] - want) < 1e-5f;
      }
      if (all) found = s;
    }
    if (found < 0) return -1;
    if (lap == 0) {
      first = found;
    } else if (found != (first + lap) % 4) {
      return -1;
    }
  }
  return first;
}

static void anchor_stop_all(le_engine* e, int32_t tracks) {
  float out[LOOP_N];
  for (int32_t ch = 0; ch < tracks; ++ch) {
    CHECK(le_engine_stop_track(e, ch) == LE_OK);
  }
  process_const(e, 0.0f, 3, out); /* held at the top */
  CHECK(e->transport_held);
}

static void anchor_play_all(le_engine* e, int32_t tracks) {
  for (int32_t ch = 0; ch < tracks; ++ch) {
    CHECK(le_engine_play(e, ch) == LE_OK);
  }
  drain(e);
}

/* The owner's example through every reset: Stop-all then Play, a Session
 * saved and recalled into a fresh engine, a retained reopen, the undo of a
 * Clear and the redo of an undone take. After each restart the chords start
 * on bar 1 and the melody keeps its two-bar offset. */
static void test_anchor_offset_survives_resets(void) {
  printf("test_anchor_offset_survives_resets\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 0.0f); /* a silent 1-bar master on track 0 */
  anchor_to_bar(e, 0);
  anchor_record_4(e, 1, anchor_chords);
  anchor_to_bar(e, 2);
  anchor_record_4(e, 2, anchor_melody);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 4);
  CHECK(s.tracks[2].multiple == 4);
  CHECK(s.tracks[0].anchor_lap == 0);
  CHECK(s.tracks[1].anchor_lap == 0);
  CHECK(s.tracks[2].anchor_lap == 2);
  anchor_to_bar(e, 0);
  CHECK(anchor_play_laps(e) == 0); /* live, as played */

  /* Stop-all, then Play: the rig restarts at lap 0. */
  anchor_stop_all(e, 3);
  anchor_play_all(e, 3);
  CHECK(e->loop_iteration == 0);
  CHECK(anchor_play_laps(e) == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].anchor_lap == 2);

  /* A Session: the stems and each take's anchor, saved and recalled into a
   * fresh engine. */
  float pcm[3][4 * LOOP_N];
  int32_t len[3];
  int32_t anchor[3];
  le_engine_get_snapshot(e, &s);
  for (int32_t ch = 0; ch < 3; ++ch) {
    len[ch] = le_engine_export_track(e, ch, pcm[ch], 4 * LOOP_N);
    anchor[ch] = s.tracks[ch].anchor_lap;
  }
  CHECK(len[0] == LOOP_N && len[1] == 4 * LOOP_N && len[2] == 4 * LOOP_N);
  le_engine_destroy(e);
  e = make_configured_engine();
  for (int32_t ch = 0; ch < 3; ++ch) {
    CHECK(le_engine_import_track(e, ch, pcm[ch], len[ch]) == LE_OK);
    CHECK(le_engine_import_anchor(e, ch, anchor[ch]) == LE_OK);
  }
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  anchor_play_all(e, 3);
  CHECK(anchor_play_laps(e) == 0);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].anchor_lap == 0);
  CHECK(s.tracks[2].anchor_lap == 2);

  /* A retained reopen (#1140) parks the takes at the head, in place. */
  int32_t outcome = -99, mask = -99;
  CHECK(le_engine_reopen_configured(e, 48000, 1, 1, 1000, &outcome, &mask) ==
        LE_OK);
  CHECK(mask == 0);
  anchor_play_all(e, 3);
  CHECK(anchor_play_laps(e) == 0);

  /* Undo of a Clear: the melody is cleared, the rest restarts without it,
   * and the undo brings it back two bars after the chords. */
  CHECK(le_engine_clear_undoable(e, 2) == LE_OK);
  drain(e);
  anchor_stop_all(e, 2);
  anchor_play_all(e, 2);
  pump_frames(e, 0.0f, LOOP_N);
  CHECK(le_engine_undo(e, 2) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[2].anchor_lap == 2);
  anchor_to_bar(e, 0);
  CHECK(anchor_play_laps(e) == 0);

  /* Redo of an undone take: undo takes the melody off (its base take), the
   * rest restarts, and the redo brings it back where it was. */
  CHECK(le_engine_undo(e, 2) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].state == LE_TRACK_EMPTY);
  anchor_stop_all(e, 2);
  anchor_play_all(e, 2);
  pump_frames(e, 0.0f, LOOP_N);
  CHECK(le_engine_redo(e, 2) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[2].anchor_lap == 2);
  anchor_to_bar(e, 0);
  CHECK(anchor_play_laps(e) == 0);

  /* And the Stop-all after all of it still restarts them in place. */
  anchor_stop_all(e, 3);
  anchor_play_all(e, 3);
  CHECK(anchor_play_laps(e) == 0);

  le_engine_destroy(e);
}

/* The import refuses a negative lap and a track it cannot place, and the
 * commit reduces the lap modulo the multiple it parks the take at. */
static void test_anchor_import_contract(void) {
  printf("test_anchor_import_contract\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  float master[LOOP_N] = {0};
  float take[2 * LOOP_N] = {0};

  CHECK(le_engine_import_anchor(e, 1, 1) == LE_ERR_INVALID); /* no take */
  CHECK(le_engine_import_track(e, 0, master, LOOP_N) == LE_OK);
  CHECK(le_engine_import_track(e, 1, take, 2 * LOOP_N) == LE_OK);
  CHECK(le_engine_import_anchor(e, 1, -1) == LE_ERR_INVALID);
  CHECK(le_engine_import_anchor(e, 99, 1) == LE_ERR_INVALID);
  CHECK(le_engine_import_anchor(e, 1, 3) == LE_OK); /* 3 mod 2 */
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].anchor_lap == 1);
  CHECK(le_engine_import_anchor(e, 1, 1) == LE_ERR_INVALID); /* not EMPTY */

  /* A new import starts a new take: the anchor given to the old one is
   * gone. */
  le_engine_destroy(e);
  e = make_configured_engine();
  CHECK(le_engine_import_track(e, 0, master, LOOP_N) == LE_OK);
  CHECK(le_engine_import_track(e, 1, take, 2 * LOOP_N) == LE_OK);
  CHECK(le_engine_import_anchor(e, 1, 1) == LE_OK);
  CHECK(le_engine_import_track(e, 1, take, 2 * LOOP_N) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].anchor_lap == 0);

  le_engine_destroy(e);
}

/* The DAW export places an arm-time image at its anchor (#854): a 2-bar take
 * played from bar 2 reads its first bar on odd laps, and the stem must too.
 * The master is silent, so the live mix is the take alone. */
static void test_anchor_perf_render_arm_image(void) {
  printf("test_anchor_perf_render_arm_image\n");
  const char* dir = render_test_dir("anchorarm");
  const int32_t sr = 48000;
  float out[64];
  float live[64];
  le_snapshot s;

  le_engine* e = make_configured_engine();
  record_base_loop(e, 0.0f);
  anchor_to_bar(e, 1);
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.25f, LOOP_N, out);
  process_const(e, 0.5f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].anchor_lap == 1);
  /* Stop-all and Play, then arm on lap 1: the take sounds its first bar
   * there, where a phase counted from anchor 0 would read its second. */
  anchor_stop_all(e, 2);
  anchor_play_all(e, 2);
  process_const(e, 0.0f, LOOP_N + 1, out);
  CHECK(e->loop_iteration == 1);

  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  const int32_t frames = 5 * LOOP_N;
  process_const(e, 0.0f, frames, live);
  le_engine_get_snapshot(e, &s);
  const uint64_t capture_frames = (uint64_t)s.perf_frames;
  CHECK(capture_frames == (uint64_t)frames);

  float lane0[LOOP_N] = {0};
  float lane1[2 * LOOP_N] = {0};
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, LOOP_N) == LOOP_N);
  CHECK(le_engine_export_track_lane(e, 1, 0, lane1, 2 * LOOP_N) == 2 * LOOP_N);
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane0, LOOP_N, sr);
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane1, 2 * LOOP_N, sr);
  CHECK(le_perf_disarm(e) == LE_OK);

  char manifest[1600];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": 1, "
           "\"masterGain\": 1.0, \"limiterOn\": false, "
           "\"limiterCeiling\": 0.99, \"tracks\": ["
           "{\"channel\": 0, \"volume\": 1.0, \"muted\": false, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track0-lane0.wav\", \"effects\": []}]}, "
           "{\"channel\": 1, \"volume\": 1.0, \"muted\": false, "
           "\"anchorLap\": 1, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track1-lane0.wav\", \"effects\": []}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
           sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);

  float stem1[64] = {0};
  CHECK(test_read_stem(dir, 1, stem1, 64) == frames);
  CHECK(fabsf(live[0] - 0.25f) < 1e-6f); /* the take's first bar */
  for (int32_t f = 0; f < frames; ++f) {
    CHECK(fabsf(stem1[f] - live[f]) < 1e-6f);
  }
  le_engine_destroy(e);
}

static void run_anchor_tests(void) {
  test_anchor_offset_survives_resets();
  test_anchor_import_contract();
  test_anchor_perf_render_arm_image();
}
