/* The chains' musical time and the beat-locked kinds (#887 part 10).
 * Included by test_engine_core.c after the rack-path tests. */

#define RH_SR 48000

/* A 120 BPM, 4/4 tempo with beat 0 at clock 0. */
static le_fx_tempo rh_tempo(double bpm) {
  le_fx_tempo t;
  memset(&t, 0, sizeof(t));
  t.qpf = (float)(bpm / 60.0 / (double)RH_SR);
  t.num = 4;
  t.den = 4;
  return t;
}

/* A one-slot Pumper state on [tempo], its depth settled. */
static le_fx_state* rh_pumper(const le_fx_tempo* tempo, const float* p) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  le_fx_entry_reset(fx, 0);
  fx->tempo = tempo;
  fx->clocked = 1;
  le_fx_pumper_seed_settled(fx, 0, p, RH_SR);
  return fx;
}

/* The Pumper's gain on a constant 1 for [n] frames from clock 0. */
static void rh_pump_run(le_fx_state* fx, const float* p4, float* gain, int n) {
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_PUMPER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p4[q];
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = 1.0f;
    float r = 1.0f;
    fx_apply_chain(fx, RH_SR, RH_SR, &l, &r, 1, types, params, NULL);
    gain[i] = l;
  }
}

/* The measured e(phase) (#891), linear between its 1/20 points. */
static float rh_shape(double phase) {
  static const float e[16] = {1.000f, 0.994f, 0.984f, 0.970f, 0.948f, 0.918f,
                              0.876f, 0.820f, 0.746f, 0.654f, 0.544f, 0.418f,
                              0.284f, 0.153f, 0.045f, 0.0f};
  const double x = phase * 20.0;
  if (x >= 15.0) return 0.0f;
  const int i = (int)x;
  return e[i] + (e[i + 1] - e[i]) * (float)(x - (double)i);
}

/* The setting of rate position [pos] (of 11). */
static float rh_rate(int pos) { return (float)pos / 10.0f; }

/* The measured shape (#891): at 1/4, 120 BPM and 70 %, the gain is
 * 1 - 0.901 e(phase) every 1/20 of the 500 ms period, at full depth 1 ms
 * after the beat (the onset ramp), and 1 from three quarters on. */
static void test_pumper_matches_the_capture(void) {
  printf("test_pumper_matches_the_capture\n");
  static const float e[16] = {1.000f, 0.994f, 0.984f, 0.970f, 0.948f, 0.918f,
                              0.876f, 0.820f, 0.746f, 0.654f, 0.544f, 0.418f,
                              0.284f, 0.153f, 0.045f, 0.0f};
  const le_fx_tempo t = rh_tempo(120.0);
  const float p[LE_FX_PARAMS] = {rh_rate(3), 0.7f};
  le_fx_state* fx = rh_pumper(&t, p);
  const int n = RH_SR; /* two periods */
  float* g = (float*)malloc(sizeof(float) * (size_t)n);
  rh_pump_run(fx, p, g, n);
  const int period = RH_SR / 2;
  const float a = 0.901f;
  for (int k = 1; k < 16; ++k) {
    const int at = period + k * period / 20;
    CHECK(fabsf(g[at] - (1.0f - a * e[k])) < 2e-3f);
  }
  const int ms = RH_SR / 1000;
  const float dip = 20.0f * log10f(g[period + 2 * ms]);
  printf("  dip 2 ms after the beat: %.2f dB (capture -20.1)\n", dip);
  CHECK(fabsf(dip - -20.09f) < 0.1f);
  CHECK(fabsf(g[period + period * 4 / 5] - 1.0f) < 1e-6f);
  /* The duck is smoothed (0.25 ms): no sample steps by more than its share
   * of the depth, on the beat or anywhere. */
  const float k = 1.0f / (1.0f + 0.00025f * (float)RH_SR);
  for (int i = 1; i < n; ++i) {
    CHECK(fabsf(g[i] - g[i - 1]) <= a * k * 1.01f + 1e-6f);
  }
  free(g);
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* Each rate is its note value at the tempo (#891: Bar 2000 ms, 1/2 1000,
 * 1/4 500, 1/8 250, 1/16 125 at 120 BPM), the triplets two thirds of
 * theirs; and the depth's dip is 6, 20 and 40 dB at 30, 70 and 100 %. */
static void test_pumper_rates_and_depths(void) {
  printf("test_pumper_rates_and_depths\n");
  const le_fx_tempo t = rh_tempo(120.0);
  const double quarter = (double)RH_SR / 2.0;
  static const double quarters[11] = {4.0,       2.0,  4.0 / 3.0, 1.0,
                                      2.0 / 3.0, 0.5,  1.0 / 3.0, 0.25,
                                      1.0 / 6.0, 0.125, 1.0 / 12.0};
  const int n = 4 * RH_SR + 16;
  float* g = (float*)malloc(sizeof(float) * (size_t)n);
  for (int pos = 0; pos < 11; ++pos) {
    const float p[LE_FX_PARAMS] = {rh_rate(pos), 1.0f};
    le_fx_state* fx = rh_pumper(&t, p);
    rh_pump_run(fx, p, g, n);
    const double frames = quarters[pos] * quarter;
    /* 1 ms into the second period the duck is the shape at that phase, at
     * 100 % depth (a = 0.99)... */
    const int at = (int)ceil(frames) + 2 * RH_SR / 1000 + 1;
    const double phase = ((double)at - frames) / frames;
    CHECK(fabsf(g[at] - (1.0f - 0.99f * rh_shape(phase))) < 2e-3f);
    /* ...and it has recovered at 80 % of the first. */
    CHECK(g[(int)(frames * 0.8)] > 0.999f);
    le_fx_state_free_buffers(fx);
    free(fx);
  }
  static const float depth[3] = {0.3f, 0.7f, 1.0f};
  static const float want_db[3] = {-6.02f, -20.09f, -40.0f};
  for (int d = 0; d < 3; ++d) {
    const float p[LE_FX_PARAMS] = {rh_rate(3), depth[d]};
    le_fx_state* fx = rh_pumper(&t, p);
    rh_pump_run(fx, p, g, RH_SR / 100);
    /* The dip, taken back to the beat: the gain over the shape there. */
    const int at = 2 * RH_SR / 1000 + 1;
    const float a = (1.0f - g[at]) / rh_shape((double)at / quarter);
    const float db = 20.0f * log10f(1.0f - a);
    printf("  depth %.0f %%: %.2f dB (want %.2f)\n", 100.0 * depth[d], db, want_db[d]);
    /* The smoothing trails the falling shape by a hair: 0.3 dB of a 40 dB
     * dip is 3e-4 of the gain. */
    CHECK(fabsf(db - want_db[d]) < 0.3f);
    le_fx_state_free_buffers(fx);
    free(fx);
  }
  free(g);
}

/* A live input's Pumper ducks once a beat at the song tempo, and at 120 BPM
 * while no tempo is set. */
static void rh_live_period(float bpm, int expect_frames) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, RH_SR, 1, 1, 512);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  if (bpm > 0.0f) CHECK(le_engine_set_tempo(e, bpm) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_PUMPER) == LE_OK);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, rh_rate(3));
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  const int n = 3 * RH_SR;
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  float in[512];
  for (int i = 0; i < 512; ++i) in[i] = 0.5f;
  for (int at = 0; at < n; at += 512) {
    le_engine_process(e, out + at, in, (uint32_t)(n - at < 512 ? n - at : 512));
  }
  /* The ducks: where the output falls through -30 dB of the input. */
  int last = -1;
  int gaps = 0;
  for (int i = RH_SR / 4; i < n; ++i) {
    const int deep = fabsf(out[i]) < 0.5f * 0.0316f;
    const int was = fabsf(out[i - 1]) < 0.5f * 0.0316f;
    if (deep && !was) {
      if (last >= 0) {
        CHECK(abs(i - last - expect_frames) <= 2);
        gaps++;
      }
      last = i;
    }
  }
  CHECK(gaps >= 2);
  free(out);
  le_engine_destroy(e);
}

static void test_pumper_follows_the_song_tempo(void) {
  printf("test_pumper_follows_the_song_tempo\n");
  rh_live_period(90.0f, RH_SR * 60 / 90);
  rh_live_period(0.0f, RH_SR / 2); /* none set: 120 BPM */
}

/* The engine's beat line: anchored where the log says, it is the very sum
 * the live chains read at every block end, through a tempo change. */
static void test_fx_tempo_log_reproduces_the_beat(void) {
  printf("test_fx_tempo_log_reproduces_the_beat\n");
  le_engine* e = make_configured_engine();
  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  remove(path);
  CHECK(le_engine_set_tempo(e, 100.0f) == LE_OK);
  CHECK(perf_arm_dir(e, perf_test_dir()) == LE_OK);
  drain(e);
  float out[64];
  double live[40];
  uint64_t at_frame[40];
  uint64_t frames = 0;
  for (int b = 0; b < 40; ++b) {
    if (b == 20) CHECK(le_engine_set_tempo(e, 140.0f) == LE_OK);
    process_const(e, 0.0f, 64, out);
    frames += 64;
    /* The beat of the block's last frame, as the chains read it. */
    const le_fx_tempo* t = &e->fx_tempo;
    const uint32_t clock = e->fx_clock_base + 63u;
    live[b] = t->anchor_beat +
              (double)(uint32_t)(clock - t->anchor_clock) * (double)t->qpf;
    at_frame[b] = frames - 1;
  }
  CHECK(le_perf_disarm(e) == LE_OK);
  static unsigned char buf[65536];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  const size_t count = log_entry_count(n);
  le_perf_log_entry anchors[16];
  int na = 0;
  le_perf_log_entry entry;
  int from = 0;
  while ((from = find_log_entry(buf, count, from, LE_PLOG_FX_TEMPO,
                                &entry)) >= 0 &&
         na < 16) {
    anchors[na++] = entry;
    from++;
  }
  printf("  %d anchors\n", na);
  CHECK(na == 2); /* the arm, and the tempo change: no more */
  /* The perf frames start at the arm: the block ends are the live frames
   * the arm's block saw first, plus the frames since. */
  const uint64_t base = anchors[0].frame;
  for (int b = 0; b < 40; ++b) {
    const uint64_t f = base + at_frame[b];
    int k = -1;
    for (int i = 0; i < na; ++i)
      if (anchors[i].frame <= f) k = i;
    CHECK(k >= 0);
    if (k < 0) continue;
    const uint64_t bits =
        (uint64_t)anchors[k].cmd.fx_tempo_log.beat_lo |
        ((uint64_t)anchors[k].cmd.fx_tempo_log.beat_hi << 32);
    double beat;
    memcpy(&beat, &bits, sizeof(beat));
    beat += (double)(uint32_t)(f - anchors[k].frame) *
            (double)anchors[k].cmd.fx_tempo_log.qpf;
    CHECK(beat == live[b]);
  }
  le_engine_destroy(e);
}

/* A lane holding a Pumper that ducks is never printed: it is locked to the
 * beat, not the lap. */
static void test_pumper_lane_is_not_printed(void) {
  printf("test_pumper_lane_is_not_printed\n");
  CHECK(le_fx_type_free_running(LE_FX_PUMPER));
  const float on[LE_FX_PARAMS] = {rh_rate(3), 0.5f};
  const float off[LE_FX_PARAMS] = {rh_rate(3), 0.0f};
  CHECK(le_fx_entry_free_running(LE_FX_PUMPER, on, RH_SR));
  CHECK(!le_fx_entry_free_running(LE_FX_PUMPER, off, RH_SR));
}

/* An FX_TEMPO event at [frame]: [beat] from there at [bpm] in 4/4. */
static le_command rh_anchor(double beat, double bpm) {
  uint64_t bits;
  memcpy(&bits, &beat, sizeof(bits));
  le_command c;
  memset(&c, 0, sizeof(c));
  c.code = LE_PLOG_FX_TEMPO;
  c.fx_tempo_log.beat_lo = (uint32_t)bits;
  c.fx_tempo_log.beat_hi = (uint32_t)(bits >> 32);
  c.fx_tempo_log.qpf = (float)(bpm / 60.0 / (double)RH_SR);
  c.fx_tempo_log.num = 4;
  c.fx_tempo_log.den = 4;
  return c;
}

/* The performance render replays the logged anchors: a lane's Pumper over
 * a tempo change renders the gain the anchors give, frame for frame. */
static void test_pumper_renders_from_the_logged_anchors(void) {
  printf("test_pumper_renders_from_the_logged_anchors\n");
  const char* dir = render_test_dir("pumper-anchors");
  const int32_t frames = RH_SR / 2;
  const int32_t change = RH_SR / 10;
  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  float base[64];
  for (int i = 0; i < 64; ++i) base[i] = 0.5f;
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, 64, RH_SR);
  char manifest[4096];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %d, "
           "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": 1, "
           "\"masterGain\": 1.0, \"limiterOn\": false, "
           "\"limiterCeiling\": 0.99, \"tracks\": [{\"channel\": 1, "
           "\"volume\": 1.0, \"muted\": false, \"lanes\": [{\"lane\": 0, "
           "\"deferred\": false, \"pcmRef\": \"loops/track1-lane0.wav\", "
           "\"effects\": [{\"type\": %d, \"params\": [%f, 1.0]}]}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
           RH_SR, frames, LE_FX_PUMPER, (double)rh_rate(5));
  test_write_manifest(dir, manifest);
  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, RH_SR, LE_TEST_EVENTS_VERSION);
    test_write_log_entry(lf, 0, rh_anchor(0.3, 100.0));
    test_write_log_entry(lf, (uint64_t)change, rh_anchor(1.7, 150.0));
    fclose(lf);
  }
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  float* wet = (float*)malloc(sizeof(float) * (size_t)frames);
  CHECK(test_read_wet_stem(dir, 1, wet, frames) == frames);
  le_engine_destroy(e);

  /* The same anchors, by hand. */
  le_fx_tempo t = rh_tempo(100.0);
  t.anchor_beat = 0.3;
  const float p[LE_FX_PARAMS] = {rh_rate(5), 1.0f};
  le_fx_state* fx = rh_pumper(&t, p);
  float* g = (float*)malloc(sizeof(float) * (size_t)frames);
  rh_pump_run(fx, p, g, change);
  t = rh_tempo(150.0);
  t.anchor_clock = (uint32_t)change;
  t.anchor_beat = 1.7;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int k = 0; k < LE_FX_MAX; ++k) types[k] = LE_FX_NONE;
  types[0] = LE_FX_PUMPER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p[q];
  for (int i = change; i < frames; ++i) {
    fx->clock = (uint32_t)i;
    float l = 1.0f;
    float r = 1.0f;
    fx_apply_chain(fx, RH_SR, RH_SR, &l, &r, 1, types, params, NULL);
    g[i] = l;
  }
  float worst = 0.0f;
  for (int i = 0; i < frames; ++i) {
    const float d = fabsf(wet[i] - 0.5f * g[i]);
    if (d > worst) worst = d;
  }
  printf("  render against the anchors: %.2e\n", (double)worst);
  CHECK(worst < 1e-6f);
  free(g);
  free(wet);
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* The beat restarts at the loop top: while a loop plays it is the
 * position times the rate, every block, through every wrap; and a held
 * transport (the loop stopped) leaves the beat on its line with no new
 * anchor, frame after frame. */
static void test_fx_beat_follows_the_loop(void) {
  printf("test_fx_beat_follows_the_loop\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, RH_SR, 1, 1, 1000);
  float out[64];
  float in[64];
  for (int i = 0; i < 64; ++i) in[i] = 0.25f;
  le_engine_record(e, 0);
  for (int f = 0; f < 4800; f += 64) le_engine_process(e, out, in, 64);
  le_engine_record(e, 0);
  drain(e);
  CHECK(e->clock.length > 0);
  int checked = 0;
  for (int b = 0; b < 400; ++b) {
    le_engine_process(e, out, in, 64);
    if (e->clock.length <= 0 || e->transport_held) continue;
    const le_fx_tempo* t = &e->fx_tempo;
    /* The clock of the frame the position stands for: the next one. */
    const uint32_t clock = e->fx_clock_base + 64u;
    const double beat = t->anchor_beat + (double)(uint32_t)(clock -
                                                            t->anchor_clock) *
                                             (double)t->qpf;
    CHECK(fabs(beat - (double)e->clock.position * (double)t->qpf) < 1e-9);
    checked++;
  }
  CHECK(checked > 300);
  /* Stopped: the transport holds at the top; the beat runs on. */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  for (int b = 0; b < 4; ++b) le_engine_process(e, out, in, 64);
  CHECK(e->transport_held);
  const uint32_t anchored = e->fx_tempo.anchor_clock;
  for (int b = 0; b < 50; ++b) le_engine_process(e, out, in, 64);
  CHECK(e->fx_tempo.anchor_clock == anchored);
  /* Played again: back on the loop's line from the top. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  int resumed = 0;
  for (int b = 0; b < 100; ++b) {
    le_engine_process(e, out, in, 64);
    if (e->transport_held) continue;
    const le_fx_tempo* t = &e->fx_tempo;
    const uint32_t clock = e->fx_clock_base + 64u;
    const double beat = t->anchor_beat + (double)(uint32_t)(clock -
                                                            t->anchor_clock) *
                                             (double)t->qpf;
    CHECK(fabs(beat - (double)e->clock.position * (double)t->qpf) < 1e-9);
    resumed++;
  }
  CHECK(resumed > 50);
  le_engine_destroy(e);
}

/* A Bar is the time signature's: three quarters in 3/4. */
static void test_pumper_bar_follows_the_signature(void) {
  printf("test_pumper_bar_follows_the_signature\n");
  le_fx_tempo t = rh_tempo(120.0);
  t.num = 3;
  const float p[LE_FX_PARAMS] = {rh_rate(0), 1.0f};
  le_fx_state* fx = rh_pumper(&t, p);
  const int n = 2 * RH_SR;
  float* g = (float*)malloc(sizeof(float) * (size_t)n);
  rh_pump_run(fx, p, g, n);
  const int bar = 3 * RH_SR / 2; /* three quarters at 120 BPM */
  CHECK(g[bar * 4 / 5] > 0.999f);
  CHECK(20.0f * log10f(g[bar + 2 * RH_SR / 1000]) < -39.0f);
  free(g);
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* ---- The Rhythmic LPF's LFO ---- */

/* The capture's level of a -12 dBFS 1 kHz sine through the Rhythmic LPF at
 * 632 Hz and 50 % resonance, its LFO at rate 2 (a half note, 1 s at
 * 120 BPM), at every 1/40 of the LFO's period from its start (#891, gD
 * passes 3 and 4: Depth 50 % and 100 %), in dB against the input. */
static const float RH_LFO_50[40] = {
    -12.0f, -6.7f,  -2.3f,  1.1f,   3.1f,   3.9f,   4.1f,   3.9f,
    3.7f,   3.5f,   3.4f,   3.5f,   3.7f,   3.9f,   4.1f,   3.9f,
    3.2f,   1.3f,   -2.1f,  -6.6f,  -11.8f, -17.2f, -22.2f, -26.7f,
    -30.8f, -34.3f, -37.2f, -39.5f, -41.2f, -42.2f, -42.5f, -42.2f,
    -41.2f, -39.6f, -37.3f, -34.4f, -30.9f, -26.9f, -22.4f, -17.4f};
static const float RH_LFO_100[40] = {
    -12.0f, 3.8f,  1.4f,   0.4f,   0.1f,   0.0f,   0.0f,   0.0f,
    0.0f,   0.0f,  0.0f,   0.0f,   0.0f,   0.0f,   0.0f,   0.0f,
    0.1f,   0.4f,  1.4f,   3.8f,   -11.2f, -33.8f, -56.2f, -74.1f,
    -84.0f, -90.0f, -94.9f, -99.1f, -86.2f, -75.3f, -93.8f, -82.0f,
    -98.9f, -87.1f, -90.0f, -89.3f, -87.7f, -76.1f, -57.0f, -34.6f};

/* The LPF's level of that sine (632 Hz, 50 % resonance) at each 1/40 of
 * the LFO's period, at Depth [depth] and rate position [rate] (of 16),
 * whose period is [period] frames at 120 BPM. The beat runs from clock 0,
 * so a period starts at frame 0; read over the period from frame 2 s, as
 * the capture's +-4 ms bins. */
static void rh_lfo_levels(float depth, int rate, int period, float* db) {
  const int sr = RH_SR;
  const int n = 2 * sr + period;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    in[i] = 0.2512f * sinf(2.0f * 3.14159265f * 1000.0f * (float)i / sr);
  }
  float p[LE_FX_PARAMS] = {0};
  p[0] = dyn_setting(LE_FX_LPF, 0, 632.0);
  p[1] = 0.5f;
  p[2] = depth;
  p[3] = (float)rate / 15.0f;
  le_fx_state* fx = dyn_state(LE_FX_LPF, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_LPF, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  const int w = sr / 250;
  for (int k = 0; k < 40; ++k) {
    const int at = 2 * sr + k * period / 40;
    double e = 0.0;
    int m = 0;
    for (int i = at - w; i < at + w; ++i) {
      const int j = i < 2 * sr ? i + period : i; /* within the period */
      e += (double)out[j] * out[j];
      ++m;
    }
    db[k] = (float)(10.0 * log10(2.0 * e / m + 1e-30) - 20.0 * log10(0.2512));
  }
  free(in);
  free(out);
}

/* The LFO sweeps the cutoff as the capture's does: a sine in log
 * frequency rising from the start of each period, over the whole cycle
 * within 2 dB at Depth 50 % and 1.5 dB at 100 % (where the capture is
 * above -50 dB; below it, the model is too). */
static void test_lpf_lfo_matches_the_capture(void) {
  printf("test_lpf_lfo_matches_the_capture\n");
  float db[40];
  rh_lfo_levels(0.5f, 6, RH_SR, db); /* 2: a half note, 1 s */
  double worst = 0.0;
  for (int k = 0; k < 40; ++k) {
    const double d = fabs((double)db[k] - RH_LFO_50[k]);
    if (d > worst) worst = d;
  }
  printf("  depth 50 %%: worst %.2f dB off the capture\n", worst);
  CHECK(worst < 2.0);
  rh_lfo_levels(1.0f, 6, RH_SR, db);
  worst = 0.0;
  for (int k = 0; k < 40; ++k) {
    if (RH_LFO_100[k] < -50.0f) {
      CHECK(db[k] < -50.0f);
      continue;
    }
    const double d = fabs((double)db[k] - RH_LFO_100[k]);
    if (d > worst) worst = d;
  }
  printf("  depth 100 %%: worst %.2f dB off the capture above -50 dB\n", worst);
  CHECK(worst < 1.5);
}

/* The rate is a note value: at 4 (a quarter, 500 ms at 120 BPM) the same
 * cycle runs in half the time. */
static void test_lpf_lfo_rate(void) {
  printf("test_lpf_lfo_rate\n");
  float db[40];
  rh_lfo_levels(0.5f, 9, RH_SR / 2, db);
  CHECK(db[10] > 2.0f);   /* the cutoff at its top: the resonance's lift */
  CHECK(db[30] < -35.0f); /* at its bottom */
  CHECK(fabsf(db[10] - db[30]) > 35.0f);
}

/* A swept filter is locked to the beat, so its lane is never printed; one
 * with its LFO at 0, or switched off at the top of the cutoff, still is. */
static void test_lpf_lfo_is_not_printed(void) {
  printf("test_lpf_lfo_is_not_printed\n");
  float p[LE_FX_PARAMS] = {0.5f, 0.2f, 0.5f, 0.4f};
  CHECK(le_fx_entry_free_running(LE_FX_LPF, p, RH_SR));
  p[2] = 0.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_LPF, p, RH_SR));
  p[2] = 0.5f;
  p[0] = 1.0f;
  CHECK(!le_fx_entry_free_running(LE_FX_LPF, p, RH_SR));
}

/* The LPF's output on a 750 Hz sine (64-frame period) at the Sliced
 * Breaker's settings (cutoff 0.64, 25 % resonance, LFO 44 % at 1/8D) on
 * [t], re-anchored at frame [at] to beat [to] (no re-anchor when at < 0). */
static void rh_lfo_run_p(le_fx_tempo* t, int at, double to, float* out, int n,
                         const float* p, uint32_t off) {
  le_fx_state* fx = dyn_state(LE_FX_LPF, RH_SR);
  fx->tempo = t;
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int k = 0; k < LE_FX_MAX; ++k) types[k] = LE_FX_NONE;
  types[0] = LE_FX_LPF;
  for (int q = 0; q < 4; ++q) params[0][q] = p[q];
  for (int i = 0; i < n; ++i) {
    if (i == at) {
      t->anchor_clock = (uint32_t)i + off;
      t->anchor_beat = to;
    }
    fx->clock = (uint32_t)i + off;
    float l = 0.5f * sinf(2.0f * 3.14159265f * (float)(i % 64) / 64.0f);
    float r = l;
    fx_apply_chain(fx, RH_SR, RH_SR, &l, &r, 1, types, params, NULL);
    out[i] = l;
  }
  dyn_free(fx);
}

static void rh_lfo_run(le_fx_tempo* t, int at, double to, float* out, int n) {
  const float p[4] = {0.6415f, 0.254f, 0.44f, 10.0f / 15.0f};
  rh_lfo_run_p(t, at, to, out, n, p, 0);
}

/* The fastest sweep (1/16 at 240 BPM, Depth 100 %) moves the corner sample
 * by sample, not in steps at the update cadence: the output's curvature
 * stays under twice the sine's own at a +3 dB lift (stepping the corner
 * every 32 frames bends it about three times as hard). */
static void test_lpf_lfo_fast_sweep_is_smooth(void) {
  printf("test_lpf_lfo_fast_sweep_is_smooth\n");
  const int n = RH_SR / 2;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  le_fx_tempo t = rh_tempo(240.0);
  const float p[4] = {0.6415f, 0.254f, 1.0f, 1.0f};
  rh_lfo_run_p(&t, -1, 0.0, y, n, p, 0);
  float bend = 0.0f;
  for (int i = RH_SR / 10; i < n; ++i) {
    bend = fmaxf(bend, fabsf(y[i] - 2.0f * y[i - 1] + y[i - 2]));
  }
  const float w = 2.0f * 3.14159265f / 64.0f;
  printf("  sharpest bend %.5f, the sine's own at +3 dB %.5f\n", (double)bend,
         (double)(0.5f * 1.41f * w * w));
  CHECK(bend < 2.0f * 0.5f * 1.41f * w * w);
  free(y);
}

/* A loop top that is not a whole number of LFO periods (a one-bar loop at
 * 1/8D: the phase goes from 1/3 back to 0, about an octave of the corner)
 * moves the corner over a millisecond or so, not in one sample: the
 * output's curvature (its second difference, which a step in the corner
 * would spike) stays within the swept filter's own. */
static void test_lpf_lfo_reanchor_is_smooth(void) {
  printf("test_lpf_lfo_reanchor_is_smooth\n");
  const int bar = 2 * RH_SR; /* 4/4 at 120 BPM */
  const int n = bar + RH_SR / 4;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  le_fx_tempo t = rh_tempo(120.0);
  rh_lfo_run(&t, bar, 0.0, y, n);
  float steady = 0.0f;
  for (int i = RH_SR / 2; i < bar; ++i) {
    steady = fmaxf(steady, fabsf(y[i] - 2.0f * y[i - 1] + y[i - 2]));
  }
  float jump = 0.0f;
  for (int i = bar; i < bar + RH_SR / 100; ++i) {
    jump = fmaxf(jump, fabsf(y[i] - 2.0f * y[i - 1] + y[i - 2]));
  }
  printf("  sharpest bend: %.5f across the loop top, %.5f before\n",
         (double)jump, (double)steady);
  CHECK(jump < 1.5f * steady);
  free(y);
}

/* The LFO reads the beat from the tempo, not from its state's clock: the
 * same anchors on a clock 32 x 1000 frames later (the same update phase)
 * give the same output, sample for sample. */
static void test_lpf_lfo_follows_the_tempo_not_the_clock(void) {
  printf("test_lpf_lfo_follows_the_tempo_not_the_clock\n");
  const int n = RH_SR;
  float* a = (float*)malloc(sizeof(float) * (size_t)n);
  float* b = (float*)malloc(sizeof(float) * (size_t)n);
  const float p[4] = {0.6415f, 0.254f, 0.44f, 10.0f / 15.0f};
  le_fx_tempo t1 = rh_tempo(97.0);
  t1.anchor_beat = 0.3;
  rh_lfo_run_p(&t1, n / 3, 1.75, a, n, p, 0);
  const uint32_t off = 32u * 1000u;
  le_fx_tempo t2 = rh_tempo(97.0);
  t2.anchor_clock = off;
  t2.anchor_beat = 0.3;
  rh_lfo_run_p(&t2, n / 3, 1.75, b, n, p, off);
  for (int i = 0; i < n; ++i) CHECK(a[i] == b[i]);
  free(a);
  free(b);
}

/* A jump across the whole swing (Depth 100 %, from the top of the cycle to
 * the bottom: about 14 octaves of corner) takes milliseconds, at the slew
 * limit, not the 32 frames of one update: a 1 kHz tone takes over 2 ms to
 * fall 20 dB (about 4; half a millisecond without the limit). */
static void test_lpf_lfo_jump_is_slewed(void) {
  printf("test_lpf_lfo_jump_is_slewed\n");
  const int n = 2 * RH_SR;
  const int at = RH_SR + RH_SR / 4; /* phase 0.25 of the 1 s period */
  le_fx_state* fx = dyn_state(LE_FX_LPF, RH_SR);
  le_fx_tempo t = rh_tempo(120.0);
  fx->tempo = &t;
  fx->clocked = 1;
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int k = 0; k < LE_FX_MAX; ++k) types[k] = LE_FX_NONE;
  types[0] = LE_FX_LPF;
  params[0][0] = dyn_setting(LE_FX_LPF, 0, 632.0);
  params[0][1] = 0.5f;
  params[0][2] = 1.0f;
  params[0][3] = 6.0f / 15.0f;
  float* y = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) {
    if (i == at) {
      t.anchor_clock = (uint32_t)i;
      t.anchor_beat = 1.5; /* phase 0.75 */
    }
    fx->clock = (uint32_t)i;
    float l = 0.2512f * sinf(2.0f * 3.14159265f * 1000.0f * (float)i / RH_SR);
    float r = l;
    fx_apply_chain(fx, RH_SR, RH_SR, &l, &r, 1, types, params, NULL);
    y[i] = l;
  }
  dyn_free(fx);
  /* The tone's own level over each cycle (its in-phase and quadrature
   * parts), so what the sweep leaves ringing at the corner does not count. */
  const int w = RH_SR / 1000;
  double before = 0.0;
  int fell = -1;
  for (int i = at - w; i + w < n && fell < 0; ++i) {
    double c = 0.0;
    double q = 0.0;
    for (int k = i; k < i + w; ++k) {
      const double ph = 2.0 * 3.14159265358979 * 1000.0 * k / RH_SR;
      c += y[k] * cos(ph);
      q += y[k] * sin(ph);
    }
    const double e = c * c + q * q;
    if (i == at - w) {
      before = e;
    } else if (i >= at && 10.0 * log10(e / before + 1e-30) < -20.0) {
      fell = i - at;
    }
  }
  printf("  20 dB down %.2f ms after the jump\n", 1000.0 * fell / RH_SR);
  CHECK(fell > 2 * RH_SR / 1000);
  CHECK(fell < 10 * RH_SR / 1000);
  free(y);
}

/* A lane holding a swept LPF stays live (it is locked to the beat, not the
 * lap); at depth 0 it prints. */
static void test_lpf_lfo_lane_stays_live(void) {
  printf("test_lpf_lfo_lane_stays_live\n");
  le_engine* a = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
  cache_record_loop(a, CACHE_LOOP, 1.0f);
  CHECK(le_engine_set_lane_fx(a, 0, 0, 0, LE_FX_LPF) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 0, 0.5f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 1, 0.2f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 0.5f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(a, 0, 0, 1, 1) == LE_OK);
  drain(a);
  le_lane_cache_info info;
  le_engine_get_lane_cache(a, 0, 0, &info);
  pump_frames(a, 0.0f, CACHE_SETTLE);
  pump_frames(a, 0.0f, CACHE_LOOP);
  le_engine_get_lane_cache(a, 0, 0, &info);
  CHECK(info.state == LE_CACHE_GAVE_UP);
  CHECK(info.reason == LE_CACHE_REASON_FREE_RUNNING);
  CHECK(le_engine_set_lane_fx_param(a, 0, 0, 0, 2, 0.0f) == LE_OK);
  drain(a);
  le_engine_get_lane_cache(a, 0, 0, &info);
  pump_frames(a, 0.0f, CACHE_SETTLE);
  CHECK(cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000));
  le_engine_destroy(a);
}

static void run_rhythmic_tests(void) {
  test_pumper_matches_the_capture();
  test_pumper_rates_and_depths();
  test_pumper_follows_the_song_tempo();
  test_fx_tempo_log_reproduces_the_beat();
  test_pumper_lane_is_not_printed();
  test_pumper_renders_from_the_logged_anchors();
  test_fx_beat_follows_the_loop();
  test_pumper_bar_follows_the_signature();
  test_lpf_lfo_matches_the_capture();
  test_lpf_lfo_rate();
  test_lpf_lfo_is_not_printed();
  test_lpf_lfo_reanchor_is_smooth();
  test_lpf_lfo_fast_sweep_is_smooth();
  test_lpf_lfo_follows_the_tempo_not_the_clock();
  test_lpf_lfo_jump_is_slewed();
  test_lpf_lfo_lane_stays_live();
}
