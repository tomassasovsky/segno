/*
 * pitch_ref.h — the frozen pitch kernels (pitch_ref.c), for the oracle test
 * (test_pitch_oracle.c). Native tests only.
 */
#ifndef SEGNO_PITCH_REF_H
#define SEGNO_PITCH_REF_H

#include <stdint.h>

#include "engine_fx.h"

/* Runs slot [slot]'s kind [type] on one sample pair as the kernels did
 * before #1755, when [type] is one of the pitch kinds (the Octaver, the
 * Whammy, the Dual Octaver, Smart Tune), and returns 1; returns 0, having
 * done nothing, for any other kind. The le_fx_test_process_hook shape. */
int le_pitch_ref_process(le_fx_state* fx, int slot, int32_t type, int sr,
                         int cap, float* l, float* r, const float* p);

#endif /* SEGNO_PITCH_REF_H */
