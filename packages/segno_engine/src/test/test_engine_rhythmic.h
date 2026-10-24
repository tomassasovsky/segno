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

/* ---- Slicer ---- */

/* The stored value of pattern [i] (of 20) and step position [k] (of 9). */
static float rh_patt(int i) { return (float)i / 19.0f; }
static float rh_step(int k) { return (float)k / 8.0f; }

/* A one-slot Slicer state on [tempo], its rings ready. */
static le_fx_state* rh_slicer(const le_fx_tempo* tempo) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(fx != NULL);
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  CHECK(le_fx_prepare(fx, 0, LE_FX_SLICER, RH_SR) == LE_OK);
  le_fx_entry_reset(fx, 0);
  fx->tempo = tempo;
  fx->clocked = 1;
  return fx;
}

/* The Slicer's output on a ramp (frame i is i / RH_SR, so a frame's value
 * names it) for [n] frames from clock 0, on both channels. */
static void rh_slice_run(le_fx_state* fx, const float* p3, float* out,
                         int n) {
  static int32_t types[LE_FX_MAX];
  static float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < LE_FX_MAX; ++s) types[s] = LE_FX_NONE;
  types[0] = LE_FX_SLICER;
  for (int q = 0; q < LE_FX_PARAMS; ++q) params[0][q] = p3[q];
  for (int i = 0; i < n; ++i) {
    fx->clock = (uint32_t)i;
    float l = (float)i / (float)RH_SR;
    float r = -l;
    fx_apply_chain(fx, RH_SR, RH_SR, &l, &r, 1, types, params, NULL);
    CHECK(r == -l);
    out[i] = l;
  }
}

/* Whether [v] is the ramp's frame [i], within [slack] frames. */
static int rh_is_frame(float v, double i, double slack) {
  return fabs((double)v * RH_SR - i) <= slack;
}

static float* rh_slice(int patt, int step, float mix, int n) {
  const le_fx_tempo t = rh_tempo(120.0);
  const float p[LE_FX_PARAMS] = {rh_patt(patt), rh_step(step), mix};
  le_fx_state* fx = rh_slicer(&t);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  rh_slice_run(fx, p, out, n);
  le_fx_state_free_buffers(fx);
  free(fx);
  return out;
}

/* AABB at 1/16 and 120 BPM (#891, seg21): a 125 ms step; A's first slice
 * plays live and its second replays it from its start, one step back. */
static void test_slicer_replays_a_repeat(void) {
  printf("test_slicer_replays_a_repeat\n");
  const int step = RH_SR / 8; /* a 1/16 at 120 BPM */
  const int n = 8 * step;     /* two cycles */
  float* o = rh_slice(0, 4, 1.0f, n);
  for (int c = 0; c < 2; ++c) {
    const int at = c * 4 * step;
    for (int k = 0; k < 4; ++k) {
      const int mid = at + k * step + step / 2;
      const int back = (k % 2) ? step : 0; /* A A B B */
      CHECK(rh_is_frame(o[mid], mid - back, 0.5));
    }
  }
  free(o);
  /* At 1/8 the step (and so the replay) is twice as long. */
  o = rh_slice(0, 2, 1.0f, 4 * step);
  CHECK(rh_is_frame(o[3 * step], 3 * step - 2 * step, 0.5));
  free(o);
}

/* ABcccc (seg24): lower case is half a step; c plays live once, then each
 * later c replays it from its start. */
static void test_slicer_half_steps(void) {
  printf("test_slicer_half_steps\n");
  const int half = RH_SR / 16;
  float* o = rh_slice(7, 4, 1.0f, 8 * half);
  CHECK(rh_is_frame(o[4 * half + half / 2], 4 * half + half / 2, 0.5));
  for (int k = 5; k < 8; ++k) {
    const int mid = k * half + half / 2;
    CHECK(rh_is_frame(o[mid], mid - (k - 4) * half, 0.5));
  }
  free(o);
}

/* A_C_ (seg23): a rest is silent; a slice ends with a 4 ms fade and starts
 * without one. */
static void test_slicer_rests_and_fades(void) {
  printf("test_slicer_rests_and_fades\n");
  const int step = RH_SR / 8;
  const int fade = 4 * RH_SR / 1000;
  float* o = rh_slice(4, 4, 1.0f, 4 * step);
  CHECK(o[step + step / 2] == 0.0f);
  CHECK(rh_is_frame(o[step - fade - 1], step - fade - 1, 0.5)); /* whole */
  const float g = o[step - fade / 2] / ((float)(step - fade / 2) / RH_SR);
  CHECK(fabsf(g - 0.5f) < 0.02f); /* half way down */
  CHECK(fabsf(o[step - 1]) < 0.01f);
  /* No fade in (a frame on, as the beat's float rate may land a boundary a
   * frame late). */
  CHECK(rh_is_frame(o[2 * step + 1], 2 * step + 1, 0.5));
  free(o);
}

/* <<<< (the factory Reverse): each step plays the step before backwards. */
static void test_slicer_reverses(void) {
  printf("test_slicer_reverses\n");
  const int step = RH_SR / 8;
  float* o = rh_slice(16, 4, 1.0f, 3 * step);
  for (int k = 10; k < step - 400; k += 997) {
    CHECK(rh_is_frame(o[2 * step + k], 2 * step - k, 1.5));
  }
  free(o);
}

/* Mix (seg22): the slices at Mix, the dry whole up to 50 % and fading to
 * nothing at 100 %. */
static void test_slicer_mix_law(void) {
  printf("test_slicer_mix_law\n");
  const int step = RH_SR / 8;
  const int mid = step + step / 2; /* A's replay, one step back */
  const float x = (float)mid / RH_SR;
  const float w = (float)(mid - step) / RH_SR;
  static const float mix[3][3] = {
      {0.5f, 1.0f, 0.5f}, {0.75f, 0.5f, 0.75f}, {0.25f, 1.0f, 0.25f}};
  for (int m = 0; m < 3; ++m) {
    float* o = rh_slice(0, 4, mix[m][0], 2 * step);
    CHECK(fabsf(o[mid] - (x * mix[m][1] + w * mix[m][2])) < 1e-5f);
    free(o);
  }
}

/* The Fd patterns are not modelled: the input passes. A slicing Slicer is
 * locked to the beat, so its lane is never printed. */
static void test_slicer_fd_passes_and_is_not_printed(void) {
  printf("test_slicer_fd_passes_and_is_not_printed\n");
  const int step = RH_SR / 8;
  for (int i = 17; i < 20; ++i) {
    float* o = rh_slice(i, 4, 1.0f, 2 * step);
    for (int k = 0; k < 2 * step; k += 101) CHECK(rh_is_frame(o[k], k, 0.5));
    free(o);
    const float p[LE_FX_PARAMS] = {rh_patt(i), 0.5f, 1.0f};
    CHECK(!le_fx_entry_free_running(LE_FX_SLICER, p, RH_SR));
  }
  CHECK(le_fx_type_free_running(LE_FX_SLICER));
  const float on[LE_FX_PARAMS] = {rh_patt(0), 0.5f, 1.0f};
  const float off[LE_FX_PARAMS] = {rh_patt(0), 0.5f, 0.0f};
  CHECK(le_fx_entry_free_running(LE_FX_SLICER, on, RH_SR));
  CHECK(!le_fx_entry_free_running(LE_FX_SLICER, off, RH_SR));
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
  test_slicer_replays_a_repeat();
  test_slicer_half_steps();
  test_slicer_rests_and_fades();
  test_slicer_reverses();
  test_slicer_mix_law();
  test_slicer_fd_passes_and_is_not_printed();
}
