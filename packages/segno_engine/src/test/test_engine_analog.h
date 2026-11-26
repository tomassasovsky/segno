/* SEG-109: the Analog device. Its own module first (analog_voice.c, driven
 * directly), then a slot of the engine playing it. Included from
 * test_engine_core.c after test_engine_meld.h (opr_* helpers, drift_run,
 * the ins_* helpers); SEGNO_INSTRUMENT_TESTS_ONLY=1 runs these with the
 * instrument tests. */

#include "analog_voice.h"

/* Slot k's Analog instance in engine e. */
static le_analog* eng_analog(le_engine* e, int32_t k) {
  return (le_analog*)le_instruments_device(e, LE_INST_DEVICE_ANALOG, k);
}

static le_analog g_analog;

/* Sets one parameter, the others as they are. */
static void analog_set(le_analog* d, int32_t p, float v) {
  static float vals[LE_ANALOG_PARAMS];
  memcpy(vals, d->values, sizeof(vals));
  vals[p] = v;
  le_analog_set_values(d, vals);
}

static void analog_chain(le_analog* d, int32_t c, int32_t field, float v) {
  analog_set(d, LE_ANALOG_CHAIN(c, field), v);
}

/* A reference patch: chain 1's sine at full oscillator level, no filter,
 * the amp envelope at once and held at full. Its peak per channel is
 * 0.7 (the sine) x 3 (the oscillator level) x 0.144 (the amp level at its
 * centre) x 0.707 (the centre pan) x 1 (the volume at its default). */
static const float kAnalogSinePeak = 0.2145f;

static void analog_reference(le_analog* d) {
  CHECK(le_analog_init(d, OPR_SR) == 0);
  le_analog_set_voice_limit(d, LE_ANALOG_VOICE_SLOTS);
  analog_chain(d, 0, LE_ANALOG_OSC_SHAPE, 0.0f);
  analog_chain(d, 0, LE_ANALOG_FILTER_ON, 0.0f);
  analog_chain(d, 0, LE_ANALOG_OSC_LEVEL, 1.0f);
  analog_chain(d, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_ATTACK, 0.0f);
  analog_chain(d, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_SUSTAIN, 1.0f);
}

/* The sine's level and pitch, the pan law and the two oscillators' routes
 * into their own chains. */
static void test_analog_levels(void) {
  printf("test_analog_levels\n");
  enum { N = 9600 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - kAnalogSinePeak) < 0.002f);
  CHECK(fabsf(opr_peak(r + N / 2, N / 2) - kAnalogSinePeak) < 0.002f);
  CHECK(fabs(opr_component(l + N / 2, N / 2, opr_note_hz(60)) - kAnalogSinePeak) < 0.005);
  /* pan at 0: all of it on the left, at the full gain */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_PAN, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - kAnalogSinePeak * 1.41421356f) < 0.003f);
  CHECK(opr_peak(r + N / 2, N / 2) < 1e-6f);
  /* oscillator 1 sent all the way to filter 2 reaches chain 2's amp, which
   * is off by default: silence */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_BALANCE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l, N) < 1e-6f);
  /* oscillator 2 on its own chain, an octave up */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_ON, 0.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_OSC_ON, 1.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_OSC_SHAPE, 0.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_OSC_OCT, 1.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_OSC_LEVEL, 1.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_FILTER_ON, 0.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_AMP_ON, 1.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_ATTACK, 0.0f);
  analog_chain(&g_analog, 1, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_SUSTAIN, 1.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(fabs(opr_component(l + N / 2, N / 2, opr_note_hz(72)) - kAnalogSinePeak) < 0.005);
}

/* Every shape through every filter type and drive, at the cutoff and
 * resonance extremes, stays finite and bounded, on both chains. */
static void test_analog_every_shape_and_filter(void) {
  printf("test_analog_every_shape_and_filter\n");
  enum { N = 4800 };
  static float l[N], r[N];
  for (int32_t shape = 0; shape < 4; ++shape) {
    for (int32_t type = 0; type < 10; ++type) {
      for (int m = 0; m < 3; ++m) {
        analog_reference(&g_analog);
        analog_set(&g_analog, LE_ANALOG_NOISE_ON, 1.0f);
        for (int32_t c = 0; c < 2; ++c) {
          analog_chain(&g_analog, c, LE_ANALOG_OSC_ON, 1.0f);
          analog_chain(&g_analog, c, LE_ANALOG_OSC_SHAPE, (float)shape);
          analog_chain(&g_analog, c, LE_ANALOG_OSC_MODE, (float)(m == 2));
          analog_chain(&g_analog, c, LE_ANALOG_OSC_SUB, 1.0f);
          analog_chain(&g_analog, c, LE_ANALOG_AMP_ON, 1.0f);
          analog_chain(&g_analog, c, LE_ANALOG_AMP_LEVEL, 1.0f);
          analog_chain(&g_analog, c, LE_ANALOG_FILTER_ON, 1.0f);
          analog_chain(&g_analog, c, LE_ANALOG_FILTER_TYPE, (float)type);
          analog_chain(&g_analog, c, LE_ANALOG_FILTER_DRIVE, (float)(m * 3));
          analog_chain(&g_analog, c, LE_ANALOG_FILTER_CUTOFF, m * 0.5f);
          analog_chain(&g_analog, c, LE_ANALOG_FILTER_Q, 1.0f - m * 0.5f);
        }
        analog_chain(&g_analog, 0, LE_ANALOG_CHAIN_LINK, 1.0f);
        CHECK(le_analog_note_on(&g_analog, 1, m == 1 ? 96 : 36, 127, 0) == 0);
        le_analog_render(&g_analog, l, r, N);
        CHECK(opr_finite(l, N) && opr_finite(r, N));
        /* the filters are linear: at Q 100 a 30 Hz cutoff under a 65 Hz
         * note, both chains at full level and filter 1 fed into filter 2,
         * rings into the hundreds */
        CHECK(opr_peak(l, N) < 4096.0f && opr_peak(r, N) < 4096.0f);
      }
    }
  }
}

/* The formant types ring at a vowel's formants: at both knobs' centre the
 * first two formants sit near 612 and 960 Hz and the response dips by far
 * more between the second and third (near 1.85 kHz). */
static void test_analog_formant(void) {
  printf("test_analog_formant\n");
  enum { N = 48000 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_SHAPE, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_ON, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_TYPE, 8.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_CUTOFF, 0.5f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_Q, 0.5f);
  CHECK(le_analog_note_on(&g_analog, 1, 36, 127, 0) == 0); /* 65.4 Hz */
  le_analog_render(&g_analog, l, r, N);
  const double f0 = opr_note_hz(36);
  /* the saw's harmonics fall as 1 / k: undo that to read the filter */
  const double h9 = 9.0 * opr_component(l + N / 2, N / 2, 9.0 * f0);    /* 589 Hz */
  const double h28 = 28.0 * opr_component(l + N / 2, N / 2, 28.0 * f0); /* 1831 Hz */
  const double h2 = 2.0 * opr_component(l + N / 2, N / 2, 2.0 * f0);    /* 131 Hz */
  CHECK(h9 > 40.0 * h28);
  CHECK(h9 > 8.0 * h2);
}

/* A linear attack is halfway at half its time; a released note ends. */
static void test_analog_envelopes(void) {
  printf("test_analog_envelopes\n");
  enum { N = 48000 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_EXP, 0.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_ATTACK, 0.5f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  /* 5 ms x 3000^0.504 = 0.28 s: halfway at 0.14 s */
  const float half = opr_peak(l + 6600, 400) / kAnalogSinePeak;
  CHECK(half > 0.44f && half < 0.56f);
  CHECK(opr_peak(l + 24000, 2000) > 0.99f * kAnalogSinePeak);
  /* a short release: the voice ends with the key up */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, 4800);
  le_analog_note_off(&g_analog, 1);
  le_analog_render(&g_analog, l, r, 9600);
  CHECK(le_analog_active(&g_analog) == 0);
  /* a sustain that falls to 0 over its Sustain Time: silent while held */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_SUSTAIN_TIME, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l + N - 4800, 4800) < 0.01f * kAnalogSinePeak);
}

/* Unison: a note of 2 or 4 copies, each one voice of the budget. */
static void test_analog_unison(void) {
  printf("test_analog_unison\n");
  enum { N = 9600 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_UNISON_ON, 1.0f);
  analog_set(&g_analog, LE_ANALOG_UNISON, 1.0f);
  analog_set(&g_analog, LE_ANALOG_UNISON_DETUNE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  CHECK(le_analog_active(&g_analog) == 4);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_finite(l, N));
  CHECK(le_analog_fade_oldest(&g_analog) == 4);
  /* detuned copies: no longer one coherent sine at the note */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_UNISON_ON, 1.0f);
  analog_set(&g_analog, LE_ANALOG_UNISON, 0.0f);
  analog_set(&g_analog, LE_ANALOG_UNISON_DETUNE, 0.5f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  CHECK(le_analog_active(&g_analog) == 2);
  le_analog_render(&g_analog, l, r, N);
  /* the second copy is 0.374 semitone up */
  CHECK(opr_component(l, N, opr_note_hz(60) * pow(2.0, 0.374 / 12.0)) > 0.3 * kAnalogSinePeak);
}

/* Voice counts, stealing, mono priority, glide, sustain and Cut. */
static void test_analog_voices(void) {
  printf("test_analog_voices\n");
  enum { N = 4800 };
  static float l[N], r[N];
  /* two voices: a third note steals the oldest */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 1.0f);
  for (uint32_t o = 1; o <= 3; ++o) CHECK(le_analog_note_on(&g_analog, o, 60 + (int)o, 100, 0) == 0);
  CHECK(le_analog_active(&g_analog) == 2);
  CHECK(le_analog_fading(&g_analog) == 1);
  CHECK(g_analog.stolen == 1);
  /* mono, low priority: a higher key waits for the lower one's release */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 1.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 100, 0) == 0);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  CHECK(le_analog_active(&g_analog) == 1 && le_analog_fading(&g_analog) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(48)) > 0.8 * kAnalogSinePeak);
  le_analog_note_off(&g_analog, 1);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.8 * kAnalogSinePeak);
  /* last priority: the newest key at once */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 100, 0) == 0);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.8 * kAnalogSinePeak);
  /* and back to the held key when it is let go */
  le_analog_note_off(&g_analog, 2);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(48)) > 0.8 * kAnalogSinePeak);
  /* glide: between the two keys 20 ms in */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  analog_set(&g_analog, LE_ANALOG_GLIDE_ON, 1.0f);
  analog_set(&g_analog, LE_ANALOG_GLIDE_TIME, 0.5f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, 960);
  CHECK(g_analog.voices[0].pitch > 48.5f / 12.0f - 5.0f && g_analog.voices[0].pitch < 59.5f / 12.0f - 5.0f);
  /* sustain holds a released note; Cut fades everything */
  analog_reference(&g_analog);
  CHECK(le_analog_sustain(&g_analog, 9, 1) == 0);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 100, 0) == 0);
  le_analog_note_off(&g_analog, 1);
  CHECK(le_analog_held(&g_analog, 1) == 0);
  CHECK(le_analog_active(&g_analog) == 1);
  le_analog_cut(&g_analog);
  le_analog_render(&g_analog, l, r, N);
  CHECK(le_analog_active(&g_analog) == 0 && le_analog_fading(&g_analog) == 0);
}

/* Renders n frames in blocks of `block`, a stealing note at 4000 and its
 * release at 6000 landing inside whatever block they fall in. */
static void analog_play(le_analog* d, float* l, float* r, int32_t n, int32_t block) {
  static const int32_t at[2] = {4000, 6000};
  int32_t i = 0, ev = 0;
  while (i < n) {
    int32_t m = n - i < block ? n - i : block;
    if (ev < 2 && i + m > at[ev]) m = at[ev] - i;
    if (m > 0) le_analog_render(d, l + i, r + i, m);
    i += m;
    if (ev < 2 && i == at[ev]) {
      if (ev == 0) CHECK(le_analog_note_on(d, 2, 64, 100, 0) == 0);
      else le_analog_note_off(d, 2);
      ev++;
    }
  }
}

/* Rendering in any block size gives the same samples: the notes, a
 * delayed unison copy, a release that ends and a voice stolen by a note
 * the budget cannot also hold. */
static void test_analog_block_size(void) {
  printf("test_analog_block_size\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static const int32_t blocks[] = {1, 7, 64, 333};
  for (int b = -1; b < 4; ++b) {
    analog_reference(&g_analog);
    analog_chain(&g_analog, 0, LE_ANALOG_OSC_SHAPE, 1.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_FILTER_ON, 1.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_FILTER_TYPE, 1.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_LFO_ON, 1.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_FILTER_LFO_CUTOFF, 0.5f);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_EXP, 0.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.05f);
    analog_set(&g_analog, LE_ANALOG_UNISON_ON, 1.0f);
    analog_set(&g_analog, LE_ANALOG_UNISON_DELAY, 0.3f);
    le_analog_set_voice_limit(&g_analog, 2); /* one two-copy note */
    CHECK(le_analog_note_on(&g_analog, 1, 57, 100, 0) == 0);
    analog_play(&g_analog, b < 0 ? ref_l : l, b < 0 ? ref_r : r, N, b < 0 ? N : blocks[b]);
    if (b < 0) {
      CHECK(g_analog.stolen == 1 && le_analog_active(&g_analog) == 0);
      continue;
    }
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
  }
}

/* A note starts from rest: nothing of the slot's last note rings on. */
static void test_analog_fresh_voice(void) {
  printf("test_analog_fresh_voice\n");
  enum { N = 9600 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_SHAPE, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_ON, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_FILTER_Q, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  le_analog_note_off(&g_analog, 1);
  le_analog_render(&g_analog, l, r, N);
  CHECK(le_analog_active(&g_analog) == 0);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_ON, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 2, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l, N) == 0.0f);
}

/* Mono hand-offs: a key pressed again while another is held sounds with
 * Legato on, and a glide starts from the key the voice last moved to. */
static void test_analog_mono_hand_offs(void) {
  printf("test_analog_mono_hand_offs\n");
  enum { N = 9600 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_LEGATO, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 100, 0) == 0);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l + N / 2, N / 2, opr_note_hz(60)) > 0.8 * kAnalogSinePeak);
  /* glide: 48, 60, back to 48, let go; the next key glides from 48 */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  analog_set(&g_analog, LE_ANALOG_GLIDE_ON, 1.0f);
  analog_set(&g_analog, LE_ANALOG_GLIDE_TIME, 0.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 100, 0) == 0);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 100, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  le_analog_note_off(&g_analog, 2);
  le_analog_render(&g_analog, l, r, N);
  le_analog_note_off(&g_analog, 1);
  le_analog_render(&g_analog, l, r, N);
  CHECK(le_analog_active(&g_analog) == 0);
  CHECK(le_analog_note_on(&g_analog, 3, 55, 100, 0) == 0);
  for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
    if (g_analog.voices[i].state == 1) CHECK(fabsf(g_analog.voices[i].pitch - (-1.0f)) < 1e-6f);
  }
}

/* Where the saw and the rectangle start, as Live's do: nothing for the
 * band-limited step's half length, the saw's first reset half a period in,
 * the rectangle without a DC offset from its first cycle. */
static void test_analog_oscillator_start(void) {
  printf("test_analog_oscillator_start\n");
  enum { N = 24000 };
  static float l[N], r[N];
  const double period = OPR_SR / (opr_note_hz(48) * pow(2.0, -0.98 / 1200.0));
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_SHAPE, 1.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l, LE_ANALOG_BL_HALF) == 0.0f);
  int32_t drop = 0;
  for (int32_t i = 1; i < (int32_t)period; ++i) { /* the first cycle */
    if (l[i] - l[i + 1] > l[drop] - l[drop + 1]) drop = i;
  }
  CHECK(fabs((double)drop - (LE_ANALOG_BL_HALF + 0.5 * period)) < 4.0);
  /* the narrowest pulse: its mean over whole cycles is 0 from the start */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_SHAPE, 2.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_PW, 0.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  const int32_t a = 2400, n = (int32_t)(10.0 * period);
  double mean = 0.0;
  for (int32_t i = a; i < a + n; ++i) mean += l[i];
  mean /= n;
  CHECK(fabs(mean) < 0.01 * opr_peak(l + a, n));
}

/* A mono key change retriggers the amp envelope through a drop to 0. */
static void test_analog_mono_retrigger(void) {
  printf("test_analog_mono_retrigger\n");
  enum { N = 4800 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l + N / 2, N / 2) > 0.9f * kAnalogSinePeak);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_peak(l + 31, 6) < 0.1f * kAnalogSinePeak); /* the drop's 0.7 ms */
  CHECK(opr_peak(l + N / 2, N / 2) > 0.9f * kAnalogSinePeak);
}

/* The LFOs and the vibrato at a note's start: a free S&H holds 0 for its
 * first cycle, a fresh voice's free LFO has run since the device started,
 * a mono key change restarts a retriggered LFO's fade-in, and a mono
 * voice's vibrato runs on through silence while a poly voice's starts at
 * 0. */
static void test_analog_lfo_starts(void) {
  printf("test_analog_lfo_starts\n");
  enum { N = 4800 };
  static float l[N], r[N];
  /* a free S&H: 0 until its first cycle ends */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_ON, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_WAVE, 3.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_GATE_RESET, 0.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_SPEED, 0.2f); /* 0.16 Hz */
  analog_chain(&g_analog, 0, LE_ANALOG_AMP_LFO_VOL, 1.0f);
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(g_analog.voices[0].c[0].ch[0].lfo == 0.0f);
  CHECK(fabsf(opr_peak(l + N / 2, N / 2) - kAnalogSinePeak) < 0.002f);
  /* a free LFO on a fresh voice: three quarters of Phase at the device's
   * start, then the free rate */
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_ON, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_GATE_RESET, 0.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_PHASE, 1.0f);
  le_analog_render(&g_analog, l, r, N); /* 0.1 s of silence */
  CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, 1);
  {
    /* Exp(3, 1000) a minute at the knob's 0.5, position 64 of 127 */
    const double hz = 3.0 * pow(1000.0 / 3.0, 64.0 / 127.0) / 60.0;
    double want = 0.75 + hz * (double)(N + LE_ANALOG_TICK) / OPR_SR;
    want -= floor(want);
    CHECK(fabs(g_analog.voices[0].c[0].ch[0].lfo_ph - want) < 2e-4);
  }
  /* a mono key change restarts a retriggered LFO's fade-in */
  analog_reference(&g_analog);
  analog_set(&g_analog, LE_ANALOG_POLYPHONY, 0.0f);
  analog_set(&g_analog, LE_ANALOG_PRIORITY, 2.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_ON, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_LFO_FADE, 0.0001f); /* 0.2 s */
  CHECK(le_analog_note_on(&g_analog, 1, 48, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(g_analog.voices[0].c[0].ch[0].lfo_amp > 0.45f);
  CHECK(le_analog_note_on(&g_analog, 2, 60, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, 64);
  CHECK(g_analog.voices[0].c[0].ch[0].lfo_amp < 0.02f);
  /* the vibrato: a mono voice's runs on through silence, a poly voice's
   * starts at 0 */
  for (int32_t poly = 0; poly < 2; ++poly) {
    analog_reference(&g_analog);
    analog_set(&g_analog, LE_ANALOG_POLYPHONY, poly ? 5.0f : 0.0f);
    analog_set(&g_analog, LE_ANALOG_VIBRATO_ON, 1.0f);
    analog_set(&g_analog, LE_ANALOG_VIBRATO_AMOUNT, 0.5f);
    analog_set(&g_analog, LE_ANALOG_VIBRATO_SPEED, 0.5f);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_RELEASE, 0.0f);
    CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
    le_analog_render(&g_analog, l, r, N);
    le_analog_note_off(&g_analog, 1);
    le_analog_render(&g_analog, l, r, N);
    le_analog_render(&g_analog, l, r, N);
    CHECK(le_analog_active(&g_analog) == 0);
    CHECK(le_analog_note_on(&g_analog, 2, 60, 127, 0) == 0);
    const le_analog_voice* v = NULL;
    for (int32_t i = 0; i < LE_ANALOG_VOICE_SLOTS; ++i) {
      if (g_analog.voices[i].state == 1 /* held */) v = &g_analog.voices[i];
    }
    CHECK(v != NULL);
    double want = poly ? 0.0 : (0.25 + 9.75 * 64.0 / 127.0) * (double)(3 * N) / OPR_SR; /* Lin(0.25, 10) */
    want -= floor(want);
    CHECK(v != NULL && fabs(v->vib_ph - want) < 1e-3);
  }
}

/* Keyboard Stretch turns about A4: at full stretch C2 sits 26 cents flat
 * and A4 in tune. */
static void test_analog_stretch(void) {
  printf("test_analog_stretch\n");
  enum { N = 48000 };
  static float l[N], r[N];
  const double c4 = opr_note_hz(60) * pow(2.0, -0.98 / 1200.0);
  const int32_t notes[2] = {36, 69};
  const double cents[2] = {-26.4, 0.0};
  for (int32_t i = 0; i < 2; ++i) {
    analog_reference(&g_analog);
    analog_set(&g_analog, LE_ANALOG_STRETCH, 1.0f);
    CHECK(le_analog_note_on(&g_analog, 1, notes[i], 127, 0) == 0);
    le_analog_render(&g_analog, l, r, N);
    const double hz = c4 * pow(2.0, (notes[i] - 60) / 12.0 + cents[i] / 1200.0);
    CHECK(opr_component(l + N / 2, N / 2, hz) > 0.9 * kAnalogSinePeak);
  }
}

/* The keyboard pitch goes through the engine's cubic 2^x: a G4 sits 1.15
 * cents sharp of equal temperament against the C4 (fit: a mono G4). */
static void test_analog_key_pitch(void) {
  printf("test_analog_key_pitch\n");
  enum { N = 48000 };
  static float l[N], r[N];
  const double g4 = opr_note_hz(67) * pow(2.0, -0.98 / 1200.0);
  analog_reference(&g_analog);
  CHECK(le_analog_note_on(&g_analog, 1, 67, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  CHECK(opr_component(l, N, g4 * pow(2.0, 1.15 / 1200.0)) > opr_component(l, N, g4) + 0.01 * kAnalogSinePeak);
}

/* The pitch envelope at full depth: the oscillator's first 40-sample tick
 * ramps its period from the unmodulated one, so a C-1 sine swept 6
 * octaves first crosses zero after about 104 samples (fit: penv-1-t015,
 * Live's first crossing at 102). */
static void test_analog_pitch_envelope(void) {
  printf("test_analog_pitch_envelope\n");
  enum { N = 4800 };
  static float l[N], r[N];
  analog_reference(&g_analog);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_OCT, -3.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_ENV_AMOUNT, 1.0f);
  analog_chain(&g_analog, 0, LE_ANALOG_OSC_ENV_TIME, 0.15f);
  CHECK(le_analog_note_on(&g_analog, 1, 36, 127, 0) == 0);
  le_analog_render(&g_analog, l, r, N);
  int32_t cross = 0;
  for (int32_t i = 40; i < N - 1 && cross == 0; ++i) {
    if ((l[i] > 0.0f) != (l[i + 1] > 0.0f)) cross = i;
  }
  CHECK(cross > 96 && cross < 112);
}

/* A free-running amp envelope ignores the key's release: it runs its
 * attack and decay as it would held. */
static void test_analog_free_run(void) {
  printf("test_analog_free_run\n");
  enum { N = 9600 };
  static float a[N], b[N], r[N];
  for (int32_t k = 0; k < 2; ++k) {
    analog_reference(&g_analog);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_FREE_RUN, 1.0f);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_DECAY, 0.4f);
    analog_chain(&g_analog, 0, LE_ANALOG_AMP_ENV + LE_ANALOG_ENV_SUSTAIN, 0.5f);
    float* x = k == 0 ? a : b;
    CHECK(le_analog_note_on(&g_analog, 1, 60, 127, 0) == 0);
    le_analog_render(&g_analog, x, r, 480);
    if (k == 1) le_analog_note_off(&g_analog, 1);
    le_analog_render(&g_analog, x + 480, r, N - 480);
  }
  CHECK(memcmp(a, b, sizeof(a)) == 0);
}

/* ---- the engine: a slot playing Analog ---- */

static void test_engine_analog_slot_matches_offline(void) {
  printf("test_engine_analog_slot_matches_offline\n");
  enum { N = 9600 };
  static float ref_l[N], ref_r[N], l[N], r[N];
  static float values[LE_ANALOG_PARAMS];
  for (int p = 0; p < LE_ANALOG_PARAMS; ++p) values[p] = le_analog_default(p);
  values[LE_ANALOG_UNISON_ON] = 1.0f;
  values[LE_ANALOG_CHAIN(0, LE_ANALOG_LFO_ON)] = 1.0f;
  values[LE_ANALOG_CHAIN(0, LE_ANALOG_FILTER_LFO_CUTOFF)] = 0.4f;
  CHECK(le_analog_init(&g_analog, OPR_SR) == 0);
  le_analog_set_values(&g_analog, values);
  le_analog_set_voice_limit(&g_analog, 32); /* the engine's default limit */
  CHECK(le_analog_note_on(&g_analog, ins_origin(1), 57, 100, 0) == 0);
  le_analog_render(&g_analog, ref_l, ref_r, N);
  static const int32_t blocks[] = {64, 1, 127, 512};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = ins_engine(INS_SR);
    drift_run(e, 640, 64, 0, NULL, NULL);
    CHECK(le_engine_set_instrument_device(e, 0, LE_INST_DEVICE_ANALOG, values) == LE_OK);
    CHECK(le_engine_instrument_note_on(e, 0, 1, 57, 100) == LE_OK);
    drift_run(e, N, blocks[b], 0, l, r);
    CHECK(memcmp(ref_l, l, sizeof(l)) == 0);
    CHECK(memcmp(ref_r, r, sizeof(r)) == 0);
    le_snapshot snap;
    le_engine_get_snapshot(e, &snap);
    CHECK(snap.instrument_device[0] == LE_INST_DEVICE_ANALOG);
    CHECK(snap.instrument_voices[0] == 2);
    CHECK(snap.instrument_peaks[0] > 0.0f);
    le_engine_destroy(e);
  }
}

static void test_engine_analog_params_and_switching(void) {
  printf("test_engine_analog_params_and_switching\n");
  le_engine* e = ins_engine(INS_SR);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ANALOG, NULL) == LE_OK);
  CHECK(le_engine_instrument_note_on(e, 1, 1, 60, 100) == LE_OK);
  drift_run(e, 256, 64, 1, NULL, NULL);
  CHECK(le_analog_active(eng_analog(e, 1)) == 1);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ANALOG_CHAIN(0, LE_ANALOG_FILTER_TYPE), 99.0f) ==
        LE_OK);
  drift_run(e, 64, 64, 1, NULL, NULL);
  CHECK(eng_analog(e, 1)->values[LE_ANALOG_CHAIN(0, LE_ANALOG_FILTER_TYPE)] == 9.0f);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ANALOG_PARAMS, 0.0f) == LE_ERR_INVALID);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ANALOG_VOLUME, NAN) == LE_ERR_INVALID);
  /* Meld ends Analog */
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_MELD, NULL) == LE_OK);
  drift_run(e, 960, 64, 1, NULL, NULL);
  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.instrument_device[1] == LE_INST_DEVICE_MELD);
  CHECK(le_analog_active(eng_analog(e, 1)) == 0 && le_analog_fading(eng_analog(e, 1)) == 0);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_ANALOG, NULL) == LE_OK);
  CHECK(le_engine_set_instrument_device_param(e, 1, LE_ANALOG_PARAMS - 1, 0.0f) == LE_OK);
  CHECK(le_engine_set_instrument_device(e, 1, LE_INST_DEVICE_TENSION + 1, NULL) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_engine_analog_midi(void) {
  printf("test_engine_analog_midi\n");
  le_engine* e = ins_engine(INS_SR);
  ins_capture cap;
  ins_attach(e, &cap, 0);
  CHECK(le_engine_set_instrument_device(e, 2, LE_INST_DEVICE_ANALOG, NULL) == LE_OK);
  le_inst_routes routes;
  memset(&routes, 0, sizeof(routes));
  ins_route(&routes, 2, 0, 0);
  CHECK(le_engine_set_instrument_routes(e, &routes) == LE_OK);
  drift_run(e, 64, 64, 2, NULL, NULL);
  ins_send(&cap, 0x90, 60, 100);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_analog_active(eng_analog(e, 2)) == 1);
  ins_send(&cap, 0xB0, 64, 127);
  ins_send(&cap, 0x80, 60, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(le_analog_active(eng_analog(e, 2)) == 1);
  CHECK(eng_analog(e, 2)->voices[0].state == 3); /* sustained */
  ins_send(&cap, 0xB0, 64, 0);
  drift_run(e, 64, 64, 2, NULL, NULL);
  CHECK(eng_analog(e, 2)->voices[0].state == 2 || eng_analog(e, 2)->voices[0].state == 0);
  CHECK(le_engine_cut_sound(e) == LE_OK);
  drift_run(e, 4800, 64, 2, NULL, NULL);
  CHECK(le_analog_active(eng_analog(e, 2)) == 0 && le_analog_fading(eng_analog(e, 2)) == 0);
  le_engine_destroy(e);
}

static void run_analog_tests(void) {
  test_analog_levels();
  test_analog_every_shape_and_filter();
  test_analog_formant();
  test_analog_envelopes();
  test_analog_unison();
  test_analog_voices();
  test_analog_block_size();
  test_analog_fresh_voice();
  test_analog_mono_hand_offs();
  test_analog_oscillator_start();
  test_analog_mono_retrigger();
  test_analog_lfo_starts();
  test_analog_stretch();
  test_analog_key_pitch();
  test_analog_pitch_envelope();
  test_analog_free_run();
  test_engine_analog_slot_matches_offline();
  test_engine_analog_params_and_switching();
  test_engine_analog_midi();
}
