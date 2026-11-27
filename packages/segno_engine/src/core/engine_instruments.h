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

/* Slot `slot`'s instance of device `device` (LE_INST_DEVICE_*, a known
 * one): an le_drift, le_operator, le_meld, le_analog, le_electric,
 * le_tension or le_collision. For tests and the slot code; the audio thread owns it once the engine runs.
 * NULL for an unknown device or slot. */
void* le_instruments_device(le_engine* e, int32_t device, int32_t slot);

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

/* The two halves of le_instruments_block, which the callback runs around the
 * MIDI drain (review L2): apply the parameter changes and the note rings
 * first, so a MIDI note meets a patch posted before it, then render. */
void le_instruments_apply(le_engine* e);
void le_instruments_render(le_engine* e, uint32_t frames);

/* ---- MIDI routing (Part 2c), called from le_midi_ports_drain ----
 * begin: once per block, before any port; switches in a published route
 * table and acknowledges it. An instrument whose MIDI the new table turns
 * off or moves to another port or channel lets go of the old port's notes
 * and sustain and drops the expression MIDI set on it (review M1). event: one current event (the drain's EVENT
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

/* Channel `ch` (0 left, 1 right) of the bus of `slot` (LE_INST_BUS_FRAMES
 * floats; the current block's frames start at 0), or NULL. */
static inline const float* le_instrument_bus(const le_engine* e, int32_t slot,
                                             int32_t ch) {
  if (e->inst_bus == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS ||
      ch < 0 || ch >= LE_INST_BUS_CHANNELS) {
    return NULL;
  }
  return e->inst_bus +
         ((int64_t)slot * LE_INST_BUS_CHANNELS + ch) * LE_INST_BUS_FRAMES;
}

/* Control thread: whether `slot` has a patch or a device requested, so its
 * source can record (SEG-109). */
static inline int le_instrument_requested(const le_engine* e, int32_t slot) {
  return e->inst_patch_requested[slot] >= 0 ||
         e->inst_device_requested[slot] != LE_INST_DEVICE_NONE;
}

/* Whether `source` names an instrument slot (#1197 Part 2b). */
static inline int le_source_is_instrument(int32_t source) {
  return source >= LE_INSTRUMENT_SOURCE_BASE && source < LE_MAX_SOURCES;
}

/* Frame `f` of instrument source `source` (an instrument slot) in the current
 * block, left in *l and right in *r: its bus, or silence when this block's
 * buses are not live (a block larger than the scratch). An empty slot's bus
 * is silence. What feeds a chain or an output takes both channels. */
static inline void le_instrument_source_frame(const le_engine* e,
                                              int32_t source, uint32_t f,
                                              float* l, float* r) {
  if (!e->inst_bus_live) {
    *l = 0.0f;
    *r = 0.0f;
    return;
  }
  const float* bus = e->inst_bus + (int64_t)(source - LE_INSTRUMENT_SOURCE_BASE) *
                                       LE_INST_BUS_CHANNELS * LE_INST_BUS_FRAMES;
  *l = bus[f];
  *r = bus[LE_INST_BUS_FRAMES + f];
}

/* The mono sum (L + R) / 2 of frame `f` of instrument source `source`: what
 * a mono stage records (the clean take, the raw performance tap). Equal
 * channels give that channel exactly, so a patch voice (both channels the
 * same) records as it did on a mono bus. */
static inline float le_instrument_source_mono(const le_engine* e,
                                              int32_t source, uint32_t f) {
  float l, r;
  le_instrument_source_frame(e, source, f, &l, &r);
  return 0.5f * (l + r);
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_INSTRUMENTS_H */
