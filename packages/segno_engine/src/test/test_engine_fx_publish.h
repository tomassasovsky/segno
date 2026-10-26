/* Cheap publishes (#887 part 4): a recipe resets only the slots that hold a
 * different entry than before. Included by test_engine_core.c. */

/* A monitor whose input is 1 for the first block and silent after: the
 * impulse a delay or reverb on its chain rings with. */
static le_engine* pub_engine(void) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 2, 1000) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 3) == LE_OK);
  return e;
}

static float pub_block(le_engine* e, float input) {
  float in[64];
  float out[128];
  for (int i = 0; i < 64; ++i) in[i] = input;
  le_engine_process(e, out, in, 64);
  float peak = 0.0f;
  for (int i = 0; i < 128; ++i) peak = fmaxf(peak, fabsf(out[i]));
  return peak;
}

/* One reverb on the monitor, fully wet, with identity [id]. */
static void pub_recipe(le_fx_recipe* r, uint32_t id, float size) {
  memset(r, 0, sizeof(*r));
  r->count = 1;
  r->enabled = 1;
  r->type[0] = LE_FX_REVERB;
  r->slot_enabled[0] = 1;
  r->level[0] = 1.0f;
  r->params[0][0] = size;
  r->params[0][1] = 0.2f;
  r->params[0][2] = 1.0f; /* all wet: the output is the tail */
  r->instance[0] = id;
}

/* The tail a reverb holds keeps sounding through a publish that keeps the
 * entry (same identity, same type) and changes only its settings, and stops
 * at one that puts a different entry there or carries no identity. */
static void test_fx_publish_keeps_unchanged_entries(void) {
  printf("test_fx_publish_keeps_unchanged_entries\n");
  for (int mode = 0; mode < 3; ++mode) {
    le_engine* e = pub_engine();
    le_fx_recipe r;
    pub_recipe(&r, 7, 0.9f);
    CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 1, &r) == LE_OK);
    pub_block(e, 0.0f); /* lands */
    pub_block(e, 1.0f); /* one loud block */
    for (int b = 0; b < 40; ++b) pub_block(e, 0.0f);
    CHECK(pub_block(e, 0.0f) > 1e-3f); /* ringing */
    /* 0: the same entry, a new size; 1: another entry; 2: no identity. */
    pub_recipe(&r, mode == 1 ? 8u : mode == 2 ? 0u : 7u, 0.95f);
    CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 2, &r) == LE_OK);
    const float after = pub_block(e, 0.0f);
    if (mode == 0) {
      CHECK(after > 1e-3f); /* the tail went on */
    } else {
      CHECK(after == 0.0f); /* reset: nothing was fed since */
    }
    le_engine_destroy(e);
  }
}

/* Entry [s] of [r]: a drive at 1x pre-gain and output [level], enabled, with
 * identity [id]. At the small input the test plays, a drive at level 1 is
 * all but the identity, so an entry leaving or moving changes nothing
 * audible; a drive at level 0 mutes, so arriving at full in one sample steps
 * the output to silence. */
static void arrival_drive(le_fx_recipe* r, int s, uint32_t id, float level) {
  r->type[s] = LE_FX_DRIVE;
  r->slot_enabled[s] = 1;
  r->level[s] = 1.0f;
  r->params[s][0] = 0.0f;
  r->params[s][1] = level;
  r->instance[s] = id;
}

#define ARRIVAL_INPUT 0.01f

/* The largest sample-to-sample change on output 0 over [blocks] blocks of a
 * constant ARRIVAL_INPUT, starting from [*last] (updated to the final value). */
static float arrival_max_step(le_engine* e, int blocks, float* last) {
  float in[64];
  float out[128];
  for (int i = 0; i < 64; ++i) in[i] = ARRIVAL_INPUT;
  float worst = 0.0f;
  for (int b = 0; b < blocks; ++b) {
    le_engine_process(e, out, in, 64);
    for (int i = 0; i < 64; ++i) {
      worst = fmaxf(worst, fabsf(out[i * 2] - *last));
      *last = out[i * 2];
    }
  }
  return worst;
}

/* A new entry fades in through the 5 ms enable ramp wherever it lands (#1452
 * review), even on a slot whose previous occupant was enabled and held no
 * tail: 0, a pedal appended into a rack that is not last, which moves the
 * enabled entry that stood there one slot on, past the old chain's end; 1, a
 * re-added rack, a new instance on the same slot; 2, a pedal added back onto
 * a slot an enabled entry left when the chain shrank, whose enabled bit the
 * departure must clear. A step to silence in one sample is a click. */
static void test_fx_publish_new_entry_ramps_in(void) {
  printf("test_fx_publish_new_entry_ramps_in\n");
  for (int mode = 0; mode < 3; ++mode) {
    le_engine* e = pub_engine();
    le_fx_recipe r;
    memset(&r, 0, sizeof(r));
    r.enabled = 1;
    r.count = mode == 1 ? 1 : 2;
    arrival_drive(&r, 0, 1, 1.0f);
    if (mode != 1) arrival_drive(&r, 1, 2, 1.0f);
    CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 1, &r) == LE_OK);
    float last = 0.0f;
    arrival_max_step(e, 40, &last); /* lands and settles */
    CHECK(last > 0.9f * ARRIVAL_INPUT); /* the drives pass the signal */
    if (mode == 2) {
      /* The chain shrinks: slot 1's entry leaves. */
      r.count = 1;
      CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 2, &r) ==
            LE_OK);
      arrival_max_step(e, 40, &last);
    }
    memset(&r, 0, sizeof(r));
    r.enabled = 1;
    if (mode == 2) {
      /* A new muting pedal on the slot the old entry left. */
      r.count = 2;
      arrival_drive(&r, 0, 1, 1.0f);
      arrival_drive(&r, 1, 3, 0.0f);
    } else if (mode == 0) {
      /* Slot 1 takes a new muting pedal; the old slot 1 moves to slot 2. */
      r.count = 3;
      arrival_drive(&r, 0, 1, 1.0f);
      arrival_drive(&r, 1, 3, 0.0f);
      arrival_drive(&r, 2, 2, 1.0f);
    } else {
      /* The same slot, a new instance that mutes. */
      r.count = 1;
      arrival_drive(&r, 0, 4, 0.0f);
    }
    CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 3, &r) == LE_OK);
    const float step = arrival_max_step(e, 40, &last);
    /* A 5 ms ramp at 48 kHz moves 1 / 240 of the swing per sample; arriving
     * at full moves all of it in one. */
    CHECK(step < ARRIVAL_INPUT / 50.0f);
    CHECK(fabsf(last) < 1e-7f); /* and it did arrive */
    le_engine_destroy(e);
  }
}

static void run_fx_publish_tests(void) {
  test_fx_publish_keeps_unchanged_entries();
  test_fx_publish_new_entry_ramps_in();
}
