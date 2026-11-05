/* Pitch across a retime (#1179 Part 4a-ii, #1675). A following track with
 * Pitch Unchanged keeps its pitch from the first frame of a tempo change: it
 * plays its take through the pitch bridge (engine_bridge.h, timing exact)
 * until the cache worker's stretch render to the new span lands, then
 * crossfades to it. Spectral oracles on a 220 Hz sine of a whole number of
 * cycles: one 4/4 bar at 120 BPM is 16000 frames at 8 kHz (440 cycles); at
 * 90 BPM the span is 21333 frames, the varispeed's 220 x 16000 / 21333 =
 * 165 Hz. */

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
  CHECK(le_engine_commit_session(e, PK_LEN, 4) == LE_OK);
  CHECK(le_engine_restore_tempo(e, 120.0f, LE_TEMPO_SOURCE_MANUAL) == LE_OK);
  drain(e);
  const uint64_t id = tf_follow(e, -1, 1);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  /* One lap from the top, so the Play's fade-in (#1400) is over. */
  static float lap[PK_LEN];
  rev_process(e, lap, PK_LEN, 512);
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

/* The length of the render track ch sounds (0: its take, or the bridge). */
static int32_t pk_sounding(le_engine* e, int ch) {
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, ch, &info);
  return info.entry_frames;
}

/* Plays (polling the cache) until track ch sounds a render of `out_len`
 * frames, appending to `out` from `*at` when given; the frames it took, or
 * -1. */
static int pk_until_render(le_engine* e, int ch, int32_t out_len, float* out,
                           int* at, int max) {
  static float scratch[256];
  for (int n = 0; n < max; n += 256) {
    if (pk_sounding(e, ch) == out_len) return n;
    test_sleep_ms(1);
    tf_process(e, out ? out + *at : scratch, 256, 0.0f);
    if (at) *at += 256;
  }
  return pk_sounding(e, ch) == out_len ? max : -1;
}

/* Whether every `win`-frame window of out[from, to) sounds `hz` at least
 * `ratio` times (in power) over `wrong`. */
static int pk_windows_at(const float* out, int from, int to, int win,
                         double hz, double wrong, double ratio) {
  int bad = 0;
  for (int i = from; i + win <= to; i += win) {
    bad += !(stretch_power_at(out, i, i + win, hz, PK_SR) >
             ratio * stretch_power_at(out, i, i + win, wrong, PK_SR));
  }
  return bad == 0;
}

/* Unchanged (the default) keeps 220 Hz from the change on (#1675): the
 * bridge plays the take at its own pitch through the settle and the render,
 * reported 0 cents, in every 512-frame window after the 10 ms swap (the
 * true pitch 15 dB over the varispeed's, which would be 20 dB under); then the
 * stretch render, the lap exactly the clock's (the output repeats every
 * 21333 frames). */
static void test_pitch_unchanged_across_retime(void) {
  printf("test_pitch_unchanged_across_retime\n");
  static float out[48 * PK_LEN];
  le_engine* e = pk_fixture(1);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.pitch_follows_speed == 0 && s.tracks[0].pitch_override == -1);
  CHECK(pk_cents(e, 0) == 0);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  int at = 0;
  tf_process(e, out, 4096, 0.0f);
  at += 4096;
  CHECK(pk_cents(e, 0) == 0);  /* the settle: the bridge keeps the pitch */
  CHECK(pk_sounding(e, 0) == 0); /* no render yet */
  CHECK(pk_until_render(e, 0, PK_LEN90, out, &at, 40 * PK_LEN) >= 0);
  CHECK(pk_renders(e, 0) == 1);
  /* every window from just past the swap to the render keeps the pitch */
  CHECK(at > 4096);
  CHECK(pk_windows_at(out, 128, at - 512, 512, 220.0, 165.0, 30.0));
  /* and the level: the bridge's grains sum to the take's */
  double sum = 0.0;
  for (int i = 128; i < at - 512; ++i) sum += (double)out[i] * out[i];
  const double rms = sqrt(sum / (double)(at - 640));
  CHECK(rms > 0.5 / sqrt(2.0) * 0.85 && rms < 0.5 / sqrt(2.0) * 1.15);
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
  CHECK(pk_cents(e, 0) == 0 && pk_cents(e, 1) == -498); /* 0 keeps its pitch */
  CHECK(pk_until_render(e, 0, PK_LEN90, NULL, NULL, 40 * PK_LEN) >= 0);
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
  CHECK(pk_cents(e, 0) == 0); /* bridged */
  CHECK(pk_until_render(e, 0, PK_LEN90, NULL, NULL, 40 * PK_LEN) >= 0);
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
  CHECK(pk_cents(e, 0) == 0 && pk_sounding(e, 0) == 0); /* bridged again */
  CHECK(pk_until_render(e, 0, 20211, NULL, NULL, 40 * PK_LEN) >= 0);
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
 * peaks at 220 x 2^(7/12) = 329.6 Hz, and so does the bridge before it,
 * over the track's plain +7 st render (#1675). */
static void test_pitch_unchanged_with_transpose(void) {
  printf("test_pitch_unchanged_with_transpose\n");
  static float out[2 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  uint64_t id = 0;
  CHECK(le_engine_install_transpose(e, 0, 7, &id) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  /* the plain render first, so the bridge has it */
  le_track_snapshot snap;
  for (int k = 0; k < 4000; ++k) {
    le_engine_get_track(e, 0, &snap);
    if (snap.transpose_effective_st == 7) break;
    (void)pk_renders(e, 0);
    test_sleep_ms(1);
    tf_process(e, out, 256, 0.0f);
  }
  CHECK(snap.transpose_effective_st == 7);
  const double want = 220.0 * pow(2.0, 7.0 / 12.0);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 2048, 0.0f);
  CHECK(pk_cents(e, 0) == 0);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.transpose_effective_st == 7); /* the bridge keeps it */
  CHECK(pk_windows_at(out, 128, 2048, 512, want, want * 0.75, 30.0));
  CHECK(pk_until_render(e, 0, PK_LEN90, NULL, NULL, 40 * PK_LEN) >= 0);
  tf_process(e, out, 1024, 0.0f);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.transpose_effective_st == 7);
  tf_process(e, out, PK_LEN90, 0.0f);
  CHECK(stretch_power_at(out, 0, PK_LEN90, want, PK_SR) >
        100.0 * stretch_power_at(out, 0, PK_LEN90, want * 0.75, PK_SR));
  CHECK(stretch_power_at(out, 0, PK_LEN90, want, PK_SR) >
        100.0 * stretch_power_at(out, 0, PK_LEN90, 220.0, PK_SR));
  le_engine_destroy(e);
}

/* The offline stem reproduces the live mix through the retime, the bridge
 * while the stretch is pending and the swap to the stretch render, from 329,
 * 331 (with its bridge flag) and 328. */
static void test_pitch_render_parity(void) {
  printf("test_pitch_render_parity\n");
  le_engine* e = pk_fixture(1);
  const char* dir = render_test_dir("pitch-keep");
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  static float live[8 * PK_LEN], replay[8 * PK_LEN];
  int at = 0;
  tf_process(e, live, 3000, 0.0f);
  at += 3000;
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, live + at, 64, 0.0f);
  at += 64;
  CHECK(pk_cents(e, 0) == 0 && pk_sounding(e, 0) == 0); /* bridged */
  /* A lap through the bridge with no cache poll (so no render can land),
   * across many grain edges and the loop point. */
  tf_process(e, live + at, PK_LEN90, 0.0f);
  at += PK_LEN90;
  CHECK(pk_sounding(e, 0) == 0);
  CHECK(pk_until_render(e, 0, PK_LEN90, live, &at,
                        8 * PK_LEN - 2 * PK_LEN90 - at) >= 0);
  tf_process(e, live + at, PK_LEN90, 0.0f);
  at += PK_LEN90;
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(at < 8 * PK_LEN);
  /* the tail sounds the take's own pitch: the stretch render played */
  CHECK(stretch_power_at(live, at - PK_LEN90, at, 220.0, PK_SR) >
        100.0 * stretch_power_at(live, at - PK_LEN90, at, 165.0, PK_SR));
  /* 331: the bridge first (the take, bridged), then the stretch render */
  le_perf_log_entry fact;
  const int facts = speed_count_facts(dir, LE_PLOG_SOURCE_LEN, 0, &fact);
  CHECK(facts >= 2 && fact.cmd.lanei.lane == 1 && fact.cmd.lanei.value == 0);
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


/* A rig whose stretch the cache cannot host (#1675): the render is refused
 * and the bridge keeps the pitch for as long as the tempo stays, reported 0
 * cents; Follows speed drops it to the varispeed and Unchanged brings it
 * back, each through the equal-power swap. */
static void test_pitch_bridge_when_refused(void) {
  printf("test_pitch_bridge_when_refused\n");
  static float out[4 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK); /* fits no render */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  for (int k = 0; k < 200; ++k) {
    tf_process(e, out, 256, 0.0f);
    (void)pk_renders(e, 0);
    test_sleep_ms(1);
  }
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.reason == LE_CACHE_REASON_BUDGET && info.renders == 0);
  CHECK(pk_cents(e, 0) == 0 && pk_sounding(e, 0) == 0);
  tf_process(e, out, 2 * PK_LEN90, 0.0f);
  CHECK(pk_windows_at(out, 0, 2 * PK_LEN90, 512, 220.0, 165.0, 30.0));
  uint64_t id = pk_pitch(e, -1, 1); /* Follows speed: the varispeed */
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_cents(e, 0) == -498);
  tf_process(e, out, PK_LEN90, 0.0f);
  CHECK(pk_windows_at(out, 128, PK_LEN90, 512, 165.0, 220.0, 30.0));
  id = pk_pitch(e, -1, 0); /* Unchanged: the bridge again */
  tf_process(e, out, 64, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_cents(e, 0) == 0);
  tf_process(e, out, PK_LEN90, 0.0f);
  CHECK(pk_windows_at(out, 128, PK_LEN90, 512, 220.0, 165.0, 30.0));
  le_engine_destroy(e);
}

/* The bridge is a function of the take, the head and the engine clock, so
 * the same change sounds the same at any block size (#1547's rule): blocks
 * of 32, 64 and 256 frames, the tempo set on a frame all three share, give
 * identical output over a lap and a half of bridge. */
static void test_pitch_bridge_block_invariance(void) {
  printf("test_pitch_bridge_block_invariance\n");
  static float ref[2 * PK_LEN90], got[2 * PK_LEN90];
  const int blocks[] = {64, 32, 256};
  const int n = PK_LEN90 + PK_LEN90 / 2;
  for (int b = 0; b < 3; ++b) {
    le_engine* e = pk_fixture(1);
    CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK); /* no render lands */
    float* out = b == 0 ? ref : got;
    CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
    rev_process(e, out, n, blocks[b]);
    if (b > 0) {
      int bad = 0;
      for (int i = 0; i < n; ++i) bad += got[i] != ref[i];
      CHECK(bad == 0);
    }
    le_engine_destroy(e);
  }
}

/* Speed keeps its coupled pitch through the bridge: at 2x a retime to 90
 * sounds 440 Hz (the Speed's octave) rather than the varispeed's
 * 2 x 165 = 330 Hz. */
static void test_pitch_bridge_with_speed(void) {
  printf("test_pitch_bridge_with_speed\n");
  static float out[2 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK);
  uint64_t id = 0;
  CHECK(le_engine_set_speed(e, 2, 1, &id) == LE_OK && id);
  tf_process(e, out, 1024, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, PK_LEN90, 0.0f);
  CHECK(pk_cents(e, 0) == 0);
  CHECK(pk_windows_at(out, 128, PK_LEN90, 512, 440.0, 330.0, 30.0));
  le_engine_destroy(e);
}

/* A bridged track keeps its pitch through a second retime (the span moves,
 * the snapshot follows) and a Stop (#1675 review): the Stop's fade reads the
 * grains on rather than dropping to the varispeed, so the fade has no step;
 * and the stem reproduces the retime. */
static void test_pitch_bridge_retime_and_stop(void) {
  printf("test_pitch_bridge_retime_and_stop\n");
  le_engine* e = pk_fixture(1);
  CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK); /* bridge for good */
  const char* dir = render_test_dir("pitch-bridge-stop");
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  static float live[8 * PK_LEN], replay[8 * PK_LEN];
  int at = 0;
  tf_process(e, live, 2000, 0.0f);
  at += 2000;
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, live + at, 6000, 0.0f);
  at += 6000;
  CHECK(le_engine_set_tempo(e, 80.0f) == LE_OK); /* still bridged */
  tf_process(e, live + at, 64, 0.0f);
  at += 64;
  CHECK(pk_cents(e, 0) == 0);
  tf_process(e, live + at, 8000, 0.0f);
  at += 8000;
  CHECK(pk_windows_at(live, at - 4096, at, 512, 220.0, 220.0 * 80 / 120,
                      30.0));
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  const int stop_at = at;
  tf_process(e, live + at, 2000, 0.0f);
  at += 2000;
  /* the fade-out continues the waveform: no step past a sine's own slope */
  const float slope = (float)(0.5 * 2.0 * M_PI * 220.0 / PK_SR);
  int steps = 0;
  for (int i = stop_at - 64; i < stop_at + 400; ++i) {
    steps += fabsf(live[i + 1] - live[i]) > 1.2f * slope;
  }
  CHECK(steps == 0);
  CHECK(le_perf_disarm(e) == LE_OK);
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
  /* Up to the Stop: the renderer's Stop fade on a retimed take differs from
   * the callback's with or without the bridge (a varispeed track shows the
   * same), a stem gap of its own. */
  int bad = 0, first = -1;
  for (int i = 0; i < stop_at; ++i) {
    if (fabsf(replay[i] - live[i]) >= 2e-3f) {
      if (first < 0) first = i;
      ++bad;
    }
  }
  if (bad) printf("  %d mismatched from %d\n", bad, first);
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* Reverse and Speed reach the next grain while bridged (#1675 review): the
 * pitch stays the take's through the toggle and the step (2x: its octave),
 * and nothing steps by more than the sine's own slope. */
static void test_pitch_bridge_reverse_and_speed(void) {
  printf("test_pitch_bridge_reverse_and_speed\n");
  static float out[3 * PK_LEN90];
  le_engine* e = pk_fixture(1);
  CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 4096, 0.0f);
  uint64_t id = 0;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK && id);
  tf_process(e, out, PK_LEN90, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_windows_at(out, 0, PK_LEN90, 512, 220.0, 165.0, 30.0));
  const float slope = (float)(0.5 * 2.0 * M_PI * 220.0 / PK_SR);
  int steps = 0;
  for (int i = 0; i + 1 < 2048; ++i) {
    steps += fabsf(out[i + 1] - out[i]) > 1.3f * slope;
  }
  CHECK(steps == 0); /* across the toggle and its first grains */
  CHECK(le_engine_set_speed(e, 2, 1, &id) == LE_OK && id);
  tf_process(e, out, PK_LEN90, 0.0f);
  fade_result(e, id, LE_OK);
  CHECK(pk_cents(e, 0) == 0);
  CHECK(pk_windows_at(out, 1024, PK_LEN90, 512, 440.0, 330.0, 30.0));
  le_engine_destroy(e);
}

/* The bridge's search on its own (#1675, after the owner heard the first
 * version as grainy on held notes), at the console's 48 kHz: the bridge run
 * over a 4 s take as the mixer runs it, a tempo change from 120 BPM to
 * `bpm` at a quarter of the lap. Fills out[0, frames) and, per hop, where
 * the grain started (starts[]) and where the head was (heads[]). */
#define PB_SR 48000
#define PB_LEN (4 * PB_SR)

static float pb_take[PB_LEN];

static int pb_run(double bpm, float* out, int frames, double* starts,
                  double* heads, int max_hops) {
  const int32_t play_len = (int32_t)(PB_LEN * 120.0 / bpm + 0.5);
  le_read_head h = {0, 0.0, (double)PB_LEN / (double)play_len};
  const int64_t pos0 = 3 * (int64_t)PB_LEN + PB_LEN / 4;
  h.origin = le_head_origin(&h, (double)(PB_LEN / 4), pos0, PB_LEN);
  const int32_t hop = le_bridge_hop(PB_SR);
  le_bridge b;
  memset(&b, 0, sizeof(b));
  int hops = 0;
  for (int i = 0; i < frames; ++i) {
    const int64_t pos = pos0 + i;
    const double index = le_head_index(&h, pos, PB_LEN);
    float x = 0.0f, y = 0.0f;
    le_bridge_frame(&b, 1, 0, pb_take, NULL, PB_LEN, &h, 1.0, index, pos,
                    (uint32_t)i, 0, hop, PB_SR, &x, &y);
    out[i] = x;
    if ((i & (hop - 1)) == 0 && hops < max_hops) {
      starts[hops] = b.cur;
      heads[hops] = index;
      ++hops;
    }
  }
  return hops;
}

/* x - y on the loop, nearest zero. */
static double pb_near(double x, double y) {
  double d = x - y;
  while (d > PB_LEN / 2) d -= PB_LEN;
  while (d < -PB_LEN / 2) d += PB_LEN;
  return d;
}

/* A small tempo change (120 -> 118 BPM: the head falls behind a grain by 34
 * frames a hop) needs no splice for many hops: each grain continues the one
 * before it, on whole samples, so the bridge plays the take itself. */
static void test_pitch_bridge_continues_the_take(void) {
  printf("test_pitch_bridge_continues_the_take\n");
  static const double notes[] = {130.8, 164.8, 196.0, 246.9, 293.7};
  for (int i = 0; i < PB_LEN; ++i) {
    double v = 0.0;
    for (int k = 0; k < 5; ++k) {
      for (int m = 1; m <= 6; ++m) {
        v += sin(2.0 * M_PI * notes[k] * m * i / PB_SR + 0.3 * m) / m;
      }
    }
    pb_take[i] = (float)(0.05 * v);
  }
  const int hop = le_bridge_hop(PB_SR);
  static float out[16 * 2048];
  double starts[16], heads[16];
  const int hops = pb_run(118.0, out, 16 * hop, starts, heads, 16);
  CHECK(hops == 16);
  for (int k = 1; k < hops; ++k) {
    CHECK(starts[k] == (double)(int64_t)starts[k]); /* whole samples */
    CHECK(fabs(pb_near(starts[k], starts[k - 1] + hop)) < 0.5);
  }
  /* from the second hop on, the take sample for sample */
  int bad = 0;
  for (int i = hop; i < 16 * hop; ++i) {
    const int64_t at = ((int64_t)starts[1] + (i - hop)) % PB_LEN;
    bad += fabsf(out[i] - pb_take[at]) > 1e-6f;
  }
  CHECK(bad == 0);
}

/* A low E on a bass (41.25 Hz, 24 ms a period) through a 120 -> 100 BPM
 * retime: the search reaches a whole period, so the note never beats. The
 * first version (+-10 ms) moved its level by 0.47 dB at its splices. */
static void test_pitch_bridge_holds_a_bass_note(void) {
  printf("test_pitch_bridge_holds_a_bass_note\n");
  for (int i = 0; i < PB_LEN; ++i) {
    double v = 0.0;
    for (int m = 1; m <= 30; ++m) {
      v += sin(2.0 * M_PI * 41.25 * m * i / PB_SR + 0.37 * m * m) / m;
    }
    pb_take[i] = (float)(0.2 * v);
  }
  static float out[3 * PB_SR];
  double starts[1], heads[1];
  pb_run(100.0, out, 3 * PB_SR, starts, heads, 0);
  /* 8 periods a window: a steady note reads the same in every one */
  const int win = 9309;
  double lo = 1e9, hi = -1e9;
  for (int i = 4096; i + win <= 3 * PB_SR; i += 1024) {
    double sum = 0.0;
    for (int j = 0; j < win; ++j) sum += (double)out[i + j] * out[i + j];
    const double db = 10.0 * log10(sum / win);
    if (db < lo) lo = db;
    if (db > hi) hi = db;
  }
  CHECK(hi - lo < 0.1);
}

/* Noise continues nowhere, so its grains keep within 10 ms of the head,
 * for the search and for how far a grain continues: drum hits stay on
 * time. */
static void test_pitch_bridge_keeps_noise_on_time(void) {
  printf("test_pitch_bridge_keeps_noise_on_time\n");
  uint32_t seed = 1675u;
  for (int i = 0; i < PB_LEN; ++i) {
    seed = seed * 1664525u + 1013904223u;
    pb_take[i] = (float)((int32_t)(seed >> 8) - (1 << 23)) / (float)(1 << 23);
  }
  static float out[3 * PB_SR];
  static double starts[80], heads[80];
  const int hops = pb_run(100.0, out, 3 * PB_SR, starts, heads, 80);
  CHECK(hops > 60);
  const double inner = PB_SR * 10 / 1000;
  int far = 0;
  for (int k = 1; k < hops; ++k) {
    far += fabs(pb_near(starts[k], heads[k])) > inner + 0.5;
  }
  CHECK(far == 0);
}

/* The renders of the tracks that sound are scheduled first: four stopped
 * tracks that also follow the tempo fill the four job slots after a retime,
 * and the playing track still gets one at the first tick that may start a
 * render. */
static void test_pitch_audible_render_first(void) {
  printf("test_pitch_audible_render_first\n");
  static float out[4096];
  le_engine* e = pk_fixture(5);
  for (int t = 1; t < 5; ++t) CHECK(le_engine_play(e, t) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  for (int t = 0; t < 4; ++t) CHECK(le_engine_stop_track(e, t) == LE_OK);
  static float laps[2 * PK_LEN];
  tf_process(e, laps, 2 * PK_LEN, 0.0f); /* the Stops' fades */
  le_track_snapshot snap;
  for (int t = 0; t < 5; ++t) {
    le_engine_get_track(e, t, &snap);
    if (snap.state != (t < 4 ? LE_TRACK_STOPPED : LE_TRACK_PLAYING)) {
      printf("  track %d state %d\n", t, snap.state);
    }
    CHECK(snap.state == (t < 4 ? LE_TRACK_STOPPED : LE_TRACK_PLAYING));
  }
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tf_process(e, out, 64, 0.0f);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 4, &info); /* the new key, settling */
  CHECK(info.state == LE_CACHE_LIVE);
  tf_process(e, out, PK_SR * (LE_CACHE_SOURCE_SETTLE_MS + 20) / 1000, 0.0f);
  le_engine_get_transpose_cache(e, 4, &info); /* one tick: the enqueue */
  CHECK(info.state == LE_CACHE_RENDERING);
  CHECK(pk_until_render(e, 4, PK_LEN90, NULL, NULL, 40 * PK_LEN) >= 0);
  le_engine_destroy(e);
}

static void run_pitch_keep_tests(void) {
  test_pitch_unchanged_across_retime();
  test_pitch_follows_speed_and_switch();
  test_pitch_tolerance();
  test_pitch_small_retime_keeps_sources();
  test_pitch_unchanged_with_transpose();
  test_pitch_render_parity();
  test_pitch_bridge_when_refused();
  test_pitch_bridge_block_invariance();
  test_pitch_bridge_with_speed();
  test_pitch_bridge_retime_and_stop();
  test_pitch_bridge_reverse_and_speed();
  test_pitch_bridge_continues_the_take();
  test_pitch_bridge_holds_a_bass_note();
  test_pitch_bridge_keeps_noise_on_time();
  test_pitch_audible_render_first();
}
