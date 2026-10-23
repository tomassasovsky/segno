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

static void run_fx_publish_tests(void) {
  test_fx_publish_keeps_unchanged_entries();
}
