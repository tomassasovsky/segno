/* #1178 Part 6a: the Library audition voice. Literal PCM through the public
 * API and le_engine_process: every expected sample is a closed form of the
 * backing tests' ramp (bk_l, bk_r), so the comparisons are exact. Included by
 * test_engine_core.c after test_engine_backing.h, whose buffer, run and WAV
 * helpers it shares. */

static le_audition_state au_state(le_engine* e) {
  le_audition_state s;
  CHECK(le_engine_audition_state(e, &s) == LE_OK);
  return s;
}

/* A [frames]-frame mono ramp (bk_l) as a stereo buffer at [sr]. */
static le_backing_buffer* au_mono(int frames, int sr) {
  float* pcm = malloc((size_t)frames * sizeof(float));
  CHECK(pcm != NULL);
  for (int k = 0; k < frames; ++k) pcm[k] = bk_l(k);
  le_backing_buffer* b = NULL;
  CHECK(le_backing_buffer_from_pcm(pcm, frames, 1, sr, &b) == LE_OK);
  free(pcm);
  return b;
}

static void test_audition_refusals(void) {
  printf("test_audition_refusals\n");
  le_backing_buffer* b = au_mono(64, BK_SR);
  le_engine* unconfigured = le_engine_create();
  CHECK(le_engine_audition_start(unconfigured, b, 0) == LE_ERR_NOT_RUNNING);
  le_engine_destroy(unconfigured);

  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_start(e, NULL, 0) == LE_ERR_INVALID);
  CHECK(le_engine_audition_start(e, b, -1) == LE_ERR_INVALID);
  CHECK(le_engine_audition_start(e, b, LE_MAX_OUTPUT_BUSES) == LE_ERR_INVALID);
  /* A pair the open device has no channels for: it would play silently. */
  CHECK(le_engine_audition_start(e, b, 1) == LE_ERR_INVALID);
  le_backing_buffer* other = au_mono(64, 44100);
  CHECK(le_engine_audition_start(e, other, 0) == LE_ERR_INVALID); /* rate */
  le_backing_buffer_free(other);
  CHECK(le_engine_audition_state(e, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_audition_state(NULL, NULL) == LE_ERR_INVALID);
  /* Raw posts are refused: START carries a pointer. */
  atomic_store_explicit(&e->a_running, 1, memory_order_release);
  CHECK(le_engine_post_command(e, LE_CMD_AUDITION_START, 0, 0.0f) ==
        LE_ERR_INVALID);
  CHECK(le_engine_post_command(e, LE_CMD_AUDITION_STOP, 0, 0.0f) ==
        LE_ERR_INVALID);
  atomic_store_explicit(&e->a_running, 0, memory_order_release);
  CHECK(le_engine_audition_start(e, b, 0) == LE_OK);
  CHECK(le_engine_audition_start(e, b, 0) == LE_ERR_INVALID); /* owned */
  le_audition_state s = au_state(e);
  CHECK(s.owned == 1 && s.frames == 0 && s.bus == -1);
  le_engine_destroy(e); /* frees the queued buffer (ASAN) */

  /* Longer than LE_AUDITION_MAX_SECONDS: refused (8 kHz keeps it small). */
  le_engine* slow = le_engine_create();
  CHECK(le_engine_configure(slow, 8000, 1, 2, 8000 * 4) == LE_OK);
  le_backing_buffer* longest = au_mono(LE_AUDITION_MAX_SECONDS * 8000, 8000);
  le_backing_buffer* over = au_mono(LE_AUDITION_MAX_SECONDS * 8000 + 1, 8000);
  CHECK(le_engine_audition_start(slow, over, 0) == LE_ERR_INVALID);
  CHECK(le_engine_audition_start(slow, longest, 0) == LE_OK);
  le_backing_buffer_free(over);
  le_engine_destroy(slow);
}

/* A 64-frame mono ramp into pair 0 appears exactly once on both channels;
 * the next block is silent; the position advances by the block; the length
 * reads 0 after the end and the buffer is handed back. */
static void test_audition_plays_once(void) {
  printf("test_audition_plays_once\n");
  static float out[256 * 4];
  le_engine* e = bk_engine(4);
  CHECK(le_engine_audition_start(e, au_mono(64, BK_SR), 0) == LE_OK);
  bk_run(e, out, 32, 4, 32);
  le_audition_state s = au_state(e);
  CHECK(s.frames == 64 && s.position == 32 && s.bus == 0 && s.owned == 1);
  bk_run(e, out + 32 * 4, 32, 4, 32);
  for (int f = 0; f < 64; ++f) {
    CHECK(out[4 * f] == bk_l(f) && out[4 * f + 1] == bk_l(f));
    CHECK(out[4 * f + 2] == 0.0f && out[4 * f + 3] == 0.0f);
  }
  s = au_state(e);
  CHECK(s.frames == 0 && s.bus == -1 && s.owned == 0);
  bk_run(e, out, 64, 4, 64);
  for (int i = 0; i < 64 * 4; ++i) CHECK(out[i] == 0.0f);
  le_engine_destroy(e);
}

/* A stereo buffer keeps its interleave in pair 1. */
static void test_audition_stereo_pair(void) {
  printf("test_audition_stereo_pair\n");
  static float out[128 * 4];
  le_engine* e = bk_engine(4);
  CHECK(le_engine_audition_start(e, bk_buffer(128, 0.0f), 1) == LE_OK);
  bk_run(e, out, 128, 4, 64);
  for (int f = 0; f < 128; ++f) {
    CHECK(out[4 * f] == 0.0f && out[4 * f + 1] == 0.0f);
    CHECK(out[4 * f + 2] == bk_l(f) && out[4 * f + 3] == bk_r(f));
  }
  le_engine_destroy(e);

  /* A disabled jack of the pair is never written. */
  e = bk_engine(2);
  CHECK(le_engine_set_output_enabled(e, 1, 0) == LE_OK);
  CHECK(le_engine_audition_start(e, bk_buffer(128, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) {
    CHECK(out[2 * f] == bk_l(f) && out[2 * f + 1] == 0.0f);
  }
  le_engine_destroy(e);
}

/* Stop between blocks silences the next block; the buffer comes back. */
static void test_audition_stop(void) {
  printf("test_audition_stop\n");
  static float out[128 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_stop(e) == LE_OK); /* nothing plays: a no-op */
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  CHECK(out[0] == bk_l(0));
  CHECK(le_engine_audition_stop(e) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 128; ++i) CHECK(out[i] == 0.0f);
  le_audition_state s = au_state(e);
  CHECK(s.frames == 0 && s.position == 0 && s.owned == 0);
  le_engine_destroy(e);
}

/* A second start replaces the first; a third before the replaced buffer is
 * handed back reads LE_ERR_NOT_READY and succeeds after one block. */
static void test_audition_replace(void) {
  printf("test_audition_replace\n");
  static float out[64 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.5f), 0) == LE_OK);
  le_backing_buffer* third = bk_buffer(4096, 0.25f);
  CHECK(le_engine_audition_start(e, third, 0) == LE_ERR_NOT_READY);
  CHECK(au_state(e).owned == 2);
  bk_run(e, out, 64, 2, 64);
  CHECK(out[0] == 0.5f + bk_l(0)); /* the second, from its first frame */
  CHECK(le_engine_audition_start(e, third, 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  CHECK(out[0] == 0.25f + bk_l(0));
  CHECK(au_state(e).owned == 1);
  le_engine_destroy(e);
}

/* Past the output buses: a bus at level 0 or muted leaves the voice at
 * unity; the master gain halves it and the limiter limits it. */
static void test_audition_after_buses_before_master(void) {
  printf("test_audition_after_buses_before_master\n");
  static float out[64 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_set_output_level(e, 0, 0.0f) == LE_OK);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) CHECK(out[2 * f] == bk_l(f));
  CHECK(le_engine_set_output_level(e, 0, 1.0f) == LE_OK);
  CHECK(le_engine_set_output_mute(e, 0, 1) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) CHECK(out[2 * f + 1] == bk_r(64 + f));
  CHECK(le_engine_set_output_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_set_master_gain(e, 0.5f) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) CHECK(out[2 * f] == bk_l(128 + f) * 0.5f);
  le_engine_destroy(e);

  /* A constant 0.5 under a 0.25 ceiling comes out at exactly 0.25. */
  e = bk_engine(2);
  float half[64 * 2];
  for (int i = 0; i < 64 * 2; ++i) half[i] = 0.5f;
  le_backing_buffer* b = NULL;
  CHECK(le_backing_buffer_from_pcm(half, 64, 2, BK_SR, &b) == LE_OK);
  CHECK(le_engine_set_limiter(e, 1, 0.25f) == LE_OK);
  CHECK(le_engine_audition_start(e, b, 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64 * 2; ++i) CHECK(out[i] == 0.25f);
  le_engine_destroy(e);
}

/* With a loop playing, the output is the loop plus the voice, sample for
 * sample: the same engine without the voice is the reference. */
static void test_audition_sums_with_loop(void) {
  printf("test_audition_sums_with_loop\n");
  enum { N = 512 };
  static float with[N * 2], without[N * 2];
  float loop[128];
  for (int i = 0; i < 128; ++i) loop[i] = (float)(i % 7) / 16.0f;
  le_engine* rig[2];
  for (int k = 0; k < 2; ++k) {
    rig[k] = bk_engine(2);
    CHECK(le_engine_import_track(rig[k], 0, loop, 128) == LE_OK);
    CHECK(le_engine_commit_session(rig[k], 128, 0) == LE_OK);
    CHECK(le_engine_play(rig[k], 0) == LE_OK);
  }
  CHECK(le_engine_audition_start(rig[1], bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(rig[0], without, N, 2, 64);
  bk_run(rig[1], with, N, 2, 64);
  int loop_heard = 0;
  for (int f = 0; f < N; ++f) {
    CHECK(with[2 * f] == without[2 * f] + bk_l(f));
    CHECK(with[2 * f + 1] == without[2 * f + 1] + bk_r(f));
    if (without[2 * f] != 0.0f) ++loop_heard;
  }
  CHECK(loop_heard > N / 2);
  le_engine_destroy(rig[0]);
  le_engine_destroy(rig[1]);
}

/* A take recorded while the voice plays holds the input only: the same take
 * without the voice is byte-identical. */
static void test_audition_not_recorded(void) {
  printf("test_audition_not_recorded\n");
  enum { N = 256 };
  static float in[N], out[N * 2];
  for (int i = 0; i < N; ++i) in[i] = (float)(i % 5) / 8.0f;
  float take[2][N];
  int32_t got[2];
  for (int k = 0; k < 2; ++k) {
    le_engine* e = bk_engine(2);
    if (k == 1) {
      CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
    }
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, out, in, N);
    CHECK(le_engine_record(e, 0) == LE_OK);
    le_engine_process(e, out, in, 64);
    got[k] = le_engine_export_track(e, 0, take[k], N);
    le_engine_destroy(e);
  }
  CHECK(got[0] > 0 && got[0] == got[1]);
  CHECK(memcmp(take[0], take[1], (size_t)got[0] * sizeof(float)) == 0);
}

/* A performance arm ends the preview: the capture holds none of it. While
 * armed, a start is refused. */
static void test_audition_and_performance_capture(void) {
  printf("test_audition_and_performance_capture\n");
  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  drain(e);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(au_state(e).frames == 0);
  static float out[LOOP_N * 2], captured[LOOP_N * 2];
  bk_run(e, out, LOOP_N, 2, LOOP_N);
  CHECK(le_engine_perf_master_pop_for_test(e, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N * 2; ++i) {
    CHECK(captured[i] == 0.0f && out[i] == 0.0f);
  }
  le_backing_buffer* b = bk_buffer(64, 0.0f);
  CHECK(le_engine_audition_start(e, b, 0) == LE_ERR_ALREADY_RUNNING);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(le_engine_audition_start(e, b, 0) == LE_OK);
  CHECK(au_state(e).owned == 1); /* the arm handed the first one back */
  le_engine_destroy(e);
}

/* A start posted after an arm's post but checked before its apply (the
 * control side reads a_perf_armed, which the callback sets) is handed back
 * unplayed: the performer never hears it over the take. */
static void test_audition_start_racing_an_arm(void) {
  printf("test_audition_start_racing_an_arm\n");
  le_engine* e = bk_engine(2);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  /* No drain: the arm is still in the ring, so the start is accepted. */
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  static float out[256 * 2];
  bk_run(e, out, 256, 2, 64);
  CHECK(atomic_load(&e->a_perf_armed) == 1);
  le_audition_state s = au_state(e);
  CHECK(s.frames == 0 && s.position == 0);
  for (int i = 0; i < 256 * 2; ++i) CHECK(out[i] == 0.0f);
  CHECK(s.owned == 0); /* handed back and freed at the collect */
  CHECK(le_perf_disarm(e) == LE_OK);
  le_engine_destroy(e);
}

/* Cut sound silences the preview too. */
static void test_audition_cut_sound(void) {
  printf("test_audition_cut_sound\n");
  static float out[64 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64 * 2; ++i) CHECK(out[i] == 0.0f);
  CHECK(au_state(e).owned == 0);
  le_engine_destroy(e);
}

/* Configure and a retained reopen free every audition buffer, one queued in
 * the ring included, and bump the epoch; destroy frees a playing one. */
static void test_audition_lifetimes(void) {
  printf("test_audition_lifetimes\n");
  static float out[64 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  const uint32_t epoch = au_state(e).epoch;
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  int32_t outcome = -1, dropped = -1;
  CHECK(le_engine_reopen_configured(e, BK_SR, 1, 2, BK_SR * 4, &outcome,
                                    &dropped) == LE_OK);
  le_audition_state s = au_state(e);
  CHECK(s.epoch == epoch + 1 && s.frames == 0 && s.owned == 0);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64 * 2; ++i) CHECK(out[i] == 0.0f);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  CHECK(le_engine_configure(e, BK_SR, 1, 2, BK_SR * 4) == LE_OK);
  s = au_state(e);
  CHECK(s.epoch == epoch + 2 && s.frames == 0 && s.owned == 0);
  CHECK(le_engine_audition_start(e, bk_buffer(4096, 0.0f), 0) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  le_engine_destroy(e);
}

/* A preview is the decoder's bounded read: the first LE_AUDITION_MAX_SECONDS
 * of a longer file, flagged; a shorter file whole. */
static void test_audition_bounded_decode(void) {
  printf("test_audition_bounded_decode\n");
  enum { SR = 8000 };
  const int over = (LE_AUDITION_MAX_SECONDS + 1) * SR;
  int16_t* pcm = calloc((size_t)over, sizeof(int16_t));
  CHECK(pcm != NULL);
  for (int i = 0; i < over; ++i) pcm[i] = (int16_t)(i % 1000);
  bk_write_wav(bk_path("long_preview.wav"), 1, 16, 1, SR, pcm, over, 0);
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  CHECK(le_backing_decode_file(bk_path("long_preview.wav"), SR, 0,
                               LE_AUDITION_MAX_SECONDS * SR, &b,
                               &info) == LE_OK);
  CHECK(info.truncated == 1 && info.source_rate == SR);
  CHECK(le_backing_buffer_frames(b) == LE_AUDITION_MAX_SECONDS * SR);
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, SR, 1, 2, SR * 4) == LE_OK);
  CHECK(le_engine_audition_start(e, b, 0) == LE_OK); /* exactly the cap */
  le_engine_destroy(e);
  bk_write_wav(bk_path("short_preview.wav"), 1, 16, 1, SR, pcm, SR, 0);
  CHECK(le_backing_decode_file(bk_path("short_preview.wav"), SR, 0,
                               LE_AUDITION_MAX_SECONDS * SR, &b,
                               &info) == LE_OK);
  CHECK(info.truncated == 0 && le_backing_buffer_frames(b) == SR);
  le_backing_buffer_free(b);
  free(pcm);
}

static void run_audition_tests(void) {
  test_audition_refusals();
  test_audition_plays_once();
  test_audition_stereo_pair();
  test_audition_stop();
  test_audition_replace();
  test_audition_after_buses_before_master();
  test_audition_sums_with_loop();
  test_audition_not_recorded();
  test_audition_and_performance_capture();
  test_audition_start_racing_an_arm();
  test_audition_cut_sound();
  test_audition_lifetimes();
  test_audition_bounded_decode();
}
