/*
 * halfband.h — exact 2:1 half-band decimator (#697 S8).
 *
 * A 61-tap linear-phase half-band FIR (Blackman-windowed sinc; every second
 * tap identically zero), applied CENTERED so the group delay is compensated
 * inside each call: the output is time-aligned with the input, no trailing
 * shift for the caller to undo.
 *
 * Passband is flat (< 0.01 dB) to 0.4 * fs and the stopband is below -78 dB
 * from 0.6 * Nyquist up, so a halving costs nothing audible below ~19 kHz at
 * 96 k. Edges are zero-padded (offline buffers, deterministic).
 *
 * A pure function: no state, no allocation, bit-identical across runs. The
 * consumer is the audio file decoder (engine_decode.c), which halves a
 * file's rate down to the engine's.
 */
#ifndef SEGNO_HALFBAND_H
#define SEGNO_HALFBAND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Kernel half-width in samples (61 taps = 2 * 30 + 1, outermost pair zero). */
#define LE_HALFBAND_HALF 29

/* 2:1 decimate: y[i] = lowpass(x)[2i]. y must hold (n + 1) / 2 samples and
 * must not overlap x. Returns the output length, or -1 on invalid args —
 * NULL pointers, n == 0, or an output length that would not fit the int32
 * return (n such that (n + 1) / 2 > INT32_MAX). */
int32_t le_halfband_decimate(const float* x, uint32_t n, float* y);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_HALFBAND_H */
