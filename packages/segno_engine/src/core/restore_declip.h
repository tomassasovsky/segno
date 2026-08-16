/*
 * restore_declip.h — offline de-clip DSP for the loop-close restoration pass
 * (#697 S8).
 *
 * Pure, deterministic, mono-float-buffer waveform repair: detect runs of
 * consecutive samples flattened against the converter rails and reconstruct
 * the missing peak. Short runs get a cubic Hermite spline through the
 * shoulder samples; longer runs get a Burg AR fit on the context each side
 * with two-sided prediction crossfaded across the gap (Janssen-style).
 *
 * This TU is the algorithm only — no engine state, no threads, no worker.
 * The restore worker (engine_restore.c, S9) is the consumer; until it lands
 * nothing in the engine calls this. Sample-rate agnostic: everything is
 * expressed in samples, no rate parameter (the constants below are sized for
 * the appliance's 96 kHz worst case).
 *
 * Determinism + allocation contract: no allocation anywhere — the caller
 * owns the one fixed-size scratch struct — and no other hidden state, so two
 * runs over the same input are bit-identical.
 */
#ifndef SEGNO_RESTORE_DECLIP_H
#define SEGNO_RESTORE_DECLIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* AR model order for the long-run path. 32 poles resolve 16 sinusoids —
 * plenty for the few milliseconds of quasi-stationary signal around a
 * clipped peak. Effective order shrinks when context is short. */
#define LE_DECLIP_ORDER 32

/* Max context samples fitted on each side of a long run (10.7 ms at 96 k).
 * Length is load-bearing: long runs come from clipped LOW-frequency content,
 * and at 96 k a short window holds a fraction of one cycle — a near-DC arc
 * whose frequency float-quantized data cannot pin down (the fitted pole
 * angle comes out far off and the extrapolation bends away early). One full
 * cycle of everything down to ~94 Hz fits in this window. */
#define LE_DECLIP_CTX 1024

/* Runs up to this length use the Hermite spline; longer runs use AR. */
#define LE_DECLIP_SHORT_RUN 16

/* CONSERVATIVE BOUND, sustained clipping: runs longer than this (5.3 ms at
 * 96 k) are left untouched. That much continuous rail is not a transient
 * peak — it is sustained overdrive (or a stuck converter), and no
 * interpolation of that length is trustworthy. Pass-through, never a guess. */
#define LE_DECLIP_MAX_RUN 512

/* Hysteresis: a run SEEDS at |s| >= clip_level and GROWS outward over
 * neighboring same-polarity samples with |s| >= clip_level * this factor —
 * the shoulder samples the anti-alias filter smeared slightly below the rail
 * are part of the damage and get repaired with the run. */
#define LE_DECLIP_HYST 0.97f

/* CONSERVATIVE BOUND, reconstruction amplitude: every repaired sample is
 * clamped into [rail, 2 * clip_level] in magnitude (rail = the original
 * sample it replaces, which sits at ~clip_level). The floor is physics — a
 * sample was clipped precisely because the true signal was beyond the rail
 * for the whole run — and the +6 dB ceiling means AR divergence on
 * pathological input can never exceed twice full scale. The ceiling binds
 * reconstructed values only: where the original sample already exceeds it
 * (clip_level set well below the material's true peaks), the ceiling lifts
 * to the original — a repair never attenuates the sample it replaces. */
#define LE_DECLIP_CLAMP_X 2.0f

/* Caller-allocated scratch (~33 KB): the only working memory the algorithm
 * uses. Contents are meaningless between calls; no init needed. The AR
 * machinery is double precision — at 96 kHz, low-frequency content puts
 * reflection coefficients within 1e-5 of the unit circle, where float
 * resolution corrupts the fit. */
typedef struct le_declip_scratch {
  float ctx[LE_DECLIP_CTX];               /* spline-pre-filled context copy */
  float rev[LE_DECLIP_CTX];               /* reversed right context */
  double f[LE_DECLIP_CTX];                /* Burg forward prediction errors */
  double b[LE_DECLIP_CTX];                /* Burg backward prediction errors */
  double a[LE_DECLIP_ORDER + 1];          /* AR polynomial, a[0] = 1 */
  double fwd[LE_DECLIP_ORDER + LE_DECLIP_MAX_RUN]; /* forward extrapolation */
  double bwd[LE_DECLIP_ORDER + LE_DECLIP_MAX_RUN]; /* backward extrapolation */
} le_declip_scratch;

/* Repairs clipped runs in `buf` (mono, `n` samples) in place. `clip_level`
 * is the rail magnitude to detect against (the engine's live detector uses
 * 0.999). Runs touching the buffer edges, and runs longer than
 * LE_DECLIP_MAX_RUN, pass through untouched (documented conservative
 * behavior; a linear buffer has no context beyond its ends). A buffer with
 * no sample at or beyond the rail comes back bit-exact.
 *
 * Returns the number of runs repaired (>= 0), or -1 on invalid arguments
 * (NULL pointers, n == 0, clip_level <= 0). */
int32_t le_declip_process(float* buf, uint32_t n, float clip_level,
                          le_declip_scratch* scratch);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_RESTORE_DECLIP_H */
