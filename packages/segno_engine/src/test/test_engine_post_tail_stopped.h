/* #1773: a stopped track's Post tail rings out while it is stopped and
 * falls to silence, so the next Play starts with nothing left of it: on the
 * callback alone, with the track chains as jobs on two effects workers
 * (#1729), and with every track chain forced through the jobs
 * (le_test_trk_jobs_force), the same sample for sample. The same holds when
 * a mute lands after the Stop, as the Rec-mode Stop of the only audible loop
 * sends it (park, then mute): the engine spares the tail of a track a Stop
 * stopped until the track runs again (le_lane::a_gate_muted). A mute while
 * the track plays still gates it, tail included (slice 3b). The cases: a
 * reverb and a delay at Post on a plain take's lane, a heard lane's Post
 * delay over its image (#1741), a reverb on the track's own chain, and every
 * kind that drains a tail (le_fx_type_drains). Included by test_engine_core.c
 * after test_engine_trk_jobs.h (shares the heard fixtures). */

enum { PTS_TAKE = 9600, PTS_WIN = 4800 };

/* How the chains run: 0 on the callback, 1 as jobs on two workers, 2 forced
 * through the jobs with no worker. */
static const char* const pts_mode_name[3] = {"callback", "workers", "forced"};

static void pts_mode(le_engine* e, int mode) {
  CHECK(le_engine_set_fx_workers(e, mode == 1 ? 2 : 0, NULL) == LE_OK);
  le_test_trk_jobs_force = mode == 2;
  /* A second track with a chain of its own, so a block has two jobs. */
  CHECK(le_engine_set_lane_fx(e, 1, 0, 0, LE_FX_EQ) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 1, 0, 1, 0) == LE_OK);
  drain(e);
}

/* The largest sample of [n] stereo frames; a non-finite one reads as
 * infinitely loud, so a tail gone to NaN never passes for silence. */
static float pts_peak(const float* out, int32_t n) {
  float p = 0.0f;
  for (int32_t i = 0; i < 2 * n; ++i) {
    if (!isfinite(out[i])) return INFINITY;
    p = fmaxf(p, fabsf(out[i]));
  }
  return p;
}

/* Track 0's own chain: one [kind] at Post, a long tail. */
static void pts_track_post(le_engine* e, int32_t kind) {
  le_fx_recipe r;
  memset(&r, 0, sizeof(r));
  r.enabled = 1;
  r.count = 1;
  r.type[0] = kind;
  r.slot_enabled[0] = 1;
  r.level[0] = 1.0f;
  le_fx_defaults(kind, r.params[0]);
  r.params[0][0] = 0.6f;
  r.params[0][1] = 0.7f;
  r.instance[0] = 4242u;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, 0, 0, 77, &r) == LE_OK);
  drain(e);
}

/* Lane 0 of track 0: one [kind] at Post (pre_count 0). The reverb and the
 * delay get long tails; any other kind keeps its defaults. */
static void pts_lane_post(le_engine* e, int32_t kind) {
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, kind) == LE_OK);
  if (kind == LE_FX_DELAY) {
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.2f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.6f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.5f) == LE_OK);
  } else if (kind == LE_FX_REVERB) {
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.9f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.6f) == LE_OK);
  }
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
  drain(e);
}

/* Records a take on track 0 and lets it play two laps, the input muted. */
static void pts_take(le_engine* e) {
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, 0, PTS_TAKE, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 960, 64, NULL);
  heard_silence(e, 2 * PTS_TAKE, 64, NULL); /* laps */
}

/* Processes silence in windows until one is quiet (or [max] windows), and
 * returns that window's peak. Modes that agree sample for sample stop at the
 * same window. */
static float pts_until_quiet(le_engine* e, int max) {
  static float out[2 * PTS_WIN];
  float last = INFINITY;
  for (int k = 0; k < max && !(last < 1e-5f); ++k) {
    heard_silence(e, PTS_WIN, 512, out);
    last = pts_peak(out, PTS_WIN);
  }
  return last;
}

/* After a take played through a Post tail on track 0: Stop (and, with
 * [mute], the mute the Rec-mode Stop sends after its park). While stopped
 * the tail rings and then falls to silence; then (unmuted again, as Rec/Play
 * does) Play. */
static void pts_check(le_engine* e, const char* what, int mode, int mute) {
  static float out[2 * PTS_WIN];
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  if (mute) CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 1200, 37, NULL); /* the Stop's fade */
  heard_silence(e, PTS_WIN, 37, out);
  const float ringing = pts_peak(out, PTS_WIN);
  const float last = pts_until_quiet(e, 200);
  if (!(ringing > 1e-3f) || !(last < 1e-5f)) {
    printf("  %s (%s%s): %g just after Stop, %g much later\n", what,
           pts_mode_name[mode], mute ? ", muted" : "", ringing, last);
  }
  CHECK(isfinite(ringing) && ringing > 1e-3f); /* it rings while stopped */
  CHECK(last < 1e-5f);                         /* and drains */
  if (mute) CHECK(le_engine_set_track_mute(e, 0, 0) == LE_OK);
  /* Play: drained, nothing of the tail is left to resume (the caller
   * compares what follows across the ways the chains run). */
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
}

/* One session: track 0's take through [kind] at Post (on the lane; on the
 * track's chain for a negative [kind]; a heard lane's Post delay for
 * [heard]), Stop (muted after it with [mute]) and Play, then [n] frames of
 * what follows into [after]. */
static void pts_session(int32_t kind, int heard, int mode, int mute,
                        float* after, int32_t n) {
  le_engine* e = heard_engine(48000);
  pts_mode(e, mode);
  if (heard) {
    /* A take recorded through input 0's reverb at Pre: its image; the
     * lane's own delay at Post plays live over it (#1741). */
    heard_post_monitor(e, 1, 1, 1);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_DELAY) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 0, 0.2f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 1, 0.6f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 2, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_count(e, 0, 0, 2, 1) == LE_OK);
    drain(e);
    heard_post_take(e, PTS_TAKE);
    heard_silence(e, 2 * PTS_TAKE, 64, NULL); /* laps */
  } else {
    if (kind < 0) {
      pts_track_post(e, -kind);
    } else {
      pts_lane_post(e, kind);
    }
    pts_take(e);
  }
  char what[64];
  snprintf(what, sizeof(what), "%s",
           heard      ? "heard Post delay"
           : kind < 0 ? "track chain's Post reverb"
                      : "lane Post");
  if (!heard && kind >= 0) {
    snprintf(what, sizeof(what), "lane Post kind %d", (int)kind);
  }
  pts_check(e, what, mode, mute);
  heard_silence(e, n, 37, after);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

/* Each case, plain and muted after the Stop: it rings and drains while
 * stopped, and after the Play it is the same on the callback, on workers and
 * forced through the jobs: no frozen rest. */
static void test_post_tail_rings_while_stopped(void) {
  printf("test_post_tail_rings_while_stopped\n");
  static float ref[2 * PTS_WIN];
  static float got[2 * PTS_WIN];
  const int32_t kinds[4] = {LE_FX_REVERB, LE_FX_DELAY, LE_FX_DELAY,
                            -LE_FX_REVERB};
  const int force = le_test_trk_jobs_force;
  for (int c = 0; c < 4; ++c) {
    for (int mute = 0; mute < 2; ++mute) {
      const int heard = c == 2;
      pts_session(kinds[c], heard, 0, mute, ref, PTS_WIN);
      for (int mode = 1; mode < 3; ++mode) {
        pts_session(kinds[c], heard, mode, mute, got, PTS_WIN);
        CHECK(memcmp(ref, got, sizeof(ref)) == 0);
      }
    }
  }
  le_test_trk_jobs_force = force;
}

/* Every kind that drains a tail, at its defaults at Post on a take's lane,
 * muted after the Stop: it rings and drains while stopped, and what follows
 * the Play is the same however the chains run. */
static void test_post_tail_every_draining_kind_rings(void) {
  printf("test_post_tail_every_draining_kind_rings\n");
  static float ref[2 * PTS_WIN];
  static float got[2 * PTS_WIN];
  const int force = le_test_trk_jobs_force;
  int kinds = 0;
  /* le_fx_type_drains reads 0 past the last kind. */
  for (int32_t kind = LE_FX_NONE + 1; kind < 256; ++kind) {
    if (!le_fx_type_drains(kind)) continue;
    ++kinds;
    pts_session(kind, 0, 0, 1, ref, PTS_WIN);
    for (int mode = 1; mode < 3; ++mode) {
      pts_session(kind, 0, mode, 1, got, PTS_WIN);
      CHECK(memcmp(ref, got, sizeof(ref)) == 0);
    }
  }
  CHECK(kinds >= 6);
  le_test_trk_jobs_force = force;
}

/* A mute while the track plays gates it, tail included, and a Stop after it
 * does not open the gate (slice 3b): only a mute that lands after a Stop
 * spares the tail. */
static void test_post_tail_mute_before_stop_gates(void) {
  printf("test_post_tail_mute_before_stop_gates\n");
  static float out[2 * PTS_WIN];
  le_engine* e = heard_engine(48000);
  pts_lane_post(e, LE_FX_DELAY);
  pts_take(e);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 2400, 37, NULL); /* the Mute's fade */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  heard_silence(e, PTS_WIN, 37, out);
  CHECK(pts_peak(out, PTS_WIN) == 0.0f);
  le_engine_destroy(e);
}

/* A spared mute gates again as soon as the track runs: a Play that leaves
 * the mute on (the unpark rule resumes a parked track with its mute kept)
 * silences the track, its tail and its loop both. */
static void test_post_tail_spared_mute_gates_when_it_runs(void) {
  printf("test_post_tail_spared_mute_gates_when_it_runs\n");
  static float out[2 * PTS_WIN];
  le_engine* e = heard_engine(48000);
  pts_lane_post(e, LE_FX_DELAY);
  pts_take(e);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 1200, 37, NULL);
  heard_silence(e, PTS_WIN, 37, out);
  CHECK(pts_peak(out, PTS_WIN) > 1e-3f); /* spared: it rings */
  CHECK(le_engine_play(e, 0) == LE_OK);
  /* Closed at once: none of the muted loop comes in under the Play's
   * fade-in, and the rest of the tail is cut with it. */
  heard_silence(e, PTS_WIN, 37, out);
  CHECK(pts_peak(out, PTS_WIN) == 0.0f);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(snap.tracks[0].muted == 1);
  le_engine_destroy(e);
}

/* The export rings where the performer heard the tail ring: a Post reverb
 * through a Stop and a mute after it, a Play that keeps the mute, and the
 * unmute, replayed by perf_render, match the live callback (the wet stem of
 * the only track is the mono output). The take is an image source (a Clear
 * and its Undo), whose Stop and Play the render replays with the callback's
 * fades (test_gate_fade_render_matches_live_stop_and_play). */
static void test_post_tail_render_matches_live_spared_mute(void) {
  printf("test_post_tail_render_matches_live_spared_mute\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("post-tail-spared");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  static float live[8000], replay[8000];
  rev_process(e, live, 64, 512);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, live + 64, 64, 512);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  pts_lane_post(e, LE_FX_REVERB);
  rev_process(e, live + 128, 1872, 512);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  rev_process(e, live + 2000, 3000, 512);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, live + 5000, 1000, 512);
  CHECK(le_engine_set_track_mute(e, 0, 0) == LE_OK);
  rev_process(e, live + 6000, 1000, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  float rang = 0.0f;
  for (int i = 2600; i < 5000; ++i) rang = fmaxf(rang, fabsf(live[i]));
  CHECK(rang > 1.0f); /* the spared tail rang while stopped, the Stop's
                       * fade (480 frames) long over */
  float muted = 0.0f;
  for (int i = 5000; i < 6000; ++i) muted = fmaxf(muted, fabsf(live[i]));
  CHECK(muted == 0.0f); /* the Play closed it at once */
  rev_render_track_wav(e, dir, len);
  const int frames = test_read_wet_stem(dir, 0, replay, 8000);
  CHECK(frames == 7000);
  int bad = 0;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) > 1e-3f) {
      if (bad++ == 0) {
        printf("  first mismatch at %d: live %.4f replay %.4f\n", i, live[i],
               replay[i]);
      }
    }
  }
  CHECK(bad == 0);
  le_engine_destroy(e);
}

static void run_post_tail_stopped_tests(void) {
  test_post_tail_rings_while_stopped();
  test_post_tail_every_draining_kind_rings();
  test_post_tail_mute_before_stop_gates();
  test_post_tail_spared_mute_gates_when_it_runs();
  test_post_tail_render_matches_live_spared_mute();
}
