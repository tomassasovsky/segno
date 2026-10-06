/*
 * lockfree_ring.h — single-producer / single-consumer lock-free command ring.
 *
 * The control side (Dart, via FFI) is the sole producer; the real-time audio
 * callback thread is the sole consumer. push/pop are wait-free and perform no
 * allocation, making them safe to call from the audio callback.
 *
 * Capacity must be a power of two. The ring stores fixed-size POD commands so
 * heap-backed recipes are immutable and retained through the callback's
 * end-of-block publication before the control owner reclaims them.
 */
#ifndef SEGNO_LOCKFREE_RING_H
#define SEGNO_LOCKFREE_RING_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "segno_engine_api.h" /* LE_MAX_TRACKS: bounded preset payload */

#ifdef __cplusplus
extern "C" {
#endif

/* A single engine command. `code` is an le_command_code; the payload is a tagged
 * union keyed on `code` so each producer fills, and the audio thread reads, NAMED
 * fields — no bit-packing. The generic { arg_i, arg_f } arm (a C11 anonymous
 * struct, so simple commands keep using cmd.arg_i / cmd.arg_f directly) carries
 * the single-int / single-float commands (record, volume, mute, gain, …); the
 * named arms carry the addressed commands that previously field-packed their
 * arguments. For the monitor-lane commands, the `channel` field holds the input
 * index. Exactly one arm is valid per `code`; see apply_command. */
typedef struct le_command {
  int32_t code;
  union {
    struct { /* generic single int + single float */
      int32_t arg_i;
      float arg_f;
    };
    struct { /* SET_CLICK_MODE: one callback-confirmed scalar request. */
      int32_t mode;
      uint32_t revision;
    } click;
    struct { /* SET_RECORD_START: one atomic pair with distinct edit intent. */
      int32_t value, edit_kind;
      uint32_t revision;
    } record_start;
    struct { /* SET_INPUT_MASK / SET_OUTPUT_MASK */
      int32_t channel;
      uint32_t mask;
    } trackmask;
    struct { /* SET_LANE_FX / SET_MONITOR_INPUT_FX (channel = input, lane unused) */
      int32_t channel, lane, index, type;
    } fx;
    struct { /* SET_LANE_FX_COUNT / SET_MONITOR_INPUT_FX_COUNT (channel = input)
              * pre_count is the leading Pre run (slice 3e); it rides the same
              * command as the count so the audio thread never sees a split
              * that names more Pre entries than the chain has. Owners with no
              * Pre stage (monitor, track, output) send 0. */
      int32_t channel, lane, count, pre_count;
    } fxcount;
    struct { /* lane int payload: SET_LANE_INPUT (input ch) / *_OUTPUT (mask) */
      int32_t channel, lane, value;
    } lanei;
    struct { /* lane float payload: SET_LANE_VOLUME / MUTE (+ monitor) */
      int32_t channel, lane;
      float value;
    } lanef;
    struct { /* LE_EVT_LAYER_RETIRED (audio -> control, on the evt_ring) */
      int32_t channel, slot;
      uint32_t generation;
    } evt;
    struct { /* LE_PLOG_RECORD_END (#819): which take on this channel finalized.
              * `channel` aliases the generic arm's arg_i, so the per-channel
              * events.log helpers that key off arg_i keep working unchanged;
              * `take_id` is the monotonic per-track counter (le_track.take_seq)
              * the offline renderer matches against the disarm manifest's
              * `takeId` to anchor the settled image by identity, not ordinal. */
      int32_t channel, take_id;
    } take;
    struct { /* LE_PLOG_PERF_ARMED (#262): the master loop phase at the exact
              * audio-thread frame LE_CMD_PERF_ARM applied. `master_len` == 0
              * means the capture armed with no master loop (Free/Song, or from
              * silence), and `position`/`iteration` are then both 0. */
      int32_t position, master_len, iteration;
    } perf_arm;
    struct { /* Mode/crown/defining RECORD: acknowledge typed producers. */
      int32_t value;
      uint32_t sequence;
      int32_t cancel_count_in; /* admission was an owned countdown cancellation */
    } clock;
    struct { /* SET_LENGTH_PRESETS / SET_LOOPER_MODE. count == 0 means a
              * mode-only command; bars are copied, never caller-owned pointers. */
      int32_t mode;
      uint32_t sequence;
      int32_t count;
      int32_t bars[LE_MAX_TRACKS];
    } presets;
    struct {
      int32_t channel, slot, install;
      le_fade_image image;
    } fade;
    struct { int32_t channel; float amount, target, seconds; } fade_log;
    struct { /* LE_CMD_REVERSE (#1162): install == 0 toggles, 1 sets target. */
      int32_t channel, slot, install, target;
    } reverse;
    struct { /* LE_PLOG_REVERSE: the direction fact. read_index is the exact
              * dry index the callback reads at this frame (-1 on a material
              * reset, which carries no anchor); turn_frames the equal-gain
              * turn window the old head is still mixed over (0 = none). */
      int32_t channel, reversed, read_index, turn_frames;
    } reverse_log;
    le_mix_settings mix;
    struct le_prepared_fx* recipe;
    struct {
      int32_t channel;
      uint32_t sequence;
      int32_t action;
      float trigger;
      le_record_image image;
      struct le_prepared_fx* recipes;
    } record_image;
    struct { int32_t channel; uint32_t image_id; int32_t state, phase; } restore_log;
    struct { /* LE_PLOG_PEEL (#1164): the slot now live, the slot filed as the
              * PEEL entry, and the track's dub_generation, so a reader can bind
              * the fact to the staged layer key {channel, slot, generation}. */
      int32_t channel, slot, previous;
      uint32_t generation;
    } peel_log;
    struct { /* LE_CMD_SET_LENGTH (#1168): publish `pool_slot` at `len` with
              * this multiple/division (and master, when `reclock` > 0), the
              * playhead mapped to (index - start) mod len. `receipt` is the
              * request slot, -1 for Undo/Redo; `image_id` the staged image;
              * `audio_rev` the track's a_audio_rev at admission. */
      int32_t channel, receipt, pool_slot, len, multiple, divisor, reclock,
          start;
      uint32_t image_id;
      uint32_t audio_rev; /* the content revision the image was read at */
    } length;
    struct { /* LE_PLOG_LENGTH (#1168): the slot now live at `len` frames and
              * the image staged for it (0 = none). */
      int32_t channel, slot, len;
      uint32_t image_id;
    } length_log;
    struct { /* COMMIT_SESSION: exact recorded span and musical bar count. */
      int32_t base_frames, loop_bars;
    } session;
    struct {
      le_record_timing_settings settings;
      uint32_t revision;
    } timing;
    struct { /* LE_CMD_RESTORE_CLEAR: undo of an undoable clear. `state` is the
              * pre-clear LE_TRACK_*; `master_len` re-establishes the grid when
              * the clear emptied the last track and reset the clock (0 = the
              * clear left the grid standing). The multiple is derived from the
              * base, exactly as LE_CMD_REDO_FROM_EMPTY does. */
      int32_t channel, len, state, master_len;
      float fade_amount;
    } restore;
  };
} le_command;

/* Fixed-capacity SPSC ring. `capacity` is a power of two; one slot is kept
 * empty to distinguish full from empty, so usable slots == capacity - 1. */
typedef struct le_ring {
  le_command* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index (audio thread reads) */
  _Atomic size_t tail; /* producer index (control thread writes) */
} le_ring;

/* Initialises `ring` to use `buffer` of `capacity` commands. `capacity` must be
 * a power of two and >= 2. Returns 1 on success, 0 on invalid arguments. */
int le_ring_init(le_ring* ring, le_command* buffer, size_t capacity);

/* Producer side. Returns 1 if the command was enqueued, 0 if the ring is full.
 * Wait-free; safe to call concurrently with le_ring_pop. */
int le_ring_push(le_ring* ring, le_command cmd);

/* Consumer side. Writes the next command into *out and returns 1, or returns 0
 * if the ring is empty. Wait-free; safe to call from the audio callback. */
int le_ring_pop(le_ring* ring, le_command* out);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_LOCKFREE_RING_H */
