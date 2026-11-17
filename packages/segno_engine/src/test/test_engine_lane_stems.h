/* #1824 (part of #1806): every lane of a track has its own performance
 * stems. A real capture through the public API of one track with three
 * lanes, each recording its own input: a take on two lanes, a delay and a
 * volume on lane 1 and a mute and unmute of it, an overdub pass, two lanes
 * added while the track plays, the fourth routed to no input, which the
 * engine removes again (it removes only a lane that holds nothing), and
 * three more passes. The monitors are muted, so the captured master is the
 * track's own output.
 *
 * The same take is played again with only one input carrying signal: its
 * master is then that lane's contribution alone, and the lane's wet stem
 * from the full take must equal it. The rendered master (the lanes' wet
 * stems summed through their routes) must equal the captured one. Both
 * within the 1e-5 the overdub replay holds (#1813). Included by
 * test_engine_core.c after test_engine_heard_perf.h (its stereo WAV writer). */

#define LST_LEN 4096
#define LST_BLOCK 64
#define LST_INPUTS 3
#define LST_OFFSET 100

typedef struct lst_signal {
  double cycles_per_frame;
  float amp;
  double phase;
} lst_signal;

/* Pumps `frames` of one signal per input ([sig] NULL: silence) in
 * LST_BLOCK blocks, draining the control side after each block. With
 * [only] >= 0 every other input is silent, while every signal still
 * advances, so each take hears the same signals at the same frames. */
static void lst_pump(le_engine* e, lst_signal* sig, int only, int frames) {
  float in[LST_BLOCK * LST_INPUTS];
  float out[LST_BLOCK];
  while (frames > 0) {
    const int n = frames > LST_BLOCK ? LST_BLOCK : frames;
    for (int i = 0; i < n; ++i) {
      for (int c = 0; c < LST_INPUTS; ++c) {
        float v = 0.0f;
        if (sig != NULL) {
          v = sig[c].amp *
              sinf((float)(2.0 * 3.14159265358979 * sig[c].phase));
          sig[c].phase += sig[c].cycles_per_frame;
          if (sig[c].phase >= 1.0) sig[c].phase -= 1.0;
        }
        in[i * LST_INPUTS + c] = only < 0 || only == c ? v : 0.0f;
      }
    }
    le_engine_process(e, out, in, (uint32_t)n);
    le_engine_drain_events(e);
    frames -= n;
  }
}

/* Appends the arm and disarm snapshots the Dart side writes to the
 * drain's performance.json: at arm the track is empty with two lanes, at
 * disarm it plays three, but lists two: a lane added after the take keeps
 * a length of 0 (#1825), which the snapshot skips. */
static void lst_finalize_manifest(const char* dir, int32_t take_id) {
  char path[700];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  char* json = malloc(1024 * 1024);
  CHECK(json != NULL);
  if (json == NULL) return;
  const size_t n = read_file_for_test(path, json, 1024 * 1024 - 1);
  CHECK(n > 0);
  json[n] = '\0';
  char* end = strrchr(json, '}');
  CHECK(end != NULL);
  FILE* f = end != NULL ? fopen(path, "wb") : NULL;
  CHECK(f != NULL);
  if (f != NULL) {
    fwrite(json, 1, (size_t)(end - json), f);
    fprintf(f,
            ",\"armSnapshot\":{\"followOutput\":false,\"captureMask\":1,"
            "\"outputEnabledMask\":1,\"latencyOffsetFrames\":%d,"
            "\"tracks\":[{\"channel\":0,\"state\":\"empty\",\"volume\":1,"
            "\"muted\":false,\"lanes\":["
            "{\"lane\":0,\"lenFrames\":0,\"deferred\":true,\"volume\":1,"
            "\"pan\":0,\"muted\":false,\"outputMask\":3},"
            "{\"lane\":1,\"lenFrames\":0,\"deferred\":true,\"volume\":1,"
            "\"pan\":0,\"muted\":false,\"outputMask\":3}]}]},"
            "\"disarmSnapshot\":{\"tracks\":[{\"channel\":0,"
            "\"state\":\"playing\",\"volume\":1,\"muted\":false,\"lanes\":["
            "{\"lane\":0,\"lenFrames\":%d,\"deferred\":false,\"takeId\":%d,"
            "\"pcmRef\":\"track0-lane0.wav\"},"
            "{\"lane\":1,\"lenFrames\":%d,\"deferred\":false,"
            "\"pcmRef\":\"track0-lane1.wav\"}]}]}}",
            LST_OFFSET, LST_LEN, take_id, LST_LEN);
    CHECK(fclose(f) == 0);
  }
  free(json);
}

/* Plays the take with every input ([only] -1) or one, and returns its
 * captured master (*frames long, the caller frees). The full take also
 * writes the disarm snapshot and renders. */
static float* lst_run(const char* name, int only, uint64_t* frames) {
  *frames = 0;
  const char* dir = render_test_dir(name);
  const int32_t sr = 48000;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, LST_INPUTS, 1, sr) == LE_OK);
  CHECK(le_perf_set_follow_output(e, 0) == LE_OK);
  for (int c = 0; c < LST_INPUTS; ++c) {
    CHECK(le_engine_set_monitor_input_mute(e, c, 1) == LE_OK);
  }
  CHECK(le_engine_set_record_offset(e, LST_OFFSET) == LE_OK);
  CHECK(le_engine_set_rec_dub(e, 0) == LE_OK);
  CHECK(le_engine_set_overdub_feedback(e, 1.0f) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 0, 2) == LE_OK);

  /* Whole cycles per loop, so each signal tiles the loop. */
  lst_signal take[LST_INPUTS] = {
      {3.0 / LST_LEN, 0.30f, 0.0},
      {5.0 / LST_LEN, 0.25f, 0.0},
      {11.0 / LST_LEN, 0.20f, 0.0},
  };
  /* The last pass leaves the third lane as it was: the disarm snapshot
   * does not list it (see lst_finalize_manifest), so its last pass's result
   * is not in the capture, and the renderer keeps what it played. */
  lst_signal last[LST_INPUTS] = {
      {19.0 / LST_LEN, 0.10f, 0.0},
      {23.0 / LST_LEN, 0.10f, 0.0},
      {29.0 / LST_LEN, 0.0f, 0.0},
  };
  lst_signal dub[LST_INPUTS] = {
      {7.0 / LST_LEN, 0.15f, 0.0},
      {13.0 / LST_LEN, 0.12f, 0.0},
      {17.0 / LST_LEN, 0.18f, 0.0},
  };


  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);
  lst_pump(e, NULL, only, 300);

  /* The take, on lanes 0 and 1: it defines the loop. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, take, only, LST_LEN);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize */
  lst_pump(e, take, only, sr / 100);      /* the seam crossfade */
  lst_pump(e, NULL, only, 500);

  /* Lane 1: quieter and through a delay, then muted for a while. */
  CHECK(le_engine_set_lane_volume(e, 0, 1, 0.7f) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 1, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 1, 1, 0) == LE_OK);
  lst_pump(e, NULL, only, LST_LEN);
  CHECK(le_engine_set_lane_mute(e, 0, 1, 1) == LE_OK);
  lst_pump(e, NULL, only, 1500);
  CHECK(le_engine_set_lane_mute(e, 0, 1, 0) == LE_OK);
  lst_pump(e, NULL, only, 1000);

  /* A pass over the two lanes, punched in and out mid-cycle. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, dub, only, LST_LEN / 2);
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, dub, only, sr / 100); /* the punch-out fade */
  lst_pump(e, NULL, only, LST_LEN + 300);
  settle_layers(e);

  /* Two lanes while the track plays, empty until a pass reaches them. The
   * fourth is routed to no input and so held nothing: the engine removes
   * it again (le_trim_trailing_lanes). */
  CHECK(le_engine_set_lane_count(e, 0, 4) == LE_OK);
  lst_pump(e, NULL, only, 700);
  CHECK(le_engine_set_lane_input(e, 0, 3, -1) == LE_OK);
  CHECK(le_engine_set_lane_volume(e, 0, 2, 0.5f) == LE_OK);
  lst_pump(e, NULL, only, 400);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].lane_count == 3);

  /* Two more passes over the lanes. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, dub, only, LST_LEN / 2 + 300);
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, dub, only, sr / 100);
  lst_pump(e, NULL, only, LST_LEN + 200);
  settle_layers(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, last, only, LST_LEN / 3);
  CHECK(le_engine_record(e, 0) == LE_OK);
  lst_pump(e, last, only, sr / 100);
  lst_pump(e, NULL, only, 2 * LST_LEN);
  settle_layers(e);

  lst_pump(e, NULL, only, LST_LEN + 333);

  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].lane_count == 3);
  CHECK(snap.perf_overruns == 0);
  *frames = (uint64_t)snap.perf_frames;
  char path[700];
  if (only < 0) {
    float lane[LST_LEN];
    for (int32_t l = 0; l < 2; ++l) {
      CHECK(le_engine_export_track_lane(e, 0, l, lane, LST_LEN) == LST_LEN);
      snprintf(path, sizeof(path), "%s/track0-lane%d.wav", dir, l);
      test_write_wav_mono(path, lane, LST_LEN, sr);
    }
  }
  const int32_t take_id = snap.tracks[0].settled_take_id;
  CHECK(le_perf_disarm(e) == LE_OK);

  float* master = calloc((size_t)*frames, sizeof(float));
  CHECK(master != NULL);
  snprintf(path, sizeof(path), "%s/master-001.wav", dir);
  FILE* mf = perf_fopen_payload(path);
  CHECK(mf != NULL);
  if (mf != NULL && master != NULL) {
    CHECK(fread(master, sizeof(float), (size_t)*frames, mf) == *frames);
  }
  if (mf != NULL) fclose(mf);

  if (only < 0) {
    lst_finalize_manifest(dir, take_id);
    CHECK(le_perf_render_begin(e, dir) == LE_OK);
    test_wait_for_render(e, 20000);
    int32_t done = 0, track_count = 0;
    CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
    CHECK(done == 1 && track_count == 1);
    int32_t channel = -1, succeeded = 0;
    CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
    CHECK(channel == 0 && succeeded == 1);
  }
  le_engine_destroy(e);
  return master;
}

/* The largest difference between [a] and [b] over [frames], and where. */
static float lst_diff(const float* a, const float* b, uint64_t frames,
                      uint64_t* at) {
  float worst = 0.0f;
  *at = 0;
  for (uint64_t f = 0; f < frames; ++f) {
    const float d = fabsf(a[f] - b[f]);
    if (d > worst) {
      worst = d;
      *at = f;
    }
  }
  return worst;
}

static float lst_peak(const float* x, uint64_t from, uint64_t to) {
  float peak = 0.0f;
  for (uint64_t f = from; f < to; ++f) {
    if (fabsf(x[f]) > peak) peak = fabsf(x[f]);
  }
  return peak;
}

static void test_lane_stems_match_live(void) {
  printf("test_lane_stems_match_live\n");
  uint64_t frames = 0;
  float* live = lst_run("lst-all", -1, &frames);
  char dir[700]; /* render_test_dir's buffer is reused by the next run */
  snprintf(dir, sizeof(dir), "%s", render_test_dir("lst-all"));
  float* alone[LST_INPUTS] = {NULL};
  for (int c = 0; c < LST_INPUTS; ++c) {
    char name[32];
    snprintf(name, sizeof(name), "lst-only%d", c);
    uint64_t n = 0;
    alone[c] = lst_run(name, c, &n);
    CHECK(n == frames); /* the same take, frame for frame */
  }
  float* dry = calloc((size_t)frames, sizeof(float));
  float* wet = calloc((size_t)frames, sizeof(float));
  float* master = calloc((size_t)frames, sizeof(float));
  CHECK(live != NULL && dry != NULL && wet != NULL && master != NULL);
  if (live == NULL || dry == NULL || wet == NULL || master == NULL) {
    goto done;
  }
  CHECK(lst_peak(live, 0, frames) > 0.3f); /* the lanes are in the master */

  char path[700];
  for (int32_t l = 0; l < LST_INPUTS; ++l) {
    /* Each lane's wet stem is what it alone sent to the master. */
    snprintf(path, sizeof(path), "%s/stems/wet/track0-lane%d.wav", dir, l);
    CHECK(test_read_wav_fixed(path, wet, (int32_t)frames) == (int32_t)frames);
    CHECK(lst_peak(alone[l], 0, frames) > 0.05f);
    uint64_t at = 0;
    const float d = lst_diff(wet, alone[l], frames, &at);
    if (d >= 1e-5f) {
      printf("    lane %d wet vs its live part: max diff %.7f at frame %llu\n",
             l, (double)d, (unsigned long long)at);
    }
    CHECK(d < 1e-5f);
  }

  /* Lane 0 plays at unity with no effect: its dry stem is its part too. */
  snprintf(path, sizeof(path), "%s/stems/dry/track0-lane0.wav", dir);
  CHECK(test_read_wav_fixed(path, dry, (int32_t)frames) == (int32_t)frames);
  uint64_t at = 0;
  CHECK(lst_diff(dry, alone[0], frames, &at) < 1e-5f);

  /* Lane 2 is silent until a pass reached it, then plays what it took. */
  snprintf(path, sizeof(path), "%s/stems/dry/track0-lane2.wav", dir);
  CHECK(test_read_wav_fixed(path, dry, (int32_t)frames) == (int32_t)frames);
  CHECK(lst_peak(dry, 0, 3 * LST_LEN) == 0.0f);
  CHECK(lst_peak(dry, frames - LST_LEN, frames) > 0.1f);
  /* Lane 3 recorded nothing. */
  snprintf(path, sizeof(path), "%s/stems/wet/track0-lane3.wav", dir);
  CHECK(test_read_wav_fixed(path, wet, (int32_t)frames) == (int32_t)frames);
  CHECK(lst_peak(wet, 0, frames) == 0.0f);

  /* The lanes summed through their mix are the track's master. */
  snprintf(path, sizeof(path), "%s/stems/wet/master.wav", dir);
  CHECK(test_read_wav_fixed(path, master, (int32_t)frames) == (int32_t)frames);
  const float d = lst_diff(master, live, frames, &at);
  if (d >= 1e-5f) {
    printf("    rendered vs captured master: max diff %.7f at frame %llu\n",
           (double)d, (unsigned long long)at);
  }
  CHECK(d < 1e-5f);

  /* The index names every lane's two stems. */
  snprintf(path, sizeof(path), "%s/stems/stems.json", dir);
  static char index[4096];
  const size_t n = read_file_for_test(path, index, sizeof(index) - 1);
  CHECK(n > 0);
  index[n] = '\0';
  CHECK(strcmp(index,
               "{\"version\":1,\"lanes\":["
               "{\"channel\":0,\"lane\":0,"
               "\"dry\":\"stems/dry/track0-lane0.wav\","
               "\"wet\":\"stems/wet/track0-lane0.wav\"},"
               "{\"channel\":0,\"lane\":1,"
               "\"dry\":\"stems/dry/track0-lane1.wav\","
               "\"wet\":\"stems/wet/track0-lane1.wav\"},"
               "{\"channel\":0,\"lane\":2,"
               "\"dry\":\"stems/dry/track0-lane2.wav\","
               "\"wet\":\"stems/wet/track0-lane2.wav\"},"
               "{\"channel\":0,\"lane\":3,"
               "\"dry\":\"stems/dry/track0-lane3.wav\","
               "\"wet\":\"stems/wet/track0-lane3.wav\"}]}\n") == 0);

done:
  for (int c = 0; c < LST_INPUTS; ++c) free(alone[c]);
  free(live);
  free(dry);
  free(wet);
  free(master);
}

/* A track the log gives no lane count (a capture from before events.log
 * 17) mixes every lane the snapshots and layers name, throughout. Lane 1
 * plays its heard image (#1713) in its wet stem, and its clean take in its
 * dry one. */
static void test_lane_stems_without_logged_count(void) {
  printf("test_lane_stems_without_logged_count\n");
  const char* dir = render_test_dir("lst-unlogged");
  const int32_t sr = 4800;
  const int32_t len = 480;
  const uint64_t frames = 1000;
  char path[700];
  float lane[480];
  for (int32_t l = 0; l < 2; ++l) {
    for (int32_t i = 0; i < len; ++i) lane[i] = 0.1f * (float)(l + 1);
    snprintf(path, sizeof(path), "%s/track0-lane%d.wav", dir, l);
    test_write_wav_mono(path, lane, len, sr);
  }
  static float pairs[2 * 480];
  for (int32_t i = 0; i < len; ++i) {
    pairs[2 * i] = 0.5f;
    pairs[2 * i + 1] = 0.3f;
  }
  snprintf(path, sizeof(path), "%s/track0-lane1-heard.wav", dir);
  heard_write_wav_stereo(path, pairs, len, sr);
  snprintf(path, sizeof(path), "%s/events.log", dir);
  FILE* lf = fopen(path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    const uint32_t version = 16;
    fwrite("PLEV", 1, 4, lf);
    fwrite(&version, 4, 1, lf);
    fwrite(&sr, 4, 1, lf);
    unsigned char entry[28] = {0};
    const int32_t code = LE_PLOG_PERF_ARMED;
    memcpy(entry + 8, &code, 4);
    memcpy(entry + 16, &len, 4); /* perf_arm.master_len */
    fwrite(entry, 1, sizeof(entry), lf);
    CHECK(fclose(lf) == 0);
  }
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f != NULL) {
    fprintf(f,
            "{\"sample_rate\":%d,\"capture_frames\":%llu,"
            "\"armSnapshot\":{\"followOutput\":false,\"captureMask\":1,"
            "\"tracks\":[{\"channel\":0,\"state\":\"playing\",\"volume\":1,"
            "\"lanes\":["
            "{\"lane\":0,\"pcmRef\":\"track0-lane0.wav\",\"outputMask\":1},"
            "{\"lane\":1,\"pcmRef\":\"track0-lane1.wav\","
            "\"heardPcmRef\":\"track0-lane1-heard.wav\","
            "\"outputMask\":1}]}]}}",
            sr, (unsigned long long)frames);
    CHECK(fclose(f) == 0);
  }
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 20000);
  int32_t done = 0, count = 0, succeeded = 0, channel = -1;
  CHECK(le_perf_render_poll(e, &done, NULL, &count) == LE_OK);
  CHECK(done == 1 && count == 1);
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(succeeded == 1);
  static float stem[1000];
  for (int32_t l = 0; l < 2; ++l) {
    snprintf(path, sizeof(path), "%s/stems/dry/track0-lane%d.wav", dir, l);
    CHECK(test_read_wav_fixed(path, stem, (int32_t)frames) == (int32_t)frames);
    CHECK(fabsf(stem[frames - 1] - 0.1f * (float)(l + 1)) < 1e-6f);
  }
  snprintf(path, sizeof(path), "%s/stems/wet/track0-lane1.wav", dir);
  CHECK(test_read_wav_fixed(path, stem, (int32_t)frames) == (int32_t)frames);
  CHECK(fabsf(stem[frames - 1] - 0.4f) < 1e-6f); /* (0.5 + 0.3) / 2 */
  /* The master holds both lanes. */
  snprintf(path, sizeof(path), "%s/stems/wet/master.wav", dir);
  CHECK(test_read_wav_fixed(path, stem, (int32_t)frames) == (int32_t)frames);
  CHECK(fabsf(stem[frames - 1] - 0.5f) < 1e-6f);
  le_engine_destroy(e);
}

static void run_lane_stems_tests(void) {
  test_lane_stems_match_live();
  test_lane_stems_without_logged_count();
}
