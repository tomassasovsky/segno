/* #1808 (Part 1 of #1806): a performance stem of an overdubbed loop against
 * what the live engine played. A real capture through the public API: a
 * take, overdub passes of different sines, a punch-out mid-cycle, then Undo,
 * Redo, Clear, Clear Undo and the disarm. The monitor is muted and no effect
 * runs, so the captured master is the track's own dry output, and the
 * rendered dry stem must equal it sample for sample. On a mismatch the test
 * prints which image each one played when. Included by test_engine_core.c
 * after test_engine_history_replay.h. */

#define ODR_LEN 4096
#define ODR_BLOCK 64
#define ODR_MAX_IMAGES 4

typedef struct odr_signal {
  double cycles_per_frame;
  float amp;
  double phase;
} odr_signal;

typedef struct odr_case {
  const char* name;
  int32_t channel; /* 0, or 1 over a muted defining take on track 0 */
  int rec_dub;     /* 1: the take goes straight on into its first pass */
  int32_t offset;  /* the record offset */
  int passes;      /* 2, or 1 punched out inside its first lap */
  float feedback;  /* 1 adds each pass, 0 replaces */
  int before_arm;  /* 1: the take is recorded before the capture arms */
} odr_case;

/* Pumps `frames` of `sig` (silence when amp is 0) in ODR_BLOCK blocks,
 * draining the control side after each block as the snapshot poll does, so
 * shadows are replenished and retired layers staged while the take runs. */
static void odr_pump(le_engine* e, odr_signal* sig, int frames) {
  float in[ODR_BLOCK];
  float out[ODR_BLOCK];
  while (frames > 0) {
    const int n = frames > ODR_BLOCK ? ODR_BLOCK : frames;
    for (int i = 0; i < n; ++i) {
      in[i] = sig->amp * sinf((float)(2.0 * 3.14159265358979 * sig->phase));
      sig->phase += sig->cycles_per_frame;
      if (sig->phase >= 1.0) sig->phase -= 1.0;
    }
    le_engine_process(e, out, in, (uint32_t)n);
    le_engine_drain_events(e);
    frames -= n;
  }
}

/* Reads the drain's performance.json, appends the arm and disarm snapshots
 * the Dart side writes (track 0's too when [channel] is another, with
 * `take0`, its settled take), and returns [channel]'s kind-0 layer files in
 * retire order through `names` (at most `cap`). */
static int odr_finalize_manifest(const char* dir, int32_t channel,
                                 int32_t offset, int32_t take_id,
                                 int32_t take0, int arm_image,
                                 char names[][64], int cap) {
  char path[700];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  char* json = malloc(1024 * 1024);
  CHECK(json != NULL);
  if (json == NULL) return 0;
  const size_t n = read_file_for_test(path, json, 1024 * 1024 - 1);
  CHECK(n > 0);
  json[n] = '\0';
  int found = 0;
  static le_json_value nodes[4096];
  le_json_arena arena;
  arena.nodes = nodes;
  arena.capacity = 4096;
  arena.used = 0;
  char* copy = malloc(n + 1);
  CHECK(copy != NULL);
  if (copy != NULL) {
    memcpy(copy, json, n + 1);
    const le_json_value* root = le_json_parse(copy, &arena);
    CHECK(root != NULL);
    const le_json_value* layers = le_json_get(root, "layers");
    for (int i = 0; i < le_json_length(layers) && found < cap; ++i) {
      const le_json_value* v = le_json_at(layers, i);
      if (le_json_number(le_json_get(v, "kind"), -1) != 0) continue;
      if (le_json_number(le_json_get(v, "channel"), -1) != channel) continue;
      if (le_json_string(le_json_get(v, "filename"), names[found], 64)) {
        ++found;
      }
    }
    free(copy);
  }
  char* end = strrchr(json, '}');
  CHECK(end != NULL);
  if (end != NULL) {
    FILE* f = fopen(path, "wb");
    CHECK(f != NULL);
    if (f != NULL) {
      fwrite(json, 1, (size_t)(end - json), f);
      fprintf(f,
              ",\"armSnapshot\":{\"followOutput\":false,\"captureMask\":1,"
              "\"latencyOffsetFrames\":%d,\"tracks\":[",
              offset);
      if (arm_image) {
        fprintf(f,
                "{\"channel\":%d,\"lanes\":[{\"lane\":0,\"deferred\":false,"
                "\"pcmRef\":\"track%d-arm.wav\"}]}",
                channel, channel);
      }
      fprintf(f, "]},\"disarmSnapshot\":{\"tracks\":[");
      /* Track 0 too when the take is on another track: it defines the
       * loop and the master holds both. */
      for (int32_t t = 0; t <= channel; ++t) {
        if (t != 0 && t != channel) continue;
        fprintf(f,
                "%s{\"channel\":%d,\"volume\":1,\"muted\":false,"
                "\"lanes\":[{\"lane\":0,\"deferred\":false,"
                "\"takeId\":%d,\"pcmRef\":\"track%d-lane0.wav\","
                "\"effects\":[]}]}",
                t == 0 ? "" : ",", t,
                t == channel ? take_id : take0, t);
      }
      fprintf(f, "]}}");
      CHECK(fclose(f) == 0);
    }
  }
  free(json);
  return found;
}

/* Which of `images` (count, each ODR_LEN frames) `x` plays over frames
 * [f, f + w), reading image index (anchor_pos + frame - anchor) mod ODR_LEN:
 * a mask of the images it matches (images that agree there all match), 0
 * for silence, -1 for none of them. */
static int odr_classify(const float* x, uint64_t f, int w,
                        float* const* images, int count, uint64_t anchor,
                        int32_t anchor_pos) {
  float peak = 0.0f;
  for (int i = 0; i < w; ++i) {
    if (fabsf(x[f + (uint64_t)i]) > peak) peak = fabsf(x[f + (uint64_t)i]);
  }
  if (peak < 1e-6f) return 0;
  int mask = 0;
  for (int k = 0; k < count; ++k) {
    int match = 1;
    for (int i = 0; i < w && match; ++i) {
      const uint64_t at = f + (uint64_t)i;
      const int64_t p =
          ((int64_t)anchor_pos + (int64_t)(at - anchor)) % ODR_LEN;
      if (fabsf(x[at] - images[k][p < 0 ? p + ODR_LEN : p]) > 1e-5f) {
        match = 0;
      }
    }
    if (match) mask |= 1 << k;
  }
  return mask != 0 ? mask : -1;
}

/* The images a classification names: the take, then each pass's result. */
static const char* odr_name(int mask) {
  static char buf[2][40];
  static int next = 0;
  char* out = buf[next++ % 2];
  if (mask < 0) return "(mixed)";
  if (mask == 0) return "silence";
  out[0] = '\0';
  for (int k = 0; k < ODR_MAX_IMAGES; ++k) {
    if (!(mask & (1 << k))) continue;
    char part[16];
    if (k == 0) {
      snprintf(part, sizeof(part), "take");
    } else {
      snprintf(part, sizeof(part), "pass%d", k);
    }
    if (out[0] != '\0') strcat(out, "=");
    strcat(out, part);
  }
  return out;
}

/* Prints which image the master and the stem play, a 64-frame window at a
 * time, reading the loop position from the lock and then each 322. */
static void odr_print_timeline(const char* dir, const float* live,
                               const float* stem, uint64_t frames,
                               float* const* images, int count) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char logbuf[1 << 20];
  const size_t entries = log_entry_count(
      read_binary_file_for_test(path, logbuf, sizeof(logbuf)));
  uint64_t anchors[16];
  int32_t anchor_pos[16];
  int anchor_n = 0;
  for (size_t i = 0; i < entries && anchor_n < 16; ++i) {
    le_perf_log_entry entry;
    decode_log_entry_at(logbuf, i, &entry);
    if (entry.cmd.code == LE_PLOG_LOOP_LENGTH_LOCKED) {
      anchors[anchor_n] = entry.frame;
      anchor_pos[anchor_n++] = 0;
    } else if (entry.cmd.code == LE_PLOG_SOURCE_APPLIED) {
      anchors[anchor_n] = entry.frame;
      anchor_pos[anchor_n++] = entry.cmd.restore_log.phase;
    }
  }
  if (anchor_n == 0) return;
  int last_live = 99, last_stem = 99;
  uint64_t run_start = 0;
  for (uint64_t f = 0; f + 64 <= frames; f += 64) {
    int a = 0;
    for (int k = 0; k < anchor_n; ++k) {
      if (anchors[k] <= f) a = k;
    }
    const int cl =
        odr_classify(live, f, 64, images, count, anchors[a], anchor_pos[a]);
    const int cs =
        odr_classify(stem, f, 64, images, count, anchors[a], anchor_pos[a]);
    if (cl == last_live && cs == last_stem) continue;
    if (f > 0) {
      printf("    [%6llu, %6llu) live %-17s stem %s\n",
             (unsigned long long)run_start, (unsigned long long)f,
             odr_name(last_live), odr_name(last_stem));
    }
    run_start = f;
    last_live = cl;
    last_stem = cs;
  }
  printf("    [%6llu, %6llu) live %-17s stem %s\n",
         (unsigned long long)run_start, (unsigned long long)frames,
         odr_name(last_live), odr_name(last_stem));
}

/* The frame of [channel]'s first RECORD_END. */
static uint64_t odr_record_end_frame(const char* dir, int32_t channel) {
  char path[700];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  static unsigned char logbuf[1 << 20];
  const size_t entries = log_entry_count(
      read_binary_file_for_test(path, logbuf, sizeof(logbuf)));
  for (size_t i = 0; i < entries; ++i) {
    le_perf_log_entry entry;
    decode_log_entry_at(logbuf, i, &entry);
    if (entry.cmd.code == LE_PLOG_RECORD_END &&
        entry.cmd.take.channel == channel) {
      return entry.frame;
    }
  }
  CHECK(0);
  return 0;
}

static void run_overdub_replay_case(const odr_case* c) {
  printf("  %s\n", c->name);
  const char* dir = render_test_dir(c->name);
  const int32_t sr = 48000;
  const int32_t ch = c->channel;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, 1, 1, sr) == LE_OK);
  CHECK(le_perf_set_follow_output(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_record_offset(e, c->offset) == LE_OK);
  CHECK(le_engine_set_rec_dub(e, c->rec_dub) == LE_OK);
  CHECK(le_engine_set_overdub_feedback(e, c->feedback) == LE_OK);

  /* Whole cycles per loop, so each signal tiles the loop cleanly. */
  odr_signal take = {3.0 / ODR_LEN, 0.30f, 0.0};
  odr_signal pass1 = {7.0 / ODR_LEN, 0.20f, 0.0};
  odr_signal pass2 = {17.0 / ODR_LEN, 0.15f, 0.0};
  odr_signal quiet = {0.0, 0.0f, 0.0};
  odr_signal* last = c->passes == 2 ? &pass2 : &pass1;
  char path[700];

  if (c->before_arm) {
    /* The take plays when the capture arms: the arm image is its lane, as
     * the Dart side exports it. */
    CHECK(le_engine_record(e, ch) == LE_OK);
    odr_pump(e, &take, ODR_LEN);
    CHECK(le_engine_record(e, ch) == LE_OK);
    odr_pump(e, &take, sr / 100);
    odr_pump(e, &quiet, 1000);
    float arm[ODR_LEN];
    CHECK(le_engine_export_track_lane(e, ch, 0, arm, ODR_LEN) == ODR_LEN);
    snprintf(path, sizeof(path), "%s/track%d-arm.wav", dir, ch);
    test_write_wav_mono(path, arm, ODR_LEN, sr);
  }
  CHECK(perf_arm_dir_long(e, dir) == LE_OK);
  drain(e);

  odr_pump(e, &quiet, 300); /* the capture runs before the take starts */
  if (ch != 0) {
    /* Track 0 defines the loop; the master is the two stems' sum. The
     * take on [ch] starts on the loop top, so it is one loop long. */
    odr_signal other = {5.0 / ODR_LEN, 0.25f, 0.0};
    CHECK(le_engine_record(e, 0) == LE_OK);
    odr_pump(e, &other, ODR_LEN);
    CHECK(le_engine_set_rec_dub(e, 0) == LE_OK);
    CHECK(le_engine_record(e, 0) == LE_OK);
    odr_pump(e, &other, sr / 100);
    CHECK(le_engine_set_rec_dub(e, c->rec_dub) == LE_OK);
    odr_pump(e, &quiet, ODR_LEN - e->clock.position);
    CHECK(e->clock.position == 0);
  }
  if (!c->before_arm) {
    CHECK(le_engine_record(e, ch) == LE_OK);
    odr_pump(e, &take, ODR_LEN);
    CHECK(le_engine_record(e, ch) == LE_OK); /* finalize */
  }
  if (!c->rec_dub) {
    odr_pump(e, &take, sr / 100); /* the seam crossfade's continuation */
    odr_pump(e, &quiet, ODR_LEN + 700);
    CHECK(le_engine_record(e, ch) == LE_OK); /* punch in mid-cycle */
  }
  /* With rec/dub the dub goes on from the take: pass 1 starts there. */
  odr_pump(e, &pass1, c->passes == 2 ? ODR_LEN : ODR_LEN / 2);
  if (c->passes == 2) odr_pump(e, &pass2, ODR_LEN / 2);
  CHECK(le_engine_record(e, ch) == LE_OK); /* punch out mid-cycle */
  odr_pump(e, last, sr / 100);            /* the punch-out fade */
  odr_pump(e, &quiet, 2 * ODR_LEN);
  settle_layers(e);
  le_track_snapshot ts;
  le_engine_get_track(e, ch, &ts);
  CHECK(ts.state == LE_TRACK_PLAYING);

  CHECK(le_engine_undo(e, ch) == LE_OK); /* back a pass */
  odr_pump(e, &quiet, ODR_LEN);
  CHECK(le_engine_redo(e, ch) == LE_OK); /* the last pass again */
  odr_pump(e, &quiet, ODR_LEN);
  CHECK(le_engine_clear_undoable(e, ch) == LE_OK);
  odr_pump(e, &quiet, ODR_LEN / 2);
  CHECK(le_engine_undo(e, ch) == LE_OK); /* Clear Undo: the last pass */
  odr_pump(e, &quiet, ODR_LEN + 333);

  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  const uint64_t frames = (uint64_t)snap.perf_frames;
  CHECK(snap.perf_overruns == 0);
  float* images[ODR_MAX_IMAGES] = {NULL};
  float* disarm = malloc(ODR_LEN * sizeof(float));
  CHECK(disarm != NULL);
  if (disarm == NULL) {
    le_engine_destroy(e);
    return;
  }
  CHECK(le_engine_export_track_lane(e, ch, 0, disarm, ODR_LEN) == ODR_LEN);
  snprintf(path, sizeof(path), "%s/track%d-lane0.wav", dir, ch);
  test_write_wav_mono(path, disarm, ODR_LEN, sr);
  const int32_t take_id = snap.tracks[ch].settled_take_id;
  if (ch != 0) {
    float* other = malloc(ODR_LEN * sizeof(float));
    CHECK(other != NULL);
    if (other != NULL) {
      CHECK(le_engine_export_track_lane(e, 0, 0, other, ODR_LEN) == ODR_LEN);
      snprintf(path, sizeof(path), "%s/track0-lane0.wav", dir);
      test_write_wav_mono(path, other, ODR_LEN, sr);
      free(other);
    }
  }
  CHECK(le_perf_disarm(e) == LE_OK);

  /* Each pass retires the loop as it was before it: the take, then each
   * pass's result but the last, which the disarm snapshot holds. */
  char layer_names[ODR_MAX_IMAGES][64];
  const int layers = odr_finalize_manifest(
      dir, ch, c->offset, take_id, snap.tracks[0].settled_take_id,
      c->before_arm, layer_names, ODR_MAX_IMAGES - 1);
  CHECK(layers == c->passes);
  for (int i = 0; i < layers; ++i) {
    images[i] = malloc(ODR_LEN * sizeof(float));
    CHECK(images[i] != NULL);
    snprintf(path, sizeof(path), "%s/%s", dir, layer_names[i]);
    FILE* lf = fopen(path, "rb");
    CHECK(lf != NULL);
    if (lf != NULL && images[i] != NULL) {
      CHECK(fread(images[i], sizeof(float), ODR_LEN, lf) == ODR_LEN);
      fclose(lf);
    }
  }
  images[layers] = disarm;

  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 20000);
  int32_t done = 0, track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1 && track_count == (ch != 0 ? 2 : 1));
  for (int32_t t = 0; t < track_count; ++t) {
    int32_t channel = -1, succeeded = 0;
    CHECK(le_perf_render_track_status(e, t, &channel, &succeeded) == LE_OK);
    CHECK(succeeded == 1);
  }

  float* live = calloc((size_t)frames, sizeof(float));
  float* stem = calloc((size_t)frames, sizeof(float));
  CHECK(live != NULL && stem != NULL);
  snprintf(path, sizeof(path), "%s/master-001.wav", dir);
  FILE* mf = perf_fopen_payload(path);
  CHECK(mf != NULL);
  size_t live_n = 0;
  if (mf != NULL && live != NULL) {
    live_n = fread(live, sizeof(float), (size_t)frames, mf);
  }
  if (mf != NULL) fclose(mf);
  CHECK(live_n == frames);
  const int32_t stem_n =
      stem != NULL ? test_read_stem(dir, ch, stem, (int32_t)frames) : 0;
  CHECK(stem_n == (int32_t)frames);
  if (ch != 0 && live != NULL && live_n == frames) {
    /* Track 0's stem is the take it played: what is left is [ch]'s. */
    float* other = calloc((size_t)frames, sizeof(float));
    CHECK(other != NULL);
    if (other != NULL) {
      CHECK(test_read_stem(dir, 0, other, (int32_t)frames) ==
            (int32_t)frames);
      for (uint64_t f = 0; f < frames; ++f) live[f] -= other[f];
      free(other);
    }
  }

  if (live_n == frames && stem_n == (int32_t)frames) {
    /* A take recorded over the loop with a record offset ends `offset`
     * frames short of it, so a rec/dub continuation retires it with its last
     * F frames faded (#730, le_dub_fade_image_tail: the take before the dub
     * is the take followed by silence). The callback played them unfaded on
     * the first lap, and no image holds them so: the stem plays the faded
     * ones there. */
    uint64_t faded_from = 0, faded_to = 0;
    if (ch != 0 && c->rec_dub && c->offset > 0) {
      const uint64_t end = odr_record_end_frame(dir, ch);
      const int32_t fade = sr / 100;
      faded_to = end + (uint64_t)(ODR_LEN - c->offset);
      faded_from = faded_to - (uint64_t)fade;
    }
    float worst = 0.0f;
    uint64_t first_bad = UINT64_MAX;
    float peak = 0.0f;
    for (uint64_t f = 0; f < frames; ++f) {
      if (f >= faded_from && f < faded_to) continue;
      const float d = fabsf(stem[f] - live[f]);
      if (d > worst) worst = d;
      if (d > 1e-5f && first_bad == UINT64_MAX) first_bad = f;
      if (fabsf(live[f]) > peak) peak = fabsf(live[f]);
    }
    CHECK(peak > 0.25f); /* the passes are in the master */
    if (worst >= 1e-5f) {
      printf("    stem vs master: max diff %.6f, first at frame %llu\n",
             (double)worst, (unsigned long long)first_bad);
      int complete = 1;
      for (int i = 0; i <= layers; ++i) complete &= images[i] != NULL;
      if (complete) {
        odr_print_timeline(dir, live, stem, frames, images, layers + 1);
      }
    }
    CHECK(worst < 1e-5f);
  }

  for (int i = 0; i <= layers && i < ODR_MAX_IMAGES; ++i) free(images[i]);
  free(live);
  free(stem);
  le_engine_destroy(e);
}

/* Each switch at the frame the live engine first reads the pass back:
 * punched in by a press or going on from the take (the record/dub toggle),
 * cut short in its first lap or after a complete pass, with and without a
 * record offset, adding or replacing, on the defining take, on a take
 * recorded over it and on a take recorded before the capture. */
static void test_overdub_replay_matches_live(void) {
  printf("test_overdub_replay_matches_live\n");
  static const odr_case cases[] = {
      {"odr-punch", 0, 0, 0, 2, 1.0f},
      {"odr-punch-offset", 0, 0, 100, 2, 1.0f},
      {"odr-recdub-offset", 0, 1, 100, 2, 1.0f},
      {"odr-recdub-short", 0, 1, 100, 1, 1.0f},
      {"odr-replace", 0, 0, 100, 2, 0.0f},
      {"odr-second-track", 1, 1, 100, 1, 1.0f},
      {"odr-second-track-full", 1, 1, 100, 2, 1.0f},
      {"odr-second-track-punch", 1, 0, 100, 2, 1.0f},
      {"odr-before-arm", 0, 0, 100, 2, 1.0f, 1},
  };
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
    run_overdub_replay_case(&cases[i]);
  }
}

static void run_overdub_replay_tests(void) {
  test_overdub_replay_matches_live();
}
