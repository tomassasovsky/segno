/*
 * restore_halfband.h — exact 2:1 half-band resampler for the loop-close
 * restoration pass (#697 S8).
 *
 * The offline denoise leg is fixed at RNNoise's 48 kHz contract while the
 * appliance records at 96 kHz, so the pipeline decimates 2:1 down and
 * interpolates 2:1 back (declip -> decimate -> denoise -> interpolate). This
 * TU is that pair: a 61-tap linear-phase half-band FIR (Blackman-windowed
 * sinc; every second tap identically zero), applied CENTERED so the group
 * delay is compensated inside each call — a decimate/interpolate round trip
 * is time-aligned with the input, no trailing shift for the caller to undo.
 *
 * Passband is flat (< 0.01 dB) to 0.4 * fs and the stopband is below -78 dB
 * from 0.6 * Nyquist up, so a round trip through the pair costs nothing
 * audible below ~19 kHz at 96 k. Edges are zero-padded (offline buffers,
 * deterministic).
 *
 * Pure functions: no state, no allocation, bit-identical across runs. The
 * consumer is the restore worker (engine_restore.c, S9).
 */
#ifndef SEGNO_RESTORE_HALFBAND_H
#define SEGNO_RESTORE_HALFBAND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Kernel half-width in samples (61 taps = 2 * 30 + 1, outermost pair zero). */
#define LE_HALFBAND_HALF 29

/* 2:1 decimate: y[i] = lowpass(x)[2i]. y must hold (n + 1) / 2 samples and
 * must not overlap x. Returns the output length, or -1 on invalid args. */
int32_t le_halfband_decimate(const float* x, uint32_t n, float* y);

/* 2:1 interpolate: y = lowpass(zero-stuffed x) * 2. y must hold 2 * n
 * samples and must not overlap x. Returns the output length (2 * n), or -1
 * on invalid args. */
int32_t le_halfband_interpolate(const float* x, uint32_t n, float* y);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_RESTORE_HALFBAND_H */
