/* #1773: a stopped track's Post tail rings out while it is stopped and
 * falls to silence, so the next Play starts with nothing left of it: on the
 * callback alone, with the track chains as jobs on two effects workers
 * (#1729), and with every track chain forced through the jobs
 * (le_test_trk_jobs_force), the same sample for sample. The cases: a reverb
 * and a delay at Post on a plain take's lane, a heard lane's Post delay over
 * its image (#1741), a reverb on the track's own chain, and every other kind
 * that drains a tail. Included by test_engine_core.c after
 * test_engine_trk_jobs.h (shares the heard fixtures). */

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

/* The largest sample of [n] stereo frames. */
static float pts_peak(const float* out, int32_t n) {
  float p = 0.0f;
  for (int32_t i = 0; i < 2 * n; ++i) p = fmaxf(p, fabsf(out[i]));
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

/* Lane 0 of track 0: one [kind] at Post (pre_count 0), a long tail. */
static void pts_lane_post(le_engine* e, int32_t kind) {
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, kind) == LE_OK);
  if (kind == LE_FX_DELAY) {
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.7f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.5f) == LE_OK);
  } else {
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.9f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.6f) == LE_OK);
  }
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
  drain(e);
}

/* After a take played a few laps through a Post tail on track 0: Stop, and
 * while stopped the tail rings and then falls to silence; then Play, and the
 * first window holds what a fresh Play holds, not the frozen tail's rest. */
static void pts_check(le_engine* e, const char* what, int mode) {
  static float out[2 * PTS_WIN];
  heard_silence(e, 2 * PTS_TAKE, 64, NULL); /* laps */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  heard_silence(e, 1200, 37, NULL); /* the Stop's fade */
  heard_silence(e, PTS_WIN, 37, out);
  const float ringing = pts_peak(out, PTS_WIN);
  /* Long enough for both tails to fall under -100 dB. */
  float last = 0.0f;
  for (int k = 0; k < 120; ++k) {
    heard_silence(e, PTS_WIN, 37, out);
    last = pts_peak(out, PTS_WIN);
  }
  if (!(ringing > 1e-3f) || !(last < 1e-5f)) {
    printf("  %s (%s): %g just after Stop, %g much later\n", what,
           pts_mode_name[mode], ringing, last);
  }
  CHECK(ringing > 1e-3f); /* it rings while stopped */
  CHECK(last < 1e-5f);    /* and drains */
  /* Play: drained, nothing of the tail is left to resume (the caller
   * compares what follows across the ways the chains run). */
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
}

static void pts_session(int32_t kind, int heard, int mode, float* after,
                        int32_t n) {
  le_engine* e = heard_engine(48000);
  pts_mode(e, mode);
  if (heard) {
    /* A take recorded through input 0's reverb at Pre: its image; the
     * lane's own delay at Post plays live over it (#1741). */
    heard_post_monitor(e, 1, 1, 1);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_DELAY) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 0, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 1, 0.7f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 2, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_count(e, 0, 0, 2, 1) == LE_OK);
    drain(e);
    heard_post_take(e, PTS_TAKE);
  } else {
    if (kind < 0) {
      pts_track_post(e, -kind);
    } else {
      pts_lane_post(e, kind);
    }
    CHECK(le_engine_record(e, 0) == LE_OK);
    heard_feed(e, 0, PTS_TAKE, 64, NULL);
    CHECK(le_engine_record(e, 0) == LE_OK);
    CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
    heard_silence(e, 960, 64, NULL);
  }
  pts_check(e,
            heard              ? "heard Post delay"
            : kind < 0         ? "track chain's Post reverb"
            : kind == LE_FX_DELAY ? "Post delay"
                               : "Post reverb",
            mode);
  heard_silence(e, n, 37, after);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

static void test_post_tail_rings_while_stopped(void) {
  printf("test_post_tail_rings_while_stopped\n");
  static float ref[2 * PTS_WIN];
  static float got[2 * PTS_WIN];
  const int32_t kinds[4] = {LE_FX_REVERB, LE_FX_DELAY, LE_FX_DELAY,
                            -LE_FX_REVERB};
  const int force = le_test_trk_jobs_force;
  for (int c = 0; c < 4; ++c) {
    const int heard = c == 2;
    pts_session(kinds[c], heard, 0, ref, PTS_WIN);
    for (int mode = 1; mode < 3; ++mode) {
      pts_session(kinds[c], heard, mode, got, PTS_WIN);
      /* After the Play, the same as on the callback: no frozen rest. */
      CHECK(memcmp(ref, got, sizeof(ref)) == 0);
    }
  }
  le_test_trk_jobs_force = force;
}

/* Every other kind that drains a tail (le_fx_type_drains), at its
 * defaults at Post on a take's lane: it rings while stopped, the same
 * however the chains run. */
static void test_post_tail_every_draining_kind_rings(void) {
  printf("test_post_tail_every_draining_kind_rings\n");
  const int32_t kinds[] = {LE_FX_ROOM_VERB, LE_FX_DUB_VERB, LE_FX_AMB_VERB,
                           LE_FX_SPRING, LE_FX_MODE_DELAY, LE_FX_ECHO};
  static float ref[2 * PTS_WIN];
  static float out[2 * PTS_WIN];
  const int force = le_test_trk_jobs_force;
  for (int k = 0; k < 6; ++k) {
    for (int mode = 0; mode < 3; ++mode) {
      le_engine* e = heard_engine(48000);
      pts_mode(e, mode);
      CHECK(le_engine_set_lane_fx(e, 0, 0, 0, kinds[k]) == LE_OK);
      CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
      drain(e);
      CHECK(le_engine_record(e, 0) == LE_OK);
      heard_feed(e, 0, PTS_TAKE, 64, NULL);
      CHECK(le_engine_record(e, 0) == LE_OK);
      CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
      heard_silence(e, 2 * PTS_TAKE, 64, NULL);
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
      heard_silence(e, 1200, 37, NULL);
      heard_silence(e, PTS_WIN, 37, out);
      if (!(pts_peak(out, PTS_WIN) > 1e-3f)) {
        printf("  kind %d (%s): %g after Stop\n", (int)kinds[k],
               pts_mode_name[mode], pts_peak(out, PTS_WIN));
      }
      CHECK(pts_peak(out, PTS_WIN) > 1e-3f);
      if (mode == 0) {
        memcpy(ref, out, sizeof(ref));
      } else {
        CHECK(memcmp(ref, out, sizeof(ref)) == 0);
      }
      le_test_trk_jobs_force = 0;
      le_engine_destroy(e);
    }
  }
  le_test_trk_jobs_force = force;
}

static void run_post_tail_stopped_tests(void) {
  test_post_tail_rings_while_stopped();
  test_post_tail_every_draining_kind_rings();
}
