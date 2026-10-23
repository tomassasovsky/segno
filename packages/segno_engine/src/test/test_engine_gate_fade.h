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
 * and the record-mode Stop's mute and Stop on one frame, each pressed at the
 * loop's peak. Each one now fades the waveform out over F frames instead of
 * stepping from 0.5 to 0. A Stop keeps reading the loop through its fade
 * even though the transport is held (the only track stopped), so the fade
 * follows the waveform rather than holding a sample. */
static void test_gate_fade_stop_and_mute_at_the_peak(void) {
  printf("test_gate_fade_stop_and_mute_at_the_peak\n");
  for (int how = 0; how < 3; ++how) {
    le_engine* e = gf_fixture(1, 0);
    float out[3 * GF_F];
    int n = 0;
    feed_const(e, 0.0f, 480, NULL, NULL); /* the next read is a peak */
    const float before = gf_x(479);
    if (how == 0) {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
    } else if (how == 1) {
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
    } else {
      CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
      CHECK(le_engine_stop_track(e, 0) == LE_OK);
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

/* A lane muted while its track was stopped starts muted at the next Play: no
 * fade-out of a lane nobody heard. */
static void test_gate_fade_mute_while_stopped_stays_silent(void) {
  printf("test_gate_fade_mute_while_stopped_stays_silent\n");
  le_engine* e = gf_fixture(1, 0);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  feed_const(e, 0.0f, 2 * GF_F, NULL, NULL);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  feed_const(e, 0.0f, 64, NULL, NULL);
  CHECK(le_engine_play(e, 0) == LE_OK);
  float out[3 * GF_F];
  int n = 0;
  feed_const(e, 0.0f, 3 * GF_F, out, &n);
  for (int k = 0; k < n; ++k) CHECK(out[k] == 0.0f);
  le_engine_destroy(e);
}

/* Stop pressed while a take is capturing: the take finalizes STOPPED and
 * plays nothing, so there is no fade to run and nothing past the take's own
 * end fades (#730) is read. Its Play later fades in. A finalize into
 * playback starts at full gain: the take continues into its own playback. */
static void test_gate_fade_take_ends_do_not_fade(void) {
  printf("test_gate_fade_take_ends_do_not_fade\n");
  le_engine* e = gf_fixture(2, 1); /* track 1 silent: cleared for a take */
  CHECK(le_engine_clear(e, 1) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  feed_const(e, 0.25f, 2000, NULL, NULL);
  le_track_snapshot snap;
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.state == LE_TRACK_RECORDING);
  CHECK(le_engine_stop_track(e, 1) == LE_OK);
  float out[GF_F];
  int n = 0;
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  const int at = (int)s.master_position_frames;
  feed_const(e, 0.0f, GF_F, out, &n);
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.state == LE_TRACK_STOPPED);
  CHECK(e->trk_play_gain[1] == 0.0f);
  int bad = 0;
  for (int k = 0; k < n; ++k) {
    if (fabs((double)out[k] - gf_x(at + k)) > 1e-6) bad++; /* track 0 alone */
  }
  CHECK(bad == 0);
  le_engine_destroy(e);

  /* The same take finalized by a second record press plays at once. */
  e = gf_fixture(2, 1);
  CHECK(le_engine_clear(e, 1) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  feed_const(e, 0.25f, 2000, NULL, NULL);
  CHECK(le_engine_record(e, 1) == LE_OK);
  feed_const(e, 0.0f, 1, NULL, NULL);
  le_engine_get_track(e, 1, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING || snap.state == LE_TRACK_OVERDUBBING);
  CHECK(e->trk_play_gain[1] == 1.0f);
  le_engine_destroy(e);
}

/* Clear stays an immediate cut: a cleared track's slot is handed back to the
 * control thread at the clear, so the callback must not read it on. */
static void test_gate_fade_clear_cuts_at_once(void) {
  printf("test_gate_fade_clear_cuts_at_once\n");
  le_engine* e = gf_fixture(1, 0);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  float out[GF_F];
  int n = 0;
  feed_const(e, 0.0f, GF_F, out, &n);
  for (int k = 0; k < n; ++k) CHECK(out[k] == 0.0f);
  CHECK(e->trk_play_gain[0] == 0.0f);
  le_engine_destroy(e);
}

/* A Stop and a Play inside one block, and a Play inside the Stop's fade:
 * the gain turns around where it is, so neither press steps the output by
 * more than the gain it had reached times the jump in the read. */
static void test_gate_fade_stop_then_play_inside_the_fade(void) {
  printf("test_gate_fade_stop_then_play_inside_the_fade\n");
  le_engine* e = gf_fixture(1, 0);
  feed_const(e, 0.0f, 480, NULL, NULL);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  float out[GF_F + 200];
  int n = 0;
  feed_const(e, 0.0f, 100, out, &n);
  const float g_at = e->trk_tail_gain[0];
  CHECK(e->trk_play_gain[0] == 0.0f && g_at > 0.75f && g_at < 0.8f);
  CHECK(le_engine_play(e, 0) == LE_OK);
  feed_const(e, 0.0f, GF_F + 100, out, &n);
  /* The Play reads from the held loop top while the tail reads on from
   * where the Stop left it: the two cross, so no frame steps by more than
   * the waveform's own slope plus the two fades' steps. */
  const double worst = gf_worst_step(out, n, gf_x(479));
  printf("  worst step %.5f (%.2fx)\n", worst, worst / gf_slope);
  CHECK(worst < 1.3 * gf_slope);
  CHECK(e->trk_play_gain[0] == 1.0f && e->trk_tail_gain[0] == 0.0f);
  le_engine_destroy(e);
}

/* The export fades where the performer heard a fade: mutes, an unmute and a
 * solo replayed by perf_render match the live callback sample for sample. */
static void test_gate_fade_render_matches_live_mute_and_solo(void) {
  printf("test_gate_fade_render_matches_live_mute_and_solo\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("gate-fade-mute");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  static float live[4000], replay[4000];
  rev_process(e, live, 37, 512);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  rev_process(e, live + 37, 600, 512);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 0) == LE_OK);
  rev_process(e, live + 637, 600, 512);
  CHECK(le_engine_set_track_solo(e, 1, 1) == LE_OK);
  rev_process(e, live + 1237, 600, 512);
  CHECK(le_engine_set_track_solo(e, 1, 0) == LE_OK);
  rev_process(e, live + 1837, 600, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  /* The live fades themselves: 37 -> 0 over F frames, then back. */
  CHECK(fabsf(live[37] - 37.0f * (1.0f - 1.0f / 480.0f)) < 1e-3f);
  CHECK(live[37 + 480] == 0.0f);
  CHECK(fabsf(live[637] - 637.0f / 480.0f) < 1e-3f);
  CHECK(live[637 + 480] == (float)((637 + 480) % len));
  rev_render_track_wav(e, dir, len);
  const int frames = test_read_wet_stem(dir, 0, replay, 4000);
  CHECK(frames == 2437);
  int bad = 0;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) > 1e-3f) bad++;
  }
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* A Stop and a Play of an image source (322/323, here a Clear Undo) replay
 * in the dry stem with the callback's fades: the Stop's fade-out reads the
 * image on past the stop, and the Play fades in. */
static void test_gate_fade_render_matches_live_stop_and_play(void) {
  printf("test_gate_fade_render_matches_live_stop_and_play\n");
  const int len = 1000;
  le_engine* e = reverse_fixture(48000, len, len);
  const char* dir = render_test_dir("gate-fade-stop");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  static float live[4000], replay[4000];
  rev_process(e, live, 64, 512);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, live + 64, 64, 512);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  rev_process(e, live + 128, 900, 512);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  rev_process(e, live + 1028, 700, 512);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, live + 1728, 700, 512);
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(live[1028] != 0.0f && live[1028 + 480] == 0.0f);
  /* The Play reads the held loop top: index 1, the second frame, at 2/F. */
  CHECK(live[1728] == 0.0f && fabsf(live[1729] - 2.0f / 480.0f) < 1e-6f);
  rev_render_track_wav(e, dir, len);
  const int frames = test_read_stem(dir, 0, replay, 4000);
  CHECK(frames == 2428);
  int bad = 0;
  for (int i = 0; i < frames; ++i) {
    if (fabsf(replay[i] - live[i]) > 1e-3f) bad++;
  }
  if (bad) {
    for (int i = 0; i < frames && bad > 0; ++i) {
      if (fabsf(replay[i] - live[i]) > 1e-3f) {
        printf("  first mismatch at %d: live %.4f replay %.4f\n", i, live[i],
               replay[i]);
        break;
      }
    }
  }
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* Cut all sound stays a cut: it silences at once rather than fading, so no
 * Stop fade-out feeds the chains whose tails it clears. A Post delay on the
 * lane does not ring after it. */
static void test_gate_fade_cut_silences_at_once(void) {
  printf("test_gate_fade_cut_silences_at_once\n");
  for (int post = 0; post < 2; ++post) {
    le_engine* e = gf_fixture(1, 0);
    if (post) {
      CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
      CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
      CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0,
                                        2400.0f / (float)(GF_SR - 1)) ==
            LE_OK);
      feed_const(e, 0.0f, GF_SR, NULL, NULL);
    }
    feed_const(e, 0.0f, 480, NULL, NULL);
    CHECK(le_engine_cut_sound(e) == LE_OK);
    static float out[GF_SR];
    int n = 0;
    feed_const(e, 0.0f, GF_SR / 2, out, &n);
    int loud = 0;
    for (int k = 0; k < n; ++k) loud += out[k] != 0.0f;
    CHECK(loud == 0);
    CHECK(e->trk_play_gain[0] == 0.0f && e->trk_tail_gain[0] == 0.0f);
    le_engine_destroy(e);
  }
}

/* Stop, Play and Stop again inside one fade: the second Stop keeps the
 * louder of the playing read and the first tail, so the one it drops is the
 * quieter. */
static void test_gate_fade_second_stop_keeps_the_louder_voice(void) {
  printf("test_gate_fade_second_stop_keeps_the_louder_voice\n");
  le_engine* e = gf_fixture(1, 0);
  feed_const(e, 0.0f, 480, NULL, NULL);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  feed_const(e, 0.0f, 100, NULL, NULL);
  CHECK(le_engine_play(e, 0) == LE_OK);
  feed_const(e, 0.0f, 100, NULL, NULL);
  const float tail = e->trk_tail_gain[0], head = e->trk_play_gain[0];
  CHECK(tail > head && head > 0.0f);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  feed_const(e, 0.0f, 1, NULL, NULL);
  /* The first tail kept fading; the playing read was dropped. */
  CHECK(fabsf(e->trk_tail_gain[0] - (tail - 1.0f / GF_F)) < 1e-6f);
  CHECK(e->trk_play_gain[0] == 0.0f);
  le_engine_destroy(e);
}

static void run_gate_fade_tests(void) {
  test_gate_fade_cut_silences_at_once();
  test_gate_fade_second_stop_keeps_the_louder_voice();
  test_gate_fade_stop_and_mute_at_the_peak();
  test_gate_fade_unmute_and_play_fade_in();
  test_gate_fade_solo_in_and_out();
  test_gate_fade_mute_while_stopped_stays_silent();
  test_gate_fade_take_ends_do_not_fade();
  test_gate_fade_clear_cuts_at_once();
  test_gate_fade_stop_then_play_inside_the_fade();
  test_gate_fade_render_matches_live_mute_and_solo();
  test_gate_fade_render_matches_live_stop_and_play();
}
