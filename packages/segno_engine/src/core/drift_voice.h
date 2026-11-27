/*
 * drift_voice.h — the Drift device: a two-oscillator subtractive synth with
 * its own modulation, voice modes and stereo output (SEG-109 P3).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Drift: behavior"), learned from Live 12.2.7 and
 * written there in Segno's words; this code is written from that
 * description. Values the description leaves open are provisional and
 * marked "P4" here, in one place each (drift_voice.c), for the fit against
 * Live renders (plan part 4).
 *
 * One le_drift per instrument slot that plays the device. Pure and real-time
 * safe like synth_voice.c: no engine types, no allocation, no locks, no
 * syscalls; le_drift_init is the only slow call. Parameters apply per
 * 32-frame chunk (LE_DRIFT_CHUNK) counted from init, so a render is the same
 * at any block size; modulation, envelopes and filters run every sample.
 *
 * Notes follow le_synth's rules: a note belongs to an origin, a repeated
 * strike from the same origin replaces its held note, a note-off releases
 * every voice of its origin, sustain contributors hold released notes, and
 * Cut fades everything. A note takes one voice (Poly), two (Stereo) or four
 * (Mono, Unison).
 *
 * Single-threaded: the audio callback calls every function on a given
 * le_drift once the engine owns it.
 */
#ifndef SEGNO_DRIFT_VOICE_H
#define SEGNO_DRIFT_VOICE_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_drift_param, LE_DRIFT_PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_DRIFT_VOICES 32
#define LE_DRIFT_CHUNK 32
#define LE_DRIFT_SUSTAIN_MAX 16
#define LE_DRIFT_MONO_STACK 16

/* Modulation sources, in the stored order. */
enum {
  LE_DRIFT_SRC_ENV1 = 0,
  LE_DRIFT_SRC_ENV2 = 1, /* Envelope 2, or the cycling envelope */
  LE_DRIFT_SRC_LFO = 2,
  LE_DRIFT_SRC_KEY = 3,
  LE_DRIFT_SRC_VELOCITY = 4,
  LE_DRIFT_SRC_MODWHEEL = 5,
  LE_DRIFT_SRC_PRESSURE = 6,
  LE_DRIFT_SRC_SLIDE = 7,
  LE_DRIFT_SOURCES = 8
};

/* Matrix targets, in the stored order. */
enum {
  LE_DRIFT_TGT_NONE = 0,
  LE_DRIFT_TGT_OSC1_GAIN,
  LE_DRIFT_TGT_OSC1_SHAPE,
  LE_DRIFT_TGT_OSC2_GAIN,
  LE_DRIFT_TGT_OSC2_DETUNE,
  LE_DRIFT_TGT_NOISE_GAIN,
  LE_DRIFT_TGT_LP_FREQ,
  LE_DRIFT_TGT_LP_RES,
  LE_DRIFT_TGT_HP_FREQ,
  LE_DRIFT_TGT_LFO_RATE,
  LE_DRIFT_TGT_CYC_RATE,
  LE_DRIFT_TGT_MAIN_VOLUME,
  LE_DRIFT_TARGETS
};

typedef struct le_drift_voice {
  int32_t state; /* LE_DRIFT_VOICE_* (drift_voice.c) */
  int32_t note;
  uint32_t origin;
  uint64_t serial; /* the start order: stealing age */
  int32_t lane;    /* 0..3 within its note's group */
  float velocity;  /* 0..1 */
  float key;       /* (note - 69) / 120 */
  /* pitch: the glided note frequency and its target in Hz (a glide moves
   * evenly in hertz), and the voice's fixed ratio (voice mode detune,
   * per-key tuning) */
  float pitch;
  float pitch_target;
  float ratio;
  float ref_ratio; /* the lane's ratio the Ratio rate modes follow */
  float osc2_drift; /* Osc 2's extra drift ratio */
  /* the voice mode's gains */
  float gain_l, gain_r;
  /* oscillators and noise, and whether the voice ever played */
  float ph1, ph2;
  int32_t played;
  float pm_prev; /* the last phase-modulation offset (its change widens the
                  * band-limiting, as a faster phase would) */
  uint32_t rng;
  /* envelopes: level, stage, and the attack's per-sample step, set at the
   * note's start from the level it starts at */
  float env1, env2;
  int32_t stage1, stage2;
  float att1, att2;
  /* the cycling envelope and the LFO */
  float cyc_ph;
  float lfo_ph;
  float lfo_inc;                    /* the LFO's last increment (Ratio) */
  float lfo_mod;                    /* its last rate modulation factor */
  /* Sample & Hold and Wander: the lane's generator (two words), its held
   * value or Wander base, Wander's delta, and the last half-cycle phase */
  uint32_t lfo_gx, lfo_gy;
  float lfo_b, lfo_d, lfo_qprev;
  int32_t lfo_done;                 /* a one-shot LFO shape ended */
  /* filters: the low-pass (type I three states, type II twelve: two
   * sections of four capacitor states and two secant gains), the high-pass */
  float lp[12];
  int32_t lp_kind; /* the filter type lp holds the state of */
  float hp[2];
  /* fade (stolen, cut, device change) */
  float fade;
  /* Reset Oscillator Phase: a note struck on a sounding voice waits while
   * the voice's envelopes fall fast, then starts from silence */
  int32_t pending;
} le_drift_voice;

/* Everything a chunk's samples read, derived from the stored values,
 * the tempo and the expression at the chunk's start (drift_voice.c,
 * derive), so a change lands on the chunk grid whatever the block size. */
typedef struct le_drift_derived {
  float rate;
  int32_t osc1, osc2; /* DSP waveform kinds */
  float osc1_ratio, osc2_ratio;
  float gain1, gain2, gain_noise;
  int32_t thru1, thru2, thru_noise;
  float env1_dec, env1_rel, env2_dec, env2_rel; /* one-pole coefficients */
  float sustain1, sustain2;
  float volume, vol_vel;
  float hp_hz, freq, tracking, res;
  int32_t filter_type;
  float lfo_hz, cyc_hz; /* rates for modes 0, 2 and 3 */
  int32_t lfo_shape, lfo_mode, cyc_mode, cycling;
  float lfo_ratio, cyc_ratio, cyc_mid, cyc_hold;
  int32_t mtx_src[3], mtx_tgt[3];
  float mtx_amt[3];
  int32_t pm_src[2], fm_src[2], lfo_src, shape_src;
  float pm_amt[2], fm_amt[2], lfo_amt, lfo_mod_amt, shape_mod, shape;
  float bend_ratio; /* pitch bend and Transpose */
  float glide;      /* the glide's one-pole coefficient */
  float fade_step;
  float pending_fall; /* per sample, a pending voice's envelopes */
} le_drift_derived;

typedef struct le_drift {
  int32_t sample_rate;
  /* the voices run at the host's rate: Live's HiQuality changes nothing in
   * its renders (bit-identical with it on and off), so the stored value has
   * no effect here either */
  float rate;
  uint64_t serial;
  int32_t chunk_left;
  float bpm;
  /* the stored parameter values, and the set the voices read */
  float values[LE_DRIFT_PARAMS];
  le_drift_derived d;
  /* instrument-wide expression: bend -1..1, modulation and pressure 0..1 */
  float bend, mod, pressure;
  uint32_t sustain[LE_DRIFT_SUSTAIN_MAX];
  int32_t sustain_n;
  uint32_t sustain_refused;
  /* Mono: the held notes, newest last, for last-note priority */
  int32_t mono_n;
  int32_t mono_note[LE_DRIFT_MONO_STACK];
  uint32_t mono_origin[LE_DRIFT_MONO_STACK];
  float mono_velocity[LE_DRIFT_MONO_STACK];
  /* per note: the loudness compensation and the per-key tuning in cents;
   * per voice: its own tuning in cents and Osc 2's extra (Drift Depth),
   * filled at init */
  float note_gain[128];
  float key_cents[128];
  float voice_cents[LE_DRIFT_VOICES];
  float osc2_cents[LE_DRIFT_VOICES];
  int32_t tuning_set; /* which serial's per-voice tables are loaded */
  /* filter II's state at rest, where a voice's filter starts */
  float f2_rest[12];
  /* the voice mode the blocks were last reset for (-1: not yet) */
  int32_t block_mode;
  /* Poly allocation: where the round robin starts */
  int32_t next_voice;
  int32_t voice_limit; /* sounding voices allowed (the engine's overload) */
  uint32_t stolen;
  le_drift_voice voices[LE_DRIFT_VOICES];
  /* the noise: one generator per voice, run per block of four (tick), and
   * this sample's value per voice */
  uint32_t noise_rng[LE_DRIFT_VOICES];
  int32_t block_ran[LE_DRIFT_VOICES / 4]; /* each block ran last sample */
  float lane_noise[LE_DRIFT_VOICES];
} le_drift;

/* The default value of each parameter (an initialised device), and its
 * range: le_drift_clamp clamps to it. */
float le_drift_default(int32_t param);
float le_drift_clamp(int32_t param, float value);

/* Prepares `d` for `sample_rate` with every parameter at its default. */
int32_t le_drift_init(le_drift* d, int32_t sample_rate);

/* Sets every parameter (LE_DRIFT_PARAMS values, clamped), applied from the
 * next chunk. HiQuality is stored without effect. */
void le_drift_set_values(le_drift* d, const float* values);

/* Starts `note` at `velocity` (1..127) for `origin`. A held note of the same
 * origin is replaced first, unless `chord` (a chord's later notes share
 * their origin with the first). Returns 0, or -1 on bad arguments. */
int32_t le_drift_note_on(le_drift* d, uint32_t origin, int32_t note,
                         int32_t velocity, int chord);

/* Releases every held voice of `origin` (sustained if sustain holds). */
void le_drift_note_off(le_drift* d, uint32_t origin);

/* Adds (on) or removes (off) sustain contributor `origin`. Returns 0, or -1
 * when the table is full (counted). */
int32_t le_drift_sustain(le_drift* d, uint32_t origin, int on);

/* LE_SYNTH_BEND (-1..1), LE_SYNTH_MOD or LE_SYNTH_PRESSURE (0..1). */
void le_drift_expression(le_drift* d, int32_t kind, float value);

/* le_synth_release_matching's rule on this device: drops the sustain
 * contributors whose origin, masked, equals `value`, lets go of the matching
 * held voices and releases what nothing sustains any more. */
void le_drift_release_matching(le_drift* d, uint32_t mask, uint32_t value);

/* Whether a held voice of `origin` exists. */
int32_t le_drift_held(const le_drift* d, uint32_t origin);

/* Fades every voice out and lets go of sustain and expression. */
void le_drift_cut(le_drift* d);

/* At most `limit` sounding voices; the excess fades, oldest first. */
void le_drift_set_voice_limit(le_drift* d, int32_t limit);

/* Fades the oldest sounding voice (the engine's budget across every
 * instrument). Returns 1, or 0 when none sounds. */
int32_t le_drift_fade_oldest(le_drift* d);

/* The tempo the Sync rate modes follow (beats per minute, > 0). */
void le_drift_set_tempo(le_drift* d, float bpm);

/* Renders `frames` into `left` and `right` (overwritten). */
void le_drift_render(le_drift* d, float* left, float* right, int32_t frames);

/* Sounding voices (held, released or sustained, not fading), and voices
 * still fading. */
int32_t le_drift_active(const le_drift* d);
int32_t le_drift_fading(const le_drift* d);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_DRIFT_VOICE_H */
