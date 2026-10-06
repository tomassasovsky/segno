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

/* ---- MIDI routing (Part 2c), called from le_midi_ports_drain ----
 * begin: once per block, before any port; switches in a published route
 * table and acknowledges it. event: one current event (the drain's EVENT
 * dispatch). gone: the drain's GAP, LOST and REBOUND dispatches, in stream
 * order: lets go of the port's held notes, removes its sustain contributors
 * and resets the expression it set. */
void le_instruments_midi_begin(le_engine* e);
void le_instruments_midi_event(le_engine* e, int32_t port,
                               const le_midi_port_event* ev);
void le_instruments_midi_gone(le_engine* e, int32_t port);

/* Control-thread origins carry this bit, MIDI origins never do. */
#define LE_INST_CONTROL_ORIGIN 0x80000000u

/* Audio thread: Cut all sound fades every instrument voice out. */
void le_instruments_cut(le_engine* e);

/* The bus of `slot` (LE_COND_SCRATCH_FRAMES floats; the current block's
 * frames start at 0), or NULL. */
static inline const float* le_instrument_bus(const le_engine* e, int32_t slot) {
  if (e->inst_bus == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS) return NULL;
  return e->inst_bus + (int64_t)slot * LE_COND_SCRATCH_FRAMES;
}

/* Whether `source` names an instrument slot (#1197 Part 2b). */
static inline int le_source_is_instrument(int32_t source) {
  return source >= LE_INSTRUMENT_SOURCE_BASE && source < LE_MAX_SOURCES;
}

/* Frame `f` of instrument source `source` (an instrument slot) in the current
 * block: its bus sample, or silence when this block's buses are not live
 * (a block larger than the scratch). An empty slot's bus is silence. */
static inline float le_instrument_source_sample(const le_engine* e,
                                                int32_t source, uint32_t f) {
  if (!e->inst_bus_live) return 0.0f;
  return e->inst_bus[(int64_t)(source - LE_INSTRUMENT_SOURCE_BASE) *
                         LE_COND_SCRATCH_FRAMES +
                     f];
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_INSTRUMENTS_H */
