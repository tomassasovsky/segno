/* #1782: the Rec-mode Stop of the only audible loop while it overdubs
 * (le_engine_stop_record_park, then the mute). The overdub ends and the
 * transport parks at the same moment: at the press when the overdub ends at
 * once, at the armed grid end when Record timing quantizes it. The pass runs
 * to that end, the mute waits for the park, a second Stop keeps the arm, and
 * the Post tail rings out after the park (the #1773 spare) the same on the
 * callback, on effects workers and forced through the jobs. Included by
 * test_engine_core.c after test_engine_post_tail_stopped.h (shares its
 * fixtures). */

/* [n] frames of constant [value] input, in blocks of [blk]. */
static void ods_feed(le_engine* e, float value, int32_t n, int32_t blk,
                     float* out) {
  float in[512];
  float o[1024];
  for (int32_t i = 0; i < 512; ++i) in[i] = value;
  for (int32_t done = 0; done < n;) {
    int32_t k = n - done < blk ? n - done : blk;
    if (k > 512) k = 512;
    le_engine_process(e, o, in, (uint32_t)k);
    if (out != NULL) memcpy(out + 2 * done, o, (size_t)k * 2 * sizeof(float));
    done += k;
  }
}

/* Frames from the master position to the loop's next top. */
static int32_t ods_to_top(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  return s.master_length_frames - s.master_position_frames;
}

/* Track 0's take through a Post delay, with quantize on (loop top) when
 * [quantized] (track 1 left recording at once with [track1_now]), then an
 * overdub of constant input that runs from a loop top for half a lap.
 * Returns the engine; [base] gets lane 0's live buffer from before the
 * overdub. */
static le_engine* ods_overdubbing_on(int mode, int quantized, int track1_now,
                                     float* base) {
  le_engine* e = heard_engine(48000);
  pts_mode(e, mode);
  pts_lane_post(e, LE_FX_DELAY);
  pts_take(e);
  CHECK(timing_gate(e, quantized) == LE_OK);
  if (track1_now) CHECK(timing_track_gate(e, 1, 0) == LE_OK);
  le_track* t = &e->tracks[0];
  const int32_t len = load_i32(&t->lanes[0].a_len);
  CHECK(len == PTS_TAKE);
  memcpy(base, t->lanes[0].pool[load_i32(&t->lanes[0].a_live)],
         (size_t)len * sizeof(float));
  /* Quantized, the press arms the punch-in for the next top; otherwise the
   * press goes in at a top. */
  if (!quantized) heard_silence(e, ods_to_top(e), 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  if (quantized) {
    drain(e);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
    CHECK(s.tracks[0].pending == 1);
    heard_silence(e, ods_to_top(e), 64, NULL);
  }
  ods_feed(e, 0.25f, len / 2, 64, NULL);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  return e;
}

static le_engine* ods_overdubbing(int mode, int quantized, float* base) {
  return ods_overdubbing_on(mode, quantized, 0, base);
}

/* The Rec-mode Stop as ControlCubit sends it for an overdubbing sole loop:
 * the park, with room for the one lane mute, then the mute. */
static void ods_rec_stop(le_engine* e) {
  CHECK(le_engine_stop_record_park(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
}

/* Parked: every track stopped, track 0 muted, nothing armed. */
static void ods_check_parked(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].muted == 1);
  CHECK(s.tracks[0].pending == 0);
  for (int c = 1; c < LE_MAX_TRACKS; ++c) {
    CHECK(s.tracks[c].state != LE_TRACK_PLAYING);
    CHECK(s.tracks[c].state != LE_TRACK_OVERDUBBING);
  }
}

/* Still overdubbing, unmuted, with the end armed. */
static void ods_check_waiting(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[0].muted == 0);
  CHECK(s.tracks[0].pending == 1);
}

/* What lane 0 gained over [base] at [pos]: the overdub's layer there. */
static float ods_layer(le_engine* e, const float* base, int32_t pos) {
  const le_lane* ln = &e->tracks[0].lanes[0];
  return ln->pool[load_i32(&ln->a_live)][pos] - base[pos];
}

/* After the park: the Post tail rings past the Stop's fade and drains while
 * the track is stopped and muted. [out] gets the window that rings. */
static void ods_check_tail(le_engine* e, const char* what, int mode,
                           float* out) {
  heard_silence(e, 1200, 37, NULL); /* the Stop's fade */
  heard_silence(e, PTS_WIN, 37, out);
  const float ringing = pts_peak(out, PTS_WIN);
  const float last = pts_until_quiet(e, 200);
  if (!(ringing > 1e-3f) || !(last < 1e-5f)) {
    printf("  %s (%s): %g just after the park, %g much later\n", what,
           pts_mode_name[mode], ringing, last);
  }
  CHECK(isfinite(ringing) && ringing > 1e-3f);
  CHECK(last < 1e-5f);
}

/* Unquantized: the Stop ends the overdub and parks at the press. The layer
 * holds the pass up to the press and nothing after it, and the tail rings. */
static void ods_immediate(int mode, float* out) {
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(mode, 0, base);
  ods_rec_stop(e);
  drain(e);
  ods_check_parked(e);
  const int32_t half = PTS_TAKE / 2;
  CHECK(fabsf(ods_layer(e, base, half - 100) - 0.25f) < 1e-4f);
  CHECK(fabsf(ods_layer(e, base, half + 100)) < 1e-6f);
  ods_check_tail(e, "immediate", mode, out);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

/* Quantized: the Stop arms the end for the loop top. The overdub, unmuted,
 * runs to the frame before it, and parks on it, muted; the pass is whole.
 * With [again], a second Stop halfway through the wait keeps the arm. */
static void ods_quantized(int mode, int again, float* out) {
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(mode, 1, base);
  ods_rec_stop(e);
  drain(e);
  ods_check_waiting(e);
  if (again) {
    ods_feed(e, 0.25f, ods_to_top(e) / 2, 64, NULL);
    ods_check_waiting(e);
    ods_rec_stop(e);
    drain(e);
    ods_check_waiting(e);
  }
  ods_feed(e, 0.25f, ods_to_top(e) - 1, 64, NULL);
  ods_check_waiting(e);
  ods_feed(e, 0.25f, 1, 1, NULL); /* the top */
  ods_check_parked(e);
  /* The pass ran to the top: the layer reaches the loop's last frame. */
  CHECK(fabsf(ods_layer(e, base, PTS_TAKE - 1) - 0.25f) < 1e-4f);
  CHECK(fabsf(ods_layer(e, base, PTS_TAKE / 2) - 0.25f) < 1e-4f);
  ods_check_tail(e, again ? "quantized, pressed twice" : "quantized", mode,
                 out);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

/* Each way, the tail after the park is the same however the chains run. */
static void test_overdub_stop_parks(void) {
  printf("test_overdub_stop_parks\n");
  static float ref[2 * PTS_WIN];
  static float got[2 * PTS_WIN];
  const int force = le_test_trk_jobs_force;
  for (int how = 0; how < 3; ++how) {
    for (int mode = 0; mode < 3; ++mode) {
      float* out = mode == 0 ? ref : got;
      if (how == 0) {
        ods_immediate(mode, out);
      } else {
        ods_quantized(mode, how == 2, out);
      }
      if (mode > 0) CHECK(memcmp(ref, got, sizeof(ref)) == 0);
    }
  }
  le_test_trk_jobs_force = force;
}

/* A Record press during the wait drops the armed end and the park with it:
 * the overdub carries on past the top, and the mute the Stop sent lands when
 * that capture ends, the loop playing. */
static void test_overdub_stop_park_dropped_by_record(void) {
  printf("test_overdub_stop_park_dropped_by_record\n");
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(0, 1, base);
  ods_rec_stop(e);
  drain(e);
  ods_check_waiting(e);
  CHECK(le_engine_record(e, 0) == LE_OK); /* cancels the armed end */
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].pending == 0);
  ods_feed(e, 0.25f, ods_to_top(e) + 100, 64, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[0].muted == 0);
  CHECK(le_engine_record(e, 0) == LE_OK); /* the punch-out, at the top */
  ods_feed(e, 0.25f, ods_to_top(e), 64, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].muted == 1);
  le_engine_destroy(e);
}

/* Only the Stop's own mute waits: a later mute of the lane (a Mute-mode
 * press during the wait) punches the pass out at once and drops the park,
 * so the loop plays on, muted, past the top. */
static void test_overdub_stop_park_later_mute_punches_out(void) {
  printf("test_overdub_stop_park_later_mute_punches_out\n");
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(0, 1, base);
  ods_rec_stop(e);
  drain(e);
  ods_check_waiting(e);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].muted == 1);
  CHECK(s.tracks[0].pending == 0);
  ods_feed(e, 0.25f, ods_to_top(e) + 100, 64, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  le_engine_destroy(e);
}

/* Another track's capture that starts during the wait ends the overdub
 * there (one capturer) and drops the park: the Stop's mute lands with that
 * end, and the loop plays on, muted, past the top. */
static void test_overdub_stop_park_dropped_by_another_capture(void) {
  printf("test_overdub_stop_park_dropped_by_another_capture\n");
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing_on(0, 1, 1, base);
  ods_rec_stop(e);
  drain(e);
  ods_check_waiting(e);
  CHECK(le_engine_record(e, 1) == LE_OK); /* at once */
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].muted == 1);
  CHECK(s.tracks[0].pending == 0);
  ods_feed(e, 0.25f, ods_to_top(e) + 100, 64, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  le_engine_destroy(e);
}

/* Another track's arm that fires on the same top fires before the park, so
 * it cannot restart the transport the park holds: a take armed to start
 * there ends with the park. */
static void test_overdub_stop_park_lands_after_the_tops_arms(void) {
  printf("test_overdub_stop_park_lands_after_the_tops_arms\n");
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(0, 1, base);
  ods_rec_stop(e);
  drain(e);
  CHECK(le_engine_record(e, 2) == LE_OK); /* a take armed for the top */
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].pending == 1);
  ods_feed(e, 0.25f, ods_to_top(e), 64, NULL);
  ods_feed(e, 0.25f, 2400, 64, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].pending == 0);
  for (int c = 0; c < LE_MAX_TRACKS; ++c) {
    CHECK(s.tracks[c].state != LE_TRACK_PLAYING);
    CHECK(s.tracks[c].state != LE_TRACK_OVERDUBBING);
    CHECK(s.tracks[c].state != LE_TRACK_RECORDING);
  }
  CHECK(s.master_position_frames == 0); /* held at the top */
  le_engine_destroy(e);
}

/* An unmute during the wait takes the Stop's mute back: the park leaves
 * the track unmuted, and spares nothing, so a later Mute of the parked
 * track gates its tail as any other mute does. */
static void test_overdub_stop_park_unmuted_during_the_wait(void) {
  printf("test_overdub_stop_park_unmuted_during_the_wait\n");
  static float base[PTS_TAKE];
  static float out[2 * PTS_WIN];
  le_engine* e = ods_overdubbing(0, 1, base);
  ods_rec_stop(e);
  CHECK(le_engine_set_track_mute(e, 0, 0) == LE_OK);
  drain(e);
  ods_check_waiting(e);
  ods_feed(e, 0.25f, ods_to_top(e), 64, NULL);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].muted == 0);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 2400, 37, NULL); /* the fades */
  heard_silence(e, PTS_WIN, 37, out);
  CHECK(pts_peak(out, PTS_WIN) == 0.0f);
  le_engine_destroy(e);
}

/* The park reserves room for the mutes that follow it, as the spare does,
 * and refuses with nothing posted when they would not fit; bad arguments are
 * refused. */
static void test_overdub_stop_park_reserves_and_validates(void) {
  printf("test_overdub_stop_park_reserves_and_validates\n");
  static float base[PTS_TAKE];
  le_engine* e = ods_overdubbing(0, 0, base);
  CHECK(le_engine_stop_record_park(NULL, 0, 1) == LE_ERR_INVALID);
  CHECK(le_engine_stop_record_park(e, -1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_stop_record_park(e, LE_MAX_TRACKS, 1) == LE_ERR_INVALID);
  CHECK(le_engine_stop_record_park(e, 0, -1) == LE_ERR_INVALID);
  /* Leave exactly 2 free slots: the park and 1 more fit, 2 more do not. */
  const size_t usable = e->ring.capacity - 1;
  for (size_t i = 0; i < usable - 2; ++i) {
    CHECK(le_engine_set_track_volume(e, 1, 1.0f) == LE_OK);
  }
  const uint64_t posted = e->commands_posted;
  CHECK(le_engine_stop_record_park(e, 0, 2) == LE_ERR_NOT_READY);
  CHECK(e->commands_posted == posted);
  ods_rec_stop(e);
  CHECK(le_engine_set_track_volume(e, 1, 1.0f) != LE_OK); /* full now */
  drain(e);
  ods_check_parked(e);
  le_engine_destroy(e);
}

static void run_overdub_stop_park_tests(void) {
  test_overdub_stop_parks();
  test_overdub_stop_park_dropped_by_record();
  test_overdub_stop_park_later_mute_punches_out();
  test_overdub_stop_park_dropped_by_another_capture();
  test_overdub_stop_park_lands_after_the_tops_arms();
  test_overdub_stop_park_unmuted_during_the_wait();
  test_overdub_stop_park_reserves_and_validates();
}
