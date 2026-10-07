/* Pitch across a retime (#1179 Part 4a-ii). A following track with Pitch
 * Unchanged plays its take through the varispeed head (timing exact, pitch
 * off by the tempo ratio, reported) until the cache worker's stretch render
 * to the new span lands, then crossfades to it and sounds its own pitch.
 * Spectral oracles on a 220 Hz sine of a whole number of cycles: one 4/4 bar
 * at 120 BPM is 16000 frames at 8 kHz (440 cycles); at 90 BPM the span is
 * 21333 frames, the varispeed's 220 x 16000 / 21333 = 165 Hz. */

#define PK_SR 8000
#define PK_LEN 16000
#define PK_LEN90 21333

static float pk_take[PK_LEN];

static uint64_t pk_pitch(le_engine* e, int channel, int value) {
  uint64_t id = 0;
  CHECK(le_engine_set_pitch_mode(e, channel, value, &id) == LE_OK && id);
  return id;
}

/* `tracks` sines on a one-bar 120 BPM grid, following the tempo, playing. */
static le_engine* pk_fixture(int tracks) {
  for (int i = 0; i < PK_LEN; ++i) {
    pk_take[i] = 0.5f * (float)sin(2.0 * M_PI * 220.0 * i / PK_SR);
  }
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, PK_SR, 1, 1, 4 * PK_LEN) == LE_OK);
  for (int t = 0; t < tracks; ++t) {
    CHECK(le_engine_import_track(e, t, pk_take, PK_LEN) == LE_OK);
  }
  CHECK(le_engine_commit_session(e, PK_LEN, 1) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  drain(e);
  const uint64_t id = tf_follow(e, -1, 1);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  return e;
}

static int32_t pk_cents(le_engine* e, int ch) {
  le_track_snapshot s;
  le_engine_get_track(e, ch, &s);
  return s.pitch_effective_cents;
}

/* Plays (polling the cache, so the worker's render is collected) until track
 * ch's tempo pitch reads `cents`; the frames it took, or -1. */
static int pk_until(le_engine* e, int ch, int32_t cents, int max) {
  float out[256];
  le_lane_cache_info info;
  for (int at = 0; at < max; at += 256) {
    if (pk_cents(e, ch) == cents) return at;
    le_engine_get_transpose_cache(e, ch, &info);
    test_sleep_ms(1);
    tf_process(e, out, 256, 0.0f);
  }
  return pk_cents(e, ch) == cents ? max : -1;
}

static int pk_renders(le_engine* e, int ch) {
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, ch, &info);
  return info.renders;
}

/* Unchanged (the default): dry through the varispeed at 165 Hz, reported
 * -498 cents, until the stretch render lands; then 220 Hz, 0 cents, the lap
 * exactly the clock's (the output repeats every 21333 frames). */
static void test_pitch_unchanged_across_retime(void) {
  printf("test_pitch_unchanged_across_retime\n");
  static float out[4 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.pitch_follows_speed == 0 && s.tracks[0].pitch_override == -1);
  CHECK(pk_cents(e, 0) == 0);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 4096, 0.0f);
  CHECK(pk_cents(e, 0) == -498); /* the settle: still dry */
  CHECK(stretch_power_at(out, 0, 4096, 165.0, PK_SR) >
        100.0 * stretch_power_at(out, 0, 4096, 220.0, PK_SR));
  CHECK(pk_until(e, 0, 0, 40 * PK_LEN) >= 0);
  CHECK(pk_renders(e, 0) == 1);
  tf_process(e, out, 1024, 0.0f); /* past the swap window */
  tf_process(e, out, 2 * PK_LEN90 + 64, 0.0f);
  CHECK(stretch_power_at(out, 0, PK_LEN90, 220.0, PK_SR) >
        100.0 * stretch_power_at(out, 0, PK_LEN90, 165.0, PK_SR));
  int bad = 0;
  for (int i = 0; i < PK_LEN90 + 64; ++i) {
    bad += fabsf(out[i] - out[i + PK_LEN90]) > 1e-4f;
  }
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* Follows speed on one track: no render, the pitch stays the ratio's. The
 * default switched to Follows speed drops a sounding stretch render back to
 * the varispeed at once, and Unchanged again takes it back from the cache
 * without a second render. */
static void test_pitch_follows_speed_and_switch(void) {
  printf("test_pitch_follows_speed_and_switch\n");
  static float out[2 * PK_LEN90];
  le_engine* e = pk_fixture(2);
  CHECK(le_engine_play(e, 1) == LE_OK);
  uint64_t id = pk_pitch(e, 1, 1);
  drain(e);
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.pitch_override == 1);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  CHECK(pk_cents(e, 0) == -498 && pk_cents(e, 1) == -498);
  CHECK(pk_until(e, 0, 0, 40 * PK_LEN) >= 0); /* track 0 keeps its pitch */
  for (int k = 0; k < 40; ++k) {
    tf_process(e, out, 256, 0.0f);
    (void)pk_renders(e, 1);
    test_sleep_ms(1);
  }
  CHECK(pk_cents(e, 1) == -498 && pk_renders(e, 1) == 0);
  id = pk_pitch(e, -1, 1); /* everything follows speed now */
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_cents(e, 0) == -498);
  id = pk_pitch(e, -1, 0);
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_cents(e, 0) == 0); /* cache-hot */
  CHECK(pk_renders(e, 0) == 1);
  /* the setting validates its arguments */
  CHECK(le_engine_set_pitch_mode(e, -1, -1, &id) == LE_ERR_INVALID && id == 0);
  CHECK(le_engine_set_pitch_mode(e, 0, 2, &id) == LE_ERR_INVALID);
  CHECK(le_engine_set_pitch_mode(e, -2, 0, &id) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* A render within 0.5 % of the span serves it: 90 -> 90.3 BPM (21262
 * frames, 0.33 % off) keeps the render, the residual reported (+6 cents);
 * 95 BPM (20211 frames) is too far and renders again, dry meanwhile. */
static void test_pitch_tolerance(void) {
  printf("test_pitch_tolerance\n");
  static float out[1024];
  le_engine* e = pk_fixture(1);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  CHECK(pk_cents(e, 0) == -498);
  CHECK(pk_until(e, 0, 0, 40 * PK_LEN) >= 0);
  CHECK(pk_renders(e, 0) == 1);
  CHECK(le_engine_set_tempo(e, 90.3f) == LE_OK);
  tf_process(e, out, 1024, 0.0f);
  CHECK(pk_cents(e, 0) == 6);
  for (int k = 0; k < 40; ++k) {
    tf_process(e, out, 256, 0.0f);
    (void)pk_renders(e, 0);
    test_sleep_ms(1);
  }
  CHECK(pk_renders(e, 0) == 1 && pk_cents(e, 0) == 6);
  CHECK(le_engine_set_tempo(e, 95.0f) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  CHECK(pk_cents(e, 0) == -404); /* dry: 1200 log2(16000 / 20211) */
  CHECK(pk_until(e, 0, 0, 40 * PK_LEN) >= 0);
  CHECK(pk_renders(e, 0) == 2);
  le_engine_destroy(e);
}

/* 4a-ii M1: a retime inside the tolerance (120 -> 120.3 BPM, 15960 frames,
 * 0.25 % off) moves no source. A track at +5 st keeps sounding its plain
 * transpose render every block, and an untransposed follower stays on its
 * dry take; neither renders, the residual reported (+4 cents). */
static void test_pitch_small_retime_keeps_sources(void) {
  printf("test_pitch_small_retime_keeps_sources\n");
  static float out[256];
  le_engine* e = pk_fixture(2);
  CHECK(le_engine_play(e, 1) == LE_OK);
  uint64_t id = 0;
  CHECK(le_engine_install_transpose(e, 0, 5, &id) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  for (int k = 0; k < 4000; ++k) {
    le_engine_get_track(e, 0, &snap);
    if (snap.transpose_effective_st == 5) break;
    (void)pk_renders(e, 0);
    test_sleep_ms(1);
    tf_process(e, out, 256, 0.0f);
  }
  CHECK(snap.transpose_effective_st == 5 && pk_renders(e, 0) == 1);
  CHECK(le_engine_set_tempo(e, 120.3f) == LE_OK);
  int dropped = 0;
  for (int k = 0; k < 60; ++k) {
    tf_process(e, out, 256, 0.0f);
    le_engine_get_track(e, 0, &snap);
    dropped += snap.transpose_effective_st != 5;
    (void)pk_renders(e, 0);
    (void)pk_renders(e, 1);
    test_sleep_ms(1);
  }
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 15960);
  CHECK(dropped == 0);
  CHECK(pk_renders(e, 0) == 1 && pk_renders(e, 1) == 0);
  CHECK(pk_cents(e, 0) == 4 && pk_cents(e, 1) == 4);
  le_engine_destroy(e);
}

/* Transpose and the stretch are one render: +7 st kept across the retime
 * peaks at 220 x 2^(7/12) = 329.6 Hz. */
static void test_pitch_unchanged_with_transpose(void) {
  printf("test_pitch_unchanged_with_transpose\n");
  static float out[2 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  uint64_t id = 0;
  CHECK(le_engine_install_transpose(e, 0, 7, &id) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  CHECK(pk_cents(e, 0) == -498);
  CHECK(pk_until(e, 0, 0, 40 * PK_LEN) >= 0);
  tf_process(e, out, 1024, 0.0f);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.transpose_effective_st == 7);
  tf_process(e, out, PK_LEN90, 0.0f);
  const double want = 220.0 * pow(2.0, 7.0 / 12.0);
  CHECK(stretch_power_at(out, 0, PK_LEN90, want, PK_SR) >
        100.0 * stretch_power_at(out, 0, PK_LEN90, want * 0.75, PK_SR));
  CHECK(stretch_power_at(out, 0, PK_LEN90, want, PK_SR) >
        100.0 * stretch_power_at(out, 0, PK_LEN90, 220.0, PK_SR));
  le_engine_destroy(e);
}

/* The offline stem reproduces the live mix through the retime, the dry
 * pending stretch and the swap to the stretch render, from 329, 331 and
 * 328. */
static void test_pitch_render_parity(void) {
  printf("test_pitch_render_parity\n");
  le_engine* e = pk_fixture(1);
  const char* dir = render_test_dir("pitch-keep");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[8 * PK_LEN], replay[8 * PK_LEN];
  int at = 0;
  tf_process(e, live, 3000, 0.0f);
  at += 3000;
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, live + at, 64, 0.0f);
  at += 64;
  CHECK(pk_cents(e, 0) == -498);
  le_lane_cache_info info;
  for (int k = 0; k < 2000 && pk_cents(e, 0) != 0; ++k) {
    le_engine_get_transpose_cache(e, 0, &info);
    test_sleep_ms(1);
    tf_process(e, live + at, 256, 0.0f);
    at += 256;
  }
  CHECK(pk_cents(e, 0) == 0);
  tf_process(e, live + at, PK_LEN90, 0.0f);
  at += PK_LEN90;
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(at < 8 * PK_LEN);
  /* the tail sounds the take's own pitch: the stretch render played */
  CHECK(stretch_power_at(live, at - PK_LEN90, at, 220.0, PK_SR) >
        100.0 * stretch_power_at(live, at - PK_LEN90, at, 165.0, PK_SR));
  le_perf_log_entry fact;
  const int facts = speed_count_facts(dir, LE_PLOG_SOURCE_LEN, 0, &fact);
  CHECK(facts >= 1 && fact.cmd.lanei.value == PK_LEN90);
  static float pcm[PK_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, PK_LEN) == PK_LEN);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, PK_LEN, PK_SR);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 20000);
  const int frames = test_read_wet_stem(dir, 0, replay, 8 * PK_LEN);
  CHECK(frames == at);
  int bad = 0, first = -1;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) >= 2e-3f) {
      if (first < 0) first = i;
      ++bad;
    }
  }
  if (bad) printf("  %d mismatched from %d\n", bad, first);
  CHECK(bad == 0);
  le_engine_destroy(e);
}

static void run_pitch_keep_tests(void) {
  test_pitch_unchanged_across_retime();
  test_pitch_follows_speed_and_switch();
  test_pitch_tolerance();
  test_pitch_small_retime_keeps_sources();
  test_pitch_unchanged_with_transpose();
  test_pitch_render_parity();
}
