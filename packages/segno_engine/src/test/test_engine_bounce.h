/* Bounce (#1202, Part 4a: Keep sources): literal-PCM oracles through the
 * production entry points. Built on the render-recipe fixture (track 0 holds
 * A[i] = i + 1 over 16 frames, track 1 holds B[i] = 100 (i + 1) over 24, on
 * an 8-frame base), so the bounced pair is A[f % 16] + B[f % 24] over 48
 * frames and every installed sample names where it came from. */

/* A finished memory render of `mask` (Cut), its job id returned. */
static uint32_t bb_render(le_engine* e, uint32_t mask) {
  le_render_request q = rr_request(mask, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  return id;
}

/* A topology that gives track `ch` `lanes` lanes. */
static le_mix_settings bb_lanes(int32_t ch, int32_t lanes) {
  le_mix_settings mix;
  memset(&mix, 0, sizeof(mix));
  mix.revision = 1;
  mix.lane_count_mask = 1u << ch;
  mix.lane_count[ch] = lanes;
  return mix;
}

/* Admits, lets the callback apply, collects; returns the callback result or
 * the admission refusal. */
static int32_t bb_bounce(le_engine* e, uint32_t job, int32_t dest,
                         const le_mix_settings* topology) {
  le_bounce_request q = {job, dest, 1, topology, NULL, 0, NULL};
  uint64_t receipt = 0;
  const int32_t rc = le_engine_bounce(e, &q, &receipt);
  if (rc != LE_OK) return rc;
  drain(e);
  le_engine_drain_events(e);
  int32_t result = LE_ERR_INVALID;
  CHECK(le_engine_read_request_result(e, receipt, &result) == LE_OK);
  return result;
}

static int32_t bb_recover(le_engine* e, int32_t dest, int redo,
                          const le_fx_recipe* lane_fx, int32_t lane_fx_count,
                          const le_mix_settings* topology) {
  le_bounce_recover_request q = {dest, redo, topology, lane_fx, lane_fx_count,
                                 NULL};
  uint64_t receipt = 0;
  const int32_t rc = le_engine_bounce_recover(e, &q, &receipt);
  if (rc != LE_OK) return rc;
  drain(e);
  le_engine_drain_events(e);
  int32_t result = LE_ERR_INVALID;
  CHECK(le_engine_read_request_result(e, receipt, &result) == LE_OK);
  return result;
}

static const float* bb_live(le_engine* e, int32_t ch, int32_t lane) {
  le_lane* ln = &e->tracks[ch].lanes[lane];
  return ln->pool[atomic_load(&ln->a_live)];
}

static void test_bounce_into_empty_destination(void) {
  printf("test_bounce_into_empty_destination\n");
  le_engine* e = rr_fixture();
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(2, 2);
  CHECK(bb_bounce(e, job, 2, &two) == LE_OK);
  le_track_snapshot s;
  le_engine_get_track(e, 2, &s);
  CHECK(s.state == LE_TRACK_STOPPED); /* Keep sources: the destination waits */
  CHECK(s.length_frames == 48);
  CHECK(s.multiple == 6); /* 48 over the 8-frame base */
  CHECK(s.lane_count == 2);
  CHECK(s.undo_depth == 1 && s.redo_depth == 0);
  const float* l = bb_live(e, 2, 0);
  const float* r = bb_live(e, 2, 1);
  for (int f = 0; f < 48; ++f) {
    CHECK(l[f] == rr_a(f) + rr_b(f));
    CHECK(r[f] == rr_a(f) + rr_b(f));
  }
  /* The stereo pair: lane 0 hard left, lane 1 hard right, unity. */
  float gl, gr;
  le_pan_gains(-1.0f, &gl, &gr);
  CHECK(load_f32(&e->tracks[2].lanes[0].a_pan_gl_bits) == gl);
  CHECK(load_f32(&e->tracks[2].lanes[0].a_pan_gr_bits) == gr);
  CHECK(load_f32(&e->tracks[2].lanes[0].a_vol_bits) == 1.0f);
  CHECK(load_f32(&e->tracks[2].a_gain_bits) == 1.0f);
  /* Sources are untouched. */
  le_engine_get_track(e, 0, &s);
  CHECK(s.state == LE_TRACK_STOPPED && s.length_frames == 16);
  /* Played from the loop top with the sources muted (Play unparks every
   * stopped track), the pair is the bounce. */
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  CHECK(le_engine_set_lane_mute(e, 1, 0, 1) == LE_OK);
  CHECK(le_engine_play(e, 2) == LE_OK);
  float out[2 * 48];
  rr_pump(e, out, 48, 7);
  for (int f = 0; f < 48; ++f) {
    CHECK(out[2 * f] == (rr_a(f) + rr_b(f)) * gl);
    CHECK(out[2 * f + 1] == rr_a(f) + rr_b(f)); /* lane 1, hard right */
  }
  /* Undo empties it again on its own slot; Redo reinstalls the bounce. */
  CHECK(le_engine_stop_track(e, 2) == LE_OK);
  drain(e);
  CHECK(bb_recover(e, 2, 0, NULL, 0, NULL) == LE_OK);
  le_engine_get_track(e, 2, &s);
  CHECK(s.state == LE_TRACK_EMPTY && s.length_frames == 0);
  CHECK(s.undo_depth == 0 && s.redo_depth == 1);
  CHECK(bb_recover(e, 2, 1, NULL, 0, NULL) == LE_OK);
  le_engine_get_track(e, 2, &s);
  CHECK(s.state == LE_TRACK_STOPPED && s.length_frames == 48);
  CHECK(s.undo_depth == 1 && s.redo_depth == 0);
  l = bb_live(e, 2, 0);
  for (int f = 0; f < 48; ++f) CHECK(l[f] == rr_a(f) + rr_b(f));
  le_engine_destroy(e);
}

/* A Multi rig whose spans fit (A: 16 frames, C: 32 frames of 100 (i + 1)),
 * so the replaced take passes the history gate on its way back. */
static float bb_c(int64_t i) { return 100.0f * (float)(i % 32 + 1); }

static le_engine* bb_fit_fixture(void) {
  le_engine* e = rr_engine();
  float a[16];
  float c[32];
  for (int i = 0; i < 16; ++i) a[i] = (float)(i + 1);
  for (int i = 0; i < 32; ++i) c[i] = bb_c(i);
  CHECK(le_engine_import_track(e, 0, a, 16) == LE_OK);
  CHECK(le_engine_import_track(e, 1, c, 32) == LE_OK);
  CHECK(le_engine_commit_session(e, 16, 0) == LE_OK);
  drain(e);
  return e;
}

static void test_bounce_replaces_and_restores(void) {
  printf("test_bounce_replaces_and_restores\n");
  le_engine* e = bb_fit_fixture();
  /* Track 1 (B) is both a source and the destination, with processing the
   * bounce must reset: half gain, a Drive on its part, Reverse, a mute. */
  le_mix_settings gain;
  memset(&gain, 0, sizeof(gain));
  gain.revision = 1;
  gain.track_gain_mask = 1u << 1;
  gain.track_gain[1] = 0.5f;
  CHECK(le_engine_set_mix(e, &gain) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 1, 0, 1, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 1, 0, 0, LE_FX_DRIVE) == LE_OK);
  uint64_t rq;
  CHECK(le_engine_toggle_reverse(e, 1, &rq) == LE_OK);
  CHECK(le_engine_set_lane_mute(e, 1, 0, 1) == LE_OK);
  drain(e);
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(1, 2);
  CHECK(bb_bounce(e, job, 1, &two) == LE_OK);
  le_track_snapshot s;
  le_engine_get_track(e, 1, &s);
  CHECK(s.length_frames == 32 && s.multiple == 2 && s.lane_count == 2);
  CHECK(s.reversed == 0 && s.muted == 0);
  CHECK(load_f32(&e->tracks[1].a_gain_bits) == 1.0f);
  CHECK(load_i32(&e->tracks[1].lanes[0].a_fx_count) == 0);
  const float* l = bb_live(e, 1, 0);
  /* The render printed the Drive, the half gain, the reverse — not the mute. */
  float sum = 0.0f;
  for (int f = 0; f < 32; ++f) sum += fabsf(l[f]);
  CHECK(sum > 0.0f);
  /* Undo puts B back: its exact samples, length, multiple, state, mute,
   * direction, and (through the given recipe and topology) its Drive and
   * gain. */
  le_fx_recipe drive;
  memset(&drive, 0, sizeof(drive));
  drive.count = 1;
  drive.enabled = 1;
  drive.type[0] = LE_FX_DRIVE;
  drive.slot_enabled[0] = 1;
  drive.level[0] = 1.0f;
  le_fx_defaults(LE_FX_DRIVE, drive.params[0]);
  le_fx_recipe lanes_fx[2];
  memset(lanes_fx, 0, sizeof(lanes_fx));
  lanes_fx[0] = drive;
  lanes_fx[1].enabled = 1;
  CHECK(bb_recover(e, 1, 0, lanes_fx, 2, &gain) == LE_OK);
  le_engine_get_track(e, 1, &s);
  CHECK(s.state == LE_TRACK_STOPPED && s.length_frames == 32);
  CHECK(s.multiple == 2 && s.reversed == 1 && s.muted == 1);
  CHECK(s.undo_depth == 0 && s.redo_depth == 1);
  CHECK(load_f32(&e->tracks[1].a_gain_bits) == 0.5f);
  CHECK(load_i32(&e->tracks[1].lanes[0].a_fx_count) == 1);
  CHECK(load_i32(&e->tracks[1].lanes[0].a_fx_type[0]) == LE_FX_DRIVE);
  l = bb_live(e, 1, 0);
  for (int f = 0; f < 32; ++f) CHECK(l[f] == bb_c(f));
  /* Redo reapplies the bounce and its reset. */
  CHECK(bb_recover(e, 1, 1, NULL, 0, NULL) == LE_OK);
  le_engine_get_track(e, 1, &s);
  CHECK(s.length_frames == 32 && s.reversed == 0 && s.muted == 0);
  CHECK(load_f32(&e->tracks[1].a_gain_bits) == 1.0f);
  CHECK(load_i32(&e->tracks[1].lanes[0].a_fx_count) == 0);
  le_engine_destroy(e);
}

static void test_bounce_phase_continues(void) {
  printf("test_bounce_phase_continues\n");
  /* A destination later played next to a kept source stays in phase: its
   * segment origin is the iteration the render froze in. */
  le_engine* e = rr_fixture();
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  rr_pump(e, NULL, 37, 5);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  float live[2 * 64];
  rr_pump(e, live, 1, 1); /* the freeze lands at 37 */
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  float render[2 * 48];
  CHECK(le_engine_render_copy(e, id, render, 48) == 48);
  const le_mix_settings two = bb_lanes(2, 2);
  CHECK(bb_bounce(e, id, 2, &two) == LE_OK);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  CHECK(le_engine_set_lane_mute(e, 1, 0, 1) == LE_OK);
  CHECK(le_engine_play(e, 2) == LE_OK);
  drain(e);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  /* The destination reads the render at the frames since the freeze's
   * iteration top. */
  const int64_t pos = (int64_t)snap.master_position_frames;
  const uint64_t iter = e->loop_iteration;
  const int64_t since =
      (int64_t)(iter - e->tracks[2].start_iter) * 8 + pos;
  float gl, gr;
  le_pan_gains(-1.0f, &gl, &gr);
  rr_pump(e, live, 32, 4);
  for (int m = 0; m < 32; ++m) {
    const int f = (int)((since + m) % 48);
    CHECK(live[2 * m] == render[2 * f] * gl);
  }
  le_engine_destroy(e);
}

static void test_bounce_mode_fit_and_reclock(void) {
  printf("test_bounce_mode_fit_and_reclock\n");
  le_engine* e = rr_engine();
  static float a[7000];
  for (int i = 0; i < 7000; ++i) a[i] = 0.25f;
  CHECK(le_engine_import_track(e, 0, a, 7000) == LE_OK);
  CHECK(le_engine_commit_session(e, 7000, 0) == LE_OK);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  /* One bar at 120 BPM is 96,000 frames: not a multiple of the 7,000 base. */
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  q.length_bars = 1;
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  const le_mix_settings two = bb_lanes(2, 2);
  CHECK(bb_bounce(e, id, 2, &two) == LE_ERR_MODE_MISMATCH);
  /* Into the source itself, the bounce is the only content: the master
   * follows it and keeps running. */
  const le_mix_settings src = bb_lanes(0, 2);
  CHECK(bb_bounce(e, id, 0, &src) == LE_OK);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.master_length_frames == 96000);
  le_track_snapshot s;
  le_engine_get_track(e, 0, &s);
  CHECK(s.length_frames == 96000 && s.multiple == 1);
  /* Its undo restores the 7,000-frame master with the take. */
  CHECK(bb_recover(e, 0, 0, NULL, 0, NULL) == LE_OK);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.master_length_frames == 7000);
  le_engine_get_track(e, 0, &s);
  CHECK(s.length_frames == 7000 && s.multiple == 1);
  le_engine_destroy(e);
}

static void test_bounce_refusals_and_history(void) {
  printf("test_bounce_refusals_and_history\n");
  le_engine* e = rr_fixture();
  uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(2, 2);
  le_bounce_request q = {job, 2, 0, &two, NULL, 0, NULL};
  uint64_t receipt;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_UNSUPPORTED); /* Clear sources */
  q.keep_sources = 1;
  q.topology = NULL;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_INVALID); /* one lane */
  q.topology = &two;
  q.job = job + 1;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_NOT_READY); /* no such job */
  q.job = job;
  /* A source that changed after the render. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_TRACKS_CHANGED);
  le_engine_destroy(e);

  e = rr_fixture();
  job = bb_render(e, 0x3);
  q.job = job;
  /* A busy destination. */
  CHECK(le_engine_record(e, 2) == LE_OK);
  drain(e);
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_NOT_READY);
  le_engine_destroy(e);

  e = rr_fixture();
  job = bb_render(e, 0x3);
  q.job = job;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_OK);
  /* In flight: every other history motion on the destination waits. */
  CHECK(le_engine_undo(e, 2) == LE_ERR_NOT_READY);
  CHECK(le_engine_record(e, 2) == LE_ERR_NOT_READY);
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_NOT_READY);
  drain(e);
  le_engine_drain_events(e);
  /* Plain Undo/Redo never split a bounce; Peel stops at it. */
  CHECK(le_engine_undo(e, 2) == LE_ERR_INVALID);
  CHECK(le_engine_peel(e, 2) != LE_OK);
  CHECK(bb_recover(e, 2, 0, NULL, 0, NULL) == LE_OK);
  CHECK(le_engine_redo(e, 2) == LE_ERR_INVALID);
  CHECK(bb_recover(e, 2, 0, NULL, 0, NULL) == LE_ERR_INVALID); /* nothing on top */
  /* Raw posts of either command are refused. */
  CHECK(le_engine_post_command(e, LE_CMD_BOUNCE, 2, 0.0f) != LE_OK);
  CHECK(le_engine_post_command(e, LE_CMD_BOUNCE_RECOVER, 2, 0.0f) != LE_OK);
  le_engine_destroy(e);
}

/* A saved Session never carries a Bounce: export starts above the newest
 * BOUNCE on the Undo side and stops at one on the Redo side, and the images
 * it names follow the same cut (review H6). */
static void test_bounce_export_cut(void) {
  printf("test_bounce_export_cut\n");
  le_engine* e = bb_fit_fixture();
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(1, 2);
  CHECK(bb_bounce(e, job, 1, &two) == LE_OK);
  int32_t kinds[8], skipped[8], undo = -1;
  CHECK(le_engine_export_history(e, 1, kinds, skipped, 8, &undo) == 0);
  CHECK(undo == 0);
  float img[64];
  CHECK(le_engine_export_layer(e, 1, 0, 0, img, 64) == 32); /* live: bounce */
  CHECK(img[0] == rr_a(0) + bb_c(0));
  CHECK(le_engine_export_layer(e, 1, 0, 1, img, 64) == LE_ERR_INVALID);
  /* After its undo the Redo side holds the bounce; nothing is exported. */
  CHECK(bb_recover(e, 1, 0, NULL, 0, NULL) == LE_OK);
  CHECK(le_engine_export_history(e, 1, kinds, skipped, 8, &undo) == 0);
  CHECK(undo == 0);
  CHECK(le_engine_export_layer(e, 1, 0, 0, img, 64) == 32); /* live: C */
  CHECK(img[0] == bb_c(0));
  CHECK(le_engine_export_layer(e, 1, 0, 1, img, 64) == LE_ERR_INVALID);
  /* And the validator refuses a BOUNCE kind outright. */
  int32_t bounce_kind[1] = {LE_HIST_BOUNCE}, zero[1] = {0};
  CHECK(le_engine_finalize_history(e, 3, bounce_kind, zero, 1, 0) ==
        LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* A bounce the callback never applied (the device went away first) leaves
 * nothing behind: no bundle, no pinned slot, no history (ASAN checks the
 * frees). */
static void test_bounce_abandoned_by_configure(void) {
  printf("test_bounce_abandoned_by_configure\n");
  le_engine* e = rr_fixture();
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(2, 2);
  le_bounce_request q = {job, 2, 1, &two, NULL, 0, NULL};
  uint64_t receipt = 0;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_OK);
  CHECK(e->tracks[2].bounce_inflight != NULL);
  CHECK(le_engine_configure(e, RR_SR, 1, 2, 0) == LE_OK);
  CHECK(e->tracks[2].bounce_inflight == NULL);
  CHECK(e->tracks[2].bounce_pin[0] == 0 && e->tracks[2].bounce_pin[1] == 0);
  CHECK(e->tracks[2].undo_count == 0);
  le_engine_destroy(e);
}

/* A loop-close restoration committed on the control thread while a Bounce
 * into the same track waits for the callback never takes the slot holding
 * the incoming image: the Bounce pins its slots until it is collected. The
 * restoration files first, so Undo of the Bounce returns to it. */
static void test_bounce_pins_slots_in_flight(void) {
  printf("test_bounce_pins_slots_in_flight\n");
  le_engine* e = bb_fit_fixture();
  const uint32_t job = bb_render(e, 0x3); /* A[f % 16] + C[f % 32], 32 frames */
  const le_mix_settings two = bb_lanes(1, 2);
  le_bounce_request q = {job, 1, 1, &two, NULL, 0, NULL};
  uint64_t receipt = 0;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_OK);
  float fixed[32];
  for (int i = 0; i < 32; ++i) fixed[i] = -1.0f - (float)i;
  float* restored[LE_MAX_LANES] = {fixed};
  const uint32_t rev = atomic_load(&e->tracks[1].a_audio_rev);
  CHECK(le_restore_commit_layer(e, 1, 0x1u, rev, 32, restored) == LE_OK);
  drain(e);
  le_engine_drain_events(e);
  int32_t result = LE_ERR_INVALID;
  CHECK(le_engine_read_request_result(e, receipt, &result) == LE_OK);
  CHECK(result == LE_OK);
  const float* l = bb_live(e, 1, 0);
  const float* r = bb_live(e, 1, 1);
  for (int f = 0; f < 32; ++f) {
    CHECK(l[f] == rr_a(f) + bb_c(f));
    CHECK(r[f] == rr_a(f) + bb_c(f));
  }
  le_track_snapshot s;
  le_engine_get_track(e, 1, &s);
  CHECK(s.undo_depth == 2);
  le_mix_settings one = bb_lanes(1, 1);
  CHECK(bb_recover(e, 1, 0, NULL, 0, &one) == LE_OK);
  l = bb_live(e, 1, 0);
  for (int f = 0; f < 32; ++f) CHECK(l[f] == fixed[f]);
  le_engine_destroy(e);
}

/* A layer filed on top of a Bounce is undone first, by plain Undo; the
 * Bounce's own recovery is refused until the Bounce is on top again. */
static void test_bounce_layer_on_top_undoes_first(void) {
  printf("test_bounce_layer_on_top_undoes_first\n");
  le_engine* e = rr_fixture();
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(2, 2);
  CHECK(bb_bounce(e, job, 2, &two) == LE_OK);
  float fixed[48];
  for (int i = 0; i < 48; ++i) fixed[i] = -1.0f - (float)i;
  float* restored[LE_MAX_LANES] = {fixed};
  const uint32_t rev = atomic_load(&e->tracks[2].a_audio_rev);
  CHECK(le_restore_commit_layer(e, 2, 0x1u, rev, 48, restored) == LE_OK);
  le_track_snapshot s;
  le_engine_get_track(e, 2, &s);
  CHECK(s.undo_depth == 2);
  CHECK(bb_recover(e, 2, 0, NULL, 0, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_undo(e, 2) == LE_OK);
  drain(e);
  le_engine_drain_events(e);
  const float* l = bb_live(e, 2, 0);
  for (int f = 0; f < 48; ++f) CHECK(l[f] == rr_a(f) + rr_b(f));
  CHECK(le_engine_undo(e, 2) == LE_ERR_INVALID); /* the Bounce is on top */
  CHECK(bb_recover(e, 2, 0, NULL, 0, NULL) == LE_OK);
  le_engine_get_track(e, 2, &s);
  CHECK(s.state == LE_TRACK_EMPTY && s.undo_depth == 0);
  le_engine_destroy(e);
}

/* The topology rides the structural path: a pending lane-count change on the
 * rig refuses the Bounce until it is published, and a one-lane PLAYING
 * destination grows to two lanes in the drain that installs the image. */
static void test_bounce_topology_grows_playing_destination(void) {
  printf("test_bounce_topology_grows_playing_destination\n");
  le_engine* e = bb_fit_fixture();
  CHECK(le_engine_play(e, 1) == LE_OK);
  rr_pump(e, NULL, 21, 5);
  const uint32_t job = bb_render(e, 0x3);
  float render[2 * 32]; /* frozen mid-loop: the image the bounce installs */
  CHECK(le_engine_render_copy(e, job, render, 32) == 32);
  const le_mix_settings three = bb_lanes(0, 3);
  CHECK(le_engine_set_mix(e, &three) == LE_OK); /* not yet applied */
  const le_mix_settings two = bb_lanes(1, 2);
  le_bounce_request q = {job, 1, 1, &two, NULL, 0, NULL};
  uint64_t receipt = 0;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_ERR_NOT_READY);
  drain(e);
  CHECK(e->tracks[1].lane_count == 1);
  CHECK(bb_bounce(e, job, 1, &two) == LE_OK);
  le_track_snapshot s;
  le_engine_get_track(e, 1, &s);
  CHECK(s.lane_count == 2 && s.length_frames == 32);
  const float* l = bb_live(e, 1, 0);
  const float* r = bb_live(e, 1, 1);
  for (int f = 0; f < 32; ++f) {
    CHECK(l[f] == render[2 * f]);
    CHECK(r[f] == render[2 * f + 1]);
  }
  le_engine_destroy(e);
}

/* During an armed performance capture the installed image is staged first
 * (#1143): the callback's 322 names it at the frame it starts mixing, and
 * the stem never loses provenance (no 323/0). */
static void test_bounce_names_its_image(void) {
  printf("test_bounce_names_its_image\n");
  le_engine* e = history_fixture();
  const char* dir = render_test_dir("bounce-provenance");
  (void)history_arm_image(e, dir);
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);
  static float live[4096];
  int at = history_process(e, live, 0, 37, 16);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  at = history_process(e, live, at, 16, 16); /* the freeze lands */
  int32_t result = LE_OK;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  const le_mix_settings two = bb_lanes(0, 2);
  le_bounce_request b = {id, 0, 1, &two, NULL, 0, NULL};
  uint64_t receipt = 0;
  const int32_t brc = le_engine_bounce(e, &b, &receipt);
  printf("  brc %d out %d cr %d cp %d q %d armed %d pend %d launch %d lif %d st %d/%d grow %d ready %d\n", brc,
         e->tracks[0].outstanding_count, e->tracks[0].clear_restore_pending,
         e->tracks[0].cancel_pending, e->tracks[0].queued_undo, e->armed[0],
         atomic_load(&e->tracks[0].a_pending), atomic_load(&e->tracks[0].a_pending_launch),
         atomic_load(&e->tracks[0].a_layer_in_flight), (int)e->tracks[0].state_cmds_posted,
         (int)atomic_load(&e->tracks[0].a_state_acks), (int)(e->lane_growth_command > atomic_load(&e->a_commands_published)),
         le_cache_source_ready(e, 0));
  CHECK(brc == LE_OK);
  const int32_t slot = e->tracks[0].bounce_pin[0] - 1;
  CHECK(slot >= 0);
  const uint32_t staged =
      slot >= 0 ? atomic_load(&e->perf.slot_image[0][slot]) : 0;
  CHECK(staged != 0);
  const int swap = at;
  at = history_process(e, live, at, 64, 16);
  le_engine_drain_events(e);
  CHECK(le_engine_read_request_result(e, receipt, &result) == LE_OK);
  CHECK(result == LE_OK);
  CHECK(le_perf_disarm(e) == LE_OK);
  le_perf_log_entry facts[16];
  const int n = history_source_facts(dir, 0, facts, 16);
  int named = 0;
  for (int i = 0; i < n; ++i) {
    if (facts[i].frame < (uint64_t)swap) continue;
    CHECK(facts[i].cmd.restore_log.image_id != 0); /* never 323/0 */
    if (facts[i].cmd.code == LE_PLOG_SOURCE_APPLIED &&
        facts[i].cmd.restore_log.image_id == staged) {
      CHECK(facts[i].frame == (uint64_t)swap);
      ++named;
    }
  }
  CHECK(named == 1);
  le_engine_destroy(e);
}

/* A Bounce the callback never applied before the device was lost is an
 * unapplied state command: reopen drops its destination with the mask, and
 * retains every other track (the reopen rule, #1140). */
static void test_bounce_unapplied_at_reopen_drops_track(void) {
  printf("test_bounce_unapplied_at_reopen_drops_track\n");
  le_engine* e = rr_fixture();
  const uint32_t job = bb_render(e, 0x3);
  const le_mix_settings two = bb_lanes(1, 2);
  le_bounce_request q = {job, 1, 1, &two, NULL, 0, NULL};
  uint64_t receipt = 0;
  CHECK(le_engine_bounce(e, &q, &receipt) == LE_OK);
  int32_t outcome = -99, mask = -99;
  CHECK(le_engine_reopen_configured(e, RR_SR, 1, 2, 0, &outcome, &mask) ==
        LE_OK);
  CHECK(outcome == LE_REOPEN_RETAINED_PARTIAL && mask == (1 << 1));
  CHECK(e->tracks[1].bounce_inflight == NULL);
  CHECK(e->tracks[1].bounce_pin[0] == 0 && e->tracks[1].bounce_pin[1] == 0);
  le_track_snapshot s;
  le_engine_get_track(e, 1, &s);
  CHECK(s.state == LE_TRACK_EMPTY && s.undo_depth == 0);
  le_engine_get_track(e, 0, &s);
  CHECK(s.state == LE_TRACK_STOPPED && s.length_frames == 16);
  le_engine_destroy(e);
}

static void run_bounce_tests(void) {
  test_bounce_into_empty_destination();
  test_bounce_replaces_and_restores();
  test_bounce_phase_continues();
  test_bounce_mode_fit_and_reclock();
  test_bounce_refusals_and_history();
  test_bounce_export_cut();
  test_bounce_abandoned_by_configure();
  test_bounce_pins_slots_in_flight();
  test_bounce_layer_on_top_undoes_first();
  test_bounce_topology_grows_playing_destination();
  test_bounce_names_its_image();
  test_bounce_unapplied_at_reopen_drops_track();
}
