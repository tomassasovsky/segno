/* Audibility fades (#1400): a mute, an unmute, a solo, a Stop, a Cut and a
 * Play each fade the track over ~10 ms instead of switching it in one frame.
 *
 * The fixture is a 100 Hz cosine at 0.5 (ten whole cycles in 4800 frames at
 * 48 kHz, so the loop's own seam is continuous). Its largest sample-to-sample
 * change is 0.5 * 2 * pi * 100 / 48000 = 0.0065, and a fade adds at most
 * 0.5 / 480 = 0.001 to it, so a fade stays under 1.3x the material's own
 * slope while a one-frame switch at the peak is a 0.5 step, 76x. */
#define GF_SR 48000
#define GF_LEN 4800
#define GF_F (GF_SR / 100)

static float gf_take[GF_LEN];

static float gf_x(int64_t i) {
  i %= GF_LEN;
  if (i < 0) i += GF_LEN;
  return gf_take[i];
}

/* [tracks] tracks of the cosine (track 1 silent when [quiet1]), every one
 * playing and one whole lap in, so each Play's own fade is over and the read
 * is back at the peak, index 0. */
static le_engine* gf_fixture(int tracks, int quiet1) {
  for (int i = 0; i < GF_LEN; ++i) {
    gf_take[i] = (float)(0.5 * cos(2.0 * 3.14159265358979323846 * 100.0 *
                                   (double)i / GF_SR));
  }
  static float zeros[GF_LEN];
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, GF_SR, 1, 1, 2 * GF_LEN) == LE_OK);
  for (int t = 0; t < tracks; ++t) {
    CHECK(le_engine_import_track(e, t, quiet1 && t == 1 ? zeros : gf_take,
                                 GF_LEN) == LE_OK);
  }
  CHECK(le_engine_commit_session(e, GF_LEN, 0) == LE_OK);
  for (int t = 0; t < tracks; ++t) CHECK(le_engine_play(e, t) == LE_OK);
  drain(e);
  feed_const(e, 0.0f, GF_LEN, NULL, NULL);
  return e;
}

static double gf_worst_step(const float* out, int n, float before) {
  double worst = fabs((double)out[0] - (double)before);
  for (int i = 1; i < n; ++i) {
    const double d = fabs((double)out[i] - (double)out[i - 1]);
    if (d > worst) worst = d;
  }
  return worst;
}

static const double gf_slope = 0.5 * 2.0 * 3.14159265358979323846 * 100.0 /
                               GF_SR;

/* The gain the k-th frame after a fade-out began carries: the gate steps
 * once on the very frame the command lands. */
static double gf_out_gain(int k) {
  const double g = 1.0 - (double)(k + 1) / GF_F;
  return g > 0.0 ? g : 0.0;
}

/* The repro from the console capture (perf-20261023-015001): a mute, a Stop,
 * the record-mode Stop's mute and Stop on one frame, and Cut, each pressed at
 * the loop's peak. Each one now fades the waveform out over F frames instead
 * of stepping from 0.5 to 0. A Stop keeps reading the loop through its fade
 * even though the transport is held (the only track stopped), so the fade
 * follows the waveform rather than holding a sample. */
static void test_gate_fade_stop_and_mute_at_the_peak(void) {
  printf("test_gate_fade_stop_and_mute_at_the_peak\n");
  for (int how = 0; how < 4; ++how) {
    le_engine* e = gf_fixture(1, 0);
    float out[3 * GF_F];
    int n = 0;
    feed_const(e, 0.0f, 480, NULL, NULL); /* the next read is a peak */
    const float before = gf_x(479);
    if (how == 0) {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
    } else if (how == 1) {
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
    } else if (how == 2) {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
    } else {
      CHECK(le_engine_cut_sound(e) == LE_OK);
    }
    feed_const(e, 0.0f, 3 * GF_F, out, &n);
    const double worst = gf_worst_step(out, n, before);
    printf("  case %d: worst step %.5f (%.2fx the material's slope)\n", how,
           worst, worst / gf_slope);
    CHECK(worst < 1.3 * gf_slope);
    int bad = 0;
    for (int k = 0; k < n; ++k) {
      const double g = how == 2 ? gf_out_gain(k) * gf_out_gain(k)
                                : gf_out_gain(k);
      if (fabs((double)out[k] - gf_x(480 + k) * g) > 1e-5) bad++;
    }
    CHECK(bad == 0);
    for (int k = GF_F; k < n; ++k) CHECK(out[k] == 0.0f);
    le_engine_destroy(e);
  }
}

/* An unmute and a Play fade in. The Play starts from the held transport's
 * loop top, where the take is at its peak: the console's 0.0039 step on
 * every Play, here 0.5. */
static void test_gate_fade_unmute_and_play_fade_in(void) {
  printf("test_gate_fade_unmute_and_play_fade_in\n");
  for (int how = 0; how < 2; ++how) {
    le_engine* e = gf_fixture(1, 0);
    if (how == 0) {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
    } else {
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
    }
    feed_const(e, 0.0f, 480 + 2 * GF_F, NULL, NULL);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int at = (int)s.master_position_frames;
    if (how == 0) {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 0) == LE_OK);
    } else {
      CHECK(at == 0); /* held at the loop top */
      CHECK(le_engine_play(e, 0) == LE_OK);
    }
    float out[3 * GF_F];
    int n = 0;
    feed_const(e, 0.0f, 3 * GF_F, out, &n);
    const double worst = gf_worst_step(out, n, 0.0f);
    printf("  %s: first sample %.5f, worst step %.5f (%.2fx)\n",
           how == 0 ? "unmute" : "play", out[0], worst, worst / gf_slope);
    CHECK(worst < 1.3 * gf_slope);
    int bad = 0;
    for (int k = 0; k < n; ++k) {
      const double g = k + 1 >= GF_F ? 1.0 : (double)(k + 1) / GF_F;
      if (fabs((double)out[k] - gf_x(at + k) * g) > 1e-5) bad++;
    }
    CHECK(bad == 0);
    le_engine_destroy(e);
  }
}

/* Another track's solo fades this one out, and clearing the solo fades it
 * back in. Track 1 is silent, so the output is track 0 alone. */
static void test_gate_fade_solo_in_and_out(void) {
  printf("test_gate_fade_solo_in_and_out\n");
  le_engine* e = gf_fixture(2, 1);
  feed_const(e, 0.0f, 480, NULL, NULL);
  float out[3 * GF_F];
  int n = 0;
  CHECK(le_engine_set_track_solo(e, 1, 1) == LE_OK);
  feed_const(e, 0.0f, 3 * GF_F, out, &n);
  CHECK(gf_worst_step(out, n, gf_x(479)) < 1.3 * gf_slope);
  int bad = 0;
  for (int k = 0; k < n; ++k) {
    if (fabs((double)out[k] - gf_x(480 + k) * gf_out_gain(k)) > 1e-5) bad++;
  }
  CHECK(bad == 0);
  n = 0;
  CHECK(le_engine_set_track_solo(e, 1, 0) == LE_OK);
  feed_const(e, 0.0f, 3 * GF_F, out, &n);
  CHECK(gf_worst_step(out, n, 0.0f) < 1.3 * gf_slope);
  bad = 0;
  for (int k = 0; k < n; ++k) {
    const double g = k + 1 >= GF_F ? 1.0 : (double)(k + 1) / GF_F;
    if (fabs((double)out[k] - gf_x(480 + 3 * GF_F + k) * g) > 1e-5) bad++;
  }
  CHECK(bad == 0);
  le_engine_destroy(e);
}

static void run_gate_fade_tests(void) {
  test_gate_fade_stop_and_mute_at_the_peak();
  test_gate_fade_unmute_and_play_fade_in();
  test_gate_fade_solo_in_and_out();
}
