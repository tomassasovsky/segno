/* SEG-109 P3: the Drift device. Its own module first (drift_voice.c, driven
 * directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_instruments.h (ins_* helpers) and
 * bench/alias_spectrum.h; SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the
 * instrument tests. */

#include "drift_voice.h"

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

/* A resonance above 1 self-oscillates with both oscillators and the noise
 * off (the filter's own noise starts it), and stays bounded. */
static void test_drift_filter_self_oscillates(void) {
  printf("test_drift_filter_self_oscillates\n");
  enum { N = 48000 };
  static float l[N], r[N];
  for (int ft = 0; ft < 1; ++ft) {
    drift_init(&g_drift, DRIFT_SR);
    drift_set(&g_drift, LE_DRIFT_FILTER_TYPE, (float)ft);
    drift_set(&g_drift, LE_DRIFT_OSC1_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_OSC2_ON, 0.0f);
    drift_set(&g_drift, LE_DRIFT_FILTER_RES, 1.01f);
    CHECK(le_drift_note_on(&g_drift, 1, 60, 100, 0) == 0);
    le_drift_render(&g_drift, l, r, N);
    CHECK(drift_finite(l, N));
    CHECK(drift_peak(l + N / 2, N / 2) > 0.005f);
    CHECK(drift_peak(l, N) < 2.0f);
  }
}

/* The band-limited oscillators alias far less than their naive forms would:
 * a 2.4 kHz tone on an FFT bin at 48 kHz, HiQuality off, the filters open,
 * and HiQuality (2x) lower still. */
static double drift_alias_db(int32_t type, int hq) {
  enum { WIN = 8192, SETTLE = 4096 };
  static float l[WIN + SETTLE], r[WIN + SETTLE];
  const int bin = 409; /* odd: 2398.7 Hz */
  const double hz = (double)bin * DRIFT_SR / WIN;
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_HIQUALITY, (float)hq);
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
   * Shark Tooth -34.8, Pulse -30.1, Triangle -58.3 dB, and HiQuality 17 to
   * 28 dB lower; the limits keep 4 dB of that */
  static const struct { int32_t type; double most; } kinds[] = {
      {4, -28.0}, {6, -32.0}, {2, -30.0}, {5, -26.0}, {1, -54.0}};
  for (size_t k = 0; k < sizeof(kinds) / sizeof(kinds[0]); ++k) {
    const double off = drift_alias_db(kinds[k].type, 0);
    const double on = drift_alias_db(kinds[k].type, 1);
    printf("  type %d: alias %.1f dB, HiQuality %.1f dB\n", kinds[k].type, off, on);
    CHECK(off < kinds[k].most);
    CHECK(on < off - 12.0);
  }
}

/* Attack rises linearly to 1 over its time, decay settles at Sustain, and a
 * release ends the voice once it falls below -60 dB: from Sustain 0.3, at
 * 0.25 s x ln(300) / ln(1000), 0.206 s. */
static void test_drift_envelope_shapes(void) {
  printf("test_drift_envelope_shapes\n");
  static float l[DRIFT_SR], r[DRIFT_SR];
  drift_init(&g_drift, DRIFT_SR);
  drift_set(&g_drift, LE_DRIFT_HIQUALITY, 0.0f);
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
  drift_set(&g_drift, LE_DRIFT_VOICE_COUNT, 0.0f); /* 8 voices */
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
  CHECK(e->drift[2].values[LE_DRIFT_VOICE_MODE] == 2.0f);
  /* clamped to its range */
  CHECK(le_engine_set_instrument_device_param(e, 2, LE_DRIFT_FILTER_FREQ, 1e6f) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(e->drift[2].values[LE_DRIFT_FILTER_FREQ] == 20000.0f);
  CHECK(le_engine_instrument_note_off(e, 1) == LE_OK);
  CHECK(le_engine_instrument_note_off(e, 2) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(!le_drift_held(&e->drift[2], ins_origin(1)));
  /* a patch ends the device */
  CHECK(le_engine_instrument_note_on(e, 2, 3, 60, 100) == LE_OK);
  CHECK(le_engine_set_instrument(e, 2, syn_patch("pad"), NULL) == LE_OK);
  drift_run(e, 960, 64, 2, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[2] == LE_INST_DEVICE_NONE);
  CHECK(snap.instrument_patch[2] == syn_patch("pad"));
  CHECK(le_drift_active(&e->drift[2]) == 0 && le_drift_fading(&e->drift[2]) == 0);
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
  CHECK(le_engine_set_instrument_device(e, 0, 2, NULL) == LE_ERR_INVALID);
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
  CHECK(le_drift_active(&e->drift[1]) == 1);
  ins_send(&cap, 0xB0, 64, 127); /* sustain */
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(e->drift[1].voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(e->drift[1].voices[0].state == 2); /* released */
  ins_send(&cap, 0x90, 62, 100);
  ins_send(&cap, 0xE0, 0, 127); /* bend up: (16256 - 8192) / 8192 */
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(fabsf(e->drift[1].bend - 0.984375f) < 1e-6f);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  CHECK(le_drift_active(&e->drift[1]) == 0 && le_drift_fading(&e->drift[1]) == 0);
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
  test_engine_drift_slot_matches_offline();
  test_engine_drift_params_and_switching();
  test_engine_drift_refusals();
  test_engine_drift_midi();
}
