/* #1713 part 2a: the heard image through length edits, the render recipe
 * (Bounce, Save selected), the whole-track print and session layers.
 * Included by test_engine_core.c after test_engine_heard.h,
 * test_engine_length.h and test_engine_render.h (shares their helpers). */

/* A heard take of N frames through input 0's reverb on track 0, finalized
 * and playing with the monitor muted, so only the take sounds. */
static le_engine* heard_take_fixture(int32_t n, uint32_t revision) {
  le_engine* e = heard_engine(48000 * 4);
  heard_monitor_reverb(e);
  le_record_image image = heard_image(revision, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, n, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, n, 960, 64, NULL);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, n, 64, NULL);
  return e;
}

/* Double and both halves build the edited image's heard image with the clean
 * take's arithmetic (with an empty input chain the image IS the clean take,
 * so the lockstep check covers every edit, Undo and Redo), and a take through
 * a reverb keeps its own image across a Double. */
static void test_heard_length_edits(void) {
  printf("test_heard_length_edits\n");
  enum { N = 4800 };
  le_engine* e = heard_engine(48000 * 4);
  le_test_heard_check = heard_lockstep_check;
  g_heard_check_failed = 0;
  le_record_image image = heard_image(20, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, 2 * N, 64, NULL);
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  CHECK(load_i32(&e->tracks[0].lanes[0].a_len) == 2 * N);
  CHECK(le_heard_has(e, 0, 0, load_i32(&e->tracks[0].lanes[0].a_live)));
  CHECK(len_edit(e, 0, LE_LENGTH_FIRST_HALF) == LE_OK);
  CHECK(len_edit(e, 0, LE_LENGTH_LAST_HALF) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  len_settle(e);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  len_settle(e);
  heard_silence(e, N, 64, NULL);
  CHECK(!g_heard_check_failed);
  le_test_heard_check = NULL;
  le_engine_destroy(e);

  e = heard_take_fixture(N, 21);
  le_lane* ln = &e->tracks[0].lanes[0];
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, load_i32(&ln->a_live), &pl, &pr));
  static float before_l[N];
  static float before_r[N];
  memcpy(before_l, pl, sizeof(before_l));
  memcpy(before_r, pr, sizeof(before_r));
  CHECK(len_edit(e, 0, LE_LENGTH_DOUBLE) == LE_OK);
  CHECK(le_heard_planes(e, 0, 0, load_i32(&ln->a_live), &pl, &pr));
  for (int32_t i = 0; i < 2 * N && pl != NULL; ++i) {
    CHECK(pl[i] == before_l[i % N]);
    CHECK(pr[i] == before_r[i % N]);
  }
  le_engine_destroy(e);
}

/* The render recipe plays a heard lane as the rig does: its image at level
 * through no chain (the lane's drive is not applied). */
static void test_heard_render_reads_the_image(void) {
  printf("test_heard_render_reads_the_image\n");
  enum { N = 4800 };
  le_engine* e = heard_take_fixture(N, 22);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 1.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  CHECK(le_engine_set_lane_volume(e, 0, 0, 0.5f) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, load_i32(&e->tracks[0].lanes[0].a_live), &pl,
                        &pr));
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  static float out[2 * N];
  CHECK(rr_render(e, &q, out, N) == N);
  le_lane_snapshot ls;
  le_engine_get_lane(e, 0, 0, &ls);
  const float vol = ls.volume;
  CHECK(vol == 0.5f);
  int matched = 0;
  for (int32_t f = 0; f < N && pl != NULL; ++f) {
    matched += fabsf(out[2 * f] - pl[f] * vol) < 1e-6f &&
               fabsf(out[2 * f + 1] - pr[f] * vol) < 1e-6f;
  }
  CHECK(matched == N);
  le_engine_destroy(e);
}

/* A track whose part plays its image gets a whole-track print over that
 * image; until then it plays live, and the print is published and engaged. */
static void test_heard_track_print(void) {
  printf("test_heard_track_print\n");
  enum { N = 48000 }; /* the print lands within a lap (#939) */
  le_engine* e = heard_take_fixture(N, 23);
  CHECK(le_engine_set_track_fx(e, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_track_fx_count(e, 0, 1, 1) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  CHECK(le_track_pre_printable(e, 0));
  for (int k = 0; k < 2000 &&
                  !atomic_load_explicit(&e->tracks[0].a_track_cache_active,
                                        memory_order_relaxed);
       ++k) {
    heard_silence(e, 64, 64, NULL);
    le_engine_drain_events(e);
    test_sleep_ms(1);
  }
  CHECK(atomic_load_explicit(&e->tracks[0].a_track_wet,
                             memory_order_acquire) != NULL);
  CHECK(atomic_load_explicit(&e->tracks[0].a_track_cache_active,
                             memory_order_relaxed));
  le_engine_destroy(e);
}

/* Every image's heard image survives a session round trip: export the
 * history and each layer's clean and heard images, import them into a
 * fresh engine, and each slot holds the same planes. */
static void test_heard_session_layers(void) {
  printf("test_heard_session_layers\n");
  enum { N = 4800 };
  le_engine* e = heard_take_fixture(N, 24);
  /* An overdub through the reverb, so two images differ. */
  CHECK(le_engine_set_monitor_input_mute(e, 0, 0) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, 2 * N, 64, NULL);
  settle_layers(e);
  int32_t kinds[8], skipped[8], starts[8], undo = 0;
  const int32_t count =
      le_engine_export_history(e, 0, kinds, skipped, starts, 8, &undo);
  CHECK(count >= 1 && count <= 3 && undo == count); /* layers, no redo */
  const int32_t images = count + 1;
  static float clean[4][N];
  static float heard[4][2 * N];
  for (int32_t o = 0; o < images; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, clean[o], N) == N);
    CHECK(le_engine_export_layer_heard(e, 0, 0, o, NULL, 0) == N);
    CHECK(le_engine_export_layer_heard(e, 0, 0, o, heard[o], N) == N);
  }
  float lane_heard[2 * 64];
  CHECK(le_engine_export_track_lane_heard(e, 0, 0, lane_heard, 64) == 64);
  for (int32_t i = 0; i < 2 * 64; ++i) {
    CHECK(lane_heard[i] == heard[undo][i]); /* the live image */
  }
  le_engine_destroy(e);

  le_engine* b = heard_engine(48000 * 4);
  for (int32_t o = 0; o < images; ++o) {
    CHECK(le_engine_import_layer(b, 0, 0, o, clean[o], N) == LE_OK);
    /* Only at the clean image's own length, and only on a staged lane. */
    CHECK(le_engine_import_layer_heard(b, 0, 0, o, heard[o], N - 1) ==
          LE_ERR_INVALID);
    CHECK(le_engine_import_layer_heard(b, 0, 1, o, heard[o], N) ==
          LE_ERR_INVALID);
    CHECK(le_engine_import_layer_heard(b, 0, 0, o, heard[o], N) == LE_OK);
  }
  int32_t lens[4] = {N, N, N, N};
  CHECK(le_engine_finalize_history(b, 0, kinds, skipped, starts, count, undo,
                                   lens, images) == LE_OK);
  for (int32_t o = 0; o < images; ++o) {
    float* pl;
    float* pr;
    CHECK(le_heard_planes(b, 0, 0, o, &pl, &pr));
    for (int32_t i = 0; i < N && pl != NULL; ++i) {
      CHECK(pl[i] == heard[o][2 * i]);
      CHECK(pr[i] == heard[o][2 * i + 1]);
    }
  }
  /* A layer with no heard image exports none. */
  CHECK(le_engine_import_layer(b, 1, 0, 0, clean[0], N) == LE_OK);
  CHECK(le_engine_export_layer_heard(b, 1, 0, 0, NULL, 0) == 0);
  le_engine_destroy(b);
}

/* #1713 part 2b: a heard take under Transpose. Its source render carries the
 * image's planes (le_wet_entry.planes 3), and the lane plays the shifted
 * image: 440 Hz on both sides from a 220 Hz take, its right side the
 * negated left as the image's was. */
static void test_heard_transpose(void) {
  printf("test_heard_transpose\n");
  static float take[TP_LEN];
  static float image[2 * TP_LEN];
  for (int i = 0; i < TP_LEN; ++i) {
    take[i] = 0.5f * (float)sin(2.0 * M_PI * 220.0 * i / TP_SR);
    image[2 * i] = take[i];
    image[2 * i + 1] = -take[i];
  }
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TP_SR, 1, 2, 30000) == LE_OK);
  CHECK(le_engine_import_layer(e, 0, 0, 0, take, TP_LEN) == LE_OK);
  CHECK(le_engine_import_layer_heard(e, 0, 0, 0, image, TP_LEN) == LE_OK);
  int32_t lens[1] = {TP_LEN};
  CHECK(le_engine_finalize_history(e, 0, NULL, NULL, NULL, 0, 0, lens, 1) ==
        LE_OK);
  CHECK(le_engine_commit_session(e, TP_LEN, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  CHECK(le_heard_has(e, 0, 0, load_i32(&e->tracks[0].lanes[0].a_live)));
  uint64_t id = tp_install(e, 0, 12);
  (void)id;
  static float out[2 * 4 * TP_LEN];
  float in[64] = {0};
  int engaged = 0;
  for (int at = 0; at < 4 * TP_LEN && !engaged; at += 64) {
    le_lane_cache_info info;
    le_engine_get_transpose_cache(e, 0, &info);
    test_sleep_ms(1);
    le_engine_process(e, out, in, 64);
    engaged = tp_effective(e, 0) == 12;
  }
  CHECK(engaged);
  const le_wet_entry* se = e->tracks[0].src_ent[0];
  CHECK(se != NULL && se->planes == 3);
  for (int at = 0; at < 3 * TP_LEN; at += 64) {
    le_engine_process(e, out + 2 * at, in, 64);
  }
  static float lch[2 * TP_LEN];
  static float rch[2 * TP_LEN];
  for (int i = 0; i < 2 * TP_LEN; ++i) {
    lch[i] = out[2 * (TP_LEN + i)];
    rch[i] = out[2 * (TP_LEN + i) + 1];
  }
  const double l440 = tp_power(lch, 0, 2 * TP_LEN, 440.0);
  const double l220 = tp_power(lch, 0, 2 * TP_LEN, 220.0);
  CHECK(l440 > 100.0 * l220); /* shifted, from the image */
  double sum = 0.0;
  double mag = 0.0;
  for (int i = 0; i < 2 * TP_LEN; ++i) {
    sum += fabs((double)lch[i] + (double)rch[i]);
    mag += fabs((double)lch[i]);
  }
  CHECK(mag > 1.0);
  CHECK(sum < 1e-3 * mag); /* the sides as the image's: R = -L */
  le_engine_destroy(e);
}

static void run_heard_edit_tests(void) {
  test_heard_transpose();
  test_heard_length_edits();
  test_heard_render_reads_the_image();
  test_heard_track_print();
  test_heard_session_layers();
}
