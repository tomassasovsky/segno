/* test_engine_clock.h - MIDI clock receive in the engine (#1228 Part 2): the
 * source command and its receipt, the follower fed from the shared sink, tempo
 * ownership, loss, and the send gate. Included by test_engine_core.c after
 * test_engine_midi_in.h, whose fake capture it reuses.
 *
 * Time is a fake clock (le_engine_set_now_fn_for_test): each pulse is pushed
 * with the fake time as its timestamp, then a block runs at that time. */

static uint64_t ec_now_ns;
static uint64_t ec_now(void* ctx) {
  (void)ctx;
  return ec_now_ns;
}

static le_engine* ec_engine(mi_fake_capture* c, int32_t port) {
  le_engine* e = make_configured_engine();
  le_engine_set_now_fn_for_test(e, ec_now, NULL);
  ec_now_ns = 10000000000ull;
  memset(c, 0, sizeof(*c));
  CHECK(le_engine_attach_midi_input(e, mi_capture(c), port) == LE_OK);
  return e;
}

/* `n` pulses of a quarter-note clock at `quarter_bpm`, one block after each. */
static void ec_pulses(le_engine* e, mi_fake_capture* c, double quarter_bpm,
                      int n) {
  const double p = 60e9 / (quarter_bpm * 24.0);
  const uint64_t t0 = ec_now_ns;
  for (int i = 1; i <= n; ++i) {
    ec_now_ns = t0 + (uint64_t)llround(i * p);
    CHECK(le_midi_sink_push(&c->sink, 0xF8, 0, 0, ec_now_ns) == 1);
    mi_block(e);
  }
}

/* Silence: the fake clock moves `ms` on, one block per millisecond. */
static void ec_silence(le_engine* e, int ms) {
  for (int i = 0; i < ms; ++i) {
    ec_now_ns += 1000000ull;
    mi_block(e);
  }
}

static void test_clock_sync_follows_external_tempo(void) {
  printf("test_clock_sync_follows_external_tempo\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 3);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_INTERNAL);
  CHECK(s.clock_source_port == -1 && s.clock_receipt == 0u);

  CHECK(le_engine_set_clock_sync(e, 8, 0, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_sync(e, 3, 2, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_sync(e, 3, 0, 2) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_sync(NULL, 3, 0, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_sync(e, 3, 1, LE_CLOCK_LOSS_STOP_LOOPS) == LE_OK);
  /* The tempo setters refuse at once, before the callback applied it. */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_ERR_EXTERNAL_CLOCK);
  mi_block(e);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_WAITING);
  CHECK(s.clock_source_port == 3 && s.clock_follow_transport == 1);
  CHECK(s.clock_loss_policy == LE_CLOCK_LOSS_STOP_LOOPS);
  CHECK(s.clock_receipt == 1u && s.clock_result == LE_OK);
  CHECK(s.clock_bpm == 0.0f);

  /* Six intervals (seven pulses) to Synced. */
  ec_pulses(e, &c, 120.0, 6);
  CHECK(mi_snapshot(e).clock_state == LE_CLOCK_STATE_WAITING);
  ec_pulses(e, &c, 120.0, 1);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_SYNCED);
  CHECK(s.clock_bpm == 120.0f && s.clock_pulses == 7u);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_EXTERNAL);

  /* Local tempo and Tap are refused; a raw post is ignored by the callback. */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_ERR_EXTERNAL_CLOCK);
  CHECK(le_engine_tap_tempo(e) == LE_ERR_EXTERNAL_CLOCK);
  CHECK(le_engine_restore_tempo(e, 90.0f, LE_TEMPO_SOURCE_MANUAL) ==
        LE_ERR_EXTERNAL_CLOCK);
  CHECK(le_push(e, LE_CMD_SET_TEMPO, 0, 90.0f) == LE_OK);
  CHECK(le_push(e, LE_CMD_TAP_TEMPO, 0, 0.0f) == LE_OK);
  mi_block(e);
  CHECK(fabsf(mi_snapshot(e).tempo_bpm - 120.0f) < 0.01f);

  /* The master speeds up; the session tempo follows within a few beats. */
  ec_pulses(e, &c, 126.0, 24 * 6);
  s = mi_snapshot(e);
  CHECK(fabsf(s.tempo_bpm - 126.0f) < 0.05f);
  CHECK(s.clock_bpm == 126.0f);

  /* Use internal tempo: the last tempo stays, as MANUAL, and is editable. */
  CHECK(le_engine_set_clock_sync(e, -1, 1, LE_CLOCK_LOSS_STOP_LOOPS) == LE_OK);
  mi_block(e);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_INTERNAL && s.clock_receipt == 2u);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);
  CHECK(fabsf(s.tempo_bpm - 126.0f) < 0.05f);
  CHECK(s.clock_bpm == 0.0f && s.clock_pulses == 0u);
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  mi_block(e);
  CHECK(fabsf(mi_snapshot(e).tempo_bpm - 90.0f) < 0.01f);
  le_engine_destroy(e);
}

/* With Internal selected, a clock on an attached port changes nothing. */
static void test_clock_sync_internal_ignores_clock(void) {
  printf("test_clock_sync_internal_ignores_clock\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 2);
  CHECK(le_engine_set_tempo(e, 84.0f) == LE_OK);
  mi_block(e);
  ec_pulses(e, &c, 100.0, 48);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_INTERNAL);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);
  CHECK(fabsf(s.tempo_bpm - 84.0f) < 0.01f);
  CHECK(s.midi_in_events == 48u); /* drained all the same */
  le_engine_destroy(e);
}

/* Silence while Synced is Lost after 250 ms at 120 BPM, keeping the last
 * tempo; silence after a Stop is Waiting; a device going away is Lost at
 * once. */
static void test_clock_sync_loss_and_stop(void) {
  printf("test_clock_sync_loss_and_stop\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 0);
  CHECK(le_engine_set_clock_sync(e, 0, 0, 0) == LE_OK);
  mi_block(e);
  ec_pulses(e, &c, 120.0, 48);
  CHECK(mi_snapshot(e).clock_state == LE_CLOCK_STATE_SYNCED);
  ec_silence(e, 249);
  CHECK(mi_snapshot(e).clock_state == LE_CLOCK_STATE_SYNCED);
  ec_silence(e, 1);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_LOST && s.clock_losses == 1u);
  CHECK(s.clock_bpm == 120.0f);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_EXTERNAL);

  ec_pulses(e, &c, 120.0, 7);
  CHECK(mi_snapshot(e).clock_state == LE_CLOCK_STATE_SYNCED);
  CHECK(le_midi_sink_push(&c.sink, 0xFC, 0, 0, ec_now_ns) == 1);
  ec_silence(e, 300);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_WAITING && s.clock_losses == 1u);

  CHECK(le_midi_sink_push(&c.sink, 0xFA, 0, 0, ec_now_ns) == 1);
  ec_pulses(e, &c, 120.0, 7);
  CHECK(mi_snapshot(e).clock_state == LE_CLOCK_STATE_SYNCED);
  CHECK(le_midi_sink_mark_lost(&c.sink) == 1);
  mi_block(e);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_LOST && s.clock_losses == 2u);
  le_engine_destroy(e);
}

/* MIDI clock counts quarter notes; Segno's tempo counts the signature's
 * denominator: a 120 quarter-note clock in 6/8 is 240. */
static void test_clock_sync_denominator_unit(void) {
  printf("test_clock_sync_denominator_unit\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 1);
  CHECK(le_engine_set_time_signature(e, 6, 8) == LE_OK);
  CHECK(le_engine_set_clock_sync(e, 1, 0, 0) == LE_OK);
  mi_block(e);
  ec_pulses(e, &c, 120.0, 7);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_SYNCED);
  CHECK(fabsf(s.tempo_bpm - 240.0f) < 0.02f && s.clock_bpm == 240.0f);
  /* A 160 quarter-note clock in 6/8 (320) is out of range. */
  ec_silence(e, 300);
  ec_pulses(e, &c, 160.0, 40);
  s = mi_snapshot(e);
  CHECK(s.clock_state != LE_CLOCK_STATE_SYNCED && s.clock_out_of_range == 1);
  le_engine_destroy(e);
}

/* The source cannot change under a take; the callback rechecks a command
 * that got past the control thread. */
static void test_clock_sync_locked_while_recording(void) {
  printf("test_clock_sync_locked_while_recording\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 4);
  le_engine_record(e, 0);
  mi_block(e);
  CHECK(mi_snapshot(e).tracks[0].state == LE_TRACK_RECORDING);
  CHECK(le_engine_set_clock_sync(e, 4, 0, 0) == LE_ERR_SYNC_LOCKED);
  /* The same source with another loss policy is not a source change. */
  CHECK(le_engine_set_clock_sync(e, -1, 0, LE_CLOCK_LOSS_STOP_LOOPS) == LE_OK);
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_receipt == 1u && s.clock_result == LE_OK);
  CHECK(s.clock_loss_policy == LE_CLOCK_LOSS_STOP_LOOPS);
  /* A raw command past the control check is refused by the callback. */
  le_command raw = {.code = LE_CMD_SET_CLOCK_SYNC};
  raw.clock_sync.port = 4;
  raw.clock_sync.sequence = 7u;
  CHECK(le_push_cmd(e, raw) == LE_OK);
  mi_block(e);
  s = mi_snapshot(e);
  CHECK(s.clock_receipt == 7u && s.clock_result == LE_ERR_SYNC_LOCKED);
  CHECK(s.clock_state == LE_CLOCK_STATE_INTERNAL && s.clock_source_port == -1);
  le_engine_destroy(e);
}

/* Another capture on the source port starts the follower over; messages lost
 * to a full ring are counted as pulses, not skipped. */
static void test_clock_sync_rebind_and_gap(void) {
  printf("test_clock_sync_rebind_and_gap\n");
  mi_fake_capture c, other;
  le_engine* e = ec_engine(&c, 5);
  CHECK(le_engine_set_clock_sync(e, 5, 0, 0) == LE_OK);
  mi_block(e);
  ec_pulses(e, &c, 120.0, 7);
  CHECK(mi_snapshot(e).clock_pulses == 7u);
  /* A burst of 254 controller messages fills the ring; one pulse still fits
   * and the next three are lost (a gap). */
  const double p = 60e9 / (120.0 * 24.0);
  const uint64_t t0 = ec_now_ns;
  for (int i = 0; i < 254; ++i) le_midi_sink_push(&c.sink, 0xB0, 7, 100, t0);
  CHECK(le_midi_sink_push(&c.sink, 0xF8, 0, 0, t0 + (uint64_t)llround(p)) == 1);
  for (int i = 2; i <= 4; ++i) {
    CHECK(le_midi_sink_push(&c.sink, 0xF8, 0, 0, t0 + (uint64_t)llround(i * p)) == 0);
  }
  ec_now_ns = t0 + (uint64_t)llround(4 * p);
  mi_block(e);
  /* The next pulse arrives 6 ms late: alone, 4.3 periods would not read as
   * missed pulses; the gap mark says pulses were lost, so it counts 4. */
  ec_now_ns = t0 + (uint64_t)llround(5.3 * p);
  CHECK(le_midi_sink_push(&c.sink, 0xF8, 0, 0, ec_now_ns) == 1);
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.midi_in_overflows == 1u);
  CHECK(s.clock_state == LE_CLOCK_STATE_SYNCED);
  CHECK(s.clock_pulses == 7u + 5u);

  memset(&other, 0, sizeof(other));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&other), 5) == LE_OK);
  mi_block(e);
  s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_WAITING && s.clock_pulses == 0u);
  le_engine_destroy(e);
}

/* Send is closed while an external source owns the clock: received clock is
 * relayed (#1228 Part 6), never regenerated from Segno's transport. */
/* Pulses queued while nothing drained the ring (the device was stopped) are
 * older than the loss deadline and are not fed to the follower. */
static void test_clock_sync_drops_backlog(void) {
  printf("test_clock_sync_drops_backlog\n");
  mi_fake_capture c;
  le_engine* e = ec_engine(&c, 6);
  CHECK(le_engine_set_clock_sync(e, 6, 0, 0) == LE_OK);
  mi_block(e);
  const double p = 60e9 / (120.0 * 24.0);
  const uint64_t t0 = ec_now_ns;
  for (int i = 1; i <= 20; ++i) {
    le_midi_sink_push(&c.sink, 0xF8, 0, 0, t0 + (uint64_t)llround(i * p));
  }
  ec_now_ns = t0 + 2000000000ull; /* the first block runs 2 s later */
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.clock_state == LE_CLOCK_STATE_WAITING && s.clock_pulses == 0u);
  CHECK(s.midi_in_events >= 20u);
  le_engine_destroy(e);
}

static void test_clock_send_closed_under_external_source(void) {
  printf("test_clock_send_closed_under_external_source\n");
  le_engine* e = tg_make_engine_cap(1000, 100000);
  CHECK(le_engine_set_clock_send(e, 1) == LE_OK);
  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_clock_sync(e, 0, 0, 0) == LE_OK);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000);
  tg_advance(e, 4000);
  uint8_t bytes[256];
  CHECK(clock_drain(e, bytes, 256) == 0);
  le_engine_destroy(e);
}

static void run_engine_clock_tests(void) {
  test_clock_sync_follows_external_tempo();
  test_clock_sync_internal_ignores_clock();
  test_clock_sync_loss_and_stop();
  test_clock_sync_denominator_unit();
  test_clock_sync_locked_while_recording();
  test_clock_sync_rebind_and_gap();
  test_clock_sync_drops_backlog();
  test_clock_send_closed_under_external_source();
}
