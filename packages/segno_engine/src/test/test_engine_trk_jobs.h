/* Track chains as jobs (#1729): the lanes' and the tracks' chains run on the
 * effects workers, as the monitor chains do (#1515), and the engine's output
 * is bit-identical whichever runs them.
 *
 * One scripted session (tj_session) drives a device-free engine with both
 * monitors' chains on (test_engine_fx_workers.h's), four tracks: track 0
 * with every kind on its lane, track 1 with synced kinds on its own chain,
 * track 2 recorded through a capture image that holds a heard image (#1713)
 * with draining kinds on its lane and a chain of its own, track 3 with no
 * chain, and the All tracks stage with synced kinds. The script plays the
 * cases a track's job has to keep its order through: takes and their
 * finalize inside blocks, a Stop's tail clear and a Play, a mute and an
 * unmute, a solo, a pan, a stomp and a retype, the heard take crossfading
 * to its clean take and back, frames the latency harness owns, all in blocks of every size from one frame to more than two of the
 * frame loop's LE_FX_BLOCK. Its output is compared, sample for sample,
 * across 0, 1, 2 and 3 workers. With none, every chain runs in the one frame
 * loop as before #1729. */

#define TJ_FRAMES (FXW_SR * 3)

/* Synced kinds, and the kinds that drain a tail when switched off. */
static void tj_recipe(le_fx_recipe* r, const int32_t* kinds, int32_t n,
                      uint64_t base) {
  memset(r, 0, sizeof(*r));
  r->enabled = 1;
  r->count = n;
  for (int32_t s = 0; s < n; ++s) {
    r->type[s] = kinds[s];
    r->slot_enabled[s] = 1;
    r->level[s] = 1.0f;
    le_fx_defaults(kinds[s], r->params[s]);
    r->instance[s] = base + (uint64_t)s;
  }
}

static void tj_session(int32_t workers, float* out,
                       le_fx_workers_telemetry* tm) {
  static const uint32_t sizes[] = {64, 17, 300, 1, 256, 513, 128, 64, 7, 640};
  static const int32_t synced[] = {LE_FX_PUMPER, LE_FX_SLICER,
                                   LE_FX_MODE_DELAY, LE_FX_TREMOLO};
  static const int32_t tails[] = {LE_FX_REVERB, LE_FX_DELAY, LE_FX_ECHO,
                                  LE_FX_ROOM_VERB};
  static const int32_t own[] = {LE_FX_DRIVE, LE_FX_COMPRESSOR, LE_FX_CHORUS};
  static const int32_t all[] = {LE_FX_MOD, LE_FX_ECHO};
  le_engine* e = le_engine_create();
  CHECK(e != NULL);
  CHECK(le_engine_configure(e, FXW_SR, FXW_IN, FXW_OUT, FXW_SR * 4) == LE_OK);
  CHECK(le_engine_set_fx_cache_cap(e, 0) == LE_OK); /* every chain live */
  CHECK(le_engine_set_fx_workers(e, workers, NULL) == LE_OK);
  uint32_t rev = 1;
  le_fx_recipe m0, m1, lane0, trk1, lane2, trk2, at;
  fxw_recipe(&m0, 0);
  fxw_recipe(&m1, 1);
  fxw_recipe(&lane0, 0);
  for (int32_t s = 0; s < lane0.count; ++s) lane0.instance[s] += 1000u;
  tj_recipe(&trk1, synced, 4, 2000u);
  tj_recipe(&lane2, tails, 4, 3000u);
  tj_recipe(&trk2, own, 3, 4000u);
  trk2.pre_count = 1;
  tj_recipe(&at, all, 2, 5000u);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 1, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x3u) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 1, 0xCu) == LE_OK);
  fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
  fxw_post(e, LE_FX_OWNER_MONITOR, 1, &rev, &m1);
  CHECK(le_engine_set_tempo(e, 117.0f) == LE_OK);

  static float in[1024 * FXW_IN];
  int32_t at_frame = 0;
  int step = 0;
  while (at_frame < TJ_FRAMES) {
    uint32_t n = sizes[step % (int)(sizeof(sizes) / sizeof(sizes[0]))];
    if ((int32_t)n > TJ_FRAMES - at_frame) n = (uint32_t)(TJ_FRAMES - at_frame);
    /* The script, at block boundaries. A 0.6 s take on track 0 defines the
     * loop, so it wraps (and re-anchors the synced kinds) every 0.6 s. */
    if (step == 3) CHECK(le_engine_record(e, 0) == LE_OK);
    if (at_frame >= FXW_SR * 6 / 10 && step < 1000) {
      CHECK(le_engine_record(e, 0) == LE_OK);
      fxw_post(e, LE_FX_OWNER_LANE, 0, &rev, &lane0);
      fxw_post(e, LE_FX_OWNER_ALL_TRACKS, 0, &rev, &at);
      CHECK(le_engine_record(e, 1) == LE_OK);
      step = 1000; /* once */
    }
    if (step == 1030) { /* track 1's take ends; its chain goes on */
      CHECK(le_engine_record(e, 1) == LE_OK);
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, 1, 0, ++rev,
                                    &trk1) == LE_OK);
    }
    if (step == 1040) { /* track 2 records what input 0's chain is heard as */
      le_record_image image = heard_image(77, 1);
      CHECK(le_engine_record_with_image(e, 2, &image) == LE_OK);
    }
    if (step == 1090) {
      CHECK(le_engine_record(e, 2) == LE_OK);
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 2, 0, ++rev,
                                    &lane2) == LE_OK);
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, 2, 0, ++rev,
                                    &trk2) == LE_OK);
      CHECK(le_engine_record(e, 3) == LE_OK); /* track 3: no chain */
    }
    if (step == 1120) CHECK(le_engine_record(e, 3) == LE_OK);
    if (step == 1150) CHECK(le_engine_stop_track(e, 1) == LE_OK);
    if (step == 1170) CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
    if (step == 1190) CHECK(le_engine_play(e, 1) == LE_OK);
    if (step == 1200) CHECK(le_engine_set_lane_mute(e, 0, 0, 0) == LE_OK);
    if (step == 1220) CHECK(le_engine_set_track_solo(e, 2, 1) == LE_OK);
    if (step == 1240) CHECK(le_engine_set_lane_pan(e, 1, 0, -0.6f) == LE_OK);
    if (step == 1260) CHECK(le_engine_set_track_solo(e, 2, 0) == LE_OK);
    if (step == 1280) { /* a measurement: frames the harness owns */
      CHECK(le_engine_begin_latency_for_test(e, 0, 1, 0.5f, 1) == LE_OK);
    }
    if (step == 1320) { /* a stomp on track 0's lane, a retype on track 1 */
      lane0.slot_enabled[2] = 0;
      fxw_post(e, LE_FX_OWNER_LANE, 0, &rev, &lane0);
      trk1.type[3] = LE_FX_DRIVE;
      le_fx_defaults(LE_FX_DRIVE, trk1.params[3]);
      trk1.instance[3] = 2999u;
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, 1, 0, ++rev,
                                    &trk1) == LE_OK);
    }
    if (step == 1300) { /* track 2's heard take crossfades to its clean */
      CHECK(le_engine_set_lane_source(e, 2, 0, LE_LANE_SOURCE_CLEAN) == LE_OK);
    }
    if (step == 1340) {
      CHECK(le_engine_set_lane_source(e, 2, 0, LE_LANE_SOURCE_HEARD) == LE_OK);
    }
    if (step == 1360) CHECK(le_engine_stop_track(e, 2) == LE_OK);
    for (uint32_t f = 0; f < n; ++f) {
      for (int32_t c = 0; c < FXW_IN; ++c) {
        in[f * FXW_IN + (uint32_t)c] = fxw_input(c, at_frame + (int32_t)f);
      }
    }
    le_engine_process(e, out + (size_t)at_frame * FXW_OUT, in, n);
    at_frame += (int32_t)n;
    ++step;
  }
  if (tm != NULL) le_engine_get_fx_workers_telemetry(e, tm);
  CHECK(step > 1360); /* the whole script ran */
  le_engine_destroy(e);
}

static float g_tj_ref[TJ_FRAMES * FXW_OUT];
static float g_tj_out[TJ_FRAMES * FXW_OUT];

static void test_trk_jobs_output_is_bit_identical(void) {
  printf("test_trk_jobs_output_is_bit_identical\n");
  le_fx_workers_telemetry tm;
  le_test_trk_jobs_blocks = 0;
  tj_session(0, g_tj_ref, &tm);
  CHECK(tm.rounds == 0);
  float peak = 0.0f;
  for (int64_t i = 0; i < (int64_t)TJ_FRAMES * FXW_OUT; ++i) {
    if (fabsf(g_tj_ref[i]) > peak) peak = fabsf(g_tj_ref[i]);
  }
  CHECK(peak > 0.05f);
  /* None with no worker, unless the whole suite forces them. */
  CHECK(le_test_trk_jobs_force || le_test_trk_jobs_blocks == 0);
  for (int32_t w = 1; w <= LE_FX_WORKERS_MAX; ++w) {
    le_test_trk_jobs_blocks = 0;
    tj_session(w, g_tj_out, &tm);
    CHECK(le_test_trk_jobs_blocks > 0); /* the tracks ran as jobs */
    int64_t d = -1;
    for (int64_t i = 0; i < (int64_t)TJ_FRAMES * FXW_OUT; ++i) {
      if (memcmp(&g_tj_ref[i], &g_tj_out[i], sizeof(float)) != 0) {
        d = i;
        break;
      }
    }
    if (d >= 0) {
      printf("  %d workers: first difference at frame %lld, output %lld "
             "(%g vs %g)\n",
             (int)w, (long long)(d / FXW_OUT), (long long)(d % FXW_OUT),
             g_tj_ref[d], g_tj_out[d]);
    }
    CHECK(d < 0);
    CHECK(tm.running == w);
    /* Every block was a round: the monitors and the tracks. */
    CHECK(tm.rounds > 0);
    uint64_t worker_jobs = 0;
    for (int32_t k = 0; k < w; ++k) worker_jobs += tm.worker[k].jobs;
    /* Workers' job counts are callback telemetry (LE_CALLBACK_TELEMETRY). */
    CHECK_TIMING(worker_jobs > 0);
    /* More jobs than the two monitors': the tracks' ran as jobs too. */
    printf("  %d workers: %llu rounds, %llu jobs\n", (int)w,
           (unsigned long long)tm.rounds,
           (unsigned long long)(worker_jobs + tm.callback_jobs));
    CHECK_TIMING(worker_jobs + tm.callback_jobs > 2u * tm.rounds);
  }
}

/* The prints (FX v3 part 2) and a Stop's tail clear, which change what a
 * track's job reads in the middle of a block: a lane's Pre reverb and a
 * whole-track print engage at a loop top, and track 0's Stop clears its Pre
 * tails where its fade-out ends, both inside blocks of 37 frames, so the
 * job must have run the frames before them first (le_trk_jobs_flush). The
 * cache's renders land at a fixed point of the session (wt_tick spins until
 * they do), so the session is the same with any worker count. */
#define TJP_FRAMES (WT_LOOP * 6)

static void tjp_session(int32_t workers, float* out,
                        le_fx_workers_telemetry* tm) {
  static const int32_t lane_kinds[] = {LE_FX_REVERB, LE_FX_DELAY};
  static const int32_t trk_kinds[] = {LE_FX_COMPRESSOR, LE_FX_CHORUS};
  static const int32_t t1_kinds[] = {LE_FX_ECHO, LE_FX_TREMOLO};
  le_engine* e =
      wt_engine_two_parts_loop(0.5f, LE_CACHE_DEFAULT_CAP_BYTES, WT_LOOP);
  CHECK(le_engine_set_fx_workers(e, workers, NULL) == LE_OK);
  le_fx_recipe lane0, trk0, t1;
  tj_recipe(&lane0, lane_kinds, 2, 6000u);
  lane0.pre_count = 1; /* the Pre reverb prints, the delay stays live */
  tj_recipe(&trk0, trk_kinds, 2, 6100u);
  trk0.pre_count = 1;
  tj_recipe(&t1, t1_kinds, 2, 6200u);
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 0, 0, 10, &lane0) ==
        LE_OK);
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_TRACK, 0, 0, 11, &trk0) ==
        LE_OK);
  /* Track 1: a take of its own, with a live chain, so there are two jobs. */
  CHECK(le_engine_set_lane_input(e, 1, 0, 1) == LE_OK);
  CHECK(le_engine_set_lane_output(e, 1, 0, 0x3) == LE_OK);
  CHECK(le_engine_record(e, 1) == LE_OK);
  static float in[2 * 64];
  int32_t at = 0;
  int stopped = 0;
  int played = 0;
  while (at < TJP_FRAMES) {
    const int32_t n = TJP_FRAMES - at < 37 ? TJP_FRAMES - at : 37;
    for (int32_t i = 0; i < 2 * n; ++i) {
      in[i] = 0.3f * sinf(0.013f * (float)(at + i / 2)) + 0.1f;
    }
    if (at >= WT_LOOP && at < WT_LOOP + 37) {
      CHECK(le_engine_record(e, 1) == LE_OK);
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 1, 0, 12, &t1) ==
            LE_OK);
    }
    if (!stopped && at >= WT_LOOP * 4) {
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
      stopped = 1;
    }
    if (!played && at >= WT_LOOP * 5) {
      CHECK(le_engine_play(e, 0) == LE_OK);
      played = 1;
    }
    le_engine_process(e, out + (size_t)at * 2, in, (uint32_t)n);
    (void)wt_tick(e);
    at += n;
  }
  le_lane_cache_info info;
  CHECK(le_engine_get_lane_cache(e, 0, 0, &info) == LE_OK);
  CHECK(info.renders > 0); /* a print was made and played */
  if (tm != NULL) le_engine_get_fx_workers_telemetry(e, tm);
  le_engine_destroy(e);
}

static float g_tjp_ref[TJP_FRAMES * 2];
static float g_tjp_out[TJP_FRAMES * 2];

static void test_trk_jobs_prints_and_stops_are_bit_identical(void) {
  printf("test_trk_jobs_prints_and_stops_are_bit_identical\n");
  le_fx_workers_telemetry tm;
  tjp_session(0, g_tjp_ref, NULL);
  for (int32_t w = 1; w <= 2; ++w) {
    le_test_trk_jobs_blocks = 0;
    tjp_session(w, g_tjp_out, &tm);
    CHECK(le_test_trk_jobs_blocks > 0);
    int64_t d = -1;
    for (int64_t i = 0; i < (int64_t)TJP_FRAMES * 2; ++i) {
      if (memcmp(&g_tjp_ref[i], &g_tjp_out[i], sizeof(float)) != 0) {
        d = i;
        break;
      }
    }
    if (d >= 0) {
      printf("  %d workers: first difference at frame %lld (%g vs %g)\n",
             (int)w, (long long)(d / 2), g_tjp_ref[d], g_tjp_out[d]);
    }
    CHECK(d < 0);
    CHECK(tm.rounds > 0);
  }
}

static void run_trk_jobs_tests(void) {
  test_trk_jobs_output_is_bit_identical();
  test_trk_jobs_prints_and_stops_are_bit_identical();
}
