/*
 * meld_voice.h — the Meld device: two engines per voice, each an oscillator
 * (meld_osc.h), a filter (meld_filter.h), an amplitude and a modulation
 * envelope and two LFOs, a modulation matrix, then the voice's drive and
 * limiter, with stereo output (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Meld: behavior"), learned from Live 12.2.7 and
 * written there in Segno's words; this code is written from that
 * description. Values it leaves open are fitted against Live renders and
 * marked "fit" in meld_voice.c.
 *
 * One le_meld per instrument slot that plays the device. Pure and real-time
 * safe like operator_voice.c: no engine types, no allocation, no locks, no
 * syscalls on the audio path; le_meld_init is the slow call. A note takes
 * one voice of up to three unison copies; each copy runs both engines. The
 * modulation (the Mod envelope, the LFOs, the matrix) runs once per 16
 * samples (LE_MELD_TICK), the oscillators, filters and Amp envelopes every
 * sample.
 *
 * Notes follow le_synth's rules: a note belongs to an origin, a repeated
 * strike from the same origin replaces its held note, a note-off releases
 * every voice of its origin, sustain contributors hold released notes, and
 * Cut fades everything.
 *
 * Single-threaded: the audio callback calls every function on a given
 * le_meld once the engine owns it.
 */
#ifndef SEGNO_MELD_VOICE_H
#define SEGNO_MELD_VOICE_H

#include <stdint.h>

#include "meld_filter.h"
#include "meld_osc.h"
#include "segno_engine_api.h" /* le_meld_param, LE_MELD_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_MELD_VOICE_SLOTS 16
#define LE_MELD_COPIES 3
#define LE_MELD_TICK 16
#define LE_MELD_SUSTAIN_MAX 16
#define LE_MELD_HELD_MAX 16
#define LE_MELD_ROUTES (LE_MELD_MOD_TARGETS * LE_MELD_MOD_SOURCES)

/* One envelope's run state: a segment ramps x from 0 to 1 and the output
 * follows its curve from y0 to y1. x is double: in float its 1/n steps
 * drift by a tenth of a sample over a release, which Live's does not (fit:
 * nloop-55-notes, Live's release over Segno's 1.0000 to the last sample in
 * double, rising to 1.0064 in float) */
typedef struct le_meld_env {
  int32_t state;
  double x;
  float y0, y1, y;
} le_meld_env;

/* LFO 1's transformer state. */
typedef struct le_meld_fx {
  float hold;     /* S&H's held value */
  int32_t cell;   /* S&H's last grid cell */
  double ph;      /* Independent S&H's own phase */
  float t;        /* seconds since the note (Gate, the fades) */
  float slew;     /* the slews' value */
  float trig;     /* Trig Env's value */
  float last;     /* the last input (Trig Env's crossing) */
} le_meld_fx;

typedef struct le_meld_lfo1 {
  double ph;
  float gen, fx;  /* the generator's output, and after the transformers */
  /* Wander */
  float walk, from, to;
  /* Euclid: the step counter; Pulsate: the pulse's height and cycles left */
  int32_t step;
  float pulse, pulse_left;
  int32_t quarter;
  le_meld_fx t[2];
  int32_t draw; /* Wander's targets drawn since the phase restarted */
} le_meld_lfo1;

typedef struct le_meld_engine {
  le_meld_osc osc;
  le_meld_filter filter;
  le_meld_env amp, mod;
  le_meld_lfo1 lfo1;
  double lfo2_ph;
  float lfo2, lfo2_sh;
  int32_t lfo2_draw; /* Random S&H's steps since the phase restarted */
  /* the note in semitones and its glide */
  float pitch, glide_to, glide_step;
  int32_t glide_left;
  int32_t live; /* started: engine B waits out its delay */
  /* the envelope rates the matrix last set, per sample (Amp) or tick (Mod) */
  float amp_dx[3], mod_dx[3];
  float amp_sustain, mod_sustain;
  float mod_prev; /* the Mod envelope's value at the last tick (0 at the note) */
  /* the tone filter: a low-pass and a high-pass one-pole */
  float tone_lp, tone_hp, tone_glp, tone_ghp;
  /* the output gains and the targets they follow */
  float gl, gr, gl_to, gr_to;
} le_meld_engine;

typedef struct le_meld_copy {
  le_meld_engine e[2];
  float random; /* the Random source, drawn at the note */
  float spread; /* the Spread source: the copy's position x Spread */
  float position;
  float lim[2]; /* the limiter's gain, dB, per channel */
  uint32_t rng;
} le_meld_copy;

typedef struct le_meld_voice {
  int32_t state; /* LE_MELD_VOICE_* (meld_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  float velocity; /* 0..1 */
  int32_t copies;
  int32_t since;   /* samples since the note started (Engine B's delay) */
  int32_t b_delay; /* samples */
  int32_t tick_left;
  int32_t quiet;   /* samples at or below the silence threshold */
  int32_t wait;    /* samples until a note that stole a voice starts */
  int32_t position_no; /* the lowest number no other held note had */
  float fade;      /* stolen or cut: 1 -> 0 */
  int32_t legato;  /* restarting in place for a legato key */
  int64_t born;    /* d->now at the slot's first note, -1 before */
  le_meld_copy c[LE_MELD_COPIES];
} le_meld_voice;

/* One non-zero matrix amount. */
typedef struct le_meld_route {
  int16_t target, source;
  float amount;
} le_meld_route;

typedef struct le_meld {
  int32_t sample_rate;
  uint64_t serial;
  uint64_t now; /* samples rendered since the device was built */
  float bpm;
  float values[LE_MELD_PARAMS];
  /* instrument-wide expression: bend -1..1, modulation and pressure 0..1 */
  float bend, mod, pressure;
  uint32_t sustain[LE_MELD_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  /* held keys, newest last: mono legato's and glide's source */
  int32_t held_n;
  int32_t held_note[LE_MELD_HELD_MAX];
  uint32_t held_origin[LE_MELD_HELD_MAX];
  int32_t voice_limit;
  uint32_t stolen;
  uint32_t rng;
  le_meld_route routes[2][LE_MELD_ROUTES];
  int32_t route_n[2];
  le_meld_voice voices[LE_MELD_VOICE_SLOTS];
  /* each oscillator's three Noise Loop buffers, last so le_meld_init can
   * leave them out of its clear: they are filled on first use */
  float loops[LE_MELD_VOICE_SLOTS][LE_MELD_COPIES][2][3][LE_MELD_LOOP_MAX];
} le_meld;

/* The default value of each parameter (an initialised device), and its
 * range: le_meld_clamp clamps to it. */
float le_meld_default(int32_t param);
float le_meld_clamp(int32_t param, float value);

/* Prepares `d` for `sample_rate` with every parameter at its default. */
int32_t le_meld_init(le_meld* d, int32_t sample_rate);

/* Sets every parameter (LE_MELD_PARAMS values, clamped), applied from the
 * next tick. */
void le_meld_set_values(le_meld* d, const float* values);

/* Starts `note` at `velocity` (1..127) for `origin`. A held note of the same
 * origin is replaced first, unless `chord`. Returns 0, or -1 on bad
 * arguments. */
int32_t le_meld_note_on(le_meld* d, uint32_t origin, int32_t note, int32_t velocity, int chord);

/* Releases every held voice of `origin` (sustained if sustain holds). */
void le_meld_note_off(le_meld* d, uint32_t origin);

/* Adds (on) or removes (off) sustain contributor `origin`. Returns 0, or -1
 * when the table is full (counted). */
int32_t le_meld_sustain(le_meld* d, uint32_t origin, int on);

/* LE_SYNTH_BEND (-1..1), LE_SYNTH_MOD or LE_SYNTH_PRESSURE (0..1). */
void le_meld_expression(le_meld* d, int32_t kind, float value);

/* le_synth_release_matching's rule on this device. */
void le_meld_release_matching(le_meld* d, uint32_t mask, uint32_t value);

/* Whether a held voice of `origin` exists. */
int32_t le_meld_held(const le_meld* d, uint32_t origin);

/* Fades every voice out and lets go of sustain and expression. */
void le_meld_cut(le_meld* d);

/* At most `limit` sounding copies; the excess fades, oldest note first. */
void le_meld_set_voice_limit(le_meld* d, int32_t limit);

/* Fades the oldest sounding note. Returns the copies it faded, 0 when none
 * sounds. */
int32_t le_meld_fade_oldest(le_meld* d);

/* The tempo the Tempo rates follow (beats per minute). */
void le_meld_set_tempo(le_meld* d, float bpm);

/* Renders `frames` into `left` and `right` (overwritten). */
void le_meld_render(le_meld* d, float* left, float* right, int32_t frames);

/* Sounding copies (of held, released or sustained voices, not fading), and
 * copies still fading. */
int32_t le_meld_active(const le_meld* d);
int32_t le_meld_fading(const le_meld* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_MELD_VOICE_H */
