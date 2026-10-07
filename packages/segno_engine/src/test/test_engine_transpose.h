/* Transpose (#1179 Part 3a): the cache worker renders each lane's take
 * pitch-shifted through the stretch shim, the callback swaps to it at the
 * same index with the equal-power law, and the renderer reproduces it. The
 * fixture is a 220 Hz sine of a whole number of cycles (110 in 0.5 s at
 * 48 kHz), so the take loops seamlessly and a spectral oracle reads its
 * pitch; the dry read is the take's own sample, exactly. */

#define TP_SR 48000
#define TP_LEN 24000

static float tp_take[TP_LEN];

static le_engine* tp_engine(int tracks) {
  for (int i = 0; i < TP_LEN; ++i) {
    tp_take[i] = 0.5f * (float)sin(2.0 * M_PI * 220.0 * i / TP_SR);
  }
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TP_SR, 1, 1, 30000) == LE_OK);
  for (int t = 0; t < tracks; ++t) {
    CHECK(le_engine_import_track(e, t, tp_take, TP_LEN) == LE_OK);
  }
  CHECK(le_engine_commit_session(e, TP_LEN, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  return e;
}

static int32_t tp_effective(le_engine* e, int ch) {
  le_track_snapshot snap;
  le_engine_get_track(e, ch, &snap);
  return snap.transpose_effective_st;
}

/* Processes up to `max` frames into out (64 at a time, polling the cache
 * between blocks so the worker's render is collected) until track ch sounds
 * `want`; returns the frames processed, or -1. */
static int tp_until(le_engine* e, int ch, int32_t want, float* out, int max) {
  le_lane_cache_info info;
  for (int at = 0; at < max; at += 64) {
    if (tp_effective(e, ch) == want) return at;
    le_engine_get_transpose_cache(e, ch, &info);
    test_sleep_ms(1);
    rev_process(e, out + at, 64, 64);
  }
  return tp_effective(e, ch) == want ? max : -1;
}

static uint64_t tp_install(le_engine* e, int ch, int st) {
  uint64_t id = 0;
  CHECK(le_engine_install_transpose(e, ch, st, &id) == LE_OK && id != 0);
  return id;
}

/* The take's mean square over [from, to) of `x`, and its Goertzel power. */
static double tp_power(const float* x, int from, int to, double hz) {
  return stretch_power_at(x, from, to, hz, TP_SR);
}

/* +12 st: the render peaks at 440 Hz (within 1 %) at the take's exact length
 * and level, loops (two laps are identical and the wrap step is an ordinary
 * one), and two engines render the same key byte-identically. */
static void test_transpose_render_pitch_loop_identity(void) {
  printf("test_transpose_render_pitch_loop_identity\n");
  static float a[8 * TP_LEN], b[8 * TP_LEN];
  le_engine* e = tp_engine(1);
  le_engine* twin = tp_engine(1);
  uint64_t id = tp_install(e, 0, 12), tid = tp_install(twin, 0, 12);
  const int ra = tp_until(e, 0, 12, a, 4 * TP_LEN);
  const int rb = tp_until(twin, 0, 12, b, 4 * TP_LEN);
  CHECK(ra >= 0 && rb >= 0);
  fade_result(e, id, LE_OK);
  fade_result(twin, tid, LE_OK);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.state == LE_CACHE_CACHED && info.engaged && info.renders == 1);
  CHECK(info.entry_frames == TP_LEN);
  rev_process(e, a, 3 * TP_LEN, 64);
  rev_process(twin, b, 3 * TP_LEN, 64);
  const int from = TP_LEN, to = 3 * TP_LEN; /* past the swap window */
  const double p440 = tp_power(a, from, to, 440.0);
  CHECK(p440 > 10.0 * tp_power(a, from, to, 220.0));
  CHECK(p440 > tp_power(a, from, to, 440.0 * 1.01));
  CHECK(p440 > tp_power(a, from, to, 440.0 * 0.99));
  double sumsq = 0;
  for (int i = from; i < to; ++i) sumsq += (double)a[i] * a[i];
  CHECK(sqrt(sumsq / (to - from)) > 0.25); /* a 0.5 sine is 0.354 rms */
  for (int i = 0; i < TP_LEN; ++i) CHECK(a[TP_LEN + i] == a[2 * TP_LEN + i]);
  float max_step = 0;
  for (int i = from; i + 1 < to; ++i) {
    const float d = fabsf(a[i + 1] - a[i]);
    if (d > max_step) max_step = d;
  }
  /* the wraps inside [from, to) are ordinary steps: no frame of the two laps
   * steps further than a 440 Hz sine at 0.5 can (0.029), with headroom */
  if (!(max_step < 0.06f)) {
    for (int i = from; i + 1 < to; ++i) {
      if (fabsf(a[i + 1] - a[i]) > 0.06f) printf("  step at %d: %g -> %g\n", i, a[i], a[i + 1]);
    }
  }
  CHECK(max_step < 0.06f);
  /* the same song position in both engines: a[i] is at ra + i */
  int same = 0, compared = 0;
  for (int i = TP_LEN; i < 3 * TP_LEN; ++i) {
    const int j = i + ra - rb;
    if (j < TP_LEN || j >= 3 * TP_LEN) continue;
    compared++;
    same += a[i] == b[j];
  }
  CHECK(compared > TP_LEN && same == compared);
  le_engine_destroy(e);
  le_engine_destroy(twin);
}

/* A step plays the dry take at true pitch until the render lands
 * (effective 0 meanwhile), then swaps at the same index with the
 * equal-power law over the turn window — the old (dry) source keeps
 * reading — and the 328 fact names the swap frame and index. The offline
 * stem reproduces all of it from the logged index. */
static void test_transpose_dry_until_ready_then_swap(void) {
  printf("test_transpose_dry_until_ready_then_swap\n");
  static float live[6 * TP_LEN], replay[6 * TP_LEN];
  le_engine* e = tp_engine(1);
  const char* dir = render_test_dir("transpose-swap");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  rev_process(e, live, 1000, 64);
  const uint64_t id = tp_install(e, 0, 2);
  rev_process(e, live + 1000, 64, 64);
  fade_result(e, id, LE_OK);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.transpose_st == 2 && snap.transpose_effective_st == 0);
  const int took = tp_until(e, 0, 2, live + 1064, 3 * TP_LEN);
  CHECK(took >= 0);
  const int total = 1064 + took + 2 * TP_LEN + 1000;
  rev_process(e, live + 1064 + took, total - 1064 - took, 64);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry first;
  CHECK(speed_count_facts(dir, LE_PLOG_TRANSPOSE, 0, &first) == 1);
  CHECK(first.cmd.transpose_log.stored == 2 &&
        first.cmd.transpose_log.effective == 2);
  const int F = first.cmd.transpose_log.turn_frames;
  CHECK(F == TP_SR / 100);
  const int f0 = (int)first.frame;
  const uint64_t q = (uint64_t)first.cmd.transpose_log.index_lo |
                     ((uint64_t)first.cmd.transpose_log.index_hi << 32);
  const int idx0 = (int)le_head_index_from_q32(q);
  for (int f = 0; f < f0; ++f) CHECK(live[f] == tp_take[f % TP_LEN]); /* dry */
  CHECK(idx0 == f0 % TP_LEN);
  for (int k = 0; k < F; ++k) {
    const int idx = (idx0 + k) % TP_LEN;
    const float render = live[f0 + k + TP_LEN]; /* the same index a lap on */
    const float want = le_head_turn_mix(k, F, 1) * render +
                       le_head_turn_mix(F - k, F, 1) * tp_take[idx];
    CHECK(fabsf(live[f0 + k] - want) < 1e-5f);
  }
  CHECK(live[f0 + F] != tp_take[(idx0 + F) % TP_LEN]);
  /* the stem */
  static float pcm[TP_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, TP_LEN) == TP_LEN);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, TP_LEN, TP_SR);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 20000);
  const int frames = test_read_wet_stem(dir, 0, replay, 6 * TP_LEN);
  CHECK(frames == total);
  int bad = 0;
  for (int i = 0; i < frames; ++i) bad += fabsf(replay[i] - live[i]) >= 2e-3f;
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* A second step inside the settle window re-keys the job: one render, and
 * the track never sounds the intermediate pitch. A volume move and a chain
 * edit on the engaged track do not re-render (E8). */
static void test_transpose_rekey_and_key_independence(void) {
  printf("test_transpose_rekey_and_key_independence\n");
  static float out[6 * TP_LEN];
  le_engine* e = tp_engine(1);
  uint64_t a = 0, b = 0;
  le_lane_cache_info info;
  CHECK(le_engine_transpose_step(e, 0, 1, &a) == LE_OK);
  for (int k = 0; k < 8; ++k) { /* ticks, worker time, a few blocks */
    rev_process(e, out, 64, 64);
    le_engine_get_transpose_cache(e, 0, &info);
    test_sleep_ms(5);
  }
  CHECK(tp_effective(e, 0) == 0); /* still settling: nothing rendered */
  CHECK(le_engine_transpose_step(e, 0, 1, &b) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, a, LE_OK);
  fade_result(e, b, LE_OK);
  CHECK(tp_until(e, 0, 2, out, 4 * TP_LEN) >= 0);
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.renders == 1);
  CHECK(le_engine_set_lane_volume(e, 0, 0, 0.5f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  for (int k = 0; k < 40; ++k) {
    le_engine_get_transpose_cache(e, 0, &info);
    test_sleep_ms(1);
    rev_process(e, out, 512, 64);
  }
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.renders == 1 && info.engaged && tp_effective(e, 0) == 2);
  le_engine_destroy(e);
}

/* E7: an engaged source render survives cap pressure that evicts a Pre
 * print; a source job that cannot fit is refused with the reason and the
 * track plays dry, reported. */
static void test_transpose_eviction_and_budget(void) {
  printf("test_transpose_eviction_and_budget\n");
  static float out[6 * TP_LEN];
  le_engine* e = tp_engine(3);
  CHECK(le_engine_play(e, 1) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 1, 0, 1, 1) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 1, 0, 0, LE_FX_DRIVE) == LE_OK);
  const uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  le_lane_cache_info print;
  for (int k = 0; k < 200; ++k) {
    le_engine_get_lane_cache(e, 1, 0, &print);
    if (print.state == LE_CACHE_CACHED) break;
    test_sleep_ms(1);
    rev_process(e, out, 512, 64);
  }
  CHECK(print.state == LE_CACHE_CACHED);
  /* a cap below even the playing source render: the print goes, the render
   * a PLAYING track sounds does not */
  CHECK(le_engine_set_fx_cache_cap(e, 1024) == LE_OK);
  le_engine_get_lane_cache(e, 1, 0, &print);
  CHECK(print.entry_frames == 0); /* the print went */
  rev_process(e, out, 512, 64);
  CHECK(tp_effective(e, 0) == 5); /* the source render did not */
  /* track 2 cannot fit a job: refused with the reason, dry, reported */
  uint64_t r2 = 0;
  CHECK(le_engine_install_transpose(e, 2, 3, &r2) == LE_OK);
  le_lane_cache_info info;
  for (int k = 0; k < 120; ++k) {
    le_engine_get_transpose_cache(e, 2, &info);
    rev_process(e, out, 64, 64);
  }
  fade_result(e, r2, LE_OK);
  le_engine_get_transpose_cache(e, 2, &info);
  CHECK(info.state == LE_CACHE_GAVE_UP && info.reason == LE_CACHE_REASON_BUDGET);
  le_track_snapshot snap;
  le_engine_get_track(e, 2, &snap);
  CHECK(snap.transpose_st == 3 && snap.transpose_effective_st == 0);
  le_engine_destroy(e);
}

/* Bypass swaps to dry and back with the stored pitch kept and the render
 * cache-hot; a punch-in on a transposed track is refused and dropped;
 * Clear resets to 0 st and its Undo returns the take untransposed; the step
 * stops at the limit; refusals and rapid presses answer receipts. */
static void test_transpose_bypass_guards_and_resets(void) {
  printf("test_transpose_bypass_guards_and_resets\n");
  static float out[6 * TP_LEN];
  le_engine* e = tp_engine(2);
  uint64_t id = tp_install(e, 0, 11);
  CHECK(tp_until(e, 0, 11, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_set_transpose_bypass(e, 1, &id) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, id, LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.transpose_bypass == 1 && s.tracks[0].transpose_st == 11 &&
        s.tracks[0].transpose_effective_st == 0);
  CHECK(le_engine_record(e, 0) == LE_OK); /* bypassed: capture allowed */
  rev_process(e, out, 64, 64);
  CHECK(le_engine_record(e, 0) == LE_OK);
  rev_process(e, out, 2048, 64);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info);
  const int renders = info.renders;
  CHECK(le_engine_set_transpose_bypass(e, 0, &id) == LE_OK);
  CHECK(tp_until(e, 0, 11, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  /* the overdub changed the take, so a new render; then the step limit */
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.renders == renders + 1);
  uint64_t up = 0, over = 0;
  CHECK(le_engine_transpose_step(e, 0, 1, &up) == LE_OK);
  CHECK(le_engine_transpose_step(e, 0, 1, &over) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, up, LE_OK);
  fade_result(e, over, LE_ERR_CAPACITY); /* at +12 */
  CHECK(le_engine_transpose_step(e, 0, 2, &id) == LE_ERR_INVALID);
  CHECK(le_engine_transpose_step(e, 3, 1, &id) == LE_ERR_INVALID); /* EMPTY */
  /* the guard: refused at the control, dropped on the callback */
  CHECK(le_engine_record(e, 0) == LE_ERR_TRANSFORMED);
  static float before[TP_LEN], after[TP_LEN];
  CHECK(le_engine_export_track(e, 0, before, TP_LEN) == TP_LEN);
  CHECK(le_push(e, LE_CMD_RECORD, 0, 0.0f) == LE_OK);
  process_const(e, 0.25f, 64, out);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_PLAYING);
  CHECK(le_engine_export_track(e, 0, after, TP_LEN) == TP_LEN);
  for (int i = 0; i < TP_LEN; ++i) CHECK(after[i] == before[i]);
  /* Clear resets the pitch; Undo returns the take untransposed */
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  rev_process(e, out, 64, 64);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.transpose_st == 0 && snap.transpose_effective_st == 0);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(tp_until(e, 0, 11, out, TP_LEN) < 0); /* nothing renders: it is 0 st */
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state != LE_TRACK_EMPTY && snap.transpose_st == 0 &&
        snap.transpose_effective_st == 0);
  CHECK(le_engine_record(e, 0) == LE_OK); /* untransposed: punch-in allowed */
  rev_process(e, out, 64, 64);
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.state == LE_TRACK_OVERDUBBING); /* and the callback agrees */
  le_engine_destroy(e);
}

/* E4: a swap's old source is a render the cache retracts and frees inside
 * the turn window (the cap drops to 0 the moment bypass swaps to dry); the
 * window keeps reading it because the collector defers the free until the
 * window lets go. Under ASAN an early free is a use-after-free. */
static void test_transpose_turn_pins_old_render(void) {
  printf("test_transpose_turn_pins_old_render\n");
  static float out[6 * TP_LEN];
  le_engine* e = tp_engine(1);
  uint64_t id = tp_install(e, 0, 7);
  CHECK(tp_until(e, 0, 7, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  rev_process(e, out, 2 * TP_LEN, 64); /* a lap of the render, for reference */
  CHECK(le_engine_set_transpose_bypass(e, 1, &id) == LE_OK);
  rev_process(e, out, 64, 64); /* the swap: the window reads the render */
  CHECK(le_engine_set_fx_cache_cap(e, 0) == LE_OK); /* retract everything */
  le_lane_cache_info info;
  for (int k = 0; k < 12; ++k) { /* through the rest of the window */
    le_engine_get_transpose_cache(e, 0, &info); /* sweeps the graveyard */
    rev_process(e, out + 64 + 64 * k, 64, 64);
  }
  fade_result(e, id, LE_OK);
  /* the window's old head read the render it pinned: equal-power toward dry */
  for (int k = 0; k < 64 * 12; ++k) CHECK(isfinite(out[64 + k]));
  rev_process(e, out, 2048, 64);
  le_engine_get_transpose_cache(e, 0, &info); /* the pin let go: freed */
  CHECK(le_engine_fx_cache_used_bytes(e) == 0);
  le_engine_destroy(e);
}

/* The master position (the clock is one lap of the take, rate 1). */
static int tp_pos(le_engine* e) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  return s.master_position_frames;
}

/* Processes until track ch sounds `want` and its swap window is over, then
 * captures one lap of output into lap (lap[k] at take index (*at + k)). */
static void tp_lap(le_engine* e, float* lap, int* at) {
  static float scratch[TP_LEN];
  rev_process(e, scratch, 1024, 64); /* past any turn window */
  *at = tp_pos(e);
  rev_process(e, lap, TP_LEN, 64);
}

/* M1: Undo and Redo are cache-hot. A take transposed +5 is rendered; with
 * Transpose bypassed it takes an overdub, and the new take is rendered too;
 * Undo then sounds the first render again from the very next block (no
 * dry block, no re-render), sample for sample what it sounded before, and
 * Redo sounds the second the same way. */
static void test_transpose_undo_redo_cache_hot(void) {
  printf("test_transpose_undo_redo_cache_hot\n");
  static float out[8 * TP_LEN], first[TP_LEN], second[TP_LEN], lap[TP_LEN];
  int first_at, second_at, at;
  le_engine* e = tp_engine(1);
  uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  tp_lap(e, first, &first_at);
  CHECK(le_engine_set_transpose_bypass(e, 1, &id) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK); /* bypassed: punch-in allowed */
  for (int k = 0; k < 64; ++k) process_const(e, 0.1f, 64, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  settle_layers(e);
  CHECK(le_engine_set_transpose_bypass(e, 0, &id) == LE_OK);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  tp_lap(e, second, &second_at);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.renders == 2);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  int dry = 0;
  for (int k = 0; k < 32; ++k) { /* two laps, block by block */
    rev_process(e, out, 64, 64);
    dry += tp_effective(e, 0) != 5;
  }
  CHECK(dry == 0);
  tp_lap(e, lap, &at);
  int bad = 0;
  for (int k = 0; k < TP_LEN; ++k) {
    bad += lap[k] != first[((at - first_at + k) % TP_LEN + TP_LEN) % TP_LEN];
  }
  CHECK(bad == 0);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  dry = 0;
  for (int k = 0; k < 32; ++k) {
    rev_process(e, out, 64, 64);
    dry += tp_effective(e, 0) != 5;
  }
  CHECK(dry == 0);
  tp_lap(e, lap, &at);
  bad = 0;
  for (int k = 0; k < TP_LEN; ++k) {
    bad += lap[k] != second[((at - second_at + k) % TP_LEN + TP_LEN) % TP_LEN];
  }
  CHECK(bad == 0);
  for (int k = 0; k < 40; ++k) { /* the worker has time: nothing re-renders */
    le_engine_get_transpose_cache(e, 0, &info);
    test_sleep_ms(1);
  }
  CHECK(info.renders == 2);
  le_engine_destroy(e);
}

/* M2 (review probe P-T3): the render a lane selects is retracted while
 * engaged (the cap drops to 0, no bypass first). Only the selection pin
 * keeps it alive until the next verdict lets go; under ASAN an early free
 * is a use-after-free. The track then plays dry, reported, and the bytes
 * are released. */
static void test_transpose_selected_render_pinned(void) {
  printf("test_transpose_selected_render_pinned\n");
  static float out[8 * TP_LEN];
  le_engine* e = tp_engine(1);
  uint64_t id = tp_install(e, 0, 7);
  CHECK(tp_until(e, 0, 7, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  rev_process(e, out, 1024, 64);
  CHECK(le_engine_set_fx_cache_cap(e, 0) == LE_OK);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info); /* sweeps the graveyard */
  for (int k = 0; k < 24; ++k) {
    rev_process(e, out + 64 * k, 64, 64);
    le_engine_get_transpose_cache(e, 0, &info);
  }
  for (int k = 0; k < 64 * 24; ++k) CHECK(isfinite(out[k]));
  CHECK(tp_effective(e, 0) == 0);
  CHECK(le_engine_fx_cache_used_bytes(e) == 0);
  le_engine_destroy(e);
}

/* M2 (P-T7): a capture armed while the track already sounds transposed
 * renders the transposed stem: PERF_ARM logs the 328 the renderer anchors
 * on. Without it the stem plays the dry take without failing. */
static void test_transpose_arm_while_transposed(void) {
  printf("test_transpose_arm_while_transposed\n");
  static float live[4 * TP_LEN], replay[4 * TP_LEN], scratch[8 * TP_LEN];
  le_engine* e = tp_engine(1);
  uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, scratch, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  rev_process(e, scratch, 1000, 64);
  const char* dir = render_test_dir("transpose-arm");
  CHECK(perf_arm_dir(e, dir) == LE_OK);
  drain(e);
  const int total = 2 * TP_LEN;
  rev_process(e, live, total, 64);
  CHECK(le_perf_disarm(e) == LE_OK);
  static float pcm[TP_LEN];
  CHECK(le_engine_export_track(e, 0, pcm, TP_LEN) == TP_LEN);
  char path[700];
  snprintf(path, sizeof(path), "%s/track.wav", dir);
  test_write_wav_mono(path, pcm, TP_LEN, TP_SR);
  fade_finalize_manifest(dir,
    "{\"followOutput\":false,\"captureMask\":1,\"tracks\":[{\"channel\":0,\"volume\":1,"
    "\"lanes\":[{\"lane\":0,\"deferred\":false,\"pcmRef\":\"track.wav\"}]}]}");
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 20000);
  const int frames = test_read_wet_stem(dir, 0, replay, 4 * TP_LEN);
  CHECK(frames == total);
  int bad = 0;
  for (int i = 0; i < frames; ++i) bad += fabsf(replay[i] - live[i]) >= 2e-3f;
  CHECK(bad == 0);
  le_engine_destroy(e);
}

/* M2 (P-T9): a track never plays two pitches. Two lanes, 220 Hz and
 * 330 Hz, at +12 st both move up an octave: 660 Hz dominates 330 Hz. */
static void test_transpose_two_lanes_move_together(void) {
  printf("test_transpose_two_lanes_move_together\n");
  static float lane1[TP_LEN], out[8 * TP_LEN];
  for (int i = 0; i < TP_LEN; ++i) {
    tp_take[i] = 0.5f * (float)sin(2.0 * M_PI * 220.0 * i / TP_SR);
    lane1[i] = 0.5f * (float)sin(2.0 * M_PI * 330.0 * i / TP_SR);
  }
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, TP_SR, 1, 1, 30000) == LE_OK);
  CHECK(le_engine_import_track(e, 0, tp_take, TP_LEN) == LE_OK);
  CHECK(le_engine_import_track_lane(e, 0, 1, lane1, TP_LEN) == LE_OK);
  CHECK(le_engine_commit_session(e, TP_LEN, 0) == LE_OK);
  CHECK(le_engine_play(e, 0) == LE_OK);
  drain(e);
  uint64_t id = tp_install(e, 0, 12);
  CHECK(tp_until(e, 0, 12, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  rev_process(e, out, 2 * TP_LEN, 64);
  const double p330 = tp_power(out, TP_LEN / 2, 2 * TP_LEN, 330.0);
  const double p660 = tp_power(out, TP_LEN / 2, 2 * TP_LEN, 660.0);
  const double p440 = tp_power(out, TP_LEN / 2, 2 * TP_LEN, 440.0);
  CHECK(p660 > 100.0 * p330); /* lane 1 moved */
  CHECK(p440 > 100.0 * tp_power(out, TP_LEN / 2, 2 * TP_LEN, 220.0));
  le_engine_destroy(e);
}

/* M2 (P-T10): a Pre print never engages while the track sounds transposed
 * (decision 7): the print plays the dry pitch through the chain. */
static void test_transpose_no_print_while_transposed(void) {
  printf("test_transpose_no_print_while_transposed\n");
  static float out[8 * TP_LEN];
  le_engine* e = tp_engine(1);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  le_lane_cache_info print;
  int engaged = 0;
  for (int k = 0; k < 400 && !engaged; ++k) {
    le_engine_get_lane_cache(e, 0, 0, &print);
    engaged = print.engaged;
    test_sleep_ms(1);
    rev_process(e, out, 512, 64);
  }
  CHECK(engaged);
  uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  int ever = 0;
  for (int k = 0; k < 4 * TP_LEN / 512; ++k) {
    le_engine_get_lane_cache(e, 0, 0, &print);
    ever |= print.engaged;
    test_sleep_ms(1);
    rev_process(e, out, 512, 64);
  }
  CHECK(!ever && tp_effective(e, 0) == 5);
  le_engine_destroy(e);
}

/* L2: a stopped transposed track keeps its render: another track's job that
 * needs the room is refused instead, and the stopped track's next Play
 * sounds the pitch at once. L3: a configure resets pitch and bypass with
 * the material. */
static void test_transpose_stopped_render_kept_and_configure(void) {
  printf("test_transpose_stopped_render_kept_and_configure\n");
  static float out[8 * TP_LEN];
  le_engine* e = tp_engine(2);
  uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  rev_process(e, out, 64, 64);
  /* room for a job (its dry copy and render) only if the stopped track's
   * render goes: the job must be refused instead */
  CHECK(le_engine_set_fx_cache_cap(e, (int64_t)TP_LEN * 8 + 1024) == LE_OK);
  uint64_t other = 0;
  CHECK(le_engine_install_transpose(e, 1, 3, &other) == LE_OK);
  le_lane_cache_info info;
  for (int k = 0; k < 200; ++k) {
    le_engine_get_transpose_cache(e, 1, &info);
    test_sleep_ms(1);
    rev_process(e, out, 64, 64);
  }
  fade_result(e, other, LE_OK);
  le_engine_get_transpose_cache(e, 1, &info);
  CHECK(info.state == LE_CACHE_GAVE_UP && info.reason == LE_CACHE_REASON_BUDGET);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rev_process(e, out, 64, 64);
  CHECK(tp_effective(e, 0) == 5);
  CHECK(le_engine_set_transpose_bypass(e, 1, &id) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_configure(e, TP_SR, 1, 1, 30000) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.transpose_bypass == 0);
  CHECK(s.tracks[0].transpose_st == 0 && s.tracks[0].transpose_effective_st == 0);
  CHECK(s.tracks[1].transpose_st == 0);
  le_engine_destroy(e);
}

/* 3a L-D1 (K8): a bypassed overdub of two passes files the pre-session key
 * on the first pass's backup only. Undo of the second pass brings back
 * content that never sounded settled (the take plus the first pass): it has
 * no render, so it plays dry and renders afresh, never the pre-session
 * render over different PCM. The render that lands is the fresh one: a lap
 * of it differs from the pre-session lap. */
static void test_transpose_two_pass_undo_renders_afresh(void) {
  printf("test_transpose_two_pass_undo_renders_afresh\n");
  static float out[8 * TP_LEN], first[TP_LEN], lap[TP_LEN];
  int first_at, at;
  le_engine* e = tp_engine(1);
  uint64_t id = tp_install(e, 0, 5);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  tp_lap(e, first, &first_at);
  CHECK(le_engine_set_transpose_bypass(e, 1, &id) == LE_OK);
  rev_process(e, out, 64, 64);
  fade_result(e, id, LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK); /* bypassed: punch-in allowed */
  /* Two whole passes and a little: the loop wraps twice while dubbing. */
  for (int k = 0; k < (2 * TP_LEN + 2048) / 64; ++k) {
    process_const(e, 0.1f, 64, out);
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  settle_layers(e);
  le_track_snapshot snap;
  le_engine_get_track(e, 0, &snap);
  CHECK(snap.undo_depth >= 2);
  CHECK(le_engine_set_transpose_bypass(e, 0, &id) == LE_OK);
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  fade_result(e, id, LE_OK);
  le_lane_cache_info info;
  le_engine_get_transpose_cache(e, 0, &info);
  const int renders = info.renders;
  /* Undo the second pass: the first pass's result, never rendered. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  rev_process(e, out, 64, 64);
  CHECK(tp_effective(e, 0) == 0); /* dry, not a stale render */
  CHECK(tp_until(e, 0, 5, out, 4 * TP_LEN) >= 0);
  le_engine_get_transpose_cache(e, 0, &info);
  CHECK(info.renders == renders + 1);
  tp_lap(e, lap, &at);
  int same = 0;
  for (int k = 0; k < TP_LEN; ++k) {
    same += lap[k] == first[((at - first_at + k) % TP_LEN + TP_LEN) % TP_LEN];
  }
  CHECK(same < TP_LEN / 2); /* the first pass is in it */
  le_engine_destroy(e);
}

/* 3a L-D1 (K3): a slot handed out for new PCM carries no content key. An
 * Undo files the outgoing overdub's key on its slot (now on the redo side);
 * a new overdub drops that redo entry and hands the freed slot out as a
 * shadow, which must come out keyless: a key left on it would name content
 * the slot no longer holds the moment the shadow is written. */
static void test_transpose_handed_out_slot_has_no_key(void) {
  printf("test_transpose_handed_out_slot_has_no_key\n");
  static float out[TP_LEN];
  le_engine* e = tp_engine(1);
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int k = 0; k < 64; ++k) process_const(e, 0.1f, 64, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  settle_layers(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  rev_process(e, out, 64, 64);
  le_track* t = &e->tracks[0];
  CHECK(t->redo_count == 1);
  const int32_t freed = t->redo_stack[0].slot;
  CHECK(freed >= 0 && freed < LE_POOL_SLOTS);
  CHECK(atomic_load(&t->a_slot_key[freed]) != 0u); /* filed on the way out */
  CHECK(le_engine_record(e, 0) == LE_OK); /* drops the redo, posts shadows */
  rev_process(e, out, 64, 64);
  CHECK(t->redo_count == 0);
  CHECK(t->dub_slot == freed || t->dub_spare == freed);
  CHECK(atomic_load(&t->a_slot_key[freed]) == 0u);
  CHECK(le_engine_record(e, 0) == LE_OK);
  settle_layers(e);
  le_engine_destroy(e);
}

static void run_transpose_tests(void) {
  test_transpose_two_pass_undo_renders_afresh();
  test_transpose_handed_out_slot_has_no_key();
  test_transpose_render_pitch_loop_identity();
  test_transpose_dry_until_ready_then_swap();
  test_transpose_rekey_and_key_independence();
  test_transpose_eviction_and_budget();
  test_transpose_bypass_guards_and_resets();
  test_transpose_turn_pins_old_render();
  test_transpose_undo_redo_cache_hot();
  test_transpose_selected_render_pinned();
  test_transpose_arm_while_transposed();
  test_transpose_two_lanes_move_together();
  test_transpose_no_print_while_transposed();
  test_transpose_stopped_render_kept_and_configure();
}
