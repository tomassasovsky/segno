/*
 * collision_voice.h — the Collision device: per voice a mallet and a noise
 * source strike two resonators (modal banks for beam, marimba, string,
 * membrane and plate; waveguides for pipe and tube), in series or in
 * parallel, with two LFOs and a modulation matrix (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Collision: behavior"), learned from Live 12.2.7's
 * Collision bundle and written there in Segno's words; this code is written
 * from that description. Values it leaves open are fitted against Live
 * renders and marked "fit" in collision_voice.c.
 *
 * One le_collision per instrument slot that plays the device. Pure and
 * real-time safe like the other devices. The matrix, the LFOs, the noise
 * filter and the resonators' coefficients move once per 32 samples
 * (LE_COLLISION_TICK); the exciters and the resonators run every sample.
 *
 * Notes follow le_synth's rules, as the other devices do. Single-threaded.
 */
#ifndef SEGNO_COLLISION_VOICE_H
#define SEGNO_COLLISION_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_collision_param, LE_COLLISION_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_COLLISION_VOICE_SLOTS 24
#define LE_COLLISION_MODES 70
#define LE_COLLISION_PIPE 4096 /* samples per waveguide line: a power of two (note 0 at 48 kHz) */
#define LE_COLLISION_TICK 32
#define LE_COLLISION_SUSTAIN_MAX 16
#define LE_COLLISION_LOOKAHEAD 17 /* the output limiter's window; the output lags 16 samples */

/* The matrix's destinations, in Live's chooser order (1..17), then the
 * knob-only ones. */
enum {
  LE_COLLISION_D_NONE = 0,
  LE_COLLISION_D_STIFFNESS,
  LE_COLLISION_D_NOISE_FREQ,
  LE_COLLISION_D_NOISE_VOLUME,
  LE_COLLISION_D_R1_PITCH,
  LE_COLLISION_D_R1_HIT,
  LE_COLLISION_D_R1_PAN,
  LE_COLLISION_D_R1_OPENING,
  LE_COLLISION_D_R2_INPUT,
  LE_COLLISION_D_R2_PITCH,
  LE_COLLISION_D_R2_HIT,
  LE_COLLISION_D_R2_PAN,
  LE_COLLISION_D_R2_OPENING,
  LE_COLLISION_D_VOLUME,
  LE_COLLISION_D_LFO1_RATE,
  LE_COLLISION_D_LFO1_DEPTH,
  LE_COLLISION_D_LFO2_RATE,
  LE_COLLISION_D_LFO2_DEPTH,
  LE_COLLISION_D_CHOOSER, /* the chooser's destinations end here */
  LE_COLLISION_D_MALLET_VOLUME = LE_COLLISION_D_CHOOSER,
  LE_COLLISION_D_MALLET_NOISE,
  LE_COLLISION_D_R1_DECAY,
  LE_COLLISION_D_R1_MATERIAL,
  LE_COLLISION_D_R1_RADIUS,
  LE_COLLISION_D_R1_INHARMONICS,
  LE_COLLISION_D_R2_DECAY,
  LE_COLLISION_D_R2_MATERIAL,
  LE_COLLISION_D_R2_RADIUS,
  LE_COLLISION_D_R2_INHARMONICS,
  LE_COLLISION_D_COUNT
};

/* A biquad's coefficients and state. */
typedef struct le_collision_bq {
  float b0, b1, b2, a1, a2;
  float x1, x2, y1, y2;
} le_collision_bq;

typedef struct le_collision_res {
  int32_t kind;   /* 0 off, 1 modal, 2 pipe, 3 tube */
  int32_t n;      /* modes in use */
  float pitch;    /* octaves, the coefficients were set at */
  float a1[LE_COLLISION_MODES], a2[LE_COLLISION_MODES];
  float e[LE_COLLISION_MODES];             /* excitation weights */
  float gl[LE_COLLISION_MODES], gr[LE_COLLISION_MODES]; /* gain x pickup weights */
  float v1[LE_COLLISION_MODES], v2[LE_COLLISION_MODES]; /* states */
  float om[LE_COLLISION_MODES];            /* the frequencies the states ring at, rad/s */
  le_collision_bq bleed;
  float bleed_g;
  float hit_rand; /* the strike's random offset to the hit position */
  /* the waveguide */
  float fw[LE_COLLISION_PIPE], bw[LE_COLLISION_PIPE];
  int32_t w;
  float delay, loss;
  float rf_b0, rf_b1, rf_a1, rf_x1, rf_y1; /* the far end's reflection */
  float hp_x, hp_y;                         /* the input's 30 Hz high-pass */
  float pe;       /* the pitch envelope, falling to 0 */
  float pe_amp, pe_x, pe_mul; /* its depth, its exponential's value and step a tick */
  int32_t pe_left;             /* samples to its end */
  float gain_l, gain_r; /* volume and pan */
  float amp_l, amp_r, amp_sl, amp_sr, amp_tl, amp_tr; /* the gains heard, their steps and targets */
  int32_t amp_n;                               /* samples left of the ramp; -1 never played */
  /* what the coefficients were set from */
  int32_t released;
  int32_t since; /* samples since the coefficients were set */
  uint32_t serial;
  float key[7];
} le_collision_res;

typedef struct le_collision_lfo {
  double ph;
  float rnd, rnd_prev;
  float out;
} le_collision_lfo;

typedef struct le_collision_voice {
  int32_t state; /* LE_COLLISION_VOICE_* (collision_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  float vel;      /* bipolar: (velocity - 64) / 63 */
  int32_t tick_left;
  int32_t fade_left, fade_len;
  int32_t quiet;
  int32_t age;       /* samples since the strike, up to its settling time */
  int32_t pulse_len; /* the mallet pulse's length in samples */
  int32_t blk_n;     /* samples into the level check's block */
  float blk_pk;      /* the block's peak so far */
  float dest[LE_COLLISION_D_COUNT]; /* this tick's matrix sums */
  /* the mallet: its pulse filter and its noise's high-pass */
  le_collision_bq pulse, mnoise;
  float pulse_in; /* the impulse waiting for the pulse filter */
  /* the noise source */
  le_collision_bq nf1, nf2;
  int32_t nf_left;    /* samples to the filters' next update */
  uint32_t nf_serial; /* the values they were set from */
  int32_t env_seg;
  float env, env_step;
  uint32_t rng;
  le_collision_res r[2];
  le_collision_lfo lfo[2];
} le_collision_voice;

typedef struct le_collision {
  int32_t sample_rate;
  uint64_t serial;
  float bpm;
  float values[LE_COLLISION_PARAMS];
  float bend, mod, pressure;
  uint32_t sustain[LE_COLLISION_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  int32_t voice_limit;
  uint32_t stolen;
  float gain; /* the master volume, smoothed */
  float limit; /* the output limiter's gain, released */
  float lim_l[LE_COLLISION_LOOKAHEAD], lim_r[LE_COLLISION_LOOKAHEAD]; /* the output, delayed */
  float lim_need[LE_COLLISION_LOOKAHEAD], lim_g[LE_COLLISION_LOOKAHEAD];
  int32_t lim_pos;
  float lim_held;
  int32_t lim_hold;
  uint32_t serial_values; /* bumped by every set_values */
  le_collision_voice voices[LE_COLLISION_VOICE_SLOTS];
} le_collision;

float le_collision_default(int32_t param);
float le_collision_clamp(int32_t param, float value);
int32_t le_collision_init(le_collision* d, int32_t sample_rate);
void le_collision_set_values(le_collision* d, const float* values);
int32_t le_collision_note_on(le_collision* d, uint32_t origin, int32_t note, int32_t velocity, int chord);
void le_collision_note_off(le_collision* d, uint32_t origin);
int32_t le_collision_sustain(le_collision* d, uint32_t origin, int on);
void le_collision_expression(le_collision* d, int32_t kind, float value);
void le_collision_release_matching(le_collision* d, uint32_t mask, uint32_t value);
int32_t le_collision_held(const le_collision* d, uint32_t origin);
void le_collision_cut(le_collision* d);
void le_collision_set_voice_limit(le_collision* d, int32_t limit);
int32_t le_collision_fade_oldest(le_collision* d);
void le_collision_set_tempo(le_collision* d, float bpm);
void le_collision_render(le_collision* d, float* left, float* right, int32_t frames);
int32_t le_collision_active(const le_collision* d);
int32_t le_collision_fading(const le_collision* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_COLLISION_VOICE_H */
