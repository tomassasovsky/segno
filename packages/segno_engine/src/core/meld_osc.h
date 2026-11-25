/*
 * meld_osc.h — Meld's oscillators: one generator per engine, any of the 25
 * types, two macros each (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Meld: behavior"), learned from Live 12.2.7 and
 * written there in Segno's words; this code is written from that
 * description. Values it leaves open are fitted against Live renders and
 * marked "fit".
 *
 * The engine sets the frequency and both macros once per control tick
 * (LE_MELD_OSC_TICK samples) and ticks one sample at a time; the macros'
 * effect ramps over 5 ms. The FM types run at min(rate, 44.1 kHz) and are
 * interpolated up to the host rate. Pure and real-time safe: no allocation,
 * no locks, no syscalls.
 */
#ifndef SEGNO_MELD_OSC_H
#define SEGNO_MELD_OSC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The oscillator types, in the order Live stores them. */
enum {
  LE_MELD_OSC_BASIC = 0,
  LE_MELD_OSC_DUAL_BASIC,
  LE_MELD_OSC_NOISY_SHAPES,
  LE_MELD_OSC_SQUARE_SYNC,
  LE_MELD_OSC_SQUARE_5TH,
  LE_MELD_OSC_SUB,
  LE_MELD_OSC_SWARM_SINE,
  LE_MELD_OSC_SWARM_TRIANGLE,
  LE_MELD_OSC_SWARM_SAW,
  LE_MELD_OSC_SWARM_SQUARE,
  LE_MELD_OSC_HARMONIC_FM,
  LE_MELD_OSC_FOLD_FM,
  LE_MELD_OSC_SQUELCH,
  LE_MELD_OSC_SIMPLE_FM,
  LE_MELD_OSC_CHIP,
  LE_MELD_OSC_SHEPARD,
  LE_MELD_OSC_TARP,
  LE_MELD_OSC_EXTRATONE,
  LE_MELD_OSC_NOISE_LOOP,
  LE_MELD_OSC_FILTERED_NOISE,
  LE_MELD_OSC_BITGRUNGE,
  LE_MELD_OSC_CRACKLE,
  LE_MELD_OSC_RAIN,
  LE_MELD_OSC_BUBBLE,
  LE_MELD_OSC_CHORD,
  LE_MELD_OSC_TYPES
};

#define LE_MELD_OSC_TICK 16
#define LE_MELD_SWARM_LANES 12
#define LE_MELD_CHORD_TONES 8

/* A two-pole state-variable filter's states. */
typedef struct le_meld_svf_state {
  float s1, s2;
} le_meld_svf_state;

/* One sample of a trapezoidal state-variable filter: g = tan(pi f / rate),
 * k the damping (2 is Q 0.5). Returns the low-pass; *bp and *hp, when
 * given, take the band and high outputs. */
static inline float le_meld_svf(le_meld_svf_state* s, float x, float g, float k, float* bp,
                                float* hp) {
  const float h = 1.0f / (1.0f + g * (g + k));
  const float b = (g * (x - s->s2) + s->s1) * h;
  const float l = s->s2 + g * b;
  s->s1 = 2.0f * b - s->s1;
  s->s2 = 2.0f * l - s->s2;
  if (bp != 0) *bp = b;
  if (hp != 0) *hp = x - k * b - l;
  return l;
}

/* The 44.1 kHz types' resampler: the last four internal samples and the
 * position between the middle two. */
typedef struct le_meld_resampler {
  float h[4];
  double pos;
} le_meld_resampler;

#define LE_MELD_RAIN_LANES 8
#define LE_MELD_BUBBLES 64
#define LE_MELD_VOSS_ROWS 16

typedef struct le_meld_osc {
  int32_t type;
  float rate;  /* the host rate */
  float irate; /* the internal rate of the 44.1 kHz types */
  float hz;    /* the frequency the engine set */
  float note;  /* its note number */
  /* the macros: their value, target and per-sample step over 5 ms */
  float m1, m2, m1_to, m2_to, m1_step, m2_step;
  int32_t ramp_n, ramp_left;
  uint32_t rng;
  le_meld_resampler rs; /* the 44.1 kHz types' resampler */
  union {
    struct {
      double ph[2];
    } basic; /* Basic Shapes, Dual Basic Shapes, Square 5th (ph[1]: its multiple) */
    struct {
      double ph[2 * LE_MELD_SWARM_LANES];
      float inc[2 * LE_MELD_SWARM_LANES];
      float x[LE_MELD_SWARM_LANES], dx[LE_MELD_SWARM_LANES];
      int32_t steps[LE_MELD_SWARM_LANES];
      int32_t left;
    } swarm;
    struct {
      double ph[LE_MELD_CHORD_TONES];
      float inc[LE_MELD_CHORD_TONES];
      int32_t left;
    } chord;
    struct {
      le_meld_svf_state lp, hp;
    } fnoise;
    struct {
      double c, m[2], psi;
    } fm; /* Simple, Harmonic and Fold FM */
    struct {
      double c, m, h;
      float t1;
    } squelch;
    struct {
      double ph[2], half;
      le_meld_svf_state hp[2];
      float x1;
    } noisy;
    struct {
      double ph, ph4;
      float hp_x, hp_y;
    } sub;
    struct {
      double ph;
      int32_t n, len;
      float w, decay, step;
      le_meld_svf_state lp;
      int32_t repeat; /* Extratone: samples to the next kick */
    } tarp;
    struct {
      double master, slave[2];
      float out, carry; /* the one-sample delay the sync corrections need */
    } sync;
    struct {
      double theta, psi;
      uint32_t seed[2];
      float level[2];
      int32_t filtered[2]; /* the stretch was recorded through the low-pass */
      le_meld_svf_state hp;
    } loop; /* Noise Loop */
    struct {
      double ph, trill;
      int32_t upper;
    } chip;
    struct {
      le_meld_svf_state lp, hp;
      float timer, env, decay, glp, ghp;
    } crackle;
    struct {
      double shift;
      double ph[8];
    } shepard;
    struct {
      uint32_t count;
      double frac;
      float out;
    } grunge;
    struct {
      float amp[LE_MELD_BUBBLES], freq[LE_MELD_BUBBLES], rise[LE_MELD_BUBBLES], decay[LE_MELD_BUBBLES];
      double ph[LE_MELD_BUBBLES];
      float timer, gain;
      int32_t slot;
    } bubble;
    struct {
      le_meld_svf_state lane[LE_MELD_RAIN_LANES], bg;
      float timer[LE_MELD_RAIN_LANES], g[LE_MELD_RAIN_LANES];
      float rows[LE_MELD_VOSS_ROWS];
      float sum, last_hz;
      uint32_t counter;
      double lfo;
    } rain;
  } s;
} le_meld_osc;

/* Builds the shared tables (idempotent; call from a slow path first). */
void le_meld_osc_tables(void);

/* Prepares `o` at the host `rate`, seeding its random generator. */
void le_meld_osc_init(le_meld_osc* o, float rate, uint32_t seed);

/* Selects `type` (LE_MELD_OSC_*). Its state starts afresh and its macros
 * jump to their targets. */
void le_meld_osc_set_type(le_meld_osc* o, int32_t type);

/* Sets the frequency (Hz, and its note number) and the macros (0..1),
 * once per control tick. The macros ramp to their new values over 5 ms. */
void le_meld_osc_set(le_meld_osc* o, float hz, float note, float m1, float m2);

/* Jumps the macros to their targets (a note start). */
void le_meld_osc_snap(le_meld_osc* o);

/* Note start: resets the phase to `phase` (0..1), as each type does. */
void le_meld_osc_reset(le_meld_osc* o, float phase);

/* One output sample at the host rate. */
float le_meld_osc_tick(le_meld_osc* o);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_MELD_OSC_H */
