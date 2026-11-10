/* #1713 part 3: the heard image's rendered tails. Included by
 * test_engine_core.c after test_engine_heard_perf.h (shares the heard
 * fixtures). */

/* Silence in 64-frame blocks with control's poll and a breath for the cache
 * worker between them, until track [t]'s tail is rendered, added and let go
 * of, or [max] frames pass. Returns the frames run. */
static int32_t tail_settle(le_engine* e, int t, int32_t max) {
  int32_t ran = 0;
  int seen = 0;
  for (; ran < max; ran += 64) {
    heard_silence(e, 64, 64, NULL);
    le_engine_drain_events(e);
    if (e->heard_tail_ctl[t] != NULL) seen = 1;
    if (seen && e->heard_tail_ctl[t] == NULL) break;
    test_sleep_ms(1);
  }
  return ran;
}

/* Copies lane 0's live image of track [t] (both sides) into [l] and [r]. */
static void tail_image(le_engine* e, int t, int32_t n, float* l, float* r) {
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, t, 0, load_i32(&e->tracks[t].lanes[0].a_live), &pl,
                        &pr));
  if (pl == NULL) return;
  memcpy(l, pl, (size_t)n * sizeof(float));
  memcpy(r, pr, (size_t)n * sizeof(float));
}

/* A take through the reverb closes into play: once its tail is rendered the
 * image holds the reverb's ringout after the take's last written position
 * (the seam continuation's end), decaying, on both sides; the clean take is
 * untouched. */
static void test_heard_tail_after_a_take(void) {
  printf("test_heard_tail_after_a_take\n");
  enum { N = 48000, F = 480 };
  le_engine* e = heard_engine(48000 * 4);
  heard_monitor_reverb(e);
  le_record_image image = heard_image(40, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  le_engine_drain_events(e); /* the input's ring, as the app's poll maps it */
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 2 * F, 64, NULL); /* the seam overlap closes the pass */
  static float clean[N];
  static float before_l[N];
  static float before_r[N];
  le_lane* ln = &e->tracks[0].lanes[0];
  memcpy(clean, ln->pool[load_i32(&ln->a_live)], sizeof(clean));
  tail_image(e, 0, N, before_l, before_r);
  const int32_t ran = tail_settle(e, 0, 4 * N);
  CHECK(ran < 4 * N);
  static float after_l[N];
  static float after_r[N];
  tail_image(e, 0, N, after_l, after_r);
  /* The tail starts after the last write and decays. */
  double early = 0.0;
  double late = 0.0;
  for (int32_t k = 0; k < 4800; ++k) {
    const int32_t q = (F + k) % N;
    early += fabs((double)after_l[q] - before_l[q]) +
             fabs((double)after_r[q] - before_r[q]);
    const int32_t q2 = (F + 24000 + k) % N;
    late += fabs((double)after_l[q2] - before_l[q2]) +
            fabs((double)after_r[q2] - before_r[q2]);
  }
  CHECK(early > 1e-2);
  CHECK(late < early);
  /* Nothing lands before the tail's start. */
  double ahead = 0.0;
  for (int32_t q = 0; q < F; ++q) {
    ahead += fabs((double)after_l[q] - before_l[q]);
  }
  CHECK(ahead == 0.0);
  CHECK(memcmp(clean, ln->pool[load_i32(&ln->a_live)], sizeof(clean)) == 0);
  le_engine_destroy(e);
}

/* A take that runs straight into overdub keeps capturing: no pass ends at
 * the take's length, so no tail is rendered there. */
static void test_heard_tail_not_while_capturing(void) {
  printf("test_heard_tail_not_while_capturing\n");
  enum { N = 4800 };
  le_engine* e = heard_engine(48000 * 4);
  heard_monitor_reverb(e);
  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  le_record_image image = heard_image(41, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  le_engine_drain_events(e);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK); /* rec -> dub */
  for (int k = 0; k < 40; ++k) {
    heard_feed(e, N + 64 * k, 64, 64, NULL);
    le_engine_drain_events(e);
  }
  CHECK(e->heard_tail_ctl[0] == NULL);
  CHECK(e->heard_pass[0].gen == 0);
  le_engine_destroy(e);
}

/* An overdub through the reverb punched out: its tail lands after the
 * punch-out, and Undo of the pass takes the tail with it. A new capture
 * before a tail is added drops what is not added. */
static void test_heard_tail_after_a_punch_out(void) {
  printf("test_heard_tail_after_a_punch_out\n");
  enum { N = 48000 };
  le_engine* e = heard_take_fixture(N, 42); /* monitor muted, playing */
  le_engine_drain_events(e);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK); /* overdub */
  heard_feed(e, 0, 9600, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 960, 64, NULL);
  const uint32_t gen = e->heard_pass[0].gen;
  CHECK(gen >= 1);
  static float before_l[N];
  static float before_r[N];
  tail_image(e, 0, N, before_l, before_r);
  CHECK(tail_settle(e, 0, 4 * N) < 4 * N);
  static float after_l[N];
  static float after_r[N];
  tail_image(e, 0, N, after_l, after_r);
  double added = 0.0;
  for (int32_t q = 0; q < N; ++q) added += fabs((double)after_l[q] - before_l[q]);
  CHECK(added > 1e-2);
  /* Undo of the pass: the pre-pass image, without the tail. */
  settle_layers(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  static float undone_l[N];
  static float undone_r[N];
  tail_image(e, 0, N, undone_l, undone_r);
  double back = 0.0;
  for (int32_t q = 0; q < N; ++q) back += fabs((double)undone_l[q] - after_l[q]);
  CHECK(back > 1e-2);
  le_engine_destroy(e);
}

/* A loop shorter than its tail: the tail wraps, adding onto the image lap
 * after lap until it is spent, and the clean take is untouched. */
static void test_heard_tail_wraps_a_short_loop(void) {
  printf("test_heard_tail_wraps_a_short_loop\n");
  enum { N = 4800 };
  le_engine* e = heard_engine(48000 * 4);
  heard_monitor_reverb(e);
  le_record_image image = heard_image(43, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  le_engine_drain_events(e);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, 960, 64, NULL);
  static float clean[N];
  static float before_l[N];
  static float before_r[N];
  le_lane* ln = &e->tracks[0].lanes[0];
  memcpy(clean, ln->pool[load_i32(&ln->a_live)], sizeof(clean));
  tail_image(e, 0, N, before_l, before_r);
  CHECK(tail_settle(e, 0, 40 * N) < 40 * N);
  static float after_l[N];
  static float after_r[N];
  tail_image(e, 0, N, after_l, after_r);
  int32_t changed = 0;
  for (int32_t q = 0; q < N; ++q) changed += after_l[q] != before_l[q];
  CHECK(changed > N / 2); /* a reverb tail longer than the loop covers it */
  CHECK(memcmp(clean, ln->pool[load_i32(&ln->a_live)], sizeof(clean)) == 0);
  le_engine_destroy(e);
}

/* Stop before the tail lands: what is not added yet is dropped (a Stop cuts
 * printed effects), and the image keeps what it had. */
static void test_heard_tail_stop_drops_it(void) {
  printf("test_heard_tail_stop_drops_it\n");
  enum { N = 48000 };
  le_engine* e = heard_take_fixture(N, 44);
  le_engine_drain_events(e);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, 0, 9600, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  heard_silence(e, 960, 64, NULL);       /* the pass ends */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  static float before_l[N];
  static float before_r[N];
  tail_image(e, 0, N, before_l, before_r);
  tail_settle(e, 0, 4 * N);
  static float after_l[N];
  static float after_r[N];
  tail_image(e, 0, N, after_l, after_r);
  CHECK(memcmp(before_l, after_l, sizeof(before_l)) == 0);
  CHECK(memcmp(before_r, after_r, sizeof(before_r)) == 0);
  le_engine_destroy(e);
}

static void run_heard_tail_tests(void) {
  test_heard_tail_after_a_take();
  test_heard_tail_not_while_capturing();
  test_heard_tail_after_a_punch_out();
  test_heard_tail_wraps_a_short_loop();
  test_heard_tail_stop_drops_it();
}
