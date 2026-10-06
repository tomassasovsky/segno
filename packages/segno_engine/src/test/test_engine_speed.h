/* Speed (#1179 Part 2a): literal-PCM oracles through the production callback.
 * Every fixture imports a ramp (pcm[i] == i), so the dry output IS the read
 * index: a sample at index i + 0.5 reads i + 0.5, and a box of n reads the
 * mean of the n indices it covers. Reuses reverse_fixture / rev_process. */

/* The ramp read at a fractional index, interpolated with wrap. */
static double speed_ramp_at(double idx, int len) {
  const int i = (int)idx;
  const double f = idx - i;
  const int j = i + 1 == len ? 0 : i + 1;
  return i + f * (j - i);
}

/* The mean of the n ramp samples from index i, wrapped (the box oracle). */
static double speed_box_at(int i, int n, int len) {
  double sum = 0;
  for (int k = 0; k < n; ++k) sum += (i + k) % len;
  return sum / n;
}

static uint64_t speed_set(le_engine* e, int numer, int denom) {
  uint64_t id = 0;
  CHECK(le_engine_set_speed(e, numer, denom, &id) == LE_OK && id != 0);
  return id;
}

/* A fixture whose transport is held, so the origin is parked and the next
 * Play starts the head at index 0, with Speed already at numer/denom. */
static le_engine* speed_parked(int sr, int len, int base, int numer,
                               int denom) {
  le_engine* e = reverse_fixture(sr, len, base);
  float out[8];
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  rev_process(e, out, 4, 512);
  const uint64_t id = speed_set(e, numer, denom);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  return e;
}

/* Counts the facts of `code` for `channel` in the capture's events.log. */
static int speed_count_facts(const char* dir, int32_t code, int32_t channel,
                             le_perf_log_entry* first) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[262144];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  int found = 0, from = 0, at;
  le_perf_log_entry entry;
  while ((at = find_log_entry(buf, count, from, code, &entry)) >= 0) {
    from = at + 1;
    if (entry.cmd.arg_i != channel) continue; /* channel leads every payload */
    if (found++ == 0 && first) *first = entry;
  }
  return found;
}

/* E1: 1/2x over two song laps reads the whole take once — index k / 2, so
 * i on even frames and the interpolated i + 0.5 on odd ones — at three rates
 * and four block sizes. A wrapped song position would span half the take
 * and snap back to 0 at frame len. */
static void test_speed_half_whole_take(void) {
  printf("test_speed_half_whole_take\n");
  const int rates[] = {44100, 48000, 96000}, blocks[] = {1, 64, 127, 512};
  const int len = 1000, n = 2 * len + 10;
  static float out[2048];
  for (int r = 0; r < 3; ++r) for (int b = 0; b < 4; ++b) {
    le_engine* e = speed_parked(rates[r], len, len, 1, 2);
    rev_process(e, out, n, blocks[b]);
    for (int k = 0; k < n; ++k) {
      CHECK(fabs(out[k] - speed_ramp_at(0.5 * (k % (2 * len)), len)) < 2e-3);
    }
    CHECK(out[1] == 0.5f && out[1999] == 499.5f); /* i + 0.5; the wrap pair */
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    CHECK(s.speed_numer == 1 && s.speed_denom == 2);
    CHECK(s.tracks[0].head_rate_milli == 500);
    CHECK(s.tracks[0].position_frames == ((n - 1) % (2 * len)) / 2);
    le_engine_destroy(e);
  }
}

/* 2x, 4x and 8x visit r * k and read the box of the r samples skipped. */
static void test_speed_integer_rates_box(void) {
  printf("test_speed_integer_rates_box\n");
  const int len = 1000, rates[] = {2, 4, 8};
  static float out[2048];
  for (int r = 0; r < 3; ++r) {
    le_engine* e = speed_parked(48000, len, len, rates[r], 1);
    rev_process(e, out, 1500, 64);
    for (int k = 0; k < 1500; ++k) {
      CHECK(fabs(out[k] - speed_box_at((rates[r] * k) % len, rates[r], len)) < 2e-3);
    }
    le_engine_destroy(e);
  }
}

/* A step 1x -> 2x at index 37 is continuous: the new head reads 37, 39, 41
 * ... (boxes of two) while the old one keeps 37, 38, 39 ..., mixed by the
 * seam's equal-gain law over F = sr / 100 frames (snapped when the loop is
 * shorter than 2F). Normal afterwards continues from the index reached. */
static void test_speed_step_continuity(void) {
  printf("test_speed_step_continuity\n");
  const int rates[] = {44100, 48000, 96000}, blocks[] = {1, 64, 127, 512};
  const int len = 1000;
  static float out[2048];
  for (int r = 0; r < 3; ++r) for (int b = 0; b < 4; ++b) {
    const int sr = rates[r], F = len >= 2 * (sr / 100) ? sr / 100 : 0;
    const int n = 2 * (sr / 100) + 100;
    le_engine* e = reverse_fixture(sr, len, len);
    rev_process(e, out, 37, blocks[b]);
    uint64_t id = speed_set(e, 2, 1);
    rev_process(e, out, n, blocks[b]);
    for (int k = 0; k < n; ++k) {
      double want = speed_box_at((37 + 2 * k) % len, 2, len);
      if (k < F) {
        const double x = (double)k / F;
        want = want * x + ((37 + k) % len) * (1 - x);
      }
      CHECK(fabs(out[k] - want) < 2e-3);
    }
    fade_result(e, id, LE_OK);
    const int cur = (37 + 2 * n) % len;
    id = speed_set(e, 1, 1);
    rev_process(e, out, n, blocks[b]);
    for (int k = 0; k < n; ++k) {
      double want = (cur + k) % len;
      if (k < F) {
        const double x = (double)k / F;
        want = want * x + speed_box_at((cur + 2 * k) % len, 2, len) * (1 - x);
      }
      CHECK(fabs(out[k] - want) < 2e-3);
    }
    fade_result(e, id, LE_OK);
    le_engine_destroy(e);
  }
}

/* E6: a request for the factor already in force is receipt-only — no fact,
 * no turn, the mix untouched (an exact twin that never repeated it). */
static void test_speed_repeated_factor_receipt_only(void) {
  printf("test_speed_repeated_factor_receipt_only\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  le_engine* twin = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("speed-repeat");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float a[2048], b[2048];
  rev_process(e, a, 37, 64);
  rev_process(twin, b, 37, 64);
  uint64_t id = speed_set(e, 2, 1), tid = speed_set(twin, 2, 1);
  rev_process(e, a, 700, 64);
  rev_process(twin, b, 700, 64);
  fade_result(e, id, LE_OK);
  fade_result(twin, tid, LE_OK);
  id = speed_set(e, 2, 1); /* twice in one drain, then once more */
  const uint64_t again = speed_set(e, 2, 1);
  rev_process(e, a, 1200, 64);
  rev_process(twin, b, 1200, 64);
  fade_result(e, id, LE_OK);
  fade_result(e, again, LE_OK);
  for (int k = 0; k < 1200; ++k) CHECK(a[k] == b[k]);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry first;
  CHECK(speed_count_facts(dir, LE_PLOG_SPEED, 0, &first) == 1);
  CHECK(first.cmd.speed_log.numer == 2 && first.cmd.speed_log.denom == 1);
  CHECK(first.cmd.speed_log.index_lo == 0 && first.cmd.speed_log.index_hi == 37);
  CHECK(first.cmd.speed_log.turn_frames == 480);
  le_engine_destroy(e);
  le_engine_destroy(twin);
}

/* A multiple of 2 at 1/2x cycles both segments over four song laps, and Sync
 * divisions at 1/2x read their own length through the same unbounded
 * position: the mono output is the sum of the three read values. */
static void test_speed_multiples_and_divisions(void) {
  printf("test_speed_multiples_and_divisions\n");
  static float out[4096];
  {
    le_engine* e = speed_parked(48000, 2000, 1000, 1, 2); /* multiple 2 */
    rev_process(e, out, 4000, 512);
    for (int k = 0; k < 4000; ++k) {
      CHECK(fabs(out[k] - speed_ramp_at(0.5 * k, 2000)) < 2e-3);
    }
    le_engine_destroy(e);
  }
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1024];
  for (int i = 0; i < 1024; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, 1024) == LE_OK);
  CHECK(le_engine_import_track(e, 1, pcm, 512) == LE_OK);
  CHECK(le_engine_import_track(e, 2, pcm, 256) == LE_OK);
  CHECK(le_engine_commit_session(e, 1024, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  const int factors[][2] = {{1, 2}, {2, 1}};
  for (int f = 0; f < 2; ++f) {
    const uint64_t id = speed_set(e, factors[f][0], factors[f][1]);
    drain(e);
    fade_result(e, id, LE_OK);
    CHECK(le_engine_play(e, 0) == LE_OK); /* unparks all three */
    rev_process(e, out, 4096, 512);
    for (int p = 0; p < 4096; ++p) {
      double want = 0;
      const int lens[] = {1024, 512, 256};
      for (int t = 0; t < 3; ++t) {
        want += f == 0 ? speed_ramp_at(fmod(0.5 * p, lens[t]), lens[t])
                       : speed_box_at((2 * p) % lens[t], 2, lens[t]);
      }
      CHECK(fabs(out[p] - want) < 4e-3);
    }
    for (int t = 0; t < 3; ++t) CHECK(le_engine_stop_track(e, t) == LE_OK);
    rev_process(e, out, 4, 512);
  }
  le_engine_destroy(e);
}

/* Free mode reads its private clock through the head, and Once ends at the
 * head's lap wrap: at 1/2x a pass is two lengths of song frames, forward
 * from 0 and reversed from len - 1. */
static void test_speed_free_mode_and_once(void) {
  printf("test_speed_free_mode_and_once\n");
  const int len = 1000;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1000];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  const uint64_t id = speed_set(e, 1, 2);
  drain(e);
  fade_result(e, id, LE_OK);
  static float out[4096];
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 2 * len + 10, 512);
  for (int k = 0; k < 2 * len; ++k) {
    CHECK(fabs(out[k] - speed_ramp_at(0.5 * k, len)) < 2e-3);
  }
  for (int k = 2 * len; k < 2 * len + 10; ++k) CHECK(out[k] == 0);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED);
  uint64_t rid;
  CHECK(le_engine_toggle_reverse(e, 0, &rid) == LE_OK);
  drain(e);
  fade_result(e, rid, LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 2 * len + 10, 512);
  for (int k = 0; k < 2 * len - 1; ++k) {
    CHECK(fabs(out[k] - speed_ramp_at(fmod(len - 1 - 0.5 * k + len, len), len)) < 2e-3);
  }
  for (int k = 2 * len; k < 2 * len + 10; ++k) CHECK(out[k] == 0);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED && snap.reversed == 1);
  le_engine_destroy(e);
}

/* Capture never writes through a fractional head: record and punch-in are
 * refused with LE_ERR_TRANSFORMED (by the factor the posted requests
 * predict) and dropped on the callback; a change is refused while a track
 * records or is armed. */
static void test_speed_capture_guards(void) {
  printf("test_speed_capture_guards\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  float out[64], before[1000], after[1000];
  uint64_t id;
  CHECK(le_engine_set_speed(e, 3, 1, &id) == LE_ERR_INVALID && id == 0);
  CHECK(le_engine_set_speed(e, 1, 4, &id) == LE_ERR_INVALID);
  CHECK(le_engine_set_speed(NULL, 1, 1, &id) == LE_ERR_INVALID);
  {
    le_engine* idle = le_engine_create();
    CHECK(le_engine_set_speed(idle, 2, 1, &id) == LE_ERR_NOT_RUNNING);
    le_engine_destroy(idle);
  }
  id = speed_set(e, 2, 1);
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED); /* predicted 2x */
  CHECK(le_engine_record(e, 1) == LE_ERR_TRANSFORMED); /* a new take too */
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED);
  /* An arm that fires after the change is dropped by the callback. */
  CHECK(le_engine_export_track(e, 0, before, len) == len);
  CHECK(le_push(e, LE_CMD_RECORD, 0, 0.0f) == LE_OK);
  process_const(e, 0.25f, 64, out);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING);
  CHECK(le_engine_export_track(e, 0, after, len) == len);
  for (int i = 0; i < len; ++i) CHECK(after[i] == before[i]);
  /* Back to 1x in flight: the guard reads the predicted factor. */
  id = speed_set(e, 1, 1);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.state == LE_TRACK_RECORDING);
  CHECK(le_engine_set_speed(e, 2, 1, &id) == LE_ERR_NOT_READY && id == 0);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  /* Refused while an arm is pending. */
  CHECK(timing_gate(e, 1) == LE_OK);
  process_const(e, 0.0f, 1, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.pending == 1);
  CHECK(le_engine_set_speed(e, 2, 1, &id) == LE_ERR_NOT_READY && id == 0);
  CHECK(le_engine_cancel_arm(e, 0) == LE_OK);
  drain(e);
  CHECK(timing_gate(e, 0) == LE_OK);
  le_engine_destroy(e);
}

/* E2: provenance facts stay quiet under a non-identity head. A restored
 * image (322) is the source, and two laps at 1/2x then a lap at 8x log no
 * 323: the expected next phase follows the head's own index. */
static void test_speed_no_spurious_transport_facts(void) {
  printf("test_speed_no_spurious_transport_facts\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("speed-provenance");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float out[2048];
  rev_process(e, out, 64, 512);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, out, 64, 512);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  rev_process(e, out, 300, 512);
  uint64_t id = speed_set(e, 1, 2);
  for (int lap = 0; lap < 2; ++lap) rev_process(e, out, 2 * len, 512);
  fade_result(e, id, LE_OK);
  id = speed_set(e, 8, 1);
  rev_process(e, out, len, 512);
  fade_result(e, id, LE_OK);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(speed_count_facts(dir, LE_PLOG_SOURCE_APPLIED, 0, NULL) == 1);
  CHECK(speed_count_facts(dir, LE_PLOG_SOURCE_TRANSPORT, 0, NULL) == 0);
  CHECK(speed_count_facts(dir, LE_PLOG_SPEED, 0, NULL) == 2);
  le_engine_destroy(e);
}

/* E3: the offline stem reproduces the live mix sample-exactly through a 1/2x
 * step, a Reverse toggle at the fractional index 87.5 (its fact logs 87; the
 * renderer keeps its own exact half), a 1/2x -> 8x step (each with its turn)
 * and back to Normal, anchored from the logged Q32.32 index. */
static void test_speed_render_parity(void) {
  printf("test_speed_render_parity\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("speed-render");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[4400], replay[4400];
  uint64_t id;
  rev_process(e, live, 37, 512);
  id = speed_set(e, 1, 2);
  rev_process(e, live + 37, 2101, 512); /* 37 + 1050.5: index 87.5 */
  fade_result(e, id, LE_OK);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live + 2138, 600, 512);
  fade_result(e, id, LE_OK);
  id = speed_set(e, 8, 1);
  rev_process(e, live + 2738, 700, 512);
  fade_result(e, id, LE_OK);
  id = speed_set(e, 1, 1);
  rev_process(e, live + 3438, 700, 512);
  fade_result(e, id, LE_OK);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(live[38] != 38.0f && fabsf(live[2138] - 87.5f) < 1e-3f);
  rev_render_track_wav(e, dir, len);
  const int frames = test_read_wet_stem(dir, 0, replay, 4400);
  CHECK(frames == 4138);
  for (int i = 0; i < frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 2e-3f);
  le_engine_destroy(e);
}

/* A step disengages the Pre print and it never re-engages at 2x; inside the
 * step's turn window the print is retracted and freed (a chain edit) on the
 * cached twin, and the window keeps reading the lane's live material only —
 * ASAN-clean and in parity with the uncached twin. Normal re-engages. */
static void test_speed_print_and_turn_source(void) {
  printf("test_speed_print_and_turn_source\n");
  le_engine *cached, *live;
  cache_pair_prepare(&cached, &live, LE_FX_DRIVE);
  pump_frames(cached, 0, CACHE_LOOP);
  pump_frames(live, 0, CACHE_LOOP);
  CHECK(cache_engaged(cached, 0, 0) == 1);
  uint64_t a = speed_set(cached, 2, 1), b = speed_set(live, 2, 1);
  static float oa[2 * CACHE_LOOP], ob[2 * CACHE_LOOP];
  pump_capture(cached, 0.0f, 128, oa);
  pump_capture(live, 0.0f, 128, ob);
  CHECK(le_engine_set_lane_fx_param(cached, 0, 0, 0, 0, 0.3f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(live, 0, 0, 0, 0, 0.3f) == LE_OK);
  pump_capture(cached, 0.0f, 2 * CACHE_LOOP - 128, oa + 128);
  pump_capture(live, 0.0f, 2 * CACHE_LOOP - 128, ob + 128);
  fade_result(cached, a, LE_OK);
  fade_result(live, b, LE_OK);
  CHECK(cache_engaged(cached, 0, 0) == 0);
  CHECK(cache_max_diff(oa, ob, 2 * CACHE_LOOP, CACHE_RAMP_SKIP) < CACHE_TOL);
  /* The edited chain prints again (one tick registers its key, then the
   * settle window), and still never engages at 2x. */
  le_lane_cache_info info;
  le_engine_get_lane_cache(cached, 0, 0, &info);
  pump_frames(cached, 0, CACHE_SETTLE);
  CHECK(cache_wait_state(cached, 0, 0, LE_CACHE_CACHED, 3000));
  pump_frames(cached, 0, 2 * CACHE_LOOP);
  CHECK(cache_engaged(cached, 0, 0) == 0);
  a = speed_set(cached, 1, 1);
  pump_frames(cached, 0, 2 * CACHE_LOOP);
  fade_result(cached, a, LE_OK);
  CHECK(cache_engaged(cached, 0, 0) == 1); /* Normal: the next lap start */
  le_engine_destroy(cached);
  le_engine_destroy(live);
}

/* A Clear at 1/2x resets direction and origin with the material, logs the
 * reset, and the global rate survives: an undo brings the take back at 1/2x
 * from index 0 of the held transport. Two lanes read the same index. */
static void test_speed_material_reset_and_lanes(void) {
  printf("test_speed_material_reset_and_lanes\n");
  const int len = 1000;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1000];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  CHECK(le_engine_import_track_lane(e, 0, 1, pcm, len) == LE_OK);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  drain(e);
  const uint64_t id = speed_set(e, 1, 2);
  drain(e);
  fade_result(e, id, LE_OK);
  static float out[2048];
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 301, 512);
  for (int k = 0; k < 301; ++k) CHECK(fabs(out[k] - 2 * 0.5 * k) < 4e-3);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, out, 64, 512);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY && s.speed_numer == 1 &&
        s.speed_denom == 2 && s.tracks[0].head_rate_milli == 500);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 400, 512);
  for (int k = 0; k < 400; ++k) CHECK(fabs(out[k] - 2 * 0.5 * k) < 4e-3);
  le_engine_destroy(e);
}

static void run_speed_tests(void) {
  test_speed_half_whole_take();
  test_speed_integer_rates_box();
  test_speed_step_continuity();
  test_speed_repeated_factor_receipt_only();
  test_speed_multiples_and_divisions();
  test_speed_free_mode_and_once();
  test_speed_capture_guards();
  test_speed_no_spurious_transport_facts();
  test_speed_render_parity();
  test_speed_print_and_turn_source();
  test_speed_material_reset_and_lanes();
}
