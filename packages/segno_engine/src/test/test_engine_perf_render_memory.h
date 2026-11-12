/* #1747: the performance render streams. A capture of any length renders in
 * the memory a short one does (every buffer is a block long), a cancel is
 * seen at the next block and leaves no partial stem, and a device
 * reconfigure lets a running render finish. Included by test_engine_core.c
 * after test_engine_heard_perf.h (shares its stereo WAV writer and the perf
 * render helpers). */

#if defined(__APPLE__)
#include <mach/mach.h> /* task_info: the process's physical footprint */
#elif defined(__linux__)
#include <fcntl.h> /* open: /proc/self/statm */
#endif

enum { RM_SR = 48000, RM_LOOP = 4800 };

/* The memory the process holds now, in bytes, or -1 where this cannot be
 * read. On macOS the physical footprint, which counts pages the compressor
 * holds (resident size would miss a long buffer of silence). */
static int64_t render_memory_now(void) {
#if defined(__APPLE__)
  task_vm_info_data_t vm;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) !=
      KERN_SUCCESS) {
    return -1;
  }
  return (int64_t)vm.phys_footprint;
#elif defined(__linux__)
  /* read() into the stack, not stdio: a FILE and its buffer are allocated
   * at every poll, and under ASan the quarantine holds each one freed, so
   * the reading itself grew the process with the render's length. */
  const int fd = open("/proc/self/statm", O_RDONLY);
  if (fd < 0) return -1;
  char text[128];
  const ssize_t got = read(fd, text, sizeof(text) - 1);
  close(fd);
  if (got <= 0) return -1;
  text[got] = '\0';
  long size = 0, resident = 0;
  if (sscanf(text, "%ld %ld", &size, &resident) != 2) return -1;
  return (int64_t)resident * (int64_t)sysconf(_SC_PAGESIZE);
#else
  return -1;
#endif
}

/* A capture of `frames` frames at 48 kHz: track 0 plays a clean take of 0.5
 * with a heard image of (0.3, 0.1), track 1 a clean take of 0.25, both a
 * 0.1 s loop from the arm, and an events.log holding only the arm fact. The
 * master is the output pair's sides in [capture_mask] (1: mono, 3: stereo). */
static const char* render_fixture_masked(const char* name, uint64_t frames,
                                         int capture_mask) {
  test_render_mkdir(perf_test_dir());
  const char* dir = render_test_dir(name);
  char loops[700];
  snprintf(loops, sizeof(loops), "%s/loops", dir);
  test_render_mkdir(loops);
  static float clean0[RM_LOOP], clean1[RM_LOOP], pairs[2 * RM_LOOP];
  for (int i = 0; i < RM_LOOP; ++i) {
    clean0[i] = 0.5f;
    clean1[i] = 0.25f;
    pairs[2 * i] = 0.3f;
    pairs[2 * i + 1] = 0.1f;
  }
  char path[760];
  snprintf(path, sizeof(path), "%s/clean0.wav", loops);
  test_write_wav_mono(path, clean0, RM_LOOP, RM_SR);
  snprintf(path, sizeof(path), "%s/clean1.wav", loops);
  test_write_wav_mono(path, clean1, RM_LOOP, RM_SR);
  snprintf(path, sizeof(path), "%s/heard0.wav", loops);
  heard_write_wav_stereo(path, pairs, RM_LOOP, RM_SR);
  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": %d, "
           "\"tracks\": [{\"channel\": 0, \"lanes\": [{\"lane\": 0, "
           "\"deferred\": false, \"pcmRef\": \"loops/clean0.wav\", "
           "\"heardPcmRef\": \"loops/heard0.wav\"}]}, "
           "{\"channel\": 1, \"lanes\": [{\"lane\": 0, \"deferred\": false, "
           "\"pcmRef\": \"loops/clean1.wav\"}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
           RM_SR, (unsigned long long)frames, capture_mask);
  test_write_manifest(dir, manifest);
  snprintf(path, sizeof(path), "%s/events.log", dir);
  FILE* lf = fopen(path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, RM_SR, LE_TEST_EVENTS_VERSION);
    test_write_log_entry(
        lf, 0,
        (le_command){.code = LE_PLOG_PERF_ARMED,
                     .perf_arm = {.position = 0, .master_len = RM_LOOP,
                                  .iteration = 0}});
    fclose(lf);
  }
  return dir;
}

/* The fixture above with a mono master. */
static const char* render_memory_fixture(const char* name, uint64_t frames) {
  return render_fixture_masked(name, frames, 1);
}

/* The stem at `rel` under [dir]: its frame count from the header (-1 when
 * it does not read) and the sample of channel 0 at `frame`. */
static int64_t render_memory_stem(const char* dir, const char* rel,
                                  uint64_t frame, int channels, float* at) {
  char path[760];
  snprintf(path, sizeof(path), "%s/%s", dir, rel);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return -1;
  unsigned char header[44];
  int64_t frames = -1;
  if (fread(header, 1, sizeof(header), f) == sizeof(header)) {
    uint32_t data_bytes;
    memcpy(&data_bytes, header + 40, 4);
    frames = (int64_t)(data_bytes / sizeof(float) / (uint32_t)channels);
    *at = NAN;
    if (fseek(f, (long)(44 + frame * sizeof(float) * (uint64_t)channels),
               SEEK_SET) != 0 ||
        fread(at, sizeof(float), 1, f) != 1) {
      frames = -1;
    }
  }
  fclose(f);
  return frames;
}

static int render_memory_exists(const char* dir, const char* rel) {
  char path[760];
  snprintf(path, sizeof(path), "%s/%s", dir, rel);
  FILE* f = fopen(path, "rb");
  if (f != NULL) fclose(f);
  return f != NULL;
}

/* Removes the stems a fixture rendered: they are tens of megabytes. */
static void render_memory_clean(const char* dir) {
  static const char* const rels[] = {"stems/dry/track0.wav",
                                     "stems/dry/track1.wav",
                                     "stems/wet/track0.wav",
                                     "stems/wet/track1.wav",
                                     "stems/wet/master.wav"};
  for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); ++i) {
    char path[760];
    snprintf(path, sizeof(path), "%s/%s", dir, rels[i]);
    remove(path);
  }
}

/* Every stem of [dir] is whole: `frames` long, still playing its loop at the
 * last frame (the dry takes, the heard image's mean in track 0's wet stem,
 * and their sum in the master). */
static void render_memory_check_stems(const char* dir, uint64_t frames) {
  const uint64_t last = frames - 1;
  float v = 0.0f;
  CHECK(render_memory_stem(dir, "stems/dry/track0.wav", last, 1, &v) ==
        (int64_t)frames);
  CHECK(fabsf(v - 0.5f) < 1e-6f);
  CHECK(render_memory_stem(dir, "stems/dry/track1.wav", last, 1, &v) ==
        (int64_t)frames);
  CHECK(fabsf(v - 0.25f) < 1e-6f);
  CHECK(render_memory_stem(dir, "stems/wet/track0.wav", last, 1, &v) ==
        (int64_t)frames);
  CHECK(fabsf(v - 0.2f) < 1e-6f);
  CHECK(render_memory_stem(dir, "stems/wet/track1.wav", last, 1, &v) ==
        (int64_t)frames);
  CHECK(fabsf(v - 0.25f) < 1e-6f);
  CHECK(render_memory_stem(dir, "stems/wet/master.wav", last, 1, &v) ==
        (int64_t)frames);
  CHECK(fabsf(v - 0.45f) < 1e-6f);
}

/* Begins a render of [dir] on [e] held after its first block
 * (le_perf_render_hold_for_test), so what the test does next lands while it
 * runs whatever the machine's speed. The caller releases the hold. */
static void render_memory_begin_held(le_engine* e, const char* dir) {
  le_perf_render_hold_for_test(1);
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  for (int i = 0; i < 60000 && !le_perf_render_held_for_test(); ++i) {
    test_sleep_ms(1);
  }
  CHECK(le_perf_render_held_for_test());
}

/* Renders [frames] frames of the two-track fixture on a fresh engine and
 * returns how far the process's memory rose above where it stood when the
 * render began (-1 where it cannot be read), the stems checked whole. */
static int64_t render_memory_growth(const char* name, uint64_t frames) {
  const char* dir = render_memory_fixture(name, frames);
  le_engine* e = le_engine_create();
  const int64_t before = render_memory_now();
  int64_t peak = before;
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  int32_t done = 0;
  for (int i = 0; i < 600000 && !done; ++i) {
    le_perf_render_poll(e, &done, NULL, NULL);
    const int64_t now = render_memory_now();
    if (now > peak) peak = now;
    if (!done) test_sleep_ms(1);
  }
  CHECK(done == 1);
  int32_t track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(track_count == 2);
  for (int i = 0; i < track_count; ++i) {
    int32_t channel = -1, succeeded = 0;
    CHECK(le_perf_render_track_status(e, i, &channel, &succeeded) == LE_OK);
    CHECK(succeeded == 1);
  }
  render_memory_check_stems(dir, frames);
  le_engine_destroy(e);
  render_memory_clean(dir);
  return before >= 0 ? peak - before : -1;
}

/* 8M frames (2 min 47 s at 48 kHz) over two tracks, one with a heard image:
 * the render's memory does not grow with the capture. Rendered whole, each
 * track held 33 bytes a frame (its dry and wet stems, both heard sides, the
 * heard marks, the routed pair) beside an 8-byte master: 264 MB here and
 * 33 MB for the 1M-frame capture it is measured against, 8.7 GB for the
 * 1 h 36 min capture that ran the console out of memory. A block at a time
 * the two hold the same. Measured against a short capture in the same
 * build, not as an absolute, so a sanitizer's shadow memory and quarantine
 * (which scale with what the render allocates, not with the capture) count
 * in both. */
static void test_perf_render_memory_is_bounded(void) {
  printf("test_perf_render_memory_is_bounded\n");
  enum { SHORT = 1000000, LONG = 8000000 };
  const int64_t short_grew = render_memory_growth("memory-short", SHORT);
  const int64_t long_grew = render_memory_growth("memory-long", LONG);
  if (short_grew < 0 || long_grew < 0) {
    printf("  (memory not measurable on this platform)\n");
    return;
  }
  printf("  render grew the process by %.1f MB over %d frames, %.1f MB over "
         "%d\n",
         (double)short_grew / 1048576.0, SHORT, (double)long_grew / 1048576.0,
         LONG);
  /* Rendered whole, the long one held 231 MB more; a block at a time, the
   * difference is below half a mono stem of it (32 MB). */
  CHECK(long_grew - short_grew < (int64_t)16 * 1024 * 1024);
}

/* A cancel is seen at the next block, and the stems it had begun are
 * removed: a stem on disk is a whole one. A stem is written beside its path
 * and published once it seals, so re-rendering a bundle and cancelling
 * (boot recovery re-renders a stranded bundle; a shutdown cancels it)
 * leaves the stems an earlier render wrote. Rendered whole, the track in
 * flight finished first, however long. */
static void test_perf_render_cancel_leaves_no_partial_stem(void) {
  printf("test_perf_render_cancel_leaves_no_partial_stem\n");
  enum { FRAMES = 8000000 };
  const char* dir = render_memory_fixture("memory-cancel", FRAMES);
  static const char* const parts[] = {"stems/dry/track0.wav.part",
                                      "stems/dry/track1.wav.part",
                                      "stems/wet/track0.wav.part",
                                      "stems/wet/track1.wav.part",
                                      "stems/wet/master.wav.part"};
  for (int pass = 0; pass < 2; ++pass) {
    le_engine* e = le_engine_create();
    render_memory_begin_held(e, dir);
    int32_t done = 0;
    le_perf_render_poll(e, &done, NULL, NULL);
    CHECK(done == 0); /* the cancel lands mid-render */
    CHECK(le_perf_render_cancel(e) == LE_OK);
    le_perf_render_hold_for_test(0);
    for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); ++i) {
      CHECK(!render_memory_exists(dir, parts[i]));
    }
    if (pass == 0) {
      /* Nothing was rendered before: no stem at all. */
      CHECK(!render_memory_exists(dir, "stems/dry/track0.wav"));
      CHECK(!render_memory_exists(dir, "stems/dry/track1.wav"));
      CHECK(!render_memory_exists(dir, "stems/wet/track0.wav"));
      CHECK(!render_memory_exists(dir, "stems/wet/track1.wav"));
      CHECK(!render_memory_exists(dir, "stems/wet/master.wav"));
      /* Then a whole render, which the next pass re-renders. */
      CHECK(le_perf_render_begin(e, dir) == LE_OK);
      test_wait_for_render(e, 600000);
    } else {
      render_memory_check_stems(dir, FRAMES); /* the earlier render's */
    }
    le_engine_destroy(e);
  }
  render_memory_clean(dir);
}

/* A device reconfigure while a render runs (the console's audio warm-up
 * switches the device seconds after start, while boot recovery renders)
 * returns at once and the render goes on to whole stems. It used to cancel
 * the render: joining a worker that was rendering a whole stem held the
 * audio start that long, and the render's stems were dropped. */
static void test_perf_render_runs_through_reconfigure(void) {
  printf("test_perf_render_runs_through_reconfigure\n");
  enum { FRAMES = 8000000 };
  const char* dir = render_memory_fixture("memory-reconfigure", FRAMES);
  le_engine* e = make_configured_engine();
  render_memory_begin_held(e, dir);
  int32_t done = 0;
  le_perf_render_poll(e, &done, NULL, NULL);
  CHECK(done == 0); /* the reconfigure lands mid-render */
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  le_perf_render_poll(e, &done, NULL, NULL);
  CHECK(done == 0); /* still rendering: not joined, not cancelled */
  le_perf_render_hold_for_test(0);
  test_wait_for_render(e, 600000);
  int32_t track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 2);
  for (int i = 0; i < track_count; ++i) {
    int32_t channel = -1, succeeded = 0;
    CHECK(le_perf_render_track_status(e, i, &channel, &succeeded) == LE_OK);
    CHECK(succeeded == 1);
  }
  render_memory_check_stems(dir, FRAMES);
  le_engine_destroy(e);
  render_memory_clean(dir);
}

/* A re-render leaves only its own stems: one it could not write takes the
 * earlier render's away, so a bundle never mixes two renders' stems. */
static void test_perf_render_rerender_leaves_only_its_own_stems(void) {
  printf("test_perf_render_rerender_leaves_only_its_own_stems\n");
  enum { FRAMES = 200000 };
  const char* dir = render_memory_fixture("memory-rerender", FRAMES);
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 60000);
  render_memory_check_stems(dir, FRAMES);

  le_perf_render_force_dry_write_failure_for_test(0);
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 60000);
  le_perf_render_force_dry_write_failure_for_test(-1);

  CHECK(!render_memory_exists(dir, "stems/dry/track0.wav")); /* the old one */
  float v = 0.0f;
  CHECK(render_memory_stem(dir, "stems/wet/track0.wav", FRAMES - 1, 1, &v) ==
        (int64_t)FRAMES);
  CHECK(render_memory_stem(dir, "stems/dry/track1.wav", FRAMES - 1, 1, &v) ==
        (int64_t)FRAMES);
  /* The master is this render's: track 1 alone, track 0 failed. */
  CHECK(render_memory_stem(dir, "stems/wet/master.wav", FRAMES - 1, 1, &v) ==
        (int64_t)FRAMES);
  CHECK(fabsf(v - 0.25f) < 1e-6f);
  le_engine_destroy(e);
  render_memory_clean(dir);
}
