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


/* ---- Part 2: the offline converter and the file decoder ---- */

/* Amplitude and residual of the [hz] component of x (stride [stride]) over
 * [n] samples at [sr]; n must hold whole cycles. *residual_db is the RMS of
 * what is left after removing that sinusoid, relative to its amplitude. */
static double bk_tone(const float* x, int stride, int n, double hz, double sr,
                      double* residual_db) {
  double a = 0.0, b = 0.0;
  for (int i = 0; i < n; ++i) {
    const double w = 2.0 * M_PI * hz * i / sr;
    a += x[(size_t)i * stride] * cos(w);
    b += x[(size_t)i * stride] * sin(w);
  }
  a *= 2.0 / n;
  b *= 2.0 / n;
  const double amp = sqrt(a * a + b * b);
  if (residual_db != NULL) {
    double sq = 0.0;
    for (int i = 0; i < n; ++i) {
      const double w = 2.0 * M_PI * hz * i / sr;
      const double r = x[(size_t)i * stride] - (a * cos(w) + b * sin(w));
      sq += r * r;
    }
    *residual_db = 20.0 * log10(sqrt(sq / n) / (amp / sqrt(2.0)) + 1e-30);
  }
  return amp;
}

/* Converts one mono plane; returns the output (caller frees) and its length. */
static float* bk_convert(const float* in, int n, int from, int to, int* out_n) {
  *out_n = (int)le_resample_frames(n, from, to);
  float* out = malloc((size_t)*out_n * sizeof(float));
  CHECK(le_resample_offline(in, 1, n, from, out, 1, *out_n, to) == LE_OK);
  return out;
}

static float* bk_sine(int n, double hz, double sr, float amp) {
  float* x = malloc((size_t)n * sizeof(float));
  for (int i = 0; i < n; ++i) x[i] = amp * (float)sin(2.0 * M_PI * hz * i / sr);
  return x;
}

static void test_resample_identity_and_guards(void) {
  printf("test_resample_identity_and_guards\n");
  float in[100], out[100];
  for (int i = 0; i < 100; ++i) in[i] = bk_l(i) - 0.003f * (float)(i % 7);
  CHECK(le_resample_offline(in, 1, 100, 48000, out, 1, 100, 48000) == LE_OK);
  for (int i = 0; i < 100; ++i) CHECK(out[i] == in[i]);
  /* Strided: every other sample of in, into every other slot of out. */
  float strided[100] = {0};
  CHECK(le_resample_offline(in, 2, 50, 48000, strided, 2, 50, 48000) == LE_OK);
  for (int i = 0; i < 50; ++i) CHECK(strided[2 * i] == in[2 * i] && strided[2 * i + 1] == 0.0f);
  CHECK(le_resample_frames(44100, 44100, 48000) == 48000);
  CHECK(le_resample_frames(1000, 48000, 44100) == 918);
  /* A wrong length, a reduction below one half, bad arguments. */
  CHECK(le_resample_offline(in, 1, 100, 48000, out, 1, 99, 48000) == LE_ERR_INVALID);
  CHECK(le_resample_offline(in, 1, 100, 96001, out, 1, 49, 48000) == LE_ERR_INVALID);
  CHECK(le_resample_offline(NULL, 1, 100, 48000, out, 1, 100, 48000) == LE_ERR_INVALID);
  CHECK(le_resample_offline(in, 0, 100, 48000, out, 1, 100, 48000) == LE_ERR_INVALID);
}

static void test_resample_dc_tone_and_alignment(void) {
  printf("test_resample_dc_tone_and_alignment\n");
  const int rates[][2] = {{44100, 48000}, {48000, 44100}, {96000, 48000},
                          {44100, 96000}, {48000, 96000}, {88200, 48000}};
  for (size_t k = 0; k < sizeof(rates) / sizeof(rates[0]); ++k) {
    const int from = rates[k][0], to = rates[k][1];
    const int n = from; /* one second */
    float* dc = malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; ++i) dc[i] = 0.5f;
    int m = 0;
    float* y = bk_convert(dc, n, from, to, &m);
    CHECK(m == (int)((int64_t)n * to / from));
    double worst = 0.0;
    for (int i = 200; i < m - 200; ++i) {
      if (fabs(y[i] - 0.5) > worst) worst = fabs(y[i] - 0.5);
    }
    if (worst >= 1e-6) printf("  dc %d->%d worst %g\n", from, to, worst);
    CHECK(worst < 1e-6);
    free(y);
    free(dc);
    /* 1 kHz at amplitude 0.5: level within 0.01 dB, residual below -90 dB,
     * measured over 100 whole cycles in the middle. */
    float* tone = bk_sine(n, 1000.0, from, 0.5f);
    y = bk_convert(tone, n, from, to, &m);
    const int win = to / 10; /* 100 cycles of 1 kHz */
    double residual = 0.0;
    const double amp = bk_tone(y + to / 4, 1, win, 1000.0, to, &residual);
    if (fabs(amp - 0.5) >= 0.0006 || residual >= -90.0)
      printf("  tone %d->%d amp %.7f residual %.1f dB\n", from, to, amp, residual);
    CHECK(fabs(amp - 0.5) < 0.0006);
    CHECK(residual < -90.0);
    free(y);
    free(tone);
  }
  /* Alignment: an impulse at input 1000 peaks at output 2000 when doubling. */
  float* imp = calloc(4000, sizeof(float));
  imp[1000] = 1.0f;
  int m = 0;
  float* y = bk_convert(imp, 4000, 48000, 96000, &m);
  int at = 0;
  for (int i = 0; i < m; ++i) {
    if (fabsf(y[i]) > fabsf(y[at])) at = i;
  }
  CHECK(at == 2000);
  free(y);
  free(imp);
}

/* Content the destination cannot hold is removed, not folded back: a 30 kHz
 * tone halved from 96 kHz leaves no 18 kHz alias; a 10 kHz tone raised from
 * 44.1 kHz leaves no 34.1 kHz image. */
static void test_resample_alias_and_image(void) {
  printf("test_resample_alias_and_image\n");
  int m = 0;
  float* tone = bk_sine(96000, 30000.0, 96000, 0.5f);
  float* y = bk_convert(tone, 96000, 96000, 48000, &m);
  const double alias = bk_tone(y + 12000, 1, 4800, 18000.0, 48000, NULL);
  if (alias >= 0.5e-4) printf("  alias at 18 kHz %g\n", alias);
  CHECK(alias < 0.5e-4); /* -80 dB re 0.5 */
  free(y);
  free(tone);
  tone = bk_sine(44100, 10000.0, 44100, 0.5f);
  y = bk_convert(tone, 44100, 44100, 96000, &m);
  const double kept = bk_tone(y + 24000, 1, 9600, 10000.0, 96000, NULL);
  const double image = bk_tone(y + 24000, 1, 9600, 34100.0, 96000, NULL);
  if (image >= 0.5e-4) printf("  image at 34.1 kHz %g\n", image);
  CHECK(fabs(kept - 0.5) < 0.0006);
  CHECK(image < 0.5e-4);
  free(y);
  free(tone);
}

/* ---- WAV writer for the decode tests ---- */

static void bk_put16(unsigned char* p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static void bk_put32(unsigned char* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = (unsigned char)(v >> (8 * i));
}

/* Writes a WAV with format code [fmt] (1 PCM, 3 float) and [bits] per
 * sample. [data] holds [frames] * [ch] samples already in that encoding.
 * [claim_bytes] overrides the data chunk size in the header (0 = actual). */
static void bk_write_wav(const char* path, int fmt, int bits, int ch, int sr,
                         const void* data, int frames, uint32_t claim_bytes) {
  const uint32_t bytes = (uint32_t)frames * (uint32_t)ch * (uint32_t)(bits / 8);
  const uint32_t stated = claim_bytes ? claim_bytes : bytes;
  unsigned char h[44] = {0};
  memcpy(h, "RIFF", 4);
  bk_put32(h + 4, 36 + stated);
  memcpy(h + 8, "WAVEfmt ", 8);
  bk_put32(h + 16, 16);
  bk_put16(h + 20, (uint16_t)fmt);
  bk_put16(h + 22, (uint16_t)ch);
  bk_put32(h + 24, (uint32_t)sr);
  bk_put32(h + 28, (uint32_t)(sr * ch * bits / 8));
  bk_put16(h + 32, (uint16_t)(ch * bits / 8));
  bk_put16(h + 34, (uint16_t)bits);
  memcpy(h + 36, "data", 4);
  bk_put32(h + 40, stated);
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  fwrite(h, 1, sizeof(h), f);
  fwrite(data, 1, bytes, f);
  fclose(f);
}

static const char* bk_path(const char* name) {
  static char path[700];
  test_render_mkdir(perf_test_dir());
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), name);
  return path;
}

static void test_backing_decode_wav_formats(void) {
  printf("test_backing_decode_wav_formats\n");
  enum { N = 1000 };
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  /* 16-bit stereo: L = k - 500, R = 3 (k - 500), exactly k / 32768 on read. */
  int16_t s16[N * 2];
  for (int k = 0; k < N; ++k) {
    s16[2 * k] = (int16_t)(k - 500);
    s16[2 * k + 1] = (int16_t)(3 * (k - 500));
  }
  bk_write_wav(bk_path("s16.wav"), 1, 16, 2, 48000, s16, N, 0);
  CHECK(le_backing_decode_file(bk_path("s16.wav"), 48000, 0, 0, &b, &info) == LE_OK);
  CHECK(info.source_rate == 48000 && info.source_channels == 2 && le_backing_buffer_frames(b) == N);
  CHECK(info.source_frames == N && info.truncated == 0);
  for (int k = 0; k < N && b; ++k) {
    CHECK(b->pcm[2 * k] == (float)(k - 500) / 32768.0f);
    CHECK(b->pcm[2 * k + 1] == (float)(3 * (k - 500)) / 32768.0f);
  }
  le_backing_buffer_free(b);
  /* 24-bit mono plays dual mono. */
  unsigned char s24[N * 3];
  for (int k = 0; k < N; ++k) {
    const int32_t v = (k - 500) * 4099;
    s24[3 * k] = (unsigned char)(v & 0xFF);
    s24[3 * k + 1] = (unsigned char)((v >> 8) & 0xFF);
    s24[3 * k + 2] = (unsigned char)((v >> 16) & 0xFF);
  }
  bk_write_wav(bk_path("s24.wav"), 1, 24, 1, 48000, s24, N, 0);
  CHECK(le_backing_decode_file(bk_path("s24.wav"), 48000, 0, 0, &b, &info) == LE_OK);
  CHECK(info.source_channels == 1 && le_backing_buffer_frames(b) == N);
  for (int k = 0; k < N && b; ++k) {
    const float want = (float)((k - 500) * 4099) / 8388608.0f;
    CHECK(b->pcm[2 * k] == want && b->pcm[2 * k + 1] == want);
  }
  le_backing_buffer_free(b);
  /* 32-bit float stereo is exact. */
  float f32[N * 2];
  for (int k = 0; k < N; ++k) {
    f32[2 * k] = bk_l(k);
    f32[2 * k + 1] = -bk_r(k);
  }
  bk_write_wav(bk_path("f32.wav"), 3, 32, 2, 48000, f32, N, 0);
  CHECK(le_backing_decode_file(bk_path("f32.wav"), 48000, 0, 0, &b, NULL) == LE_OK);
  for (int k = 0; k < N && b; ++k) {
    CHECK(b->pcm[2 * k] == bk_l(k) && b->pcm[2 * k + 1] == -bk_r(k));
  }
  le_backing_buffer_free(b);
  /* A 44.1 kHz file read for a 48 kHz engine is converted on the way. */
  CHECK(le_backing_decode_file(bk_path("f32.wav"), 44100, 0, 0, &b, &info) == LE_OK);
  CHECK(info.source_rate == 48000 && le_backing_buffer_frames(b) == 918);
  CHECK(le_backing_buffer_rate(b) == 44100);
  le_backing_buffer_free(b);
}

/* A 192 kHz file on a 48 kHz engine halves exactly to 96 kHz, then
 * converts: the 1 kHz tone keeps its level, and a 40 kHz tone the engine
 * rate cannot hold leaves no 8 kHz alias. */
static void test_backing_decode_192k(void) {
  printf("test_backing_decode_192k\n");
  enum { N = 192000 };
  float* x = malloc((size_t)N * sizeof(float));
  for (int i = 0; i < N; ++i) {
    x[i] = 0.25f * (float)sin(2.0 * M_PI * 1000.0 * i / 192000.0) +
           0.25f * (float)sin(2.0 * M_PI * 40000.0 * i / 192000.0);
  }
  bk_write_wav(bk_path("hi.wav"), 3, 32, 1, 192000, x, N, 0);
  free(x);
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  CHECK(le_backing_decode_file(bk_path("hi.wav"), 48000, 0, 0, &b, &info) == LE_OK);
  CHECK(info.source_rate == 192000 && le_backing_buffer_frames(b) == 48000);
  if (b != NULL) {
    const double kept = bk_tone(b->pcm + 2 * 12000, 2, 4800, 1000.0, 48000, NULL);
    const double alias = bk_tone(b->pcm + 2 * 12000, 2, 4800, 8000.0, 48000, NULL);
    if (fabs(kept - 0.25) >= 0.0003 || alias >= 0.25e-4)
      printf("  192k kept %.7f alias %g\n", kept, alias);
    CHECK(fabs(kept - 0.25) < 0.0003);
    CHECK(alias < 0.25e-4); /* -80 dB re 0.25 */
  }
  le_backing_buffer_free(b);
}

/* MP3 decodes; FLAC is compiled out (CVE-2024-41147) and is refused as an
 * unsupported format before any decoder sees it. */
static void test_backing_decode_mp3_and_no_flac(void) {
  printf("test_backing_decode_mp3_and_no_flac\n");
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  CHECK(le_backing_decode_file("src/test/fixtures/backing/sine1k_44k1_mono.flac",
                               48000, 0, 0, &b, &info) == LE_ERR_UNSUPPORTED);
  CHECK(b == NULL);
  /* 41 MPEG frames (47232 at 44.1 kHz: miniaudio keeps the encoder delay and
   * end padding, see the fixture README) converted to 48 kHz, the 1 kHz tone
   * dominant on both sides. */
  CHECK(le_backing_decode_file("src/test/fixtures/backing/sine1k_44k1_stereo.mp3",
                               48000, 0, 0, &b, &info) == LE_OK);
  CHECK(info.source_rate == 44100 && info.source_channels == 2);
  CHECK(info.source_frames == 47232);
  const int frames = le_backing_buffer_frames(b);
  CHECK(frames == (int)le_resample_frames(47232, 44100, 48000)); /* 51408 */
  if (b != NULL) {
    for (int side = 0; side < 2; ++side) {
      double residual = 0.0;
      const double amp =
          bk_tone(b->pcm + 2 * 12000 + side, 2, 4800, 1000.0, 48000, &residual);
      CHECK(fabs(amp - 0.125) < 0.01);
      CHECK(residual < -40.0);
    }
  }
  le_backing_buffer_free(b);
}

/* An 8 kHz 16-bit mono WAV one second over the cap. */
static int64_t bk_mem_tight(void) { return LE_MEM_RESERVE_BYTES + 100ll * 1024 * 1024; }

static void bk_write_long_wav(void) {
  const int n = (LE_BACKING_MAX_SECONDS + 1) * 8000;
  int16_t* pcm = calloc((size_t)n, sizeof(int16_t));
  bk_write_wav(bk_path("long.wav"), 1, 16, 1, 8000, pcm, n, 0);
  free(pcm);
}

static void test_backing_decode_refusals(void) {
  printf("test_backing_decode_refusals\n");
  le_backing_buffer* b = (le_backing_buffer*)1;
  CHECK(le_backing_decode_file(NULL, 48000, 0, 0, &b, NULL) == LE_ERR_INVALID);
  CHECK(b == NULL);
  CHECK(le_backing_decode_file("", 48000, 0, 0, &b, NULL) == LE_ERR_INVALID);
  CHECK(le_backing_decode_file(bk_path("absent.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_INVALID);
  FILE* f = fopen(bk_path("truncated.wav"), "wb");
  CHECK(f != NULL);
  if (f) { fwrite("RIFF\0\0\0\0WAVE", 1, 12, f); fclose(f); }
  CHECK(le_backing_decode_file(bk_path("truncated.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_INVALID);
  f = fopen(bk_path("text.wav"), "wb");
  CHECK(f != NULL);
  if (f) { fputs("not audio, just words in a file named like one\n", f); fclose(f); }
  CHECK(le_backing_decode_file(bk_path("text.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_UNSUPPORTED);
  int16_t quad[4 * 64] = {0};
  bk_write_wav(bk_path("quad.wav"), 1, 16, 4, 48000, quad, 64, 0);
  CHECK(le_backing_decode_file(bk_path("quad.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_UNSUPPORTED);
  /* A real 901 s file (8 kHz, 16-bit: 14.4 MB) is refused as too long from
   * its stated length, before the decode allocates for it. */
  bk_write_long_wav();
  le_test_mem_available_hook = bk_mem_tight; /* allocating it would refuse */
  CHECK(le_backing_decode_file(bk_path("long.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_TOO_LONG);
  le_test_mem_available_hook = NULL;
  CHECK(b == NULL);
  le_backing_decode_info info;
  CHECK(le_backing_probe_file(bk_path("long.wav"), &info, NULL, 0) ==
        LE_ERR_TOO_LONG);
  /* A header stating 901 s over 64 frames states more than the file could
   * hold, and is refused as damaged before it sizes anything. */
  int16_t few[64] = {0};
  bk_write_wav(bk_path("liar.wav"), 1, 16, 1, 48000, few, 64,
               (uint32_t)(LE_BACKING_MAX_SECONDS + 1) * 48000u * 2u);
  CHECK(le_backing_decode_file(bk_path("liar.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_INVALID);
  CHECK(b == NULL);
}


/* A bounded read (preview, recording part): starts where asked, keeps at
 * most max_frames, says it stopped early; at the engine rate it is exact. */
static void test_backing_decode_bounded(void) {
  printf("test_backing_decode_bounded\n");
  enum { N = 5000 };
  int16_t s16[N];
  for (int k = 0; k < N; ++k) s16[k] = (int16_t)(k - 2500);
  bk_write_wav(bk_path("bounded.wav"), 1, 16, 1, 48000, s16, N, 0);
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  CHECK(le_backing_decode_file(bk_path("bounded.wav"), 48000, 1000, 300, &b,
                               &info) == LE_OK);
  CHECK(le_backing_buffer_frames(b) == 300 && info.truncated == 1);
  for (int k = 0; k < 300 && b; ++k) {
    CHECK(b->pcm[2 * k] == (float)(1000 + k - 2500) / 32768.0f);
  }
  le_backing_buffer_free(b);
  /* Up to the end: not truncated. */
  CHECK(le_backing_decode_file(bk_path("bounded.wav"), 48000, 4900, 300, &b,
                               &info) == LE_OK);
  CHECK(le_backing_buffer_frames(b) == 100 && info.truncated == 0);
  le_backing_buffer_free(b);
  /* Past the end, or negative arguments. */
  CHECK(le_backing_decode_file(bk_path("bounded.wav"), 48000, N, 300, &b,
                               &info) == LE_ERR_INVALID);
  CHECK(le_backing_decode_file(bk_path("bounded.wav"), 48000, -1, 0, &b,
                               &info) == LE_ERR_INVALID);
  /* A bounded read of a file longer than the cap is allowed: it reads only
   * what it keeps. */
  bk_write_long_wav();
  CHECK(le_backing_decode_file(bk_path("long.wav"), 48000, 0, 32, &b,
                               &info) == LE_OK);
  CHECK(le_backing_buffer_frames(b) == 32 && info.truncated == 1);
  le_backing_buffer_free(b);
}

/* The probe decodes everything, keeps nothing, and peaks it. */
static void test_backing_probe(void) {
  printf("test_backing_probe\n");
  enum { N = 10000 };
  int16_t s16[N * 2];
  for (int k = 0; k < N; ++k) {
    s16[2 * k] = (int16_t)(k < N / 2 ? 1000 : 2000);
    s16[2 * k + 1] = (int16_t)(k < N / 2 ? -3000 : 0);
  }
  bk_write_wav(bk_path("probe.wav"), 1, 16, 2, 44100, s16, N, 0);
  le_backing_decode_info info;
  float peaks[2];
  CHECK(le_backing_probe_file(bk_path("probe.wav"), &info, peaks, 2) == LE_OK);
  CHECK(info.source_rate == 44100 && info.source_channels == 2);
  CHECK(info.source_frames == N);
  CHECK(peaks[0] == 3000.0f / 32768.0f && peaks[1] == 2000.0f / 32768.0f);
  CHECK(le_backing_probe_file(bk_path("probe.wav"), &info, NULL, 0) == LE_OK);
  CHECK(le_backing_probe_file("src/test/fixtures/backing/sine1k_44k1_stereo.mp3",
                              &info, peaks, 2) == LE_OK);
  CHECK(info.source_frames == 47232);
  CHECK(le_backing_probe_file(bk_path("absent.wav"), &info, peaks, 2) ==
        LE_ERR_INVALID);
}

static int64_t bk_mem_bytes;
static int64_t bk_mem_given(void) { return LE_MEM_RESERVE_BYTES + bk_mem_bytes; }

/* Whether a whole decode of [path] at [rate] succeeds with exactly [bytes]
 * available above the reserve. */
static int32_t bk_decode_with(const char* path, int32_t rate, int64_t bytes) {
  le_backing_buffer* b = NULL;
  bk_mem_bytes = bytes;
  le_test_mem_available_hook = bk_mem_given;
  const int32_t rc = le_backing_decode_file(path, rate, 0, 0, &b, NULL);
  le_test_mem_available_hook = NULL;
  CHECK((rc == LE_OK) == (b != NULL));
  le_backing_buffer_free(b);
  return rc;
}

/* A decode whose peak would leave less than the reserve is refused before it
 * allocates; unknown memory (-1) is not refused. The peak counts every term
 * (review L3, M2): the source and the stereo output; on the halving path,
 * the planes the source is read into plus one channel's first halving. */
static void test_backing_decode_memory_guard(void) {
  printf("test_backing_decode_memory_guard\n");
  enum { N = 2000 };
  int16_t s16[N] = {0};
  bk_write_wav(bk_path("mem.wav"), 1, 16, 1, 48000, s16, N, 0);
  /* Mono at the engine rate: source N floats, output (N + 1) x 2. */
  const int64_t peak = ((int64_t)N + 2 * (N + 1)) * 4;
  CHECK(bk_decode_with(bk_path("mem.wav"), 48000, peak - 4) == LE_ERR_CAPACITY);
  CHECK(bk_decode_with(bk_path("mem.wav"), 48000, N * 4 + 64) ==
        LE_ERR_CAPACITY); /* the source alone would fit */
  CHECK(bk_decode_with(bk_path("mem.wav"), 48000, peak) == LE_OK);
  /* Stereo 192 kHz on a 44.1 kHz engine halves twice: the planes (2H) plus
   * one half plane (H / 2) outweigh the planes plus the stereo output
   * (2 x 1838), so this is the term that has to be counted. */
  enum { H = 8000 };
  float* hi = calloc((size_t)H * 2, sizeof(float));
  bk_write_wav(bk_path("mem192.wav"), 3, 32, 2, 192000, hi, H, 0);
  free(hi);
  const int64_t hpeak = ((int64_t)H * 2 + H / 2 + 1) * 4;
  CHECK(bk_decode_with(bk_path("mem192.wav"), 44100, hpeak - 4) ==
        LE_ERR_CAPACITY);
  CHECK(bk_decode_with(bk_path("mem192.wav"), 44100, hpeak) == LE_OK);
  /* Unknown memory is not refused. */
  le_backing_buffer* b = NULL;
  CHECK(le_backing_decode_file(bk_path("mem.wav"), 48000, 0, 0, &b, NULL) ==
        LE_OK);
  le_backing_buffer_free(b);
}

/* What the header claims is checked before it sizes anything, and a file
 * that decodes to another length than it states is damaged. */
static void test_backing_decode_header_checks(void) {
  printf("test_backing_decode_header_checks\n");
  int16_t s16[64] = {0};
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  bk_write_wav(bk_path("slow.wav"), 1, 16, 1, 4000, s16, 64, 0);
  CHECK(le_backing_decode_file(bk_path("slow.wav"), 48000, 0, 0, &b, &info) ==
        LE_ERR_UNSUPPORTED);
  bk_write_wav(bk_path("fast.wav"), 1, 16, 1, 384000, s16, 64, 0);
  CHECK(le_backing_decode_file(bk_path("fast.wav"), 48000, 0, 0, &b, &info) ==
        LE_ERR_UNSUPPORTED);
  CHECK(le_backing_probe_file(bk_path("fast.wav"), &info, NULL, 0) ==
        LE_ERR_UNSUPPORTED);
  /* States 1000 frames, holds 64. */
  bk_write_wav(bk_path("short.wav"), 1, 16, 1, 48000, s16, 64, 2000);
  CHECK(le_backing_decode_file(bk_path("short.wav"), 48000, 0, 0, &b, &info) ==
        LE_ERR_INVALID);
  CHECK(le_backing_probe_file(bk_path("short.wav"), &info, NULL, 0) ==
        LE_ERR_INVALID);
  CHECK(b == NULL);
  /* An engine rate out of range is a bad argument. */
  bk_write_wav(bk_path("ok.wav"), 1, 16, 1, 48000, s16, 64, 0);
  CHECK(le_backing_decode_file(bk_path("ok.wav"), 0, 0, 0, &b, &info) ==
        LE_ERR_INVALID);
}


/* ---- P2 review: the whitelist, non-finite samples, bounded reads ---- */

#define BK_FIX "src/test/fixtures/backing/"

/* Probe and whole decode both answer [want]. */
static void bk_expect(const char* path, int32_t want) {
  le_backing_decode_info info;
  le_backing_buffer* b = NULL;
  const int32_t probe = le_backing_probe_file(path, &info, NULL, 0);
  const int32_t decode = le_backing_decode_file(path, 48000, 0, 0, &b, &info);
  if (probe != want || decode != want) {
    printf("  %s: probe %d decode %d, want %d\n", path, probe, decode, want);
  }
  CHECK(probe == want);
  CHECK(decode == want);
  CHECK((decode == LE_OK) == (b != NULL));
  le_backing_buffer_free(b);
}

/* A WAV with an arbitrary fmt body and optional extra chunk ahead of data. */
static void bk_write_raw_wav(const char* path, const unsigned char* fmt,
                             uint32_t fmt_len, const char* extra_id,
                             uint32_t extra_len, uint32_t extra_claim,
                             uint32_t data_len) {
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  unsigned char h[8];
  const uint32_t extra = extra_id ? 8 + extra_len + (extra_len & 1) : 0;
  fwrite("RIFF", 1, 4, f);
  bk_put32(h, 4 + 8 + fmt_len + extra + 8 + data_len);
  fwrite(h, 1, 4, f);
  fwrite("WAVEfmt ", 1, 8, f);
  bk_put32(h, fmt_len);
  fwrite(h, 1, 4, f);
  fwrite(fmt, 1, fmt_len, f);
  if (extra_id) {
    fwrite(extra_id, 1, 4, f);
    bk_put32(h, extra_claim);
    fwrite(h, 1, 4, f);
    for (uint32_t i = 0; i < extra_len + (extra_len & 1); ++i) fputc(0, f);
  }
  fwrite("data", 1, 4, f);
  bk_put32(h, data_len);
  fwrite(h, 1, 4, f);
  /* Small values in every encoding (float or PCM): byte 3 stays 0. */
  for (uint32_t i = 0; i < data_len; ++i) fputc(i % 4 == 3 ? 0 : (int)(i * 7u) & 0x7F, f);
  fclose(f);
}

/* A fmt body: [tag] (0xFFFE: EXTENSIBLE with subformat [sub]). */
static uint32_t bk_fmt(unsigned char* f, uint16_t tag, uint16_t sub, int ch,
                       int sr, int bits) {
  memset(f, 0, 40);
  bk_put16(f, tag);
  bk_put16(f + 2, (uint16_t)ch);
  bk_put32(f + 4, (uint32_t)sr);
  bk_put32(f + 8, (uint32_t)(sr * ch * bits / 8));
  bk_put16(f + 12, (uint16_t)(ch * bits / 8));
  bk_put16(f + 14, (uint16_t)bits);
  if (tag != 0xFFFE) return 16;
  static const unsigned char tail[14] = {0x00, 0x00, 0x00, 0x00, 0x10,
                                         0x00, 0x80, 0x00, 0x00, 0xAA,
                                         0x00, 0x38, 0x9B, 0x71};
  bk_put16(f + 16, 22);
  bk_put16(f + 18, (uint16_t)bits);
  bk_put32(f + 20, ch == 1 ? 0x4u : 0x3u);
  bk_put16(f + 24, sub);
  memcpy(f + 26, tail, sizeof(tail));
  return 40;
}

/* Only WAV PCM 16/24/32 and float32 (plain or EXTENSIBLE) and MPEG Layer
 * III reach a decoder; the review's reproducers are refused, and quickly
 * (H1: 256 channels aborted the process; H2: a short fact chunk and a
 * Wave64 chunk size hung for hours; M1: MS-ADPCM read out of bounds; L1:
 * 44101 Hz probed fine and failed to decode). */
static void test_backing_decode_whitelist(void) {
  printf("test_backing_decode_whitelist\n");
  bk_expect(BK_FIX "ch256_s16.wav", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "fact0_fmt1.wav", LE_ERR_INVALID);
  bk_expect(BK_FIX "msadpcm_oob.wav", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "w64_huge_chunk.bin", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "r44101.wav", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "layer2.mp2", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "tiny.aiff", LE_ERR_UNSUPPORTED);
  bk_expect(BK_FIX "sine1k_44k1_mono.flac", LE_ERR_UNSUPPORTED);
  /* Found by the fuzz driver: float samples near FLT_MAX, finite but
   * overflowing the converter to Inf. */
  bk_expect(BK_FIX "f32_huge_values.wav", LE_ERR_INVALID);
  /* L4: a 0.2 s MP3 with ID3v2.3 and ID3v1 tags decodes. */
  bk_expect(BK_FIX "short_tagged.mp3", LE_OK);

  unsigned char f[40];
  uint32_t n;
  /* Accepted: PCM 16/24/32 and float32, plain and EXTENSIBLE. */
  const int ok_bits[][2] = {{1, 16}, {1, 24}, {1, 32}, {3, 32}};
  for (size_t i = 0; i < sizeof(ok_bits) / sizeof(ok_bits[0]); ++i) {
    const int tag = ok_bits[i][0], bits = ok_bits[i][1];
    n = bk_fmt(f, (uint16_t)tag, 0, 2, 48000, bits);
    bk_write_raw_wav(bk_path("ok_plain.wav"), f, n, NULL, 0, 0,
                     (uint32_t)(64 * 2 * bits / 8));
    if (tag == 3) {
      float z[128] = {0};
      bk_write_wav(bk_path("ok_plain.wav"), 3, 32, 2, 48000, z, 64, 0);
    }
    bk_expect(bk_path("ok_plain.wav"), LE_OK);
    n = bk_fmt(f, 0xFFFE, (uint16_t)tag, 2, 48000, bits);
    bk_write_raw_wav(bk_path("ok_ext.wav"), f, n, NULL, 0, 0,
                     (uint32_t)(64 * 2 * bits / 8));
    bk_expect(bk_path("ok_ext.wav"), LE_OK);
  }
  /* Refused formats: 8-bit, 64-bit float, mu-law (7), A-law (6), IMA-ADPCM
   * (0x11), and EXTENSIBLE carrying an ADPCM subformat. */
  const int refused[][3] = {
      {1, 0, 8}, {3, 0, 64}, {7, 0, 8}, {6, 0, 8}, {0x11, 0, 4},
      {0xFFFE, 2, 16}};
  for (size_t i = 0; i < sizeof(refused) / sizeof(refused[0]); ++i) {
    n = bk_fmt(f, (uint16_t)refused[i][0], (uint16_t)refused[i][1], 1, 48000,
               refused[i][2]);
    bk_write_raw_wav(bk_path("refused.wav"), f, n, NULL, 0, 0, 512);
    bk_expect(bk_path("refused.wav"), LE_ERR_UNSUPPORTED);
  }
  /* Other containers. */
  const char* magics[] = {"RIFX", "RF64", "BW64", "FORM", "OggS"};
  for (size_t i = 0; i < sizeof(magics) / sizeof(magics[0]); ++i) {
    n = bk_fmt(f, 1, 0, 1, 48000, 16);
    bk_write_raw_wav(bk_path("container.wav"), f, n, NULL, 0, 0, 512);
    FILE* w = fopen(bk_path("container.wav"), "r+b");
    CHECK(w != NULL);
    if (w) { fwrite(magics[i], 1, 4, w); fclose(w); }
    bk_expect(bk_path("container.wav"), LE_ERR_UNSUPPORTED);
  }
  /* fact: 0-3 bytes would underflow dr_wav's seek (H2); 4 is fine. */
  for (uint32_t len = 0; len <= 4; ++len) {
    n = bk_fmt(f, 1, 0, 1, 48000, 16);
    bk_write_raw_wav(bk_path("fact.wav"), f, n, "fact", len, len, 512);
    bk_expect(bk_path("fact.wav"), len < 4 ? LE_ERR_INVALID : LE_OK);
  }
  /* A chunk that claims more than the rest of the file, and a block align
   * that does not match. */
  n = bk_fmt(f, 1, 0, 1, 48000, 16);
  bk_write_raw_wav(bk_path("huge_chunk.wav"), f, n, "LIST", 4, 0xFFFFFFF0u,
                   512);
  bk_expect(bk_path("huge_chunk.wav"), LE_ERR_INVALID);
  n = bk_fmt(f, 1, 0, 1, 48000, 16);
  bk_put16(f + 12, 4);
  bk_write_raw_wav(bk_path("align.wav"), f, n, NULL, 0, 0, 512);
  bk_expect(bk_path("align.wav"), LE_ERR_INVALID);
  /* Not a regular file. */
  le_backing_decode_info info;
  CHECK(le_backing_probe_file(perf_test_dir(), &info, NULL, 0) ==
        LE_ERR_INVALID);
}

/* H3: a NaN or Inf in a float WAV is refused at the probe and the decode,
 * so it never reaches the voice (one NaN poisons output-bus FX for good). */
static void test_backing_decode_non_finite(void) {
  printf("test_backing_decode_non_finite\n");
  enum { N = 4800 };
  le_backing_buffer* bb = NULL;
  float* x = malloc((size_t)N * sizeof(float));
  /* A finite value near FLT_MAX is damaged too: the converter's sum would
   * overflow it to Inf (found by the fuzz driver). */
  const float bad[3] = {NAN, INFINITY, 3.39e38f};
  for (int k = 0; k < 3; ++k) {
    for (int i = 0; i < N; ++i) x[i] = 0.1f;
    x[100] = bad[k];
    bk_write_wav(bk_path("nonfinite.wav"), 3, 32, 1, 48000, x, N, 0);
    bk_expect(bk_path("nonfinite.wav"), LE_ERR_INVALID);
    CHECK(le_backing_decode_file(bk_path("nonfinite.wav"), 44100, 0, 0, &bb,
                                 NULL) == LE_ERR_INVALID);
    le_backing_buffer* b = NULL;
    CHECK(le_backing_decode_file(bk_path("nonfinite.wav"), 48000, 50, 100, &b,
                                 NULL) == LE_ERR_INVALID);
    CHECK(b == NULL);
  }
  free(x);
  /* 60 dB over full scale is still a sound; beyond that it is damaged. */
  float edge[64];
  for (int i = 0; i < 64; ++i) edge[i] = i == 10 ? 1024.0f : 0.5f;
  bk_write_wav(bk_path("hot.wav"), 3, 32, 1, 48000, edge, 64, 0);
  bk_expect(bk_path("hot.wav"), LE_OK);
  edge[10] = 1025.0f;
  bk_write_wav(bk_path("hot.wav"), 3, 32, 1, 48000, edge, 64, 0);
  bk_expect(bk_path("hot.wav"), LE_ERR_INVALID);
}

/* L2: a bounded read computes exactly the whole-file decode's samples at the
 * same output positions, converted (44.1 to 48 kHz) and halved (192 to
 * 44.1 kHz, two halvings). */
static void test_backing_decode_bounded_matches_whole(void) {
  printf("test_backing_decode_bounded_matches_whole\n");
  const int cases[][4] = {
      /* source rate, engine rate, start frame, frames */
      {44100, 48000, 7001, 500},
      {192000, 44100, 30003, 700},
      {48000, 48000, 1234, 300},
  };
  for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
    const int sr = cases[c][0], er = cases[c][1];
    const int start = cases[c][2], want = cases[c][3];
    const int n = sr / 2; /* half a second */
    float* x = malloc((size_t)n * 2 * sizeof(float));
    uint32_t seed = 12345u + (uint32_t)c;
    for (int i = 0; i < n * 2; ++i) {
      seed = seed * 1664525u + 1013904223u;
      x[i] = 0.5f * ((float)(seed >> 8) / 16777216.0f - 0.5f);
    }
    bk_write_wav(bk_path("span.wav"), 3, 32, 2, sr, x, n, 0);
    free(x);
    le_backing_buffer* whole = NULL;
    le_backing_buffer* part = NULL;
    le_backing_decode_info info;
    CHECK(le_backing_decode_file(bk_path("span.wav"), er, 0, 0, &whole,
                                 NULL) == LE_OK);
    CHECK(le_backing_decode_file(bk_path("span.wav"), er, start, want, &part,
                                 &info) == LE_OK);
    CHECK(info.truncated == 1);
    const int64_t first = ((int64_t)start * er + sr - 1) / sr;
    CHECK(le_backing_buffer_frames(part) == want);
    int differ = 0;
    for (int i = 0; whole && part && i < want * 2; ++i) {
      if (part->pcm[i] != whole->pcm[first * 2 + i]) ++differ;
    }
    if (differ) printf("  %d->%d: %d samples differ\n", sr, er, differ);
    CHECK(differ == 0);
    le_backing_buffer_free(whole);
    le_backing_buffer_free(part);
  }
}

/* Review of #1223, L5: a bounded read starting at the last source frame of
 * a reduction has no output frame of its own: an empty read, not damage;
 * the voice refuses the empty buffer. */
static void test_backing_decode_empty_bounded_read(void) {
  printf("test_backing_decode_empty_bounded_read\n");
  enum { N = 9600 };
  float* x = calloc(N, sizeof(float));
  bk_write_wav(bk_path("tail.wav"), 3, 32, 1, 96000, x, N, 0);
  free(x);
  le_backing_buffer* b = NULL;
  le_backing_decode_info info;
  CHECK(le_backing_decode_file(bk_path("tail.wav"), 48000, N - 1, 100, &b,
                               &info) == LE_OK);
  CHECK(b != NULL && le_backing_buffer_frames(b) == 0 && info.truncated == 0);
  le_engine* e = bk_engine(2);
  CHECK(le_engine_backing_load(e, b, 1, 0) == LE_ERR_INVALID);
  CHECK(le_engine_backing_stage_next(e, b, 1) == LE_ERR_INVALID);
  le_engine_destroy(e);
  le_backing_buffer_free(b);
  /* One frame earlier there is one. */
  b = NULL;
  CHECK(le_backing_decode_file(bk_path("tail.wav"), 48000, N - 2, 100, &b,
                               &info) == LE_OK);
  CHECK(le_backing_buffer_frames(b) == 1);
  le_backing_buffer_free(b);
}

/* Defense in depth for H2: reads and seeks stop after a bounded amount of
 * work, so even a decoder loop the header check missed ends. */
static void test_backing_decode_work_bound(void) {
  printf("test_backing_decode_work_bound\n");
  enum { N = 48000 };
  int16_t* s16 = calloc(N, sizeof(int16_t));
  bk_write_wav(bk_path("budget.wav"), 1, 16, 1, 48000, s16, N, 0);
  free(s16);
  le_backing_buffer* b = NULL;
  le_test_decode_budget = 20000; /* a fifth of the file */
  CHECK(le_backing_decode_file(bk_path("budget.wav"), 48000, 0, 0, &b, NULL) ==
        LE_ERR_INVALID);
  le_backing_decode_info info;
  CHECK(le_backing_probe_file(bk_path("budget.wav"), &info, NULL, 0) ==
        LE_ERR_INVALID);
  le_test_decode_budget = 0;
  CHECK(le_backing_decode_file(bk_path("budget.wav"), 48000, 0, 0, &b, NULL) ==
        LE_OK);
  le_backing_buffer_free(b);
}

static void run_backing_decode_tests(void) {
  test_resample_identity_and_guards();
  test_resample_dc_tone_and_alignment();
  test_resample_alias_and_image();
  test_backing_decode_wav_formats();
  test_backing_decode_192k();
  test_backing_decode_mp3_and_no_flac();
  test_backing_decode_refusals();
  test_backing_decode_bounded();
  test_backing_probe();
  test_backing_decode_memory_guard();
  test_backing_decode_header_checks();
  test_backing_decode_whitelist();
  test_backing_decode_non_finite();
  test_backing_decode_bounded_matches_whole();
  test_backing_decode_work_bound();
  test_backing_decode_empty_bounded_read();
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
  run_backing_decode_tests();
}
