/* Literal PCM oracles through the production callback and checked producers. */
static le_engine* fade_fixture(int sr) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, 1, 1, 1000) == LE_OK);
  float pcm[128];
  for (int i = 0; i < 128; ++i) pcm[i] = 0.5f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
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
  CHECK(le_engine_play(e, 1) == LE_OK);
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
  CHECK(le_engine_play(e, 0) == LE_OK);
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

/* Preserve the actual native sidecar, including staged restoration identities,
 * while supplying only the Dart-owned arm/disarm fields in this native fixture. */
static void fade_finalize_manifest(const char* dir, const char* arm) {
  char path[700]; snprintf(path, sizeof(path), "%s/performance.json", dir);
  char* json = malloc(1024 * 1024);
  CHECK(json != NULL);
  if (!json) return;
  CHECK(read_file_for_test(path, json, 1024 * 1024) > 0);
  char* end = strrchr(json, '}');
  CHECK(end != NULL);
  if (end) {
    FILE* f = fopen(path, "wb"); CHECK(f != NULL);
    if (f) {
      fwrite(json, 1, (size_t)(end - json), f);
      fprintf(f, ",\"armSnapshot\":%s,\"disarmSnapshot\":{\"tracks\":[]}}", arm);
      CHECK(fclose(f) == 0);
    }
  }
  free(json);
}

static void test_fade_actual_arm_render(void) {
  printf("test_fade_actual_arm_render\n");
  le_engine* e = fade_fixture(48000);
  uint64_t id;
  CHECK(le_engine_toggle_fade(e, 0, .5f, &id) == LE_OK);
  fade_process(e, 12000, 512, 1, -1.0 / 24000, .5f);
  const char* dir = render_test_dir("fade-arm");
  CHECK(le_perf_arm(e, dir) == LE_OK); drain(e);
  float input[256] = {0}, live[512], replay[512], pcm[128];
  le_engine_process(e, live, input, 128);
  CHECK(le_engine_toggle_fade(e, 0, 2, &id) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, .5f, &id) == LE_OK);
  CHECK(le_engine_toggle_fade(e, 0, 1, &id) == LE_OK);
  le_engine_process(e, live + 128, input, 128);
  le_track_snapshot before_clear;
  le_engine_get_track(e, 0, &before_clear);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  le_engine_process(e, live + 256, input, 128);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, live + 384, input, 128);
  for (int i = 256; i < 384; ++i) CHECK(live[i] == 0);
  CHECK(fabsf(live[384] - .5f * before_clear.fade.amount) < 1e-6f);
  CHECK(fabsf(live[384] - .248666666667f) < 1e-6f);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, 128) == 128);
  char path[700]; snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, 128, 48000);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  const int replay_frames = test_read_wet_stem(dir, 0, replay, 512);
  CHECK(replay_frames == 512);
  CHECK(live[0] == .25f); // current amount at actual arm, not an earlier snapshot
  for (int i = 0; i < replay_frames; ++i) CHECK(fabsf(replay[i] - live[i]) < 1e-6f);
  for (int i = 0; i < 128; ++i) CHECK(pcm[i] == .5f);
  le_engine_destroy(e);
}

/* Install a moving/stationary image without sampling any audio frames. */
static uint64_t fade_install_at(le_engine* e, float amount, float target, float seconds) {
  le_track_snapshot s;
  le_engine_get_track(e, 0, &s);
  le_fade_image image = s.fade;
  image.amount = amount; image.target = target; image.full_travel_seconds = seconds;
  uint64_t request = 0;
  CHECK(le_engine_install_fade(e, 0, &image, &request) == LE_OK);
  return request;
}

static void fade_check_stationary(le_engine* e, float amount) {
  le_track_snapshot s;
  le_engine_get_track(e, 0, &s);
  CHECK(s.fade.amount == amount && s.fade.target == amount);
  CHECK(s.fade.full_travel_seconds == 0);
}

static void fade_clear_before_publication(le_engine* e, int stage) {
  if (stage != 1 || e->tracks[0].fade.amount > .500001) return;
  le_test_fade_hook = NULL;
  le_track_snapshot stale; le_engine_get_track(e, 0, &stale);
  CHECK(stale.fade.amount == .75f); // previous coherent control observation
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
}

static void test_fade_clear_boundary(void) {
  printf("test_fade_clear_boundary\n");
  for (int interleave = 0; interleave < 2; ++interleave) {
    le_engine* e = fade_fixture(48000);
    uint64_t request = fade_install_at(e, .75f, 0, 1);
    drain(e); fade_result(e, request, LE_OK);
    le_track_snapshot old;
    le_engine_get_track(e, 0, &old);
    CHECK(old.fade.amount == .75f);
    if (!interleave) {
      // Clear is posted while publication is held: control retains .75, but
      // the next command consumption observes the actual progressed .5.
      le_test_fade_hook = fade_clear_before_publication;
      fade_process(e, 12000, 512, .75, -1.0 / 48000, .5f);
      CHECK(le_test_fade_hook == NULL);
    } else {
      request = fade_install_at(e, .5f, 0, 4); drain(e);
      fade_result(e, request, LE_OK);
      g_process_after_clear_posted = 1;
      CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
    }
    CHECK(le_engine_clear_restore_pending(e, 0) == 0); // ordinary stays synchronous
    if (!interleave) CHECK(le_engine_undo(e, 0) == LE_ERR_NOT_READY);
    drain(e);
    fade_check_stationary(e, 1);
    le_track_snapshot empty; le_engine_get_track(e, 0, &empty);
    le_fade_image obsolete = empty.fade;
    obsolete.amount = obsolete.target = .9f;
    CHECK(le_engine_undo(e, 0) == LE_OK);
    CHECK(le_engine_install_fade(e, 0, &obsolete, &request) == LE_OK);
    fade_process(e, 512, 127, .5, 0, .5f); // includes first restored sample
    fade_result(e, request, LE_ERR_INVALID); // EMPTY identity cannot retarget restored material
    fade_check_stationary(e, .5f);
    CHECK(e->tracks[0].redo_count == 1);
    // A queued restore -> Clear must capture the restored image, not EMPTY unity.
    CHECK(le_engine_redo(e, 0) == LE_OK); drain(e);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    fade_process(e, 128, 127, .5, 0, .5f);
    fade_check_stationary(e, .5f);
    // Re-clear captures an independent newer image and leaves source PCM alone.
    request = fade_install_at(e, .25f, .25f, 0); drain(e);
    fade_result(e, request, LE_OK);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    fade_process(e, 128, 127, .25, 0, .5f);
    float pcm[128]; CHECK(le_engine_export_track(e, 0, pcm, 128) == 128);
    for (int i = 0; i < 128; ++i) CHECK(pcm[i] == .5f);
    le_engine_destroy(e);
  }
}

static void test_fade_clear_pressure_and_frozen(void) {
  printf("test_fade_clear_pressure_and_frozen\n");
  for (int frozen = 0; frozen < 2; ++frozen) {
    le_engine* e = fade_fixture(48000);
    uint64_t request = fade_install_at(e, .25f, .25f, 0);
    drain(e); fade_result(e, request, LE_OK);
    if (frozen) {
      CHECK(le_engine_record(e, 0) == LE_OK);
      float in[64], out[64];
      for (int i = 0; i < 64; ++i) in[i] = .25f;
      le_engine_process(e, out, in, 64);
    }
    const int depth = e->tracks[0].undo_count;
    for (int i = 0; i < LE_RING_CAPACITY - 1; ++i)
      CHECK(le_engine_set_track_volume(e, 0, 1) == LE_OK);
    CHECK(le_engine_clear_undoable(e, 0) != LE_OK);
    CHECK(e->tracks[0].undo_count == depth);
    CHECK(!e->tracks[0].clear_restore_pending);
    fade_check_stationary(e, .25f);
    drain(e);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
    CHECK(le_engine_clear_restore_pending(e, 0) == frozen);
    // These are valid stale no-op reports. Fill after posting (which drains).
    const le_command benign = {.code = LE_EVT_TAKE_CANCELLED,
                               .lanei = {LE_MAX_TRACKS - 1, 0, 0}};
    int filled = 0; while (le_ring_push(&e->evt_ring, benign)) ++filled;
    CHECK(filled > 0);
    drain(e);
    CHECK(!le_engine_clear_restore_pending(e, 0));
    CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
    fade_check_stationary(e, .25f);
    le_track_snapshot s; le_engine_get_track(e, 0, &s);
    CHECK(s.state == (frozen ? LE_TRACK_STOPPED : LE_TRACK_PLAYING));
    CHECK(!s.muted);
    if (frozen) {
      CHECK(le_engine_play(e, 0) == LE_OK);
      float in[128] = {0}, out[128]; le_engine_process(e, out, in, 128);
      for (int i = 0; i < 128; ++i)
        CHECK(fabsf(out[i] - (i < 64 ? .1875f : .125f)) < 1e-6f);
    } else fade_process(e, 128, 127, .25, 0, .5f);
    le_engine_destroy(e);
  }
}

static void fade_clear_overwrite(le_engine* e, int stage) {
  if (stage != 3) return;
  le_test_fade_hook = NULL;
  /* A newer raw Clear supersedes recovery and overwrites during the copy. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
}

static void test_fade_clear_coherent_read(void) {
  printf("test_fade_clear_coherent_read\n");
  le_engine* e = fade_fixture(48000);
  uint64_t id = fade_install_at(e, .5f, .5f, 0); drain(e); fade_result(e, id, LE_OK);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
  // Simulate publication suspended at its odd revision: no mute or pop on refusal.
  atomic_fetch_add(&e->tracks[0].a_clear_revision, 1);
  CHECK(le_engine_undo(e, 0) == LE_ERR_NOT_READY);
  CHECK(e->tracks[0].undo_count == 1 && e->tracks[0].redo_count == 0);
  atomic_fetch_add(&e->tracks[0].a_clear_revision, 1);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
  le_test_fade_hook = fade_clear_overwrite;
  CHECK(le_engine_undo(e, 0) == LE_ERR_INVALID);
  CHECK(e->tracks[0].undo_count == 0);
  fade_check_stationary(e, 1);
  le_engine_destroy(e);
}

static void test_fade_clear_history(void) {
  printf("test_fade_clear_history\n");
  le_engine* e = fade_fixture(48000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  float in[128] = {0}, out[128];
  le_engine_process(e, out, in, 128);
  le_engine_drain_events(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_process(e, out, in, 128); // retire the latency-compensated pass
  le_engine_drain_events(e);
  uint64_t id = fade_install_at(e, .5f, .5f, 0); drain(e); fade_result(e, id, LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
  fade_check_stationary(e, .5f);
  CHECK(le_engine_redo(e, 0) == LE_OK); drain(e);
  fade_check_stationary(e, .5f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
  fade_check_stationary(e, .5f);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e); // layer is still below CLEAR
  fade_check_stationary(e, .5f);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e); // base -> EMPTY
  fade_check_stationary(e, 1);
  CHECK(le_engine_redo(e, 0) == LE_OK); drain(e);
  fade_check_stationary(e, 1);
  le_engine_destroy(e);
}

/* Schedule the render half of an already-entered callback after control has
 * posted Clear: that callback cannot consume the newly posted command until
 * its next command-drain boundary. Save/reinsert only that command to model
 * this ordering deterministically without a scheduler-dependent thread race. */
static void test_fade_clear_late_retirement(void) {
  printf("test_fade_clear_late_retirement\n");
  le_engine* e = fade_fixture(48000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  float in[128], out[128];
  for (int i = 0; i < 128; ++i) in[i] = .25f;
  le_engine_process(e, out, in, 64);
  le_engine_drain_events(e); drain(e);
  CHECK(e->tracks[0].undo_count == 0);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  le_engine_drain_events(e);
  CHECK(e->tracks[0].outstanding_count == 0); // pending Clear cannot reuse old shadows
  le_command clear;
  CHECK(le_ring_pop(&e->ring, &clear) == 1);
  CHECK(clear.code == LE_CMD_CLEAR);
  le_engine_process(e, out, in, 128); // finishes a real backed pass, after control finish
  CHECK(le_ring_push(&e->ring, clear) == 1);
  drain(e);
  CHECK(le_engine_clear_restore_pending(e, 0) == 0);
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
  CHECK(e->tracks[0].undo_count == 1); // the completed pass remains below CLEAR
  CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
  float pcm[128];
  const int exported = le_engine_export_track(e, 0, pcm, 128);
  CHECK(exported == 128);
  if (exported == 128) for (int i = 0; i < 128; ++i) CHECK(pcm[i] == .5f);
  le_engine_destroy(e);
}

static void test_fade_clear_superseded_retirement(void) {
  printf("test_fade_clear_superseded_retirement\n");
  for (int fresh = 0; fresh < 2; ++fresh) {
    le_engine* e = fade_fixture(48000);
    CHECK(le_engine_record(e, 0) == LE_OK);
    float in[128] = {0}, out[128];
    le_engine_process(e, out, in, 64);
    le_engine_drain_events(e); drain(e);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
    le_command clear, old_layer;
    CHECK(le_ring_pop(&e->ring, &clear) == 1 && clear.code == LE_CMD_CLEAR);
    le_engine_process(e, out, in, 128);
    CHECK(le_ring_pop(&e->evt_ring, &old_layer) == 1);
    CHECK(old_layer.code == LE_EVT_LAYER_RETIRED);
    CHECK(le_ring_push(&e->ring, clear) == 1); drain(e);
    CHECK((fresh ? le_engine_record(e, 0) : le_engine_clear(e, 0)) == LE_OK);
    CHECK(le_ring_push(&e->evt_ring, old_layer) == 1);
    le_engine_drain_events(e);
    CHECK(e->tracks[0].undo_count == 0);
    CHECK(!e->tracks[0].clear_restore_pending);
    le_engine_process(e, out, in, 64);
    CHECK(e->tracks[0].undo_count == 0);
    CHECK(load_i32(&e->tracks[0].a_state) ==
          (fresh ? LE_TRACK_RECORDING : LE_TRACK_EMPTY));
    le_engine_destroy(e);
  }
}

static void fade_render_status(le_engine* e, const char* dir, int expected) {
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  int32_t channel = -1, succeeded = -1;
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(channel == 0 && succeeded == expected);
}

static float fade_restore_interleaved_sample;
static void fade_restore_interleave(le_engine* e, int stage) {
  if (stage != 4) return;
  le_test_fade_hook = NULL;
  float input = 0;
  le_engine_process(e, &fade_restore_interleaved_sample, &input, 1);
}

/* Pending arm owns staging; the callback may restore before control publishes
 * the same slot. Re-arm creates a new namespace and different exact material. */
static void test_fade_restore_capture_lifetime(void) {
  printf("test_fade_restore_capture_lifetime\n");
  le_engine* e = fade_fixture(48000);
  for (int capture = 0; capture < 2; ++capture) {
    if (capture) {
      CHECK(le_engine_clear(e, 0) == LE_OK); drain(e);
      float pcm[128];
      for (int i = 0; i < 128; ++i) pcm[i] = (float)(i + 1) / 256;
      CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
      CHECK(le_engine_commit_session(e, 128, 0) == LE_OK); drain(e);
    }
    uint64_t id = fade_install_at(e, .25f, .25f, 0); drain(e); fade_result(e, id, LE_OK);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    const char* dir = render_test_dir(capture ? "fade-rearm" : "fade-pending-arm");
    CHECK(le_perf_arm(e, dir) == LE_OK); // deliberately leave ARM queued
    le_test_fade_hook = fade_restore_interleave;
    CHECK(le_engine_undo(e, 0) == LE_OK);
    float in[128] = {0}, live[265], replay[265];
    live[0] = fade_restore_interleaved_sample;
    le_engine_process(e, live + 1, in, 7);
    CHECK(le_engine_play(e, 0) == LE_OK);
    le_engine_process(e, live + 8, in, 128);
    CHECK(le_engine_stop_track(e, 0) == LE_OK);
    le_engine_process(e, live + 136, in, 1);
    CHECK(le_engine_play(e, 0) == LE_OK);
    le_engine_process(e, live + 137, in, 128);
    CHECK(le_engine_clear(e, 0) == LE_OK); drain(e);
    CHECK(le_perf_disarm(e) == LE_OK);
    fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
    fade_render_status(e, dir, 1);
    CHECK(test_read_wet_stem(dir, 0, replay, 265) == 265);
    for (int i = 0; i < 265; ++i) CHECK(fabsf(live[i] - replay[i]) < 1e-6f);
    CHECK(live[0] == (capture ? 0 : .125f));
    if (capture) {
      for (int i = 0; i < 128; ++i) CHECK(live[8 + i] == (float)(i + 1) / 1024);
      // Restored identity never accepts a missing, short or overlong file.
      char path[700], backup[700];
      snprintf(path, sizeof(path), "%s/restore-0-1.pcm", dir);
      snprintf(backup, sizeof(backup), "%s/restore-backup.pcm", dir);
      unsigned char bytes[512];
      CHECK(read_binary_file_for_test(path, bytes, sizeof(bytes)) == sizeof(bytes));
      CHECK(rename(path, backup) == 0); fade_render_status(e, dir, 0);
      CHECK(rename(backup, path) == 0);
      FILE* file = fopen(path, "wb"); CHECK(file != NULL);
      if (file) { CHECK(fwrite(bytes, 1, 511, file) == 511); CHECK(fclose(file) == 0); }
      fade_render_status(e, dir, 0);
      file = fopen(path, "wb"); CHECK(file != NULL);
      if (file) { CHECK(fwrite(bytes, 1, 512, file) == 512); fputc(0, file); CHECK(fclose(file) == 0); }
      fade_render_status(e, dir, 0);
      file = fopen(path, "wb"); CHECK(file != NULL);
      if (file) { CHECK(fwrite(bytes, 1, 512, file) == 512); CHECK(fclose(file) == 0); }
      fade_render_status(e, dir, 1);
      // Every fact is valid, but the bounded segment builder cannot represent
      // this many transitions. It must fail instead of silently dropping them.
      snprintf(path, sizeof(path), "%s/events.log", dir);
      file = fopen(path, "ab"); CHECK(file != NULL);
      if (file) {
        for (int i = 0; i < 4096; ++i)
          test_write_log_entry(file, 1, (le_command){.code = LE_PLOG_RESTORE_TRANSPORT,
              .restore_log = {0, 1, LE_TRACK_STOPPED, 0}});
        CHECK(fclose(file) == 0);
      }
      fade_render_status(e, dir, 0);
    }
  }
  le_engine_destroy(e);
}

static void test_fade_restore_history_replacement(void) {
  printf("test_fade_restore_history_replacement\n");
  for (int redo = 0; redo < 2; ++redo) {
    le_engine* e = fade_fixture(48000);
    float in[128], out[128];
    for (int i = 0; i < 128; ++i) in[i] = .25f;
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, out, in, 128); le_engine_drain_events(e);
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, out, in, 128); le_engine_drain_events(e);
    CHECK(e->tracks[0].undo_count > 0);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    const char* dir = render_test_dir(redo ? "fade-restore-redo" : "fade-restore-undo");
    CHECK(le_perf_arm(e, dir) == LE_OK);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    le_engine_process(e, out, in, 1);
    CHECK(le_engine_undo(e, 0) == LE_OK); // same-span layer, still PLAYING
    le_engine_process(e, out, in, 1);
    if (redo) { CHECK(le_engine_redo(e, 0) == LE_OK); le_engine_process(e, out, in, 1); }
    CHECK(le_engine_stop_track(e, 0) == LE_OK); drain(e);
    CHECK(le_engine_play(e, 0) == LE_OK); le_engine_process(e, out, in, 1);
    CHECK(atomic_load(&e->a_perf_layer_overruns) == 0);
    CHECK(le_engine_clear(e, 0) == LE_OK); drain(e);
    CHECK(le_perf_disarm(e) == LE_OK);
    fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
    fade_render_status(e, dir, 0); // truthful unsupported history, not stale PCM success
    le_engine_destroy(e);
  }
}

static void test_fade_restore_frozen_render(void) {
  printf("test_fade_restore_frozen_render\n");
  le_engine* e = fade_fixture(48000);
  uint64_t id = fade_install_at(e, .25f, .25f, 0); drain(e); fade_result(e, id, LE_OK);
  float input[128], live[256], replay[256];
  for (int i = 0; i < 128; ++i) input[i] = .25f;
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_process(e, live, input, 64);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
  const char* dir = render_test_dir("fade-frozen-render");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, live, input, 128);
  CHECK(le_engine_play(e, 0) == LE_OK);
  le_engine_process(e, live + 128, input, 128);
  CHECK(le_perf_disarm(e) == LE_OK);
  fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
  fade_render_status(e, dir, 1);
  CHECK(test_read_wet_stem(dir, 0, replay, 256) == 256);
  for (int i = 0; i < 256; ++i) {
    const float expected = i < 128 ? 0 : (i < 192 ? .1875f : .125f);
    CHECK(live[i] == expected);
    CHECK(fabsf(replay[i] - expected) < 1e-6f);
  }
  le_engine_destroy(e);
}

static void test_fade_restore_surviving_grid_phase(void) {
  printf("test_fade_restore_surviving_grid_phase\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  float pcm[128], zero[128] = {0}, live[128], replay[128];
  for (int i = 0; i < 128; ++i) pcm[i] = (float)(i + 1) / 256;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_import_track(e, 1, zero, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK); drain(e);
  uint64_t id = fade_install_at(e, .5f, .5f, 0); drain(e); fade_result(e, id, LE_OK);
  le_engine_process(e, live, zero, 37);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  le_engine_process(e, live, zero, 13); // sibling preserves the advancing grid
  CHECK(e->clock.position == 50);
  const char* dir = render_test_dir("fade-restored-phase");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, live, zero, 128);
  CHECK(le_perf_disarm(e) == LE_OK);
  fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
  fade_render_status(e, dir, 1);
  CHECK(test_read_wet_stem(dir, 0, replay, 128) == 128);
  for (int i = 0; i < 128; ++i) {
    const float expected = pcm[(50 + i) % 128] * .5f;
    CHECK(live[i] == expected);
    CHECK(fabsf(replay[i] - expected) < 1e-6f);
  }
  le_engine_destroy(e);
}

static void fade_redo_selected_source(le_engine* e, int stage) {
  if (stage != 5) return;
  le_test_fade_hook = NULL;
  CHECK(le_engine_redo(e, 0) == LE_OK);
}

static void test_fade_restore_source_end_edges(void) {
  printf("test_fade_restore_source_end_edges\n");
  for (int racing_swap = 0; racing_swap < 2; ++racing_swap) {
    le_engine* e = fade_fixture(48000);
    float input[128], output[128];
    for (int i = 0; i < 128; ++i) input[i] = .25f;
    if (racing_swap) {
      CHECK(le_engine_record(e, 0) == LE_OK);
      le_engine_process(e, output, input, 128); le_engine_drain_events(e);
      CHECK(le_engine_record(e, 0) == LE_OK);
      le_engine_process(e, output, input, 128); le_engine_drain_events(e);
    }
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    const char* dir = render_test_dir(racing_swap ? "fade-selected-slot-race" : "fade-undo-empty");
    CHECK(le_perf_arm(e, dir) == LE_OK);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    le_engine_process(e, output, input, 1);
    CHECK(le_engine_undo(e, 0) == LE_OK);
    if (racing_swap) le_test_fade_hook = fade_redo_selected_source;
    le_engine_process(e, output, input, 1);
    CHECK(output[0] == (racing_swap ? .5f : 0));
    CHECK(le_perf_disarm(e) == LE_OK);
    fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
    fade_render_status(e, dir, 0);
    le_engine_destroy(e);
  }
}

typedef struct fade_drain_gate {
  _Atomic int entered, release;
} fade_drain_gate;
static void fade_hold_drain(void* opaque) {
  fade_drain_gate* gate = opaque;
  if (!gate) return;
  atomic_store(&gate->entered, 1);
  while (!atomic_load(&gate->release)) test_sleep_ms(1);
}

static void test_fade_restore_staging_and_manifest_capacity(void) {
  printf("test_fade_restore_staging_and_manifest_capacity\n");
  for (int manifest_full = 0; manifest_full < 2; ++manifest_full) {
    le_engine* e = fade_fixture(48000);
    uint64_t id = fade_install_at(e, .25f, .25f, 0); drain(e); fade_result(e, id, LE_OK);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    fade_drain_gate gate = {0};
    le_perf_drain_set_mid_cycle_hook_for_test(fade_hold_drain, &gate);
    const char* dir = render_test_dir(manifest_full ? "fade-manifest-capacity" : "fade-staging-refusal");
    CHECK(le_perf_arm(e, dir) == LE_OK); drain(e);
    for (int i = 0; i < 5000 && !atomic_load(&gate.entered); ++i) test_sleep_ms(1);
    CHECK(atomic_load(&gate.entered));
    const unsigned capacity = manifest_full ? LE_LAYER_STAGING_RING_CAPACITY : 2;
    // Consumer is parked before its first staging access: use a small valid
    // ring to prove refusal without exhausting the manifest in this case.
    CHECK(le_layer_staging_ring_init(&e->perf.layer_staging_ring,
        e->perf.layer_staging_ring.buffer, capacity) == 1);
    // Fill the real staging owner with valid tiny images while its consumer is
    // parked. The following real restoration must free its refused kind-1 copy.
    for (unsigned i = 0; i < capacity - 1; ++i) {
      le_staged_layer entry = {.channel = 1, .slot = 0, .frame = i,
                              .frame_count = 1, .lane_count = 1};
      entry.lane_pcm[0] = malloc(sizeof(float)); CHECK(entry.lane_pcm[0] != NULL);
      if (entry.lane_pcm[0]) entry.lane_pcm[0][0] = .5f;
      CHECK(le_layer_staging_ring_push(&e->perf.layer_staging_ring, entry) == 1);
    }
    CHECK(le_engine_undo(e, 0) == LE_OK);
    float input = 0, output = 0;
    le_engine_process(e, &output, &input, 1);
    CHECK(output == .125f); // capture refusal cannot refuse musical Undo
    CHECK(atomic_load(&e->a_perf_layer_overruns) == 1);
    atomic_store(&gate.release, 1);
    for (int i = 0; i < 5000 && atomic_load(&e->perf.layer_staging_ring.head) !=
         atomic_load(&e->perf.layer_staging_ring.tail); ++i) test_sleep_ms(1);
    CHECK(atomic_load(&e->perf.layer_staging_ring.head) == atomic_load(&e->perf.layer_staging_ring.tail));
    if (manifest_full) {
      // One restoration fills the final manifest entry; the next is dropped and
      // counted. Capture continues; the render below fails that stem instead.
      for (int i = 0; i < 2; ++i) {
        CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
        CHECK(le_engine_undo(e, 0) == LE_OK);
        le_engine_process(e, &output, &input, 1);
        CHECK(output == .125f);
      }
      for (int i = 0; i < 5000 && atomic_load(&e->perf.layer_staging_ring.head) !=
           atomic_load(&e->perf.layer_staging_ring.tail); ++i) test_sleep_ms(1);
      CHECK(!le_perf_drain_self_stopped(e->perf.drain));
    }
    CHECK(le_perf_disarm(e) == LE_OK);
    le_perf_drain_set_mid_cycle_hook_for_test(NULL, NULL);
    char path[700]; snprintf(path, sizeof(path), "%s/performance.json", dir);
    char* json = malloc(1024 * 1024); CHECK(json != NULL);
    if (json) {
      CHECK(read_file_for_test(path, json, 1024 * 1024) > 0);
      CHECK(strstr(json, "\"stopped_early\"") == NULL);
      CHECK((strstr(json, "\"layers_dropped\": 1,") != NULL) == manifest_full);
      if (manifest_full) {
        CHECK(count_layer_entries_for_test(json) == (int)LE_LAYER_STAGING_RING_CAPACITY);
        CHECK(strstr(json, "restore-0-2.pcm") != NULL);
        CHECK(strstr(json, "restore-0-3.pcm") == NULL);
      } else {
        CHECK(count_layer_entries_for_test(json) == 1);
        CHECK(strstr(json, "restore-0-1.pcm") == NULL);
      }
      free(json);
    }
    // Master keeps every processed frame, including those after the drop.
    snprintf(path, sizeof(path), "%s/master.pcm", dir);
    const int frames_processed = manifest_full ? 3 : 1;
    float recorded[3] = {0};
    CHECK(read_binary_file_for_test(path, (unsigned char*)recorded,
        sizeof(float) * frames_processed) == (int)(sizeof(float) * frames_processed));
    for (int i = 0; i < frames_processed; ++i) CHECK(recorded[i] == .125f);
    fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
    fade_render_status(e, dir, 0);
    le_engine_destroy(e);
  }
}

static void test_fade_grouped_muted_restore_stems(void) {
  printf("test_fade_grouped_muted_restore_stems\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  float pcm[128], zero[128] = {0}, output[128], stem[128];
  for (int i = 0; i < 128; ++i) pcm[i] = .5f;
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_import_track(e, 1, pcm, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK); drain(e);
  CHECK(le_engine_play(e, 1) == LE_OK); drain(e);
  uint64_t id = fade_install_at(e, .25f, .25f, 0); drain(e); fade_result(e, id, LE_OK);
  le_track_snapshot track; le_engine_get_track(e, 1, &track);
  track.fade.amount = track.fade.target = .5f; track.fade.full_travel_seconds = 0;
  CHECK(le_engine_install_fade(e, 1, &track.fade, &id) == LE_OK); drain(e); fade_result(e, id, LE_OK);
  CHECK(le_engine_set_lane_mute(e, 1, 0, 1) == LE_OK); drain(e);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  CHECK(le_engine_clear_undoable(e, 1) == LE_OK); drain(e);
  const char* dir = render_test_dir("fade-group-muted");
  CHECK(le_perf_arm(e, dir) == LE_OK);
  CHECK(le_engine_history_mode_gate(e, 3, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 1) == LE_OK);
  le_engine_process(e, output, zero, 128);
  le_engine_get_track(e, 1, &track);
  CHECK(track.state == LE_TRACK_PLAYING && track.muted);
  for (int i = 0; i < 128; ++i) CHECK(output[i] == .125f);
  CHECK(le_perf_disarm(e) == LE_OK);
  fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
  fade_render_status(e, dir, 1);
  CHECK(test_read_wet_stem(dir, 0, stem, 128) == 128);
  for (int i = 0; i < 128; ++i) CHECK(stem[i] == .125f);
  int32_t channel = -1, success = 0;
  CHECK(le_perf_render_track_status(e, 1, &channel, &success) == LE_OK);
  CHECK(channel == 1 && success == 1);
  CHECK(test_read_wet_stem(dir, 1, stem, 128) == 128);
  for (int i = 0; i < 128; ++i) CHECK(stem[i] == 0);
  le_engine_destroy(e);
}

static void test_fade_restore_overdub_source_end(void) {
  printf("test_fade_restore_overdub_source_end\n");
  for (int before_first_sample = 0; before_first_sample < 2; ++before_first_sample) {
    le_engine* e = fade_fixture(48000);
    float input[128], output[128];
    for (int i = 0; i < 128; ++i) input[i] = .25f;
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, output, input, 64);
    CHECK(le_engine_clear_undoable(e, 0) == LE_OK); drain(e);
    const char* dir = render_test_dir(before_first_sample ? "fade-first-fact-invalid" : "fade-stopped-overdub");
    CHECK(le_perf_arm(e, dir) == LE_OK);
    CHECK(le_engine_undo(e, 0) == LE_OK); drain(e);
    if (!before_first_sample) {
      le_engine_process(e, output, input, 1);
      CHECK(output[0] == 0); // frozen restoration is STOPPED
    }
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, output, input, 1);
    CHECK(output[0] > 0); // no layer has retired to describe this new interval
    CHECK(le_engine_clear(e, 0) == LE_OK); drain(e);
    CHECK(le_perf_disarm(e) == LE_OK);
    fade_finalize_manifest(dir, "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[]}");
    fade_render_status(e, dir, 0); // even when the first captured fact is invalidation
    le_engine_destroy(e);
  }
}
