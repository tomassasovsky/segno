/* synth_voice.h / synth_patch.c oracles (#1197 Part 1): the instrument voice
 * pool and the nineteen-patch table, tested as pure code before any engine
 * integration. Included from test_engine_core.c like test_engine_read_head.h.
 * SEGNO_SYNTH_TESTS_ONLY=1 runs only these. */

#include "synth_voice.h"

#define SYN_SR 48000

/* Large state outside the stack (a synth is about 30 KiB). */
static le_synth g_syn_a;
static le_synth g_syn_b;

static int32_t syn_patch(const char* id) {
  const int32_t i = le_synth_patch_find(id);
  CHECK(i >= 0);
  return i;
}

/* Renders `frames` of instruments 0..n_out-1 into out[] (NULL entries are
 * discarded), `block` frames per call, appending at `*pos`. */
static void syn_render(le_synth* s, float** out, int32_t n_out, int32_t frames,
                       int32_t block) {
  static float scratch[LE_SYNTH_MAX_INSTRUMENTS][512];
  float* bus[LE_SYNTH_MAX_INSTRUMENTS];
  for (int32_t b = 0; b < LE_SYNTH_MAX_INSTRUMENTS; ++b) bus[b] = scratch[b];
  int32_t done = 0;
  while (done < frames) {
    int32_t n = frames - done;
    if (n > block) n = block;
    if (n > 512) n = 512;
    le_synth_render(s, bus, LE_SYNTH_MAX_INSTRUMENTS, n);
    for (int32_t b = 0; b < n_out; ++b) {
      if (out[b] != NULL) memcpy(out[b] + done, scratch[b], sizeof(float) * (size_t)n);
    }
    done += n;
  }
}

/* Sign changes, counting 0 as positive. */
static int32_t syn_crossings(const float* x, int32_t n) {
  int32_t c = 0;
  for (int32_t i = 1; i < n; ++i) {
    if ((x[i - 1] < 0.0f) != (x[i] < 0.0f)) c++;
  }
  return c;
}

static float syn_peak(const float* x, int32_t n) {
  float p = 0.0f;
  for (int32_t i = 0; i < n; ++i) {
    if (fabsf(x[i]) > p) p = fabsf(x[i]);
  }
  return p;
}

static double syn_rms(const float* x, int32_t n) {
  double s = 0.0;
  for (int32_t i = 0; i < n; ++i) s += (double)x[i] * x[i];
  return sqrt(s / (double)n);
}

static void test_synth_patch_table(void) {
  printf("test_synth_patch_table\n");
  static const char* ids[LE_SYNTH_PATCHES] = {
      "piano", "keys",    "clav",   "organ", "reed",    "lead",
      "pad",   "pluck",   "bass",   "synth-bass",       "sub",
      "strings", "violin", "cello", "drums", "electronic-drums",
      "marimba", "vibes", "bells"};
  static const int32_t families[LE_SYNTH_PATCHES] = {
      LE_SYNTH_KEYS,   LE_SYNTH_KEYS,    LE_SYNTH_KEYS,    LE_SYNTH_ORGANS,
      LE_SYNTH_ORGANS, LE_SYNTH_SYNTHS,  LE_SYNTH_SYNTHS,  LE_SYNTH_SYNTHS,
      LE_SYNTH_BASS,   LE_SYNTH_BASS,    LE_SYNTH_BASS,    LE_SYNTH_STRINGS,
      LE_SYNTH_STRINGS, LE_SYNTH_STRINGS, LE_SYNTH_DRUMS,  LE_SYNTH_DRUMS,
      LE_SYNTH_PERCUSSION, LE_SYNTH_PERCUSSION, LE_SYNTH_PERCUSSION};
  static const float defaults[LE_SYNTH_PATCHES][3] = {
      {68, 72, 22}, {52, 60, 45}, {80, 18, 65}, {60, 35, 8},  {45, 12, 22},
      {72, 2, 25},  {42, 60, 72}, {62, 0, 12},  {35, 65, 18}, {43, 75, 24},
      {20, 20, 30}, {42, 55, 28}, {64, 30, 38}, {30, 45, 20}, {52, 40, 65},
      {75, 25, 80}, {35, 42, 0},  {50, 80, 35}, {80, 90, 0}};
  CHECK(le_synth_patch_count() == 19);
  for (int32_t i = 0; i < LE_SYNTH_PATCHES; ++i) {
    le_synth_patch_desc d;
    CHECK(le_synth_patch_info(i, &d) == LE_OK);
    CHECK(strcmp(d.id, ids[i]) == 0);
    CHECK(d.family == families[i]);
    for (int k = 0; k < 3; ++k) CHECK(d.defaults[k] == defaults[i][k]);
    CHECK(le_synth_patch_find(ids[i]) == i);
  }
  le_synth_patch_desc d;
  CHECK(le_synth_patch_info(-1, &d) == LE_ERR_INVALID);
  CHECK(le_synth_patch_info(19, &d) == LE_ERR_INVALID);
  CHECK(le_synth_patch_info(0, NULL) == LE_ERR_INVALID);
  CHECK(le_synth_patch_find("tuba") == -1);

  /* the seven families' parameters, with the mapping the voice uses */
  static const char* keys[LE_SYNTH_FAMILIES][3] = {
      {"brightness", "decay", "character"}, {"harmonics", "rotary", "release"},
      {"cutoff", "attack", "release"},      {"cutoff", "punch", "release"},
      {"brightness", "attack", "vibrato"},  {"tone", "decay", "body"},
      {"hardness", "decay", "tremolo"}};
  for (int32_t f = 0; f < LE_SYNTH_FAMILIES; ++f) {
    for (int32_t k = 0; k < 3; ++k) {
      le_synth_param_desc pd;
      CHECK(le_synth_param_info(f, k, &pd) == LE_OK);
      CHECK(strcmp(pd.key, keys[f][k]) == 0);
    }
  }
  le_synth_param_desc pd;
  CHECK(le_synth_param_info(LE_SYNTH_KEYS, 1, &pd) == LE_OK);
  CHECK(pd.unit == LE_SYNTH_UNIT_SECONDS && pd.at_min == 0.08f &&
        pd.at_max == 2.48f && pd.exponential == 0);
  CHECK(le_synth_param_info(LE_SYNTH_SYNTHS, 0, &pd) == LE_OK);
  CHECK(pd.unit == LE_SYNTH_UNIT_HERTZ && pd.at_min == 180.0f &&
        pd.at_max == 12600.0f && pd.exponential == 1);
  CHECK(le_synth_param_info(LE_SYNTH_STRINGS, 1, &pd) == LE_OK);
  CHECK(pd.unit == LE_SYNTH_UNIT_SECONDS && pd.at_min == 0.008f &&
        pd.at_max == 0.908f);
  CHECK(le_synth_param_info(LE_SYNTH_BASS, 1, &pd) == LE_OK);
  CHECK(pd.unit == LE_SYNTH_UNIT_PERCENT && pd.at_min == 0.0f &&
        pd.at_max == 100.0f);
  CHECK(le_synth_param_info(7, 0, &pd) == LE_ERR_INVALID);
  CHECK(le_synth_param_info(0, 3, &pd) == LE_ERR_INVALID);
  CHECK(le_synth_param_info(0, 0, NULL) == LE_ERR_INVALID);
  const le_synth_param* cutoff = le_synth_family_param(LE_SYNTH_BASS, 0);
  CHECK(le_synth_param_value(cutoff, 0.0f) == 180.0f);
  CHECK(fabsf(le_synth_param_value(cutoff, 100.0f) - 12600.0f) < 0.5f);
  CHECK(fabsf(le_synth_param_value(cutoff, 50.0f) - 1505.99f) < 0.05f);
  /* the pen's ready state: Electric keys decay 60 reads 1.52 s */
  CHECK(fabsf(le_synth_param_value(le_synth_family_param(LE_SYNTH_KEYS, 1),
                                   60.0f) -
              1.52f) < 1e-5f);
}

static void test_synth_arg_guards(void) {
  printf("test_synth_arg_guards\n");
  CHECK(le_synth_init(&g_syn_a, SYN_SR, 0, 1) == -1);
  CHECK(le_synth_init(&g_syn_a, SYN_SR, 65, 1) == -1);
  CHECK(le_synth_init(&g_syn_a, 0, 32, 1) == -1);
  CHECK(le_synth_init(&g_syn_a, SYN_SR, 32, 1) == 0);
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 60, 100) == -1); /* no patch */
  CHECK(le_synth_set_param(&g_syn_a, 0, 0, 50.0f) == -1);
  CHECK(le_synth_set_instrument(&g_syn_a, 0, 19) == -1);
  CHECK(le_synth_set_instrument(&g_syn_a, 8, 0) == -1);
  CHECK(le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub")) == 0);
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 128, 100) == -1);
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 60, 0) == -1);
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 60, 128) == -1);
  CHECK(le_synth_note_on(&g_syn_a, -1, 1, 60, 100) == -1);
  CHECK(le_synth_active(&g_syn_a, -1) == 0);
  CHECK(le_synth_set_param(&g_syn_a, 0, 3, 50.0f) == -1);
  CHECK(le_synth_set_param(&g_syn_a, 0, 0, 250.0f) == 0);
  CHECK(g_syn_a.inst[0].params[0] == 100.0f); /* clamped */
}

static void test_synth_pitch_and_exact_release(void) {
  printf("test_synth_pitch_and_exact_release\n");
  float* x = (float*)calloc(2 * SYN_SR, sizeof(float));
  float* out[1] = {x};
  /* sub, note 69: 440 Hz -> 880 sign changes per second */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 69, 127) == 0);
  syn_render(&g_syn_a, out, 1, SYN_SR, 64);
  const int32_t c69 = syn_crossings(x, SYN_SR);
  CHECK(c69 >= 878 && c69 <= 882);
  /* release 30 -> 0.08 + 0.30 * 2.4 = 0.80 s = 38400 frames */
  le_synth_note_off(&g_syn_a, 1);
  CHECK(le_synth_active(&g_syn_a, 0) == 1);
  syn_render(&g_syn_a, out, 1, 38400 - 480, 64); /* to T - 10 ms */
  CHECK(le_synth_active(&g_syn_a, 0) == 1);
  CHECK(syn_peak(x + 38400 - 960, 480) > 0.0f);
  syn_render(&g_syn_a, out, 1, 480 + 8, 64); /* to T + 8 frames */
  CHECK(le_synth_active(&g_syn_a, 0) == 0);
  syn_render(&g_syn_a, out, 1, 4800, 64);
  for (int32_t i = 0; i < 4800; ++i) CHECK(x[i] == 0.0f);

  /* note 81: 880 Hz -> 1760 */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  le_synth_note_on(&g_syn_a, 0, 1, 81, 127);
  syn_render(&g_syn_a, out, 1, SYN_SR, 64);
  const int32_t c81 = syn_crossings(x, SYN_SR);
  CHECK(c81 >= 1758 && c81 <= 1762);
  free(x);
}

static void test_synth_velocity_scales(void) {
  printf("test_synth_velocity_scales\n");
  const int32_t n = SYN_SR / 5;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  float* oa[1] = {a};
  float* ob[1] = {b};
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  le_synth_note_on(&g_syn_a, 0, 1, 57, 127);
  syn_render(&g_syn_a, oa, 1, n, 64);
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("sub"));
  le_synth_note_on(&g_syn_b, 0, 1, 57, 64);
  syn_render(&g_syn_b, ob, 1, n, 64);
  const float ratio = syn_peak(b, n) / syn_peak(a, n);
  CHECK(syn_peak(a, n) > 0.1f);
  CHECK(fabsf(ratio - 64.0f / 127.0f) < 0.01f * 64.0f / 127.0f);
  free(a);
  free(b);
}

static void test_synth_drum_kick_and_note_off(void) {
  printf("test_synth_drum_kick_and_note_off\n");
  float* a = (float*)calloc(SYN_SR, sizeof(float));
  float* b = (float*)calloc(SYN_SR, sizeof(float));
  float* oa[1] = {a};
  float* ob[1] = {b};
  /* drums: tone 52, decay 40 -> 1.04 s, a 0.15 + 1.04 * 0.55 = 0.722 s hit
   * sweeping 135 -> 47 Hz over its first half */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("drums"));
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 36, 127) == 0);
  syn_render(&g_syn_a, oa, 1, SYN_SR, 64);
  /* the first period: between the first two rising crossings */
  int32_t up[2] = {-1, -1}, k = 0;
  for (int32_t i = 1; i < SYN_SR && k < 2; ++i) {
    if (a[i - 1] < 0.0f && a[i] >= 0.0f) up[k++] = i;
  }
  CHECK(k == 2);
  /* the second period's frequency is the sweep's at its middle,
   * 135 * (47/135)^(t / 0.361): about 130.5 Hz at 11.5 ms */
  const float first_hz = (float)SYN_SR / (float)(up[1] - up[0]);
  const float mid_t = 0.5f * (float)(up[0] + up[1]) / (float)SYN_SR;
  const float sweep_hz = 135.0f * powf(47.0f / 135.0f, mid_t / 0.361f);
  CHECK(fabsf(first_hz - sweep_hz) < 2.0f);
  CHECK(first_hz > 125.0f); /* still near the 135 Hz start */
  /* 0.40 .. 0.70 s: the sweep has ended at 47 Hz */
  const int32_t c = syn_crossings(a + SYN_SR * 4 / 10, SYN_SR * 3 / 10);
  const float late_hz = (float)c / (2.0f * 0.3f);
  CHECK(late_hz >= 45.0f && late_hz <= 49.0f);
  /* the hit ends by itself */
  CHECK(le_synth_active(&g_syn_a, -1) == 0);
  for (int32_t i = SYN_SR * 74 / 100; i < SYN_SR; ++i) CHECK(a[i] == 0.0f);

  /* a note-off changes nothing */
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("drums"));
  le_synth_note_on(&g_syn_b, 0, 1, 36, 127);
  syn_render(&g_syn_b, ob, 1, SYN_SR / 10, 64);
  le_synth_note_off(&g_syn_b, 1);
  float* tail[1] = {b + SYN_SR / 10};
  syn_render(&g_syn_b, tail, 1, SYN_SR - SYN_SR / 10, 64);
  CHECK(memcmp(a, b, sizeof(float) * SYN_SR) == 0);

  /* an undefined drum note plays nothing */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("drums"));
  CHECK(le_synth_note_on(&g_syn_a, 0, 1, 60, 127) == -1);
  CHECK(le_synth_active(&g_syn_a, -1) == 0);
  syn_render(&g_syn_a, oa, 1, 4800, 64);
  for (int32_t i = 0; i < 4800; ++i) CHECK(a[i] == 0.0f);
  free(a);
  free(b);
}

static void test_synth_steal_prefers_same_instrument(void) {
  printf("test_synth_steal_prefers_same_instrument\n");
  const int32_t n = SYN_SR / 10;
  float* b1 = (float*)calloc((size_t)n, sizeof(float));
  float* b2 = (float*)calloc((size_t)n, sizeof(float));
  /* B's note is the oldest in the pool; A then fills it and asks for one more */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  le_synth_set_instrument(&g_syn_a, 1, syn_patch("sub"));
  le_synth_note_on(&g_syn_a, 1, 100, 45, 100);
  for (uint32_t o = 1; o <= 31; ++o) le_synth_note_on(&g_syn_a, 0, o, 40 + (int32_t)o, 100);
  CHECK(le_synth_active(&g_syn_a, -1) == 32);
  CHECK(le_synth_note_on(&g_syn_a, 0, 32, 80, 100) == 0);
  CHECK(le_synth_has_origin(&g_syn_a, 100));
  CHECK(!le_synth_has_origin(&g_syn_a, 1)); /* A's oldest went */
  CHECK(le_synth_active(&g_syn_a, 0) == 31);
  CHECK(le_synth_active(&g_syn_a, 1) == 1);
  CHECK(le_synth_fading(&g_syn_a) == 1);
  CHECK(g_syn_a.stolen == 1 && g_syn_a.stolen_hard == 0);
  float* oa[2] = {NULL, b1};
  syn_render(&g_syn_a, oa, 2, n, 64);
  CHECK(le_synth_fading(&g_syn_a) == 0);
  /* B's bus is exactly B alone */
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 1, syn_patch("sub"));
  le_synth_note_on(&g_syn_b, 1, 100, 45, 100);
  float* ob[2] = {NULL, b2};
  syn_render(&g_syn_b, ob, 2, n, 64);
  CHECK(memcmp(b1, b2, sizeof(float) * (size_t)n) == 0);

  /* released voices go before held ones */
  le_synth_init(&g_syn_a, SYN_SR, 4, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  for (uint32_t o = 1; o <= 4; ++o) le_synth_note_on(&g_syn_a, 0, o, 50 + (int32_t)o, 100);
  le_synth_note_off(&g_syn_a, 3);
  le_synth_note_on(&g_syn_a, 0, 5, 60, 100);
  CHECK(!le_synth_has_origin(&g_syn_a, 3));
  CHECK(le_synth_has_origin(&g_syn_a, 1));
  CHECK(le_synth_has_origin(&g_syn_a, 5));
  /* a released voice of ANOTHER instrument goes before this one's held */
  le_synth_init(&g_syn_a, SYN_SR, 2, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("sub"));
  le_synth_set_instrument(&g_syn_a, 1, syn_patch("sub"));
  le_synth_note_on(&g_syn_a, 0, 1, 50, 100);
  le_synth_note_on(&g_syn_a, 1, 2, 52, 100);
  le_synth_note_off(&g_syn_a, 2);
  le_synth_note_on(&g_syn_a, 0, 3, 54, 100);
  CHECK(le_synth_has_origin(&g_syn_a, 1));
  CHECK(!le_synth_has_origin(&g_syn_a, 2));
  free(b1);
  free(b2);
}

static void test_synth_steal_fades_to_exact_zero(void) {
  printf("test_synth_steal_fades_to_exact_zero\n");
  const int32_t n = 4800;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  float* oa[1] = {a};
  float* ob[1] = {b};
  /* a pool of one: B steals A, which fades over 3 ms (frames 0..143) */
  le_synth_init(&g_syn_a, SYN_SR, 1, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("keys"));
  le_synth_note_on(&g_syn_a, 0, 1, 60, 120);
  syn_render(&g_syn_a, oa, 1, n, 64);
  le_synth_note_on(&g_syn_a, 0, 2, 64, 120);
  CHECK(le_synth_fading(&g_syn_a) == 1);
  syn_render(&g_syn_a, oa, 1, n, 64);
  CHECK(le_synth_fading(&g_syn_a) == 0);
  /* the same B with nothing before it, at the same frame */
  le_synth_init(&g_syn_b, SYN_SR, 1, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("keys"));
  syn_render(&g_syn_b, ob, 1, n, 64);
  le_synth_note_on(&g_syn_b, 0, 2, 64, 120);
  syn_render(&g_syn_b, ob, 1, n, 64);
  CHECK(memcmp(a, b, sizeof(float) * 100) != 0); /* the fade is heard */
  CHECK(memcmp(a + 144, b + 144, sizeof(float) * (size_t)(n - 144)) == 0);
  /* a repeated strike from one origin replaces its voice the same way */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("keys"));
  le_synth_note_on(&g_syn_a, 0, 7, 60, 100);
  le_synth_note_on(&g_syn_a, 0, 7, 60, 100);
  CHECK(le_synth_active(&g_syn_a, 0) == 1);
  CHECK(le_synth_fading(&g_syn_a) == 1);
  /* a patch change fades the instrument and loads the new defaults */
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("keys")); /* same: kept */
  CHECK(le_synth_active(&g_syn_a, 0) == 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("piano"));
  CHECK(le_synth_active(&g_syn_a, 0) == 0);
  CHECK(le_synth_fading(&g_syn_a) == 2);
  CHECK(g_syn_a.inst[0].params[0] == 68.0f && g_syn_a.inst[0].params[1] == 72.0f &&
        g_syn_a.inst[0].params[2] == 22.0f);
  free(a);
  free(b);
}

static void test_synth_cutoff_parameter(void) {
  printf("test_synth_cutoff_parameter\n");
  const int32_t n = SYN_SR / 2;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  float* oa[1] = {a};
  float* ob[1] = {b};
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("lead"));
  le_synth_set_param(&g_syn_a, 0, 0, 100.0f);
  le_synth_note_on(&g_syn_a, 0, 1, 96, 127);
  syn_render(&g_syn_a, oa, 1, n, 64);
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("lead"));
  le_synth_set_param(&g_syn_b, 0, 0, 0.0f);
  le_synth_note_on(&g_syn_b, 0, 1, 96, 127);
  syn_render(&g_syn_b, ob, 1, n, 64);
  CHECK(syn_rms(a, n) > 0.05);
  CHECK(syn_rms(b, n) < 0.1 * syn_rms(a, n));
  free(a);
  free(b);
}

/* Every patch, twice with the same seed: byte-identical, finite, in range. */
static void test_synth_deterministic_and_bounded(void) {
  printf("test_synth_deterministic_and_bounded\n");
  const int32_t n = SYN_SR;
  float* a[8];
  float* b[8];
  for (int i = 0; i < 8; ++i) {
    a[i] = (float*)calloc((size_t)n, sizeof(float));
    b[i] = (float*)calloc((size_t)n, sizeof(float));
  }
  le_synth_init(&g_syn_a, SYN_SR, 32, 7);
  le_synth_init(&g_syn_b, SYN_SR, 32, 7);
  int all_same = 1, finite = 1, bounded = 1, any_sound = 1;
  for (int32_t round = 0; round < 3; ++round) {
    for (int32_t inst = 0; inst < 8; ++inst) {
      const int32_t patch = round * 8 + inst;
      le_synth* both[2] = {&g_syn_a, &g_syn_b};
      for (int s = 0; s < 2; ++s) {
        le_synth_set_instrument(both[s], inst, patch < LE_SYNTH_PATCHES ? patch : -1);
        if (patch >= LE_SYNTH_PATCHES) continue;
        /* one voice per bus, so the bound is a single voice's; drums play
         * their loudest piece here and every piece below */
        const int32_t note =
            le_synth_patch_at(patch)->family == LE_SYNTH_DRUMS ? 38 : 60;
        le_synth_note_on(both[s], inst, 10 + (uint32_t)inst, note, 127);
      }
    }
    for (int half = 0; half < 2; ++half) {
      syn_render(&g_syn_a, a, 8, n, 64);
      syn_render(&g_syn_b, b, 8, n, 64);
      for (int32_t inst = 0; inst < 8; ++inst) {
        const int32_t patch = round * 8 + inst;
        if (memcmp(a[inst], b[inst], sizeof(float) * (size_t)n) != 0) all_same = 0;
        for (int32_t i = 0; i < n; ++i) {
          if (!isfinite(a[inst][i])) finite = 0;
          if (fabsf(a[inst][i]) > 1.0f) bounded = 0;
        }
        if (half == 0 && patch < LE_SYNTH_PATCHES && syn_peak(a[inst], n) < 0.01f) {
          printf("  silent patch %s\n", le_synth_patch_at(patch)->id);
          any_sound = 0;
        }
      }
      for (uint32_t o = 10; o < 18; ++o) {
        le_synth_note_off(&g_syn_a, o);
        le_synth_note_off(&g_syn_b, o);
      }
    }
  }
  /* every drum piece of both kits, alone */
  static const int32_t pieces[] = {35, 36, 38, 39, 40, 42, 44};
  for (int32_t kit = 0; kit < 2; ++kit) {
    for (int32_t k = 0; k < 7; ++k) {
      le_synth* both[2] = {&g_syn_a, &g_syn_b};
      float* ob[2][1] = {{a[0]}, {b[0]}};
      for (int s = 0; s < 2; ++s) {
        le_synth_init(both[s], SYN_SR, 32, 7);
        le_synth_set_instrument(both[s], 0,
                                syn_patch(kit ? "electronic-drums" : "drums"));
        le_synth_note_on(both[s], 0, 1, pieces[k], 127);
        syn_render(both[s], ob[s], 1, n, 64);
      }
      if (memcmp(a[0], b[0], sizeof(float) * (size_t)n) != 0) all_same = 0;
      if (syn_peak(a[0], n) < 0.01f) any_sound = 0;
      for (int32_t i = 0; i < n; ++i) {
        if (!isfinite(a[0][i])) finite = 0;
        if (fabsf(a[0][i]) > 1.0f) bounded = 0;
      }
    }
  }
  CHECK(all_same);
  CHECK(finite);
  CHECK(bounded);
  CHECK(any_sound);
  /* the seed reaches the noise: another seed, another snare */
  float* c[1] = {a[0]};
  float* d[1] = {b[0]};
  le_synth_init(&g_syn_a, SYN_SR, 32, 7);
  le_synth_init(&g_syn_b, SYN_SR, 32, 8);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("drums"));
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("drums"));
  le_synth_note_on(&g_syn_a, 0, 1, 38, 127);
  le_synth_note_on(&g_syn_b, 0, 1, 38, 127);
  syn_render(&g_syn_a, c, 1, 4800, 64);
  syn_render(&g_syn_b, d, 1, 4800, 64);
  CHECK(memcmp(a[0], b[0], sizeof(float) * 4800) != 0);
  for (int i = 0; i < 8; ++i) {
    free(a[i]);
    free(b[i]);
  }
}

/* A full pool stolen in one burst still fades every victim (one fade slot per
 * pool voice), and the burst's notes all sound. */
static void test_synth_full_pool_burst_fades_all(void) {
  printf("test_synth_full_pool_burst_fades_all\n");
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("keys"));
  for (uint32_t o = 1; o <= 32; ++o) le_synth_note_on(&g_syn_a, 0, o, 40 + (int32_t)o, 100);
  for (uint32_t o = 33; o <= 64; ++o) {
    CHECK(le_synth_note_on(&g_syn_a, 0, o, 40 + (int32_t)(o - 32), 100) == 0);
  }
  CHECK(le_synth_active(&g_syn_a, 0) == 32);
  CHECK(le_synth_fading(&g_syn_a) == 32);
  CHECK(g_syn_a.stolen == 32);
  CHECK(g_syn_a.stolen_hard == 0);
  for (uint32_t o = 1; o <= 32; ++o) CHECK(!le_synth_has_origin(&g_syn_a, o));
  float* none[1] = {NULL};
  syn_render(&g_syn_a, none, 1, 145, 64);
  CHECK(le_synth_fading(&g_syn_a) == 0);
  CHECK(le_synth_active(&g_syn_a, 0) == 32);
}

/* Cut all sound fades voices where they are: the instrument's bus is exactly
 * silent 3 ms later, the other instrument keeps playing, and a note struck
 * while every slot is still fading takes the most finished one. */
static void test_synth_cut_fades_in_place(void) {
  printf("test_synth_cut_fades_in_place\n");
  const int32_t n = 4800;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  float* c = (float*)calloc((size_t)n, sizeof(float));
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("organ"));
  le_synth_set_instrument(&g_syn_a, 1, syn_patch("sub"));
  for (uint32_t o = 1; o <= 16; ++o) le_synth_note_on(&g_syn_a, 0, o, 48 + (int32_t)o, 100);
  le_synth_note_on(&g_syn_a, 1, 100, 40, 100);
  float* warm[2] = {NULL, NULL};
  syn_render(&g_syn_a, warm, 2, 960, 64);
  le_synth_cut(&g_syn_a, 0);
  CHECK(le_synth_active(&g_syn_a, 0) == 0);
  CHECK(le_synth_active(&g_syn_a, 1) == 1);
  CHECK(le_synth_fading(&g_syn_a) == 16);
  float* o2[2] = {a, b};
  syn_render(&g_syn_a, o2, 2, n, 64);
  CHECK(syn_peak(a, 144) > 0.0f); /* the fade is heard */
  for (int32_t i = 144; i < n; ++i) CHECK(a[i] == 0.0f);
  CHECK(le_synth_fading(&g_syn_a) == 0);
  CHECK(syn_peak(b, n) > 0.01f); /* the other instrument plays on */
  /* sub alone, same frames: its bus is unaffected by the cut */
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 1, syn_patch("sub"));
  for (uint32_t o = 1; o <= 16; ++o) g_syn_b.serial++; /* same start order */
  le_synth_note_on(&g_syn_b, 1, 100, 40, 100);
  float* w2[2] = {NULL, NULL};
  syn_render(&g_syn_b, w2, 2, 960, 64);
  float* o3[2] = {NULL, c};
  syn_render(&g_syn_b, o3, 2, n, 64);
  CHECK(memcmp(b, c, sizeof(float) * (size_t)n) == 0);
  /* cut everything, then strike while every slot fades */
  le_synth_init(&g_syn_a, SYN_SR, 2, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("organ"));
  le_synth_note_on(&g_syn_a, 0, 1, 60, 100);
  le_synth_note_on(&g_syn_a, 0, 2, 64, 100);
  le_synth_cut(&g_syn_a, -1);
  CHECK(le_synth_active(&g_syn_a, -1) == 0);
  CHECK(le_synth_note_on(&g_syn_a, 0, 3, 67, 100) == 0);
  CHECK(le_synth_active(&g_syn_a, -1) == 1);
  CHECK(g_syn_a.stolen_hard == 1);
  free(a);
  free(b);
  free(c);
}

/* The overload control: lowering the voice limit fades the excess in
 * stealing order and later notes steal at the limit. */
static void test_synth_voice_limit(void) {
  printf("test_synth_voice_limit\n");
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("pad"));
  CHECK(le_synth_set_voice_limit(&g_syn_a, 0) == -1);
  CHECK(le_synth_set_voice_limit(&g_syn_a, 33) == -1);
  for (uint32_t o = 1; o <= 16; ++o) le_synth_note_on(&g_syn_a, 0, o, 40 + (int32_t)o, 100);
  CHECK(le_synth_set_voice_limit(&g_syn_a, 8) == 0);
  CHECK(le_synth_active(&g_syn_a, -1) == 8);
  CHECK(le_synth_fading(&g_syn_a) == 8);
  for (uint32_t o = 1; o <= 8; ++o) CHECK(!le_synth_has_origin(&g_syn_a, o));
  for (uint32_t o = 9; o <= 16; ++o) CHECK(le_synth_has_origin(&g_syn_a, o));
  le_synth_note_on(&g_syn_a, 0, 17, 70, 100);
  CHECK(le_synth_active(&g_syn_a, -1) == 8);
  CHECK(!le_synth_has_origin(&g_syn_a, 9));
  CHECK(le_synth_set_voice_limit(&g_syn_a, 32) == 0);
  le_synth_note_on(&g_syn_a, 0, 18, 71, 100);
  CHECK(le_synth_active(&g_syn_a, -1) == 9);
}

/* A drum pad struck, released and struck again: both hits ring (the first is
 * not choked), and the first is exactly its solo render. A strike while the
 * pad is still down replaces the hit, as for any held voice. */
static void test_synth_drum_restrike_overlaps(void) {
  printf("test_synth_drum_restrike_overlaps\n");
  const int32_t n = SYN_SR / 2;
  float* both = (float*)calloc((size_t)n, sizeof(float));
  float* first = (float*)calloc((size_t)n, sizeof(float));
  float* second = (float*)calloc((size_t)n, sizeof(float));
  const int32_t gap = SYN_SR * 150 / 1000; /* 50 ms held + 100 ms released */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("drums"));
  le_synth_note_on(&g_syn_a, 0, 38, 38, 127);
  float* oa[1] = {both};
  syn_render(&g_syn_a, oa, 1, SYN_SR / 20, 64);
  le_synth_note_off(&g_syn_a, 38);
  float* ob[1] = {both + SYN_SR / 20};
  syn_render(&g_syn_a, ob, 1, gap - SYN_SR / 20, 64);
  CHECK(le_synth_note_on(&g_syn_a, 0, 38, 38, 127) == 0);
  CHECK(le_synth_fading(&g_syn_a) == 0); /* nothing choked */
  CHECK(le_synth_active(&g_syn_a, 0) == 2);
  float* oc[1] = {both + gap};
  syn_render(&g_syn_a, oc, 1, n - gap, 64);
  /* the same two hits rendered separately (same serials: same noise) */
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("drums"));
  le_synth_note_on(&g_syn_b, 0, 1, 38, 127);
  float* f1[1] = {first};
  syn_render(&g_syn_b, f1, 1, n, 64);
  le_synth_init(&g_syn_b, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_b, 0, syn_patch("drums"));
  g_syn_b.serial = 1;
  float* skip[1] = {NULL};
  syn_render(&g_syn_b, skip, 1, gap, 64);
  le_synth_note_on(&g_syn_b, 0, 2, 38, 127);
  float* f2[1] = {second + gap};
  syn_render(&g_syn_b, f2, 1, n - gap, 64);
  float worst = 0.0f;
  for (int32_t i = 0; i < n; ++i) {
    const float d = fabsf(both[i] - (first[i] + second[i]));
    if (d > worst) worst = d;
  }
  CHECK(worst < 1e-6f);
  CHECK(syn_peak(first + gap, SYN_SR / 10) > 0.01f); /* still ringing then */
  /* a strike while the pad is down replaces the held hit */
  le_synth_init(&g_syn_a, SYN_SR, 32, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("drums"));
  le_synth_note_on(&g_syn_a, 0, 38, 38, 127);
  le_synth_note_on(&g_syn_a, 0, 38, 38, 127);
  CHECK(le_synth_active(&g_syn_a, 0) == 1);
  CHECK(le_synth_fading(&g_syn_a) == 1);
  free(both);
  free(first);
  free(second);
}

/* More steals than fade slots within 3 ms: the most finished fade is
 * overwritten, without a fade, and counted. */
static void test_synth_fade_slot_overflow(void) {
  printf("test_synth_fade_slot_overflow\n");
  le_synth_init(&g_syn_a, SYN_SR, 64, 1);
  le_synth_set_instrument(&g_syn_a, 0, syn_patch("organ"));
  uint32_t o = 1;
  for (int i = 0; i < 64; ++i, ++o) le_synth_note_on(&g_syn_a, 0, o, 30 + i % 60, 90);
  float* none[1] = {NULL};
  /* A: 32 steals into slots 0..31; nearly finished 140 frames later */
  for (int i = 0; i < 32; ++i, ++o) le_synth_note_on(&g_syn_a, 0, o, 30 + i, 90);
  syn_render(&g_syn_a, none, 1, 140, 1);
  /* B: 32 steals into slots 32..63 */
  for (int i = 0; i < 32; ++i, ++o) le_synth_note_on(&g_syn_a, 0, o, 40 + i, 90);
  syn_render(&g_syn_a, none, 1, 10, 1); /* A ends: slots 0..31 free */
  /* C: 32 fresh steals into slots 0..31; B (32..63) is the most finished */
  for (int i = 0; i < 32; ++i, ++o) le_synth_note_on(&g_syn_a, 0, o, 50 + i, 90);
  CHECK(le_synth_fading(&g_syn_a) == 64);
  CHECK(g_syn_a.stolen_hard == 0);
  int fresh_before = 0;
  for (int i = 0; i < LE_SYNTH_FADE_SLOTS; ++i) fresh_before += g_syn_a.fades[i].fade == 1.0f;
  CHECK(fresh_before == 32);
  /* one more steal: no free fade slot */
  le_synth_note_on(&g_syn_a, 0, o, 90, 90);
  CHECK(g_syn_a.stolen_hard == 1);
  CHECK(g_syn_a.stolen == 32 * 3 + 1);
  int fresh = 0, older = 0;
  for (int i = 0; i < LE_SYNTH_FADE_SLOTS; ++i) {
    if (g_syn_a.fades[i].fade == 1.0f) fresh++; else older++;
  }
  CHECK(fresh == 33 && older == 31); /* one of B was overwritten, not C */
  for (int i = 0; i < 32; ++i) CHECK(g_syn_a.fades[i].fade == 1.0f);
}

/* Note 127 puts upper partials past Nyquist (bells' 5.4x is 67.7 kHz): they
 * fall silent instead of aliasing or running their phase away. */
static void test_synth_top_note_bounded(void) {
  printf("test_synth_top_note_bounded\n");
  const int32_t n = SYN_SR / 4;
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* oa[1] = {a};
  int ok = 1;
  for (int32_t patch = 0; patch < LE_SYNTH_PATCHES; ++patch) {
    if (le_synth_patch_at(patch)->family == LE_SYNTH_DRUMS) continue;
    le_synth_init(&g_syn_a, SYN_SR, 32, 1);
    le_synth_set_instrument(&g_syn_a, 0, patch);
    le_synth_set_param(&g_syn_a, 0, 0, 100.0f); /* filter wide open */
    CHECK(le_synth_note_on(&g_syn_a, 0, 1, 127, 127) == 0);
    syn_render(&g_syn_a, oa, 1, n, 64);
    for (int32_t i = 0; i < n; ++i) {
      if (!isfinite(a[i]) || fabsf(a[i]) > 1.0f) ok = 0;
    }
    if (syn_peak(a, n) < 1e-3f) ok = 0; /* the fundamental still sounds */
    for (int32_t p = 0; p < 4; ++p) {
      if (g_syn_a.voices[0].phase[p] < 0.0f || g_syn_a.voices[0].phase[p] >= 1.0f) ok = 0;
    }
  }
  CHECK(ok);
  free(a);
}

/* The same events at the same frames render the same samples whatever the
 * caller's block size: control-rate values follow a fixed grid. */
static void syn_script(le_synth* s, float** out, int32_t block) {
  le_synth_init(s, SYN_SR, 32, 3);
  le_synth_set_instrument(s, 0, syn_patch("pad"));
  le_synth_set_instrument(s, 1, syn_patch("drums"));
  le_synth_set_instrument(s, 2, syn_patch("vibes"));   /* tremolo LFO */
  le_synth_set_instrument(s, 3, syn_patch("violin"));  /* vibrato LFO */
  static const int32_t at[] = {0, 3000, 7001, 9000, 15000, 24000};
  int32_t pos = 0;
  for (int step = 0; step < 6; ++step) {
    const int32_t next = at[step];
    if (next > pos) {
      float* o[4];
      for (int b = 0; b < 4; ++b) o[b] = out[b] + pos;
      syn_render(s, o, 4, next - pos, block);
      pos = next;
    }
    switch (step) {
      case 0:
        le_synth_note_on(s, 0, 1, 60, 100);
        le_synth_note_on(s, 1, 2, 38, 100);
        le_synth_note_on(s, 2, 4, 72, 100);
        le_synth_note_on(s, 3, 5, 67, 100);
        break;
      case 1:
        le_synth_note_on(s, 0, 3, 67, 90);
        break;
      case 2:
        le_synth_note_off(s, 1);
        le_synth_note_off(s, 4);
        break;
      case 3:
        le_synth_set_param(s, 0, 0, 10.0f);
        le_synth_set_param(s, 3, 2, 90.0f);
        break;
      case 4:
        le_synth_note_off(s, 3);
        le_synth_note_off(s, 5);
        break;
      default:
        break;
    }
  }
}

static void test_synth_block_size_independent(void) {
  printf("test_synth_block_size_independent\n");
  const int32_t n = 24000;
  float* ref[4];
  float* got[4];
  for (int b = 0; b < 4; ++b) {
    ref[b] = (float*)calloc((size_t)n, sizeof(float));
    got[b] = (float*)calloc((size_t)n, sizeof(float));
  }
  syn_script(&g_syn_a, ref, 1);
  static const int32_t blocks[] = {64, 127, 512};
  for (int k = 0; k < 3; ++k) {
    syn_script(&g_syn_b, got, blocks[k]);
    for (int b = 0; b < 4; ++b) {
      CHECK(memcmp(ref[b], got[b], sizeof(float) * (size_t)n) == 0);
    }
  }
  for (int b = 0; b < 4; ++b) CHECK(syn_peak(ref[b], n) > 0.01f);
  for (int b = 0; b < 4; ++b) {
    free(ref[b]);
    free(got[b]);
  }
}

/* The held-origin hint lets a release skip the voice scan; it must never
 * hide a held voice. A random mix of notes, releases, steals, limits, cuts
 * and renders, checking after every release that no voice of that origin is
 * still held (#1197 Part 2c review H1). */
static void test_synth_held_hint_never_misses(void) {
  printf("test_synth_held_hint_never_misses\n");
  le_synth* s = &g_syn_a;
  CHECK(le_synth_init(s, 48000, LE_SYNTH_MAX_VOICES, 3) == 0);
  CHECK(le_synth_set_instrument(s, 0, syn_patch("pad")) == 0);
  CHECK(le_synth_set_instrument(s, 1, syn_patch("drums")) == 0);
  uint32_t r = 12345u;
  int misses = 0;
  for (int step = 0; step < 200000; ++step) {
    r = r * 1664525u + 1013904223u;
    const uint32_t origin = (r >> 8) % 600u;
    switch ((r >> 24) % 8u) {
      case 0: case 1: case 2:
        le_synth_note_on(s, (int32_t)((r >> 4) & 1u), origin,
                         (r & 1u) ? 36 + (int32_t)(origin % 8u) : 60, 90);
        break;
      case 3: case 4:
        le_synth_note_off(s, origin);
        for (int i = 0; i < s->voice_count; ++i) {
          misses += s->voices[i].state == 1 && s->voices[i].origin == origin;
        }
        break;
      case 5:
        le_synth_render(s, NULL, 0, (int32_t)((r >> 3) % 70u));
        break;
      case 6:
        le_synth_set_voice_limit(s, 1 + (int32_t)((r >> 2) % 64u));
        break;
      default:
        if ((r & 63u) == 0u) le_synth_cut(s, -1);
        break;
    }
  }
  CHECK(misses == 0);
  /* 256 strikes of one origin with no render in between: the bound must
   * not wrap to zero */
  CHECK(le_synth_init(s, 48000, LE_SYNTH_MAX_VOICES, 3) == 0);
  CHECK(le_synth_set_instrument(s, 0, syn_patch("pad")) == 0);
  for (int n = 0; n < 256; ++n) le_synth_note_on(s, 0, 77, 60, 90);
  le_synth_note_off(s, 77);
  int held = 0;
  for (int i = 0; i < s->voice_count; ++i) held += s->voices[i].state == 1;
  CHECK(held == 0 && le_synth_active(s, 0) == 1);
}

static void run_synth_tests(void) {
  test_synth_patch_table();
  test_synth_arg_guards();
  test_synth_pitch_and_exact_release();
  test_synth_velocity_scales();
  test_synth_drum_kick_and_note_off();
  test_synth_steal_prefers_same_instrument();
  test_synth_steal_fades_to_exact_zero();
  test_synth_cutoff_parameter();
  test_synth_deterministic_and_bounded();
  test_synth_full_pool_burst_fades_all();
  test_synth_drum_restrike_overlaps();
  test_synth_fade_slot_overflow();
  test_synth_cut_fades_in_place();
  test_synth_voice_limit();
  test_synth_top_note_bounded();
  test_synth_block_size_independent();
  test_synth_held_hint_never_misses();
}
