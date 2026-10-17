/* Audio & tempo follow (#1179 Part 4a): a song-tempo change retimes the
 * shared clock and every following track reads its take at speed * len /
 * span. Literal oracles: every fixture imports a ramp (pcm[i] == i), so the
 * dry output IS the read index. At 4 kHz one 4/4 bar at 120 BPM is 8000
 * frames; at 90 BPM the retimed master is round(8000 * 120 / 90) = 10667. */

#define TF_SR 4000
#define TF_LEN 8000
#define TF_LEN90 10667
#define TF_TURN (TF_SR / 100) /* the turn window a retime opens (4a L1) */

static float tf_ramp[TF_LEN];

static uint64_t tf_follow(le_engine* e, int channel, int value) {
  uint64_t id = 0;
  CHECK(le_engine_set_follow_tempo(e, channel, value, &id) == LE_OK && id);
  return id;
}

/* Processes `frames` frames of `input` in blocks of 64 into out (or a
 * scratch buffer). */
static void tf_process(le_engine* e, float* out, int frames, float input) {
  float scratch[64];
  for (int at = 0; at < frames; at += 64) {
    const int n = frames - at < 64 ? frames - at : 64;
    process_const(e, input, n, out ? out + at : scratch);
  }
}

/* `tracks` ramps of TF_LEN on a one-bar 120 BPM grid, Follow default
 * `follow`, playing from the top. */
static le_engine* tf_fixture(int tracks, int follow, int max_frames) {
  for (int i = 0; i < TF_LEN; ++i) tf_ramp[i] = (float)i;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, max_frames) == LE_OK);
  for (int t = 0; t < tracks; ++t) {
    CHECK(le_engine_import_track(e, t, tf_ramp, TF_LEN) == LE_OK);
  }
  CHECK(le_engine_commit_session(e, TF_LEN, 4) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  drain(e);
  if (follow) {
    const uint64_t id = tf_follow(e, -1, 1);
    drain(e);
    fade_result(e, id, LE_OK);
  }
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  return e;
}

static le_snapshot tf_snap(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  return s;
}

/* Retiming to 90 scales the clock and the phase, keeps the bar, moves the
 * beats and reads the take at 8000 / 10667 with the origin kept; the wrap
 * lands exactly on the clock's. The old head reads on through a turn window
 * (4a L1), after which the read is the ramp oracle exactly. Back to 120 is
 * the identity head again, bit-exact, the phase carrying its fraction. */
static void test_follow_retime_ratio_and_identity(void) {
  printf("test_follow_retime_ratio_and_identity\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  static float out[3 * TF_LEN];
  tf_process(e, out, 2000, 0.0f);
  CHECK(out[1999] == 1999.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.tempo_follow == LE_TEMPO_FOLLOW_RETIMES);
  CHECK(s.recorded_tempo_bpm == 120.0f && s.follow_tempo == 1);
  CHECK(s.current_beat == 0); /* the last frame read is 1999, beat 0 */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  const int n = TF_LEN90 - 2666 + 1000; /* across the wrap */
  tf_process(e, out, n, 0.0f);
  const double r = 8000.0 / 10667.0;
  int bad = 0;
  for (int k = TF_TURN; k < n; ++k) {
    bad += fabs(out[k] - speed_ramp_at(le_head_wrap(r * (2666 + k), TF_LEN),
                                       TF_LEN)) >= 2e-3;
  }
  CHECK(bad == 0);
  /* Inside the window the blend stays between the two heads' reads: the
   * old one on at 1 from 2000, the new one at 0.75 from 1999.5 (the
   * clock's whole 2666 x 0.75; the old head alone was a half-sample step
   * back). No step: each frame moves less than 1.1. */
  for (int k = 0; k < TF_TURN; ++k) {
    CHECK(out[k] >= 1999.49f + 0.75f * k && out[k] <= 2000.01f + k);
    if (k > 0) CHECK(out[k] - out[k - 1] > 0.5f && out[k] - out[k - 1] < 1.1f);
  }
  CHECK(out[TF_LEN90 - 2666] == 0.0f); /* the clock's top is the take's */
  s = tf_snap(e);
  CHECK(s.tempo_bpm == 90.0f && s.master_length_frames == TF_LEN90);
  CHECK(s.loop_bars == 1 && s.recorded_tempo_bpm == 120.0f);
  CHECK(s.tracks[0].head_rate_milli == 749);
  CHECK(s.tracks[0].length_frames == TF_LEN); /* the take is untouched */
  /* The beats divide the new length: beat 2 starts at 5334, not 4000. */
  tf_process(e, NULL, 5333 - 1000 + 1, 0.0f); /* last frame at 5333 */
  CHECK(tf_snap(e).current_beat == 1);
  tf_process(e, NULL, 1, 0.0f);
  CHECK(tf_snap(e).current_beat == 2);
  /* Back to the recorded tempo: the recorded length and the identity head,
   * continuing from the scaled phase. */
  const int32_t at90 = tf_snap(e).master_position_frames;
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, out, 9000, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN && s.tracks[0].head_rate_milli == 1000);
  bad = 0;
  for (int k = TF_TURN + 1; k < 9000; ++k) {
    const float want = out[k - 1] == TF_LEN - 1 ? 0.0f : out[k - 1] + 1.0f;
    bad += out[k] != want || out[k] != (float)(int)out[k];
  }
  CHECK(bad == 0);
  /* 2000 scaled to 2666.75: the 0.75 rides into the way back. */
  const int64_t home = (int64_t)floor((at90 + 0.75) * TF_LEN / TF_LEN90);
  CHECK(out[TF_TURN] == (float)((home + TF_TURN) % TF_LEN));
  le_engine_destroy(e);
}

/* A take recorded at the new tempo plays at its own speed while the old one
 * stretches; back at the old tempo they swap roles, and a punch-in is
 * refused on whichever take a retime moved off its span. */
static void test_follow_new_take_at_new_tempo(void) {
  printf("test_follow_new_take_at_new_tempo\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 128, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED); /* off its span */
  /* ...and a punch-in that fires anyway is dropped by the callback. */
  static float before[TF_LEN], after[TF_LEN];
  CHECK(le_engine_export_track(e, 0, before, TF_LEN) == TF_LEN);
  CHECK(le_push(e, LE_CMD_RECORD, 0, 0.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.25f);
  CHECK(tf_snap(e).tracks[0].state == LE_TRACK_PLAYING);
  CHECK(le_engine_export_track(e, 0, after, TF_LEN) == TF_LEN);
  int changed = 0;
  for (int i = 0; i < TF_LEN; ++i) changed += after[i] != before[i];
  CHECK(changed == 0);
  CHECK(le_engine_record(e, 1) == LE_OK);
  tf_process(e, NULL, 4000, 0.25f);
  CHECK(le_engine_record(e, 1) == LE_OK);
  tf_process(e, NULL, 1024, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == TF_LEN90);
  CHECK(s.tracks[1].head_rate_milli == 1000);
  CHECK(s.tracks[0].head_rate_milli == 749);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN);
  CHECK(s.tracks[0].head_rate_milli == 1000);
  CHECK(s.tracks[1].head_rate_milli == 1333); /* 10667 / 8000 */
  CHECK(le_engine_record(e, 1) == LE_ERR_TRANSFORMED);
  CHECK(le_engine_record(e, 0) == LE_OK); /* home again */
  le_engine_destroy(e);
}

/* A track that keeps its recorded speed reads on continuously through the
 * retime at rate 1, its lap its own; its punch-in is refused all the same;
 * Stop/Play re-anchors it on the song clock; turning Follow on for it
 * re-rates it from the index it was reading. */
static void test_follow_off_detaches(void) {
  printf("test_follow_off_detaches\n");
  le_engine* e = tf_fixture(2, 1, 4 * TF_LEN);
  uint64_t id = tf_follow(e, 1, 0);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK); /* hear track 1 alone */
  static float out[2 * TF_LEN];
  tf_process(e, out, 3000, 0.0f);
  fade_result(e, id, LE_OK);
  le_snapshot s = tf_snap(e);
  CHECK(s.tracks[1].follow_override == 0 && s.tracks[0].follow_override == -1);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out + 3000, 9000, 0.0f);
  int bad = 0;
  for (int k = 1; k < 12000; ++k) bad += out[k] != (float)(k % TF_LEN);
  CHECK(bad == 0); /* one continuous lap of 8000, not the song's 10667 */
  s = tf_snap(e);
  CHECK(s.tracks[1].head_rate_milli == 1000 && s.tracks[0].head_rate_milli == 749);
  CHECK(le_engine_record(e, 1) == LE_ERR_TRANSFORMED);
  /* Follow on for it: the index continues, then advances at 0.75. */
  id = tf_follow(e, 1, -1);
  tf_process(e, out, 400, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(fabsf(out[0] - (float)(12000 % TF_LEN)) < 1.0f);
  for (int k = 200; k < 400; ++k) {
    CHECK(fabsf(out[k] - out[k - 1] - (float)(8000.0 / 10667.0)) < 1e-3f);
  }
  CHECK(tf_snap(e).tracks[1].head_rate_milli == 749);
  le_engine_destroy(e);
}

/* What keeps the tempo locked: no follower, no bar grid, a capture or its
 * punch tail, and a length the buffers cannot hold. The setting validates
 * its arguments. */
static void test_follow_guards(void) {
  printf("test_follow_guards\n");
  uint64_t id;
  {
    le_engine* idle = le_engine_create();
    CHECK(le_engine_set_follow_tempo(idle, -1, 1, &id) == LE_ERR_NOT_RUNNING);
    le_engine_destroy(idle);
  }
  le_engine* e = tf_fixture(1, 0, 4 * TF_LEN);
  CHECK(le_engine_set_follow_tempo(e, -1, -1, &id) == LE_ERR_INVALID && !id);
  CHECK(le_engine_set_follow_tempo(e, -2, 1, &id) == LE_ERR_INVALID);
  CHECK(le_engine_set_follow_tempo(e, 0, 2, &id) == LE_ERR_INVALID);
  CHECK(le_engine_set_follow_tempo(e, LE_MAX_TRACKS, 1, &id) == LE_ERR_INVALID);
  CHECK(tf_snap(e).tempo_follow == LE_TEMPO_FOLLOW_NO_FOLLOWER);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.tempo_bpm == 120.0f && s.master_length_frames == TF_LEN);
  /* An override alone makes a follower. */
  id = tf_follow(e, 0, 1);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(tf_snap(e).tempo_follow == LE_TEMPO_FOLLOW_RETIMES);
  /* Overdubbing, then its punch tail, keep it locked. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tf_process(e, NULL, 64, 0.25f);
  CHECK(tf_snap(e).tempo_follow == LE_TEMPO_FOLLOW_BUSY);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).tempo_bpm == 120.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f); /* the tail is still writing */
  CHECK(tf_snap(e).tempo_bpm == 120.0f);
  settle_layers(e);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).master_length_frames == TF_LEN90);
  le_engine_destroy(e);
  /* 10667 frames do not fit a 10000-frame rig: nothing changes. */
  e = tf_fixture(1, 1, 10000);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.tempo_bpm == 120.0f && s.master_length_frames == TF_LEN);
  CHECK(le_engine_set_tempo(e, 100.0f) == LE_OK); /* 9600 fits */
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).master_length_frames == 9600);
  le_engine_destroy(e);
  /* No bar grid: nothing to follow, the tempo stays. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_import_track(e, 0, tf_ramp, TF_LEN) == LE_OK);
  CHECK(le_engine_commit_session(e, TF_LEN, 0) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  drain(e);
  id = tf_follow(e, -1, 1);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(tf_snap(e).tempo_follow == LE_TEMPO_FOLLOW_NO_GRID);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.tempo_bpm == 120.0f && s.master_length_frames == TF_LEN);
  le_engine_destroy(e);
}

/* A Sync division keeps whole slices: 10667 rounds up to 10668, the half
 * reads 4000 / 5334 and laps twice per bar. A mode switch re-clocks every
 * take at its own length and returns the song to its recorded tempo. */
static void test_follow_division_and_mode_switch(void) {
  printf("test_follow_division_and_mode_switch\n");
  for (int i = 0; i < TF_LEN; ++i) tf_ramp[i] = (float)i;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_import_track(e, 0, tf_ramp, TF_LEN) == LE_OK);
  CHECK(le_engine_import_track(e, 1, tf_ramp, TF_LEN / 2) == LE_OK);
  CHECK(le_engine_commit_session(e, TF_LEN, 4) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  drain(e);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  uint64_t id = tf_follow(e, -1, 1);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  static float out[2 * TF_LEN];
  tf_process(e, out, 2 * 5334 + 10, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.master_length_frames == 10668 && s.master_length_frames % 2 == 0);
  CHECK(s.tracks[1].head_rate_milli == 749 && s.tracks[0].head_rate_milli == 749);
  const double r = 4000.0 / 5334.0;
  int bad = 0;
  for (int k = TF_TURN; k < 2 * 5334 + 10; ++k) {
    bad += fabs(out[k] - speed_ramp_at(le_head_wrap(r * k, 4000), 4000)) >= 2e-3;
  }
  CHECK(bad == 0);
  CHECK(out[5334] == 0.0f && out[2 * 5334] == 0.0f); /* two laps a bar */
  /* Stopped, a switch back to Multi re-clocks the takes at their own
   * lengths (Multi's base is the shortest take, the half) and returns the
   * song to its recorded tempo. */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_stop_track(e, 1) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_MULTI) == LE_OK);
  drain(e);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN / 2 && s.tempo_bpm == 120.0f);
  CHECK(s.tracks[0].head_rate_milli == 1000 && s.tracks[1].head_rate_milli == 1000);
  CHECK(le_engine_record(e, 0) == LE_OK); /* back on its span */
  le_engine_destroy(e);
}

/* A take cleared and restored after a retime comes back at the retimed
 * clock's ratio, its punch-in refused until the tempo returns. */
static void test_follow_clear_undo_keeps_ratio(void) {
  printf("test_follow_clear_undo_keeps_ratio\n");
  le_engine* e = tf_fixture(2, 1, 4 * TF_LEN);
  tf_process(e, NULL, 128, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_clear_undoable(e, 1) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).tracks[1].head_rate_milli == 1000); /* empty: the Speed */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].head_rate_milli == 749);
  CHECK(le_engine_record(e, 1) == LE_ERR_TRANSFORMED);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).tracks[1].head_rate_milli == 1000);
  CHECK(le_engine_record(e, 1) == LE_OK);
  le_engine_destroy(e);
}

/* The offline stem reproduces the live mix sample-exactly through a retime,
 * a Speed step composing with it (1/2 * 8000 / 10667), a Follow-off turn and
 * the way back, from the logged spans and indices. */
static void test_follow_render_parity(void) {
  printf("test_follow_render_parity\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  const char* dir = render_test_dir("follow-render");
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  static float live[5 * TF_LEN], replay[5 * TF_LEN];
  int at = 0;
  tf_process(e, live, 2000, 0.0f);
  at += 2000;
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, live + at, 9000, 0.0f);
  at += 9000;
  uint64_t id = speed_set(e, 1, 2);
  tf_process(e, live + at, 3001, 0.0f);
  at += 3001;
  fade_result(e, id, LE_OK);
  CHECK(tf_snap(e).tracks[0].head_rate_milli == 374);
  id = tf_follow(e, 0, 0); /* keeps its recorded speed: 1/2 alone */
  tf_process(e, live + at, 2003, 0.0f);
  at += 2003;
  fade_result(e, id, LE_OK);
  id = tf_follow(e, 0, -1);
  tf_process(e, live + at, 1000, 0.0f);
  at += 1000;
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, live + at, 1500, 0.0f);
  at += 1500;
  id = speed_set(e, 1, 1);
  tf_process(e, live + at, 1500, 0.0f);
  at += 1500;
  fade_result(e, id, LE_OK);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(tf_snap(e).tracks[0].head_rate_milli == 1000);
  float pcm[TF_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, TF_LEN) == TF_LEN);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, TF_LEN, TF_SR);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int frames = test_read_wet_stem(dir, 0, replay, 5 * TF_LEN);
  CHECK(frames == at);
  int bad = 0, first = -1;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) >= 2e-3f) {
      if (first < 0) first = i;
      ++bad;
    }
  }
  if (bad) printf("  first mismatch at %d: live %f replay %f\n", first,
                  live[first], replay[first]);
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* A master recorded live at a set tempo latches it as the recorded tempo
 * (the snapshot shows it), and a later retime scales from it. */
static void test_follow_live_master_latches(void) {
  printf("test_follow_live_master_latches\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tf_process(e, NULL, TF_LEN, 0.25f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize: one bar */
  tf_process(e, NULL, 1024, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN && s.loop_bars == 1);
  CHECK(s.recorded_tempo_bpm == 120.0f);
  const uint64_t id = tf_follow(e, -1, 1);
  tf_process(e, NULL, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN90 && s.recorded_tempo_bpm == 120.0f);
  /* Clearing the last take: no recorded tempo, and the tempo is free. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.recorded_tempo_bpm == 0.0f && s.tempo_follow == LE_TEMPO_FOLLOW_FREE);
  le_engine_destroy(e);
}

/* A capture armed after a retime renders the stem from the span the arm
 * logs (PERF_ARM's 329), sample-exactly. */
static void test_follow_arm_while_retimed(void) {
  printf("test_follow_arm_while_retimed\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 1500, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 777, 0.0f);
  const char* dir = render_test_dir("follow-arm");
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  static float live[3 * TF_LEN], replay[3 * TF_LEN];
  const int total = 2 * TF_LEN90;
  tf_process(e, live, total, 0.0f);
  CHECK(le_perf_disarm(e) == LE_OK);
  float pcm[TF_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, TF_LEN) == TF_LEN);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, TF_LEN, TF_SR);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int frames = test_read_wet_stem(dir, 0, replay, 3 * TF_LEN);
  CHECK(frames == total);
  int bad = 0;
  for (int i = 0; i < frames; ++i) bad += fabsf(replay[i] - live[i]) >= 2e-3f;
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* 4a H1: after a retime, clearing the LAST take and undoing it brings the
 * take back on the retimed clock at the retimed ratio, the recorded tempo
 * still the one it was laid down at; the way home is exact. */
static void test_follow_clear_last_take_undo(void) {
  printf("test_follow_clear_last_take_undo\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 128, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.master_length_frames == 0 && s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.master_length_frames == TF_LEN90 && s.tempo_bpm == 90.0f);
  CHECK(s.tracks[0].head_rate_milli == 749);
  CHECK(s.recorded_tempo_bpm == 120.0f);
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN && s.tracks[0].head_rate_milli == 1000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_destroy(e);
}

/* 4a M1: within LE_TEMPO_SNAP_BPM of the recorded tempo the song returns
 * to it exactly (tempo, length, every take on its span); beyond it the
 * bar count sets the length and the take stays off its span. */
static void test_follow_snap_to_recorded(void) {
  printf("test_follow_snap_to_recorded\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 128, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_set_tempo(e, 120.04f) == LE_OK); /* a rounded display */
  tf_process(e, NULL, 64, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.tempo_bpm == 120.0f && s.master_length_frames == TF_LEN);
  CHECK(s.tracks[0].head_rate_milli == 1000);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_set_tempo(e, 120.06f) == LE_OK); /* a real change */
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.tempo_bpm == 120.06f && s.master_length_frames == 7996);
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED);
  le_engine_destroy(e);
}

/* 4a M2 (plan 4.2): the new length is round(bars x frames_per_bar), not the
 * recorded length scaled. A master played a little long (8010 frames, one
 * bar at 120) retimes to the bar at 90, 10667, not 10680; the recorded
 * tempo brings back its own 8010. */
static void test_follow_length_on_the_bar(void) {
  printf("test_follow_length_on_the_bar\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tf_process(e, NULL, 8010, 0.25f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tf_process(e, NULL, 1024, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.master_length_frames == 8010 && s.loop_bars == 1);
  CHECK(s.recorded_tempo_bpm == 120.0f);
  const uint64_t id = tf_follow(e, -1, 1);
  tf_process(e, NULL, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(tf_snap(e).master_length_frames == TF_LEN90);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == 8010 && s.tracks[0].head_rate_milli == 1000);
  le_engine_destroy(e);
}

/* 4a L1: a retime neither clicks nor drifts. Across twenty retimes at
 * assorted positions the ramp's output bends without a corner: the step
 * from one frame to the next changes by under 0.4 (a linear window at two
 * rates bends it by up to their difference, 0.25; a bare switch adds up to a
 * sample of index), because the old head reads on through the turn window.
 * Fifty immediate 90/120 pairs leave the song where it would have been
 * without them (the phase keeps its fraction). */
static void test_follow_retime_no_click_no_drift(void) {
  printf("test_follow_retime_no_click_no_drift\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  static float out[40 * 211];
  int at = 0;
  for (int i = 0; i < 20; ++i) {
    CHECK(le_engine_set_tempo(e, i % 2 ? 120.0f : 90.0f) == LE_OK);
    tf_process(e, out + at, 211 + 13 * i, 0.0f);
    at += 211 + 13 * i;
  }
  int corners = 0;
  for (int k = 2; k < at; ++k) {
    if (out[k] > 7900.0f || out[k - 2] > 7900.0f || out[k] < 100.0f) continue;
    const float bend = (out[k] - out[k - 1]) - (out[k - 1] - out[k - 2]);
    if ((bend > 0.4f || bend < -0.4f) && corners++ == 0) {
      printf("  first corner at %d: %f %f %f\n", k, out[k - 2], out[k - 1],
             out[k]);
    }
  }
  CHECK(corners == 0);
  le_engine_destroy(e);
  e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 1201, 0.0f);
  const int32_t start = tf_snap(e).master_position_frames;
  for (int i = 0; i < 50; ++i) {
    CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
    CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
    tf_process(e, NULL, 64, 0.0f);
  }
  const int32_t end = tf_snap(e).master_position_frames;
  const int32_t want = (start + 50 * 64) % TF_LEN;
  CHECK(end - want <= 1 && want - end <= 1);
  le_engine_destroy(e);
}

/* Part 4b: a Session recall of a retimed rig with takes at two tempi. The
 * snapshot carries the recorded pair and each take's span; a fresh engine
 * restores the recorded tempo, imports the takes with their spans, commits
 * at the recorded length and retimes: every take reads at the ratio it had,
 * the clock exactly the saved one. */
static void test_follow_session_recall_spans(void) {
  printf("test_follow_session_recall_spans\n");
  le_engine* e = tf_fixture(1, 1, 4 * TF_LEN);
  tf_process(e, NULL, 128, 0.0f);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  CHECK(le_engine_record(e, 1) == LE_OK);
  tf_process(e, NULL, 4000, 0.25f);
  CHECK(le_engine_record(e, 1) == LE_OK);
  tf_process(e, NULL, 1024, 0.0f);
  le_snapshot s = tf_snap(e);
  CHECK(s.recorded_tempo_bpm == 120.0f && s.recorded_length_frames == TF_LEN);
  CHECK(s.master_length_frames == TF_LEN90);
  CHECK(s.tracks[0].span_frames == TF_LEN && s.tracks[1].span_frames == 0);
  CHECK(s.tracks[1].length_frames == TF_LEN90);
  static float take0[TF_LEN], take1[TF_LEN90];
  CHECK(le_engine_export_track(e, 0, take0, TF_LEN) == TF_LEN);
  CHECK(le_engine_export_track(e, 1, take1, TF_LEN90) == TF_LEN90);
  le_engine_destroy(e);
  /* What a Session saves for track 1: span 0 means the clock in force. */
  const int32_t span1 = s.tracks[1].span_frames > 0 ? s.tracks[1].span_frames
                                                     : s.master_length_frames;
  e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_import_span(e, 0, TF_LEN) == LE_ERR_INVALID); /* no take */
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  /* The recall installs Follow before the takes (Part 4b's order). */
  const uint64_t id = tf_follow(e, -1, 1);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_import_track(e, 0, take0, TF_LEN) == LE_OK);
  CHECK(le_engine_import_track(e, 1, take1, TF_LEN90) == LE_OK);
  CHECK(le_engine_import_span(e, 1, 4 * TF_LEN + 1) == LE_ERR_INVALID);
  CHECK(le_engine_import_span(e, 1, span1) == LE_OK);
  CHECK(le_engine_commit_session(e, TF_LEN, 4) == LE_OK);
  drain(e);
  CHECK(le_engine_import_span(e, 1, span1) == LE_ERR_INVALID); /* committed */
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN && s.recorded_tempo_bpm == 120.0f);
  CHECK(s.tracks[1].span_frames == TF_LEN90 && s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].head_rate_milli == 1333); /* parked at its span's rate */
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  drain(e);
  s = tf_snap(e);
  CHECK(s.tracks[0].head_rate_milli == 1000);
  CHECK(s.tracks[1].head_rate_milli == 1333); /* its take over the bar */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, NULL, 64, 0.0f);
  s = tf_snap(e);
  CHECK(s.master_length_frames == TF_LEN90 && s.recorded_tempo_bpm == 120.0f);
  CHECK(s.tracks[0].head_rate_milli == 749 && s.tracks[1].head_rate_milli == 1000);
  CHECK(le_engine_record(e, 1) == LE_OK); /* on its span: overdub allowed */
  le_engine_destroy(e);
  /* A span belongs to the take it was given for: a fresh lane-0 import
   * (a retried load) starts without one. */
  e = le_engine_create();
  CHECK(le_engine_configure(e, TF_SR, 1, 1, 4 * TF_LEN) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  CHECK(le_engine_import_track(e, 0, take0, TF_LEN) == LE_OK);
  CHECK(le_engine_import_span(e, 0, TF_LEN90) == LE_OK);
  CHECK(le_engine_import_track(e, 0, take0, TF_LEN) == LE_OK);
  /* Two laps laid down at 180 BPM (5333 each) on the 8000 recorded clock:
   * the laps come from the span, 10666 / 5333 = 2, not from the clock. */
  CHECK(le_engine_import_track(e, 1, take1, 2 * 5333) == LE_OK);
  CHECK(le_engine_import_span(e, 1, 5333) == LE_OK);
  /* The layered import's first image starts a new take the same way. */
  CHECK(le_engine_import_track(e, 2, take0, TF_LEN) == LE_OK);
  CHECK(le_engine_import_span(e, 2, TF_LEN90) == LE_OK);
  CHECK(le_engine_import_layer(e, 2, 0, 0, take0, TF_LEN) == LE_OK);
  CHECK(le_engine_commit_session(e, TF_LEN, 4) == LE_OK);
  drain(e);
  s = tf_snap(e);
  CHECK(s.tracks[0].span_frames == 0 && s.tracks[0].head_rate_milli == 1000);
  CHECK(s.tracks[1].multiple == 2 && s.tracks[1].span_frames == 5333);
  CHECK(s.tracks[2].span_frames == 0);
  le_engine_destroy(e);
}

static void run_tempo_follow_tests(void) {
  test_follow_session_recall_spans();
  test_follow_clear_last_take_undo();
  test_follow_snap_to_recorded();
  test_follow_length_on_the_bar();
  test_follow_retime_no_click_no_drift();
  test_follow_live_master_latches();
  test_follow_arm_while_retimed();
  test_follow_retime_ratio_and_identity();
  test_follow_new_take_at_new_tempo();
  test_follow_off_detaches();
  test_follow_guards();
  test_follow_division_and_mode_switch();
  test_follow_clear_undo_keeps_ratio();
  test_follow_render_parity();
}
