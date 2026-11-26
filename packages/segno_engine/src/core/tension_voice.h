/*
 * tension_voice.h — the Tension device: per note a physically modelled
 * string (a two-rail waveguide) struck, plucked or bowed, with a damper, a
 * finger on a fret, a pickup and a pitch shifter for pitches above the
 * struck one; then Analog's filter with its envelope and LFO, and one body
 * resonating for every voice (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Tension: behavior"), learned from Live 12.2.7's
 * Tension bundle and written there in Segno's words; this code is written
 * from that description. Values it leaves open are fitted against Live
 * renders and marked "fit" in tension_voice.c.
 *
 * One le_tension per instrument slot that plays the device. Pure and
 * real-time safe like the other devices. Pitch, the filter and the LFO
 * move once per 32 samples (LE_TENSION_TICK); the string, its contacts,
 * the filter and the body run every sample. A note takes 1, 2 or 4 unison
 * voices, each its own string.
 *
 * Notes follow le_synth's rules, as the other devices do. Single-threaded.
 */
#ifndef SEGNO_TENSION_VOICE_H
#define SEGNO_TENSION_VOICE_H

#include <stdint.h>

#include "aas_parts.h"        /* le_aas_env, le_aas_filter */
#include "segno_engine_api.h" /* le_tension_param, LE_TENSION_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_TENSION_VOICE_SLOTS 32
#define LE_TENSION_RAIL 4096 /* samples per rail: a power of two (16 Hz at 96 kHz) */
#define LE_TENSION_SHIFT 4096 /* the pitch shifter's history */
#define LE_TENSION_TICK 32
#define LE_TENSION_SUSTAIN_MAX 16
#define LE_TENSION_HELD_MAX 16
#define LE_TENSION_BODY_LINE 8192 /* samples per body line */
#define LE_TENSION_BODY_AP 1024   /* samples per body all-pass */

/* A body of mass m on a felt contact (hammer, plectrum, damper). Its
 * motion is in double, as the engine's: a heavy damper's felt holds
 * centimetres where the contact holds microns. */
typedef struct le_tension_contact {
  int32_t on;    /* 0 parked */
  double y, v;   /* position and velocity, toward the string positive */
  double z;      /* the felt's give */
  double f;      /* the last force */
  float m, k, r; /* mass, stiffness, felt damping */
  float grav;    /* gravity along y */
  float reach;   /* the plectrum's protrusion (0 otherwise) */
  double y0;     /* the string's displacement at the strike, where the exciter's frame starts */
} le_tension_contact;

typedef struct le_tension_voice {
  int32_t state; /* LE_TENSION_VOICE_* (tension_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  float velocity; /* 0..1 */
  int32_t copy;   /* 0..3: its place in the note's unison */
  int32_t copies;
  float detune;   /* octaves: its unison offset */
  int32_t delay;  /* samples before it starts */
  int32_t since;  /* samples since the note, saturating */
  int32_t off_wait; /* samples until a released copy lets go, its delay after the key */
  int32_t fade_left, fade_len;
  int32_t quiet;  /* released 1 ms blocks in a row that were quiet */
  int32_t flying; /* released samples with the damper off the string */
  int32_t rel_n;  /* released samples into the current 1 ms block */
  float blk_peak; /* the string's peak in that block */
  int32_t tick_left;
  float pitch, pitch_to; /* the played pitch, octaves from C4, glided */
  float kerr;            /* octaves: Keyboard Error's draw for this strike */
  float p0;              /* the pitch at the strike */
  double vib_ph;
  float vib_t;
  /* the string */
  float a[LE_TENSION_RAIL], b[LE_TENSION_RAIL];
  int32_t w;       /* the rails' write index */
  int32_t len;     /* L: rail A's length, fixed at the strike */
  float e, e_to, e_step; /* rail B's extra delay, ramped across a tick */
  float c_tune;    /* the loop's phase-delay correction */
  float g, g_to, g_step; /* the loss per reflection, ramped */
  float lp_b, lp_a, lp_x, lp_y; /* the damping low-pass */
  float ap_a, ap_x, ap_y;       /* the dispersion all-pass */
  float hp_y, hp_x;             /* the output's 10 Hz high-pass */
  int32_t exc_tap, damp_tap, pick_tap;
  int32_t exc_type; /* engine type: 1 plectrum, 2 hammer, 3 bouncing, 4 bow, 0 off */
  le_tension_contact exc, damper;
  float bow_f, bow_vc, bow_vb; /* the bow */
  float bow_vb_late, bow_vscale; /* the bow's speed after its first block; the speed scaling it last took */
  int32_t bow_hold;              /* samples left on the last strike's speed scaling */
  double ys_exc, ys_damp; /* the string's displacement at the contacts */
  /* the finger on the fret */
  int32_t term, term_was; /* the finger is on; it was at the last strike */
  float tf_m, tf_k, ta_k;
  double te_y, tf_y, tf_v, t_ff, t_fa; /* in double: see finger_fret */
  /* pitches above the strike: the shifter and its crossfade */
  float sh[LE_TENSION_SHIFT];
  int32_t sh_w;
  float sh_d, sh_ratio, sh_mix, sh_mix_step;
  /* the filter, its envelope and LFO */
  le_aas_filter f;
  le_aas_env fenv;
  float fc, q;
  double lfo_ph;
  float lfo_sh, lfo_sh_prev, lfo_amp, lfo_wait;
  uint32_t rng;
} le_tension_voice;

/* The body: four recirculating lines with an all-pass inside each. */
typedef struct le_tension_body {
  float line[4][LE_TENSION_BODY_LINE];
  int32_t len[4], tap[4], w;
  float apb[4][LE_TENSION_BODY_AP]; /* the embedded all-passes */
  int32_t apw;
  float hp_y[4], hp_x[4];  /* the low cut per line */
  float lp_y[4];           /* the absorption per line */
  float fb[4];             /* each line's last output */
  int32_t type, size;      /* what the lengths were built for */
  float level, mix_dry, mix_wet; /* ramped */
  float level_to, dry_to, wet_to;
  float level_step, dry_step, wet_step;
  int32_t tail_left; /* samples of tail left after the last string */
} le_tension_body;

typedef struct le_tension {
  int32_t sample_rate;
  uint64_t serial;
  float bpm;
  float values[LE_TENSION_PARAMS];
  float bend, mod, pressure;
  uint32_t sustain[LE_TENSION_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  int32_t held_n;
  int32_t held_note[LE_TENSION_HELD_MAX];
  uint32_t held_origin[LE_TENSION_HELD_MAX];
  float last_pitch;
  int32_t played;
  int32_t voice_limit;
  uint32_t stolen;
  float mix[LE_TENSION_TICK * 8]; /* scratch: the voices' sum */
  le_tension_body body;
  le_tension_voice voices[LE_TENSION_VOICE_SLOTS];
} le_tension;

float le_tension_default(int32_t param);
float le_tension_clamp(int32_t param, float value);
int32_t le_tension_init(le_tension* d, int32_t sample_rate);
void le_tension_set_values(le_tension* d, const float* values);
int32_t le_tension_note_on(le_tension* d, uint32_t origin, int32_t note, int32_t velocity, int chord);
void le_tension_note_off(le_tension* d, uint32_t origin);
int32_t le_tension_sustain(le_tension* d, uint32_t origin, int on);
void le_tension_expression(le_tension* d, int32_t kind, float value);
void le_tension_release_matching(le_tension* d, uint32_t mask, uint32_t value);
int32_t le_tension_held(const le_tension* d, uint32_t origin);
void le_tension_cut(le_tension* d);
void le_tension_set_voice_limit(le_tension* d, int32_t limit);
int32_t le_tension_fade_oldest(le_tension* d);
void le_tension_set_tempo(le_tension* d, float bpm);
void le_tension_render(le_tension* d, float* left, float* right, int32_t frames);
int32_t le_tension_active(const le_tension* d);
int32_t le_tension_fading(const le_tension* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_TENSION_VOICE_H */
