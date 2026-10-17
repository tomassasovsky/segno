/* test_engine_midi_in.h - the engine side of the native MIDI input sink
 * (#1228 Part 1; le_midi_port.h). Included by test_engine_core.c.
 *
 * The engine test does not link midi.c, so a capture is stood in for by a
 * struct that begins with a le_midi_sink, exactly the layout midi.c pins for
 * struct le_midi; the engine reaches both through that first member. */

typedef struct mi_fake_capture {
  le_midi_sink sink;
} mi_fake_capture;

static le_midi* mi_capture(mi_fake_capture* c) { return (le_midi*)(void*)c; }

static le_snapshot mi_snapshot(le_engine* e) {
  le_snapshot s;
  memset(&s, 0, sizeof(s));
  le_engine_get_snapshot(e, &s);
  return s;
}

static void mi_block(le_engine* e) {
  float out[64];
  process_const(e, 0.0f, 32, out);
}

static void test_midi_in_attach_drains_counts_and_masks(void) {
  printf("test_midi_in_attach_drains_counts_and_masks\n");
  le_engine* e = make_configured_engine();
  mi_fake_capture c;
  memset(&c, 0, sizeof(c));
  CHECK(le_engine_attach_midi_input(NULL, mi_capture(&c), 0) == LE_ERR_INVALID);
  CHECK(le_engine_attach_midi_input(e, NULL, 0) == LE_ERR_INVALID);
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), -1) == LE_ERR_INVALID);
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), LE_MAX_MIDI_PORTS) ==
        LE_ERR_INVALID);
  CHECK(le_engine_detach_midi_input(e, LE_MAX_MIDI_PORTS) == LE_ERR_INVALID);
  CHECK(mi_snapshot(e).midi_in_attached_mask == 0u);

  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 2) == LE_OK);
  CHECK(mi_snapshot(e).midi_in_attached_mask == 0x4u);
  CHECK(le_midi_sink_push(&c.sink, 0xF8, 0, 0, 1000000000ull) == 1);
  CHECK(le_midi_sink_push(&c.sink, 0x90, 60, 100, 1000000100ull) == 1);
  CHECK(le_midi_sink_push(&c.sink, 0xFC, 0, 0, 1000000200ull) == 1);
  /* Nothing is consumed before a block runs. */
  CHECK(mi_snapshot(e).midi_in_events == 0u);
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.midi_in_events == 3u);
  CHECK(s.midi_in_stale == 0u && s.midi_in_overflows == 0u);
  CHECK(atomic_load(&e->midi_ports[2].tail) == atomic_load(&e->midi_ports[2].head));

  CHECK(le_engine_detach_midi_input(e, 2) == LE_OK);
  CHECK(mi_snapshot(e).midi_in_attached_mask == 0u);
  CHECK(atomic_load(&c.sink.port) == NULL);
  CHECK(le_midi_sink_push(&c.sink, 0xF8, 0, 0, 1) == 0);
  CHECK(le_engine_detach_midi_input(e, 2) == LE_OK); /* idempotent */
  le_engine_destroy(e);
}

/* Events pushed under an earlier binding are never applied after a
 * reattach: they are dropped and counted (review H2). */
static void test_midi_in_reattach_drops_stale(void) {
  printf("test_midi_in_reattach_drops_stale\n");
  le_engine* e = make_configured_engine();
  mi_fake_capture a, b;
  memset(&a, 0, sizeof(a));
  memset(&b, 0, sizeof(b));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&a), 5) == LE_OK);
  CHECK(le_midi_sink_push(&a.sink, 0x90, 60, 100, 1) == 1);
  CHECK(le_midi_sink_push(&a.sink, 0x80, 60, 0, 2) == 1);
  /* Another capture takes port 5 before the audio thread drained it. */
  CHECK(le_engine_attach_midi_input(e, mi_capture(&b), 5) == LE_OK);
  CHECK(atomic_load(&a.sink.port) == NULL);
  CHECK(le_midi_sink_push(&a.sink, 0x90, 61, 100, 3) == 0);
  CHECK(le_midi_sink_push(&b.sink, 0x90, 62, 100, 4) == 1);
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.midi_in_events == 1u);
  CHECK(s.midi_in_stale == 2u);
  CHECK(s.midi_in_attached_mask == 0x20u);
  /* Moving b to port 0 leaves port 5 free and makes nothing stale twice. */
  CHECK(le_engine_attach_midi_input(e, mi_capture(&b), 0) == LE_OK);
  CHECK(mi_snapshot(e).midi_in_attached_mask == 0x1u);
  le_engine_destroy(e);
}

/* A full ring is reported once per block that finds the flag (review H3),
 * and a lost port once per edge. */
static void test_midi_in_overflow_and_lost_are_counted(void) {
  printf("test_midi_in_overflow_and_lost_are_counted\n");
  le_engine* e = make_configured_engine();
  mi_fake_capture c;
  memset(&c, 0, sizeof(c));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 1) == LE_OK);
  int pushed = 0;
  for (int i = 0; i < 300; ++i) pushed += le_midi_sink_push(&c.sink, 0xF8, 0, 0, 1);
  CHECK(pushed == (int)LE_MIDI_PORT_RING_CAP - 1);
  mi_block(e);
  le_snapshot s = mi_snapshot(e);
  CHECK(s.midi_in_events == LE_MIDI_PORT_RING_CAP - 1u);
  CHECK(s.midi_in_overflows == 1u);
  mi_block(e);
  CHECK(mi_snapshot(e).midi_in_overflows == 1u);

  CHECK(le_midi_sink_mark_lost(&c.sink) == 1);
  mi_block(e);
  CHECK(mi_snapshot(e).midi_in_lost == 1u);
  mi_block(e);
  CHECK(mi_snapshot(e).midi_in_lost == 1u); /* an edge, not a level */
  /* Reattaching clears lost; a second loss is a second edge. */
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 1) == LE_OK);
  mi_block(e);
  CHECK(le_midi_sink_mark_lost(&c.sink) == 1);
  mi_block(e);
  CHECK(mi_snapshot(e).midi_in_lost == 2u);
  le_engine_destroy(e);
}

/* Destroying the engine detaches every capture first, so none can write the
 * freed ports. */
static void test_midi_in_destroy_detaches(void) {
  printf("test_midi_in_destroy_detaches\n");
  le_engine* e = le_engine_create(); /* never configured: still attachable */
  mi_fake_capture a, b;
  memset(&a, 0, sizeof(a));
  memset(&b, 0, sizeof(b));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&a), 0) == LE_OK);
  CHECK(le_engine_attach_midi_input(e, mi_capture(&b), 7) == LE_OK);
  le_engine_destroy(e);
  CHECK(atomic_load(&a.sink.port) == NULL);
  CHECK(atomic_load(&b.sink.port) == NULL);
  CHECK(le_midi_sink_push(&a.sink, 0xF8, 0, 0, 1) == 0);
  CHECK(le_midi_sink_mark_lost(&b.sink) == 0);
}

/* ---- dispatch order (review of PR #1246, M1/L1/L2) ----
 * le_test_midi_dispatch_hook records what the drain hands its consumers, as
 * "E<status>" for an event, "G" for a gap, "L" for lost and "R" for a
 * binding change, per port. */
static char mi_log[2048];
static size_t mi_log_len;
static mi_fake_capture* mi_rebind_to;   /* bind this in the hook, once */
static le_engine* mi_rebind_engine;
static int mi_rebind_port;

static void mi_dispatch_log(le_engine* e, int port, int kind,
                            const le_midi_port_event* ev) {
  (void)e;
  char item[16];
  switch (kind) {
    case LE_MIDI_DISPATCH_EVENT:
      snprintf(item, sizeof(item), "%dE%02X", port, ev->status);
      break;
    case LE_MIDI_DISPATCH_GAP: snprintf(item, sizeof(item), "%dG", port); break;
    case LE_MIDI_DISPATCH_LOST: snprintf(item, sizeof(item), "%dL", port); break;
    default: snprintf(item, sizeof(item), "%dR", port); break;
  }
  if (mi_log_len + strlen(item) + 2 < sizeof(mi_log)) {
    mi_log_len += (size_t)snprintf(mi_log + mi_log_len,
                                   sizeof(mi_log) - mi_log_len, "%s%s",
                                   mi_log_len ? " " : "", item);
  }
  if (kind == LE_MIDI_DISPATCH_EVENT && mi_rebind_to != NULL) {
    /* A capture binds to this port while the drain is running and pushes. */
    mi_fake_capture* c = mi_rebind_to;
    mi_rebind_to = NULL;
    le_engine_attach_midi_input(mi_rebind_engine, mi_capture(c), mi_rebind_port);
    le_midi_sink_push(&c->sink, 0x80, 60, 0, 99);
  }
}

static void mi_log_reset(void) {
  mi_log_len = 0;
  mi_log[0] = '\0';
}

/* A loss is dispatched after the events read before it; a detach and a
 * close followed at once by an attach each give one binding edge. */
static void test_midi_in_dispatch_order(void) {
  printf("test_midi_in_dispatch_order\n");
  le_engine* e = make_configured_engine();
  le_test_midi_dispatch_hook = mi_dispatch_log;
  mi_fake_capture c;
  memset(&c, 0, sizeof(c));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 1) == LE_OK);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "1R") == 0); /* the attach */

  /* A Note On, then the device goes away, before one block. */
  le_midi_sink_push(&c.sink, 0x90, 60, 100, 1);
  le_midi_sink_mark_lost(&c.sink);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "1E90 1L") == 0);

  /* Close (unbind with the lost mark) and attach again inside one block:
   * the lost flag is clear again, but the binding edge is still seen. */
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 1) == LE_OK);
  mi_block(e);
  le_midi_sink_push(&c.sink, 0x90, 61, 100, 2); /* queued, then closed */
  le_midi_sink_unbind(&c.sink, 1);
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 1) == LE_OK);
  le_midi_sink_push(&c.sink, 0x90, 62, 100, 3);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "1R 1E90") == 0); /* the old Note On is stale */
  CHECK(mi_snapshot(e).midi_in_stale == 1u);

  /* A detach is an edge too. */
  CHECK(le_engine_detach_midi_input(e, 1) == LE_OK);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "1R") == 0);
  mi_log_reset();
  mi_block(e);
  CHECK(mi_log_len == 0u); /* once */

  le_test_midi_dispatch_hook = NULL;
  le_engine_destroy(e);
}

/* A gap is dispatched at its position: after the events queued before the
 * loss and before the ones that followed it. */
static void test_midi_in_gap_position(void) {
  printf("test_midi_in_gap_position\n");
  le_engine* e = make_configured_engine();
  le_test_midi_dispatch_hook = mi_dispatch_log;
  mi_fake_capture c;
  memset(&c, 0, sizeof(c));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&c), 0) == LE_OK);
  mi_block(e);
  le_midi_sink_push(&c.sink, 0xF8, 0, 0, 1);
  le_midi_sink_push(&c.sink, 0xF8, 0, 0, 2);
  le_midi_sink_mark_gap(&c.sink); /* an OS overrun here */
  le_midi_sink_push(&c.sink, 0xFA, 0, 0, 3);
  le_midi_sink_push(&c.sink, 0xFC, 0, 0, 4);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "0EF8 0EF8 0G 0EFA 0EFC") == 0);
  /* A gap with nothing queued after it comes last. */
  le_midi_sink_push(&c.sink, 0xF8, 0, 0, 5);
  le_midi_sink_mark_gap(&c.sink);
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "0EF8 0G") == 0);
  CHECK(mi_snapshot(e).midi_in_overflows == 2u);
  le_test_midi_dispatch_hook = NULL;
  le_engine_destroy(e);
}

/* A binding made while the drain runs is a rebind at the first event of the
 * new generation, not a stale drop (L1). */
static void test_midi_in_bind_during_drain(void) {
  printf("test_midi_in_bind_during_drain\n");
  le_engine* e = make_configured_engine();
  le_test_midi_dispatch_hook = mi_dispatch_log;
  mi_fake_capture a, b;
  memset(&a, 0, sizeof(a));
  memset(&b, 0, sizeof(b));
  CHECK(le_engine_attach_midi_input(e, mi_capture(&a), 2) == LE_OK);
  mi_block(e);
  le_midi_sink_push(&a.sink, 0x90, 60, 100, 1);
  mi_rebind_to = &b;
  mi_rebind_engine = e;
  mi_rebind_port = 2;
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "2E90 2R 2E80") == 0);
  CHECK(mi_snapshot(e).midi_in_stale == 0u);

  /* The device behind b goes away and a capture binds again while the same
   * drain runs: the loss was read for b's binding and is dispatched before
   * that binding's end, never after the new binding's events (PR #1246
   * review DL1). */
  le_midi_sink_push(&b.sink, 0x90, 61, 100, 2);
  le_midi_sink_mark_lost(&b.sink);
  mi_rebind_to = &a;
  mi_log_reset();
  mi_block(e);
  CHECK(strcmp(mi_log, "2E90 2L 2R 2E80") == 0);
  mi_log_reset();
  mi_block(e);
  CHECK(mi_log_len == 0u); /* the new binding is not lost */
  le_test_midi_dispatch_hook = NULL;
  le_engine_destroy(e);
}

static void run_midi_in_tests(void) {
  test_midi_in_attach_drains_counts_and_masks();
  test_midi_in_reattach_drops_stale();
  test_midi_in_overflow_and_lost_are_counted();
  test_midi_in_destroy_detaches();
  test_midi_in_dispatch_order();
  test_midi_in_gap_position();
  test_midi_in_bind_during_drain();
}
