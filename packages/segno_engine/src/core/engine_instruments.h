/*
 * engine_instruments.h — the engine side of the instrument voices (#1197
 * Part 2a): slots, buses, note rings and the synth inside the callback.
 * Internal; the public calls are in segno_engine_api.h.
 */
#ifndef SEGNO_ENGINE_INSTRUMENTS_H
#define SEGNO_ENGINE_INSTRUMENTS_H

#include <stdint.h>

#include "engine_private.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The synth's noise seed: fixed, so a render is reproducible offline. */
#define LE_INST_SYNTH_SEED 0x5e9a0u

/* Allocates the synth and the buses (le_engine_create). Returns 0 on
 * allocation failure. */
int le_instruments_create(le_engine* e);

/* Frees what le_instruments_create allocated (le_engine_destroy). */
void le_instruments_destroy(le_engine* e);

/* Re-initialises the synth at `sample_rate`, empties both rings, clears every
 * slot and bumps the synth epoch (configure and reopen, device closed). */
void le_instruments_reset(le_engine* e, int32_t sample_rate);

/* Audio thread, from apply_command: LE_CMD_SET_VOICE_LIMIT and
 * LE_CMD_INSTRUMENT_RESET. */
void le_instruments_apply_command(le_engine* e, const le_command* cmd);

/* Audio thread, once per block after the command drain: applies parameter
 * changes, drains both note rings in posting order and renders `frames` of
 * every instrument into its bus. */
void le_instruments_block(le_engine* e, uint32_t frames);

/* Audio thread: Cut all sound fades every instrument voice out. */
void le_instruments_cut(le_engine* e);

/* The bus of `slot` (LE_COND_SCRATCH_FRAMES floats; the current block's
 * frames start at 0), or NULL. */
static inline const float* le_instrument_bus(const le_engine* e, int32_t slot) {
  if (e->inst_bus == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS) return NULL;
  return e->inst_bus + (int64_t)slot * LE_COND_SCRATCH_FRAMES;
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_INSTRUMENTS_H */
