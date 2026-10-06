/* Foot Tuner mute (#1229 Part 4): literal monitor sums through the production
 * callback. Four inputs carry the constants 0.1, 0.2, 0.3 and 0.4 and every
 * monitor routes clean to output 0, so output 0 IS the sum of the inputs that
 * are heard and each claim below is a claim about which inputs were silenced. */
enum { TUNER_MUTE_N = 64 };

static le_engine* tuner_mute_fixture(void) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 4, 2, 48000) == LE_OK);
  for (int c = 0; c < 4; ++c) {
    CHECK(le_engine_set_monitor_input(e, c, 1) == LE_OK);
    CHECK(le_engine_set_monitor_input_output(e, c, 0x1) == LE_OK);
  }
  drain(e);
  return e;
}

/* Output 0 for one block of the four constants; asserts every frame agrees. */
static float tuner_mute_out0(le_engine* e) {
  float in[4 * TUNER_MUTE_N];
  float out[2 * TUNER_MUTE_N];
  for (int f = 0; f < TUNER_MUTE_N; ++f) {
    for (int c = 0; c < 4; ++c) in[f * 4 + c] = 0.1f * (float)(c + 1);
  }
  le_engine_process(e, out, in, TUNER_MUTE_N);
  for (int f = 1; f < TUNER_MUTE_N; ++f) {
    CHECK(fabsf(out[f * 2] - out[0]) < 1e-6f);
  }
  return out[0];
}

static uint32_t tuner_mute_mask_now(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  return s.tuner_mute_mask;
}

static void test_tuner_mute_literal(void) {
  printf("test_tuner_mute_literal\n");
  le_engine* e = tuner_mute_fixture();
  CHECK(fabsf(tuner_mute_out0(e) - 1.0f) < 1e-6f);
  CHECK(tuner_mute_mask_now(e) == 0u);

  /* Tune input 3 of a stereo pair 3+4 (inputs 2 and 3 here): both silent. */
  CHECK(le_engine_set_tuner_input(e, 2) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0xCu) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.3f) < 1e-6f);
  CHECK(tuner_mute_mask_now(e) == 0xCu);

  /* Bits for inputs the device lacks are dropped. */
  CHECK(le_engine_set_tuner_mute(e, 0xFFFFFFFFu) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e)) < 1e-6f);
  CHECK(tuner_mute_mask_now(e) == 0xFu);

  /* An empty mask restores every monitor. */
  CHECK(le_engine_set_tuner_mute(e, 0u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 1.0f) < 1e-6f);
  CHECK(tuner_mute_mask_now(e) == 0u);

  CHECK(le_engine_set_tuner_mute(NULL, 0x1u) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* The tuner mute and the player's persistent monitor mute are ORed; neither
 * changes the other. */
static void test_tuner_mute_keeps_monitor_mute(void) {
  printf("test_tuner_mute_keeps_monitor_mute\n");
  le_engine* e = tuner_mute_fixture();
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_tuner_input(e, 1) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x2u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.7f) < 1e-6f); /* 0.3 + 0.4 */

  /* Clearing the tuner mute leaves input 0's own mute in place. */
  CHECK(le_engine_set_tuner_mute(e, 0u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.9f) < 1e-6f); /* 0.2 + 0.3 + 0.4 */

  /* And the other way: a persistent mute set under the tuner mute survives
   * the tuner mute ending. */
  CHECK(le_engine_set_tuner_mute(e, 0x2u) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 1, 1) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.7f) < 1e-6f); /* 0.3 + 0.4 */
  CHECK(load_i32(&e->monitors[1].a_muted) == 1);
  CHECK(load_i32(&e->monitors[2].a_muted) == 0);
  le_engine_destroy(e);
}

/* The mask belongs to the tuner arm: refused while disarmed, and dropped by
 * every arm, move or disarm, so a tuning can never leave an input silent. */
static void test_tuner_mute_owned_by_arm(void) {
  printf("test_tuner_mute_owned_by_arm\n");
  le_engine* e = tuner_mute_fixture();

  /* Disarmed: refused. */
  CHECK(le_engine_set_tuner_mute(e, 0x1u) == LE_OK);
  drain(e);
  CHECK(tuner_mute_mask_now(e) == 0u);
  CHECK(fabsf(tuner_mute_out0(e) - 1.0f) < 1e-6f);

  /* Disarm clears it. */
  CHECK(le_engine_set_tuner_input(e, 0) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x1u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.9f) < 1e-6f);
  CHECK(le_engine_set_tuner_input(e, -1) == LE_OK);
  drain(e);
  CHECK(tuner_mute_mask_now(e) == 0u);
  CHECK(fabsf(tuner_mute_out0(e) - 1.0f) < 1e-6f);

  /* Moving to another input clears it; the caller re-sends it. */
  CHECK(le_engine_set_tuner_input(e, 2) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x4u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.7f) < 1e-6f);
  CHECK(le_engine_set_tuner_input(e, 3) == LE_OK);
  drain(e);
  CHECK(tuner_mute_mask_now(e) == 0u);
  CHECK(fabsf(tuner_mute_out0(e) - 1.0f) < 1e-6f);

  /* An out-of-range arm disarms, which clears it too. */
  CHECK(le_engine_set_tuner_mute(e, 0x8u) == LE_OK);
  drain(e);
  CHECK(fabsf(tuner_mute_out0(e) - 0.6f) < 1e-6f);
  CHECK(le_engine_set_tuner_input(e, 9) == LE_OK);
  drain(e);
  CHECK(tuner_mute_mask_now(e) == 0u);

  /* A reconfigure (and so a reopen) disarms the tuner and drops its mask
   * with it, as it resets every monitor; the repository re-arms and re-sends
   * both. */
  CHECK(le_engine_set_tuner_input(e, 1) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x2u) == LE_OK);
  drain(e);
  CHECK(tuner_mute_mask_now(e) == 0x2u);
  CHECK(le_engine_configure(e, 48000, 4, 2, 48000) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tuner_input == -1);
  CHECK(s.tuner_mute_mask == 0u);
  le_engine_destroy(e);
}

/* Only monitoring changes: the detector still hears the muted input and a
 * track records it sample for sample. */
static void test_tuner_mute_detector_and_capture_independent(void) {
  printf("test_tuner_mute_detector_and_capture_independent\n");
  enum { BLOCK = 256, REC = 4096 };
  le_engine* e = tuner_mute_fixture();
  CHECK(le_engine_set_lane_input(e, 0, 0, 2) == LE_OK);
  CHECK(le_engine_set_tuner_input(e, 2) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x4u) == LE_OK);
  drain(e);

  static float heard[REC];
  float in[4 * BLOCK];
  float out[2 * BLOCK];
  int phase = 0;
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int at = 0; at < REC; at += BLOCK) {
    for (int f = 0; f < BLOCK; ++f, ++phase) {
      const float x =
          0.5f * sinf(2.0f * LE_FFT_PI * 220.0f * (float)phase / 48000.0f);
      heard[at + f] = x;
      for (int c = 0; c < 4; ++c) in[f * 4 + c] = c == 2 ? x : 0.0f;
    }
    le_engine_process(e, out, in, BLOCK);
    /* Input 2 is the only signal and its monitor is muted: output 0 is
     * silent while the track captures it. */
    for (int f = 0; f < BLOCK; ++f) CHECK(fabsf(out[f * 2]) < 1e-6f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  static float pcm[REC];
  CHECK(le_engine_export_track(e, 0, pcm, REC) == REC);
  for (int i = 0; i < REC; ++i) CHECK(pcm[i] == heard[i]);

  /* Keep feeding the note until the detector has several full windows. */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  const int blocks = (LE_TUNER_WIN * LE_TUNER_DECIM * 3) / BLOCK;
  for (int b = 0; b < blocks; ++b) {
    for (int f = 0; f < BLOCK; ++f, ++phase) {
      const float x =
          0.5f * sinf(2.0f * LE_FFT_PI * 220.0f * (float)phase / 48000.0f);
      for (int c = 0; c < 4; ++c) in[f * 4 + c] = c == 2 ? x : 0.0f;
    }
    le_engine_process(e, out, in, BLOCK);
  }
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  printf("  muted input 2 220 Hz -> %.2f Hz conf=%.2f\n", s.tuner_hz,
         s.tuner_confidence);
  CHECK(s.tuner_input == 2);
  CHECK(s.tuner_mute_mask == 0x4u);
  CHECK(fabsf(s.tuner_hz - 220.0f) < 1.0f);
  CHECK(s.tuner_confidence >= 0.5f);
  le_engine_destroy(e);
}

/* The mask is not a musical record: a performance capture logs nothing for
 * it, and the muted input's monitor stem holds the silence that was heard. */
static void test_tuner_mute_not_logged(void) {
  printf("test_tuner_mute_not_logged\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  float in[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) in[i] = 1.0f;
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(le_engine_set_tuner_input(e, 0) == LE_OK);
  CHECK(le_engine_set_tuner_mute(e, 0x1u) == LE_OK);
  drain(e);

  float out[LOOP_N];
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f);
  float captured[2 * LOOP_N];
  CHECK(le_engine_perf_monitor_pop_for_test(e, 0, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(captured[i] == 0.0f);

  CHECK(le_engine_set_tuner_mute(e, 0u) == LE_OK);
  CHECK(le_engine_set_tuner_input(e, -1) == LE_OK);
  drain(e);
  CHECK(le_perf_disarm(e) == LE_OK);

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  static unsigned char buf[16384];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  const size_t count = log_entry_count(n);
  le_perf_log_entry entry;
  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_TUNER_MUTE, &entry) < 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_TUNER_INPUT, &entry) < 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_MUTE, &entry) <
        0);
  le_engine_destroy(e);
}

static void run_tuner_mute_tests(void) {
  test_tuner_mute_literal();
  test_tuner_mute_keeps_monitor_mute();
  test_tuner_mute_owned_by_arm();
  test_tuner_mute_detector_and_capture_independent();
  test_tuner_mute_not_logged();
}
