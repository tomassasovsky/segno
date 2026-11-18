/* #1741: a take records its input chain's Pre run; the chain's Post entries
 * belong to the lane and run live over the image, so they ring out past a
 * Stop. Included by test_engine_core.c after test_engine_heard_tail.h
 * (shares the heard fixtures). */

/* Input 0's monitor chain through a recipe: a reverb, then a delay, with
 * the first [pre] entries Pre. */
static void heard_post_monitor(le_engine* e, int32_t count, int32_t pre,
                               uint32_t revision) {
  le_fx_recipe r;
  memset(&r, 0, sizeof(r));
  r.count = count;
  r.pre_count = pre;
  r.enabled = 1;
  const int32_t types[2] = {LE_FX_REVERB, LE_FX_DELAY};
  for (int s = 0; s < count; ++s) {
    r.type[s] = types[s];
    r.slot_enabled[s] = 1;
    r.level[s] = 1.0f;
    r.params[s][0] = 0.5f;
    r.params[s][1] = 0.5f;
    r.params[s][2] = 0.5f;
    r.instance[s] = 100u + (uint64_t)s;
  }
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, revision, &r) ==
        LE_OK);
  drain(e);
}

/* A take of [n] frames through input 0's chain, closed into play with the
 * monitor muted after it; returns its live image's left plane. */
static const float* heard_post_take(le_engine* e, int32_t n) {
  le_record_image image = heard_image(51, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, n, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 960, 64, NULL);
  float* pl = NULL;
  float* pr = NULL;
  CHECK(le_heard_planes(e, 0, 0, load_i32(&e->tracks[0].lanes[0].a_live), &pl,
                        &pr));
  return pl;
}

/* The lane takes the take's copy of the input chain: a reverb at Pre and a
 * delay at Post. */
static void heard_post_lane_copy(le_engine* e) {
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 2, 1) == LE_OK);
  drain(e);
}

/* The image holds what the lane does not run live: the input chain's Pre
 * run where the lane carries the Post entries (the same as a take through
 * the reverb alone), and the whole chain where the lane has none (an
 * overdub over a take recorded dry). */
static void test_heard_records_the_pre_run(void) {
  printf("test_heard_records_the_pre_run\n");
  enum { N = 4800, F = 480 };
  le_engine* both = heard_engine(48000);
  heard_post_monitor(both, 2, 1, 1);
  heard_post_lane_copy(both);
  le_engine* bare = heard_engine(48000);
  heard_post_monitor(bare, 2, 1, 1);
  le_engine* pre = heard_engine(48000);
  heard_post_monitor(pre, 1, 1, 1);
  const float* a = heard_post_take(both, N);
  const float* w = heard_post_take(bare, N);
  const float* b = heard_post_take(pre, N);
  CHECK(a != NULL && b != NULL && w != NULL);
  int same = a != NULL && b != NULL;
  int whole = 0;
  double energy = 0.0;
  for (int32_t i = F; same && i < N; ++i) {
    if (a[i] != b[i]) same = 0;
    if (w != NULL && w[i] != b[i]) whole = 1;
    energy += fabs((double)a[i]);
  }
  CHECK(same);
  CHECK(whole);
  CHECK(energy > 1e-2);
  le_engine_destroy(both);
  le_engine_destroy(bare);
  le_engine_destroy(pre);
}

/* The lane's Post delay plays over the image and rings out past a Stop; the
 * same delay at Pre is printed and Stop cuts it, as the take's Pre run is. */
static void test_heard_post_rings_past_stop(void) {
  printf("test_heard_post_rings_past_stop\n");
  enum { N = 9600 };
  for (int post = 0; post < 2; ++post) {
    le_engine* e = heard_engine(48000);
    heard_post_monitor(e, 1, 1, 1);
    /* The take's lane: the reverb (Pre, the image stands for it), then a
     * delay at Post or at Pre. */
    CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_DELAY) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 0, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 1, 0.7f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 1, 2, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_count(e, 0, 0, 2, post ? 1 : 2) == LE_OK);
    drain(e);
    heard_post_take(e, N);
    heard_silence(e, 2 * N, 64, NULL); /* laps of the image */
    CHECK(le_engine_stop_track(e, 0) == LE_OK);
    heard_silence(e, 4800, 64, NULL); /* past the Stop fade */
    static float out[2 * 24000];
    heard_silence(e, 24000, 64, out);
    float peak = 0.0f;
    for (int32_t i = 0; i < 2 * 24000; ++i) peak = fmaxf(peak, fabsf(out[i]));
    if (post) {
      CHECK(peak > 1e-3f);
    } else {
      CHECK(peak == 0.0f);
    }
    le_engine_destroy(e);
  }
}

static void run_heard_post_tests(void) {
  test_heard_records_the_pre_run();
  test_heard_post_rings_past_stop();
}
