/*
 * operator_voice.h — the Operator device: four table-lookup operators in
 * eleven phase-modulation algorithms, a filter, a shaper, an LFO and a pitch
 * envelope, with stereo output (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Operator: behavior"), learned from Live 12.2.7 and
 * written there in Segno's words; this code is written from that
 * description. Values the description leaves open are fitted against Live
 * renders and marked "fit" in operator_voice.c.
 *
 * One le_operator per instrument slot that plays the device. Pure and
 * real-time safe like drift_voice.c: no engine types, no allocation, no
 * locks, no syscalls on the audio path. le_operator_init is the slow call
 * (the first one also builds the shared wave tables). A user wave's tables
 * are rebuilt on the audio thread when its harmonics change, one operator
 * per render call. Parameters apply per 32-frame chunk (LE_OPERATOR_CHUNK);
 * the operators, envelopes, filter and shaper run every sample.
 *
 * Notes follow le_synth's rules: a note belongs to an origin, a repeated
 * strike from the same origin replaces its held note, a note-off releases
 * every voice of its origin, sustain contributors hold released notes, and
 * Cut fades everything. A note takes one voice, or two with Spread.
 *
 * Single-threaded: the audio callback calls every function on a given
 * le_operator once the engine owns it.
 */
#ifndef SEGNO_OPERATOR_VOICE_H
#define SEGNO_OPERATOR_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_operator_param, LE_OPERATOR_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_OPERATOR_OPS 4
/* 48 voices, each with its Spread partner, and room for stolen voices to
 * fade */
#define LE_OPERATOR_VOICE_SLOTS 104
#define LE_OPERATOR_CHUNK 32
#define LE_OPERATOR_SUSTAIN_MAX 16
#define LE_OPERATOR_HELD_MAX 16
/* A wave's band-limited copies: every limit from 1024 harmonics down to 1,
 * after the full table */
#define LE_OPERATOR_LEVELS 11
/* the floats one wave's tables take, guard samples included: four of 4096
 * (the full table and the copies keeping 1024, 512 and 256 harmonics), then
 * 2048 .. 64 (16 samples per period of the top harmonic, at least 64) */
#define LE_OPERATOR_WAVE_FLOATS 20560

/* One wave: its full table and band-limited copies, each a power-of-two
 * table with a guard sample, and the gain the table was normalised by. */
typedef struct le_operator_wave {
  const float* level[LE_OPERATOR_LEVELS + 1]; /* [0]: the full table */
  int32_t size[LE_OPERATOR_LEVELS + 1];       /* samples */
  int32_t limit[LE_OPERATOR_LEVELS + 1];      /* highest harmonic kept */
  int32_t levels;                             /* tables in use */
  float gain;
  float freq_mult; /* 1, or 1/64 for the noises */
  int32_t white;   /* Noise White: one sample per output sample */
} le_operator_wave;

/* One envelope's run state. */
typedef struct le_operator_env {
  int32_t state; /* ENV_* (operator_voice.c) */
  double t, dt;  /* segment position 0..1 and its step per sample */
  double c;      /* slope 1: the one-pole coefficient */
  float y0, y1;  /* segment start and target */
  float s;       /* segment slope */
  float y;       /* output, before the level scale */
  double repeat; /* Beat/Sync: samples to the next retrigger */
} le_operator_env;

typedef struct le_operator_voice {
  int32_t state; /* LE_OPERATOR_VOICE_* (operator_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  int32_t side;   /* 0: both channels, 1: left only, 2: right only (Spread) */
  float velocity; /* 0..1 */
  float detune;   /* semitones: Spread's -0.1 s or +0.1 s */
  float pan;      /* the note's key and random pan, latched */
  /* glide: the pitch in semitones and its per-chunk step */
  float pitch, pitch_step;
  int32_t glide_chunks;
  float fade; /* stolen or cut: 1 -> 0 */
  /* operators */
  double phase[LE_OPERATOR_OPS]; /* table indices, 0..4096 */
  float out[LE_OPERATOR_OPS];
  float y2[LE_OPERATOR_OPS];                         /* feedback history */
  float lp_x[LE_OPERATOR_OPS], lp_y[LE_OPERATOR_OPS]; /* Tone filter */
  float tone_b, tone_a; /* the Tone filter's coefficients */
  float time_mod;       /* the Time route's factor on envelope times */
  float inc[LE_OPERATOR_OPS];                        /* per engine sample */
  float amp[LE_OPERATOR_OPS], amp_step[LE_OPERATOR_OPS];
  int32_t table[LE_OPERATOR_OPS]; /* band-limited copy in use */
  uint32_t white_pos[LE_OPERATOR_OPS];
  le_operator_env env[LE_OPERATOR_OPS];
  le_operator_env fenv, penv, lenv;
  /* LFO */
  double lfo_phase;
  float lfo_lp, lfo_lp_x, lfo_sh, lfo_hold;
  float lfo_bp[4];
  float lfo_out;    /* this sample's shape x envelope, before the amounts */
  float lfo_filter; /* the filter's smoothed LFO, semitones */
  /* filter: two sections (band, low) and their previous inputs, and the
   * ramped coefficients */
  float f_s[2][2];
  float f_x1[2];
  float f_an[16]; /* the analog circuits' states */
  float f_g, f_k, f_g_step, f_k_step;
  float f_w[3], f_w_step[3]; /* morph weights: low, band, high */
  /* shaper: 2x up and down half-band states */
  float sh_up[4][2], sh_dn[4][2];
  /* the output gains, ramped per sample */
  float gl, gr, gl_step, gr_step;
  /* Antialias: the operators' 2x decimator */
  float aa[4][2];
  uint32_t rng;
} le_operator_voice;

typedef struct le_operator {
  int32_t sample_rate;
  uint64_t serial;
  int32_t chunk_left;
  float bpm;
  float values[LE_OPERATOR_PARAMS];
  /* instrument-wide expression: bend -1..1, modulation and pressure 0..1 */
  float bend, mod, pressure;
  uint32_t sustain[LE_OPERATOR_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  /* held keys, newest last: mono legato's source */
  int32_t held_n;
  int32_t held_note[LE_OPERATOR_HELD_MAX];
  uint32_t held_origin[LE_OPERATOR_HELD_MAX];
  float last_pitch; /* the last played note, the glide start */
  int32_t played;   /* whether a note has played since init */
  double lfo_free;  /* the free-running LFO phase (Retrigger off) */
  int32_t voice_limit;
  uint32_t stolen;
  uint32_t rng;
  /* each operator's user wave, rebuilt when its harmonics change */
  le_operator_wave user[LE_OPERATOR_OPS];
  uint32_t user_dirty; /* bit per operator */
  float user_tables[LE_OPERATOR_OPS][LE_OPERATOR_WAVE_FLOATS];
  le_operator_voice voices[LE_OPERATOR_VOICE_SLOTS];
} le_operator;

/* The default value of each parameter (an initialised device), and its
 * range: le_operator_clamp clamps to it. */
float le_operator_default(int32_t param);
float le_operator_clamp(int32_t param, float value);

/* Prepares `d` for `sample_rate` with every parameter at its default. */
int32_t le_operator_init(le_operator* d, int32_t sample_rate);

/* Sets every parameter (LE_OPERATOR_PARAMS values, clamped), applied from
 * the next chunk. */
void le_operator_set_values(le_operator* d, const float* values);

/* Starts `note` at `velocity` (1..127) for `origin`. A held note of the same
 * origin is replaced first, unless `chord` (a chord's later notes share
 * their origin with the first). Returns 0, or -1 on bad arguments. */
int32_t le_operator_note_on(le_operator* d, uint32_t origin, int32_t note,
                            int32_t velocity, int chord);

/* Releases every held voice of `origin` (sustained if sustain holds). */
void le_operator_note_off(le_operator* d, uint32_t origin);

/* Adds (on) or removes (off) sustain contributor `origin`. Returns 0, or -1
 * when the table is full (counted). */
int32_t le_operator_sustain(le_operator* d, uint32_t origin, int on);

/* LE_SYNTH_BEND (-1..1), LE_SYNTH_MOD or LE_SYNTH_PRESSURE (0..1). */
void le_operator_expression(le_operator* d, int32_t kind, float value);

/* le_synth_release_matching's rule on this device. */
void le_operator_release_matching(le_operator* d, uint32_t mask,
                                  uint32_t value);

/* Whether a held voice of `origin` exists. */
int32_t le_operator_held(const le_operator* d, uint32_t origin);

/* Fades every voice out and lets go of sustain and expression. */
void le_operator_cut(le_operator* d);

/* At most `limit` sounding voices; the excess fades, oldest first. */
void le_operator_set_voice_limit(le_operator* d, int32_t limit);

/* Fades the oldest sounding voice. Returns 1, or 0 when none sounds. */
int32_t le_operator_fade_oldest(le_operator* d);

/* The tempo the Sync rates and Beat/Sync loops follow (beats per minute). */
void le_operator_set_tempo(le_operator* d, float bpm);

/* Renders `frames` into `left` and `right` (overwritten). */
void le_operator_render(le_operator* d, float* left, float* right,
                        int32_t frames);

/* Sounding voices (held, released or sustained, not fading), and voices
 * still fading. */
int32_t le_operator_active(const le_operator* d);
int32_t le_operator_fading(const le_operator* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_OPERATOR_VOICE_H */
