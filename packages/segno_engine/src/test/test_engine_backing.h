/* #1200 Part 1: the native backing voice and click pan. Literal PCM through
 * the public API and le_engine_process: every expected sample is a closed form
 * of a ramp buffer (L = (k + 1) / 8192, R = L / 2), computed with the same
 * float operations the voice uses, so the comparisons are exact. Included by
 * test_engine_core.c after test_engine_history_replay.h (shares its render
 * helpers for the stem leg). */

#define BK_SR 48000
#define BK_RAMP (BK_SR * LE_BACKING_RAMP_MS / 1000) /* 240 */

static float bk_l(int k) { return (float)(k + 1) / 8192.0f; }
static float bk_r(int k) { return bk_l(k) * 0.5f; }

/* A [frames]-frame stereo ramp, offset by [base] so two buffers differ. */
static le_backing_buffer* bk_buffer(int frames, float base) {
  float* pcm = malloc((size_t)frames * 2 * sizeof(float));
  CHECK(pcm != NULL);
  for (int k = 0; k < frames; ++k) {
    pcm[2 * k] = base + bk_l(k);
    pcm[2 * k + 1] = base + bk_r(k);
  }
  le_backing_buffer* b = NULL;
  CHECK(le_backing_buffer_from_pcm(pcm, frames, 2, BK_SR, &b) == LE_OK);
  free(pcm);
  return b;
}

static le_engine* bk_engine(int out_ch) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, BK_SR, 1, out_ch, BK_SR * 4) == LE_OK);
  return e;
}

/* Processes [frames] frames of silence in blocks of [block] into out
 * (interleaved, out_ch channels). */
static void bk_run(le_engine* e, float* out, int frames, int out_ch,
                   int block) {
  static float in[512];
  for (int at = 0; at < frames;) {
    int n = frames - at;
    if (n > block) n = block;
    le_engine_process(e, out + (size_t)at * out_ch, in, (uint32_t)n);
    at += n;
  }
}

static le_backing_state bk_state(le_engine* e) {
  le_backing_state s;
  CHECK(le_engine_backing_state(e, &s) == LE_OK);
  return s;
}

static void test_backing_buffer_and_refusals(void) {
  printf("test_backing_buffer_and_refusals\n");
  const float mono[3] = {.25f, -.5f, .75f};
  le_backing_buffer* b = NULL;
  CHECK(le_backing_buffer_from_pcm(mono, 3, 1, BK_SR, &b) == LE_OK);
  CHECK(le_backing_buffer_frames(b) == 3);
  CHECK(le_backing_buffer_rate(b) == BK_SR);
  float peaks[3];
  CHECK(le_backing_buffer_peaks(b, peaks, 3) == 3);
  CHECK(peaks[0] == .25f && peaks[1] == .5f && peaks[2] == .75f);
  CHECK(le_backing_buffer_from_pcm(mono, 0, 1, BK_SR, &b) == LE_ERR_INVALID);
  CHECK(b == NULL);
  CHECK(le_backing_buffer_from_pcm(mono, 3, 3, BK_SR, &b) == LE_ERR_INVALID);
  /* A NaN or Inf sample would poison output-bus FX for good: refused. */
  const float nan_pcm[3] = {.25f, NAN, .75f};
  const float inf_pcm[2] = {INFINITY, 0.0f};
  CHECK(le_backing_buffer_from_pcm(nan_pcm, 3, 1, BK_SR, &b) == LE_ERR_INVALID);
  CHECK(le_backing_buffer_from_pcm(inf_pcm, 1, 2, BK_SR, &b) == LE_ERR_INVALID);
  CHECK(b == NULL);
  CHECK(le_backing_buffer_from_pcm(mono, 1, 1, BK_SR, &b) == LE_OK);

  le_engine* unconfigured = le_engine_create();
  CHECK(le_engine_backing_load(unconfigured, b, 1, 1) == LE_ERR_NOT_RUNNING);
  le_engine_destroy(unconfigured);

  le_engine* e = bk_engine(2);
  le_backing_buffer* other = NULL;
  CHECK(le_backing_buffer_from_pcm(mono, 3, 1, 44100, &other) == LE_OK);
  CHECK(le_engine_backing_load(e, other, 1, 1) == LE_ERR_INVALID); /* rate */
  le_backing_buffer_free(other);
  CHECK(le_engine_backing_load(e, NULL, 1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_backing_load(e, b, 1, 0) == LE_OK);
  CHECK(le_engine_backing_load(e, b, 2, 0) == LE_ERR_INVALID); /* owned */
  CHECK(le_engine_backing_set_end(e, 3) == LE_ERR_INVALID);
  CHECK(le_engine_backing_set_level(e, NAN) == LE_ERR_INVALID);
  CHECK(le_engine_backing_set_pan(e, NAN) == LE_ERR_INVALID);
  CHECK(le_engine_set_click_pan(e, NAN) == LE_ERR_INVALID);
  CHECK(le_engine_backing_transport(e, 3) == LE_ERR_INVALID);
  /* Raw posts are refused for the whole family (LOAD carries a pointer a raw
   * {arg_i, arg_f} post cannot express). */
  atomic_store_explicit(&e->a_running, 1, memory_order_release);
  for (int code = LE_CMD_BACKING_LOAD; code <= LE_CMD_BACKING_SEEK; ++code) {
    CHECK(le_engine_post_command(e, code, 0, 0.0f) == LE_ERR_INVALID);
  }
  atomic_store_explicit(&e->a_running, 0, memory_order_release);
  CHECK(le_engine_backing_set_level(e, 9.0f) == LE_OK);
  CHECK(le_engine_backing_set_pan(e, -4.0f) == LE_OK);
  le_backing_state s = bk_state(e);
  CHECK(s.level == LE_MAX_GAIN && s.pan == -1.0f);
  CHECK(s.item == -1 && s.next_item == -1 && s.frames == 0);
  drain(e);
  s = bk_state(e);
  CHECK(s.item == 1 && s.frames == 1 && s.transport == LE_BACKING_STOPPED);
  CHECK(s.owned == 1);
  le_engine_destroy(e);
}

static void test_backing_play_literal(void) {
  printf("test_backing_play_literal\n");
  enum { N = 4096 };
  le_engine* e = bk_engine(4);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 7, 1) == LE_OK);
  static float out[N * 4];
  bk_run(e, out, N, 4, 64);
  int bad = 0;
  for (int f = 0; f < N; ++f) {
    if (out[4 * f] != bk_l(f) || out[4 * f + 1] != bk_r(f) ||
        out[4 * f + 2] != 0.0f || out[4 * f + 3] != 0.0f) ++bad;
  }
  CHECK(bad == 0);
  le_backing_state s = bk_state(e);
  CHECK(s.item == 7 && s.transport == LE_BACKING_STOPPED && s.position == 0);
  CHECK(s.end_count == 1 && s.last_end == LE_BACKING_EV_STOPPED);
  le_engine_destroy(e);
}

static void test_backing_level_pan_route(void) {
  printf("test_backing_level_pan_route\n");
  enum { N = 512 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_set_level(e, 0.5f) == LE_OK);
  CHECK(le_engine_backing_set_pan(e, 0.5f) == LE_OK);
  float gl, gr;
  le_pan_gains(0.5f, &gl, &gr);
  CHECK(fabsf(gl - 0.70710677f) < 1e-7f && gr == 1.0f);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) {
    CHECK(out[2 * f] == bk_l(f) * 0.5f * gl);
    CHECK(out[2 * f + 1] == bk_r(f) * 0.5f * gr);
  }
  /* One masked channel takes the pair's mid. */
  CHECK(le_engine_backing_set_level(e, 1.0f) == LE_OK);
  CHECK(le_engine_backing_set_pan(e, 0.0f) == LE_OK);
  CHECK(le_engine_backing_set_output(e, 0x1) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) {
    const int k = 64 + f;
    CHECK(out[2 * f] == 0.5f * (bk_l(k) + bk_r(k)));
    CHECK(out[2 * f + 1] == 0.0f);
  }
  /* A structurally disabled output never carries it: the one channel left
   * of the mask takes the mid, as every routed source's would. */
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_set_output_enabled(e, 0, 0) == LE_OK);
  drain(e);
  bk_run(e, out, 64, 2, 64);
  for (int f = 0; f < 64; ++f) {
    CHECK(out[2 * f] == 0.0f);
    CHECK(out[2 * f + 1] == 0.5f * (bk_l(128 + f) + bk_r(128 + f)));
  }
  le_engine_destroy(e);
}

static void test_backing_pause_resume_stop_ramps(void) {
  printf("test_backing_pause_resume_stop_ramps\n");
  enum { N = 8192 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 1000, 2, 100);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PAUSE) == LE_OK);
  bk_run(e, out, 300, 2, 100);
  for (int i = 0; i < 300; ++i) {
    const float g = i < BK_RAMP
                        ? 1.0f * (1.0f - (float)(i + 1) / (float)BK_RAMP)
                        : 0.0f;
    CHECK(out[2 * i] == (i < BK_RAMP ? 0.0f + bk_l(1000 + i) * g : 0.0f));
  }
  le_backing_state s = bk_state(e);
  CHECK(s.transport == LE_BACKING_PAUSED && s.position == 1000);
  /* Resume fades in from the held position. */
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out, 300, 2, 100);
  for (int i = 0; i < 300; ++i) {
    const float g =
        i < BK_RAMP ? (float)(i + 1) / (float)BK_RAMP : 1.0f;
    CHECK(out[2 * i] == bk_l(1000 + i) * g);
  }
  /* Stop fades out and rewinds; Play then starts unfaded at frame 0. */
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_STOP) == LE_OK);
  bk_run(e, out, 300, 2, 100);
  for (int i = 0; i < BK_RAMP; ++i) {
    const float g = 1.0f * (1.0f - (float)(i + 1) / (float)BK_RAMP);
    CHECK(out[2 * i] == 0.0f + bk_l(1300 + i) * g);
  }
  for (int i = BK_RAMP; i < 300; ++i) CHECK(out[2 * i] == 0.0f);
  s = bk_state(e);
  CHECK(s.transport == LE_BACKING_STOPPED && s.position == 0);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out, 4, 2, 4);
  for (int i = 0; i < 4; ++i) CHECK(out[2 * i] == bk_l(i));
  le_engine_destroy(e);
}

static void test_backing_seek_clamp_and_preserve(void) {
  printf("test_backing_seek_clamp_and_preserve\n");
  enum { N = 8192 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  /* Nothing loaded: a seek is a no-op. */
  CHECK(le_engine_backing_seek(e, 100) == LE_OK);
  drain(e);
  CHECK(bk_state(e).position == 0 && bk_state(e).frames == 0);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 0) == LE_OK);
  /* Stopped: the seek moves the position and stays stopped. */
  CHECK(le_engine_backing_seek(e, 3000) == LE_OK);
  drain(e);
  le_backing_state s = bk_state(e);
  CHECK(s.position == 3000 && s.transport == LE_BACKING_STOPPED);
  /* Past the end clamps to the last frame. */
  CHECK(le_engine_backing_seek(e, N + 50) == LE_OK);
  drain(e);
  CHECK(bk_state(e).position == N - 1);
  CHECK(le_engine_backing_seek(e, 3000) == LE_OK);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out, 100, 2, 100); /* away from frame 0: fades in */
  for (int i = 0; i < 100; ++i) {
    CHECK(out[2 * i] == bk_l(3000 + i) * ((float)(i + 1) / (float)BK_RAMP));
  }
  bk_run(e, out, 200, 2, 100); /* ramp done at 3240 */
  /* Seek while playing: the old position fades out while the new fades in. */
  CHECK(le_engine_backing_seek(e, 6000) == LE_OK);
  bk_run(e, out, 300, 2, 100);
  for (int i = 0; i < 300; ++i) {
    float want = 0.0f;
    if (i < BK_RAMP) {
      want += bk_l(3300 + i) * (1.0f * (1.0f - (float)(i + 1) / (float)BK_RAMP));
      want += bk_l(6000 + i) * ((float)(i + 1) / (float)BK_RAMP);
    } else {
      want = 0.0f + bk_l(6000 + i);
    }
    CHECK(out[2 * i] == want);
  }
  s = bk_state(e);
  CHECK(s.transport == LE_BACKING_PLAYING && s.position == 6300);
  /* A seek while paused keeps it paused. */
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PAUSE) == LE_OK);
  CHECK(le_engine_backing_seek(e, 10) == LE_OK);
  bk_run(e, out, BK_RAMP + 10, 2, 50);
  s = bk_state(e);
  CHECK(s.transport == LE_BACKING_PAUSED && s.position == 10);
  le_engine_destroy(e);
}

static void test_backing_end_modes(void) {
  printf("test_backing_end_modes\n");
  enum { N = 300 };
  static float out[1000 * 2];
  /* Stop (the default): silence after the last frame, rewound. */
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(bk_state(e).end_mode == LE_BACKING_END_STOP);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 400, 2, 64);
  CHECK(out[2 * 299] == bk_l(299));
  for (int i = 300; i < 400; ++i) CHECK(out[2 * i] == 0.0f);
  le_backing_state s = bk_state(e);
  CHECK(s.transport == LE_BACKING_STOPPED && s.position == 0);
  CHECK(s.end_count == 1 && s.last_end == LE_BACKING_EV_STOPPED);

  /* Repeat: frame 300 is frame 0 again, unfaded, every lap. */
  CHECK(le_engine_backing_set_end(e, LE_BACKING_END_REPEAT) == LE_OK);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out, 700, 2, 64);
  for (int i = 0; i < 700; ++i) CHECK(out[2 * i] == bk_l(i % N));
  s = bk_state(e);
  CHECK(s.transport == LE_BACKING_PLAYING && s.position == 100);
  CHECK(s.end_count == 3 && s.last_end == LE_BACKING_EV_REPEATED);
  le_engine_destroy(e);

  /* Next with a staged buffer: gapless, the token follows. */
  e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_set_end(e, LE_BACKING_END_NEXT) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  CHECK(le_engine_backing_stage_next(e, bk_buffer(N, 0.5f), 2) == LE_OK);
  drain(e);
  s = bk_state(e);
  CHECK(s.item == 1 && s.next_item == 2 && s.owned == 2);
  bk_run(e, out, 700, 2, 64);
  for (int i = 0; i < N; ++i) CHECK(out[2 * i] == bk_l(i));
  for (int i = N; i < 2 * N; ++i) CHECK(out[2 * i] == 0.5f + bk_l(i - N));
  for (int i = 2 * N; i < 700; ++i) CHECK(out[2 * i] == 0.0f);
  s = bk_state(e);
  CHECK(s.item == 2 && s.next_item == -1);
  CHECK(s.end_count == 2 && s.last_end == LE_BACKING_EV_NEXT_MISSING);
  CHECK(s.transport == LE_BACKING_STOPPED && s.position == 0);
  CHECK(s.owned == 1); /* the first buffer came back and was freed */
  le_engine_destroy(e);
}

static void test_backing_replace_while_playing(void) {
  printf("test_backing_replace_while_playing\n");
  enum { N = 4096 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 500, 2, 100);
  /* B replaces A: A fades out over the ramp while B starts at its frame 0. */
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.25f), 2, 1) == LE_OK);
  CHECK(bk_state(e).owned == 2);
  bk_run(e, out, 300, 2, 100);
  for (int i = 0; i < 300; ++i) {
    float want = 0.0f;
    if (i < BK_RAMP) {
      want += bk_l(500 + i) * (1.0f * (1.0f - (float)(i + 1) / (float)BK_RAMP));
    }
    want += 0.25f + bk_l(i);
    CHECK(out[2 * i] == want);
  }
  le_backing_state s = bk_state(e);
  CHECK(s.item == 2 && s.position == 300 && s.owned == 1);

  /* Registry bound: four engine-owned buffers, then NOT_READY until the
   * callback hands the replaced ones back. */
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 3, 0) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 4, 0) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 5, 0) == LE_OK);
  le_backing_buffer* spare = bk_buffer(N, 0.0f);
  CHECK(le_engine_backing_load(e, spare, 6, 0) == LE_ERR_NOT_READY);
  bk_run(e, out, BK_RAMP + 10, 2, 64);
  s = bk_state(e);
  CHECK(s.item == 5 && s.owned == 1);
  CHECK(le_engine_backing_load(e, spare, 6, 0) == LE_OK);
  /* Clear unloads both slots; a queued buffer dies with destroy (ASan). */
  CHECK(le_engine_backing_stage_next(e, bk_buffer(N, 0.0f), 7) == LE_OK);
  drain(e);
  /* Restaging hands the previous stage back. */
  CHECK(le_engine_backing_stage_next(e, bk_buffer(N, 0.0f), 9) == LE_OK);
  drain(e);
  s = bk_state(e);
  CHECK(s.item == 6 && s.next_item == 9 && s.owned == 2);
  CHECK(le_engine_backing_clear(e) == LE_OK);
  drain(e);
  s = bk_state(e);
  CHECK(s.item == -1 && s.next_item == -1 && s.frames == 0 && s.owned == 0);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 8, 1) == LE_OK);
  le_engine_destroy(e);
}

static void test_backing_independent_of_loops(void) {
  printf("test_backing_independent_of_loops\n");
  enum { N = 4096 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  float pcm[128];
  for (int i = 0; i < 128; ++i) pcm[i] = 0.0f; /* a silent loop */
  CHECK(le_engine_import_track(e, 0, pcm, 128) == LE_OK);
  CHECK(le_engine_commit_session(e, 128, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 256, 2, 64);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  bk_run(e, out, 128, 2, 64);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  bk_run(e, out + 256, 128, 2, 64);
  for (int i = 0; i < 256; ++i) CHECK(out[2 * i] == bk_l(256 + i));
  CHECK(bk_state(e).transport == LE_BACKING_PLAYING);
  /* Cut sound: silent from the next frame, no ramp, rewound. */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64; ++i) CHECK(out[2 * i] == 0.0f && out[2 * i + 1] == 0.0f);
  le_backing_state s = bk_state(e);
  CHECK(s.transport == LE_BACKING_STOPPED && s.position == 0 && s.item == 1);
  le_engine_destroy(e);
}

static void test_backing_output_bus_processes_it(void) {
  printf("test_backing_output_bus_processes_it\n");
  enum { N = 4096 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_set_output_level(e, 0, 0.5f) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64; ++i) CHECK(out[2 * i] == bk_l(i) * 0.5f);
  CHECK(le_engine_set_output_mute(e, 0, 1) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64; ++i) CHECK(out[2 * i] == 0.0f);
  CHECK(le_engine_set_output_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_set_output_level(e, 0, 1.0f) == LE_OK);
  CHECK(le_engine_set_master_gain(e, 0.5f) == LE_OK);
  bk_run(e, out, 64, 2, 64);
  for (int i = 0; i < 64; ++i) CHECK(out[2 * i] == bk_l(128 + i) * 0.5f);
  le_engine_destroy(e);
}

/* The captured bus carries the backing; the master tap reads it before the
 * bus level, exactly as it reads the click and the tracks. */
static void test_backing_in_master_capture(void) {
  printf("test_backing_in_master_capture\n");
  enum { N = 4096 };
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  drain(e);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  static float out[LOOP_N * 2], captured[LOOP_N * 2];
  const int start = bk_state(e).position;
  bk_run(e, out, LOOP_N, 2, LOOP_N);
  CHECK(le_engine_perf_master_pop_for_test(e, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(captured[2 * i] == bk_l(start + i));
    CHECK(captured[2 * i + 1] == bk_r(start + i));
  }
  CHECK(le_perf_disarm(e) == LE_OK);
  le_engine_destroy(e);
}

/* The stems never contain the backing, and no backing command reaches the
 * event log: the track on output 0 renders exactly; the backing on output 1
 * sounded the whole time. */
static void test_backing_excluded_from_stems(void) {
  printf("test_backing_excluded_from_stems\n");
  le_engine* e = bk_engine(2);
  float a[HR_LEN], b[HR_LEN], c[HR_LEN];
  history_layer_patterns(a, b, c);
  CHECK(le_engine_import_track(e, 0, a, HR_LEN) == LE_OK);
  CHECK(le_engine_commit_session(e, HR_LEN, 0) == LE_OK);
  CHECK(le_engine_set_lane_output(e, 0, 0, 0x1) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_backing_set_output(e, 0x2) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(4096, 0.0f), 1, 1) == LE_OK);
  drain(e);
  const char* dir = render_test_dir("backing-stems");
  const char* arm = history_arm_image(e, dir);
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float out[1024 * 2], live[1024];
  bk_run(e, out, 512, 2, 128);
  CHECK(le_engine_backing_seek(e, 2000) == LE_OK);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PAUSE) == LE_OK);
  bk_run(e, out + 512 * 2, 256, 2, 128);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out + 768 * 2, 256, 2, 128);
  CHECK(le_perf_disarm(e) == LE_OK);
  int backing_heard = 0;
  for (int i = 0; i < 1024; ++i) {
    live[i] = out[2 * i];
    if (out[2 * i + 1] != 0.0f) ++backing_heard;
  }
  CHECK(backing_heard > 700);
  for (int code = LE_CMD_BACKING_LOAD; code <= LE_CMD_BACKING_SEEK; ++code) {
    char path[700];
    snprintf(path, sizeof(path), "%s/events.log", dir);
    static unsigned char buf[1 << 20];
    const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
    const size_t count = log_entry_count(n);
    for (size_t i = 0; i < count; ++i) {
      le_perf_log_entry entry;
      decode_log_entry_at(buf, i, &entry);
      CHECK(entry.cmd.code != code);
    }
  }
  history_render_parity(e, dir, arm, live, 1024);
  le_engine_destroy(e);
}

static void test_backing_lifetimes(void) {
  printf("test_backing_lifetimes\n");
  enum { N = 4096 };
  static float out[N * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_set_level(e, 0.5f) == LE_OK);
  CHECK(le_engine_backing_set_end(e, LE_BACKING_END_REPEAT) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 1, 1) == LE_OK);
  CHECK(le_engine_backing_stage_next(e, bk_buffer(N, 0.0f), 2) == LE_OK);
  bk_run(e, out, 600, 2, 100);
  const uint32_t epoch = bk_state(e).epoch;
  /* A retained reopen keeps both buffers, stopped at 0; a load still queued
   * in the ring dies with it (and is freed). */
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 3, 1) == LE_OK);
  int32_t outcome = -1, dropped = -1;
  CHECK(le_engine_reopen_configured(e, BK_SR, 1, 2, BK_SR * 4, &outcome,
                                    &dropped) == LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED);
  le_backing_state s = bk_state(e);
  CHECK(s.epoch == epoch + 1);
  CHECK(s.item == 1 && s.next_item == 2 && s.frames == N && s.owned == 2);
  CHECK(s.transport == LE_BACKING_STOPPED && s.position == 0);
  /* Settings persist like the click's. */
  CHECK(s.mask == 0x3 && s.level == 0.5f && s.end_mode == LE_BACKING_END_REPEAT);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PLAY) == LE_OK);
  bk_run(e, out, 4, 2, 4);
  CHECK(out[0] == bk_l(0) * 0.5f);
  /* A configure frees everything. */
  CHECK(le_engine_configure(e, BK_SR, 1, 2, BK_SR * 4) == LE_OK);
  s = bk_state(e);
  CHECK(s.epoch == epoch + 2);
  CHECK(s.item == -1 && s.next_item == -1 && s.frames == 0 && s.owned == 0);
  CHECK(s.mask == 0x3 && s.level == 0.5f);
  /* A configure while a Pause still fades: the fade voice must let go of
   * the buffer the configure frees (ASan reads freed memory otherwise, and
   * the stale voice would still sound). */
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 10, 1) == LE_OK);
  bk_run(e, out, 100, 2, 100);
  CHECK(le_engine_backing_transport(e, LE_BACKING_OP_PAUSE) == LE_OK);
  bk_run(e, out, 50, 2, 50);
  CHECK(le_engine_configure(e, BK_SR, 1, 2, BK_SR * 4) == LE_OK);
  bk_run(e, out, BK_RAMP, 2, 64);
  for (int i = 0; i < BK_RAMP * 2; ++i) CHECK(out[i] == 0.0f);
  CHECK(bk_state(e).owned == 0);
  /* Destroy with a loaded, a staged, a fading and a queued buffer. */
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 4, 1) == LE_OK);
  CHECK(le_engine_backing_stage_next(e, bk_buffer(N, 0.0f), 5) == LE_OK);
  bk_run(e, out, 100, 2, 100);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 6, 1) == LE_OK);
  bk_run(e, out, 10, 2, 10);
  CHECK(le_engine_backing_load(e, bk_buffer(N, 0.0f), 7, 1) == LE_OK);
  le_engine_destroy(e);
}


/* The byte budget (M1): two maximal buffers fit, a third is refused with
 * CAPACITY while nothing is in transit, NOT_READY while one is. */
static void test_backing_byte_budget(void) {
  printf("test_backing_byte_budget\n");
  le_engine* e = bk_engine(2);
  /* Fake sizes: the registry counts bytes from frames; three 600 MB
   * buffers' worth of frames without allocating them. */
  const int32_t big = (int32_t)(600ll * 1024 * 1024 / 8);
  le_backing_buffer* b[3];
  for (int i = 0; i < 3; ++i) {
    b[i] = bk_buffer(4, 0.0f);
    b[i]->frames = big; /* never read: the voice stays stopped */
  }
  CHECK(le_engine_backing_load(e, b[0], 1, 0) == LE_OK);
  CHECK(le_engine_backing_stage_next(e, b[1], 2) == LE_OK);
  drain(e);
  const int32_t third = le_engine_backing_load(e, b[2], 3, 0);
  CHECK(third == LE_ERR_CAPACITY);
  le_backing_state s = bk_state(e);
  CHECK(s.owned == 2 && s.owned_bytes == 2ll * big * 8);
  drain(e); /* a wrongly accepted third would be loaded, never played */
  for (int i = 0; i < 3; ++i) b[i]->frames = 4; /* real sizes for teardown */
  if (third != LE_OK) le_backing_buffer_free(b[2]);
  le_engine_destroy(e);

  /* Review L1: a replaced buffer still fading is in transit, so a stage that
   * fits once it is back reads NOT_READY (retry), not CAPACITY. */
  static float out[1024 * 2];
  e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  le_backing_buffer* a = bk_buffer(4096, 0.0f);
  CHECK(le_engine_backing_load(e, a, 1, 1) == LE_OK);
  bk_run(e, out, 100, 2, 100);
  /* Only the byte count grows: the fade reads positions below 400. */
  a->frames = big;
  le_backing_buffer* bb = bk_buffer(4, 0.0f);
  le_backing_buffer* c = bk_buffer(4, 0.0f);
  bb->frames = big;
  c->frames = big;
  CHECK(le_engine_backing_load(e, bb, 2, 0) == LE_OK); /* stays stopped */
  bk_run(e, out, 10, 2, 10); /* applied: a fades out on the second voice */
  CHECK(le_engine_backing_stage_next(e, c, 3) == LE_ERR_NOT_READY);
  bk_run(e, out, BK_RAMP + 10, 2, 64); /* the fade ends and hands a back */
  CHECK(le_engine_backing_stage_next(e, c, 3) == LE_OK);
  drain(e);
  CHECK(bk_state(e).owned == 2);
  bb->frames = 4;
  c->frames = 4;
  le_engine_destroy(e);
}

/* The End = Next advance never drops a buffer: with every return slot taken
 * (forced here; the registry bound makes it unreachable otherwise) the
 * callback stops instead of advancing. */
static void test_backing_advance_refused_when_returns_full(void) {
  printf("test_backing_advance_refused_when_returns_full\n");
  static float out[600 * 2];
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_set_end(e, LE_BACKING_END_NEXT) == LE_OK);
  CHECK(le_engine_backing_load(e, bk_buffer(300, 0.0f), 1, 1) == LE_OK);
  CHECK(le_engine_backing_stage_next(e, bk_buffer(300, 0.5f), 2) == LE_OK);
  drain(e);
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    atomic_store_explicit(&e->a_backing_dead[i], bk_buffer(1, 0.0f),
                          memory_order_relaxed);
  }
  bk_run(e, out, 400, 2, 64);
  for (int i = 300; i < 400; ++i) CHECK(out[2 * i] == 0.0f);
  /* Collecting frees the four placeholders; the loaded and staged stay. */
  le_backing_state s = bk_state(e);
  CHECK(s.item == 1 && s.next_item == 2);
  CHECK(s.transport == LE_BACKING_STOPPED);
  CHECK(s.last_end == LE_BACKING_EV_NEXT_MISSING && s.owned == 2);
  le_engine_destroy(e);
}

/* A performance with the backing on the captured bus says so in its
 * sidecar (L8); one without it does not. */
static void test_backing_marks_capture(void) {
  printf("test_backing_marks_capture\n");
  /* One engine, routed then unrouted: the second capture's marker must not
   * carry over from the first (the count resets at arm). */
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_load(e, bk_buffer(8192, 0.0f), 1, 1) == LE_OK);
  for (int pass = 0; pass < 2; ++pass) {
    const int routed = pass == 0;
    CHECK(le_engine_backing_set_output(e, routed ? 0x3 : 0x0) == LE_OK);
    drain(e);
    const char* dir =
        render_test_dir(routed ? "backing-mark-1" : "backing-mark-0");
    CHECK(le_perf_arm(e, dir) == LE_OK);
    drain(e);
    static float out[512 * 2];
    bk_run(e, out, 512, 2, 128);
    CHECK(le_perf_disarm(e) == LE_OK);
    CHECK(history_manifest_count(dir, "\"backing_in_master\": true") ==
          routed);
  }
  le_engine_destroy(e);
}

static void test_click_pan(void) {
  printf("test_click_pan\n");
  le_engine* e = ck_make_engine(2);
  double energy[2] = {0};
  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x3) == LE_OK);
  CHECK(le_engine_set_click_pan(e, -1.0f) == LE_OK);
  CHECK(bk_state(e).click_pan == -1.0f);
  ck_run(e, 1, 2, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_FPB, 2, energy, NULL);
  CHECK(energy[0] > 0.5);
  CHECK(energy[1] == 0.0); /* hard left: the right jack is exactly silent */
  /* Centre: both jacks carry the same sample, as an unpanned click does. */
  CHECK(le_engine_set_click_pan(e, 0.0f) == LE_OK);
  static float out[CK_FPB * 2];
  bk_run(e, out, CK_FPB, 2, 64);
  int differ = 0, sounding = 0;
  for (int i = 0; i < CK_FPB; ++i) {
    if (out[2 * i] != out[2 * i + 1]) ++differ;
    if (out[2 * i] != 0.0f) ++sounding;
  }
  CHECK(differ == 0 && sounding > 0);
  le_engine_destroy(e);
}

static void run_backing_tests(void) {
  test_backing_buffer_and_refusals();
  test_backing_play_literal();
  test_backing_level_pan_route();
  test_backing_pause_resume_stop_ramps();
  test_backing_seek_clamp_and_preserve();
  test_backing_end_modes();
  test_backing_replace_while_playing();
  test_backing_independent_of_loops();
  test_backing_output_bus_processes_it();
  test_backing_in_master_capture();
  test_backing_excluded_from_stems();
  test_backing_lifetimes();
  test_backing_byte_budget();
  test_backing_advance_refused_when_returns_full();
  test_backing_marks_capture();
  test_click_pan();
}
