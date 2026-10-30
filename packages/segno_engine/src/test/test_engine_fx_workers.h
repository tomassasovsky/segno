/* Effects on more than one core (#1515, part 1): the monitor chains run as
 * jobs, on the callback or on worker threads, and the engine's output is
 * bit-identical whichever runs them.
 *
 * One scripted session (fxw_session) drives a device-free engine with both
 * monitor chains holding every kind (LE_FX_PLUGIN aside), a recorded loop
 * whose wraps re-anchor the synced kinds' tempo inside blocks, an output bus
 * chain with synced kinds of its own (the second loop's clock), the click,
 * a latency measurement (frames the harness owns), stomps, retypes, a chain
 * edit, a mute and a chain switched off and on, in blocks of every size from
 * one frame to more than two of the frame loop's LE_FX_BLOCK. Its output is
 * compared, sample for sample, across 0, 1, 2 and 3 workers, and with a
 * worker the scheduler never runs.
 *
 * Needs only the public API, engine_internal.h and engine_fx.h, so a copy
 * of fxw_session also runs against the engine from before #1515 to show the
 * split frame loop changes nothing (the PR records that comparison). */

#ifdef FXW_BEFORE_WORKERS
typedef struct le_fx_workers_telemetry le_fx_workers_telemetry;
#endif

#define FXW_SR 48000
#define FXW_IN 2
#define FXW_OUT 4
#define FXW_FRAMES (FXW_SR * 3)

/* A harmonic bass line with a little noise on input 0, its octave on input
 * 1: the Dual Octaver's low band and the gates have something to work on. */
static float fxw_input(int32_t ch, int32_t i) {
  static const float notes[4] = {82.41f, 110.0f, 146.83f, 98.0f};
  const int32_t len = FXW_SR / 4;
  const float hz = notes[(i / len) % 4] * (ch == 0 ? 1.0f : 2.0f);
  const double ph = 2.0 * 3.14159265358979 * hz * (double)i / FXW_SR;
  double x = 0.0;
  for (int k = 1; k <= 6; ++k) x += sin(k * ph) / k;
  uint32_t n = (uint32_t)i * 1664525u + 1013904223u + (uint32_t)ch * 7u;
  n ^= n >> 13;
  return (float)(0.18 * x) + (float)(n & 0xFFFFu) / 65536.0f * 0.01f;
}

/* Every kind but the hosted plugin, half on each monitor: kinds 1..16 on
 * monitor 0 and 17..32 on monitor 1, each at its defaults. */
static void fxw_recipe(le_fx_recipe* r, int32_t monitor) {
  memset(r, 0, sizeof(*r));
  r->enabled = 1;
  int32_t n = 0;
  const int32_t first = monitor == 0 ? 1 : 17;
  for (int32_t k = first; k < first + 16 && k <= LE_FX_SMART_TUNE; ++k) {
    if (k == LE_FX_PLUGIN) continue;
    r->type[n] = k;
    r->slot_enabled[n] = 1;
    r->level[n] = 1.0f;
    le_fx_defaults(k, r->params[n]);
    r->instance[n] = (uint64_t)(100 * (monitor + 1) + k);
    ++n;
  }
  r->count = n;
}

/* The output bus 0 chain: the synced kinds, run in the second loop. */
static void fxw_bus_recipe(le_fx_recipe* r) {
  static const int32_t kinds[] = {LE_FX_PUMPER, LE_FX_SLICER, LE_FX_MODE_DELAY,
                                  LE_FX_OCTAVER};
  memset(r, 0, sizeof(*r));
  r->enabled = 1;
  r->count = 4;
  for (int s = 0; s < 4; ++s) {
    r->type[s] = kinds[s];
    r->slot_enabled[s] = 1;
    r->level[s] = 1.0f;
    le_fx_defaults(kinds[s], r->params[s]);
    r->instance[s] = (uint64_t)(900 + s);
  }
}

static void fxw_post(le_engine* e, int32_t owner, int32_t ch, uint32_t* rev,
                     const le_fx_recipe* r) {
  CHECK(le_engine_set_fx_recipe(e, owner, ch, 0, ++*rev, r) == LE_OK);
}

/* Runs the session on a fresh engine with [workers] workers (worker 0 held
 * when [hold]), writing every output frame to [out] (FXW_FRAMES * FXW_OUT
 * floats). Fills [tm] when it is not NULL. */
static void fxw_session(int32_t workers, int hold, float* out,
                        le_fx_workers_telemetry* tm) {
  static const uint32_t sizes[] = {64, 17, 300, 1, 256, 513, 128, 64, 7, 640};
  le_engine* e = le_engine_create();
  CHECK(e != NULL);
  CHECK(le_engine_configure(e, FXW_SR, FXW_IN, FXW_OUT, FXW_SR * 4) == LE_OK);
#ifndef FXW_BEFORE_WORKERS
  CHECK(le_engine_set_fx_workers(e, workers, NULL) == LE_OK);
  if (hold) le_engine_hold_fx_worker_for_test(e, 0, 1);
#else
  (void)workers;
  (void)hold;
#endif
  uint32_t rev = 1;
  le_fx_recipe m0, m1, bus;
  fxw_recipe(&m0, 0);
  fxw_recipe(&m1, 1);
  fxw_bus_recipe(&bus);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 1, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x3u) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 1, 0xCu) == LE_OK);
  fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
  fxw_post(e, LE_FX_OWNER_MONITOR, 1, &rev, &m1);
  fxw_post(e, LE_FX_OWNER_OUTPUT, 0, &rev, &bus);
  CHECK(le_engine_set_tempo(e, 117.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);

  static float in[1024 * FXW_IN];
  int32_t at = 0;
  int step = 0;
  while (at < FXW_FRAMES) {
    uint32_t n = sizes[step % (int)(sizeof(sizes) / sizeof(sizes[0]))];
    if ((int32_t)n > FXW_FRAMES - at) n = (uint32_t)(FXW_FRAMES - at);
    /* The script, at block boundaries: a 0.7 s take on track 0, so the loop
     * wraps (and re-anchors the tempo) every 0.7 s from 0.8 s on. */
    if (step == 3) CHECK(le_engine_record(e, 0) == LE_OK);
    if (at >= FXW_SR * 7 / 10 && step < 1000) {
      CHECK(le_engine_record(e, 0) == LE_OK);
      step = 1000; /* once */
    }
    if (step == 1040) { /* a stomp on monitor 0 and a retype on monitor 1 */
      m0.slot_enabled[3] = 0;
      fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
      m1.type[5] = LE_FX_DRIVE;
      le_fx_defaults(LE_FX_DRIVE, m1.params[5]);
      m1.instance[5] = 777;
      fxw_post(e, LE_FX_OWNER_MONITOR, 1, &rev, &m1);
    }
    if (step == 1080) { /* a measurement: frames the harness owns */
      CHECK(le_engine_begin_latency_for_test(e, 0, 1, 0.5f, 1) == LE_OK);
    }
    if (step == 1160) { /* a chain edit and the stomp undone */
      m0.slot_enabled[3] = 1;
      m0.count -= 2;
      fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
    }
    if (step == 1200) CHECK(le_engine_set_monitor_input_mute(e, 1, 1) == LE_OK);
    if (step == 1240) CHECK(le_engine_set_monitor_input_mute(e, 1, 0) == LE_OK);
    if (step == 1280) { /* monitor 0's chain off, then on again */
      m0.enabled = 0;
      fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
    }
    if (step == 1320) {
      m0.enabled = 1;
      fxw_post(e, LE_FX_OWNER_MONITOR, 0, &rev, &m0);
    }
    for (uint32_t f = 0; f < n; ++f) {
      for (int32_t c = 0; c < FXW_IN; ++c) {
        in[f * FXW_IN + (uint32_t)c] = fxw_input(c, at + (int32_t)f);
      }
    }
    le_engine_process(e, out + (size_t)at * FXW_OUT, in, n);
    at += (int32_t)n;
    ++step;
  }
#ifndef FXW_BEFORE_WORKERS
  if (tm != NULL) le_engine_get_fx_workers_telemetry(e, tm);
#else
  (void)tm;
#endif
  le_engine_destroy(e);
}

#ifndef FXW_BEFORE_WORKERS

static float g_fxw_ref[FXW_FRAMES * FXW_OUT];
static float g_fxw_out[FXW_FRAMES * FXW_OUT];

/* Where two runs first differ, for the failure message; -1 when they are
 * bit-identical. */
static int64_t fxw_first_difference(const float* a, const float* b) {
  for (int64_t i = 0; i < (int64_t)FXW_FRAMES * FXW_OUT; ++i) {
    if (memcmp(&a[i], &b[i], sizeof(float)) != 0) return i;
  }
  return -1;
}

static void test_fx_workers_output_is_bit_identical(void) {
  le_fx_workers_telemetry tm;
  fxw_session(0, 0, g_fxw_ref, &tm);
  CHECK(tm.running == 0);
  CHECK(tm.rounds == 0);
  /* The session is not silent: the monitors and the bus chain sound. */
  float peak = 0.0f;
  for (int64_t i = 0; i < (int64_t)FXW_FRAMES * FXW_OUT; ++i) {
    if (fabsf(g_fxw_ref[i]) > peak) peak = fabsf(g_fxw_ref[i]);
  }
  CHECK(peak > 0.05f);
  for (int32_t w = 1; w <= LE_FX_WORKERS_MAX; ++w) {
    fxw_session(w, 0, g_fxw_out, &tm);
    const int64_t d = fxw_first_difference(g_fxw_ref, g_fxw_out);
    if (d >= 0) {
      printf("  %d workers: first difference at frame %lld, output %lld\n",
             (int)w, (long long)(d / FXW_OUT), (long long)(d % FXW_OUT));
    }
    CHECK(d < 0);
    CHECK(tm.requested == w);
    CHECK(tm.running == w);
    /* Every block with both chains on was a round (two jobs). */
    CHECK(tm.rounds > 0);
  }
}

/* A worker that is woken but never claims (the scheduler never runs it):
 * every block still finishes, the callback runs the jobs, and the output is
 * the same. */
static void test_fx_workers_held_worker_is_covered(void) {
  le_fx_workers_telemetry tm;
  fxw_session(0, 0, g_fxw_ref, NULL);
  fxw_session(1, 1, g_fxw_out, &tm);
  CHECK(fxw_first_difference(g_fxw_ref, g_fxw_out) < 0);
  CHECK(tm.running == 1);
  CHECK(tm.rounds > 0);
  CHECK(tm.worker[0].jobs == 0);
  CHECK(tm.callback_jobs == 2 * tm.rounds);
}

/* The request: bounds, the cores' range, and the worker count fixed while a
 * device runs (a configured, device-free engine starts them at once). */
static void test_fx_workers_request(void) {
  le_engine* e = le_engine_create();
  le_fx_workers_telemetry tm;
  CHECK(le_engine_set_fx_workers(e, -1, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_set_fx_workers(e, LE_FX_WORKERS_MAX + 1, NULL) ==
        LE_ERR_INVALID);
  const int32_t bad[] = {0, -2};
  CHECK(le_engine_set_fx_workers(e, 1, bad) == LE_ERR_INVALID);
  CHECK(le_engine_set_fx_workers(e, 2, NULL) == LE_OK);
  le_engine_get_fx_workers_telemetry(e, &tm);
  CHECK(tm.requested == 2);
  CHECK(tm.running == 0); /* not configured: nothing started yet */
  CHECK(le_engine_configure(e, FXW_SR, 1, 2, FXW_SR) == LE_OK);
  le_engine_get_fx_workers_telemetry(e, &tm);
  CHECK(tm.running == 2);
  CHECK(le_engine_set_fx_workers(e, 1, NULL) == LE_OK);
  le_engine_get_fx_workers_telemetry(e, &tm);
  CHECK(tm.running == 1);
#if !defined(__linux__)
  /* No way to pin a thread here: a worker asked for a core does not run. */
  const int32_t pinned[] = {-1, 0};
  CHECK(le_engine_set_fx_workers(e, 1, pinned) == LE_OK);
  le_engine_get_fx_workers_telemetry(e, &tm);
  CHECK(tm.running == 0);
#endif
  CHECK(le_engine_set_fx_workers(e, 0, NULL) == LE_OK);
  le_engine_get_fx_workers_telemetry(e, &tm);
  CHECK(tm.running == 0);
  le_engine_destroy(e);
}

static void run_fx_workers_tests(void) {
  test_fx_workers_request();
  test_fx_workers_output_is_bit_identical();
  test_fx_workers_held_worker_is_covered();
}

#endif /* FXW_BEFORE_WORKERS */
