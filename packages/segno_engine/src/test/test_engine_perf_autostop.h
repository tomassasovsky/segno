/* #1767: a performance take stops on its own when nobody is playing (no
 * logged event and no captured input above LE_PERF_ACTIVITY_DBFS through
 * the sound trigger's high-pass for idle_stop_seconds), and at its longest
 * length (max_seconds), keeping everything recorded. Included by
 * test_engine_core.c after the perf reserve tests (shares their helpers). */

/* Arms a take at 48 kHz with input 0 monitored (so it is captured) and the
 * given idle stop and longest length, in seconds (0: none). */
static le_engine* autostop_arm(int32_t idle_seconds, int32_t max_seconds) {
  perf_clear_test_dir();
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);
  drain(e);
  le_perf_target target;
  memset(&target, 0, sizeof(target));
  target.capture_dir = perf_test_dir();
  for (int i = 0; i < 16; ++i) target.take_id[i] = (uint8_t)i;
  target.volume_generation = -1;
  target.reserve_bytes = UINT64_MAX;
  target.idle_stop_seconds = idle_seconds;
  target.max_seconds = max_seconds;
  CHECK(le_perf_arm(e, &target) == LE_OK);
  drain(e);
  return e;
}

typedef float (*autostop_signal)(uint64_t frame);

/* Pumps frames [from, to) of the input [signal] through [e] in 50-frame
 * blocks, as a device would. */
static void autostop_pump(le_engine* e, uint64_t from, uint64_t to,
                          autostop_signal signal) {
  float in[50], out[50];
  for (uint64_t f = from; f < to; f += 50) {
    for (int i = 0; i < 50; ++i) in[i] = signal(f + (uint64_t)i);
    le_engine_process(e, out, in, 50);
  }
}

static float autostop_silence(uint64_t frame) {
  (void)frame;
  return 0.0f;
}

/* A string held at -20 dBFS: 220 Hz. */
static float autostop_playing(uint64_t frame) {
  return 0.1f * sinf(6.2831853f * 220.0f * (float)frame / 48000.0f);
}

/* Notes 0.2 s long every 0.8 s, -20 dBFS, silence between. */
static float autostop_phrases(uint64_t frame) {
  return frame % 38400 < 9600 ? autostop_playing(frame) : 0.0f;
}

/* 50 Hz mains hum at -26 dBFS: under the floor once the trigger's 100 Hz
 * high-pass has taken it 24 dB down. */
static float autostop_hum(uint64_t frame) {
  return 0.05f * sinf(6.2831853f * 50.0f * (float)frame / 48000.0f);
}

static int32_t autostop_reason(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  return s.perf_stop_reason;
}

/* A second of nothing: the take ends a second after its last event (the
 * arm's own, at frame 0), everything up to there kept. */
static void test_perf_autostop_idle_take_stops(void) {
  printf("test_perf_autostop_idle_take_stops\n");
  le_engine* e = autostop_arm(1, 0);
  autostop_pump(e, 0, 3 * 48000, autostop_silence);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(perf_sidecar_contains("\"stopped_early\": \"idle\""));
  CHECK(perf_sidecar_contains("\"capture_frames\": 48000,"));
  CHECK(perf_test_file_size("master-001.wav") == 84 + 48000 * 4);
  CHECK(perf_test_file_size("input-0-001.wav") == 84 + 48000 * 8);
  CHECK(autostop_reason(e) == LE_PERF_STOP_IDLE);
  le_engine_destroy(e);
}

/* Steady playing is never stopped: held notes, and phrases with rests
 * shorter than the idle period. */
static void test_perf_autostop_playing_never_stops(void) {
  printf("test_perf_autostop_playing_never_stops\n");
  const autostop_signal signals[] = {autostop_playing, autostop_phrases};
  for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
    le_engine* e = autostop_arm(1, 0);
    autostop_pump(e, 0, 4 * 48000, signals[i]);
    CHECK(le_perf_disarm(e) == LE_OK);
    CHECK(!perf_sidecar_contains("\"stopped_early\""));
    CHECK(perf_sidecar_contains("\"capture_frames\": 192000,"));
    CHECK(autostop_reason(e) == LE_PERF_STOP_DISARM);
    le_engine_destroy(e);
  }
}

/* Hum on an input with nobody playing is not playing. */
static void test_perf_autostop_hum_does_not_count(void) {
  printf("test_perf_autostop_hum_does_not_count\n");
  le_engine* e = autostop_arm(1, 0);
  autostop_pump(e, 0, 3 * 48000, autostop_hum);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(perf_sidecar_contains("\"stopped_early\": \"idle\""));
  CHECK(perf_sidecar_contains("\"capture_frames\": 48000,"));
  le_engine_destroy(e);
}

/* A logged event (a volume change) is something happening: the idle period
 * starts over from its frame. */
static void test_perf_autostop_event_restarts_the_period(void) {
  printf("test_perf_autostop_event_restarts_the_period\n");
  le_engine* e = autostop_arm(1, 0);
  autostop_pump(e, 0, 40000, autostop_silence);
  CHECK(le_engine_set_track_volume(e, 0, 0.5f) == LE_OK);
  autostop_pump(e, 40000, 4 * 48000, autostop_silence);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(perf_sidecar_contains("\"stopped_early\": \"idle\""));
  /* Applied in the block after the call, logged at its first frame. */
  CHECK(perf_sidecar_contains("\"capture_frames\": 88000,"));
  CHECK(autostop_reason(e) == LE_PERF_STOP_IDLE);
  le_engine_destroy(e);
}

/* The longest take ends there however much is played. */
static void test_perf_autostop_length_limit(void) {
  printf("test_perf_autostop_length_limit\n");
  le_engine* e = autostop_arm(0, 1);
  autostop_pump(e, 0, 2 * 48000, autostop_playing);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(perf_sidecar_contains("\"stopped_early\": \"length_limit\""));
  CHECK(perf_sidecar_contains("\"capture_frames\": 48000,"));
  CHECK(perf_test_file_size("input-0-001.wav") == 84 + 48000 * 8);
  CHECK(autostop_reason(e) == LE_PERF_STOP_LENGTH_LIMIT);
  le_engine_destroy(e);
}

/* Arms after a 0.1 s loop is recorded on track 0 and left playing (with
 * [overdub], left overdubbing): the engine logs a musical-time anchor at
 * every loop top and, overdubbing, a retired layer every pass, with nobody
 * there. Those are not someone playing. */
static void autostop_unattended_loop(int overdub) {
  perf_clear_test_dir();
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);
  drain(e);
  float out[64];
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int i = 0; i < 4800 / 50; ++i) process_const(e, 0.2f, 50, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize: the loop plays */
  drain(e);
  if (overdub) {
    CHECK(le_engine_record(e, 0) == LE_OK); /* start overdub */
    drain(e);
  }
  le_perf_target target;
  memset(&target, 0, sizeof(target));
  target.capture_dir = perf_test_dir();
  for (int i = 0; i < 16; ++i) target.take_id[i] = (uint8_t)i;
  target.volume_generation = -1;
  target.reserve_bytes = UINT64_MAX;
  target.idle_stop_seconds = 1;
  CHECK(le_perf_arm(e, &target) == LE_OK);
  drain(e);
  autostop_pump(e, 0, 3 * 48000, autostop_silence);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(perf_sidecar_contains("\"stopped_early\": \"idle\""));
  CHECK(perf_sidecar_contains("\"capture_frames\": 48000,"));
  CHECK(perf_test_file_size("events.log") > 12 + 28 * 10); /* it logged */
  le_engine_destroy(e);
}

static void test_perf_autostop_unattended_loop_stops(void) {
  printf("test_perf_autostop_unattended_loop_stops\n");
  autostop_unattended_loop(0);
  autostop_unattended_loop(1);
}

/* A negative idle period or longest length is refused, not read as none. */
static void test_perf_autostop_refuses_negative_times(void) {
  printf("test_perf_autostop_refuses_negative_times\n");
  perf_clear_test_dir();
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  for (int which = 0; which < 2; ++which) {
    le_perf_target target;
    memset(&target, 0, sizeof(target));
    target.capture_dir = perf_test_dir();
    target.volume_generation = -1;
    target.reserve_bytes = UINT64_MAX;
    target.idle_stop_seconds = which == 0 ? -1 : 0;
    target.max_seconds = which == 1 ? -1 : 0;
    CHECK(le_perf_arm(e, &target) == LE_ERR_INVALID);
  }
  le_engine_destroy(e);
}

/* Playing the console hears only through the interface (its monitor muted,
 * the player on the interface's direct monitoring) is still playing: the
 * device's own input level counts, before any fader (#1767). Pumped in
 * steps the drain thread runs between, since it reads the meters live. */
static void test_perf_autostop_muted_monitor_still_playing(void) {
  printf("test_perf_autostop_muted_monitor_still_playing\n");
  le_engine* e = autostop_arm(2, 0);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  drain(e);
  for (uint64_t f = 0; f < 4 * 48000; f += 12000) {
    autostop_pump(e, f, f + 12000, autostop_playing);
    test_sleep_ms(300); /* a drain cycle */
  }
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(!perf_sidecar_contains("\"stopped_early\""));
  CHECK(perf_sidecar_contains("\"capture_frames\": 192000,"));
  le_engine_destroy(e);
}

/* A take that stops for idle or at its longest length logs nothing past the
 * frame it ends at (#1549), whatever the engine logged after it before the
 * drain ran: here a loop's tempo anchors at every loop top. */
static void test_perf_autostop_log_ends_with_the_take(void) {
  printf("test_perf_autostop_log_ends_with_the_take\n");
  autostop_unattended_loop(0);
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f == NULL) return;
  unsigned char header[12];
  CHECK(fread(header, 1, sizeof(header), f) == sizeof(header));
  unsigned char entry[28];
  int count = 0;
  while (fread(entry, 1, sizeof(entry), f) == sizeof(entry)) {
    uint64_t frame;
    memcpy(&frame, entry, 8);
    CHECK(frame <= 48000);
    ++count;
  }
  fclose(f);
  CHECK(count > 0);
}
