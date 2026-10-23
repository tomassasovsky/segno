/* The Dub Rack's parallel paths (#1430): Amb-Verb on one path, Doubler,
 * Dub Delay and Dub-Verb on the other, each carrying its own dry, summed by
 * the Amb-Dub Mix law. Included by test_engine_core.c after the reverb
 * tests.
 *
 * The rack under test is the Dub Rack's order without the doubler: slot 0
 * the Dub Delay (wet only), slot 1 the Dub-Verb, slot 2 the Amb-Verb, all
 * three on their paths, and slot 3 a passthrough carrying the rack's last
 * edge, standing in for the compressor and EQ (on, so the rack is on). */

#define RP_SR 48000
#define RP_N 4

typedef struct rp_rack {
  le_fx_state* fx;
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t on[LE_FX_MAX];
  uint32_t clock;
} rp_rack;

/* A fresh rack at Amb-Dub Mix [m] with the slots in [on] engaged (bit s for
 * slot s), each settled where it starts. */
static void rp_open(rp_rack* k, float m, int on) {
  memset(k, 0, sizeof(*k));
  k->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  CHECK(k->fx != NULL);
  const int32_t types[RP_N] = {LE_FX_DELAY, LE_FX_DUB_VERB, LE_FX_AMB_VERB,
                               LE_FX_NONE};
  const int32_t rack[RP_N] = {LE_FX_RACK_FIRST | LE_FX_RACK_DUB_PATH,
                              LE_FX_RACK_DUB_PATH, LE_FX_RACK_AMB_PATH,
                              LE_FX_RACK_LAST};
  for (int s = 0; s < LE_FX_MAX; ++s) {
    k->types[s] = LE_FX_NONE;
    k->fx->chan[s] = (le_fx_chan){LE_FX_CHAN_IN_STEREO, LE_FX_CHAN_OUT_STEREO,
                                  1.0f, 1.0f, 1.0f, 0};
  }
  for (int s = 0; s < RP_N; ++s) {
    k->types[s] = types[s];
    k->fx->chan[s].rack = rack[s];
    k->on[s] = (on >> s) & 1;
    le_fx_entry_reset(k->fx, s);
    if (types[s] != LE_FX_NONE) {
      CHECK(le_fx_prepare(k->fx, s, types[s], RP_SR) == LE_OK);
    }
    for (int q = 0; q < le_fx_param_count(types[s]); ++q) {
      le_fx_param_desc d;
      CHECK(le_fx_param_info(types[s], q, &d) == LE_OK);
      k->params[s][q] = d.def;
    }
    le_fx_enable_seed_at(k->fx, s, k->on[s]);
  }
  k->fx->chan_any = 1;
  k->params[0][0] = 0.25f; /* a 250 ms echo */
  k->params[0][1] = 0.0f;  /* one of it */
  k->params[0][2] = 1.0f;  /* echoes only, as the Dub Rack's */
  k->params[2][2] = m;
  k->fx->clocked = 1;
}

static void rp_close(rp_rack* k) {
  le_fx_state_free_buffers(k->fx);
  free(k->fx);
}

/* [n] samples of [in] (both channels) through the rack; the left output to
 * [out]. */
static void rp_run(rp_rack* k, const float* in, float* out, int n) {
  for (int i = 0; i < n; ++i) {
    k->fx->clock = k->clock++;
    float l = in[i];
    float r = in[i];
    fx_apply_chain(k->fx, RP_SR, RP_SR, &l, &r, RP_N, k->types, k->params,
                   k->on);
    out[i] = l;
  }
}

/* The left output for a constant [x] once settled, at mix [m] with [on]. */
static float rp_settled(float m, int on, float x) {
  rp_rack k;
  rp_open(&k, m, on);
  const int n = RP_SR / 10;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = x;
  rp_run(&k, in, out, n);
  const float y = out[n - 1];
  free(in);
  free(out);
  rp_close(&k);
  return y;
}

/* With every pedal off but the rack on, the two dry signals sum by the
 * law: the measured dry gain against m (#891), to what the m read-out's
 * 0.003 moves the gain by there (the law's slope times 0.003). */
static void test_rack_paths_dry_law(void) {
  printf("test_rack_paths_dry_law\n");
  const float m[] = {0.0f,   0.055f, 0.106f, 0.206f, 0.303f, 0.403f, 0.600f,
                     0.701f, 0.797f, 0.898f, 0.947f, 1.0f};
  const float measured[] = {1.0000f, 1.0125f, 1.0458f, 1.1714f,
                            1.3697f, 1.6529f, 1.9576f, 1.8368f,
                            1.6400f, 1.3600f, 1.1900f, 1.0000f};
  for (int i = 0; i < (int)(sizeof(m) / sizeof(m[0])); ++i) {
    const float g = rp_settled(m[i], 1 << 3, 0.25f) / 0.25f;
    const float slope = 4.0f * fabsf(2.0f * m[i] - 1.0f);
    CHECK(fabsf(g - measured[i]) < 0.003f * slope + 0.002f);
  }
  /* The Dub Rack's default: 1.64 at 40 %, +4.3 dB. */
  CHECK(fabsf(rp_settled(0.4f, 1 << 3, 0.25f) - 0.41f) < 1e-6f);
}

/* With every entry off the rack is off, and it hands on its input exactly,
 * whatever the mix. */
static void test_rack_paths_off_is_passthrough(void) {
  printf("test_rack_paths_off_is_passthrough\n");
  CHECK(rp_settled(0.4f, 0, 0.3f) == 0.3f);
  CHECK(rp_settled(0.5f, 0, -0.7f) == -0.7f);
}

/* The Dub Delay passes no dry, so with it alone on only the Amb path's dry
 * is left at lag 0, and its echo arrives at D(m) times the delay's own echo
 * level (here 1; #891 saw 0.409 = 0.64 x the Looper X delay's 0.639 at
 * 40 %). */
static void test_rack_paths_dub_delay_alone(void) {
  printf("test_rack_paths_dub_delay_alone\n");
  const int n = RP_SR / 2;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* out = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 0.5f;
  rp_rack k;
  rp_open(&k, 0.4f, 1 | 1 << 3);
  rp_run(&k, in, out, n);
  rp_close(&k);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);
  int peak = 1;
  for (int i = 1; i < n; ++i) {
    if (fabsf(out[i]) > fabsf(out[peak])) peak = i;
  }
  CHECK(abs(peak - RP_SR / 4) <= 1);
  CHECK(fabsf(out[peak] - 0.64f * 0.5f) < 1e-5f);
  free(in);
  free(out);
}

/* Parallel, not series: with both reverbs on, the output is the Dub-alone
 * plus the Amb-alone output less the dry they both carry (#891: to -98 dB
 * at 0, 0.5 and 1). */
static void test_rack_paths_are_parallel(void) {
  printf("test_rack_paths_are_parallel\n");
  const int n = RP_SR / 2;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* dub = (float*)calloc((size_t)n, sizeof(float));
  float* amb = (float*)calloc((size_t)n, sizeof(float));
  float* both = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 0.5f;
  in[RP_SR / 8] = -0.25f;
  const float ms[] = {0.0f, 0.5f, 1.0f};
  for (int t = 0; t < 3; ++t) {
    rp_rack k;
    rp_open(&k, ms[t], 1 << 1 | 1 << 3);
    rp_run(&k, in, dub, n);
    rp_close(&k);
    rp_open(&k, ms[t], 1 << 2 | 1 << 3);
    rp_run(&k, in, amb, n);
    rp_close(&k);
    rp_open(&k, ms[t], 1 << 1 | 1 << 2 | 1 << 3);
    rp_run(&k, in, both, n);
    rp_close(&k);
    /* The law: A(m), D(m). */
    const float a =
        ms[t] <= 0.5f ? 1.0f : 1.0f - (2.0f * ms[t] - 1.0f) * (2.0f * ms[t] - 1.0f);
    const float d = ms[t] >= 0.5f ? 1.0f : 4.0f * ms[t] * ms[t];
    double err = 0.0, ref = 0.0;
    for (int i = 0; i < n; ++i) {
      /* Each alone carries the other path's dry at its gain. */
      const double want = dub[i] + amb[i] - (double)(a + d) * in[i];
      err += (both[i] - want) * (both[i] - want);
      ref += (double)both[i] * both[i];
    }
    CHECK(10.0 * log10(err / ref + 1e-30) < -90.0);
  }
  /* At 0 the Dub path is silent: Dub-Verb alone hands on the dry. */
  {
    rp_rack k;
    rp_open(&k, 0.0f, 1 << 1 | 1 << 3);
    rp_run(&k, in, dub, n);
    rp_close(&k);
    for (int i = 0; i < n; ++i) CHECK(dub[i] == in[i]);
  }
  free(in);
  free(dub);
  free(amb);
  free(both);
}

/* A moving Amb-Dub Mix glides: no sample steps by more than the enable
 * ramp's step times the signal. */
static void test_rack_paths_mix_glides(void) {
  printf("test_rack_paths_mix_glides\n");
  rp_rack k;
  rp_open(&k, 0.0f, 1 << 3);
  const int n = RP_SR / 20;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  for (int i = 0; i < n; ++i) in[i] = 0.5f;
  rp_run(&k, in, out, 1);
  k.params[2][2] = 0.5f; /* D jumps from 0 to 1 */
  rp_run(&k, in, out, n);
  const float step = 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * RP_SR);
  float prev = 0.5f;
  for (int i = 0; i < n; ++i) {
    CHECK(fabsf(out[i] - prev) <= 0.5f * step * 1.001f + 1e-7f);
    prev = out[i];
  }
  CHECK(fabsf(out[n - 1] - 1.0f) < 1e-6f);
  free(in);
  free(out);
  rp_close(&k);
}

/* The recipe takes one path per entry, not both. */
static void test_rack_paths_recipe_bits(void) {
  printf("test_rack_paths_recipe_bits\n");
  le_engine* e = make_configured_engine();
  le_fx_recipe r;
  memset(&r, 0, sizeof(r));
  r.count = 2;
  r.enabled = 1;
  r.type[0] = LE_FX_DUB_VERB;
  r.type[1] = LE_FX_AMB_VERB;
  for (int s = 0; s < 2; ++s) {
    r.slot_enabled[s] = 1;
    r.level[s] = 1.0f;
  }
  r.rack[0] = LE_FX_RACK_FIRST | LE_FX_RACK_DUB_PATH;
  r.rack[1] = LE_FX_RACK_LAST | LE_FX_RACK_AMB_PATH;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 0, 0, 1, &r) == LE_OK);
  drain(e);
  r.rack[1] = LE_FX_RACK_LAST | LE_FX_RACK_DUB_PATH | LE_FX_RACK_AMB_PATH;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 0, 0, 2, &r) ==
        LE_ERR_INVALID);
  r.rack[1] = 16;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_LANE, 0, 0, 3, &r) ==
        LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* The performance render routes the paths as the live chain does: each
 * entry's `rackPath` (manifest JSON) sets its path, so a Dub Rack with its
 * reverbs off and its last pedal on renders 1.64 of the loop at 40 %, and
 * 1 without the paths. */
static void test_rack_paths_in_the_stems(void) {
  printf("test_rack_paths_in_the_stems\n");
  char fx[1024];
  const char* shape =
      "[{\"type\": %d, \"enabled\": false, \"params\": [0.7, 0.2], "
      "%s\"rack\": {\"id\": \"r1\"}}, "
      "{\"type\": %d, \"enabled\": false, \"params\": [0.2, 0.4, 0.4], "
      "%s\"rack\": {\"id\": \"r1\"}}, "
      "{\"type\": 0, \"params\": [0.0], \"rack\": {\"id\": \"r1\"}}]";
  snprintf(fx, sizeof(fx), shape, LE_FX_DUB_VERB, "\"rackPath\": \"dub\", ",
           LE_FX_AMB_VERB, "\"rackPath\": \"amb\", ");
  CHECK(rk_stem_case("rack-paths", fx, 0.82f) < 1e-6f);
  snprintf(fx, sizeof(fx), shape, LE_FX_DUB_VERB, "", LE_FX_AMB_VERB, "");
  CHECK(rk_stem_case("rack-no-paths", fx, 0.5f) < 1e-6f);
}

/* A gain between Pre and Post that lands inside a section scales what the
 * section sums, as it would the signal in series: the result is the same as
 * the gain ahead of the section. */
static void test_rack_paths_gain_inside_a_section(void) {
  printf("test_rack_paths_gain_inside_a_section\n");
  for (int at = 0; at < 3; ++at) {
    rp_rack k;
    rp_open(&k, 0.4f, 1 << 3);
    float y = 0.0f;
    for (int i = 0; i < 100; ++i) {
      k.fx->clock = k.clock++;
      float l = 0.25f;
      float r = 0.25f;
      fx_apply_chain_with_gain(k.fx, RP_SR, RP_SR, &l, &r, RP_N, k.types,
                               k.params, k.on, at, 0.5f);
      y = l;
    }
    rp_close(&k);
    CHECK(fabsf(y - 0.25f * 1.64f * 0.5f) < 1e-6f);
  }
}

/* The rack switching off glides the dry boost away at the enable rate and
 * lands on the input exactly; a tail draining out of it keeps its path's
 * gain, as the same tail does with the rack on. */
static void test_rack_paths_rack_off(void) {
  printf("test_rack_paths_rack_off\n");
  {
    rp_rack k;
    rp_open(&k, 0.4f, 1 << 3);
    const int n = RP_SR / 50;
    float in[RP_SR / 50];
    float out[RP_SR / 50];
    for (int i = 0; i < n; ++i) in[i] = 0.25f;
    rp_run(&k, in, out, 10);
    CHECK(fabsf(out[9] - 0.41f) < 1e-6f);
    k.on[3] = 0;
    rp_run(&k, in, out, n);
    const float step = 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * RP_SR);
    float prev = 0.41f;
    for (int i = 0; i < n; ++i) {
      CHECK(out[i] <= prev + 1e-7f);
      CHECK(prev - out[i] <= 0.16f * step * 1.01f + 1e-7f);
      prev = out[i];
    }
    CHECK(out[n - 1] == 0.25f);
    rp_close(&k);
  }
  {
    /* The Dub-Verb at m 0.25 (D 0.25): an impulse, then the whole rack
     * off, against the rack left on. */
    const int n = RP_SR / 4;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* on = (float*)calloc((size_t)n, sizeof(float));
    float* off = (float*)calloc((size_t)n, sizeof(float));
    in[0] = 0.5f;
    rp_rack k;
    rp_open(&k, 0.25f, 1 << 1 | 1 << 3);
    rp_run(&k, in, on, n);
    rp_close(&k);
    rp_open(&k, 0.25f, 1 << 1 | 1 << 3);
    rp_run(&k, in, off, RP_SR / 100);
    k.on[1] = 0;
    k.on[3] = 0;
    rp_run(&k, in + RP_SR / 100, off + RP_SR / 100, n - RP_SR / 100);
    rp_close(&k);
    double err = 0.0, ref = 0.0;
    for (int i = RP_SR / 100; i < n; ++i) {
      err += (double)(off[i] - on[i]) * (off[i] - on[i]);
      ref += (double)on[i] * on[i];
    }
    CHECK(ref > 0.0);
    CHECK(10.0 * log10(err / ref + 1e-30) < -90.0);
    free(in);
    free(on);
    free(off);
  }
}

static void run_rack_path_tests(void) {
  test_rack_paths_dry_law();
  test_rack_paths_off_is_passthrough();
  test_rack_paths_dub_delay_alone();
  test_rack_paths_are_parallel();
  test_rack_paths_mix_glides();
  test_rack_paths_recipe_bits();
  test_rack_paths_in_the_stems();
  test_rack_paths_gain_inside_a_section();
  test_rack_paths_rack_off();
}
