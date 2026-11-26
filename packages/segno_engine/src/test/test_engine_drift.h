/* SEG-109 P3: the Drift device. Its own module first (drift_voice.c, driven
 * directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_instruments.h (ins_* helpers) and
 * bench/alias_spectrum.h; SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the
 * instrument tests. */

#include "drift_voice.h"

/* Slot k's Drift instance in engine e. */
static le_drift* eng_drift(le_engine* e, int32_t k) {
  return (le_drift*)le_instruments_device(e, LE_INST_DEVICE_DRIFT, k);
}

#define DRIFT_SR 48000

static le_drift g_drift;

static void drift_init(le_drift* d, int32_t sr) { CHECK(le_drift_init(d, sr) == 0); }

/* Sets one parameter, the others as they are. */
static void drift_set(le_drift* d, int32_t p, float v) {
  float vals[LE_DRIFT_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_drift_set_values(d, vals);
}

static float drift_peak(const float* x, int32_t n) {
  float p = 0.0f;
  for (int32_t i = 0; i < n; ++i) p = fabsf(x[i]) > p ? fabsf(x[i]) : p;
  return p;
}

static float drift_hz(int32_t note) { return 440.0f * exp2f((note - 69) / 12.0f); }

static int drift_finite(const float* x, int32_t n) {
  for (int32_t i = 0; i < n; ++i) {
    if (!isfinite(x[i])) return 0;
  }
  return 1;
}

/* Every oscillator type through both filters renders finite, audible
 * stereo with headroom. */
static void test_drift_every_type_renders(void) {
  printf("test_drift_every_type_renders\n");
  enum { N = 9600 };
  static float l[N], r[N];
  for (int ft = 0; ft < 2; ++ft) {
    for (int t1 = 0; t1 < 7; ++t1) {
      for (int t2 = 0; t2 < 5; t2 += 2) {
        drift_init(&g_drift, DRIFT_SR);
        drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, (float)ft);
        drift_set(&g_drift, LE_DRIFT_OSC1_TYPE, (float)t1);
        drift_set(&g_drift, LE_DRIFT_OSC2_TYPE, (float)t2);
        drift_set(&g_drift, LE_DRIFT_OSC1_SHAPE, 0.6f);
        drift_set(&g_drift, LE_DRIFT_FILTER_RES, 0.8f);
        CHECK(le_drift_note_on(&g_drift, 1, 57, 110, 0) == 0);
        le_drift_render(&g_drift, l, r, N);
        CHECK(drift_finite(l, N) && drift_finite(r, N));
        CHECK(drift_peak(l, N) > 0.005f);
        CHECK(drift_peak(l, N) < 2.0f);
      }
    }
  }
}

/* Resonance modulated past 1 (here velocity through the matrix, to 1.3)
 * self-oscillates on both filter types with both oscillators and the noise
 * off (the filter's own noise starts it), and stays bounded. At 1 itself
 * the fitted filters ring (+29 dB) without oscillating, as Live's do. */
static void test_drift_filter_self_oscillates(void) {
  printf("test_drift_filter_self_oscillates\n");
  enum { N = 48000 };
  static float l[N], r[N];
  for (int ft = 0; ft < 2; ++ft) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, (float)ft);
    drift_set(&g_drift, LE_DRIFT_OSC1_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_RES, 1.01f);
    drift_set(&g_drift, LE_DRIFT_MATRIX_SOURCE1, 4.0f); /* Velocity */
    drift_set(&g_drift, LE_DRIFT_MATRIX_TARGET1, 7.0f); /* LP Resonance */
    drift_set(&g_drift, LE_DRIFT_MATRIX_AMOUNT1, 1.0f);
    CHECK(le_drift_note_on(&g_drift, 1, 60, 127, 0) == 0);
    le_drift_render(&g_drift, l, r, N);
    CHECK(drift_finite(l, N));
    CHECK(drift_peak(l + N / 2, N / 2) > 0.005f);
    CHECK(drift_peak(l, N) < 4.0f);
  }
}

/* The band-limited oscillators alias far less than their naive forms would:
 * a 2.4 kHz tone on an FFT bin at 48 kHz, around the filters. */
static double drift_alias_db(int32_t type) {
  enum { WIN = 8192, SETTLE = 4096 };
  static float l[WIN + SETTLE], r[WIN + SETTLE];
  const int bin = 409; /* odd: 2398.7 Hz */
  const double hz = (double)bin * DRIFT_SR / WIN;
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
  drift_set(&g_drift, LE_DRIFT_OSC1_TYPE, (float)type);
  drift_set(&g_drift, LE_DRIFT_OSC1_GAIN, 1.0f);
  drift_set(&g_drift, LE_DRIFT_FILTER_OSC1_THROUGH, 0.0f); /* around the filters */
  drift_set(&g_drift, LE_DRIFT_DRIFT_DEPTH, 0.0f);
  drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 0.0f);
  drift_set(&g_drift, LE_DRIFT_ENV1_SUSTAIN, 1.0f);
  drift_set(&g_drift, LE_DRIFT_PITCH_BEND_RANGE, 2.0f);
  /* note 74 (587.3 Hz) two octaves up: the bend finishes the tuning */
  drift_set(&g_drift, LE_DRIFT_OSC1_TRANSPOSE, 2.0f);
  const double base = 440.0 * pow(2.0, (74.0 - 69.0) / 12.0) * 4.0;
  le_drift_expression(&g_drift, LE_SYNTH_BEND, (float)(6.0 * log2(hz / base)));
  CHECK(le_drift_note_on(&g_drift, 1, 74, 127, 0) == 0);
  le_drift_render(&g_drift, l, r, WIN + SETTLE);
  return alias_analyze(l + SETTLE, WIN, DRIFT_SR, bin, NULL).alias_db;
}

static void test_drift_oscillators_band_limited(void) {
  printf("test_drift_oscillators_band_limited\n");
  /* Measured on macOS arm64 at 2026-11-25: Saw -32.3, Rectangle -36.3,
   * Shark Tooth -34.8, Pulse -30.1, Triangle -58.3 dB; the limits keep 4 dB
   * of that */
  static const struct { int32_t type; double most; } kinds[] = {
      {4, -28.0}, {6, -32.0}, {2, -30.0}, {5, -26.0}, {1, -54.0}};
  for (size_t k = 0; k < sizeof(kinds) / sizeof(kinds[0]); ++k) {
    const double alias = drift_alias_db(kinds[k].type);
    printf("  type %d: alias %.1f dB\n", kinds[k].type, alias);
    CHECK(alias < kinds[k].most);
  }
}

/* Attack rises linearly to 1 over its time, decay settles at Sustain, and a
 * release ends the voice once it falls below -60 dB: from Sustain 0.3, at
 * 0.25 s x ln(300) / ln(1000), 0.206 s. */
static void test_drift_envelope_shapes(void) {
  printf("test_drift_envelope_shapes\n");
  static float l[DRIFT_SR], r[DRIFT_SR];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 0.1f);
  drift_set(&g_drift, LE_DRIFT_ENV1_DECAY, 0.2f);
  drift_set(&g_drift, LE_DRIFT_ENV1_SUSTAIN, 0.3f);
  drift_set(&g_drift, LE_DRIFT_ENV1_RELEASE, 0.25f);
  le_drift_render(&g_drift, l, r, 64); /* the values reach the chunk grid */
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, 2400);
  CHECK(fabsf(g_drift.voices[0].env1 - 0.5f) < 0.01f);
  le_drift_render(&g_drift, l, r, 2400);
  CHECK(g_drift.voices[0].env1 > 0.99f);
  le_drift_render(&g_drift, l, r, 9600); /* the decay's time */
  CHECK(fabsf(g_drift.voices[0].env1 - 0.3f) < 0.001f);
  le_drift_note_off(&g_drift, 1);
  le_drift_render(&g_drift, l, r, 9400);
  CHECK(le_drift_active(&g_drift) == 1); /* 0.196 s: still releasing */
  le_drift_render(&g_drift, l, r, 1000);
  CHECK(le_drift_active(&g_drift) == 0); /* 0.217 s: ended */
}

/* The same notes and parameter changes render the same samples at any
 * block size: parameters land on the 32-frame grid. */
static void test_drift_block_size_invariant(void) {
  printf("test_drift_block_size_invariant\n");
  enum { N = 6000 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {N, 1, 37, 256};
  for (int b = 0; b < 4; ++b) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 3.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_AMOUNT, 1.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_MOD_AMOUNT2, 0.3f);
    CHECK(le_drift_note_on(&g_drift, 1, 52, 90, 0) == 0);
    float* ol = b == 0 ? ref_l : l;
    float* orr = b == 0 ? ref_r : r;
    for (int32_t done = 0; done < N;) {
      int32_t n = N - done < blocks[b] ? N - done : blocks[b];
      if (done < 3000 && done + n > 3000) n = 3000 - done; /* change at 3000 */
      if (done == 3000) drift_set(&g_drift, LE_DRIFT_FILTER_FREQ, 600.0f);
      le_drift_render(&g_drift, ol + done, orr + done, n);
      done += n;
    }
    if (b > 0) {
      CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
      CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    }
  }
}

/* Poly takes a voice a note, Stereo two, Unison four (panned apart), Mono
 * four for its one note; Mono returns to the held note under the released
 * one, without a retrigger when Legato is on. */
static void test_drift_voice_modes(void) {
  printf("test_drift_voice_modes\n");
  enum { N = 4800 };
  static float l[N], r[N];
  static const int32_t per_note[4] = {1, 4, 2, 4};
  for (int32_t mode = 0; mode < 4; ++mode) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_VOICE_MODE, (float)mode);
    drift_set(&g_drift, LE_DRIFT_UNISON_DEPTH, 1.0f);
    drift_set(&g_drift, LE_DRIFT_STEREO_DEPTH, 1.0f);
    CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
    CHECK(le_drift_note_on(&g_drift, 2, 64, 100, 0) == 0);
    le_drift_render(&g_drift, l, r, N);
    CHECK(le_drift_active(&g_drift) == (mode == 1 ? 4 : 2 * per_note[mode]));
    double side = 0.0;
    for (int32_t i = 0; i < N; ++i) side += fabs((double)l[i] - r[i]);
    if (mode >= 2) {
      CHECK(side > 1.0);
    } else {
      CHECK(side == 0.0);
    }
  }
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 1.0f);
  drift_set(&g_drift, LE_DRIFT_LEGATO, 1.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, N);
  CHECK(le_drift_note_on(&g_drift, 2, 67, 100, 0) == 0);
  CHECK(g_drift.voices[0].note == 67);
  CHECK(g_drift.voices[0].stage1 == 2); /* legato: no new attack */
  le_drift_note_off(&g_drift, 2);
  CHECK(g_drift.voices[0].note == 60);
  CHECK(le_drift_held(&g_drift, 1));
  le_drift_note_off(&g_drift, 1);
  CHECK(!le_drift_held(&g_drift, 1));
  CHECK(g_drift.voices[0].stage1 == 3); /* releasing */
}

/* Nine notes on eight voices steal the oldest; a restrike from one origin
 * keeps one voice; a note of a note already sounding reuses its voice. */
static void test_drift_allocation(void) {
  printf("test_drift_allocation\n");
  static float l[256], r[256];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_VOICE_COUNT, 1.0f); /* 8 voices */
  for (uint32_t k = 0; k < 9; ++k) {
    CHECK(le_drift_note_on(&g_drift, 10 + k, 40 + (int32_t)k, 100, 0) == 0);
  }
  le_drift_render(&g_drift, l, r, 256);
  CHECK(le_drift_active(&g_drift) == 8);
  CHECK(g_drift.stolen == 1);
  CHECK(!le_drift_held(&g_drift, 10)); /* the oldest went */
  CHECK(le_drift_held(&g_drift, 18));
  drift_init(&g_drift, DRIFT_SR);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  CHECK(le_drift_note_on(&g_drift, 1, 62, 100, 0) == 0);
  CHECK(le_drift_active(&g_drift) == 1);
  CHECK(le_drift_note_on(&g_drift, 2, 62, 100, 0) == 0);
  CHECK(le_drift_active(&g_drift) == 1);
  CHECK(le_drift_held(&g_drift, 2));
  /* a chord's notes share an origin: each keeps its own voice */
  CHECK(le_drift_note_on(&g_drift, 3, 70, 100, 0) == 0);
  CHECK(le_drift_note_on(&g_drift, 3, 74, 100, 1) == 0);
  CHECK(le_drift_active(&g_drift) == 3);
  le_drift_note_off(&g_drift, 3);
  CHECK(!le_drift_held(&g_drift, 3));
}

/* Sustain holds released notes until its last contributor lets go; Cut
 * fades everything and drops sustain; a release by port drops only that
 * port's notes and sustain. */
static void test_drift_sustain_cut_and_release_matching(void) {
  printf("test_drift_sustain_cut_and_release_matching\n");
  static float l[4800], r[4800];
  drift_init(&g_drift, DRIFT_SR);
  CHECK(le_drift_sustain(&g_drift, 100, 1) == 0);
  CHECK(le_drift_sustain(&g_drift, 101, 1) == 0);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  le_drift_note_off(&g_drift, 1);
  le_drift_render(&g_drift, l, r, 4800);
  CHECK(le_drift_active(&g_drift) == 1);
  CHECK(g_drift.voices[0].state == 3); /* sustained */
  CHECK(le_drift_sustain(&g_drift, 100, 0) == 0);
  CHECK(g_drift.voices[0].state == 3);
  CHECK(le_drift_sustain(&g_drift, 101, 0) == 0);
  CHECK(g_drift.voices[0].state == 2); /* released */
  CHECK(le_drift_note_on(&g_drift, 2, 64, 100, 0) == 0);
  le_drift_cut(&g_drift);
  CHECK(le_drift_active(&g_drift) == 0);
  CHECK(le_drift_fading(&g_drift) >= 1);
  le_drift_render(&g_drift, l, r, 4800);
  CHECK(le_drift_fading(&g_drift) == 0);
  CHECK(drift_peak(l + 480, 4320) == 0.0f);
  drift_init(&g_drift, DRIFT_SR);
  CHECK(le_drift_note_on(&g_drift, 0x01000005u, 60, 100, 0) == 0); /* port 1 */
  CHECK(le_drift_note_on(&g_drift, 0x02000005u, 64, 100, 0) == 0); /* port 2 */
  le_drift_release_matching(&g_drift, 0xFF000000u, 0x01000000u);
  CHECK(!le_drift_held(&g_drift, 0x01000005u));
  CHECK(le_drift_held(&g_drift, 0x02000005u));
}

/* Notes held while Voice Mode changes still let go: Poly to Mono and back. */
static void test_drift_mode_change_releases_held_notes(void) {
  printf("test_drift_mode_change_releases_held_notes\n");
  static float l[9600], r[9600];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_ENV1_RELEASE, 0.05f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  CHECK(le_drift_note_on(&g_drift, 2, 64, 100, 0) == 0);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 1.0f); /* Mono */
  le_drift_note_off(&g_drift, 1);
  le_drift_note_off(&g_drift, 2);
  CHECK(!le_drift_held(&g_drift, 1) && !le_drift_held(&g_drift, 2));
  le_drift_render(&g_drift, l, r, 9600);
  CHECK(le_drift_active(&g_drift) == 0);
  /* Mono to Poly: the note held under Mono lets go, and leaves no stale
   * entry on Mono's stack */
  CHECK(le_drift_note_on(&g_drift, 3, 60, 100, 0) == 0);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 0.0f);
  le_drift_note_off(&g_drift, 3);
  CHECK(!le_drift_held(&g_drift, 3));
  CHECK(g_drift.mono_n == 0);
}

/* A retriggered attack rises from the level it starts at over the whole
 * Attack time. */
static void test_drift_retriggered_attack_keeps_its_time(void) {
  printf("test_drift_retriggered_attack_keeps_its_time\n");
  static float l[DRIFT_SR], r[DRIFT_SR];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 1.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, DRIFT_SR / 2);
  CHECK(fabsf(g_drift.voices[0].env1 - 0.5f) < 0.01f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0); /* restrike */
  le_drift_render(&g_drift, l, r, DRIFT_SR / 4);
  CHECK(fabsf(g_drift.voices[0].env1 - 0.625f) < 0.01f); /* 0.5 + 0.5 / 4 */
  le_drift_render(&g_drift, l, r, DRIFT_SR * 3 / 4 - 100);
  CHECK(g_drift.voices[0].stage1 == 1);
  le_drift_render(&g_drift, l, r, 200);
  CHECK(g_drift.voices[0].stage1 == 2); /* the top at 1 s, not 0.5 s */
}

/* After Poly, a Unison group is free only when all four of its voices are:
 * a note never takes a voice another note still sounds on. */
static void test_drift_group_needs_every_lane_free(void) {
  printf("test_drift_group_needs_every_lane_free\n");
  static float l[9600], r[9600];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_ENV1_RELEASE, 0.01f);
  for (uint32_t k = 0; k < 4; ++k) {
    CHECK(le_drift_note_on(&g_drift, 1 + k, 50 + (int32_t)k, 100, 0) == 0);
  }
  le_drift_note_off(&g_drift, 1); /* voice 0 ends; 1 to 3 hold */
  le_drift_render(&g_drift, l, r, 9600);
  CHECK(g_drift.voices[0].state == 0 && g_drift.voices[1].state == 1);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 3.0f);
  CHECK(le_drift_note_on(&g_drift, 9, 70, 100, 0) == 0);
  for (int32_t i = 1; i < 4; ++i) {
    CHECK(g_drift.voices[i].note == 50 + i && g_drift.voices[i].origin == 1u + (uint32_t)i);
  }
  int32_t on_new = 0;
  for (int32_t i = 4; i < LE_DRIFT_VOICES; ++i) on_new += g_drift.voices[i].note == 70;
  CHECK(on_new == 4); /* a whole group of its own */
  CHECK(g_drift.stolen == 0);
}

/* The LFO's rate modes in their stored order (Freq, Time, Ratio, Sync),
 * the Sync divisions slowest first, and Retrigger's start phase. */
static void test_drift_lfo_rate_modes(void) {
  printf("test_drift_lfo_rate_modes\n");
  static float l[12000], r[12000];
  static const struct {
    int32_t mode, sync;
    float time, ratio, cycles; /* cycles over 0.25 s at note 69 */
  } k[] = {
      {1, 0, 0.5f, 1.0f, 0.5f},   /* Time 0.5 s: 2 Hz */
      {3, 12, 1.0f, 1.0f, 0.5f},  /* Sync 1 beat at 120 BPM: 2 Hz */
      {3, 6, 1.0f, 1.0f, 0.125f}, /* 4 beats */
      {2, 0, 1.0f, 0.25f, 27.5f}, /* Ratio 0.25 of 440 Hz */
  };
  for (size_t i = 0; i < sizeof(k) / sizeof(k[0]); ++i) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_LFO_RETRIGGER, 1.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_MODE, (float)k[i].mode);
    drift_set(&g_drift, LE_DRIFT_LFO_TIME, k[i].time);
    drift_set(&g_drift, LE_DRIFT_LFO_RATIO, k[i].ratio);
    drift_set(&g_drift, LE_DRIFT_LFO_SYNCED_RATE, (float)k[i].sync);
    le_drift_render(&g_drift, l, r, 32); /* the values apply from a chunk */
    CHECK(le_drift_note_on(&g_drift, 1, 69, 100, 0) == 0);
    CHECK(g_drift.voices[0].lfo_ph == 0.25f); /* a sine restarts at its peak */
    le_drift_render(&g_drift, l, r, 12000);
    const float want = fmodf(0.25f + k[i].cycles, 1.0f);
    CHECK(fabsf(g_drift.voices[0].lfo_ph - want) < 0.01f);
  }
}

/* Shark Tooth carries no DC at any shape, modulated past 0..1 included:
 * through the bypass (no high-pass), one second of 440 cycles averages
 * to nothing. */
static void test_drift_shark_has_no_dc(void) {
  printf("test_drift_shark_has_no_dc\n");
  static float l[DRIFT_SR], r[DRIFT_SR];
  static const float shapes[] = {-0.5f, 0.0f, 0.3f, 0.6f, 1.0f, 1.5f};
  for (size_t i = 0; i < sizeof(shapes) / sizeof(shapes[0]); ++i) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_OSC1_TYPE, 2.0f);
    drift_set(&g_drift, LE_DRIFT_OSC1_SHAPE, shapes[i] < 0.0f ? 0.0f : shapes[i] > 1.0f ? 1.0f : shapes[i]);
    /* past the ends: a fixed offset from the matrix's Osc 1 Shape target,
     * Velocity as its source */
    drift_set(&g_drift, LE_DRIFT_MATRIX_SOURCE1, (float)LE_DRIFT_SRC_VELOCITY);
    drift_set(&g_drift, LE_DRIFT_MATRIX_TARGET1, (float)LE_DRIFT_TGT_OSC1_SHAPE);
    drift_set(&g_drift, LE_DRIFT_MATRIX_AMOUNT1,
              shapes[i] < 0.0f ? -1.0f : shapes[i] > 1.0f ? 1.0f : 0.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_OSC1_THROUGH, 0.0f);
    drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_NOISE_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 0.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_SUSTAIN, 1.0f);
    le_drift_render(&g_drift, l, r, 32);
    /* velocity 127: 0.5 above the bipolar centre, so +-0.5 past the ends */
    CHECK(le_drift_note_on(&g_drift, 1, 69, 127, 0) == 0);
    le_drift_render(&g_drift, l, r, 4800);
    le_drift_render(&g_drift, l, r, DRIFT_SR);
    double sum = 0.0, sq = 0.0;
    for (int32_t f = 0; f < DRIFT_SR; ++f) {
      sum += l[f];
      sq += (double)l[f] * l[f];
    }
    const double rms = sqrt(sq / DRIFT_SR);
    CHECK(rms > 0.01);
    CHECK(fabs(sum / DRIFT_SR) < 0.01 * rms);
    /* at shape 1 and past it, a falling ramp that rises back fast: the
     * output falls on most samples (around the filters, no clip) */
    if (shapes[i] >= 1.0f) {
      int32_t falls = 0;
      for (int32_t f = 1; f < DRIFT_SR; ++f) falls += l[f] < l[f - 1];
      CHECK(falls > DRIFT_SR * 8 / 10);
    }
  }
}

/* With Reset Oscillator Phase off a voice keeps the phase its last note
 * left; on, a silent voice starts at 0. A note after the last one ended
 * takes the same voice (the search starts at the voice allocated last). */
static void test_drift_reset_phase_and_reuse(void) {
  printf("test_drift_reset_phase_and_reuse\n");
  static float l[9600], r[9600];
  for (int reset = 0; reset < 2; ++reset) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_RESET_OSC_PHASE, (float)reset);
    drift_set(&g_drift, LE_DRIFT_ENV1_RELEASE, 0.01f);
    CHECK(le_drift_note_on(&g_drift, 1, 61, 100, 0) == 0);
    le_drift_render(&g_drift, l, r, 1000);
    le_drift_note_off(&g_drift, 1);
    le_drift_render(&g_drift, l, r, 9600);
    CHECK(g_drift.voices[0].state == 0);
    const float left_at = g_drift.voices[0].ph1;
    CHECK(left_at != 0.0f);
    CHECK(le_drift_note_on(&g_drift, 2, 66, 100, 0) == 0);
    CHECK(g_drift.voices[0].note == 66);
    CHECK(g_drift.voices[0].ph1 == (reset ? 0.0f : left_at));
  }
}

/* With Reset Oscillator Phase on, a note struck on a sounding voice (here
 * Mono legato) waits while the voice falls silent in about 1 ms, then
 * starts at phase 0 with a new attack, its glide running on; with it off
 * the legato note only changes pitch. */
static void test_drift_reset_phase_restart_waits(void) {
  printf("test_drift_reset_phase_restart_waits\n");
  static float l[4800], r[4800];
  for (int reset = 0; reset < 2; ++reset) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 1.0f);
    drift_set(&g_drift, LE_DRIFT_LEGATO, 1.0f);
    drift_set(&g_drift, LE_DRIFT_GLIDE, 0.5f);
    drift_set(&g_drift, LE_DRIFT_RESET_OSC_PHASE, (float)reset);
    CHECK(le_drift_note_on(&g_drift, 1, 48, 100, 0) == 0);
    le_drift_render(&g_drift, l, r, 4800);
    CHECK(le_drift_note_on(&g_drift, 2, 60, 100, 0) == 0);
    le_drift_voice* v = &g_drift.voices[0];
    CHECK(v->pending == reset);
    le_drift_render(&g_drift, l, r, 40); /* 0.83 ms: still falling */
    CHECK(v->pending == reset);
    if (reset) CHECK(v->env1 < 0.01f && v->env1 > 0.001f);
    le_drift_render(&g_drift, l, r, 20); /* 1.25 ms: restarted */
    CHECK(v->pending == 0);
    CHECK(v->stage1 == (reset ? 1 : 2)); /* a new attack, or legato */
    if (reset) CHECK(v->ph1 < 60.0f * 262.0f / DRIFT_SR);
    CHECK(v->pitch > drift_hz(48) && v->pitch < drift_hz(60)); /* gliding */
  }
}

/* Glide moves evenly in hertz: after one time constant (0.144 x Glide)
 * the distance to the new note in hertz is 1/e of where it started. */
static void test_drift_glide_in_hertz(void) {
  printf("test_drift_glide_in_hertz\n");
  static float l[13824], r[13824];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 1.0f);
  drift_set(&g_drift, LE_DRIFT_LEGATO, 1.0f);
  drift_set(&g_drift, LE_DRIFT_GLIDE, 2.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 48, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, 480);
  CHECK(le_drift_note_on(&g_drift, 2, 60, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, 13824); /* 0.288 s */
  const float lo = drift_hz(48), hi = drift_hz(60);
  const float left = (hi - g_drift.voices[0].pitch) / (hi - lo);
  CHECK(fabsf(left - 0.3679f) < 0.01f);
}

/* The first chunk rendered resets the voice blocks: a free-running LFO
 * (Retrigger off) starts at its shape's start phase and runs while the
 * voices are idle, in Ratio mode at Ratio x A4. */
static void test_drift_block_reset_lfo_phase(void) {
  printf("test_drift_block_reset_lfo_phase\n");
  static float l[480], r[480];
  for (int ratio = 0; ratio < 2; ++ratio) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_LFO_MODE, ratio ? 2.0f : 0.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_SHAPE, 2.0f); /* a saw: starts at 0.5 */
    drift_set(&g_drift, LE_DRIFT_LFO_RATE, 2.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_RATIO, 0.25f);
    le_drift_render(&g_drift, l, r, 480);
    const float per_s = ratio ? 0.25f * 440.0f : 2.0f;
    const float want = fmodf(0.5f + per_s * 0.01f, 1.0f);
    CHECK(fabsf(g_drift.voices[5].lfo_ph - want) < 0.002f);
  }
}

/* Filter II starts a voice at rest: with every source off, a note through
 * it stays silent (from zero state its offsets would step through the
 * output coupling). A retriggered Sample & Hold starts on a drawn value. */
static void test_drift_filter2_starts_at_rest(void) {
  printf("test_drift_filter2_starts_at_rest\n");
  static float l[4800], r[4800];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, 1.0f);
  drift_set(&g_drift, LE_DRIFT_OSC1_ON, 0.0f);
  drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 127, 0) == 0);
  le_drift_render(&g_drift, l, r, 4800);
  CHECK(drift_peak(l, 4800) < 1e-4f);
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_LFO_SHAPE, 5.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_RETRIGGER, 1.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 127, 0) == 0);
  CHECK(g_drift.voices[0].lfo_b != 0.0f);
}

/* Drift Depth's tuning is the measured table: a few values pinned (cents
 * per unit of depth / 0.58: voice 0 +2.48, voice 18 -12.33, key 24 -0.17,
 * key 31 +14.06, key 59 +12.94, none outside C1..B5), and a note's ratio
 * is the sum at w; Osc 2 adds its own per-voice offset. Unison's first
 * lane is the sharpest, panned left. */
static void test_drift_tuning_table(void) {
  printf("test_drift_tuning_table\n");
  drift_init(&g_drift, DRIFT_SR);
  CHECK(fabsf(g_drift.voice_cents[0] - 2.48f) < 0.005f);
  CHECK(fabsf(g_drift.voice_cents[18] + 12.33f) < 0.005f);
  CHECK(fabsf(g_drift.key_cents[24] + 0.17f) < 0.005f);
  CHECK(fabsf(g_drift.key_cents[31] - 14.06f) < 0.005f);
  CHECK(fabsf(g_drift.key_cents[59] - 12.94f) < 0.005f);
  CHECK(g_drift.key_cents[23] == 0.0f && g_drift.key_cents[84] == 0.0f);
  drift_set(&g_drift, LE_DRIFT_DRIFT_DEPTH, 0.58f); /* w = 1 */
  CHECK(le_drift_note_on(&g_drift, 1, 59, 100, 0) == 0);
  const float cents = 1200.0f * log2f(g_drift.voices[0].ratio);
  CHECK(fabsf(cents - (12.94f + 2.48f)) < 0.01f);
  /* Osc 2 adds its own per-voice offset: voice 0 +0.21 */
  CHECK(fabsf(1200.0f * log2f(g_drift.voices[0].osc2_drift) - 0.21f) < 0.01f);
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_DRIFT_DEPTH, 0.0f);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 3.0f);
  drift_set(&g_drift, LE_DRIFT_UNISON_DEPTH, 1.0f);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  CHECK(g_drift.voices[0].ratio > g_drift.voices[3].ratio);
  CHECK(g_drift.voices[0].gain_l > g_drift.voices[0].gain_r);
}

/* The preset's SerialNumber picks the per-voice tuning: serials 2217915 and
 * 8388607 (and above, clamped) their own measured values, any other serial
 * serial 0's. */
static void test_drift_serial_picks_tuning(void) {
  printf("test_drift_serial_picks_tuning\n");
  static float l[32], r[32];
  static const struct { float serial, voice0; } k[] = {
      {2217915.0f, -11.79f}, {2217914.0f, 2.48f}, {9.0e6f, -3.90f}, {0.0f, 2.48f}};
  drift_init(&g_drift, DRIFT_SR);
  for (int i = 0; i < 4; ++i) {
    drift_set(&g_drift, LE_DRIFT_SERIAL_NUMBER, k[i].serial);
    le_drift_render(&g_drift, l, r, 32);
    CHECK(fabsf(g_drift.voice_cents[0] - k[i].voice0) < 0.005f);
  }
}

/* Sample & Hold changes its value only at half-cycle boundaries (twice per
 * cycle), while its generator steps every sample: 100 Hz over 0.1 s holds
 * 20 values after the first, each in -1..1. */
static void test_drift_sample_hold_steps(void) {
  printf("test_drift_sample_hold_steps\n");
  static float l[1], r[1];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_LFO_SHAPE, 5.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_MODE, 0.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_RATE, 100.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_AMOUNT, 1.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_RETRIGGER, 1.0f);
  le_drift_render(&g_drift, l, r, 1);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  float last = g_drift.voices[0].lfo_b;
  const uint32_t gy = g_drift.voices[0].lfo_gy;
  int changes = 0;
  const int n = DRIFT_SR / 10;
  for (int i = 0; i < n; ++i) {
    le_drift_render(&g_drift, l, r, 1);
    const float b = g_drift.voices[0].lfo_b;
    CHECK(b >= -1.0f && b < 1.0f);
    if (b != last) ++changes;
    last = b;
  }
  CHECK(changes >= 19 && changes <= 21);
  CHECK(g_drift.voices[0].lfo_gy != gy);
}

/* An LFO in Ratio mode routed to pitch moves the oscillators' phase, not
 * their frequency: the phase accumulators run as without it. In Freq mode
 * the same routing is vibrato and they do not. The cycling envelope in
 * Ratio mode is phase modulation too (run 3). */
static void test_drift_ratio_lfo_is_phase_modulation(void) {
  printf("test_drift_ratio_lfo_is_phase_modulation\n");
  static float l[4800], r[4800];
  float ph[4];
  for (int run = 0; run < 4; ++run) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_LFO_MODE, run == 2 ? 0.0f : 2.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_RATE, 7.0f);
    drift_set(&g_drift, LE_DRIFT_LFO_RATIO, 2.375f);
    drift_set(&g_drift, LE_DRIFT_LFO_AMOUNT, 1.0f);
    drift_set(&g_drift, LE_DRIFT_ENV2_CYCLING, 1.0f);
    drift_set(&g_drift, LE_DRIFT_CYC_MODE, 2.0f);
    drift_set(&g_drift, LE_DRIFT_CYC_RATIO, 3.0f);
    drift_set(&g_drift, LE_DRIFT_PITCH_MOD_SOURCE1,
              (float)(run == 3 ? LE_DRIFT_SRC_ENV2 : LE_DRIFT_SRC_LFO));
    drift_set(&g_drift, LE_DRIFT_PITCH_MOD_AMOUNT1, run == 0 ? 0.0f : 0.5f);
    le_drift_render(&g_drift, l, r, 32);
    CHECK(le_drift_note_on(&g_drift, 1, 48, 100, 0) == 0);
    le_drift_render(&g_drift, l, r, 4800);
    ph[run] = g_drift.voices[0].ph1;
  }
  CHECK(fabsf(ph[1] - ph[0]) < 1e-3f);
  CHECK(fabsf(ph[2] - ph[0]) > 1e-2f);
  CHECK(fabsf(ph[3] - ph[0]) < 1e-3f);
}

/* A Ratio-mode LFO follows a Mono lane's octave: the sub lanes' LFOs run
 * at half and a quarter of the top lane's rate, and each lane keys as the
 * note it plays. */
static void test_drift_mono_lane_ratio_lfo(void) {
  printf("test_drift_mono_lane_ratio_lfo\n");
  static float l[480], r[480];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_VOICE_MODE, 1.0f);
  drift_set(&g_drift, LE_DRIFT_MONO_DEPTH, 1.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_MODE, 2.0f);
  drift_set(&g_drift, LE_DRIFT_LFO_RATIO, 1.0f);
  drift_set(&g_drift, LE_DRIFT_DRIFT_DEPTH, 0.0f); /* no per-key offsets */
  le_drift_render(&g_drift, l, r, 32);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
  le_drift_render(&g_drift, l, r, 480);
  const float top = g_drift.voices[0].lfo_inc;
  CHECK(top > 0.0f);
  CHECK(fabsf(g_drift.voices[1].lfo_inc - 0.5f * top) < 1e-6f);
  CHECK(fabsf(g_drift.voices[3].lfo_inc - 0.25f * top) < 1e-6f);
  /* and each lane keys as its own note: C4's lanes as C4, C3, C3, C2 */
  CHECK(fabsf(g_drift.voices[0].key - (60.0f - 69.0f) / 120.0f) < 1e-6f);
  CHECK(fabsf(g_drift.voices[1].key - (48.0f - 69.0f) / 120.0f) < 1e-6f);
  CHECK(fabsf(g_drift.voices[3].key - (36.0f - 69.0f) / 120.0f) < 1e-6f);
}

/* The filters' input stage: a sine at Gain 0.5 passes clean, one at Gain
 * 1 clips its positive side first. */
static void test_drift_filter_input_clips_asymmetrically(void) {
  printf("test_drift_filter_input_clips_asymmetrically\n");
  static float l[9600], r[9600];
  float ratio[2];
  for (int k = 0; k < 2; ++k) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_OSC1_TYPE, 0.0f);
    drift_set(&g_drift, LE_DRIFT_OSC1_GAIN, k ? 1.0f : 0.5f);
    drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_FREQ, 20000.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 0.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_SUSTAIN, 1.0f);
    le_drift_render(&g_drift, l, r, 32);
    CHECK(le_drift_note_on(&g_drift, 1, 60, 127, 0) == 0);
    le_drift_render(&g_drift, l, r, 9600);
    le_drift_render(&g_drift, l, r, 9600);
    float hi = 0.0f, lo = 0.0f;
    for (int32_t f = 0; f < 9600; ++f) {
      hi = l[f] > hi ? l[f] : hi;
      lo = l[f] < lo ? l[f] : lo;
    }
    ratio[k] = hi / -lo;
  }
  CHECK(fabsf(ratio[0] - 1.0f) < 0.02f);
  CHECK(ratio[1] < 0.95f);
}

/* Voices run in blocks of four: a silent voice in a running block keeps
 * turning its oscillators, one in an idle block does not; and blocks that
 * start together play the same noise voice for voice, while the voices of
 * one block differ. */
static void test_drift_voice_blocks(void) {
  printf("test_drift_voice_blocks\n");
  static float l[4800], r[4800];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_NOISE_ON, 1.0f);
  le_drift_render(&g_drift, l, r, 32);
  CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0); /* voice 0, block 0 */
  le_drift_render(&g_drift, l, r, 4800);
  CHECK(g_drift.voices[1].state == 0 && g_drift.voices[1].ph1 != 0.0f);
  CHECK(g_drift.voices[4].state == 0 && g_drift.voices[4].ph1 == 0.0f);
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_NOISE_ON, 1.0f);
  drift_set(&g_drift, LE_DRIFT_NOISE_GAIN, 1.0f);
  le_drift_render(&g_drift, l, r, 32);
  for (uint32_t k = 0; k < 5; ++k) {
    CHECK(le_drift_note_on(&g_drift, 1 + k, 50 + 2 * (int32_t)k, 100, 0) == 0);
  }
  CHECK(g_drift.voices[4].state != 0); /* the fifth note opened block 1 */
  le_drift_render(&g_drift, l, r, 480);
  CHECK(g_drift.lane_noise[0] == g_drift.lane_noise[4]);
  CHECK(g_drift.lane_noise[0] != g_drift.lane_noise[1]);
}

/* A Filter Type change while a note sounds starts the new filter from
 * rest: no jolt from the other filter's state, either way round. */
static void test_drift_filter_type_switch_is_smooth(void) {
  printf("test_drift_filter_type_switch_is_smooth\n");
  enum { N = 9600, AFTER = 960 };
  static float l[N], r[N];
  for (int from = 0; from < 2; ++from) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, (float)from);
    drift_set(&g_drift, LE_DRIFT_FILTER_FREQ, 800.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_RES, 0.9f);
    drift_set(&g_drift, LE_DRIFT_OSC1_GAIN, 1.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_ATTACK, 0.0f);
    drift_set(&g_drift, LE_DRIFT_ENV1_SUSTAIN, 1.0f);
    le_drift_render(&g_drift, l, r, 32);
    CHECK(le_drift_note_on(&g_drift, 1, 45, 127, 0) == 0);
    le_drift_render(&g_drift, l, r, N);
    const float before = drift_peak(l + N / 2, N / 2);
    drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, (float)(1 - from));
    le_drift_render(&g_drift, l, r, N);
    const float settled = drift_peak(l + N / 2, N / 2);
    const float jolt = drift_peak(l, AFTER);
    CHECK(before > 0.01f && settled > 0.01f);
    CHECK(jolt < 1.5f * fmaxf(before, settled));
  }
}

/* ---- the engine: a slot playing Drift ---- */

/* Processes [frames] in blocks of [block]; when [l] and [r] are given,
 * appends slot [slot]'s bus. */
static void drift_run(le_engine* e, int32_t frames, int32_t block, int32_t slot,
                      float* l, float* r) {
  static float in[2 * 512], o[2 * 512];
  memset(in, 0, sizeof(in));
  for (int32_t done = 0; done < frames;) {
    int32_t n = frames - done < block ? frames - done : block;
    if (n > 512) n = 512;
    le_engine_process(e, o, in, (uint32_t)n);
    if (l != NULL) memcpy(l + done, le_instrument_bus(e, slot, 0), sizeof(float) * (size_t)n);
    if (r != NULL) memcpy(r + done, le_instrument_bus(e, slot, 1), sizeof(float) * (size_t)n);
    done += n;
  }
}

/* The engine's slot renders what the module renders offline, sample for
 * sample, at any block size; the snapshot names the device. */
static void test_engine_drift_slot_matches_offline(void) {
  printf("test_engine_drift_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  float values[LE_DRIFT_PARAMS];
  for (int p = 0; p < LE_DRIFT_PARAMS; ++p) values[p] = le_drift_default(p);
  values[LE_DRIFT_VOICE_MODE] = 3.0f; /* Unison: two different sides */
  values[LE_DRIFT_UNISON_DEPTH] = 0.8f;
  drift_init(&g_drift, INS_SR);
  le_drift_set_values(&g_drift, values);
  le_drift_set_voice_limit(&g_drift, 32);
  CHECK(le_drift_note_on(&g_drift, ins_origin(1), 57, 100, 0) == 0);
  le_drift_render(&g_drift, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL); /* silent blocks first */
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_DRIFT, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_DRIFT);
    CHECK(snap.instrument_patch[0] == -1);
    CHECK(snap.instrument_voices[0] == 4);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

/* A parameter set on the slot reaches the device; a note-off releases; a
 * patch given to the slot ends the device, and a device given ends the
 * patch. */
static void test_engine_drift_params_and_switching(void) {
  printf("test_engine_drift_params_and_switching\n");
  enum { N = 4800 };
  static float l[N], r[N];
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 1, 60, 100) == LE_OK);
  drift_run(e, N, 64, 2, l, r);
  CHECK(memcmp(l, r, sizeof(l)) == 0); /* Poly: centred */
  CHECK(le_engine_set_instrument_device_param(e, 2, LE_DRIFT_VOICE_MODE, 2.0f) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 2, 64, 100) == LE_OK);
  drift_run(e, N, 64, 2, l, r);
  CHECK(memcmp(l, r, sizeof(l)) != 0); /* Stereo */
  CHECK(eng_drift(e, 2)->values[LE_DRIFT_VOICE_MODE] == 2.0f);
  /* clamped to its range */
  CHECK(le_engine_set_instrument_device_param(e, 2, LE_DRIFT_FILTER_FREQ, 1e6f) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_drift(e, 2)->values[LE_DRIFT_FILTER_FREQ] == 20000.0f);
  CHECK(le_engine_instrument_note_off(e, 1) == LE_OK);
  CHECK(le_engine_instrument_note_off(e, 2) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(!le_drift_held(eng_drift(e, 2), ins_origin(1)));
  /* a patch ends the device */
  CHECK(le_engine_instrument_note_on(e, 2, 3, 60, 100) == LE_OK);
  CHECK(le_engine_set_instrument(e, 2, syn_patch("pad"), NULL) == LE_OK);
  drift_run(e, 960, 64, 2, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[2] == LE_INST_DEVICE_NONE);
  CHECK(snap.instrument_patch[2] == syn_patch("pad"));
  CHECK(le_drift_active(eng_drift(e, 2)) == 0 && le_drift_fading(eng_drift(e, 2)) == 0);
  CHECK(le_engine_set_instrument_device_param(e, 2, LE_DRIFT_VOLUME, 0.5f) ==
        LE_ERR_NO_INSTRUMENT);
  /* and a device ends the patch */
  CHECK(le_engine_instrument_note_on(e, 2, 4, 60, 100) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  drift_run(e, 960, 64, 2, NULL, NULL);
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[2] == LE_INST_DEVICE_DRIFT);
  CHECK(snap.instrument_patch[2] == -1);
  CHECK(le_synth_active((le_synth*)e->synth, 2) == 0);
  CHECK(le_engine_set_instrument_param(e, 2, 0, 50.0f) == LE_ERR_NO_INSTRUMENT);
  le_engine_destroy(e);
}

/* The voice limit bounds every instrument together: two device slots and a
 * patch slot share it, and a limit below one Unison note's four voices
 * still holds. */
static void test_engine_drift_voice_budget(void) {
  printf("test_engine_drift_voice_budget\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_voice_limit(e, 8) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  CHECK(le_engine_set_instrument(e, 2, syn_patch("pad"), NULL) == LE_OK);
  for (int32_t k = 0; k < 6; ++k) {
    CHECK(le_engine_instrument_note_on(e, 0, 10 + (uint32_t)k, 48 + k, 100) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 1, 20 + (uint32_t)k, 60 + k, 100) == LE_OK);
  }
  CHECK(le_engine_instrument_note_on(e, 2, 30, 72, 100) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 2, 31, 76, 100) == LE_OK);
  drift_run(e, 64, 64, 0, NULL, NULL);
  const int32_t total = le_synth_active((le_synth*)e->synth, -1) +
                        le_drift_active(eng_drift(e, 0)) + le_drift_active(eng_drift(e, 1));
  CHECK(total == 8);
  CHECK(le_synth_active((le_synth*)e->synth, 2) == 2);
  CHECK(le_drift_active(eng_drift(e, 0)) == 3 && le_drift_active(eng_drift(e, 1)) == 3);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.voices_stolen >= 6);
  /* a limit of 2 with a Unison note */
  CHECK(le_engine_cut_sound(e) == LE_OK);
  CHECK(le_engine_set_voice_limit(e, 2) == LE_OK);
  CHECK(le_engine_set_instrument_device_param(e, 0, LE_DRIFT_VOICE_MODE, 3.0f) == LE_OK);
  drift_run(e, 960, 64, 0, NULL, NULL);
  CHECK(le_engine_instrument_note_on(e, 0, 40, 60, 100) == LE_OK);
  drift_run(e, 64, 64, 0, NULL, NULL);
  CHECK(le_drift_active(eng_drift(e, 0)) == 2);
  le_engine_destroy(e);
}

static void test_engine_drift_refusals(void) {
  printf("test_engine_drift_refusals\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_DRIFT, NULL) ==
        LE_ERR_NOT_RUNNING);
  le_engine_destroy(e);
  e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, -1, LE_INST_DEVICE_DRIFT, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device(e, LE_MAX_INSTRUMENTS, LE_INST_DEVICE_DRIFT, NULL) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_NONE, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_COLLISION + 1, NULL) == LE_ERR_INVALID);
  float values[LE_DRIFT_PARAMS];
  for (int p = 0; p < LE_DRIFT_PARAMS; ++p) values[p] = le_drift_default(p);
  values[LE_DRIFT_GLIDE] = NAN;
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_DRIFT, values) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 0, LE_DRIFT_VOLUME, 0.5f) ==
        LE_ERR_NO_INSTRUMENT);
  CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  CHECK(le_engine_set_instrument_device_param(e, 0, -1, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 0, LE_DRIFT_PARAMS, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 0, LE_DRIFT_VOLUME, NAN) == LE_ERR_INVALID);
  /* a device slot is a source a take can arm on */
  CHECK(le_engine_set_lane_input(e, 0, 0, 32) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_destroy(e);
}

/* MIDI routed to a device slot plays it; its note-off and a sustain pedal
 * act on it; Cut all sound fades it. */
static void test_engine_drift_midi(void) {
  printf("test_engine_drift_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_DRIFT, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 1, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(le_drift_active(eng_drift(e, 1)) == 1);
  ins_send(&cap, 0xB0, 64, 127); /* sustain */
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_drift(e, 1)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_drift(e, 1)->voices[0].state == 2); /* released */
  ins_send(&cap, 0x90, 62, 100);
  ins_send(&cap, 0xE0, 0, 127); /* bend up: (16256 - 8192) / 8192 */
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(fabsf(eng_drift(e, 1)->bend - 0.984375f) < 1e-6f);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  CHECK(le_drift_active(eng_drift(e, 1)) == 0 && le_drift_fading(eng_drift(e, 1)) == 0);
  le_engine_destroy(e);
}

static void run_drift_tests(void) {
  test_drift_every_type_renders();
  test_drift_filter_self_oscillates();
  test_drift_oscillators_band_limited();
  test_drift_envelope_shapes();
  test_drift_block_size_invariant();
  test_drift_voice_modes();
  test_drift_allocation();
  test_drift_sustain_cut_and_release_matching();
  test_drift_mode_change_releases_held_notes();
  test_drift_retriggered_attack_keeps_its_time();
  test_drift_group_needs_every_lane_free();
  test_drift_lfo_rate_modes();
  test_drift_shark_has_no_dc();
  test_drift_reset_phase_and_reuse();
  test_drift_reset_phase_restart_waits();
  test_drift_glide_in_hertz();
  test_drift_block_reset_lfo_phase();
  test_drift_filter2_starts_at_rest();
  test_drift_tuning_table();
  test_drift_serial_picks_tuning();
  test_drift_sample_hold_steps();
  test_drift_ratio_lfo_is_phase_modulation();
  test_drift_mono_lane_ratio_lfo();
  test_drift_filter_input_clips_asymmetrically();
  test_drift_voice_blocks();
  test_drift_filter_type_switch_is_smooth();
  test_engine_drift_slot_matches_offline();
  test_engine_drift_voice_budget();
  test_engine_drift_params_and_switching();
  test_engine_drift_refusals();
  test_engine_drift_midi();
}
