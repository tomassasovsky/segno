/* Reverse (#1162): literal-PCM oracles through the production callback. Every
 * fixture imports a ramp (pcm[i] == i), so the dry output IS the read index
 * and a direction claim is a claim about which sample came out. */
static le_engine* reverse_fixture(int sr, int len, int base) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, 1, 1, 4000) == LE_OK);
  float pcm[2048];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  CHECK(le_engine_commit_session(e, base, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  return e;
}

static void rev_process(le_engine* e, float* out, int frames, int block) {
  float input[512] = {0};
  for (int at = 0; at < frames;) {
    int n = frames - at;
    if (n > block) n = block;
    le_engine_process(e, out + at, input, (uint32_t)n);
    at += n;
  }
}

/* The dry sample `k` frames after a turn whose continuous index was `cur`:
 * the new head steps in `reversed`, the old head keeps the other way, and
 * the two are mixed over `F` frames by the seam's equal-gain law. */
static double rev_expect(int reversed, int cur, int k, int len, int F) {
  int64_t nw = reversed ? cur - k : cur + k;
  int64_t old = reversed ? cur + k : cur - k;
  nw %= len; if (nw < 0) nw += len;
  old %= len; if (old < 0) old += len;
  if (F > 0 && k < F) {
    const double x = (double)k / F;
    return (double)nw * x + (double)old * (1 - x);
  }
  return (double)nw;
}

static void rev_check(const float* out, int frames, int reversed, int cur,
                      int len, int F) {
  for (int k = 0; k < frames; ++k) {
    CHECK(fabs(out[k] - rev_expect(reversed, cur, k, len, F)) < 2e-3);
  }
}

static int rev_mod(int v, int len) {
  v %= len;
  return v < 0 ? v + len : v;
}

static void test_reverse_turn_samples(void) {
  printf("test_reverse_turn_samples\n");
  const int rates[] = {44100, 48000}, blocks[] = {1, 127, 512}, len = 1000;
  for (int r = 0; r < 2; ++r) for (int b = 0; b < 3; ++b) {
    const int sr = rates[r], F = sr / 100, n = 2 * F + 100;
    le_engine* e = reverse_fixture(sr, len, len);
    float out[4096];
    rev_process(e, out, 37, blocks[b]);
    for (int i = 0; i < 37; ++i) CHECK(out[i] == (float)i);
    uint64_t id;
    CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK && id != 0);
    int32_t result;
    CHECK(le_engine_read_request_result(e, id, &result) == LE_ERR_NOT_READY);
    /* 37, 36, 35 ... through the turn window, then exact; wraps 0 -> 999. */
    rev_process(e, out, n, blocks[b]);
    rev_check(out, n, 1, 37, len, F);
    fade_result(e, id, LE_OK);
    le_track_snapshot snap;
    le_engine_get_track(e, 0, &snap);
    CHECK(snap.reversed == 1);
    CHECK(snap.position_frames == rev_mod(37 - (n - 1), len)); /* backward */
    /* Toggling back continues from the current index. */
    const int cur = rev_mod(37 - n, len);
    CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
    rev_process(e, out, n, blocks[b]);
    rev_check(out, n, 0, cur, len, F);
    fade_result(e, id, LE_OK);
    /* The phase offset persists: the track no longer reads the master phase. */
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].reversed == 0);
    CHECK(s.tracks[0].position_frames == 36);
    CHECK(s.master_position_frames == (37 + 2 * n) % len);
    /* ... until the transport hold re-locks it. */
    CHECK(le_engine_stop_track(e, 0) == LE_OK);
    rev_process(e, out, 8, blocks[b]);
    for (int i = 0; i < 8; ++i) CHECK(out[i] == 0);
    CHECK(le_engine_play(e, 0) == LE_OK);
    rev_process(e, out, 5, blocks[b]);
    for (int i = 0; i < 5; ++i) CHECK(out[i] == (float)i);
    le_engine_destroy(e);
  }
}

static void test_reverse_stopped_and_install(void) {
  printf("test_reverse_stopped_and_install\n");
  const int len = 1000, F = 480;
  le_engine* e = reverse_fixture(48000, len, len);
  float out[1024];
  rev_process(e, out, 37, 512);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  rev_process(e, out, 10, 512); /* held: the clock parks at 0 */
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 4, 512);
  for (int i = 0; i < 4; ++i) CHECK(out[i] == 0); /* stopped stays stopped */
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.reversed == 1 && snap.state == LE_TRACK_STOPPED);
  /* The held transport parks the origin every frame, so Play re-enters at
   * the reversed lap start, len - 1, with no turn: nothing sounded when the
   * direction flipped. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 5, 512);
  for (int i = 0; i < 5; ++i) CHECK(out[i] == (float)(999 - i));
  /* Installing the direction a track already has changes nothing. */
  CHECK(le_engine_install_reverse(e, 0, 1, &id) == LE_OK);
  rev_process(e, out, 3, 512);
  CHECK(out[0] == 994 && out[1] == 993 && out[2] == 992);
  fade_result(e, id, LE_OK);
  /* Installing the other direction turns like a toggle. */
  CHECK(le_engine_install_reverse(e, 0, 0, &id) == LE_OK);
  rev_process(e, out, 600, 512);
  rev_check(out, 600, 0, 991, len, F);
  fade_result(e, id, LE_OK);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.reversed == 0);
  le_engine_destroy(e);
}

static void test_reverse_multiple_segments(void) {
  printf("test_reverse_multiple_segments\n");
  const int len = 2000, F = 480;
  le_engine* e = reverse_fixture(48000, len, 1000); /* multiple 2 */
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.multiple == 2 && snap.length_frames == len);
  static float out[2048];
  rev_process(e, out, 1037, 512); /* into the second segment */
  for (int i = 0; i < 1037; ++i) CHECK(out[i] == (float)i);
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 1200, 512); /* mirrors across both segments */
  rev_check(out, 1200, 1, 1037, len, F);
  fade_result(e, id, LE_OK);
  le_engine_destroy(e);
}

static void test_reverse_sync_divisions(void) {
  printf("test_reverse_sync_divisions\n");
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
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2 && s.tracks[2].sync_divisor == 4);
  static float out[2048];
  /* Play from the held transport unparks every stopped track, so the mono
   * output is the sum of the three read indices: the primary's phase p, the
   * half division's p % 512 and the quarter's p % 256. */
  CHECK(le_engine_play(e, 1) == LE_OK);
  rev_process(e, out, 600, 512);
  for (int p = 0; p < 600; ++p) CHECK(out[p] == (float)(p + p % 512 + p % 256));
  /* Division 2 mirrors the folded phase; 512 is shorter than two turn
   * windows, so the turn snaps. */
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 1, &id) == LE_OK);
  rev_process(e, out, 1100, 512);
  for (int k = 0; k < 1100; ++k) {
    const int p = 600 + k;
    CHECK(out[k] == (float)(p % 1024 + p % 256) + (float)rev_expect(1, 600 % 512, k, 512, 0));
  }
  fade_result(e, id, LE_OK);
  /* With the origin parked by a hold, the reversed lap starts at len - 1 on
   * the primary's loop top and completes exactly two laps per primary cycle. */
  for (int t = 0; t < 3; ++t) CHECK(le_engine_stop_track(e, t) == LE_OK);
  rev_process(e, out, 4, 512);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 1024, 512);
  for (int p = 0; p < 1024; ++p) {
    CHECK(out[p] == (float)(p + 511 - p % 512 + p % 256));
  }
  /* Division 4, toggled while stopped and launched in the next block: it
   * re-enters at index 0 and runs back; the others keep their directions. */
  for (int t = 0; t < 3; ++t) CHECK(le_engine_stop_track(e, t) == LE_OK);
  rev_process(e, out, 4, 512);
  CHECK(le_engine_toggle_reverse(e, 2, &id) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_play(e, 2) == LE_OK);
  rev_process(e, out, 600, 512);
  for (int p = 0; p < 600; ++p) {
    CHECK(out[p] == (float)(p + 511 - p % 512 + (256 - p % 256) % 256));
  }
  le_engine_destroy(e);
}

static void test_reverse_free_mode_and_once(void) {
  printf("test_reverse_free_mode_and_once\n");
  const int len = 1000, F = 480;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1000];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_FREE);
  static float out[2048];
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 37, 512);
  for (int i = 0; i < 37; ++i) CHECK(out[i] == (float)i);
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 1100, 512); /* the private clock ticks on, the read runs back */
  rev_check(out, 1100, 1, 37, len, F);
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.position_frames == rev_mod(37 - 1099, len));
  /* Once finishes the current reversed pass (down to index 0) and stops;
   * the relaunch after the automatic end starts at the lap start, len - 1. */
  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);
  const int cur = rev_mod(37 - 1100, len);
  rev_process(e, out, cur + 1, 512);
  for (int k = 0; k <= cur; ++k) CHECK(out[k] == (float)(cur - k));
  rev_process(e, out, 10, 512);
  for (int i = 0; i < 10; ++i) CHECK(out[i] == 0);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED && snap.reversed == 1);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 5, 512);
  for (int i = 0; i < 5; ++i) CHECK(out[i] == (float)(999 - i));
  le_engine_destroy(e);
}

static void test_reverse_shared_once(void) {
  printf("test_reverse_shared_once\n");
  const int len = 1000, F = 480;
  le_engine* e = reverse_fixture(48000, len, len);
  static float out[2048];
  rev_process(e, out, 1037, 512); /* a whole lap has sounded */
  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 38, 512); /* 37 .. 0, mixing the turn */
  rev_check(out, 38, 1, 37, len, F);
  fade_result(e, id, LE_OK);
  rev_process(e, out, 10, 512); /* the next index would be 999: lap end */
  for (int i = 0; i < 10; ++i) CHECK(out[i] == 0);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 1000, 512); /* one reversed lap from len - 1 */
  for (int i = 0; i < 1000; ++i) CHECK(out[i] == (float)(999 - i));
  rev_process(e, out, 5, 512);
  for (int i = 0; i < 5; ++i) CHECK(out[i] == 0);
  le_engine_destroy(e);
}

static void test_reverse_two_lanes(void) {
  printf("test_reverse_two_lanes\n");
  const int len = 1000, F = 480;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1000];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  CHECK(le_engine_import_track_lane(e, 0, 1, pcm, len) == LE_OK);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  static float out[2048];
  rev_process(e, out, 37, 512);
  for (int i = 0; i < 37; ++i) CHECK(out[i] == (float)(2 * i));
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 1100, 512);
  for (int k = 0; k < 1100; ++k) {
    CHECK(fabs(out[k] - 2 * rev_expect(1, 37, k, len, F)) < 4e-3);
  }
  fade_result(e, id, LE_OK);
  le_engine_destroy(e);
}

static void test_reverse_fade_continues(void) {
  printf("test_reverse_fade_continues\n");
  const int len = 1000, F = 480, sr = 48000;
  le_engine* e = reverse_fixture(sr, len, len);
  static float out[2048];
  uint64_t fade_id, id;
  CHECK(le_engine_toggle_fade(e, 0, 0.5f, &fade_id) == LE_OK);
  rev_process(e, out, 100, 512);
  for (int j = 0; j < 100; ++j) {
    CHECK(fabs(out[j] - j * (1 - 2.0 * j / sr)) < 2e-2);
  }
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 900, 512);
  for (int k = 0; k < 900; ++k) {
    const double amount = 1 - 2.0 * (100 + k) / sr;
    CHECK(fabs(out[k] - rev_expect(1, 100, k, len, F) * amount) < 2e-2);
  }
  fade_result(e, id, LE_OK);
  le_engine_destroy(e);
}

static void test_reverse_refusals_and_record_guard(void) {
  printf("test_reverse_refusals_and_record_guard\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  float ramp[1000], pcm[1000], out[64];
  for (int i = 0; i < len; ++i) ramp[i] = (float)i;
  uint64_t id;
  int32_t result;
  CHECK(le_engine_toggle_reverse(NULL, 0, &id) == LE_ERR_INVALID);
  CHECK(le_engine_toggle_reverse(e, 0, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_toggle_reverse(e, -1, &id) == LE_ERR_INVALID && id == 0);
  CHECK(le_engine_toggle_reverse(e, 2, &id) == LE_ERR_INVALID); /* EMPTY */
  /* Install is admitted on an EMPTY track (Session recall installs before
   * the commit) and the callback refuses one that holds no material. */
  CHECK(le_engine_install_reverse(e, 2, 1, &id) == LE_OK);
  drain(e);
  fade_result(e, id, LE_ERR_INVALID);
  {
    le_engine* idle = le_engine_create();
    CHECK(le_engine_toggle_reverse(idle, 0, &id) == LE_ERR_NOT_RUNNING);
    le_engine_destroy(idle);
  }
  /* A punch-in on a reversed track is refused, playing or stopped, and the
   * press changes nothing. */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_record(e, 0) == LE_ERR_REVERSED);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_ERR_REVERSED);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING && snap.reversed == 1);
  /* The guard reads the direction the posted toggles predict. */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK); /* back to forward */
  CHECK(le_engine_record(e, 0) == LE_OK);              /* lands after it */
  drain(e);
  fade_result(e, id, LE_OK);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_OVERDUBBING && snap.reversed == 0);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_ERR_INVALID); /* writing */
  process_const(e, 0.0f, 64, out); /* the punch envelope rises */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out: the tail still writes */
  drain(e);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  process_const(e, 0.0f, 1, out);
  fade_result(e, id, LE_ERR_INVALID); /* refused by the callback: od_gain */
  for (int i = 0; i < 12; ++i) process_const(e, 0.0f, 64, out);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK); /* tail decayed */
  CHECK(le_engine_record(e, 0) == LE_ERR_REVERSED);    /* predicted reversed */
  drain(e);
  fade_result(e, id, LE_OK);
  /* The callback drops a punch-in that reaches it anyway (a raw post stands
   * in for an arm that fired after the toggle): no state change, no write. */
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  CHECK(le_push(e, LE_CMD_RECORD, 0, 0.0f) == LE_OK);
  process_const(e, 0.25f, 64, out);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING && snap.reversed == 1);
  CHECK(le_engine_export_track(e, 0, ramp, len) == len);
  for (int i = 0; i < len; ++i) CHECK(ramp[i] == pcm[i]);
  /* Toggle refused while RECORDING. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.state == LE_TRACK_RECORDING);
  CHECK(le_engine_toggle_reverse(e, 1, &id) == LE_ERR_INVALID && id == 0);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  /* Toggle waits while an arm is pending (it may fire into OVERDUBBING). */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK); /* forward again */
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(timing_gate(e, 1) == LE_OK);
  process_const(e, 0.0f, 1, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.pending == 1);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_ERR_NOT_READY && id == 0);
  CHECK(le_engine_cancel_arm(e, 0) == LE_OK);
  drain(e);
  CHECK(timing_gate(e, 0) == LE_OK);
  /* Unread receipts stay owned; a read frees the slot. */
  uint64_t ids[LE_RING_CAPACITY];
  for (int i = 0; i < (int)LE_RING_CAPACITY; ++i) {
    CHECK(le_engine_toggle_reverse(e, 0, &ids[i]) == LE_OK);
    drain(e);
  }
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_ERR_NOT_READY && id == 0);
  fade_result(e, ids[0], LE_OK);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  /* Configure retires every pending receipt. */
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  CHECK(le_engine_read_request_result(e, id, &result) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* Counts the LE_PLOG_REVERSE facts for `channel` in the capture's events.log
 * and returns the first one's payload through `first` (zeroed when absent). */
static int rev_log_facts(const char* dir, int32_t channel,
                         le_perf_log_entry* first, le_perf_log_entry* last) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[65536];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  uint32_t version;
  memcpy(&version, buf + 4, 4);
  CHECK(version == LE_TEST_EVENTS_VERSION);
  const size_t count = log_entry_count(n);
  memset(first, 0, sizeof(*first));
  memset(last, 0, sizeof(*last));
  int found = 0, from = 0;
  le_perf_log_entry entry;
  for (;;) {
    const int at = find_log_entry(buf, count, from, LE_PLOG_REVERSE, &entry);
    if (at < 0) break;
    from = at + 1;
    if (entry.cmd.reverse_log.channel != channel) continue;
    if (found == 0) *first = entry;
    *last = entry;
    found++;
  }
  return found;
}

static void rev_render_track_wav(le_engine* e, const char* dir, int len) {
  float pcm[1000];
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, len, 48000);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
}

/* A toggle back to the pre-turn direction inside the turn window cancels the
 * turn: the old head has kept reading, so it plays on alone, and the stem
 * reproduces it. */
static void test_reverse_rapid_double_toggles(void) {
  printf("test_reverse_rapid_double_toggles\n");
  const int len = 1000, F = 480;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("reverse-double");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[2048], replay[2048];
  uint64_t id, other;
  rev_process(e, live, 37, 512);
  /* Both in one drain: two receipts, direction unchanged, and the output is
   * the forward ramp with no burst from the reversed head. */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  CHECK(le_engine_toggle_reverse(e, 0, &other) == LE_OK && other > id);
  rev_process(e, live + 37, 600, 512);
  for (int k = 0; k < 600; ++k) CHECK(live[37 + k] == (float)(37 + k));
  fade_result(e, id, LE_OK);
  fade_result(e, other, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.reversed == 0);
  /* 100 frames into a turn: the mix so far, then the forward head alone,
   * which never stopped advancing. */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live + 637, 100, 512);
  rev_check(live + 637, 100, 1, 637, len, F);
  CHECK(le_engine_toggle_reverse(e, 0, &other) == LE_OK);
  rev_process(e, live + 737, 299, 512);
  for (int k = 0; k < 299; ++k) CHECK(live[737 + k] == (float)((737 + k) % len));
  fade_result(e, id, LE_OK);
  fade_result(e, other, LE_OK);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry first, last;
  CHECK(rev_log_facts(dir, 0, &first, &last) == 4);
  CHECK(last.cmd.reverse_log.reversed == 0);
  CHECK(last.cmd.reverse_log.read_index == 737);
  CHECK(last.cmd.reverse_log.turn_frames == 0);
  rev_render_track_wav(e, dir, len);
  const int frames = test_read_wet_stem(dir, 0, replay, 2048);
  CHECK(frames == 1036);
  for (int i = 0; i < frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 2e-3f);
  le_engine_destroy(e);
}

/* Stop inside the turn window, then Play: the hold parks the origin and the
 * turn together, so the relaunch starts clean at the reversed lap start. */
static void test_reverse_hold_settles_turn(void) {
  printf("test_reverse_hold_settles_turn\n");
  const int len = 1000, F = 480;
  le_engine* e = reverse_fixture(48000, len, len);
  float out[512];
  rev_process(e, out, 37, 512);
  uint64_t id;
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, out, 100, 512);
  rev_check(out, 100, 1, 37, len, F);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  rev_process(e, out, 8, 512);
  for (int i = 0; i < 8; ++i) CHECK(out[i] == 0);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 5, 512);
  for (int i = 0; i < 5; ++i) CHECK(out[i] == (float)(999 - i));
  le_engine_destroy(e);
}

/* A Session recall installs the direction on the imported EMPTY track before
 * the commit; the commit parks the origin, so a Play in the same drain starts
 * at the reversed lap start. */
static void test_reverse_commit_parks_install(void) {
  printf("test_reverse_commit_parks_install\n");
  const int len = 1000;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4000) == LE_OK);
  float pcm[1000], out[8];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  uint64_t id;
  CHECK(le_engine_install_reverse(e, 0, 1, &id) == LE_OK);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 5, 512);
  for (int i = 0; i < 5; ++i) CHECK(out[i] == (float)(999 - i));
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.reversed == 1 && snap.state == LE_TRACK_PLAYING);
  le_engine_destroy(e);
}

/* More direction facts than the renderer's segment table holds: the stem
 * fails cleanly, and the image is freed once, by the segment that loaded it. */
static void test_reverse_render_segment_overflow(void) {
  printf("test_reverse_render_segment_overflow\n");
  const int len = 1000, toggles = 4200;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("reverse-overflow");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  float out[8];
  for (int i = 0; i < toggles; ++i) {
    uint64_t id;
    CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
    rev_process(e, out, 1, 512);
    fade_result(e, id, LE_OK);
    /* Let the drain thread empty the log ring, so every fact reaches disk. */
    if (i % 256 == 255) test_sleep_ms(30);
  }
  CHECK(le_perf_disarm(e) == LE_OK);
  rev_render_track_wav(e, dir, len);
  int32_t done = 0, count = 0, channel = -1, succeeded = 1;
  CHECK(le_perf_render_poll(e, &done, NULL, &count) == LE_OK);
  CHECK(done == 1 && count == 1);
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(channel == 0 && succeeded == 0);
  le_engine_destroy(e);
}

static void test_reverse_material_resets(void) {
  printf("test_reverse_material_resets\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("reverse-resets");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  float out[64], pcm[1000];
  for (int i = 0; i < len; ++i) pcm[i] = (float)i;
  uint64_t id;
  le_track_snapshot snap;
  /* Clear. */
  process_const(e, 0.0f, 37, out);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.reversed == 1 && snap.position_frames == 36); /* the last read */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_EMPTY && snap.reversed == 0);
  /* A new capture reads forward and its direction is fresh. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int i = 0; i < 8; ++i) process_const(e, 0.25f, 64, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING && snap.reversed == 0);
  CHECK(snap.length_frames > 0);
  /* Undo to empty. */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  drain(e);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_EMPTY && snap.reversed == 0);
  /* Import resets the transforms of the imported track. */
  CHECK(le_engine_import_track(e, 1, pcm, len) == LE_OK);
  drain(e);
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.reversed == 0);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry first, last;
  const int facts = rev_log_facts(dir, 0, &first, &last);
  CHECK(facts == 5); /* toggle, clear, capture reset, toggle, undo-to-empty */
  CHECK(first.cmd.reverse_log.reversed == 1);
  CHECK(first.cmd.reverse_log.read_index == 37);
  CHECK(first.cmd.reverse_log.turn_frames == 480);
  CHECK(last.cmd.reverse_log.reversed == 0);
  CHECK(last.cmd.reverse_log.read_index == -1);
  CHECK(rev_log_facts(dir, 1, &first, &last) >= 1); /* the import's reset */
  CHECK(last.cmd.reverse_log.reversed == 0 && last.cmd.reverse_log.read_index == -1);
  le_engine_destroy(e);
}

static void test_reverse_cache_disengages(void) {
  printf("test_reverse_cache_disengages\n");
  le_engine *cached, *live;
  cache_pair_prepare(&cached, &live, LE_FX_DRIVE);
  pump_frames(cached, 0, CACHE_LOOP);
  pump_frames(live, 0, CACHE_LOOP);
  le_lane_cache_info info;
  le_engine_get_lane_cache(cached, 0, 0, &info);
  CHECK(info.engaged);
  uint64_t a, b;
  CHECK(le_engine_toggle_reverse(cached, 0, &a) == LE_OK);
  CHECK(le_engine_toggle_reverse(live, 0, &b) == LE_OK);
  static float oa[2 * CACHE_LOOP], ob[2 * CACHE_LOOP];
  pump_capture(cached, 0.0f, 2 * CACHE_LOOP, oa);
  pump_capture(live, 0.0f, 2 * CACHE_LOOP, ob);
  fade_result(cached, a, LE_OK);
  fade_result(live, b, LE_OK);
  /* The print disengaged at the toggle, the live chain re-entered through
   * the enable ramp, and nothing re-engaged across two more laps. */
  le_engine_get_lane_cache(cached, 0, 0, &info);
  CHECK(!info.engaged);
  CHECK(cache_max_diff(oa, ob, 2 * CACHE_LOOP, CACHE_RAMP_SKIP) < CACHE_TOL);
  /* Forward again: the print re-engages at the next lap start, in parity. */
  CHECK(le_engine_toggle_reverse(cached, 0, &a) == LE_OK);
  CHECK(le_engine_toggle_reverse(live, 0, &b) == LE_OK);
  pump_capture(cached, 0.0f, 2 * CACHE_LOOP, oa);
  pump_capture(live, 0.0f, 2 * CACHE_LOOP, ob);
  le_engine_get_lane_cache(cached, 0, 0, &info);
  CHECK(info.engaged);
  CHECK(cache_max_diff(oa, ob, 2 * CACHE_LOOP, CACHE_RAMP_SKIP) < CACHE_TOL);
  le_engine_destroy(cached);
  le_engine_destroy(live);
}

static void test_reverse_actual_arm_render(void) {
  printf("test_reverse_actual_arm_render\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("reverse-arm");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[2048], replay[2048];
  float pcm[1000];
  uint64_t id;
  rev_process(e, live, 128, 512);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live + 128, 640, 512); /* the whole turn and past it */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live + 768, 640, 512); /* the second turn completes */
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK); /* a third turn */
  rev_process(e, live + 1408, 512, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, len, 48000);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int frames = test_read_wet_stem(dir, 0, replay, 2048);
  CHECK(frames == 1920);
  CHECK(live[128] == 128 && live[129] != 127); /* the turn is in the live take */
  for (int i = 0; i < frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 2e-3f);
  le_perf_log_entry first, last;
  CHECK(rev_log_facts(dir, 0, &first, &last) == 3);
  CHECK(first.cmd.reverse_log.reversed == 1 && first.cmd.reverse_log.read_index == 128);
  CHECK(first.cmd.reverse_log.turn_frames == 480);
  CHECK(last.cmd.reverse_log.reversed == 1 && last.cmd.reverse_log.turn_frames == 480);
  le_engine_destroy(e);
}

/* A restored image (322) tracks its playback phase through 323 facts: with
 * the expected phase stepping in the track's direction, continuous reversed
 * playback logs none, and the renderer follows the image backward. */
static void test_reverse_restored_image_tracks_phase(void) {
  printf("test_reverse_restored_image_tracks_phase\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("reverse-restored");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[2048], replay[2048];
  float pcm[1000];
  uint64_t id;
  rev_process(e, live, 64, 512);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, live + 64, 64, 512);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* the staged image is the source */
  rev_process(e, live + 128, 128, 512);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live + 256, 768, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  for (int i = 64; i < 128; ++i) CHECK(live[i] == 0);
  /* The restore re-established the held grid, so the image plays from 0;
   * the toggle at index 128 turns it around. */
  CHECK(live[129] == 1 && live[256] == 128 && live[257] != 129);
  /* One 322 at the restore, and no 323 while the reversed read is continuous. */
  {
    char path[700];
    snprintf(path, sizeof(path), "%s/events.log", dir);
    static unsigned char buf[65536];
    const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
    const size_t count = log_entry_count(n);
    le_perf_log_entry entry;
    int applied = 0, transport = 0, from = 0, at;
    while ((at = find_log_entry(buf, count, from, LE_PLOG_SOURCE_APPLIED,
                                &entry)) >= 0) {
      from = at + 1;
      if (entry.cmd.restore_log.channel == 0) applied++;
    }
    from = 0;
    while ((at = find_log_entry(buf, count, from, LE_PLOG_SOURCE_TRANSPORT,
                                &entry)) >= 0) {
      from = at + 1;
      if (entry.cmd.restore_log.channel == 0) transport++;
    }
    CHECK(applied == 1);
    CHECK(transport == 0);
  }
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, len, 48000);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int frames = test_read_wet_stem(dir, 0, replay, 2048);
  CHECK(frames == 1024);
  for (int i = 0; i < frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 2e-3f);
  le_engine_destroy(e);
}

/* A track already reversed when the capture arms: the arm logs its direction
 * and index, so the stem reads backward from capture frame 0. */
static void test_reverse_render_armed_reversed(void) {
  printf("test_reverse_render_armed_reversed\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  static float live[1024], replay[1024];
  float pcm[1000];
  uint64_t id;
  rev_process(e, live, 300, 512);
  CHECK(le_engine_toggle_reverse(e, 0, &id) == LE_OK);
  rev_process(e, live, 600, 512); /* the turn is over before the arm */
  const char* dir = render_test_dir("reverse-armed");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  rev_process(e, live, 512, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(live[1] == live[0] - 1 || (live[0] == 0 && live[1] == 999));
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, len, 48000);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int frames = test_read_wet_stem(dir, 0, replay, 1024);
  CHECK(frames == 512);
  for (int i = 0; i < frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 2e-3f);
  le_perf_log_entry first, last;
  CHECK(rev_log_facts(dir, 0, &first, &last) == 1);
  CHECK(first.frame == 0 && first.cmd.reverse_log.reversed == 1);
  CHECK(first.cmd.reverse_log.read_index == (int32_t)live[0]);
  CHECK(first.cmd.reverse_log.turn_frames == 0);
  le_engine_destroy(e);
}

static void run_reverse_tests(void) {
  test_reverse_turn_samples();
  test_reverse_stopped_and_install();
  test_reverse_multiple_segments();
  test_reverse_sync_divisions();
  test_reverse_free_mode_and_once();
  test_reverse_shared_once();
  test_reverse_two_lanes();
  test_reverse_fade_continues();
  test_reverse_refusals_and_record_guard();
  test_reverse_rapid_double_toggles();
  test_reverse_hold_settles_turn();
  test_reverse_commit_parks_install();
  test_reverse_render_segment_overflow();
  test_reverse_material_resets();
  test_reverse_cache_disengages();
  test_reverse_actual_arm_render();
  test_reverse_restored_image_tracks_phase();
  test_reverse_render_armed_reversed();
}
