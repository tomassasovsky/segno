/* A rack's output side (#1386): the level, output choice and placement on a
 * rack's LAST entry belong to the rack. They apply after that entry whatever
 * it is (a passthrough LE_FX_NONE module, or a bypassed effect) while any
 * entry of the rack is on, fade with the enable ramp, and leave the signal
 * untouched with every entry off or the chain off. Proven live, through the
 * wet cache, through the shared render recipe and through the stem render.
 *
 * The rack under test is two entries: a unity DRIVE (p0 = 0 -> 1x pre-gain,
 * p1 = 1 -> unity level, so it passes tanhf(x)) and a last entry carrying the
 * rack level. Level 0.5 keeps every value under the output limiter. */

#define RK_LEVEL 0.5f

/* The two-entry rack: entry 0 a unity DRIVE, entry 1 [tail] (LE_FX_NONE or
 * another unity DRIVE) carrying the rack level. [pre] entries are Pre. */
static le_fx_recipe rk_recipe(int32_t pre, int32_t on0, int32_t tail,
                              int32_t on1, int32_t chain_on) {
  le_fx_recipe r;
  memset(&r, 0, sizeof(r));
  r.count = 2;
  r.pre_count = pre;
  r.enabled = chain_on;
  r.type[0] = LE_FX_DRIVE;
  r.params[0][1] = 1.0f;
  r.slot_enabled[0] = on0;
  r.level[0] = 1.0f;
  r.rack[0] = LE_FX_RACK_FIRST;
  r.type[1] = tail;
  if (tail == LE_FX_DRIVE) r.params[1][1] = 1.0f;
  r.slot_enabled[1] = on1;
  r.level[1] = RK_LEVEL;
  r.rack[1] = LE_FX_RACK_LAST;
  return r;
}

static uint32_t g_rk_revision = 100;

static void rk_publish(le_engine* e, const le_fx_recipe* r) {
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 0, 0, ++g_rk_revision,
                                r) == LE_OK);
  drain(e);
}

/* A live engine (no cache) playing a constant 0.5 loop to outputs 0 and 1. */
static le_engine* rk_live_engine(void) {
  static float cap[4 * 64];
  float in[64];
  for (int i = 0; i < 64; ++i) in[i] = 0.5f;
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 4, 1000);
  le_engine_set_fx_cache_cap(e, 0);
  CHECK(le_engine_set_lane_output(e, 0, 0, 0x3) == LE_OK);
  drain(e);
  le_engine_record(e, 0);
  le_engine_process(e, cap, in, LOOP_N);
  le_engine_record(e, 0);
  drain(e);
  return e;
}

/* Pumps [frames] of silence (in 64-frame blocks), keeping output 0 and 1 of
 * each frame in out[2 * f], out[2 * f + 1] when [out] is not NULL. */
static void rk_pump(le_engine* e, int frames, float* out) {
  static float cap[4 * 64];
  float zin[64] = {0};
  for (int at = 0; at < frames;) {
    int n = frames - at;
    if (n > 64) n = 64;
    le_engine_process(e, cap, zin, (uint32_t)n);
    if (out != NULL) {
      for (int f = 0; f < n; ++f) {
        out[2 * (at + f)] = cap[4 * f];
        out[2 * (at + f) + 1] = cap[4 * f + 1];
      }
    }
    at += n;
  }
}

/* Settled output 0 and 1 for the rack [r], live. */
static void rk_live_settled(const le_fx_recipe* r, float* l, float* rr) {
  le_engine* e = rk_live_engine();
  rk_publish(e, r);
  float out[2 * 64];
  rk_pump(e, 1024, NULL); /* past every ramp */
  rk_pump(e, 64, out);
  *l = out[2 * 63];
  *rr = out[2 * 63 + 1];
  le_engine_destroy(e);
}

static void test_rack_level_reaches_a_rack_ending_in_a_passthrough(void) {
  printf("test_rack_level_reaches_a_rack_ending_in_a_passthrough\n");
  const le_fx_recipe r = rk_recipe(0, 1, LE_FX_NONE, 1, 1);
  float l = 0.0f;
  float rr = 0.0f;
  rk_live_settled(&r, &l, &rr);
  /* The level rides an entry the engine has no effect for, and still lands. */
  CHECK(fabsf(l - tanhf(0.5f) * RK_LEVEL) < 1e-5f);
  CHECK(fabsf(rr - tanhf(0.5f) * RK_LEVEL) < 1e-5f);
  /* The same with the passthrough itself switched off. */
  const le_fx_recipe off = rk_recipe(0, 1, LE_FX_NONE, 0, 1);
  rk_live_settled(&off, &l, &rr);
  CHECK(fabsf(l - tanhf(0.5f) * RK_LEVEL) < 1e-5f);
}

static void test_rack_level_holds_with_the_last_pedal_bypassed(void) {
  printf("test_rack_level_holds_with_the_last_pedal_bypassed\n");
  const le_fx_recipe r = rk_recipe(0, 1, LE_FX_DRIVE, 0, 1);
  float l = 0.0f;
  float rr = 0.0f;
  rk_live_settled(&r, &l, &rr);
  CHECK(fabsf(l - tanhf(0.5f) * RK_LEVEL) < 1e-5f);
  CHECK(fabsf(rr - tanhf(0.5f) * RK_LEVEL) < 1e-5f);
  /* And with the last pedal on, exactly what the per-entry path gave. */
  const le_fx_recipe on = rk_recipe(0, 1, LE_FX_DRIVE, 1, 1);
  rk_live_settled(&on, &l, &rr);
  CHECK(fabsf(l - tanhf(tanhf(0.5f)) * RK_LEVEL) < 1e-5f);
}

/* All pedals off, or the chain off: the rack is bit-exact passthrough — the
 * output equals an engine that never had a chain. */
static void test_rack_all_off_or_chain_off_is_bit_exact_dry(void) {
  printf("test_rack_all_off_or_chain_off_is_bit_exact_dry\n");
  /* Both engines pump past the publish's own enable ramps first: a recipe
   * that lands with entries off fades them out from the reset's settled-on
   * state, which is the recipe path's behaviour and not the rack rule. */
  le_engine* dry = rk_live_engine();
  static float want[2 * 2048];
  rk_pump(dry, 1024, NULL);
  rk_pump(dry, 2048, want);
  le_engine_destroy(dry);
  const le_fx_recipe cases[] = {
      rk_recipe(0, 0, LE_FX_NONE, 0, 1),
      rk_recipe(0, 0, LE_FX_DRIVE, 0, 1),
      rk_recipe(0, 1, LE_FX_DRIVE, 1, 0), /* the chain off */
      rk_recipe(0, 1, LE_FX_NONE, 1, 0),
  };
  for (size_t k = 0; k < sizeof(cases) / sizeof(cases[0]); ++k) {
    le_engine* e = rk_live_engine();
    rk_publish(e, &cases[k]);
    static float got[2 * 2048];
    rk_pump(e, 1024, NULL);
    rk_pump(e, 2048, got);
    CHECK(memcmp(want, got, sizeof(want)) == 0);
    le_engine_destroy(e);
  }
}

/* Switching the rack's last pedal on off flips the rack side on and off:
 * the level fades with the enable ramp, never in one step, and settles at
 * bit-exact dry. */
static void test_rack_output_side_ramps_without_a_step(void) {
  printf("test_rack_output_side_ramps_without_a_step\n");
  le_engine* e = rk_live_engine();
  const le_fx_recipe r = rk_recipe(0, 1, LE_FX_NONE, 1, 1);
  rk_publish(e, &r);
  rk_pump(e, 1024, NULL);
  static float out[2 * 1024];
  for (int pass = 0; pass < 2; ++pass) {
    /* pass 0: both pedals off (the rack off); pass 1: both back on. */
    CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, pass) == LE_OK);
    CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 1, pass) == LE_OK);
    drain(e);
    rk_pump(e, 1024, out);
    float worst = 0.0f;
    float prev = pass == 0 ? tanhf(0.5f) * RK_LEVEL : 0.5f;
    for (int f = 0; f < 1024; ++f) {
      const float d = fabsf(out[2 * f] - prev);
      if (d > worst) worst = d;
      prev = out[2 * f];
    }
    printf("  pass %d: largest per-frame move %.6f, %.6f -> %.6f\n", pass,
           (double)worst, (double)out[0], (double)out[2 * 1023]);
    /* The whole swing is ~0.27 over the 240-frame ramp; a step would move
     * it in one frame. */
    CHECK(worst < 0.005f);
    const float end = pass == 0 ? 0.5f : tanhf(0.5f) * RK_LEVEL;
    CHECK(fabsf(out[2 * 1023] - end) < 1e-6f);
  }
  /* Off again and settled: the dry loop, exactly. */
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 1, 0) == LE_OK);
  drain(e);
  rk_pump(e, 1024, out);
  CHECK(out[2 * 1023] == 0.5f);
  /* One pedal on is enough: the passthrough alone keeps the rack level. */
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 1, 1) == LE_OK);
  drain(e);
  rk_pump(e, 1024, out);
  CHECK(fabsf(out[2 * 1023] - 0.5f * RK_LEVEL) < 1e-6f);
  le_engine_destroy(e);
}

/* ---- the wet cache ---- */

/* A cached engine (A) and a live one (B) on the same 1.0 loop, the rack
 * [r] published at a loop top in Pre, A's print engaged; returns the largest
 * difference over one cached lap and A's last output in *last. */
static float rk_cache_parity(const le_fx_recipe* r, float* last,
                             int32_t* engaged) {
  le_engine* a = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
  le_engine* b = cache_engine(0);
  cache_record_loop(a, CACHE_LOOP, 1.0f);
  cache_record_loop(b, CACHE_LOOP, 1.0f);
  const int32_t need = (CACHE_LOOP - cache_master_pos(a)) % CACHE_LOOP;
  if (need > 0) {
    pump_frames(a, 0.0f, need);
    pump_frames(b, 0.0f, need);
  }
  rk_publish(a, r);
  rk_publish(b, r);
  le_lane_cache_info info;
  le_engine_get_lane_cache(a, 0, 0, &info); /* registers the key */
  pump_frames(a, 0.0f, CACHE_SETTLE);
  pump_frames(b, 0.0f, CACHE_SETTLE);
  cache_wait_state(a, 0, 0, LE_CACHE_CACHED, 3000);
  pump_frames(a, 0.0f, CACHE_LOOP - CACHE_SETTLE + 64);
  pump_frames(b, 0.0f, CACHE_LOOP - CACHE_SETTLE + 64);
  *engaged = cache_engaged(a, 0, 0);
  const int32_t n = 4096;
  float* oa = (float*)malloc((size_t)n * sizeof(float));
  float* ob = (float*)malloc((size_t)n * sizeof(float));
  pump_capture(a, 0.0f, n, oa);
  pump_capture(b, 0.0f, n, ob);
  const float diff = cache_max_diff(oa, ob, n, 0);
  *last = oa[n - 1];
  free(oa);
  free(ob);
  le_engine_destroy(a);
  le_engine_destroy(b);
  return diff;
}

static void test_rack_output_side_in_the_wet_cache(void) {
  printf("test_rack_output_side_in_the_wet_cache\n");
  float last = 0.0f;
  int32_t engaged = 0;
  /* Ends in a passthrough: the print carries the level, equal to live. */
  le_fx_recipe r = rk_recipe(2, 1, LE_FX_NONE, 1, 1);
  CHECK(rk_cache_parity(&r, &last, &engaged) <= CACHE_TOL);
  CHECK(engaged == 1);
  CHECK(fabsf(last - tanhf(1.0f) * RK_LEVEL) < 1e-4f);
  /* The last pedal bypassed, the first on. */
  r = rk_recipe(2, 1, LE_FX_DRIVE, 0, 1);
  CHECK(rk_cache_parity(&r, &last, &engaged) <= CACHE_TOL);
  CHECK(engaged == 1);
  CHECK(fabsf(last - tanhf(1.0f) * RK_LEVEL) < 1e-4f);
  /* Every pedal off: whatever the cache does, the lane plays the dry loop. */
  r = rk_recipe(2, 0, LE_FX_DRIVE, 0, 1);
  CHECK(rk_cache_parity(&r, &last, &engaged) <= CACHE_TOL);
  CHECK(last == 1.0f);
  r = rk_recipe(2, 1, LE_FX_NONE, 1, 0); /* the chain off */
  CHECK(rk_cache_parity(&r, &last, &engaged) <= CACHE_TOL);
  CHECK(last == 1.0f);
}

/* ---- the shared render recipe ---- */

/* Live from the loop top against the Cut render, sample for sample, for the
 * rack [r] on track 0's lane, with [settle] frames pumped first so every
 * live ramp has finished (the render starts settled). */
static void rk_render_parity(const le_fx_recipe* r, float* out_first) {
  le_engine* e = rr_engine();
  static float pcm[4000];
  for (int i = 0; i < 4000; ++i) pcm[i] = (float)((i * 5) % 11) / 11.0f - 0.4f;
  CHECK(le_engine_import_track(e, 0, pcm, 4000) == LE_OK);
  CHECK(le_engine_commit_session(e, 4000, 0) == LE_OK);
  drain(e);
  rk_publish(e, r);
  rr_pump(e, NULL, 2048, 64);
  CHECK(le_engine_play(e, 0) == LE_OK);
  static float live[2 * 3000];
  rr_pump(e, live, 3000, 64);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  static float out[2 * 4000];
  CHECK(rr_render(e, &q, out, 4000) == 4000);
  int mismatches = 0;
  /* From the end of the Play's fade-in (#1400), which the render does not
   * have; these racks hold no memory, so the fade ends where it ends. */
  for (int f = RR_SR / 100; f < 3000; ++f) {
    if (live[2 * f] != out[2 * f] || live[2 * f + 1] != out[2 * f + 1]) {
      mismatches++;
    }
  }
  CHECK(mismatches == 0);
  for (int f = 0; f < 8; ++f) out_first[f] = out[2 * f];
  le_engine_destroy(e);
}

static void test_rack_output_side_in_a_render(void) {
  printf("test_rack_output_side_in_a_render\n");
  float first[8];
  float dry[8];
  /* Post (live in the render) and Pre (printed by the render). */
  for (int32_t pre = 0; pre <= 2; pre += 2) {
    const le_fx_recipe none_tail = rk_recipe(pre, 1, LE_FX_NONE, 1, 1);
    rk_render_parity(&none_tail, first);
    const le_fx_recipe off = rk_recipe(pre, 0, LE_FX_DRIVE, 0, 1);
    rk_render_parity(&off, dry);
    /* The render of the rack that is off is the source itself... */
    for (int f = 0; f < 8; ++f) {
      const float src = (float)((f * 5) % 11) / 11.0f - 0.4f;
      CHECK(dry[f] == src);
      /* ...and the rack ending in a passthrough carries its level. */
      CHECK(fabsf(first[f] - tanhf(src) * RK_LEVEL) < 1e-6f);
    }
    const le_fx_recipe bypassed_tail = rk_recipe(pre, 1, LE_FX_DRIVE, 0, 1);
    rk_render_parity(&bypassed_tail, first);
    for (int f = 0; f < 8; ++f) {
      const float src = (float)((f * 5) % 11) / 11.0f - 0.4f;
      CHECK(fabsf(first[f] - tanhf(src) * RK_LEVEL) < 1e-6f);
    }
  }
}

/* ---- the stem render ---- */

/* Renders a 0.5 loop on channel 1 through the arm-time lane chain [effects]
 * (manifest JSON) and returns the wet stem's largest distance from [want]
 * (or from the dry stem when [want] < 0). */
static float rk_stem_case(const char* name, const char* effects, float want) {
  const char* dir = render_test_dir(name);
  const int32_t sr = 48000;
  const int32_t loop_len = 64;
  const uint64_t capture_frames = 960;
  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  float base[64];
  for (int i = 0; i < loop_len; ++i) base[i] = 0.5f;
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, loop_len, sr);
  char manifest[4096];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"followOutput\": false, \"captureMask\": 1, "
           "\"masterGain\": 1.0, \"limiterOn\": false, "
           "\"limiterCeiling\": 0.99, \"tracks\": [{\"channel\": 1, "
           "\"volume\": 1.0, \"muted\": false, \"lanes\": [{\"lane\": 0, "
           "\"deferred\": false, \"pcmRef\": \"loops/track1-lane0.wav\", "
           "\"effects\": %s}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
           sr, (unsigned long long)capture_frames, effects);
  test_write_manifest(dir, manifest);
  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr, LE_TEST_EVENTS_VERSION);
    fclose(lf);
  }
  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);
  static float dry[960];
  static float wet[960];
  CHECK(test_read_stem(dir, 1, dry, (int32_t)capture_frames) ==
        (int32_t)capture_frames);
  CHECK(test_read_wet_stem(dir, 1, wet, (int32_t)capture_frames) ==
        (int32_t)capture_frames);
  float worst = 0.0f;
  for (uint64_t f = 0; f < capture_frames; ++f) {
    const float d = fabsf(wet[f] - (want < 0.0f ? dry[f] : want));
    if (d > worst) worst = d;
  }
  le_engine_destroy(e);
  return worst;
}

static void test_rack_output_side_in_the_stems(void) {
  printf("test_rack_output_side_in_the_stems\n");
  char fx[1024];
  /* A rack ending in a passthrough: the stem carries the rack level. */
  snprintf(fx, sizeof(fx),
           "[{\"type\": %d, \"params\": [0.0, 1.0, 0.0, 0.0], "
           "\"rack\": {\"id\": \"r1\", \"name\": \"Rack\"}}, "
           "{\"type\": 0, \"params\": [0.0, 0.0, 0.0, 0.0], "
           "\"channels\": {\"level\": %f}, "
           "\"rack\": {\"id\": \"r1\", \"name\": \"Rack\"}}]",
           LE_FX_DRIVE, (double)RK_LEVEL);
  CHECK(rk_stem_case("rack-none-tail", fx, tanhf(0.5f) * RK_LEVEL) < 1e-6f);
  /* The last pedal bypassed, the first on: the level holds. */
  snprintf(fx, sizeof(fx),
           "[{\"type\": %d, \"params\": [0.0, 1.0, 0.0, 0.0], "
           "\"rack\": {\"id\": \"r1\"}}, "
           "{\"type\": %d, \"enabled\": false, "
           "\"params\": [0.0, 1.0, 0.0, 0.0], \"channels\": {\"level\": %f}, "
           "\"rack\": {\"id\": \"r1\"}}]",
           LE_FX_DRIVE, LE_FX_DRIVE, (double)RK_LEVEL);
  CHECK(rk_stem_case("rack-bypassed-tail", fx, tanhf(0.5f) * RK_LEVEL) <
        1e-6f);
  /* Every pedal off: the stem is the dry stem, bit for bit. */
  snprintf(fx, sizeof(fx),
           "[{\"type\": %d, \"enabled\": false, "
           "\"params\": [0.0, 1.0, 0.0, 0.0], \"rack\": {\"id\": \"r1\"}}, "
           "{\"type\": 0, \"enabled\": false, "
           "\"params\": [0.0, 0.0, 0.0, 0.0], \"channels\": {\"level\": %f}, "
           "\"rack\": {\"id\": \"r1\"}}]",
           LE_FX_DRIVE, (double)RK_LEVEL);
  CHECK(rk_stem_case("rack-all-off", fx, -1.0f) == 0.0f);
  /* A standalone entry's own level keeps applying to its own effect only. */
  snprintf(fx, sizeof(fx),
           "[{\"type\": %d, \"params\": [0.0, 1.0, 0.0, 0.0], "
           "\"channels\": {\"level\": %f}}]",
           LE_FX_DRIVE, (double)RK_LEVEL);
  CHECK(rk_stem_case("entry-level", fx, tanhf(0.5f) * RK_LEVEL) < 1e-6f);
  /* A rack balanced hard right: the stem is the mono fold-down of the pair,
   * not its silent left side. The pan law keeps the near side at unity. */
  snprintf(fx, sizeof(fx),
           "[{\"type\": %d, \"params\": [0.0, 1.0, 0.0, 0.0], "
           "\"rack\": {\"id\": \"r1\"}}, "
           "{\"type\": 0, \"params\": [0.0, 0.0, 0.0, 0.0], "
           "\"channels\": {\"placement\": 1.0}, \"rack\": {\"id\": \"r1\"}}]",
           LE_FX_DRIVE);
  CHECK(rk_stem_case("rack-balance-right", fx, 0.5f * tanhf(0.5f)) < 1e-6f);
}

/* ---- the chain itself, driven directly ---- */

/* A fresh offline state with every slot settled on and at its channel
 * defaults; [chan_any] set, as the snapshot sets it for a chain with a rack. */
static le_fx_state* rk_state(void) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  for (int s = 0; s < LE_FX_MAX; ++s) {
    le_fx_enable_seed_settled(fx, s);
    fx->chan[s] = (le_fx_chan){LE_FX_CHAN_IN_STEREO, LE_FX_CHAN_OUT_STEREO,
                               1.0f, 1.0f, 1.0f, 0};
  }
  fx->chan_any = 1;
  return fx;
}

static void rk_chan(le_fx_state* fx, int s, int32_t in, int32_t out,
                    float placement, float level, int32_t rack) {
  le_fx_chan* c = &fx->chan[s];
  c->in_mode = in;
  c->out_mode = out;
  le_pan_gains(placement, &c->gl, &c->gr);
  c->level = level;
  c->rack = rack;
}

static void rk_free(le_fx_state* fx) {
  le_fx_state_free_buffers(fx);
  free(fx);
}

/* Unity DRIVE parameters: tanhf(x) out. */
static void rk_unity_drive(float p[LE_FX_PARAMS]) {
  for (int k = 0; k < LE_FX_PARAMS; ++k) p[k] = 0.0f;
  p[1] = 1.0f;
}

/* Stomping a rack off at -20 dB leaves the tail draining out of its last
 * pedal at -20 dB, and the dry signal passing untouched — never the tail
 * jumping to unity. A rack of a unity DRIVE and a 100-frame DELAY (all wet,
 * feedback 0.6, level 0.1): twin A keeps the rack on and hears silence after
 * an impulse; twin B stomps the rack off before the first echo and, once the
 * stomp's ramp is over, is fed a constant 0.2. The delay is linear and B's
 * feed is silent while it drains, so B must be exactly 0.2 plus A's echoes. */
static void test_rack_off_tail_keeps_the_rack_level(void) {
  printf("test_rack_off_tail_keeps_the_rack_level\n");
  const int sr = 48000;
  int32_t types[LE_FX_MAX] = {LE_FX_DRIVE, LE_FX_DELAY};
  float params[LE_FX_MAX][LE_FX_PARAMS] = {{0}};
  rk_unity_drive(params[0]);
  params[1][0] = 100.0f / (float)(sr - 1);
  params[1][1] = 0.6f;
  params[1][2] = 1.0f;
  le_fx_state* a = rk_state();
  le_fx_state* b = rk_state();
  le_fx_state* both[2] = {a, b};
  for (int k = 0; k < 2; ++k) {
    rk_chan(both[k], 0, 0, 0, 0.0f, 1.0f, LE_FX_RACK_FIRST);
    rk_chan(both[k], 1, 0, 0, 0.0f, 0.1f, LE_FX_RACK_LAST);
    le_fx_entry_reset(both[k], 1);
    CHECK(le_fx_prepare(both[k], 1, LE_FX_DELAY, sr) == LE_OK);
  }
  const int32_t on[LE_FX_MAX] = {1, 1};
  const int32_t off[LE_FX_MAX] = {0, 0};
  float worst = 0.0f;
  float loudest = 0.0f;
  for (int f = 0; f < 4000; ++f) {
    float al = f == 0 ? 0.5f : 0.0f;
    float ar = al;
    fx_apply_chain(a, sr, sr, &al, &ar, 2, types, params, on);
    /* The dry 0.2 starts once the stomp's ramp is over: during the ramp a
     * delay is still fed a fading copy of its input, by design. */
    float bl = f == 0 ? 0.5f : f >= 50 + 300 ? 0.2f : 0.0f;
    float br = bl;
    fx_apply_chain(b, sr, sr, &bl, &br, 2, types, params, f >= 50 ? off : on);
    if (f >= 50 + 300) { /* past the stomp's ramp */
      const float d = fabsf(bl - (0.2f + al));
      if (d > worst) worst = d;
      if (fabsf(bl - 0.2f) > loudest) loudest = fabsf(bl - 0.2f);
    }
  }
  printf("  tail vs the rack-on twin: %.8f, loudest echo %.6f\n",
         (double)worst, (double)loudest);
  CHECK(worst < 1e-6f);
  /* The echoes are there, at the rack level: tanh(0.5) * 0.6^k * 0.1. */
  CHECK(loudest > 0.005f && loudest < 0.05f);
  rk_free(a);
  rk_free(b);
}

/* The rack's input choice is the rack's: it reaches the pedals whatever the
 * first pedal is, and an all-off rack passes the pair untouched. */
static void test_rack_input_choice_survives_a_bypassed_first_pedal(void) {
  printf("test_rack_input_choice_survives_a_bypassed_first_pedal\n");
  const int sr = 48000;
  for (int head = 0; head < 2; ++head) { /* a bypassed DRIVE, then NONE */
    int32_t types[LE_FX_MAX] = {head == 0 ? LE_FX_DRIVE : LE_FX_NONE,
                                LE_FX_DRIVE};
    float params[LE_FX_MAX][LE_FX_PARAMS] = {{0}};
    rk_unity_drive(params[0]);
    rk_unity_drive(params[1]);
    le_fx_state* fx = rk_state();
    rk_chan(fx, 0, LE_FX_CHAN_IN_LEFT, 0, 0.0f, 1.0f, LE_FX_RACK_FIRST);
    rk_chan(fx, 1, 0, 0, 0.0f, 1.0f, LE_FX_RACK_LAST);
    const int32_t en[LE_FX_MAX] = {0, 1};
    float l = 0.0f;
    float r = 0.0f;
    for (int f = 0; f < 600; ++f) {
      l = 0.5f;
      r = -0.25f;
      fx_apply_chain(fx, sr, sr, &l, &r, 2, types, params, en);
    }
    CHECK(fabsf(l - tanhf(0.5f)) < 1e-6f);
    CHECK(fabsf(r - tanhf(0.5f)) < 1e-6f); /* Left only, on both sides */
    const int32_t off[LE_FX_MAX] = {0, 0};
    for (int f = 0; f < 600; ++f) {
      l = 0.5f;
      r = -0.25f;
      fx_apply_chain(fx, sr, sr, &l, &r, 2, types, params, off);
    }
    CHECK(l == 0.5f && r == -0.25f);
    rk_free(fx);
  }
}

/* Output choice and placement on a rack that ends in a passthrough, and two
 * racks with a single effect between them, each keeping its own sides. */
static void test_rack_placement_mono_and_multi_rack(void) {
  printf("test_rack_placement_mono_and_multi_rack\n");
  const int sr = 48000;
  int32_t types[LE_FX_MAX] = {LE_FX_DRIVE, LE_FX_NONE};
  float params[LE_FX_MAX][LE_FX_PARAMS] = {{0}};
  rk_unity_drive(params[0]);
  const int32_t on[LE_FX_MAX] = {1, 1, 1, 1};
  /* Stereo out, balance hard right: the left side exactly silent. */
  le_fx_state* fx = rk_state();
  rk_chan(fx, 0, 0, 0, 0.0f, 1.0f, LE_FX_RACK_FIRST);
  rk_chan(fx, 1, 0, LE_FX_CHAN_OUT_STEREO, 1.0f, 0.5f, LE_FX_RACK_LAST);
  float l = 0.5f;
  float r = -0.25f;
  fx_apply_chain(fx, sr, sr, &l, &r, 2, types, params, on);
  CHECK(l == 0.0f);
  CHECK(fabsf(r - tanhf(-0.25f) * 0.5f) < 1e-6f);
  /* Mono out, panned hard left: the average, on the left only. */
  rk_chan(fx, 1, 0, LE_FX_CHAN_OUT_MONO, -1.0f, 1.0f, LE_FX_RACK_LAST);
  l = 0.5f;
  r = -0.25f;
  fx_apply_chain(fx, sr, sr, &l, &r, 2, types, params, on);
  CHECK(fabsf(l - 0.5f * (tanhf(0.5f) + tanhf(-0.25f))) < 1e-6f);
  CHECK(r == 0.0f);
  rk_free(fx);

  /* [rack A: DRIVE, NONE at 0.5] [a single DRIVE] [rack B: NONE at 0.25]. */
  int32_t chain[LE_FX_MAX] = {LE_FX_DRIVE, LE_FX_NONE, LE_FX_DRIVE,
                              LE_FX_NONE};
  float cp[LE_FX_MAX][LE_FX_PARAMS] = {{0}};
  rk_unity_drive(cp[0]);
  rk_unity_drive(cp[2]);
  fx = rk_state();
  rk_chan(fx, 0, 0, 0, 0.0f, 1.0f, LE_FX_RACK_FIRST);
  rk_chan(fx, 1, 0, 0, 0.0f, 0.5f, LE_FX_RACK_LAST);
  rk_chan(fx, 3, 0, 0, 0.0f, 0.25f, LE_FX_RACK_FIRST | LE_FX_RACK_LAST);
  const int32_t b_off[LE_FX_MAX] = {1, 1, 1, 0};
  for (int f = 0; f < 600; ++f) {
    l = 0.5f;
    r = 0.5f;
    fx_apply_chain(fx, sr, sr, &l, &r, 4, chain, cp, b_off);
  }
  const float want_a = tanhf(tanhf(0.5f) * 0.5f);
  CHECK(fabsf(l - want_a) < 1e-6f); /* rack B off: untouched */
  for (int f = 0; f < 600; ++f) {
    l = 0.5f;
    r = 0.5f;
    fx_apply_chain(fx, sr, sr, &l, &r, 4, chain, cp, on);
  }
  CHECK(fabsf(l - want_a * 0.25f) < 1e-6f); /* rack B on: its own level */
  rk_free(fx);
}

/* A rack made only of entries the engine has no effect for still runs: its
 * level lands with a pedal on, and it is dry with every pedal off — live and
 * in a render. */
static void test_rack_of_passthroughs_runs(void) {
  printf("test_rack_of_passthroughs_runs\n");
  le_fx_recipe r = rk_recipe(0, 1, LE_FX_NONE, 1, 1);
  r.type[0] = LE_FX_NONE;
  float l = 0.0f;
  float rr = 0.0f;
  rk_live_settled(&r, &l, &rr);
  CHECK(fabsf(l - 0.5f * RK_LEVEL) < 1e-6f);
  le_fx_recipe off = r;
  off.slot_enabled[0] = 0;
  off.slot_enabled[1] = 0;
  rk_live_settled(&off, &l, &rr);
  CHECK(l == 0.5f && rr == 0.5f);
  float first[8];
  for (int32_t pre = 0; pre <= 2; pre += 2) {
    r.pre_count = pre;
    rk_render_parity(&r, first);
    for (int f = 0; f < 8; ++f) {
      const float src = (float)((f * 5) % 11) / 11.0f - 0.4f;
      CHECK(fabsf(first[f] - src * RK_LEVEL) < 1e-6f);
    }
  }
}

/* The rack's crossfade keeps following its pedals while its channel handling
 * sits at the defaults: switched off at unity and then given a level, the
 * rack stays dry on every frame instead of fading that level out. */
static void test_rack_crossfade_follows_at_the_defaults(void) {
  printf("test_rack_crossfade_follows_at_the_defaults\n");
  le_engine* e = rk_live_engine();
  le_fx_recipe r = rk_recipe(0, 1, LE_FX_NONE, 1, 1);
  r.level[1] = 1.0f;
  rk_publish(e, &r);
  rk_pump(e, 1024, NULL);
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 1, 0) == LE_OK);
  drain(e);
  rk_pump(e, 1024, NULL);
  CHECK(le_engine_set_lane_fx_channels(e, 0, 0, 1, 0, 0, 0.0f, 0.5f) ==
        LE_OK);
  drain(e);
  static float out[2 * 1024];
  rk_pump(e, 1024, out);
  int moved = 0;
  for (int f = 0; f < 1024; ++f) {
    if (out[2 * f] != 0.5f || out[2 * f + 1] != 0.5f) moved++;
  }
  CHECK(moved == 0);
  /* And a pedal on brings the new level in. */
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, 1) == LE_OK);
  drain(e);
  rk_pump(e, 1024, out);
  CHECK(fabsf(out[2 * 1023] - tanhf(0.5f) * 0.5f) < 1e-6f);
  le_engine_destroy(e);
}

/* A recipe that moves a rack's last entry while audio plays keeps the rack's
 * level on every frame: the new last entry takes the rack's state at once. */
static void test_rack_edge_moving_while_playing(void) {
  printf("test_rack_edge_moving_while_playing\n");
  le_engine* e = rk_live_engine();
  const le_fx_recipe two = rk_recipe(0, 1, LE_FX_NONE, 1, 1);
  rk_publish(e, &two);
  rk_pump(e, 1024, NULL);
  /* Three entries: the old last one is inside the rack now. */
  le_fx_recipe three = two;
  three.count = 3;
  three.rack[1] = 0;
  three.level[1] = 1.0f;
  three.type[2] = LE_FX_NONE;
  three.slot_enabled[2] = 1;
  three.level[2] = RK_LEVEL;
  three.rack[2] = LE_FX_RACK_LAST;
  const float want = tanhf(0.5f) * RK_LEVEL;
  static float out[2 * 512];
  for (int k = 0; k < 2; ++k) {
    rk_publish(e, k == 0 ? &three : &two);
    rk_pump(e, 512, out);
    float worst = 0.0f;
    for (int f = 0; f < 512; ++f) {
      const float d = fabsf(out[2 * f] - want);
      if (d > worst) worst = d;
    }
    CHECK(worst < 1e-6f);
  }
  le_engine_destroy(e);
}

static void run_rack_output_tests(void) {
  test_rack_level_reaches_a_rack_ending_in_a_passthrough();
  test_rack_level_holds_with_the_last_pedal_bypassed();
  test_rack_all_off_or_chain_off_is_bit_exact_dry();
  test_rack_output_side_ramps_without_a_step();
  test_rack_output_side_in_the_wet_cache();
  test_rack_output_side_in_a_render();
  test_rack_output_side_in_the_stems();
  test_rack_off_tail_keeps_the_rack_level();
  test_rack_input_choice_survives_a_bypassed_first_pedal();
  test_rack_placement_mono_and_multi_rack();
  test_rack_of_passthroughs_runs();
  test_rack_crossfade_follows_at_the_defaults();
  test_rack_edge_moving_while_playing();
}
