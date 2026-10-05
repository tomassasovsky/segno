/* Literal PCM oracles through the production callback and checked producers. */
static le_engine* fade_fixture(int sr) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, 1, 1, 1000) == LE_OK);
  float pcm[128];
  for (int i = 0; i < 128; ++i) pcm[i] = 0.5f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  drain(e);
  return e;
}

static void fade_process(le_engine* e, int frames, int block,
                         double start, double slope, float gain) {
  float input[512] = {0}, output[512];
  for (int at = 0; at < frames;) {
    int n = frames - at;
    if (n > block) n = block;
    le_engine_process(e, output, input, n);
    for (int i = 0; i < n; ++i) {
      double amount = start + slope * (at + i);
      if (amount < 0) amount = 0;
      if (amount > 1) amount = 1;
      CHECK(fabs(output[i] - gain * amount) < 2e-6);
    }
    at += n;
  }
}

static void fade_result(le_engine* e, uint64_t id, int expected) {
  int32_t result = 123;
  CHECK(le_engine_read_fade_result(e, id, &result) == LE_OK);
  CHECK(result == expected);
  CHECK(le_engine_read_fade_result(e, id, &result) == LE_ERR_INVALID);
}

static void test_fade_samples(void) {
  printf("test_fade_samples\n");
  const int rates[] = {44100, 48000}, blocks[] = {1, 127, 512};
  for (int r = 0; r < 2; ++r) for (int b = 0; b < 3; ++b) {
    int sr = rates[r];
    le_engine* e = fade_fixture(sr);
    uint64_t id;
    CHECK(le_engine_toggle_fade(e, 0, 0.5f, &id) == LE_OK);
    int32_t result;
    CHECK(le_engine_read_fade_result(e, id, &result) == LE_ERR_NOT_READY);
    fade_process(e, sr / 2 + 2, blocks[b], 1, -2.0 / sr, 0.5f);
    fade_result(e, id, LE_OK);
    le_track_snapshot snap;
    le_engine_get_track(e, 0, &snap);
    CHECK(snap.fade.amount == 0 && snap.fade.target == 0);
    CHECK(snap.volume == 1);
    CHECK(le_engine_toggle_fade(e, 0, 0.5f, &id) == LE_OK);
    fade_process(e, sr / 2 + 2, blocks[b], 0, 2.0 / sr, 0.5f);
    fade_result(e, id, LE_OK);
    float original[128];
    CHECK(le_engine_export_track(e, 0, original, 128) == 128);
    for (int i = 0; i < 128; ++i) CHECK(original[i] == 0.5f);
    le_engine_destroy(e);
  }
}

static void test_fade_retrigger_and_stopped(void) {
  printf("test_fade_retrigger_and_stopped\n");
  le_engine* e = fade_fixture(48000);
  uint64_t a, b;
  CHECK(le_engine_toggle_fade(e, 0, 0.5f, &a) == LE_OK);
  fade_process(e, 12000, 127, 1, -1.0 / 24000, 0.5f);
  fade_result(e, a, LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, 1, &a) == LE_OK);
  fade_process(e, 24002, 512, 0.5, 1.0 / 48000, 0.5f);
  fade_result(e, a, LE_OK);
  // Both resolve from callback target; stale UI amount/target is irrelevant.
  CHECK(le_engine_toggle_fade(e, 0, 0.5f, &a) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, 2, &b) == LE_OK);
  fade_process(e, 256, 127, 1, 0, 0.5f);
  fade_result(e, a, LE_OK); fade_result(e, b, LE_OK);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, 0.5f, &a) == LE_OK);
  fade_process(e, 24001, 512, 0, 0, 0);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED && snap.fade.amount == 0);
  CHECK(le_engine_play(e, 0) == LE_OK);
  fade_process(e, 256, 127, 0, 0, 0);
  fade_result(e, a, LE_OK);
  le_engine_destroy(e);
}

static void test_fade_images_and_receipts(void) {
  printf("test_fade_images_and_receipts\n");
  le_engine* e = fade_fixture(48000);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  le_fade_image image = snap.fade;
  image.amount = image.target = 0.25f;
  uint64_t a, b;
  CHECK(le_engine_install_fade(e, 0, &image, &a) == LE_OK);
  fade_process(e, 1, 1, 0.25, 0, 0.5f); // first audible frame is complete image
  fade_result(e, a, LE_OK);
  image.amount = NAN;
  CHECK(le_engine_install_fade(e, 0, &image, &a) == LE_ERR_INVALID && a == 0);
  CHECK(le_engine_toggle_fade(e, 0, INFINITY, &a) == LE_ERR_INVALID);
  CHECK(le_engine_toggle_fade(e, 0, 0.49f, &a) == LE_ERR_INVALID);
  fade_process(e, 1, 1, 0.25, 0, 0.5f);
  CHECK(le_engine_toggle_fade(e, 1, 1, &a) == LE_OK);
  drain(e); fade_result(e, a, LE_ERR_INVALID); // independent empty track refused
  image = snap.fade;
  CHECK(le_engine_clear(e, 0) == LE_OK);
  CHECK(le_engine_install_fade(e, 0, &image, &a) == LE_OK);
  drain(e); fade_result(e, a, LE_ERR_INVALID);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.fade.amount == 1 && snap.fade.target == 1);
  CHECK(snap.fade.generation != image.generation);
  // All receipt slots remain owned even after commands leave the ring.
  uint64_t ids[LE_RING_CAPACITY];
  for (int i = 0; i < LE_RING_CAPACITY; ++i) {
    CHECK(le_engine_toggle_fade(e, 0, 1, &ids[i]) == LE_OK);
    drain(e);
  }
  CHECK(le_engine_toggle_fade(e, 0, 1, &a) == LE_ERR_NOT_READY && a == 0);
  fade_result(e, ids[0], LE_ERR_INVALID);
  CHECK(le_engine_toggle_fade(e, 0, 1, &b) == LE_OK);
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  int32_t result;
  CHECK(le_engine_read_fade_result(e, b, &result) == LE_ERR_INVALID);
  CHECK(le_engine_install_fade(e, 0, &image, &a) == LE_ERR_INVALID);
  CHECK(le_engine_toggle_fade(e, 0, 1, &a) == LE_OK && a > b);
  drain(e); fade_result(e, a, LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_fade_independent_tracks_and_capture(void) {
  printf("test_fade_independent_tracks_and_capture\n");
  le_engine* e = fade_fixture(48000);
  float pcm[128], input[512] = {0}, output[512];
  for (int i = 0; i < 128; ++i) pcm[i] = .25f;
  CHECK(le_engine_import_track(e, 1, pcm, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  CHECK(le_engine_set_track_volume(e, 0, .5f) == LE_OK);
  drain(e);
  uint64_t a, b;
  CHECK(le_engine_toggle_fade(e, 0, .5f, &a) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 1, 1, &b) == LE_OK);
  le_engine_process(e, output, input, 512);
  for (int i = 0; i < 512; ++i)
    CHECK(fabs(output[i] - (.25 * (1 - i / 24000.0) + .25 * (1 - i / 48000.0))) < 2e-6);
  fade_result(e, a, LE_OK); fade_result(e, b, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap); CHECK(snap.volume == .5f);
  le_engine_destroy(e);

  le_engine* dry = fade_fixture(48000);
  e = fade_fixture(48000);
  le_engine_get_track(e, 0, &snap);
  le_fade_image image = snap.fade;
  image.amount = image.target = 0;
  CHECK(le_engine_install_fade(e, 0, &image, &a) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_record(dry, 0) == LE_OK);
  for (int i = 0; i < 512; ++i) input[i] = .1f;
  le_engine_process(e, output, input, 512);
  for (int i = 0; i < 512; ++i) CHECK(output[i] == 0);
  le_engine_process(dry, output, input, 512);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_record(dry, 0) == LE_OK);
  drain(e); drain(dry);
  float reference[128];
  CHECK(le_engine_export_track(e, 0, pcm, 128) == 128);
  CHECK(le_engine_export_track(dry, 0, reference, 128) == 128);
  CHECK(memcmp(pcm, reference, sizeof(pcm)) == 0);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);
  le_engine_process(e, output, input, 512);
  for (int i = 0; i < 512; ++i) CHECK(fabsf(output[i] - .1f) < 1e-6f);
  le_engine_destroy(e); le_engine_destroy(dry);
}

static void test_fade_lane_cache_and_tails(void) {
  printf("test_fade_lane_cache_and_tails\n");
  le_engine *cached, *live;
  cache_pair_prepare(&cached, &live, LE_FX_DRIVE);
  pump_frames(cached, 0, CACHE_LOOP); pump_frames(live, 0, CACHE_LOOP);
  le_lane_cache_info info;
  le_engine_get_lane_cache(cached, 0, 0, &info);
  CHECK(info.engaged);
  uint64_t id;
  CHECK(le_engine_toggle_fade(cached, 0, .5f, &id) == LE_OK);
  float input[512] = {0}, a[512], b[512];
  le_engine_process(cached, a, input, 512);
  le_engine_process(live, b, input, 512);
  for (int i = 0; i < 512; ++i)
    CHECK(fabs(a[i] - b[i] * (1 - i / 24000.0)) < 1e-3);
  le_engine_destroy(cached); le_engine_destroy(live);

  for (int track = 0; track < 2; ++track) {
    le_engine* e = fade_fixture(48000);
    if (track) {
      CHECK(le_engine_set_track_fx(e, 0, 0, LE_FX_ECHO) == LE_OK);
      CHECK(le_engine_set_track_fx_count(e, 0, 1, 0) == LE_OK);
      CHECK(le_engine_set_track_fx_param(e, 0, 0, 0, .01f) == LE_OK);
      CHECK(le_engine_set_track_fx_param(e, 0, 0, 1, .6f) == LE_OK);
      CHECK(le_engine_set_track_fx_param(e, 0, 0, 2, 1) == LE_OK);
    } else {
      CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_ECHO) == LE_OK);
      CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
      CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, .01f) == LE_OK);
      CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, .6f) == LE_OK);
      CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1) == LE_OK);
    }
    for (int i = 0; i < 8; ++i) le_engine_process(e, a, input, 512);
    le_track_snapshot snap; le_engine_get_track(e, 0, &snap);
    le_fade_image image = snap.fade; image.amount = image.target = 0;
    CHECK(le_engine_install_fade(e, 0, &image, &id) == LE_OK);
    le_engine_process(e, a, input, 512);
    float peak = 0;
    for (int i = 0; i < 512; ++i) peak = fmaxf(peak, fabsf(a[i]));
    if (track) CHECK(peak > .01f); // downstream Track Post tail survives
    else CHECK(peak == 0); // upstream lane Post tail is attenuated
    le_engine_destroy(e);
  }
}

static void test_fade_import_before_audibility(void) {
  printf("test_fade_import_before_audibility\n");
  le_engine* e = make_configured_engine();
  float pcm[128], out[1], in[1] = {0};
  for (int i = 0; i < 128; ++i) pcm[i] = .5f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(!le_engine_commands_settled(e));
  drain(e); // production Session must settle reset before choosing identity
  le_track_snapshot snapshot;
  le_engine_get_track(e, 0, &snapshot);
  CHECK(snapshot.state == LE_TRACK_EMPTY);
  le_fade_image image = snapshot.fade;
  image.amount = image.target = .25f;
  uint64_t request;
  CHECK(le_engine_install_fade(e, 0, &image, &request) == LE_OK);
  le_engine_process(e, out, in, 1); // callbacks run, but content is still silent
  CHECK(out[0] == 0);
  fade_result(e, request, LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  le_engine_process(e, out, in, 1);
  CHECK(out[0] == .125f); // no unity sample between commit and image install
  CHECK(le_engine_clear(e, 0) == LE_OK); drain(e);
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK); drain(e);
  le_engine_get_track(e, 0, &snapshot);
  image = snapshot.fade; image.amount = image.target = .25f;
  CHECK(le_engine_install_fade(e, 0, &image, &request) == LE_OK); drain(e);
  fade_result(e, request, LE_OK);
  // Replacement of loaded-but-EMPTY material must invalidate the old image.
  for (int i = 0; i < 128; ++i) pcm[i] = .75f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_install_fade(e, 0, &image, &request) == LE_OK);
  drain(e); fade_result(e, request, LE_ERR_INVALID);
  le_engine_get_track(e, 0, &snapshot);
  CHECK(snapshot.fade.amount == 1 && snapshot.fade.generation != image.generation);
  const uint64_t generation = snapshot.fade.generation;
  // Ring-full refusal precedes any material mutation or generation change.
  for (int i = 0; i < LE_RING_CAPACITY - 1; ++i)
    CHECK(le_engine_set_track_volume(e, 0, 1) == LE_OK);
  pcm[0] = .1f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_ERR_NOT_READY);
  float original[128];
  CHECK(le_engine_export_track(e, 0, original, 128) == 128 && original[0] == .75f);
  drain(e);
  le_engine_get_track(e, 0, &snapshot);
  CHECK(snapshot.fade.generation == generation);
  le_engine_destroy(e);
}

static le_fade_image fade_hook_before;
static int fade_hook_stage;
static void fade_snapshot_interleave(le_engine* e, int stage) {
  if (stage != fade_hook_stage) return;
  le_test_fade_hook = NULL;
  if (stage == 1) {
    le_track_snapshot observed;
    le_engine_get_track(e, 0, &observed);
    CHECK(observed.fade.amount == fade_hook_before.amount);
    CHECK(observed.fade.target == fade_hook_before.target);
    CHECK(observed.fade.full_travel_seconds == fade_hook_before.full_travel_seconds);
  } else drain(e); // complete a new publication halfway through tuple reading
}

static void test_fade_coherent_publication(void) {
  printf("test_fade_coherent_publication\n");
  le_engine* e = fade_fixture(48000);
  le_track_snapshot before, observed;
  le_engine_get_track(e, 0, &before);
  fade_hook_before = before.fade;
  le_fade_image image = before.fade;
  image.amount = .25f; image.target = 0; image.full_travel_seconds = 2;
  uint64_t id;
  CHECK(le_engine_install_fade(e, 0, &image, &id) == LE_OK);
  fade_hook_stage = 1; le_test_fade_hook = fade_snapshot_interleave;
  drain(e);
  le_engine_get_track(e, 0, &before);
  CHECK(before.fade.amount == .25f && before.fade.target == 0);
  image.amount = .75f; image.target = 1; image.full_travel_seconds = 4;
  CHECK(le_engine_install_fade(e, 0, &image, &id) == LE_OK);
  fade_hook_stage = 2; le_test_fade_hook = fade_snapshot_interleave;
  le_engine_get_track(e, 0, &observed);
  CHECK(observed.fade.amount == before.fade.amount);
  CHECK(observed.fade.target == before.fade.target);
  CHECK(observed.fade.full_travel_seconds == before.fade.full_travel_seconds);
  le_engine_get_track(e, 0, &observed);
  CHECK(observed.fade.amount == .75f && observed.fade.target == 1);
  CHECK(observed.fade.full_travel_seconds == 4);
  le_engine_destroy(e);
}

static void test_fade_actual_arm_render(void) {
  printf("test_fade_actual_arm_render\n");
  le_engine* e = fade_fixture(48000);
  uint64_t id;
  CHECK(le_engine_toggle_fade(e, 0, .5f, &id) == LE_OK);
  fade_process(e, 12000, 512, 1, -1.0 / 24000, .5f);
  const char* dir = render_test_dir("fade-arm");
  CHECK(le_perf_arm(e, dir) == LE_OK); drain(e);
  float input[256] = {0}, live[256], replay[256], pcm[128];
  le_engine_process(e, live, input, 128);
  CHECK(le_engine_toggle_fade(e, 0, 2, &id) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, .5f, &id) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, 1, &id) == LE_OK);
  le_engine_process(e, live + 128, input, 128);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, 128) == 128);
  char path[700]; snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, 128, 48000);
  test_write_manifest(dir,
    "{\"sample_rate\":48000,\"capture_frames\":256,"
    "\"armSnapshot\":{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]},"
    "\"disarmSnapshot\":{\"tracks\":[]},\"layers\":[]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int replay_frames = test_read_wet_stem(dir, 0, replay, 256);
  CHECK(replay_frames == 256);
  CHECK(live[0] == .25f); // current amount at actual arm, not an earlier snapshot
  for (int i = 0; i < replay_frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 1e-6f);
  for (int i = 0; i < 128; ++i) CHECK(pcm[i] == .5f);
  le_engine_destroy(e);
}
