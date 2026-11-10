/* #1713 part 2c: the heard image in a performance capture. Its layers and
 * restore images are staged with their heard images, the lanes' sources are
 * logged (LE_PLOG_HEARD_SOURCE), and the offline render's wet stem plays a
 * heard image where the rig played it. Included by test_engine_core.c after
 * test_engine_heard_edits.h (shares its fixtures and the perf render
 * helpers). */

/* A 32-bit float stereo WAV of `count` (L, R) pairs, the format
 * performance_repository writes a heard image's snapshot in. */
static void heard_write_wav_stereo(const char* path, const float* pairs,
                                   int32_t count, int32_t sample_rate) {
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  unsigned char header[44] = {0};
  const uint32_t data_bytes = (uint32_t)count * 2u * (uint32_t)sizeof(float);
  const uint32_t riff_size = 36 + data_bytes;
  const uint32_t fmt_size = 16;
  const uint16_t format = 3;
  const uint16_t channels = 2;
  const uint32_t rate = (uint32_t)sample_rate;
  const uint32_t byte_rate = rate * 2u * (uint32_t)sizeof(float);
  const uint16_t align = 2 * sizeof(float);
  const uint16_t bits = 32;
  memcpy(header + 0, "RIFF", 4);
  memcpy(header + 4, &riff_size, 4);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  memcpy(header + 16, &fmt_size, 4);
  memcpy(header + 20, &format, 2);
  memcpy(header + 22, &channels, 2);
  memcpy(header + 24, &rate, 4);
  memcpy(header + 28, &byte_rate, 4);
  memcpy(header + 32, &align, 2);
  memcpy(header + 34, &bits, 2);
  memcpy(header + 36, "data", 4);
  memcpy(header + 40, &data_bytes, 4);
  fwrite(header, 1, sizeof(header), f);
  fwrite(pairs, sizeof(float), 2 * (size_t)count, f);
  fclose(f);
}

enum { HP_SR = 4800, HP_LOOP = 8 };

/* render_test_dir for a test that may run before any perf test made the
 * captures' parent directory. */
static const char* heard_perf_dir(const char* name) {
  test_render_mkdir(perf_test_dir());
  return render_test_dir(name);
}

/* An arm snapshot for track 0 whose lane 0 holds a clean take of 0.5 and a
 * heard image of (0.3, 0.1), and the events.log header with the arm fact. */
static FILE* heard_perf_fixture(const char* dir, uint64_t capture_frames,
                                const char* layers) {
  char loops[700];
  snprintf(loops, sizeof(loops), "%s/loops", dir);
  test_render_mkdir(loops);
  float clean[HP_LOOP];
  float pairs[2 * HP_LOOP];
  for (int i = 0; i < HP_LOOP; ++i) {
    clean[i] = 0.5f;
    pairs[2 * i] = 0.3f;
    pairs[2 * i + 1] = 0.1f;
  }
  char path[760];
  snprintf(path, sizeof(path), "%s/clean.wav", loops);
  test_write_wav_mono(path, clean, HP_LOOP, HP_SR);
  snprintf(path, sizeof(path), "%s/heard.wav", loops);
  heard_write_wav_stereo(path, pairs, HP_LOOP, HP_SR);
  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": 1, "
           "\"tracks\": [{\"channel\": 0, \"lanes\": [{\"lane\": 0, "
           "\"deferred\": false, \"pcmRef\": \"loops/clean.wav\", "
           "\"heardPcmRef\": \"loops/heard.wav\"}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": [%s]}",
           HP_SR, (unsigned long long)capture_frames, layers);
  test_write_manifest(dir, manifest);
  snprintf(path, sizeof(path), "%s/events.log", dir);
  FILE* lf = fopen(path, "wb");
  CHECK(lf != NULL);
  if (lf == NULL) return NULL;
  test_write_log_header(lf, HP_SR, LE_TEST_EVENTS_VERSION);
  test_write_log_entry(
      lf, 0,
      (le_command){.code = LE_PLOG_PERF_ARMED,
                   .perf_arm = {.position = 0, .master_len = HP_LOOP,
                                .iteration = 0}});
  return lf;
}

/* The dry stem is the clean takes and the wet stem the heard images (their
 * sides' mean): the arm image's from frame 0, then a retired layer's from
 * its logged retire, read from the heard section after its clean lanes. */
static void test_heard_perf_wet_stem_plays_the_images(void) {
  printf("test_heard_perf_wet_stem_plays_the_images\n");
  enum { CAP = 64, RETIRE = 24 };
  const char* dir = heard_perf_dir("heard-layers");
  float layer[3 * HP_LOOP];
  for (int i = 0; i < HP_LOOP; ++i) {
    layer[i] = 1.0f;                    /* clean */
    layer[HP_LOOP + 2 * i] = 0.6f;      /* heard L */
    layer[HP_LOOP + 2 * i + 1] = 0.2f;  /* heard R */
  }
  char path[700];
  snprintf(path, sizeof(path), "%s/layer-heard.pcm", dir);
  FILE* pf = fopen(path, "wb");
  CHECK(pf != NULL);
  if (pf != NULL) {
    fwrite(layer, sizeof(float), 3 * HP_LOOP, pf);
    fclose(pf);
  }
  char layers[400];
  snprintf(layers, sizeof(layers),
           "{\"channel\": 0, \"slot\": 1, \"generation\": 0, \"frame\": %d, "
           "\"frame_count\": %d, \"lane_count\": 1, \"kind\": 0, "
           "\"restore_id\": 0, \"filename\": \"layer-heard.pcm\", "
           "\"heard_mask\": 1}",
           RETIRE, HP_LOOP);
  FILE* lf = heard_perf_fixture(dir, CAP, layers);
  if (lf != NULL) {
    test_write_log_entry(
        lf, RETIRE,
        (le_command){.code = LE_PLOG_LAYER_RETIRED,
                     .evt = {.channel = 0, .slot = 1, .generation = 0}});
    fclose(lf);
  }
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);
  int32_t channel = -1, ok = 0;
  CHECK(le_perf_render_track_status(e, 0, &channel, &ok) == LE_OK);
  CHECK(channel == 0 && ok == 1);
  float dry[CAP];
  float wet[CAP];
  CHECK(test_read_stem(dir, 0, dry, CAP) == CAP);
  CHECK(test_read_wet_stem(dir, 0, wet, CAP) == CAP);
  for (int f = 0; f < CAP; ++f) {
    CHECK(fabsf(dry[f] - (f < RETIRE ? 0.5f : 1.0f)) < 1e-6f);
    CHECK(fabsf(wet[f] - (f < RETIRE ? 0.2f : 0.4f)) < 1e-6f);
  }
  le_engine_destroy(e);
}

/* A logged source switch crossfades the wet stem over 10 ms, as the rig
 * does: from the image to the clean take through its (empty) chain, and
 * back; an image its renders cannot play yet fades to the clean take the
 * same way. */
static void test_heard_perf_source_switch(void) {
  printf("test_heard_perf_source_switch\n");
  enum {
    CAP = 240,
    TO_CLEAN = 16,
    TO_HEARD = 120,
    UNAVAILABLE = 200,
    XF = HP_SR / 100
  };
  const char* dir = heard_perf_dir("heard-source");
  FILE* lf = heard_perf_fixture(dir, CAP, "");
  if (lf != NULL) {
    test_write_log_entry(lf, TO_CLEAN,
                         (le_command){.code = LE_PLOG_HEARD_SOURCE,
                                      .lanei = {0, 0, 0}});
    test_write_log_entry(lf, TO_HEARD,
                         (le_command){.code = LE_PLOG_HEARD_SOURCE,
                                      .lanei = {0, 0, 1}});
    test_write_log_entry(lf, UNAVAILABLE,
                         (le_command){.code = LE_PLOG_HEARD_SOURCE,
                                      .lanei = {0, 0, 2}});
    fclose(lf);
  }
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);
  float wet[CAP];
  CHECK(test_read_wet_stem(dir, 0, wet, CAP) == CAP);
  for (int f = 0; f < CAP; ++f) {
    if (f < TO_CLEAN || (f >= TO_HEARD + XF && f < UNAVAILABLE)) {
      CHECK(fabsf(wet[f] - 0.2f) < 1e-5f);
    } else if ((f >= TO_CLEAN + XF && f < TO_HEARD) ||
               f >= UNAVAILABLE + XF) {
      CHECK(fabsf(wet[f] - 0.5f) < 1e-5f);
    } else {
      CHECK(wet[f] > 0.2f - 1e-5f && wet[f] < 0.5f + 1e-5f);
    }
  }
  CHECK(wet[TO_CLEAN + XF / 2] > 0.3f && wet[TO_CLEAN + XF / 2] < 0.4f);
  le_engine_destroy(e);
}

/* A live capture: an overdub through the reverb on a heard take retires a
 * layer whose file carries its heard image after the clean lane (and the
 * manifest says so), and events.log names the lane's source at the arm and
 * at a switch. */
static void test_heard_perf_capture_stages_images(void) {
  printf("test_heard_perf_capture_stages_images\n");
  enum { N = 4800 };
  const char* dir = heard_perf_dir("heard-capture");
  le_engine* e = heard_take_fixture(N, 31);
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  heard_silence(e, 256, 64, NULL);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, 2 * N, 64, NULL);
  settle_layers(e);
  CHECK(le_engine_set_lane_source(e, 0, 0, LE_LANE_SOURCE_CLEAN) == LE_OK);
  heard_silence(e, 256, 64, NULL);
  CHECK(le_perf_disarm(e) == LE_OK);

  char path[760];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  static char json[65536];
  const size_t jn = read_binary_file_for_test(path, (unsigned char*)json,
                                              sizeof(json) - 1);
  json[jn] = '\0';
  const char* hm = strstr(json, "\"heard_mask\": 1");
  CHECK(hm != NULL);
  /* That layer's own entry: back to its opening brace. */
  const char* open = hm;
  while (open > json && *open != '{') --open;
  int frame_count = 0, lane_count = 0;
  char filename[64] = {0};
  const char* fc = strstr(open, "\"frame_count\": ");
  const char* lc = strstr(open, "\"lane_count\": ");
  const char* fnm = strstr(open, "\"filename\": \"");
  CHECK(fc != NULL && lc != NULL && fnm != NULL && fnm < hm);
  if (fc != NULL && lc != NULL && fnm != NULL) {
    sscanf(fc, "\"frame_count\": %d", &frame_count);
    sscanf(lc, "\"lane_count\": %d", &lane_count);
    sscanf(fnm, "\"filename\": \"%63[^\"]", filename);
  }
  CHECK(frame_count == N && lane_count == 1);
  snprintf(path, sizeof(path), "%s/%s", dir, filename);
  static float file[3 * N + 1];
  const size_t got = read_binary_file_for_test(path, (unsigned char*)file,
                                               sizeof(file));
  CHECK(got == 3 * (size_t)N * sizeof(float)); /* clean, then (L, R) */
  /* The heard section is the layer's image: an image the reverb made,
   * whose sides differ from each other and from the clean take. */
  double side_diff = 0.0;
  double clean_diff = 0.0;
  for (int i = 0; i < N && got == 3 * (size_t)N * sizeof(float); ++i) {
    side_diff += fabs((double)file[N + 2 * i] - (double)file[N + 2 * i + 1]);
    clean_diff += fabs((double)file[N + 2 * i] - (double)file[i]);
  }
  CHECK(side_diff > 1e-3 && clean_diff > 1e-3);

  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char buf[1 << 20];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  le_perf_log_entry entry;
  const int first = find_log_entry(buf, count, 0, LE_PLOG_HEARD_SOURCE, &entry);
  CHECK(first >= 0);
  CHECK(entry.cmd.lanei.channel == 0 && entry.cmd.lanei.lane == 0 &&
        entry.cmd.lanei.value == 1);
  const int second =
      find_log_entry(buf, count, first + 1, LE_PLOG_HEARD_SOURCE, &entry);
  CHECK(second > first);
  CHECK(entry.cmd.lanei.value == 0);
  le_engine_destroy(e);
}

/* A take finalized during the capture plays its image at level from its
 * RECORD_END, as the callback's lane does (it crossfaded in while it
 * recorded), with no fade from the clean take; and a heard WAV whose length
 * differs from the clean take's fails the stem. */
static void test_heard_perf_fresh_take(void) {
  printf("test_heard_perf_fresh_take\n");
  enum { CAP = 64, END = 8 };
  for (int bad = 0; bad < 2; ++bad) {
    const char* dir = heard_perf_dir(bad ? "heard-fresh-bad" : "heard-fresh");
    char loops[700];
    snprintf(loops, sizeof(loops), "%s/loops", dir);
    test_render_mkdir(loops);
    float clean[HP_LOOP];
    float pairs[2 * (HP_LOOP + 1)];
    for (int i = 0; i < HP_LOOP + 1; ++i) {
      if (i < HP_LOOP) clean[i] = 0.5f;
      pairs[2 * i] = 0.3f;
      pairs[2 * i + 1] = 0.1f;
    }
    char path[760];
    snprintf(path, sizeof(path), "%s/clean.wav", loops);
    test_write_wav_mono(path, clean, HP_LOOP, HP_SR);
    snprintf(path, sizeof(path), "%s/heard.wav", loops);
    heard_write_wav_stereo(path, pairs, HP_LOOP + bad, HP_SR);
    char manifest[2048];
    snprintf(manifest, sizeof(manifest),
             "{\"sample_rate\": %d, \"capture_frames\": %d, "
             "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": 1, "
             "\"tracks\": []}, "
             "\"disarmSnapshot\": {\"tracks\": [{\"channel\": 0, \"lanes\": "
             "[{\"lane\": 0, \"deferred\": false, \"takeId\": 1, "
             "\"pcmRef\": \"loops/clean.wav\", "
             "\"heardPcmRef\": \"loops/heard.wav\"}]}]}, \"layers\": []}",
             HP_SR, CAP);
    test_write_manifest(dir, manifest);
    snprintf(path, sizeof(path), "%s/events.log", dir);
    FILE* lf = fopen(path, "wb");
    CHECK(lf != NULL);
    if (lf == NULL) return;
    test_write_log_header(lf, HP_SR, LE_TEST_EVENTS_VERSION);
    test_write_log_entry(lf, END,
                         (le_command){.code = LE_PLOG_RECORD_END,
                                      .take = {.channel = 0, .take_id = 1}});
    fclose(lf);
    le_engine* e = le_engine_create();
    CHECK(le_perf_render_begin(e, dir) == LE_OK);
    test_wait_for_render(e, 2000);
    int32_t channel = -1, ok = 0;
    CHECK(le_perf_render_track_status(e, 0, &channel, &ok) == LE_OK);
    CHECK(ok == !bad);
    if (!bad) {
      float wet[CAP];
      CHECK(test_read_wet_stem(dir, 0, wet, CAP) == CAP);
      for (int f = END; f < CAP; ++f) CHECK(fabsf(wet[f] - 0.2f) < 1e-6f);
    }
    le_engine_destroy(e);
  }
}

static void run_heard_perf_tests(void) {
  test_heard_perf_wet_stem_plays_the_images();
  test_heard_perf_source_switch();
  test_heard_perf_fresh_take();
  test_heard_perf_capture_stages_images();
}
