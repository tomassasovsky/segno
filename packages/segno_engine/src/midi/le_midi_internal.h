/*
 * le_midi_internal.h - non-public MIDI entry points for deterministic tests.
 *
 * Exposes the pure parser, the backend selector, and injection hooks so the
 * portable core (the ring, the parser, the drain/callback path, and the
 * dispose-ordering guarantee) can be unit-tested without any MIDI hardware.
 * Not part of the FFI surface (excluded from ffigen).
 */
#ifndef SEGNO_ENGINE_MIDI_INTERNAL_H
#define SEGNO_ENGINE_MIDI_INTERNAL_H

#include <stdint.h>

#include "le_midi_backend.h" /* le_midi_backend, le_midi_ring_push/drain */
#include "segno_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Classification of the supported MIDI channel-voice messages. */
typedef enum le_midi_kind {
  LE_MIDI_IGNORE = 0,   /* SysEx, poly aftertouch, active sensing, etc. */
  LE_MIDI_CC = 1,       /* Control Change */
  LE_MIDI_NOTE_ON = 2,  /* Note On with non-zero velocity */
  LE_MIDI_NOTE_OFF = 3, /* Note Off, or Note On with velocity 0 */
  LE_MIDI_PROGRAM = 4,  /* Program Change (one data byte) */
  /* The kinds below reach only the engine sink (le_midi_port.h), never the
   * Dart callback, which keeps receiving exactly the four kinds above. */
  LE_MIDI_CHANNEL_PRESSURE = 5, /* 0xD0, one data byte */
  LE_MIDI_PITCH_BEND = 6,       /* 0xE0, 14-bit: data1 LSB, data2 MSB */
  LE_MIDI_SONG_POSITION = 7,    /* 0xF2, 14-bit sixteenth notes, LSB first */
  LE_MIDI_CLOCK = 8,            /* 0xF8 Timing Clock, 24 per quarter note */
  LE_MIDI_START = 9,            /* 0xFA */
  LE_MIDI_CONTINUE = 10,        /* 0xFB */
  LE_MIDI_STOP = 11,            /* 0xFC */
} le_midi_kind;

/* Parsed message. `channel` is 0..15 for channel messages and 0 otherwise.
 * `number` is the CC or note number, the program, the pressure, or the LSB of
 * a 14-bit value; `value` is the CC value, the velocity, or the MSB of a
 * 14-bit value. Real-time messages carry neither. */
typedef struct le_midi_parsed {
  le_midi_kind kind;
  uint8_t channel;
  uint8_t number;
  uint8_t value;
} le_midi_parsed;

/* Pure classifier: maps a raw (status, data1, data2) triple to its kind, filling
 * *out when out != NULL. Note On with velocity 0 is reported as LE_MIDI_NOTE_OFF
 * (the standard running-status convention). A status byte below 0x80 (a data
 * byte / running status, which the backends never forward) is LE_MIDI_IGNORE.
 * No state, no allocation - safe anywhere. */
le_midi_kind le_midi_parse(uint8_t status, uint8_t data1, uint8_t data2,
                           le_midi_parsed* out);

/* Returns the compiled-in per-OS backend, or NULL when the platform has none.
 * Mirrors le_select_backend (engine_internal.h). */
const le_midi_backend* le_midi_select_backend(void);

/* Returns the compiled-in per-OS MIDI *output* backend, or NULL when the
 * platform has none. The send-side counterpart of le_midi_select_backend. */
const le_midi_out_backend* le_midi_out_select_backend(void);

/* Test hook: register a callback on `m` directly, without opening a device, so
 * the ring -> drain -> callback path can be exercised in isolation. */
void le_midi_set_cb_for_test(le_midi* m, le_midi_event_cb cb);

/* Test hook: push a raw message as if it arrived from an OS callback (identical
 * to le_midi_ring_push). Returns 1 if enqueued, 0 if dropped/full. */
int le_midi_push_for_test(le_midi* m, uint8_t status, uint8_t data1,
                          uint8_t data2, uint64_t ts_us);

/* Whether the Dart callback ring carries `kind` (Note, CC and Program). */
int le_midi_kind_for_dart(le_midi_kind kind);

/* Whether the engine sink carries `kind`: every kind but Program and IGNORE. */
int le_midi_kind_for_sink(le_midi_kind kind);

/* Test hook: one message through the full input path a backend uses
 * (le_midi_input): the engine sink if bound, then the Dart ring. */
void le_midi_input_for_test(le_midi* m, uint8_t status, uint8_t data1,
                            uint8_t data2, uint64_t t_ns);

/* The sink at the start of every capture handle (le_midi_port.h). */
struct le_midi_sink* le_midi_sink_of(le_midi* m);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_MIDI_INTERNAL_H */
