/* #1870: a lane chain on an EMPTY track stops running once its output has
 * stayed under LE_FX_DRAIN_FLOOR for its whole tail
 * (le_fx_chain_quiet_frames), so an idle console stops processing silence
 * nobody hears: the track takes the idle skip and needs no job. A Clear's
 * Post tail drains first; a Record or a chain edit runs the chain again, and
 * a take recorded after a sleep plays exactly as one through a chain that
 * never slept. Monitor chains never sleep. On the callback, on two workers
 * and forced through the jobs (pts_mode). Included by test_engine_core.c
 * after test_engine_post_tail_stopped.h (pts_* helpers). */

static le_lane* lcs_lane(le_engine* e) { return &e->tracks[0].lanes[0]; }

/* What track 0 lane 0's chain needs to stay quiet before it sleeps. */
static int32_t lcs_need(le_engine* e) {
  le_lane* ln = lcs_lane(e);
  int32_t types[LE_FX_MAX];
  const int32_t n = load_i32(&ln->a_fx_count);
  for (int32_t s = 0; s < n; ++s) types[s] = load_i32(&ln->a_fx_type[s]);
  return le_fx_chain_quiet_frames(&ln->fx, n, types, 48000,
                                  e->fx_delay_frames);
}

/* The horizon: the minimum window plus each entry that holds a tail; a
 * hosted plugin's chain never sleeps. */
static void test_lane_chain_quiet_frames(void) {
  printf("test_lane_chain_quiet_frames\n");
  le_engine* e = heard_engine(48000);
  const int32_t minimum = 48000 * LE_FX_DRAIN_QUIET_MS / 1000;
  le_lane* ln = lcs_lane(e);
  const int32_t none[1] = {LE_FX_NONE};
  CHECK(le_fx_chain_quiet_frames(&ln->fx, 0, none, 48000, 48000) == minimum);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_EQ) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_REVERB) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 2, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 3, 0) == LE_OK);
  drain(e);
  CHECK(lcs_need(e) == minimum + 2 * e->fx_delay_frames);
  const int32_t plugin[2] = {LE_FX_EQ, LE_FX_PLUGIN};
  CHECK(le_fx_chain_quiet_frames(&ln->fx, 2, plugin, 48000, 48000) == -1);
  le_engine_destroy(e);
}

/* A chain set on an EMPTY track and never fed runs for its horizon, then
 * sleeps; asleep, no track has a job. */
static void test_lane_chain_sleeps_on_empty_track(void) {
  printf("test_lane_chain_sleeps_on_empty_track\n");
  const int force = le_test_trk_jobs_force;
  for (int mode = 0; mode < 3; ++mode) {
    le_engine* e = heard_engine(48000);
    pts_mode(e, mode);
    pts_lane_post(e, LE_FX_REVERB);
    const int32_t need = lcs_need(e);
    CHECK(need == 48000 * LE_FX_DRAIN_QUIET_MS / 1000 + e->fx_delay_frames);
    le_test_trk_jobs_blocks = 0;
    heard_silence(e, need / 2, 64, NULL);
    CHECK(!lcs_lane(e)->fx_asleep);
    if (mode == 2) CHECK(le_test_trk_jobs_blocks > 0);
    heard_silence(e, need, 64, NULL);
    CHECK(lcs_lane(e)->fx_asleep);
    CHECK(e->tracks[1].lanes[0].fx_asleep); /* pts_mode's EQ, no tail */
    le_test_trk_jobs_blocks = 0;
    heard_silence(e, 4800, 64, NULL);
    CHECK(le_test_trk_jobs_blocks == 0);
    le_test_trk_jobs_force = 0;
    le_engine_destroy(e);
  }
  le_test_trk_jobs_force = force;
}

/* A Clear's Post tail rings out first: the chain sleeps no sooner than a
 * whole horizon after the last frame at or over the floor, and the same
 * sample for sample however the chains run. */
static void lcs_clear_session(int mode, float* out, int32_t n,
                              int32_t* asleep_at, int32_t* last_loud) {
  le_engine* e = heard_engine(48000);
  pts_mode(e, mode);
  pts_lane_post(e, LE_FX_DELAY);
  pts_take(e);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  *asleep_at = -1;
  *last_loud = -1;
  for (int32_t done = 0; done < n; done += 37) {
    if (*asleep_at < 0 && lcs_lane(e)->fx_asleep) *asleep_at = done;
    heard_silence(e, 37, 37, out + 2 * done);
    for (int32_t i = 0; i < 2 * 37; ++i) {
      if (fabsf(out[2 * done + i]) >= LE_FX_DRAIN_FLOOR) {
        *last_loud = done + i / 2;
      }
    }
  }
  const int32_t need = lcs_need(e);
  if (*asleep_at < 0 || *asleep_at - *last_loud < need) {
    printf("  mode %s: asleep at %d, last loud %d, need %d\n",
           pts_mode_name[mode], (int)*asleep_at, (int)*last_loud, (int)need);
  }
  CHECK(*last_loud > 2400); /* it rang after the Clear */
  CHECK(*asleep_at >= 0);
  CHECK(*asleep_at - *last_loud >= need);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

static void test_lane_chain_drains_before_it_sleeps(void) {
  printf("test_lane_chain_drains_before_it_sleeps\n");
  enum { N = 48000 * 12 - (48000 * 12) % 37 };
  static float ref[2 * N];
  static float got[2 * N];
  const int force = le_test_trk_jobs_force;
  int32_t ref_at, ref_loud, at, loud;
  lcs_clear_session(0, ref, N, &ref_at, &ref_loud);
  for (int mode = 1; mode < 3; ++mode) {
    lcs_clear_session(mode, got, N, &at, &loud);
    CHECK(memcmp(ref, got, sizeof(ref)) == 0);
    CHECK(at == ref_at);
  }
  le_test_trk_jobs_force = force;
}

/* Three seconds of silence on an EMPTY track through a [kind] lane chain,
 * kept awake by re-sending a setting unchanged (an edit) with [awake], then
 * a take through it: [n] frames of its playback into [out]. */
static void lcs_take_session(int32_t kind, int awake, int mode, float* out,
                             int32_t n) {
  le_engine* e = heard_engine(48000);
  pts_mode(e, mode);
  pts_lane_post(e, kind);
  float p0;
  {
    float d[LE_FX_PARAMS];
    le_fx_defaults(kind, d);
    p0 = kind == LE_FX_DELAY ? 0.2f : kind == LE_FX_REVERB ? 0.9f : d[0];
  }
  for (int k = 0; k < 30; ++k) {
    if (awake) {
      CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, p0) == LE_OK);
      drain(e);
    }
    heard_silence(e, 4800, 64, NULL);
  }
  CHECK(lcs_lane(e)->fx_asleep == !awake);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  CHECK(!lcs_lane(e)->fx_asleep); /* a recording runs its chain */
  heard_feed(e, 64, PTS_TAKE - 64, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, n, 64, out);
  le_test_trk_jobs_force = 0;
  le_engine_destroy(e);
}

/* A take recorded after the chain slept plays exactly as one through a
 * chain kept awake. */
static void test_lane_chain_wakes_for_a_take(void) {
  printf("test_lane_chain_wakes_for_a_take\n");
  enum { N = 3 * PTS_TAKE };
  static float ref[2 * N];
  static float got[2 * N];
  const int force = le_test_trk_jobs_force;
  const int32_t kinds[2] = {LE_FX_DELAY, LE_FX_REVERB};
  for (int k = 0; k < 2; ++k) {
    lcs_take_session(kinds[k], 1, 0, ref, N);
    CHECK(pts_peak(ref, N) > 1e-3f);
    for (int mode = 0; mode < 3; ++mode) {
      lcs_take_session(kinds[k], 0, mode, got, N);
      if (memcmp(ref, got, sizeof(ref)) != 0) {
        printf("  kind %d (%s): differs from a chain kept awake\n",
               (int)kinds[k], pts_mode_name[mode]);
      }
      CHECK(memcmp(ref, got, sizeof(ref)) == 0);
    }
  }
  le_test_trk_jobs_force = force;
}

/* An edit wakes a sleeping chain for another whole horizon. */
static void test_lane_chain_wakes_on_edit(void) {
  printf("test_lane_chain_wakes_on_edit\n");
  le_engine* e = heard_engine(48000);
  pts_lane_post(e, LE_FX_DELAY);
  const int32_t need = lcs_need(e);
  heard_silence(e, need + 128, 64, NULL);
  CHECK(lcs_lane(e)->fx_asleep);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.4f) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  CHECK(!lcs_lane(e)->fx_asleep);
  heard_silence(e, need / 2, 64, NULL);
  CHECK(!lcs_lane(e)->fx_asleep);
  heard_silence(e, need, 64, NULL);
  CHECK(lcs_lane(e)->fx_asleep);
  le_engine_destroy(e);
}

/* A monitor chain is never put to sleep: after long silence, with every
 * lane chain asleep, the first frame played is heard through it. */
static void test_lane_chain_sleep_leaves_monitors(void) {
  printf("test_lane_chain_sleep_leaves_monitors\n");
  le_engine* e = heard_engine(48000);
  heard_monitor_reverb(e);
  pts_lane_post(e, LE_FX_DELAY);
  heard_silence(e, 3 * 48000, 64, NULL);
  CHECK(lcs_lane(e)->fx_asleep);
  float in[64] = {0};
  float out[128];
  in[0] = 0.5f;
  le_engine_process(e, out, in, 64);
  CHECK(fabsf(out[0]) > 0.1f && fabsf(out[1]) > 0.1f);
  le_engine_destroy(e);
}

static void run_lane_chain_sleep_tests(void) {
  test_lane_chain_quiet_frames();
  test_lane_chain_sleeps_on_empty_track();
  test_lane_chain_drains_before_it_sleeps();
  test_lane_chain_wakes_for_a_take();
  test_lane_chain_wakes_on_edit();
  test_lane_chain_sleep_leaves_monitors();
}
