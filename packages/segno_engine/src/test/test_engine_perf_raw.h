/* #1805: a performance take records each captured input raw as well as
 * heard: its clean mono sample, before its monitor chain, gate, volume and
 * pan, every frame while armed, written as `input-raw-<n>-NNN.wav` (stream
 * LE_PERF_RAW_STREAM_BASE + n). Included by test_engine_core.c after the
 * perf reserve and autostop tests (shares their helpers). */

/* The raw ring holds the input as it arrived, whatever the monitor does to
 * it: at its volume and pan, muted, and switched off. An input that was
 * never monitored is recorded raw too, and not as heard. */
static void test_perf_raw_tap_is_the_clean_input(void) {
  printf("test_perf_raw_tap_is_the_clean_input\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  CHECK(le_engine_set_monitor_input_volume(e, 0, 0.5f) == LE_OK);
  CHECK(le_engine_set_monitor_input_pan(e, 0, -0.5f) == LE_OK);
  drain(e);
  CHECK(perf_arm_dir(e, perf_test_dir()) == LE_OK);
  drain(e);

  enum { N = 64 };
  for (int step = 0; step < 3; ++step) {
    if (step == 1) CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
    if (step == 2) CHECK(le_engine_set_monitor_input(e, 0, 0) == LE_OK);
    drain(e);
    /* drain() pumps blocks of its own: empty the rings of them. */
    float scratch[2 * 4096];
    while (le_engine_perf_raw_pop_for_test(e, 0, scratch, 4096) > 0) {
    }
    while (le_engine_perf_raw_pop_for_test(e, 1, scratch, 4096) > 0) {
    }
    while (le_engine_perf_monitor_pop_for_test(e, 0, scratch, 2048) > 0) {
    }
    float in[2 * N], out[2 * N];
    for (int i = 0; i < N; ++i) {
      in[2 * i] = perf_indexed_sample(step * N + i) - 0.25f;
      in[2 * i + 1] = 0.75f; /* input 1: never monitored */
    }
    le_engine_process(e, out, in, N);
    float raw[N];
    CHECK(le_engine_perf_raw_pop_for_test(e, 0, raw, N) == N);
    int exact = 1;
    for (int i = 0; i < N; ++i) exact &= raw[i] == in[2 * i];
    CHECK(exact);
    float heard[2 * N];
    CHECK(le_engine_perf_monitor_pop_for_test(e, 0, heard, N) == N);
    const float gl = load_f32(&e->monitors[0].a_pan_gl_bits);
    int as_heard = 1;
    for (int i = 0; i < N; ++i) {
      const float want = step == 0 ? in[2 * i] * 0.5f * gl : 0.0f;
      as_heard &= fabsf(heard[2 * i] - want) < 1e-6f;
    }
    CHECK(as_heard);
    float other[N];
    CHECK(le_engine_perf_raw_pop_for_test(e, 1, other, N) == N);
    int raw_other = 1;
    for (int i = 0; i < N; ++i) raw_other &= other[i] == 0.75f;
    CHECK(raw_other);
  }
  CHECK(e->perf.input_mask == UINT64_C(1));
  CHECK(e->perf_raw_mask == UINT64_C(3));
  float none[2 * N];
  CHECK(le_engine_perf_monitor_pop_for_test(e, 1, none, N) == 0);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_engine_destroy(e);
}

/* A full raw ring drops the frame and counts it like the other taps: the
 * master and as-heard rings are emptied, the raw one is not. */
static void test_perf_raw_ring_overflow_counts(void) {
  printf("test_perf_raw_ring_overflow_counts\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 4, 1, 1, 1000); /* tiny rate: 7 frames a ring */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  drain(e);
  CHECK(perf_arm_dir(e, perf_test_dir()) == LE_OK);
  drain(e);
  float scratch[64];
  while (le_engine_perf_master_pop_for_test(e, scratch, 32) > 0) {
  }
  while (le_engine_perf_monitor_pop_for_test(e, 0, scratch, 32) > 0) {
  }
  while (le_engine_perf_raw_pop_for_test(e, 0, scratch, 64) > 0) {
  }
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  const uint32_t before = s.perf_overruns;
  float in[7] = {0}, out[7];
  le_engine_process(e, out, in, 7);
  CHECK(le_engine_perf_master_pop_for_test(e, scratch, 32) == 7);
  CHECK(le_engine_perf_monitor_pop_for_test(e, 0, scratch, 32) == 7);
  le_engine_process(e, out, in, 7);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_overruns == before + 7); /* only the raw ring was full */
  CHECK(le_engine_perf_raw_pop_for_test(e, 0, scratch, 64) == 7);
  le_engine_destroy(e);
}

/* Pumps [frames] indexed input frames into a take at 48 kHz with input 0
 * captured, its monitor muted from the start (so the as-heard file is
 * silent), parts of [part_bytes]. */
static le_engine* perf_raw_take(uint64_t part_bytes, int frames) {
  perf_clear_test_dir();
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  drain(e);
  CHECK(perf_arm_target_for_test(e, perf_test_dir(), part_bytes, NULL, 0) ==
        LE_OK);
  drain(e);
  for (int base = 0; base < frames; base += 50) {
    float in[50], out[50];
    for (int i = 0; i < 50; ++i) in[i] = perf_indexed_sample(base + i);
    le_engine_process(e, out, in, 50);
  }
  CHECK(le_perf_disarm(e) == LE_OK);
  return e;
}

/* The drain writes the raw stream as mono float parts beside the as-heard
 * ones, rolling to a new part like any stream; the sidecar lists it under
 * `raw_inputs` and its parts as stream 100, and so does the checkpoint. */
static void test_perf_raw_drain_writes_mono_parts(void) {
  printf("test_perf_raw_drain_writes_mono_parts\n");
  /* 600 frames a raw part, 300 an as-heard one. */
  const uint64_t part_bytes = 84 + 600 * 4;
  le_engine* e = perf_raw_take(part_bytes, 1000);
  float expected[1000];
  for (int i = 0; i < 1000; ++i) expected[i] = perf_indexed_sample(i);
  CHECK(perf_part_holds("input-raw-0-001.wav", expected, 600, 1));
  CHECK(perf_part_holds("input-raw-0-002.wav", expected + 600, 400, 1));
  CHECK(perf_test_file_size("input-raw-0-003.wav") == -1);
  /* As heard: muted, so silence, in parts of 300 frames. */
  static const float zeros[2 * 300] = {0};
  CHECK(perf_part_holds("input-0-001.wav", zeros, 300, 2));
  CHECK(perf_part_holds("input-0-004.wav", zeros, 100, 2));

  char path[760];
  snprintf(path, sizeof(path), "%s/input-raw-0-002.wav", perf_test_dir());
  unsigned char header[84];
  CHECK(read_binary_file_for_test(path, header, 84) == 84);
  CHECK(header[22] == 1 && header[23] == 0);   /* mono */
  CHECK(header[60] == 100 && header[61] == 0); /* stream 100 + 0 */
  CHECK(header[62] == 2 && header[63] == 0);   /* part 2 */
  CHECK(le32_at(header + 80) == 400 * sizeof(float));

  CHECK(perf_sidecar_contains(
      "\"channel_layout\": {\"master_channels\": 1, \"captured_inputs\": [0], "
      "\"raw_inputs\": [0]},"));
  CHECK(perf_sidecar_contains("{\"stream\": 100, \"index\": 2, \"file\": "
                              "\"input-raw-0-002.wav\", \"frames\": 400, "
                              "\"bytes\": 1684,"));
  /* The streams in number order: master, the input as heard, then raw. */
  CHECK(perf_sidecar_contains("\"file\": \"input-0-004.wav\", \"frames\": 100, "
                              "\"bytes\": 884, \"overs\": 0, \"sha256\": "));
  {
    static char json[65536];
    snprintf(path, sizeof(path), "%s/performance.json", perf_test_dir());
    CHECK(read_file_for_test(path, json, sizeof(json)) > 0);
    const char* heard = strstr(json, "\"input-0-001.wav\"");
    const char* raw = strstr(json, "\"input-raw-0-001.wav\"");
    CHECK(heard != NULL && raw != NULL && heard < raw);
  }
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_zero_filled_frames == 0);
  le_engine_destroy(e);

  /* The final checkpoint names the raw stream, mono, with its parts. */
  static char slot[1 << 16];
  int found = 0;
  for (int k = 0; k < 2; ++k) {
    snprintf(path, sizeof(path), "%s/checkpoint-%c.json", perf_test_dir(),
             k == 0 ? 'a' : 'b');
    if (read_file_for_test(path, slot, sizeof(slot)) == 0) continue;
    found |= strstr(slot, "{\"stream\": 100, \"channels\": 1, \"parts\": [") !=
                 NULL &&
             strstr(slot, "\"input-raw-0-002.wav\"") != NULL;
  }
  CHECK(found);
}

/* Playing on an input whose monitor is muted keeps the take going: the raw
 * recording is what the player played (#1767's idle stop reads it too). */
static void test_perf_raw_input_counts_as_playing(void) {
  printf("test_perf_raw_input_counts_as_playing\n");
  le_engine* e = autostop_arm(1, 0);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  drain(e);
  autostop_pump(e, 0, 4 * 48000, autostop_playing);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(!perf_sidecar_contains("\"stopped_early\""));
  CHECK(autostop_reason(e) == LE_PERF_STOP_DISARM);
  le_engine_destroy(e);
}

/* A loopback channel (#1805 review) carries the device's own output: a
 * monitor left enabled on it (from before a reopen that marked it) is not
 * captured, raw or as heard, and the capture estimate leaves it out. */
static void test_perf_arm_skips_loopback_inputs(void) {
  printf("test_perf_arm_skips_loopback_inputs\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 1, 1000);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 1, 1) == LE_OK);
  drain(e);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_capture_streams == 3);     /* master, input 0 heard and raw */
  CHECK(s.perf_capture_frame_bytes == 16); /* 4 + 8 + 4 */
  CHECK(perf_arm_dir(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(e->perf.input_mask == UINT64_C(1));
  float scratch[64];
  CHECK(le_engine_perf_raw_pop_for_test(e, 1, scratch, 64) == 0);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_engine_destroy(e);
}
