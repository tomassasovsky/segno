/*
 * analog_voice.h — the Analog device: two chains per voice, each an
 * oscillator, a filter with drive, an amplifier, an LFO, a filter and an amp
 * envelope, fed also by a noise source, with glide, vibrato and unison
 * (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Analog: behavior"), learned from Live 12.2.7's Analog
 * bundle and written there in Segno's words; this code is written from that
 * description. Values it leaves open are fitted against Live renders and
 * marked "fit" in analog_voice.c.
 *
 * One le_analog per instrument slot that plays the device. Pure and
 * real-time safe like meld_voice.c: no allocation, no locks, no syscalls on
 * the audio path. Control values (pitch, cutoffs, gains) are recomputed
 * once per 32 samples (LE_ANALOG_TICK); the oscillators, filters and
 * envelopes run every sample. A note takes one voice of 1, 2 or 4 unison
 * copies.
 *
 * Notes follow le_synth's rules, as the other devices do. Single-threaded.
 */
#ifndef SEGNO_ANALOG_VOICE_H
#define SEGNO_ANALOG_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_analog_param, LE_ANALOG_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_ANALOG_VOICE_SLOTS 40
#define LE_ANALOG_COPIES 4
#define LE_ANALOG_TICK 32
#define LE_ANALOG_SUSTAIN_MAX 16
#define LE_ANALOG_HELD_MAX 16
#define LE_ANALOG_FADE_MS 1 /* a stolen or cut voice's fade */
#define LE_ANALOG_BL_HALF 13   /* the band-limited step's half length, samples */
#define LE_ANALOG_BL_PHASES 512 /* its table's fractional positions */
#define LE_ANALOG_BL_RING 32   /* the oscillator's output ring (a power of 2) */

typedef struct le_analog_env {
  int32_t seg;    /* ANALOG_SEG_* (analog_voice.c) */
  int32_t left;   /* samples left in the segment */
  float y, y0, to, c, step;
  float scale;    /* velocity's level scale */
} le_analog_env;

/* What a chain's control tick holds until the next one (analog_voice.c). */
typedef struct le_analog_tick {
  float fc, q, k;       /* the filter */
  float pw;             /* the pulse width, a fraction of the period */
  float sub, ratio;     /* the sub level, the sync ratio (0: no sync) */
  float to_f1, to_f2;   /* the oscillator's levels into each filter */
  float n_f1, n_f2;     /* the noise's */
  float link;           /* filter 1 into filter 2 */
} le_analog_tick;

/* One chain of one copy. */
typedef struct le_analog_chain {
  double ph, ph2;      /* the oscillator (or sync slave) and its sub/master */
  int32_t sub_sign;    /* the sub square's level, toggled at each reset */
  float dc;            /* the integrator's leak */
  float inc, inc_m;    /* per-sample increments: oscillator (slave), master */
  float penv;          /* the pitch envelope, 1 -> 0 */
  float penv_step;
  float s[3][2];       /* the filter's 2-pole stages (the formants': three) */
  float g[3], k;       /* their coefficients (one g but for the formants) */
  float level[3];      /* the formants' band levels */
  float fc;            /* the modulated cutoff (filter 2 follows it) */
  le_analog_env fenv, aenv;
  double lfo_ph;
  float lfo, lfo_sh, lfo_sh_prev, lfo_amp, lfo_wait;
  float gl, gr, gl_step, gr_step; /* the amp's gains but the envelope, ramped across a tick */
  float noise_lp;
  float ring[LE_ANALOG_BL_RING]; /* the oscillator's output, LE_ANALOG_BL_HALF samples late */
  int32_t ring_at;               /* the slot of the current sample */
  le_analog_tick t;    /* this tick's values */
} le_analog_chain;

typedef struct le_analog_copy {
  le_analog_chain ch[2];
  float detune;   /* octaves: the copy's unison offset */
  int32_t delay;  /* samples before the copy starts */
  float noise_lp;
  float noise_ring[LE_ANALOG_BL_RING]; /* the noise, as late as the oscillators */
  int32_t noise_at;
  uint32_t rng;
} le_analog_copy;

typedef struct le_analog_voice {
  int32_t state; /* LE_ANALOG_VOICE_* (analog_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  float velocity; /* 0..1 */
  int32_t copies;
  float pitch, pitch_to; /* the keyboard pitch in octaves from C4, glided */
  float glide_c;         /* per-tick glide coefficient */
  double vib_ph;
  float vib_t;           /* seconds since the note (vibrato delay and fade) */
  float vib_dev;         /* this vibrato cycle's rate deviation, a fraction */
  int32_t tick_left;
  int32_t since;      /* samples since the note, saturating */
  int32_t fade_left;  /* stolen or cut: samples of fade left */
  int32_t fade_len;   /* samples a millisecond */
  le_analog_copy c[LE_ANALOG_COPIES];
} le_analog_voice;

typedef struct le_analog {
  int32_t sample_rate;
  uint64_t serial;
  float bpm;
  float values[LE_ANALOG_PARAMS];
  float bend, mod, pressure;
  uint32_t sustain[LE_ANALOG_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  int32_t held_n;
  int32_t held_note[LE_ANALOG_HELD_MAX];
  uint32_t held_origin[LE_ANALOG_HELD_MAX];
  float last_pitch;
  int32_t played;
  int32_t voice_limit;
  uint32_t stolen;
  uint32_t rng;
  /* the band-limited step's residual (analog_voice.c) */
  float bl[LE_ANALOG_BL_PHASES + 1][2 * LE_ANALOG_BL_HALF];
  le_analog_voice voices[LE_ANALOG_VOICE_SLOTS];
} le_analog;

float le_analog_default(int32_t param);
float le_analog_clamp(int32_t param, float value);
int32_t le_analog_init(le_analog* d, int32_t sample_rate);
void le_analog_set_values(le_analog* d, const float* values);
int32_t le_analog_note_on(le_analog* d, uint32_t origin, int32_t note, int32_t velocity, int chord);
void le_analog_note_off(le_analog* d, uint32_t origin);
int32_t le_analog_sustain(le_analog* d, uint32_t origin, int on);
void le_analog_expression(le_analog* d, int32_t kind, float value);
void le_analog_release_matching(le_analog* d, uint32_t mask, uint32_t value);
int32_t le_analog_held(const le_analog* d, uint32_t origin);
void le_analog_cut(le_analog* d);
void le_analog_set_voice_limit(le_analog* d, int32_t limit);
int32_t le_analog_fade_oldest(le_analog* d);
void le_analog_set_tempo(le_analog* d, float bpm);
void le_analog_render(le_analog* d, float* left, float* right, int32_t frames);
int32_t le_analog_active(const le_analog* d);
int32_t le_analog_fading(const le_analog* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ANALOG_VOICE_H */
