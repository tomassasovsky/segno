/*
 * synth_voice.h — the Segno instrument voice pool and patch table (#1197).
 *
 * Nineteen synthesis patches in seven families (Keys, Organs, Synths, Bass,
 * Strings, Drums, Percussion), each with three family parameters on a 0..100
 * scale, rendered by one fixed pool of voices into one mono bus per
 * instrument. The definitions follow the accepted prototype
 * (docs/design/instrument-catalogue.js and instrument-runtime.js in the main
 * checkout); the plan is docs/plan/2026-10-06-feat-instruments-plan.md.
 *
 * Pure and real-time safe: no engine types, no atomics, no allocation, no
 * locks and no syscalls. le_synth_init is the only function that may be slow
 * (it fills the sine table and the note frequencies); everything else is
 * bounded by the pool and the block. Control-rate values (filter coefficients,
 * LFO, pitch modulation, family parameters) update on a fixed grid of
 * LE_SYNTH_CTRL_FRAMES frames counted from init, independent of how the
 * caller splits its blocks, so the same events at the same frames render the
 * same samples at any block size.
 *
 * Single-threaded: one thread (the audio callback, once the engine owns a
 * synth) calls every function on a given le_synth.
 */
#ifndef SEGNO_SYNTH_VOICE_H
#define SEGNO_SYNTH_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_synth_family, le_synth_param_unit */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_SYNTH_MAX_INSTRUMENTS 8
#define LE_SYNTH_DEFAULT_VOICES 32
#define LE_SYNTH_MAX_VOICES 64
/* A stolen voice (or one struck again) fades over LE_SYNTH_FADE_MS in one of
 * these slots, so a steal never clicks and the new note starts in the same
 * block. One per pool voice, so even a full pool stolen in one burst fades;
 * only more than that many steals within 3 ms overwrite a fade (counted in
 * stolen_hard). Cut and patch changes fade voices in place instead. */
#define LE_SYNTH_FADE_SLOTS LE_SYNTH_MAX_VOICES
#define LE_SYNTH_FADE_MS 3
#define LE_SYNTH_CTRL_FRAMES 32
#define LE_SYNTH_SINE_SIZE 2048

/* Families (le_synth_family) and parameter units (le_synth_param_unit) are
 * the public enums in segno_engine_api.h. */

enum {
  LE_SYNTH_WAVE_SINE = 0,
  LE_SYNTH_WAVE_TRIANGLE = 1,
  LE_SYNTH_WAVE_SAW = 2,
  LE_SYNTH_WAVE_SQUARE = 3,
  LE_SYNTH_WAVE_NOISE = 4,
};

/* One patch: the catalogue's (wave, ratio, level) plus what the voice needs. */
typedef struct le_synth_patch {
  const char* id;        /* stable identity, stored by sessions */
  int32_t family;        /* LE_SYNTH_KEYS .. LE_SYNTH_PERCUSSION */
  int32_t wave;          /* first partial's waveform */
  float ratio;           /* second partial's frequency ratio */
  float level;           /* sustain level of a transient patch, of the peak */
  float resonance;       /* filter Q (2.8 for the resonant leads, else 0.7) */
  int32_t transient;     /* decays to `level` (Keys, Bass, Percussion, pluck) */
  int32_t extra_partial; /* 0, or 1 for bells' 5.4x partial */
  int32_t electronic;    /* drums: the electronic kick sweep */
  float defaults[LE_SYNTH_FAMILY_PARAMS]; /* 0..100 */
} le_synth_patch;

/* One family parameter: its key and the mapping from 0..100 to `unit`. */
typedef struct le_synth_param {
  const char* key;
  int32_t unit;
  float at_min;        /* the value at 0 */
  float at_max;        /* the value at 100 */
  int32_t exponential; /* 1: at_min * (at_max / at_min) ^ (v / 100) */
} le_synth_param;

/* The patch at `index` (0..LE_SYNTH_PATCHES-1), or NULL. */
const le_synth_patch* le_synth_patch_at(int32_t index);
/* Index of the patch whose id is `id`, or -1. */
int32_t le_synth_patch_find(const char* id);
/* Parameter `index` (0..2) of `family`, or NULL. */
const le_synth_param* le_synth_family_param(int32_t family, int32_t index);
/* The parameter's value in its unit for a 0..100 setting (clamped). */
float le_synth_param_value(const le_synth_param* p, float v);

typedef struct le_synth_voice {
  int32_t state; /* LE_SYNTH_VOICE_* (synth_voice.c) */
  int32_t inst;
  int32_t patch;
  int32_t note;
  uint32_t origin;
  uint64_t serial; /* start order: the stealing age */
  float velocity;  /* 0..1 */
  float hz;
  /* oscillators: up to four partials (drums use 0 and 1) */
  int32_t partials;
  int32_t wave[4];
  float mult[4]; /* frequency multiple of hz */
  float phase[4];
  float inc[4];
  float gain[4];
  /* state-variable filter, coefficients per control block */
  float ic1, ic2, a1, a2, a3, k;
  int32_t highpass;
  /* envelope: attack (linear) -> decay (exponential) -> sustain; release
   * approaches -rel_floor exponentially and ends where it crosses zero */
  int32_t stage;
  float env;
  float att_step;
  int32_t att_left;
  float peak;
  float dec_mul;
  float dec_target;
  int32_t dec_left;
  float rel_floor;
  float rel_k;
  /* amplitude modulation, interpolated across the control block */
  float amp;
  float amp_step;
  float lfo_phase;
  /* drums */
  int32_t drum; /* 0, or LE_SYNTH_DRUM_* (synth_voice.c) */
  float sweep_mul;
  int32_t sweep_left;
  uint32_t noise;
  /* fade slots only */
  float fade;
  float fade_step;
} le_synth_voice;

typedef struct le_synth_instrument {
  int32_t patch; /* -1: none */
  float params[LE_SYNTH_FAMILY_PARAMS];
} le_synth_instrument;

typedef struct le_synth {
  int32_t sample_rate;
  int32_t voice_count; /* the pool size, <= LE_SYNTH_MAX_VOICES */
  int32_t voice_limit; /* sounding voices allowed, <= voice_count (overload) */
  uint32_t seed;
  uint64_t serial;
  int32_t ctrl_left; /* frames until the next control update */
  float sine[LE_SYNTH_SINE_SIZE + 1];
  float note_hz[128];
  le_synth_instrument inst[LE_SYNTH_MAX_INSTRUMENTS];
  le_synth_voice voices[LE_SYNTH_MAX_VOICES];
  le_synth_voice fades[LE_SYNTH_FADE_SLOTS];
  uint32_t stolen;      /* voices taken for a new note (faded) */
  uint32_t stolen_hard; /* voices or fades cut without a fade (no room) */
} le_synth;

/* Prepares `s` for `sample_rate` with a pool of `voices` (1..64). No
 * instrument has a patch afterwards. Returns 0, or -1 on bad arguments. */
int32_t le_synth_init(le_synth* s, int32_t sample_rate, int32_t voices,
                      uint32_t seed);

/* Gives instrument `inst` patch `patch` (-1 for none) with the patch's
 * default parameters. A change fades that instrument's sounding voices.
 * Returns 0, or -1 on bad arguments. */
int32_t le_synth_set_instrument(le_synth* s, int32_t inst, int32_t patch);

/* Sets family parameter `index` of instrument `inst` (0..100, clamped); it
 * applies from the next control block. Returns 0, or -1. */
int32_t le_synth_set_param(le_synth* s, int32_t inst, int32_t index, float v);

/* Starts `note` (0..127) at `velocity` (1..127) on `inst` for `origin`. A
 * held voice of the same instrument and origin is faded first (a repeated
 * strike). Drums play only their defined notes. Returns 0 when a voice
 * started, -1 when the note was not played. */
int32_t le_synth_note_on(le_synth* s, int32_t inst, uint32_t origin,
                         int32_t note, int32_t velocity);

/* Releases every held voice started for `origin` (drums ignore it). */
void le_synth_note_off(le_synth* s, uint32_t origin);

/* Cut all sound: every sounding voice of `inst` (-1: every instrument) fades
 * to silence over LE_SYNTH_FADE_MS in place. */
void le_synth_cut(le_synth* s, int32_t inst);

/* Allows at most `limit` (1..pool) sounding voices: the overload policy's
 * control. Lowering it fades the excess in stealing order; later notes steal
 * at the limit. Returns 0, or -1 for a limit out of range. */
int32_t le_synth_set_voice_limit(le_synth* s, int32_t limit);

/* Renders `frames` into bus[0..n_bus-1] (each zeroed first; a NULL bus is
 * skipped, its voices still advance). Instrument i writes bus[i]. */
void le_synth_render(le_synth* s, float* const* bus, int32_t n_bus,
                     int32_t frames);

/* Sounding (held or releasing, not fading) voices of `inst`, or of every
 * instrument for -1. */
int32_t le_synth_active(const le_synth* s, int32_t inst);
/* Voices fading out (stolen, struck again, or cut by a patch change). */
int32_t le_synth_fading(const le_synth* s);
/* Whether a sounding voice for `origin` exists (held or releasing). */
int32_t le_synth_has_origin(const le_synth* s, uint32_t origin);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_SYNTH_VOICE_H */
