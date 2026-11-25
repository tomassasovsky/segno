/*
 * meld_filter.h — Meld's filters: one per engine, any of the 17 types, a
 * frequency and two macros (SEG-109).
 *
 * The behavior is specified in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Meld: behavior"), learned from Live 12.2.7 and
 * written there in Segno's words; this code is written from that
 * description. Values it leaves open are fitted against Live renders and
 * marked "fit".
 *
 * The engine sets the frequency and macros once per control tick and runs
 * the filter every sample. Pure and real-time safe.
 */
#ifndef SEGNO_MELD_FILTER_H
#define SEGNO_MELD_FILTER_H

#include <stdint.h>

#include "meld_osc.h" /* le_meld_svf_state */

#ifdef __cplusplus
extern "C" {
#endif

/* The filter types, in the order Live stores them. */
enum {
  LE_MELD_FILTER_SVF12 = 0,
  LE_MELD_FILTER_SVF24,
  LE_MELD_FILTER_LOWPASS,
  LE_MELD_FILTER_HIGHPASS,
  LE_MELD_FILTER_BANDPASS,
  LE_MELD_FILTER_DFM,
  LE_MELD_FILTER_SRF,
  LE_MELD_FILTER_FILTHER,
  LE_MELD_FILTER_EQ_PEAK,
  LE_MELD_FILTER_EQ_NOTCH,
  LE_MELD_FILTER_PHASER,
  LE_MELD_FILTER_REDUX,
  LE_MELD_FILTER_VOWEL,
  LE_MELD_FILTER_COMB,
  LE_MELD_FILTER_COMB_INVERTED,
  LE_MELD_FILTER_PLATE,
  LE_MELD_FILTER_MEMBRANE,
  LE_MELD_FILTER_TYPES
};

/* The combs' delay line: down to 23.4 Hz at 48 kHz */
#define LE_MELD_COMB_LEN 2048
#define LE_MELD_MODES 32
#define LE_MELD_FORMANTS 5

typedef struct le_meld_filter {
  int32_t type;
  float rate;
  float hz, m1, m2; /* the last values set */
  /* the coefficients the last set computed */
  float g, k1, k2, w[3], w_to[3], w_coef;
  float gin, gout, gin_to, gout_to, glide; /* drive gains and their glide */
  union {
    struct {
      le_meld_svf_state a, b;
    } svf;
    struct {
      float s[7];
      float kfb, c_g, c_he, c_c1, c_inv1g;
    } ms2;
    struct {
      float s1, s2, y, g1, g2, kfb;
    } dfm;
    struct {
      float v, x1; /* the diode clipper's voltage and last input */
      le_meld_svf_state lp, bw;
      float dc_x, dc_y, g_bw;
    } filther;
    struct {
      float buf[LE_MELD_COMB_LEN];
      int32_t w;
      float delay, fb, damp_a, damp_b, damp_g, damp_s;
    } comb;
    struct {
      le_meld_svf_state core, pre, post;
      double clock;
      float g_on, duty, dclk, last;
    } srf;
    struct {
      float st[5]; /* osr_section.h's states */
      float g, k;
    } osr;
    struct {
      le_meld_svf_state stage[6];
      float k, k_to, fb;
    } phaser;
    struct {
      double ph;
      float hist[4];
      float levels, dc_x, dc_y;
    } redux;
    struct {
      le_meld_svf_state mode[LE_MELD_MODES];
      float g[LE_MELD_MODES], k[LE_MELD_MODES];
      float set_hz, set_m1, set_m2;
    } modal;
    struct {
      le_meld_svf_state band[LE_MELD_FORMANTS];
      float g[LE_MELD_FORMANTS], amp[LE_MELD_FORMANTS], amp_to[LE_MELD_FORMANTS];
      float k;
    } vowel;
  } s;
} le_meld_filter;

void le_meld_filter_init(le_meld_filter* f, float rate);

/* Selects `type` (LE_MELD_FILTER_*), its state cleared. */
void le_meld_filter_set_type(le_meld_filter* f, int32_t type);

/* Sets the frequency (Hz) and macros (0..1), once per control tick. */
void le_meld_filter_set(le_meld_filter* f, float hz, float m1, float m2);

/* Clears the filter's state. */
void le_meld_filter_reset(le_meld_filter* f);

/* Jumps the gains and weights that glide to their targets (a new type, a
 * note's first values). */
void le_meld_filter_snap(le_meld_filter* f);

/* Filters one sample. */
float le_meld_filter_tick(le_meld_filter* f, float x);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_MELD_FILTER_H */
