/*
 * electric_voice.h — the Electric device: per voice a mallet that strikes
 * a fork of four resonators, a damper that thumps it, and a pickup that
 * turns the fork's motion into the output (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Electric: behavior"), learned from Live 12.2.7's
 * Electric bundle and written there in Segno's words; this code is written
 * from that description. Values it leaves open are fitted against Live
 * renders and marked "fit" in electric_voice.c.
 *
 * One le_electric per instrument slot that plays the device. Pure and
 * real-time safe like the other devices: no allocation, no locks, no
 * syscalls on the audio path. The strikes, the resonators' coefficients and
 * the pitch move once per 1 ms block (LE_ELECTRIC_BLOCK at 48 kHz, as the
 * engine Live's renders come from); the mallet, damper, resonators and
 * pickup run every sample. A note strikes one block after it arrives.
 *
 * Notes follow le_synth's rules, as the other devices do. Single-threaded.
 */
#ifndef SEGNO_ELECTRIC_VOICE_H
#define SEGNO_ELECTRIC_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_electric_param, LE_ELECTRIC_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_ELECTRIC_VOICE_SLOTS 40
#define LE_ELECTRIC_SUSTAIN_MAX 16

/* One second-order resonator of the fork. */
typedef struct le_electric_res {
  float b, c1, c2;     /* y = b (x - x2) + c1 y1 - c2 y2 */
  float y1, y2;
} le_electric_res;

typedef struct le_electric_voice {
  int32_t state; /* LE_ELECTRIC_VOICE_* (electric_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial;
  float velocity;  /* (vel - 1) / 126 */
  int32_t wait;    /* blocks until the strike: 2 at note-on */
  int32_t gate;    /* 1 while held or sustained */
  int32_t damp;    /* a damper burst due at the next block (1 on, 2 off) */
  int32_t quiet;   /* released blocks below the silence floor */
  float fade;      /* stolen, cut or retriggered: 1 -> 0 */
  float fade_step;
  /* the mallet's four stages and their coefficients */
  float m[4];
  float mp1, ma, mp2, mb;
  /* the damper's envelope and noise */
  float e[2], n[2];
  float dp, da, np, nb;
  uint32_t rng;
  /* the fork: tone bar, tine, tine partial, mallet noise */
  le_electric_res r[4];
  float x1, x2;    /* the fork's input history */
  /* the pickup, latched at the strike */
  float pk_gain, pk_in, pk_a, pk_b;
  int32_t pk_model;
  float pv, pu1, pw1; /* its state */
} le_electric_voice;

typedef struct le_electric {
  int32_t sample_rate;
  int32_t block;      /* samples per 1 ms block */
  int32_t block_left; /* samples left in the current block */
  uint64_t serial;
  float values[LE_ELECTRIC_PARAMS];
  float bend, mod, pressure;
  uint32_t sustain[LE_ELECTRIC_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  int32_t voice_limit;
  uint32_t stolen;
  float gain, gain_step; /* the output volume, ramped across a block */
  le_electric_voice voices[LE_ELECTRIC_VOICE_SLOTS];
} le_electric;

float le_electric_default(int32_t param);
float le_electric_clamp(int32_t param, float value);
int32_t le_electric_init(le_electric* d, int32_t sample_rate);
void le_electric_set_values(le_electric* d, const float* values);
int32_t le_electric_note_on(le_electric* d, uint32_t origin, int32_t note, int32_t velocity, int chord);
void le_electric_note_off(le_electric* d, uint32_t origin);
int32_t le_electric_sustain(le_electric* d, uint32_t origin, int on);
void le_electric_expression(le_electric* d, int32_t kind, float value);
void le_electric_release_matching(le_electric* d, uint32_t mask, uint32_t value);
int32_t le_electric_held(const le_electric* d, uint32_t origin);
void le_electric_cut(le_electric* d);
void le_electric_set_voice_limit(le_electric* d, int32_t limit);
int32_t le_electric_fade_oldest(le_electric* d);
void le_electric_set_tempo(le_electric* d, float bpm);
void le_electric_render(le_electric* d, float* left, float* right, int32_t frames);
int32_t le_electric_active(const le_electric* d);
int32_t le_electric_fading(const le_electric* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ELECTRIC_VOICE_H */
