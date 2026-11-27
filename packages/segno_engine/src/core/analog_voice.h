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

#include "aas_parts.h"         /* le_aas_env, le_aas_filter */
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
#define LE_ANALOG_DEVICE_VOICES 32 /* the most voices a patch plays */
#define LE_ANALOG_BL_HALF 13   /* the band-limited impulse's half length, samples */
#define LE_ANALOG_BL_PHASES 512 /* its table's fractional positions */
#define LE_ANALOG_BL_RING 32   /* the impulses an oscillator has still to play (a power of 2) */
#define LE_ANALOG_BL_PENDING 8 /* a sync saw's own resets still ahead of it */


/* What a chain's control tick holds until the next one (analog_voice.c). */
typedef struct le_analog_tick {
  float fc, q, k;       /* the filter */
  float pw;             /* the pulse width, a fraction of the period */
  float sub, ratio;     /* the sub level, the sync ratio (0: no sync) */
  float to_f1, to_f2;   /* the oscillator's levels into each filter */
  float n_f1, n_f2;     /* the noise's */
  float link;           /* filter 1 into filter 2 */
  float f_base;         /* the oscillator's own pitch, Hz (its octave, semitone and detune) */
  float lfo_mul;        /* the LFO's pitch, a factor */
  float k1;             /* the keyboard pitch's scale (Mod 1) */
  float key, key_pre;   /* the oscillator's pitch input, octaves: the note's, and before a
                         * delayed copy's note the device voice's last */
  float env_amt;        /* the pitch envelope's depth, octaves */
  float f_hi;           /* the frequency's top */
} le_analog_tick;

/* A chain's oscillator. It stays with its device voice from one note to the
 * next and stands still while the voice is idle (analog_voice.c). */
typedef struct le_analog_osc {
  double ph;            /* sine: the phase; saw: cycles to its next reset; rectangle: samples
                         * into its segment */
  double ph2;           /* sine: the sub's phase; sync: samples into the master's cycle */
  float y;              /* saw and rectangle: the integrator, their output */
  int32_t high;         /* rectangle: in its high segment */
  int32_t sub_sign;     /* the sub's sign, turned over at each reset */
  float per, per_m;     /* the period (a sync slave's) and a sync master's, samples (0: unset) */
  float per_step, per_m_step, per_to, per_m_to;
  int32_t ramp;         /* samples of the period's ramp left */
  int32_t otick;        /* samples to the next pitch tick */
  float penv, penv_dec; /* the pitch envelope, 1 -> 0, and its step a tick */
  int32_t penv_n;       /* its ticks left */
  float ring[LE_ANALOG_BL_RING]; /* impulses still to play, from the current sample on */
  int32_t ring_at;
  float pend[LE_ANALOG_BL_PENDING]; /* a sync saw's own resets scheduled ahead: samples to each */
  int32_t npend;
} le_analog_osc;

/* One chain of one copy. */
typedef struct le_analog_chain {
  le_analog_osc o;     /* the oscillator */
  le_aas_filter f;     /* the filter */
  float fc;            /* the modulated cutoff (filter 2 follows it) */
  le_aas_env fenv, aenv;
  double lfo_ph;
  float lfo, lfo_sh, lfo_sh_prev, lfo_amp, lfo_wait;
  float gl, gr, gl_step, gr_step; /* the amp's gains but the envelope, ramped across a tick */
  int32_t g_fresh;                /* the gains take their first values at once */
  float noise_lp;
  le_analog_tick t;    /* this tick's values */
} le_analog_chain;

typedef struct le_analog_copy {
  le_analog_chain ch[2];
  float detune;   /* octaves: the copy's unison offset */
  int32_t delay;  /* samples before the copy starts */
  int32_t rel_at; /* the voice age its delayed release falls on, -1 none */
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
  float pre;             /* the keyboard pitch its device voice played last (a delayed copy's
                          * oscillators run at it until the copy's note) */
  float glide_c;         /* per-tick glide coefficient */
  int32_t glided;        /* the key that started or took back the voice glided */
  int32_t keyed_at;      /* the device's age then */
  double vib_ph;
  float vib_t;           /* seconds since the note (vibrato delay and fade) */
  float vib_dev;         /* this vibrato cycle's rate deviation, a fraction */
  int32_t tick_left;
  int32_t since;      /* samples since the note, saturating */
  int32_t lv;         /* the device voice it plays (LE_ANALOG_DEVICE_VOICES), -1 none */
  int32_t osc_lv;     /* the device voice whose oscillators it runs, -1 none */
  int32_t quiet_at;   /* the age its amp envelopes ended (its oscillators run on from there) */
  int32_t amp_end;    /* the age an amp envelope last ended */
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
  int32_t first_age; /* the age of the device's first note */
  int32_t voice_limit;
  uint32_t stolen;
  uint32_t rng;
  int32_t age; /* samples rendered since init, saturating (the amps' start ramp) */
  /* each device voice's free LFOs, carried from one note to the next */
  double lv_ph[LE_ANALOG_DEVICE_VOICES][LE_ANALOG_COPIES][2];
  float lv_sh[LE_ANALOG_DEVICE_VOICES][LE_ANALOG_COPIES][2][2]; /* the random waves' held values */
  double lv_vib[LE_ANALOG_DEVICE_VOICES];                       /* a mono voice's vibrato phase */
  int32_t lv_quiet[LE_ANALOG_DEVICE_VOICES]; /* the age it went quiet or was taken over */
  uint8_t lv_used[LE_ANALOG_DEVICE_VOICES];
  le_aas_env lv_fenv[LE_ANALOG_DEVICE_VOICES][LE_ANALOG_COPIES][2]; /* the filter envelopes, carried on */
  le_analog_osc lv_osc[LE_ANALOG_DEVICE_VOICES][LE_ANALOG_COPIES][2]; /* the oscillators */
  int32_t lv_note[LE_ANALOG_DEVICE_VOICES]; /* the note it played last, -1 none */
  int32_t osc_quiet[LE_ANALOG_DEVICE_VOICES]; /* the age its oscillators were last handed back */
  int32_t osc_steal; /* the oscillators of the voice the note being started takes over, -1 none */
  int32_t lv_last;  /* the device voice a note took last */
  int32_t lv_steal; /* the voice the note being started takes over, -1 none */
  /* the band-limited impulse (analog_voice.c) */
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
