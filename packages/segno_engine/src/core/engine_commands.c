#include <math.h>
/*
 * engine_commands.c — control-thread command producers + record/undo machinery.
 *
 * THREAD OWNERSHIP: control thread (the Dart-facing FFI setters). Almost every
 * function here validates its arguments and posts a command into the SPSC ring
 * (le_push) for the audio thread to apply; the exceptions do control-thread work
 * the audio thread is guaranteed not to race — the O(1) undo/redo buffer-index
 * swaps, the shadow-slot supply + retired-layer collection (le_engine_drain_events),
 * the quantize/auto-record arm bookkeeping, and the lazy effect-buffer / lane
 * allocation in le_fx_prepare_entry / le_engine_set_lane_count.
 *
 * Undo layers are captured PER OVERDUB PASS on the audio thread (backup-on-write
 * into a pre-posted shadow slot — see engine_process.c); completed layers come
 * back through the evt_ring and are pushed onto the control-side stacks here.
 * Control mutations follow push-then-mutate: state is only changed after the
 * matching ring command was accepted, so a full ring never desyncs the two sides.
 *
 * Split verbatim out of engine.c (S1) behind the unchanged ABI. Shared helpers
 * (le_push, valid_channel, le_lanes_active, le_lane_reset)
 * come from engine_core.h; the octaver Hann init + PV sizes from engine_fx.h. The
 * matching audio-thread consumers (apply_command + handlers) are in
 * engine_process.c.
 */
#include <stdint.h>
#include <stdio.h> /* fprintf — the disarm callback-telemetry summary (#722) */
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h"  /* le_audio_ring_alloc/release (capture rings) */
#include "engine_cache.h" /* le_cache_tick (wet-cache scheduler heartbeat) */
#include "engine_restore.h" /* le_restore_tick + le_restore_commit_layer (#697) */
#include "engine_core.h" /* le_push, valid_channel, le_lanes_active, le_*_reset */
#include "engine_fx.h"   /* le_fx_ensure_hann, LE_PV_N / LE_PV_BINS */
#include "engine_private.h"
#include "engine_internal.h"
#include "layer_staging_ring.h" /* le_layer_staging_ring_push (retired-layer persistence) */
#include "segno_engine_api.h"
#include "perf_drain.h"     /* le_perf_drain_start/stop (capture-to-disk thread) */
#include "perf_log_ring.h"  /* le_perf_log_ring_push (control-side event log) */
#include "tempo_grid.h"     /* le_grid_signature_valid, le_grid_div bounds */

/* Whether the track's history is entirely erased-take material — i.e. its top
 * entry is a clear restore point, so everything on the stack belongs to a take
 * the user cleared. Such history yields to a fresh recording (it never outranks
 * one), which is what le_grid_still_needed and le_drop_clear_history rely on. */
static int le_history_is_cleared(const le_track* t) {
  return t->undo_count > 0 &&
         t->undo_stack[t->undo_count - 1].kind == LE_HIST_CLEAR;
}

/* Republishes what the host may read off a snapshot: how many overdub layers
 * undo can peel RIGHT NOW, and whether the next undo restores a cleared take.
 *
 * a_undo_depth is not the raw entry count. Its published contract is "available
 * undo steps (overdub layers)" (segno_engine_api.h), and a cleared track's
 * layers are not steps yet — they sit under a restore point and only become
 * peelable once it is undone. Publishing the raw count there would report peel
 * depth on an EMPTY track, breaking both that contract and the host's
 * EMPTY => undoDepth == 0 invariant. The restore point gets its own flag
 * instead, so "undo does something" stays answerable without conflating the two.
 *
 * The pair is stored non-atomically with respect to each other; a host reading
 * between them sees at worst a stale flag on the next poll, the same tolerance
 * every other published depth already carries. */
/* The undo-stack index of the LAYER the next Peel consumes (#1164): the
 * topmost LAYER reachable from the top through PEEL entries only, with
 * *skipped = how many PEEL entries sit above it. -1 when none is reachable —
 * the stack is empty (the live buffer is the original take), or a kind that is
 * not an overdub (CLEAR, PROCESSED) lies above the topmost LAYER. Stopping at
 * the deepest LAYER is what keeps the original take out of Peel's reach: that
 * entry IS the pre-first-overdub image, so swapping it in leaves the original
 * audible with nothing deeper to consume. */
static int le_peel_target(const le_track* t, int32_t* skipped) {
  int n = 0;
  for (int i = t->undo_count - 1; i >= 0; --i) {
    const int32_t kind = t->undo_stack[i].kind;
    if (kind == LE_HIST_LAYER) {
      *skipped = n;
      return i;
    }
    if (kind != LE_HIST_PEEL) break;
    ++n;
  }
  *skipped = 0;
  return -1;
}

/* How many LAYER entries Peel can still consume: those above the highest entry
 * that is neither LAYER nor PEEL (the whole stack when there is none). */
static int32_t le_peel_depth(const le_track* t) {
  int32_t depth = 0;
  for (int i = t->undo_count - 1; i >= 0; --i) {
    const int32_t kind = t->undo_stack[i].kind;
    if (kind == LE_HIST_LAYER) ++depth;
    else if (kind != LE_HIST_PEEL) break;
  }
  return depth;
}

static void le_publish_undo_depth(le_track* t) {
  /* A frozen take's restore point is still to be filed: the layers kept
   * beneath it are not peelable yet (the track reads EMPTY), and the restore
   * is not offered until the point lands — so both read 0 for now. */
  if (t->clear_restore_pending) {
    store_i32(&t->a_undo_depth, 0);
    store_i32(&t->a_clear_restore, 0);
    store_i32(&t->a_peel_depth, 0);
    return;
  }
  /* A command that gives the track content is in flight (a clear restore,
   * a resurrect) while the wire still reads EMPTY: hold both at 0 — an EMPTY
   * track never shows peelable layers — and republish once the audio thread
   * has applied it (le_engine_drain_events). */
  if (t->state_cmds_posted >
          atomic_load_explicit(&t->a_state_acks, memory_order_acquire) &&
      t->pending_target != LE_TRACK_EMPTY &&
      load_i32(&t->a_state) == LE_TRACK_EMPTY) {
    store_i32(&t->a_undo_depth, 0);
    store_i32(&t->a_clear_restore, 0);
    store_i32(&t->a_peel_depth, 0);
    t->depth_republish = 1;
    return;
  }
  const int cleared = le_history_is_cleared(t);
  store_i32(&t->a_undo_depth, cleared ? 0 : t->undo_count);
  store_i32(&t->a_clear_restore, cleared ? 1 : 0);
  /* A CLEAR on top already reads 0 (nothing LAYER or PEEL above it). */
  store_i32(&t->a_peel_depth, le_peel_depth(t));
}

/* The pool slot INDEX the next shadow acquisition on [t] selects, given the
 * history it will see: the first index that is neither the (shared) live index
 * nor named by the first `undo_count` / `redo_count` / `outstanding_count`
 * entries of the respective stacks. The same index names the snapshot in every
 * lane — the undo span is lockstep across lanes — so this works on the
 * track-level stacks plus lane 0's live index (all lanes share it). When every
 * index is in use, it names the slot of the oldest evictable undo entry and
 * stores that entry's stack position in *evict (else -1); -1 when nothing can
 * be freed. PURE: it evicts nothing and allocates nothing, so the capture
 * admission check in le_record_impl can preview exactly the slot the real
 * acquisition below will take, from the retained-history view that action
 * leaves behind, without a second selection policy.
 *
 * The LE_HIST_CLEAR skip is belt-and-braces, NOT a live path: a restore point
 * only sits on the undo stack while its track is EMPTY, and an EMPTY track
 * posts no dub shadows, so nothing acquires against a stack holding one. (Once
 * undone it moves to the redo stack, where the `used` scan pins its slot — and
 * a punch-in discards it via le_clear_redo before acquiring anyway.) The
 * invariant is subtle and lives in three places, so this stays: if it ever
 * breaks, degrading peel depth is survivable and recycling the erased take's
 * buffer into a live recording is not. Deliberately untested — the mutation
 * that removes it cannot be caught, because the path cannot be reached.
 *
 * PEEL and PROCESSED entries (#1164) are evictable like LAYERs: losing one
 * costs a recovery step, never audio the track plays. A redo-side PEEL marker
 * names slot -1, which the `used` scan never matches, so it pins nothing. */
static int track_select_slot(le_track* t, int undo_count, int redo_count,
                             int outstanding_count, int* evict) {
  *evict = -1;
  const int live = load_i32(&t->lanes[0].a_live);
  for (int i = 0; i < LE_POOL_SLOTS; ++i) {
    if (i == live) continue;
    int used = 0;
    for (int k = 0; k < undo_count && !used; ++k) {
      if (t->undo_stack[k].slot == i) used = 1;
    }
    for (int k = 0; k < redo_count && !used; ++k) {
      if (t->redo_stack[k].slot == i) used = 1;
    }
    for (int k = 0; k < outstanding_count && !used; ++k) {
      if (t->outstanding_slots[k] == i) used = 1;
    }
    if (!used) return i;
  }
  for (int e = 0; e < undo_count; ++e) {
    if (t->undo_stack[e].kind == LE_HIST_CLEAR) continue;
    *evict = e;
    return t->undo_stack[e].slot;
  }
  return -1;
}

/* Acquires the slot track_select_slot names for the track's current stacks.
 * If the pool is full, evicts the oldest undo entry and reuses its slot (never
 * an audio-held one) — layers are fair game: losing the deepest one costs peel
 * depth and nothing else. Returns -1 only if nothing can be freed. Allocation
 * of the slot's buffers happens per lane in le_post_dub_shadows. */
static int track_acquire_slot(le_track* t) {
  int evict;
  const int slot = track_select_slot(t, t->undo_count, t->redo_count,
                                     t->outstanding_count, &evict);
  if (evict >= 0) {
    for (int k = evict + 1; k < t->undo_count; ++k) {
      t->undo_stack[k - 1] = t->undo_stack[k];
    }
    t->undo_count--;
    le_publish_undo_depth(t);
  }
  return slot;
}

/* How many shadow slots control keeps posted to the audio thread per capturing
 * track: the armed one plus one spare, so a pass boundary can rotate without
 * waiting a control round-trip. */
#define LE_DUB_SHADOWS 2

/* The track's SETTLED loop length, or 0 when it has none yet. A track still
 * RECORDING publishes a_len as its GROWING record position (the per-block
 * publish in engine_process.c), not the final loop length — so a_len must never
 * be used to size an undo-layer slot mid-capture. The pass that fills such a
 * slot covers the FINAL length (le_dub_session_start latches dub_len at
 * finalize), so a slot sized to a partial length would be written past its end
 * by the audio thread's backup-on-write. Callers read 0 as "not settled": size
 * at the cap, and don't resize. */
static int32_t le_track_settled_len(le_track* t) {
  if (load_i32(&t->a_state) == LE_TRACK_RECORDING) return 0;
  return load_i32(&t->lanes[0].a_len);
}

/* The buffer an undo layer for a settled `len`-frame loop needs: the length
 * rounded up to LE_LAYER_QUANTUM, capped at the recording cap — a 2 s loop's
 * layer costs ~2 s of floats, not the cap. `len <= 0` (not settled — a pre-arm
 * posted while the loop is still being recorded) can only be served by the full
 * cap; le_handle_retired shrinks such a slot back to size once its pass retires
 * and the real length is known. */
static int32_t le_layer_slot_frames(const le_engine* engine, int32_t len) {
  if (len <= 0) return engine->max_loop_frames;
  const int32_t want =
      ((len + LE_LAYER_QUANTUM - 1) / LE_LAYER_QUANTUM) * LE_LAYER_QUANTUM;
  return want > engine->max_loop_frames ? engine->max_loop_frames : want;
}

/* Tops the track's posted shadow slots up to `target` (control thread):
 * acquires a free pool slot, lazily allocates its buffer on every active lane,
 * and posts it via LE_CMD_DUB_SHADOW. Push-then-mutate: the slot only becomes
 * `outstanding` once the ring accepted the command (a lazily allocated buffer
 * stays in the pool either way). The audio thread arms the slot as its next
 * shadow; the ring's release/acquire publishes the fresh buffers, exactly like
 * the fx delay-line pattern.
 *
 * `target` is LE_DUB_SHADOWS (armed + spare) for a running dub session, but 1
 * for a pre-arm during RECORDING: the length is not settled there, so each slot
 * costs the full recording cap, and only the first wrap's pass needs one — its
 * spare arrives from the running session's replenish right after finalize, when
 * the length is settled and the slot is loop-length-quantized. Capped at
 * LE_DUB_SHADOWS. */
static void le_post_dub_shadows(le_engine* engine, int32_t channel,
                                int32_t target) {
  le_track* t = &engine->tracks[channel];
  /* Old callback shadows remain owned until the pending Clear completes. */
  if (t->clear_restore_pending) return;
  const int32_t lanes = le_lanes_active(t);
  const int32_t want = le_layer_slot_frames(engine, le_track_settled_len(t));
  if (target > LE_DUB_SHADOWS) target = LE_DUB_SHADOWS;
  while (t->outstanding_count < target) {
    const int slot = track_acquire_slot(t);
    if (slot < 0) return; /* pool exhausted beyond eviction: skip boundaries */
    int ok = 1;
    for (int32_t l = 0; l < lanes; ++l) {
      if (!le_lane_ensure_slot(&t->lanes[l], slot, want)) {
        ok = 0; /* OOM: do not post a torn slot */
      }
    }
    if (!ok) return;
    if (le_push_cmd(engine, (le_command){.code = LE_CMD_DUB_SHADOW,
                                         .lanei = {channel, 0, slot}}) !=
        LE_OK) {
      return; /* ring full: try again on the next drain/press */
    }
    t->outstanding_slots[t->outstanding_count++] = slot;
  }
}

/* Whether a fresh capture on [channel] is bound to continue straight into
 * overdub, so its shadow slots are worth pre-arming during RECORDING — letting
 * the first wrap's pass back up on write and retire as its own undo layer
 * instead of merging into the base. rec/dub mode continues any second-press
 * finalize into overdub, so any capture qualifies when it is on. With rec/dub
 * off, only a non-defining capture (master already exists) with a fixed loop
 * multiple auto-finalizes into overdub; a defining capture, or one with an auto
 * multiple, finalizes to playback and is skipped so it never strands a pre-armed
 * slot (cap-sized, since the length is unknown until finalize).
 *
 * Known, deliberate exclusion: an auto-multiple capture that records all the
 * way to the buffer cap rolls into overdub (advance_transport_frame's
 * record_pos >= max_loop_frames auto-finalize) with no pre-armed slot, so that
 * first wrap merges into the base — the pre-fix behaviour. Covering it would
 * mean pre-arming every auto-multiple capture, stranding a cap-sized slot on
 * the common record-to-playback flow, to benefit only a capture held for the
 * entire cap (30 s+) without a press.
 *
 * `has_master` comes from the CALLER, never re-read from a_master_len here: a
 * caller that just pushed the internal grid-redefine CLEAR (le_engine_record's
 * fresh-take branch) already knows the capture will be defining, while the
 * atomic stays stale until the audio thread applies that CLEAR — re-reading it
 * would pre-arm exactly the defining capture this gate exists to skip. */
static int le_capture_may_overdub(le_engine* engine, int32_t channel,
                                  int has_master) {
  if (engine->rec_dub) return 1;
  if (!has_master) return 0;
  return le_effective_multiple(engine, channel) > 0;
}

/* Pushes onto the redo stack, refusing rather than running off the end.
 *
 * Most entries name a distinct pool slot, so live + undo + redo + outstanding <=
 * LE_POOL_SLOTS bounds the stacks implicitly. Two pushes escape that bound by
 * naming the ALREADY-live slot and consuming no new one: undo-to-empty's, and
 * the clear restore point's (#219). Today the totals still fit — LE_DUB_SHADOWS
 * keeps 2 slots outstanding while dubbing, so undo tops out at LE_POOL_SLOTS - 3
 * and redo peaks one index short of the end — but that is a one-slot margin
 * resting on a constant that has nothing to do with undo. Bound it explicitly
 * instead of leaving the arrays safe by coincidence. */
static int le_redo_push(le_track* t, le_hist_entry e) {
  if (t->redo_count >= LE_POOL_SLOTS) return 0;
  t->redo_stack[t->redo_count++] = e;
  return 1;
}

/* One undo step on a track that has stacked layers (control thread): swap the
 * live pool index back to the top undo snapshot and push the previous live onto
 * the redo stack — every active lane in lockstep (the one undo span). The
 * caller has verified the track is not capturing and no layer is in flight.
 *
 * The redo push cannot fail here: it moves one entry off the undo stack for the
 * one it adds, so the total is unchanged. Losing the redo step would still beat
 * corrupting the struct, hence the guard rather than an assert.
 *
 * Capture provenance (#1143): the target slot is staged as an immutable image
 * BEFORE it is published, so the callback can name exactly the PCM that became
 * audible at the frame it first mixes it. Staging refusal never refuses the
 * swap (D5); the stem then fails truthfully (323/0). */
static uint32_t le_stage_source_image(le_engine* engine, int32_t channel,
                                      int32_t slot, int32_t len);

/* A history entry of `kind` naming `slot`; `skipped` is meaningful for PEEL
 * only and zero otherwise. Same zero-filling aggregate shape as le_hist_layer. */
static le_hist_entry le_hist_kind_entry(int32_t kind, int32_t slot,
                                        int32_t skipped) {
  le_hist_entry e = le_hist_layer(slot);
  e.kind = kind;
  e.skipped = skipped;
  return e;
}

static void le_undo_swap(le_engine* engine, le_track* t) {
  const le_hist_entry top = t->undo_stack[--t->undo_count];
  const int32_t live = load_i32(&t->lanes[0].a_live);
  const uint32_t id = le_stage_source_image(
      engine, (int32_t)(t - engine->tracks), top.slot,
      load_i32(&t->lanes[0].a_len));
  if (top.kind == LE_HIST_PEEL) {
    /* Undo of a Peel (#1164): the image Peel removed comes back live, and the
     * LAYER it consumed is re-inserted `skipped` entries below the PEEL's
     * position — beneath the PEEL entries that sat above it at peel time — so
     * the stack is exactly what it was before that peel and history stays
     * chronological across repeated peels and later overdubs. Clamped to the
     * bottom: pool eviction removes the lowest entries first, so the entries
     * between the insertion point and the PEEL can only have vanished once
     * nothing lay below them. The redo marker (slot -1) re-peels. */
    const int p = t->undo_count;
    int insert = p - top.skipped;
    if (insert < 0) insert = 0;
    for (int k = p; k > insert; --k) t->undo_stack[k] = t->undo_stack[k - 1];
    t->undo_stack[insert] = le_hist_layer(live);
    t->undo_count++;
    (void)le_redo_push(t, le_hist_kind_entry(LE_HIST_PEEL, -1, top.skipped));
  } else {
    /* LAYER and PROCESSED: the redo entry keeps the kind, so a redo re-files
     * a restoration swap as PROCESSED rather than as a peelable layer. */
    (void)le_redo_push(t, le_hist_kind_entry(top.kind, live, 0));
  }
  le_publish_live_image(engine, t, top.slot, id); /* [R1] undo swap */
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
}

/* The Peel motion (#1164), shared by le_engine_peel and the redo of a PEEL
 * marker: removes the LAYER at `idx` (the `skipped` PEEL entries above it
 * shift down one), pushes PEEL{former live, skipped} on top, and publishes
 * the LAYER's slot live on every lane. The stack count is unchanged and every
 * slot stays referenced exactly once (track_select_slot's uniqueness scan).
 * Never allocates or writes PCM: Peel only moves between images that already
 * exist. The target is staged before it is published (#1143) so a running
 * capture replays the swap exactly. Depths and the redo branch are the
 * callers' to settle. */
static void le_peel_apply(le_engine* engine, le_track* t, int idx,
                          int32_t skipped) {
  const int32_t target = t->undo_stack[idx].slot;
  const int32_t live = load_i32(&t->lanes[0].a_live);
  const uint32_t id = le_stage_source_image(
      engine, (int32_t)(t - engine->tracks), target,
      load_i32(&t->lanes[0].a_len));
  for (int k = idx + 1; k < t->undo_count; ++k) {
    t->undo_stack[k - 1] = t->undo_stack[k];
  }
  t->undo_stack[t->undo_count - 1] =
      le_hist_kind_entry(LE_HIST_PEEL, live, skipped);
  le_publish_live_image(engine, t, target, id); /* [R1] peel swap */
}

/* #595: drops every lane's recoverable flag once NOTHING on this track can
 * come back — no live take (len 0), no undo history (which includes a clear
 * restore point: the shadow that keeps a wiped-looking take one undo away),
 * and no redo. Anything short of all three keeps the flags: a stale 1 only
 * declines a lane trim, a wrong 0 lets the trim eat a restorable take (the
 * #594 failure), so every guard errs toward keeping. Called after the history
 * mutations that can only shrink the ways back (redo invalidation, restore-
 * point drops, the plain clear); per-lane granularity comes from the SET side
 * (only writing lanes ever latch), not from here. */
static void le_track_drop_recoverable_if_dead(le_track* t) {
  if (load_i32(&t->lanes[0].a_len) > 0) return;
  if (t->undo_count > 0 || t->redo_count > 0) return;
  /* A frozen take's restore point is still to be filed (LE_EVT_CLEAR_FROZEN):
   * the live slot it will name must stay allocated. */
  if (t->clear_restore_pending) return;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    store_i32(&t->lanes[l].a_recoverable, 0);
  }
}

/* Clears a track's redo history (control thread) — a fresh action (punch-in,
 * new recording, session import) invalidates the resurrect path, including the
 * undone-to-empty length. */
static void le_clear_redo(le_track* t) {
  t->redo_count = 0;
  t->empty_len = 0;
  store_i32(&t->a_redo_depth, 0);
  le_track_drop_recoverable_if_dead(t); /* #595: the resurrect path died */
}


/* Drops a track's clear restore point(s) and the erased take beneath them
 * (control thread). A fresh capture on this track is about to record into the
 * live slot a restore point names (le_begin_empty_capture regrows and the audio
 * thread writes pool[live] in place), so the way back is gone whether or not the
 * bookkeeping admits it — and the layers under the mark belong to the erased
 * take, which the new recording replaces wholesale. Dropping both restores the
 * pre-#219 semantic exactly: after clear-then-record, undo depth is 0. */
static void le_drop_clear_history(le_track* t) {
  /* A frozen take still waiting for its Clear completion
   * is about to be recorded over too: the point can never be filed, and the
   * layers kept beneath it belong to the erased take — they go with it. */
  if (t->clear_restore_pending) {
    t->clear_restore_pending = 0;
    t->undo_count = 0;
    le_publish_undo_depth(t);
    le_track_drop_recoverable_if_dead(t);
    return;
  }
  if (!le_history_is_cleared(t)) return;
  t->undo_count = 0;
  le_publish_undo_depth(t);
  le_track_drop_recoverable_if_dead(t); /* #595: the way back is gone */
}

/* le_effective_state — the track's effective state for control-side decisions
 * — moved to engine_core.h (static inline): the wet-cache scheduler's enqueue
 * gate (engine_cache.c) decides from the same predicate and the two must
 * never diverge. */

/* Commits a completed loop-close restoration (#697 S9) as ONE lockstep undo
 * layer — declared in engine_restore.h, defined HERE so it reuses the undo /
 * pool machinery above (track_acquire_slot, le_clear_redo, le_hist_layer,
 * le_publish_undo_depth, le_track_publish_live) rather than duplicating it.
 * Control thread only; the audio thread is untouched (a_live is swapped by a
 * single release store, and no buffer it can hold is freed — the pre-restore
 * live slot lives on as the pushed undo layer). See the header for the full
 * contract. */
int32_t le_restore_commit_layer(le_engine* engine, int32_t channel,
                                uint32_t lane_mask, uint32_t audio_rev,
                                int32_t len,
                                float* const restored[LE_MAX_LANES]) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return LE_ERR_INVALID;
  }
  le_track* t = &engine->tracks[channel];
  /* The same gate the enqueue used, re-checked at commit: a capture may have
   * started since. */
  const int32_t est = le_effective_state(t);
  if (est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) return LE_ERR_INVALID;
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  /* [B5]: the take must not have moved since the worker copied it. */
  if (atomic_load_explicit(&t->a_audio_rev, memory_order_acquire) != audio_rev) {
    return LE_ERR_INVALID;
  }
  const int32_t live = load_i32(&t->lanes[0].a_live);
  if (len <= 0 || load_i32(&t->lanes[0].a_len) != len) return LE_ERR_INVALID;

  const int32_t lanes = le_lanes_active(t);
  const int32_t slot = track_acquire_slot(t);
  if (slot < 0) return LE_ERR_INVALID; /* pool exhausted beyond eviction */

  /* Fill the fresh slot on every active lane: the restored PCM where opted,
   * else a plain copy of the current live buffer (safe to read on this thread
   * — the gate above proves the audio thread is not writing pool[live]). */
  for (int32_t l = 0; l < lanes; ++l) {
    if (!le_lane_ensure_slot(&t->lanes[l], slot, len)) {
      /* OOM: abandon the commit. track_acquire_slot only returns a free slot
       * (never referenced by a_live / undo / redo / outstanding), so leaving
       * it partially allocated in the pool is harmless — nothing names it. */
      return LE_ERR_INVALID;
    }
    float* dst = t->lanes[l].pool[slot];
    const float* src = t->lanes[l].pool[live];
    if ((lane_mask & (1u << l)) && restored[l] != NULL) {
      memcpy(dst, restored[l], (size_t)len * sizeof(float));
    } else if (src != NULL) {
      memcpy(dst, src, (size_t)len * sizeof(float));
    } else {
      memset(dst, 0, (size_t)len * sizeof(float));
    }
  }

  /* A fresh action invalidates any redo path, exactly like a punch-in. */
  le_clear_redo(t);
  /* Push the pre-restoration live slot as one lockstep undo entry so a plain
   * le_engine_undo swaps the restoration back to the raw take (the retention
   * model the plan specifies: in-session undo, no session-bundle change).
   * Filed as PROCESSED, not LAYER (#1164): a conditioning swap is not an
   * overdub, so Peel must never consume it as one — a full-length raw take
   * swapped under a conditioned image would not be "the newest overdub". */
  if (t->undo_count < LE_POOL_SLOTS) {
    t->undo_stack[t->undo_count++] =
        le_hist_kind_entry(LE_HIST_PROCESSED, live, 0);
  }
  le_publish_undo_depth(t);
  /* Swap a_live to the restored slot on every lane + bump a_audio_rev in one
   * motion (invalidating and re-rendering the wet cache). Image 0 (#1143):
   * processed material has no staged copy, so a running capture's stem fails
   * truthfully at this swap (323/0) instead of replaying the raw take. */
  le_publish_live_image(engine, t, slot, 0);
  return LE_OK;
}

/* Marks a successfully posted state-flip command (control thread). */
static void le_mark_state_cmd(le_track* t, int32_t target) {
  t->state_cmds_posted++;
  t->pending_target = target;
  t->pending_len = 0; /* the posters that restore a length set it after */
  t->pending_master_len = 0;
}

/* Marks a successfully posted command that EMPTIES the track: the state flip
 * plus the publication ticket a later fresh capture needs before it may free,
 * regrow or zero this track's PCM (#1146, le_track.empty_command). Called
 * after the push, so commands_posted already counts that command. */
static void le_mark_empty_cmd(le_engine* engine, le_track* t) {
  le_mark_state_cmd(t, LE_TRACK_EMPTY);
  t->empty_command = engine->commands_posted;
}

/* Tickets a successfully posted command that can empty [channel] on the audio
 * thread WITHOUT a state command of its own: a cancellation that reaches a
 * take inside its launch grace (DISARM, STOP_RECORD_CONTROL, CANCEL_COUNT_IN
 * -> handle_record -> apply_undo_to_empty), or a stop/finish that finalizes a
 * RECORDING take which captured nothing (finalize_new_track's void take ->
 * EMPTY). Unconditional on purpose: the control view cannot tell a void take
 * from a kept one (a RECORD posted in the same block still reads EMPTY here),
 * and a ticket on a track that keeps its content is never consulted — the
 * guard reads it only while the track is EMPTY, and the next emptying
 * re-tickets. Called after the push, so commands_posted counts the command. */
static void le_ticket_emptying(le_engine* engine, int32_t channel) {
  if (channel < 0 || channel >= engine->track_count) return;
  engine->tracks[channel].empty_command = engine->commands_posted;
}

/* DISARM empties a track only through its launch: a take inside its grace
 * (handle_record -> apply_undo_to_empty), or a pending launch the count-in may
 * commit before the DISARM applies. An ordinary arm cancellation empties
 * nothing, and must stay re-armable within the same block. */
/* Whether [t] has a launch a press may only cancel: a Count-in deferral
 * pending, or a committed take inside its cancellation grace. Pending first,
 * then grace, both acquire: le_count_in_commit stores the grace (release)
 * before it clears the pending flag (release), so a clear read here implies
 * the grace store is visible — no instant exists where a cancellable launch
 * reads as neither. Every control-side reader of the pair goes through this
 * one helper so none of them re-introduces the relaxed, unordered read. */
static int le_launch_cancellable(le_track* t) {
  return atomic_load_explicit(&t->a_pending_launch, memory_order_acquire) ||
         atomic_load_explicit(&t->a_launch_grace, memory_order_acquire);
}

static void le_ticket_launch_cancel(le_engine* engine, int32_t channel) {
  if (channel < 0 || channel >= engine->track_count) return;
  if (le_launch_cancellable(&engine->tracks[channel])) {
    le_ticket_emptying(engine, channel);
  }
}

/* The master grid a clear on [t] must record for its restore point: what an
 * in-flight restore on this track is about to re-establish, else the wire's
 * — the grid twin of le_effective_len. */
static int32_t le_effective_master_len(le_engine* engine, le_track* t) {
  if (t->state_cmds_posted >
          atomic_load_explicit(&t->a_state_acks, memory_order_acquire) &&
      t->pending_master_len > 0) {
    return t->pending_master_len;
  }
  return load_i32(&engine->a_master_len);
}

/* The master grid the rig runs once every posted restore has landed: the
 * wire's, or the master a clear point being restored on any track is about to
 * re-establish while the wire still reads none — the rig-wide twin of
 * le_effective_master_len, for a press that must know whether it defines the
 * grid or records over one (a record behind a queued restore of the only
 * take). */
static int32_t le_rig_effective_master_len(le_engine* engine) {
  const int32_t wire = load_i32(&engine->a_master_len);
  if (wire > 0) return wire;
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* o = &engine->tracks[c];
    if (o->state_cmds_posted >
            atomic_load_explicit(&o->a_state_acks, memory_order_acquire) &&
        o->pending_master_len > 0) {
      return o->pending_master_len;
    }
  }
  return 0;
}

/* The control thread's view of a track's length: what a posted-but-unapplied
 * state command will publish (a restore's take length, an emptying's 0), or
 * the published length once everything posted has been acked — the length
 * twin of le_effective_state, so a decision made in the gap (a clear right
 * behind a restore) measures the take it will find. */
static int32_t le_effective_len(le_track* t) {
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return t->pending_len;
  }
  return load_i32(&t->lanes[0].a_len);
}

/* Defined below with the quantize machinery; needed by the undo-to-empty
 * paths so a pending arm can't fire a surprise recording on an emptied track.
 * Returns the DISARM push result (LE_OK when there was no arm to cancel) —
 * the internal callers discard it, le_engine_cancel_arm reports it. */
static int32_t le_cancel_arm(le_engine* engine, int32_t channel);
static int32_t le_post_clock_command(le_engine* engine, int32_t code,
                                       int32_t value);

/* #595: trailing-lane reclaim, defined below but called from the event drain
 * (le_engine_drain_events) as well as the un-route itself. */
static int le_trim_trailing_lanes(le_engine* engine, int32_t channel,
                                   int32_t unrouted_lane);

/* Applies undo taps that were queued while a layer was in flight (control
 * thread, called from the event drain once the flight flag cleared). Each
 * queued tap peels one layer; past the last stacked layer it falls through to
 * the undo-to-empty path exactly like a live tap would. */
static void le_apply_queued_undo(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  while (t->queued_undo > 0) {
    t->queued_undo--;
    if (t->undo_count > 0) {
      le_undo_swap(engine, t);
      continue;
    }
    const int32_t st = le_effective_state(t);
    const int32_t len = load_i32(&t->lanes[0].a_len);
    if ((st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) || len <= 0) break;
    /* Checked BEFORE the command is posted: an undo-to-empty whose resurrect
     * slot did not make it onto the redo stack would empty the track with no
     * way back — worse than declining the tap. */
    if (t->redo_count >= LE_POOL_SLOTS) break;
    if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) break;
    le_cancel_arm(engine, channel);
    (void)le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)));
    t->empty_len = len;
    le_mark_empty_cmd(engine, t);
    le_track_set_len(t, 0); /* coherent snapshot before the audio thread
                             * applies — a poll must never see EMPTY with a
                             * stale nonzero length (mirrors the live-tap and
                             * clear paths) */
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_sync_divisor, 0); /* B3: coherent-snapshot mirror */
    store_i32(&t->a_redo_depth, t->redo_count);
    break; /* empty now — further queued taps are no-ops */
  }
  t->queued_undo = 0;
}

/* Retired-layer persistence (part 5, D-LAYER): copies a retiring layer's PCM
 * into a fresh heap buffer per active lane and hands it to the drain thread
 * via layer_staging_ring — BEFORE any pool-reclaim path (eviction, clear,
 * redo-invalidation) can let the slot's memory be overwritten by a later
 * write. No-op when not armed (checked via the published atomic — this is
 * control-thread code, so e->perf.armed, the audio-thread-local mirror, must
 * not be read here).
 *
 * Called from le_handle_retired UNCONDITIONALLY, before its generation check:
 * a generation mismatch there means "this event predates a clear," but the
 * audio genuinely played and was captured into the pool slot right up until
 * that clear — skipping the copy would silently destroy it, which is exactly
 * the hazard this part exists to close. A dropped copy (OOM, or the staging
 * ring itself full — see LE_LAYER_STAGING_RING_CAPACITY) increments a
 * dedicated overrun atomic rather than corrupting state.
 *
 * KNOWN COST, deliberately left alone by #722: these copies are multi-MB for
 * any real loop, so the malloc here and the matching free on the drain thread
 * are the largest allocator events in the armed path. (They are NOT a
 * per-pass mmap/munmap storm — glibc's mmap threshold is dynamic and rises to
 * the size of the first large chunk freed, so repeated same-size passes come
 * from the arena; see perf_drain.c's header for the measurement that
 * disproved the original claim.) Removing them needs a real design anyway:
 * the sizes are the track's ACTUAL loop length, so a preallocated pool would
 * either pin max_loop_frames per slot (hundreds of MB across LE_MAX_TRACKS *
 * LE_MAX_LANES) or need a size-keyed free-list recycled back across the
 * thread boundary. Neither is in scope here.
 *
 * Returns 1 once the copy is in the staging ring, 0 when nothing was staged
 * (not armed, nothing recorded, or a refusal — which is also counted). */
static int le_stage_retired_layer(le_engine* engine, int32_t channel,
                                  int32_t slot, uint32_t generation,
                                  int32_t restored_len, uint32_t restore_id) {
  /* A queued ARM already owns its worker/ring before callback acknowledgement. */
  if (restore_id ? engine->perf.drain == NULL :
      !atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return 0;
  }
  if (channel < 0 || channel >= engine->track_count) return 0;
  le_track* t = &engine->tracks[channel];
  const int32_t frame_count = restore_id ? restored_len : load_i32(&t->lanes[0].a_len);
  if (frame_count <= 0) return 0; /* nothing recorded into this slot */
  const int32_t lane_count = le_lanes_active(t);

  le_staged_layer entry = {0};
  entry.channel = channel;
  entry.kind = restore_id != 0;
  entry.restore_id = restore_id;
  entry.lane_count = lane_count;
  entry.frame_count = frame_count;
  entry.slot = slot;
  entry.generation = generation;
  entry.frame = atomic_load_explicit(&engine->a_perf_frames,
                                     memory_order_relaxed);

  for (int32_t l = 0; l < lane_count; ++l) {
    const float* src = t->lanes[l].pool[slot];
    if (src == NULL || t->lanes[l].pool_cap[slot] < frame_count) {
      /* Shouldn't happen for an active lane whose track just retired a pass
       * on this slot (le_post_dub_shadows allocates every active lane's
       * buffer before posting it) — fail closed rather than copy garbage. */
      for (int32_t k = 0; k < l; ++k) free(entry.lane_pcm[k]);
      atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                                memory_order_relaxed);
      return 0;
    }
    float* copy = (float*)malloc((size_t)frame_count * sizeof(float));
    if (copy == NULL) {
      for (int32_t k = 0; k < l; ++k) free(entry.lane_pcm[k]);
      atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                                memory_order_relaxed);
      return 0;
    }
    memcpy(copy, src, (size_t)frame_count * sizeof(float));
    entry.lane_pcm[l] = copy;
  }

  if (!le_layer_staging_ring_push(&engine->perf.layer_staging_ring, entry)) {
    for (int32_t l = 0; l < lane_count; ++l) free(entry.lane_pcm[l]);
    atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                              memory_order_relaxed);
    return 0;
  }
  return 1;
}

/* Stages pool slot [slot] of [channel] as a callback-applied source image
 * (#1143, plan section 2.4) and records its id in perf.slot_image. Returns the
 * id, or 0 when nothing was staged: no capture owns a drain (the same gate
 * le_restore_clear used, which includes an ARM still awaiting its callback),
 * the id space is exhausted, or le_stage_retired_layer refused. A 0 entry is
 * what the callback logs as 323/0 when it mixes the slot, so a stem never
 * replays PCM that has no immutable copy. The musical operation itself is
 * never refused here (D5). */
static uint32_t le_stage_source_image(le_engine* engine, int32_t channel,
                                      int32_t slot, int32_t len) {
  if (engine->perf.drain == NULL) return 0;
  uint32_t id = 0;
  if (engine->perf.next_image_id == UINT32_MAX) {
    atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                              memory_order_relaxed);
  } else {
    id = ++engine->perf.next_image_id;
    if (!le_stage_retired_layer(engine, channel, slot, 0, len, id)) id = 0;
  }
  atomic_store_explicit(&engine->perf.slot_image[channel][slot], id,
                        memory_order_relaxed);
  return id;
}

/* Handles one retired-layer event (control thread): returns the slot from the
 * audio thread's hands (`outstanding`) onto the undo stack, right-sizes it, and
 * replenishes the spare while the dub session keeps running. */
static void le_handle_retired(le_engine* engine, const le_command* evt,
                              int replenish) {
  const int32_t ch = evt->evt.channel;
  if (ch < 0 || ch >= engine->track_count) return;
  le_track* t = &engine->tracks[ch];
  le_stage_retired_layer(engine, ch, evt->evt.slot, evt->evt.generation, 0, 0);
  const int frozen_predecessor = t->clear_restore_pending &&
      t->dub_generation == t->clear_restore_generation &&
      evt->evt.generation + 1u == t->clear_restore_generation;
  if (evt->evt.generation != t->dub_generation && !frozen_predecessor) {
    return; /* no current Clear owns this retired era */
  }
  for (int k = 0; k < t->outstanding_count; ++k) {
    if (t->outstanding_slots[k] == evt->evt.slot) {
      t->outstanding_slots[k] = t->outstanding_slots[--t->outstanding_count];
      break;
    }
  }
  /* Right-size a slot that was pre-armed at the recording cap because the loop
   * length was not settled while it was still being recorded (the first wrap's
   * layer, and its spare). The length is settled now and the audio thread has
   * handed the slot back — the retire event IS that hand-off, and the slot is
   * never the live one — so the control thread can shrink it to the same
   * loop-length-quantized size every other layer gets. Without this the cap
   * (30 s by default, up to minutes if the user raised it) would stay pinned
   * per lane for the rest of the session. The retired PCM is preserved: the
   * shrink keeps the leading frames, and the staging copy above already ran.
   * An unsettled length (a fresh capture already re-armed this track) skips the
   * resize rather than risk truncating the layer — leaving it oversized is
   * always safe. */
  const int32_t len = le_track_settled_len(t);
  if (len > 0) {
    const int32_t want = le_layer_slot_frames(engine, len);
    const int32_t lanes = le_lanes_active(t);
    for (int32_t l = 0; l < lanes; ++l) {
      le_lane_shrink_slot(&t->lanes[l], evt->evt.slot, want);
    }
  }
  if (t->undo_count < LE_POOL_SLOTS) {
    t->undo_stack[t->undo_count++] = le_hist_layer(evt->evt.slot);
    le_publish_undo_depth(t);
  }
  if (replenish && load_i32(&t->a_layer_in_flight)) {
    /* the dub continues: keep armed + spare posted */
    le_post_dub_shadows(engine, ch, LE_DUB_SHADOWS);
  }
}

/* LE_CMD_CANCEL_TAKE landed (le_engine_undo while RECORDING): the audio
 * thread finalized the take at [value] frames and emptied the track, keeping
 * the content in the live slot. File that slot as the redo candidate, exactly
 * as the undo-to-empty path does for a completed take — a redo then plays it
 * immediately (LE_CMD_REDO_FROM_EMPTY). A cancelled take that captured
 * nothing (value 0) leaves nothing to redo. */
static void le_handle_take_cancelled(le_engine* engine, const le_command* evt) {
  const int32_t ch = evt->lanei.channel;
  const int32_t len = evt->lanei.value;
  if (ch < 0 || ch >= engine->track_count) return;
  le_track* t = &engine->tracks[ch];
  /* A clear or a fresh capture since the cancel was posted owns the slot
   * now; the late event files nothing. */
  if (!t->cancel_pending) return;
  t->cancel_pending = 0;
  if (len <= 0) return;
  /* The cancel already cleared the redo branch (a fresh take does, at
   * capture start), so the slot goes on an empty stack. */
  if (!le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)))) return;
  t->empty_len = len;
  store_i32(&t->a_redo_depth, t->redo_count);
  for (int32_t l = 0; l < le_lanes_active(t); ++l) {
    store_i32(&t->lanes[l].a_recoverable, 1);
  }
}

static void le_handle_event(le_engine* engine, const le_command* evt,
                            int replenish) {
  switch (evt->code) {
    case LE_EVT_LAYER_RETIRED:
      le_handle_retired(engine, evt, replenish);
      break;
    case LE_EVT_TAKE_CANCELLED:
      le_handle_take_cancelled(engine, evt);
      break;
    default:
      break;
  }
}

/* A latched report is not consumed until the matching control-owned point
 * exists. This includes callback completion between post and finish_clear. */
static void le_collect_clear(le_engine* engine, le_track* t) {
  if (!t->clear_cmd_ack || t->clear_cmd_ack >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) return;
  const uint32_t first = atomic_load_explicit(&t->a_clear_revision, memory_order_seq_cst);
  if (first & 1u) return;
  const uint32_t generation = atomic_load_explicit(&t->a_clear_generation, memory_order_seq_cst);
  const uint32_t bits = atomic_load_explicit(&t->a_clear_fade_amount, memory_order_seq_cst);
  const int32_t len = atomic_load_explicit(&t->a_clear_len, memory_order_seq_cst);
  const int32_t master_len = atomic_load_explicit(&t->a_clear_master_len, memory_order_seq_cst);
#ifdef LE_NATIVE_TESTS
  if (le_test_fade_hook) le_test_fade_hook(engine, 3);
#endif
  const uint32_t last = atomic_load_explicit(&t->a_clear_revision, memory_order_seq_cst);
  if (first != last || generation != t->clear_restore_generation) return;
  float amount;
  memcpy(&amount, &bits, sizeof(amount));
  if (t->clear_restore_pending) {
    /* Readiness follows every preceding layer retirement. A drain before the
     * acquire could miss one, so collect those layers before placing CLEAR. */
    le_command evt;
    while (le_ring_pop(&engine->evt_ring, &evt)) le_handle_event(engine, &evt, 1);
    if (!t->clear_restore_pending || generation != t->clear_restore_generation) return;
    t->clear_restore_pending = 0;
    if (len <= 0) {
      t->undo_count = 0;
      le_publish_undo_depth(t);
      le_track_drop_recoverable_if_dead(t);
      return;
    }
    /* Each layer owns a distinct pool slot, while the live slot is pinned.
     * Thus even the final in-flight retirement leaves one entry for CLEAR. */
    le_hist_entry e = {0};
    e.kind = LE_HIST_CLEAR;
    e.slot = t->clear_restore_slot;
    e.len = len;
    e.master_len = master_len;
    e.multiple = master_len > 0 && len >= master_len ? len / master_len : 1;
    e.state = LE_TRACK_STOPPED;
    e.clear_generation = generation;
    e.fade_amount = amount;
    e.fade_ready = 1;
    t->undo_stack[t->undo_count++] = e;
    le_publish_undo_depth(t);
  } else if (le_history_is_cleared(t)) {
    le_hist_entry* e = &t->undo_stack[t->undo_count - 1];
    if (e->clear_generation == generation && !e->fade_ready) {
      e->fade_amount = amount;
      e->fade_ready = 1;
    }
  }
}

void le_engine_drain_events(le_engine* engine) {
  le_fx_recipe_collect(engine, 0);
  if (engine == NULL) return;
  le_command evt;
  while (le_ring_pop(&engine->evt_ring, &evt)) {
    le_handle_event(engine, &evt, 1);
  }
  /* Queued undo taps apply once their track's flight flag clears. The audio
   * thread pushes the final retire event BEFORE clearing the flag (the push is
   * the release), so after an acquire-load reads 0 one more pop pass is
   * guaranteed to see that event — then the stack is complete and the queued
   * taps peel the layers the user asked for.
   *
   * The same sweep replenishes shadow slots for any in-flight session (armed +
   * spare), and pre-arms ONE for a track that is still RECORDING but bound to
   * run straight into overdub (rec/dub, or a non-defining fixed multiple). The
   * length is not settled mid-capture, so a pre-armed slot is cap-sized
   * (le_post_dub_shadows) — one is all the first wrap needs, and its spare
   * comes from this same sweep's in-flight branch right after finalize, when
   * the slot is loop-length-quantized. Arming BEFORE the finalize->overdub
   * transition is what lets the first wrap's pass back up on write and retire
   * as its own undo layer — instead of running un-backed and merging into the
   * base. A base loop so short it finalizes before this post lands falls back
   * to the merge, the same coherent behaviour as spare starvation. */
  for (int32_t ch = 0; ch < engine->track_count; ++ch) {
    le_track* t = &engine->tracks[ch];
    le_collect_clear(engine, t);
    /* A depth held back while a restore was in flight: publish it now that
     * the audio thread has applied the state (see le_publish_undo_depth). */
    if (t->depth_republish &&
        t->state_cmds_posted <=
            atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
      t->depth_republish = 0;
      le_publish_undo_depth(t);
    }
    /* The punch-out latch lives only for the unapplied window: once the
     * track has actually left OVERDUBBING, a later tap must be free to post
     * its own punch-out again. */
    if (t->dub_punch_out_posted &&
        load_i32(&t->a_state) != LE_TRACK_OVERDUBBING) {
      t->dub_punch_out_posted = 0;
    }
    const int in_flight =
        atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire);
    /* Effective state, not raw a_state: a CLEAR / undo-to-empty pushed but not
     * yet applied means this track is about to be EMPTY — pre-arming it would
     * post a cap-sized slot straight into the clear's path (the same unacked
     * window every control-side decision in this file guards with
     * le_effective_state). */
    const int recording = le_effective_state(t) == LE_TRACK_RECORDING;
    if (in_flight) {
      le_post_dub_shadows(engine, ch, LE_DUB_SHADOWS);
    } else if (recording &&
               le_capture_may_overdub(engine, ch,
                                      load_i32(&engine->a_master_len) > 0)) {
      /* The a_master_len read is safe here BECAUSE effective state said
       * RECORDING: that required acquiring the ack of every pending state
       * command, and handle_clear stores its master reset before its ack's
       * release — so a defining capture behind an internal grid-redefine
       * clear always reads 0, never the dead grid's stale length. */
      le_post_dub_shadows(engine, ch, 1);
    }
    if (t->queued_undo <= 0) continue;
    if (in_flight) continue; /* still capturing/draining: keep waiting */
    while (le_ring_pop(&engine->evt_ring, &evt)) {
      le_handle_event(engine, &evt, 1);
    }
    le_apply_queued_undo(engine, ch);
  }
  /* #595: post-drain trailing-lane reclaim. An un-route latched
   * pending_lane_trim; now that this drain follows the audio thread applying
   * the block's commands, every un-routed lane's routing is published, so one
   * trim pass (unrouted_lane == -1, judging purely by published routing) frees
   * the whole trailing run a burst of un-routes left stranded — the immediate
   * trim in le_engine_set_lane_input could only reclaim the last of the burst.
   * A refused structural admission remains pending for the next drain. */
  for (int32_t ch = 0; ch < engine->track_count; ++ch) {
    if (!engine->tracks[ch].pending_lane_trim) continue;
    engine->tracks[ch].pending_lane_trim =
        !le_trim_trailing_lanes(engine, ch, -1);
  }
  /* Loop-stage wet cache (FX v3 part 2): one scheduler pass per drain —
   * collect finished renders, publish [B5], chunked enqueue copies,
   * debounce + enqueue [B2][B3], enforce the memory cap. No-op until
   * le_cache_init has run.
   *
   * CADENCE CONTRACT: this hook is the cache's ONLY control-thread
   * heartbeat, so cache liveness (renders publishing, cap bytes releasing)
   * requires SOME periodic control-side call into le_engine_drain_events —
   * the app's snapshot poll today, or le_engine_get_lane_cache polling in a
   * headless/test harness. A client that stops calling entirely leaves the
   * cache frozen mid-flight (lanes report RENDERING, bytes stay pinned) —
   * audio is unaffected (live playback continues), but any such client must
   * either keep polling or grow a dedicated pump seam here first. Per-call
   * cost is bounded: the copy step is chunked and every scan is fixed-size
   * with an under-budget early-out. */
  le_cache_tick(engine);
  /* Offline loop-close restoration worker (#697 S9): the same control-thread
   * heartbeat drives its chunked enqueue copy + finished-job collect. No-op
   * until le_restore_init, and until a le_engine_restore_track enqueues a job. */
  le_restore_tick(engine);
}

/* Retained reopen (#1140), control-side half — see engine_core.h. The device
 * is closed and the workers are joined, so every field below is owned here;
 * le_engine_reopen_outcome has already ruled out a pending state command, a
 * pending cancel and a pending Clear mailbox. */
/* Files one complete pre-pass image the audio thread could not hand off as a
 * committed layer, exactly as its retire event would have been. */
static void le_reopen_file_slot(le_engine* engine, int32_t ch, int32_t slot) {
  const le_command synth = {.code = LE_EVT_LAYER_RETIRED,
                            .evt = {ch, slot, engine->tracks[ch].dub_gen_audio}};
  le_handle_retired(engine, &synth, 0);
}

void le_engine_reopen_file_retired(le_engine* engine, uint32_t drop_mask) {
  if (engine == NULL) return;
  le_command evt;
  /* Events the audio thread pushed before the loss: file them as usual, but
   * replenish nothing — a shadow posted now would go into a ring the runtime
   * reset is about to re-initialise. */
  while (le_ring_pop(&engine->evt_ring, &evt)) le_handle_event(engine, &evt, 0);
  for (int32_t ch = 0; ch < engine->track_count; ++ch) {
    le_track* t = &engine->tracks[ch];
    if (drop_mask & (1u << ch)) continue; /* dropped whole by the settle */
    /* A Clear that applied in its last block but whose report was never
     * collected: complete its restore point now, while the mailbox and
     * clear_cmd_ack are intact (the runtime reset zeroes both). */
    le_collect_clear(engine, t);
    /* Complete pre-pass images the audio thread could not hand off yet are
     * committed layers. With the event ring full across two pass boundaries
     * there can be TWO: the older pass parked in dub_retire_slot and the
     * newer one frozen complete in the armed slot (le_dub_boundary returns
     * early while a retire is stuck). File oldest first, so the undo order
     * matches the order the passes were played. The live slot keeps whatever
     * was written un-backed after them (the same merge spare starvation
     * produces). */
    if (t->dub_retire_slot >= 0) {
      le_reopen_file_slot(engine, ch, t->dub_retire_slot);
      t->dub_retire_slot = -1;
    }
    if (t->dub_slot >= 0 && t->dub_len > 0 && t->dub_count >= t->dub_len) {
      le_reopen_file_slot(engine, ch, t->dub_slot);
      t->dub_slot = -1;
    }
    /* The dub session ends with the device: posted-but-unarmed shadows return
     * to the pool, an undo tap queued behind the in-flight layer is dropped
     * with the pass it waited on, and the punch-out latch has nothing left
     * to guard. */
    t->outstanding_count = 0;
    t->queued_undo = 0;
    t->dub_punch_out_posted = 0;
    t->depth_republish = 0;
    t->pending_lane_trim = 0;
    le_publish_undo_depth(t);
  }
}

/* Zeroes every active lane's live buffer (control thread) before a fresh capture
 * over an existing master, so any unrecorded tail of a rounded-up multi-loop
 * length plays as silence. The track is EMPTY, so the audio thread is not
 * reading it. (Defining recordings — no master yet — use record_pos bounds and
 * need none.) */
static void le_prepare_new_capture(le_engine* engine, le_track* t) {
  const size_t n = (size_t)engine->max_loop_frames; /* mono */
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &t->lanes[l];
    const int live = load_i32(&ln->a_live);
    /* A recording target must hold the full cap: undo may have swapped a
     * loop-length-quantized snapshot slot into a_live. Grow-only-if-allocated:
     * a never-used lane stays lazily NULL (the audio thread's null guard
     * plays/records it as silence, unchanged). The track is EMPTY, so the
     * audio thread never dereferences the slot while it regrows. */
    if (ln->pool[live] == NULL) continue;
    if (!le_lane_ensure_slot(ln, live, engine->max_loop_frames)) continue;
    memset(ln->pool[live], 0, n * sizeof(float));
  }
}

/* The effective quantize state for [channel]: its per-track override, or the
 * global default when the track inherits (override < 0). */
static int le_effective_quantize(le_engine* engine, int32_t channel) {
  const le_record_timing_readback timing = le_record_timing_read(engine, 0);
  const int code = timing.track_timing[channel];
  return (code < 0 ? timing.default_timing : code) != 0;
}

/* Cancels a pending quantized arm (control thread): disarms and tells the
 * audio thread to clear the pending flag. Arming creates no undo layer (layers
 * are captured per pass once the overdub actually runs), so there is nothing
 * to reverse. No-op when the track is not armed. */
static int32_t le_cancel_arm(le_engine* engine, int32_t channel) {
  if (!engine->armed[channel]) return LE_OK; /* nothing to cancel */
  engine->armed[channel] = 0;
  /* The push can fail — a full ring (stalled audio callbacks on a lost
   * device) or an unconfigured engine — which leaves a_pending set on the
   * audio thread even though control now reads unarmed. The internal callers
   * are void and have always discarded this; returning it is what lets the
   * public le_engine_cancel_arm tell its caller the arm may still fire. */
  const int32_t rc = le_push(engine, LE_CMD_DISARM, channel, 0.0f);
  if (rc == LE_OK) le_ticket_launch_cancel(engine, channel);
  return rc;
}

/* Whether any track is driving the loop clock (playing or capturing). A
 * quantized action can only fire at a loop top if the transport is actually
 * ticking — with everything parked or empty the clock is HELD at the top
 * (advance_transport_frame's idle branch), so a deferred action would wait
 * forever. Callers act immediately instead: the held position IS the top. */
static int le_transport_active(le_engine* engine) {
  for (int32_t c = 0; c < engine->track_count; ++c) {
    const int32_t st = le_effective_state(&engine->tracks[c]);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_RECORDING ||
        st == LE_TRACK_OVERDUBBING) {
      return 1;
    }
  }
  return 0;
}

/* Whether the kept master grid is still needed by any track OTHER than
 * [channel]: content (or a pending length), an undo history, or an
 * undone-to-empty redo history that would resurrect onto that grid. When
 * nothing needs it, a fresh recording is free to redefine the tempo. */
static int le_grid_still_needed(le_engine* engine, int32_t channel) {
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* o = &engine->tracks[c];
    if (c == channel) continue;
    if (le_effective_state(o) != LE_TRACK_EMPTY) return 1;
    if (load_i32(&o->lanes[0].a_len) > 0) return 1;
    /* A cleared sibling's history does NOT hold the grid: its restore point
     * yields to this fresh recording (le_drop_clear_history runs when the take
     * starts), exactly as the pre-#219 clear — which reset the stack outright —
     * left nothing here to find. Counting it would lock the new loop to the
     * dead tempo, the very ghost-grid bug this function exists to prevent. */
    if (le_history_is_cleared(o)) continue;
    if (o->undo_count > 0 || o->redo_count > 0 || o->empty_len > 0) return 1;
  }
  return 0;
}

/* One-time bookkeeping for a capture starting (or arming) on an EMPTY track
 * (control thread): a fresh take invalidates redo history (including the
 * undone-to-empty resurrect length), cancels queued undo taps, and unmutes
 * every active lane so the new recording is always audible — a Stop-muted or
 * cleared track never records into silence. The mute commands ride the ring so
 * they order before the record/arm command that follows.
 *
 * NO shadow slots are posted here: the loop length is unknown until finalize,
 * so a slot allocated now would have to be recording-cap-sized — defeating the
 * loop-length quantization. Instead the capture start DROPS any leftover armed
 * slots audio-side (handle_record's EMPTY case; they may be sized for a
 * previous, shorter loop) and `outstanding` is reclaimed here — safe because
 * an EMPTY track can have no layer in flight, hence no retire events to
 * mis-attribute, and nothing re-posts this track's slots until content exists.
 * A capture that runs straight into overdub (rec/dub, fixed multiple) instead
 * gets cap-sized slots pre-armed after the RECORD command (le_engine_record) or
 * by the RECORDING branch of le_engine_drain_events, so they are in hand at the
 * finalize->overdub transition and the first wrap's pass backs up on write as
 * its own undo layer. Only if the loop finalizes before that post lands does
 * the first pass go un-backed and merge into the next boundary — coherent,
 * never torn, the spare-starvation fallback. */
static void le_begin_empty_capture(le_engine* engine, int32_t channel, int defer_mix) {
  le_track* t = &engine->tracks[channel];
  le_clear_redo(t);
  /* Same invalidation, one level up: a fresh take also kills any way back to a
   * cleared one, because the loop below regrows pool[live] and the audio thread
   * then records into that very slot — the one a restore point names. */
  le_drop_clear_history(t);
  t->queued_undo = 0;
  t->cancel_pending = 0; /* a new take supersedes a cancelled one's redo */
  /* #1143: the regrow below, le_prepare_new_capture's zero and the recording
   * itself rewrite pool slots whose content an earlier admission may have
   * staged; the next slot this track makes live is a fresh take. */
  le_forget_slot_images(engine, channel);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    /* A fresh capture can grow to the recording cap, but undo may have left a
     * loop-length-quantized snapshot slot live — regrow it first
     * (grow-only-if-allocated: never-used lanes stay lazily NULL). Safe here:
     * the track is (effectively) EMPTY, so the audio thread reads the pointer
     * but never dereferences it, and the RECORD/ARM command that changes that
     * is only pushed after this returns (ring FIFO). Same pattern as
     * le_engine_set_lane_count's live-lane allocation. */
    le_lane* ln = &t->lanes[l];
    const int live = load_i32(&ln->a_live);
    if (ln->pool[live] != NULL) {
      le_lane_ensure_slot(ln, live, engine->max_loop_frames);
    }
    if (!defer_mix) le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                     .lanef = {channel, l, 0.0f}});
  }
  t->outstanding_count = 0; /* reclaim; audio drops its armed slots at start */
}

/* One-time bookkeeping for an overdub punch-in (or arm) over existing content
 * (control thread): invalidates redo, cancels queued undo taps, and supplies
 * the audio thread's shadow slots for per-pass layer capture. No snapshot is
 * copied here — the first pass's backup-on-write captures the pre-dub content
 * incrementally on the audio thread. */
static void le_begin_punch_in(le_engine* engine, int32_t channel, int defer_shadows) {
  le_track* t = &engine->tracks[channel];
  /* Part 5 (D-LAYER): le_clear_redo below discards redo_stack's slot
   * references — the redo-invalidation hazard (undo, then a fresh punch-in)
   * the plan calls out by name. The caller (le_engine_record) already drained
   * once at its own top, but a previous dub session's tail can still be
   * draining/retiring asynchronously (a_layer_in_flight can outlive the
   * state's return to PLAYING/STOPPED, which is this function's own
   * precondition) — so a fresh retire event could have landed in evt_ring in
   * the interim. Draining again here, immediately before the discard,
   * shrinks that window from "however long since the last poll" to the
   * handful of instructions in between (it can't be fully closed without
   * blocking on the audio thread, which this control-thread-only fix
   * deliberately does not do — see le_stage_retired_layer, which persists
   * the event's PCM regardless of by the time it IS drained). */
  if (!defer_shadows) le_engine_drain_events(engine);
  le_clear_redo(t);
  t->queued_undo = 0;
  if (!defer_shadows) le_post_dub_shadows(engine, channel, LE_DUB_SHADOWS);
}

/* Sole producer: the consumer can only increase available capacity. Checking
 * before preparation reserves this bounded sequence without a lock or a
 * callback-side allocation. Ring indices are monotonic, not masked offsets. */
static int le_record_capacity(le_engine* e, size_t required) {
  const size_t tail = atomic_load_explicit(&e->ring.tail, memory_order_relaxed);
  const size_t head = atomic_load_explicit(&e->ring.head, memory_order_acquire);
  return required <= e->ring.capacity - 1 - (tail - head);
}

/* Prepare the first shadow of a fresh capture, including a deferred arm. Both the live
 * recording buffer and this shadow must fit the unknown final loop length.
 * Allocate detached replacements first: refusal cannot destroy a redo/clear
 * restore point, or leave one lane of a stereo capture prepared alone. */
static int le_prepare_image_capture(le_engine* e, int32_t channel) {
  le_track* t = &e->tracks[channel];
  const int live = load_i32(&t->lanes[0].a_live);
  /* Live and outstanding slots are excluded; history is not — the same
   * selection le_record_impl previewed before admitting this preparation. */
  int evict;
  const int shadow = track_select_slot(t, 0, 0, t->outstanding_count, &evict);
  if (shadow < 0) return -1;
  const int slots[2] = {live, shadow};
  const int lanes = le_lanes_active(t);
  float* allocated[2][LE_MAX_LANES] = {{0}};
  for (int n = 0; n < 2; ++n) {
    for (int l = 0; l < lanes; ++l) {
      const le_lane* ln = &t->lanes[l];
      const int slot = slots[n];
      if ((n == 0 && ln->pool[slot] == NULL) ||
          (ln->pool[slot] && ln->pool_cap[slot] >= e->max_loop_frames))
        continue;
      allocated[n][l] = (float*)calloc((size_t)e->max_loop_frames, sizeof(float));
      if (!allocated[n][l]) goto refused;
    }
  }
  for (int n = 0; n < 2; ++n) {
    for (int l = 0; l < lanes; ++l) {
      if (!allocated[n][l]) continue;
      le_lane* ln = &t->lanes[l];
      free(ln->pool[slots[n]]);
      ln->pool[slots[n]] = allocated[n][l];
      ln->pool_cap[slots[n]] = e->max_loop_frames;
    }
  }
  return shadow;

refused:
  for (int n = 0; n < 2; ++n)
    for (int l = 0; l < lanes; ++l) free(allocated[n][l]);
  return -1;
}

/* Prepare every initial punch-in shadow before publishing RECORD/ARM. No
 * history is discarded and no pool buffer is replaced until both the complete
 * command sequence and every required allocation can succeed. After this
 * returns success the caller must post exactly its reserved record command;
 * it must not drain events or enqueue unrelated commands in between. */
static int le_prepare_image_punch_in(le_engine* e, int32_t channel) {
  le_track* t = &e->tracks[channel];
  const int missing = t->outstanding_count < LE_DUB_SHADOWS
      ? LE_DUB_SHADOWS - t->outstanding_count : 0;
  if (!le_record_capacity(e, (size_t)missing + 1)) return 0;
  const int lanes = le_lanes_active(t);
  const int want = le_layer_slot_frames(e, le_track_settled_len(t));
  unsigned char used[LE_POOL_SLOTS] = {0};
  used[load_i32(&t->lanes[0].a_live)] = 2;
  for (int i = 0; i < t->outstanding_count; ++i)
    used[t->outstanding_slots[i]] = 2;
  for (int i = 0; i < t->undo_count; ++i)
    if (!used[t->undo_stack[i].slot]) used[t->undo_stack[i].slot] = 1;
  /* Redo slots are available at successful punch-in, but their original
   * contents remain untouched if preparation fails. Prefer these/free slots
   * to evicting undo. Select an oldest layer only when the pool is full. */
  int slots[LE_DUB_SHADOWS];
  float* allocated[LE_DUB_SHADOWS][LE_MAX_LANES] = {{0}};
  for (int n = 0; n < missing; ++n) {
    int slot = -1;
    for (int i = 0; i < LE_POOL_SLOTS; ++i)
      if (!used[i]) { slot = i; break; }
    if (slot < 0) {
      for (int i = 0; i < t->undo_count; ++i) {
        const le_hist_entry entry = t->undo_stack[i];
        if (used[entry.slot] == 1 && entry.kind != LE_HIST_CLEAR) {
          slot = entry.slot;
          break;
        }
      }
    }
    if (slot < 0) goto refused;
    slots[n] = slot;
    used[slot] = 2;
    for (int l = 0; l < lanes; ++l) {
      const le_lane* ln = &t->lanes[l];
      if (ln->pool[slot] != NULL && ln->pool_cap[slot] >= want) continue;
      allocated[n][l] = (float*)calloc((size_t)want, sizeof(float));
      if (!allocated[n][l]) goto refused;
    }
  }
  le_clear_redo(t);
  t->queued_undo = 0;
  for (int n = 0; n < missing; ++n) {
    const int slot = slots[n];
    for (int i = 0; i < t->undo_count; ++i) {
      if (t->undo_stack[i].slot != slot) continue;
      for (int k = i + 1; k < t->undo_count; ++k)
        t->undo_stack[k - 1] = t->undo_stack[k];
      t->undo_count--;
      break;
    }
    for (int l = 0; l < lanes; ++l) {
      if (!allocated[n][l]) continue;
      le_lane* ln = &t->lanes[l];
      free(ln->pool[slot]);
      ln->pool[slot] = allocated[n][l];
      ln->pool_cap[slot] = want;
    }
    /* Capacity for ALL shadows plus the final action was proven before any
     * mutation. Shadows precede capture, even if the callback drains now. */
    t->outstanding_slots[t->outstanding_count++] = slot;
    (void)le_push_cmd(e, (le_command){.code = LE_CMD_DUB_SHADOW,
                                    .lanei = {channel, 0, slot}});
  }
  le_publish_undo_depth(t);
  return 1;

refused:
  for (int n = 0; n < LE_DUB_SHADOWS; ++n)
    for (int l = 0; l < lanes; ++l) free(allocated[n][l]);
  return 0;
}

static int le_mix_float(float value, float min, float max) {
  return isfinite(value) && value >= min && value <= max;
}

int le_mix_valid(const le_engine* e, const le_mix_settings* mix) {
  if (!e || !mix || mix->revision == 0) return 0;
  const uint32_t outputs = (1u << LE_MAX_OUTPUT_BUSES) - 1u;
  if ((mix->output_mask & ~outputs) ||
      ((mix->output_muted | mix->output_mono) & ~mix->output_mask)) return 0;
  for (int i = 0; i < LE_MAX_OUTPUT_BUSES; ++i) {
    if ((mix->output_mask & (1u << i)) &&
        (!le_mix_float(mix->output_level[i], 0, 1) ||
         !le_mix_float(mix->output_balance[i], -1, 1))) return 0;
  }
  const uint32_t tracks = (1u << e->track_count) - 1u;
  if (mix->track_gain_mask & ~tracks) return 0;
  for (int ch = 0; ch < e->track_count; ++ch)
    if ((mix->track_gain_mask & (1u << ch)) &&
        !le_mix_float(mix->track_gain[ch], 0, LE_MAX_GAIN)) return 0;
  if ((mix->lane_count_mask | mix->source_track_mask) & ~tracks) return 0;
  for (int ch = 0; ch < e->track_count; ++ch) {
    if (!(mix->lane_count_mask & (1u << ch))) continue;
    const int count = mix->lane_count[ch];
    if (count < 1 || count > LE_MAX_LANES) return 0;
    for (int l = count; l < le_lanes_active(&e->tracks[ch]); ++l)
      if (atomic_load_explicit(&e->tracks[ch].lanes[l].a_recoverable,
                               memory_order_acquire)) return 0;
  }
  if ((mix->solo_mask & ~tracks) || (mix->solo_values & ~mix->solo_mask)) return 0;
  for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES; ++i) {
    const uint64_t bit = UINT64_C(1) << i;
    if ((mix->routing_input_mask & bit) &&
        (mix->lane_input[i] < -1 || mix->lane_input[i] >= LE_MAX_CHANNELS)) return 0;
    if (((mix->lane_mask | mix->image_mask | mix->routing_input_mask |
          mix->routing_output_mask) & bit) &&
        i / LE_MAX_LANES >= e->track_count) return 0;
    if ((mix->lane_mask & bit) &&
        (!le_mix_float(mix->lane_gain[i], 0, LE_MAX_GAIN) ||
         !le_mix_float(mix->lane_pan[i], -1, 1))) return 0;
    if ((mix->image_mask & bit) &&
        (!le_mix_float(mix->image_gain[i], 0, 1) ||
         !le_mix_float(mix->image_pan[i], -1, 1))) return 0;
  }
  for (int i = 0; i < LE_MAX_CHANNELS; ++i) {
    if ((mix->monitor_mask & (1u << i)) &&
        (!le_mix_float(mix->monitor_gain[i], 0, LE_MAX_GAIN) ||
         !le_mix_float(mix->monitor_pan[i], -1, 1))) return 0;
    if ((mix->trim_mask & (1u << i)) &&
        !le_mix_float(mix->input_trim[i], 0, LE_MAX_INPUT_TRIM)) return 0;
  }
  return 1;
}

int le_image_valid(const le_engine* e, int32_t channel,
                   const le_record_image* image) {
  if (!e || !image || (image->fx_lane_mask >> LE_MAX_LANES) ||
      (image->fx_lane_mask && !image->lane_fx) || image->revision == 0 || channel < 0 ||
      channel >= e->track_count || (image->lane_mask >> LE_MAX_LANES)) return 0;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    if ((image->lane_mask & (1u << l)) &&
        (!le_mix_float(image->gain[l], 0, 1) ||
         !le_mix_float(image->pan[l], -1, 1))) return 0;
  }
  return 1;
}

static int le_prepare_routing(le_engine* e, const le_mix_settings* mix) {
  if (mix->lane_count_mask) {
    /* The prior callback must finish every buffer access before preparation
     * can touch an inactive lane again. Reuse the existing publication ack;
     * unrelated startup commands do not block this allocation. */
    if (e->lane_growth_command > atomic_load_explicit(
          &e->a_commands_published, memory_order_acquire)) return LE_ERR_INVALID;
    for (int ch = 0; ch < e->track_count; ++ch) {
      if (!(mix->lane_count_mask & (1u << ch))) continue;
      le_track* t = &e->tracks[ch];
      const int st = le_effective_state(t);
      if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
          load_i32(&t->a_pending) || load_i32(&t->a_pending_launch) ||
          load_i32(&t->a_layer_in_flight)) return LE_ERR_INVALID;
      const int old_count = le_lanes_active(t);
      if (mix->lane_count[ch] > old_count)
        le_cache_evict_lanes(e, ch, old_count, mix->lane_count[ch]);
      for (int l = old_count; l < mix->lane_count[ch]; ++l) {
        le_lane* ln = &t->lanes[l];
        const int live = load_i32(&ln->a_live);
        if (!le_lane_ensure_slot(ln, live, e->max_loop_frames)) return LE_ERR_INVALID;
        if (!load_i32(&ln->a_recoverable))
          memset(ln->pool[live], 0, (size_t)e->max_loop_frames * sizeof(float));
      }
    }
  }
  return LE_OK;
}

int32_t le_engine_set_mix(le_engine* e, const le_mix_settings* mix) {
  if (!le_mix_valid(e, mix)) return LE_ERR_INVALID;
  const int prepared = le_prepare_routing(e, mix);
  if (prepared != LE_OK) return prepared;
  const int32_t rc = le_push_cmd(e, (le_command){.code = LE_CMD_SET_MIX, .mix = *mix});
  if (rc == LE_OK && mix->lane_count_mask) e->lane_growth_command = e->commands_posted;
  return rc;
}

static void le_prepare_clear(le_track* t, int freeze) {
  /* Arm the report before any drain can consume it. The callback may already
   * have applied CLEAR after the push, but only this control thread drains
   * its report. Every accepted clear supersedes an older pending recovery. */
  t->clear_restore_pending = freeze;
  t->clear_restore_slot = freeze ? load_i32(&t->lanes[0].a_live) : -1;
  t->clear_restore_generation = t->dub_generation + 1;
  t->clear_cmd_ack = t->state_cmds_posted + 1;
  t->dub_punch_out_posted = 0;
  t->depth_republish = 0;
  t->queued_undo = 0;
  t->cancel_pending = 0;
}

static void le_finish_clear(le_engine* engine, int32_t channel, int freeze,
                            const le_hist_entry* restore) {
  le_track* t = &engine->tracks[channel];
  /* An undoable clear keeps the stack and pushes the restore point ON TOP of it:
   * the erased take's layers stay put beneath, which is what makes them peelable
   * again once the restore point is undone. A plain clear drops the lot.
   *
   * Either way the redo branch dies (le_clear_redo): a clear is a fresh action,
   * and standard undo semantics discard the redo path at one. That also keeps
   * the two stacks unambiguous — the restore point owns the redo slot from here,
   * so it cannot collide with a pre-clear redo layer. */
  if (restore) {
    t->undo_stack[t->undo_count++] = *restore;
  } else if (!freeze) {
    t->undo_count = 0;
  }
  /* A frozen point was armed before the drain. Keep its completed layers
   * and any point that already arrived; do not mark it pending again. */
  le_clear_redo(t);
  le_publish_undo_depth(t);
  /* Reclaim every shadow slot the audio thread holds: it drops them when the
   * CLEAR applies, and any later re-post travels the command ring behind that
   * CLEAR, so a reclaimed slot can never be armed twice. The generation bump
   * makes any still-in-ring retire event from before the clear stale. */
  t->outstanding_count = 0;
  t->dub_generation++;
  le_mark_empty_cmd(engine, t);
  t->clear_cmd_ack = t->state_cmds_posted;
  /* Coherent snapshot before the audio thread applies — except for a frozen
   * capture, whose published length is what handle_clear reports back for
   * the restore point (the state it publishes is still the capture's until
   * the clear lands, so a poll never sees EMPTY with a length). */
  if (!freeze) le_track_set_len(t, 0);
  /* #595: after the length publish, not before — a plain clear (no restore
   * point kept) leaves len 0 / undo 0 / redo 0, and only then may the lanes'
   * recoverable flags drop. An undoable clear keeps its restore point on the
   * undo stack, so the helper keeps the flags — the erased take is still one
   * undo away. */
  le_track_drop_recoverable_if_dead(t);
  engine->armed[channel] = 0;
}

static int32_t le_post_record_image(le_engine* e, int32_t channel,
                                     int32_t action, float trigger,
                                     int clocked, const le_record_image* image,
                                     int fresh_shadow, int clear_first) {
  if (!image) return clocked ? le_post_clock_command(e, action, channel)
                            : le_push(e, action, channel, trigger);
  uint32_t sequence = clocked ? e->clock_commands_posted + 1 : 0;
  if (clocked && sequence == 0) sequence = 1;
  const le_command command = {
      .code = LE_CMD_RECORD_IMAGE,
      .record_image = {channel, sequence, action, trigger, *image, e->record_fx_prepared}};
  le_command owned_command = command;
  owned_command.record_image.image.lane_fx = NULL;
  owned_command.record_image.image.fx_lane_mask = 0;
  int32_t result;
  if (fresh_shadow >= 0 || clear_first) {
    /* The entire bounded sequence was admitted before preparation, and no
     * intervening helper may enqueue. Publish optional CLEAR, RECORD/ARM and
     * its optional fresh shadow with one tail release: the callback cannot
     * start a capture while only RECORD is visible. The shadow follows RECORD
     * because a fresh start drops the previous take's armed slots. Match
     * le_push_cmd's settlement accounting for every consumed command. */
    const size_t tail = atomic_load_explicit(&e->ring.tail, memory_order_relaxed);
    size_t count = 0;
    if (clear_first) {
      e->ring.buffer[(tail + count++) & e->ring.mask] = (le_command){
          .code = LE_CMD_CLEAR, .arg_i = channel};
    }
    e->ring.buffer[(tail + count++) & e->ring.mask] = owned_command;
#ifdef LE_NATIVE_TESTS
    extern void le_test_record_image_staged(le_engine* engine);
    le_test_record_image_staged(e);
#endif
    if (fresh_shadow >= 0) {
      e->ring.buffer[(tail + count++) & e->ring.mask] = (le_command){
          .code = LE_CMD_DUB_SHADOW, .lanei = {channel, 0, fresh_shadow}};
      le_track* t = &e->tracks[channel];
      t->outstanding_slots[t->outstanding_count++] = fresh_shadow;
    }
    e->commands_posted += (uint32_t)count;
    /* The batched CLEAR was marked before it was counted: ticket the batch. */
    if (clear_first) e->tracks[channel].empty_command = e->commands_posted;
    atomic_store_explicit(&e->ring.tail, tail + count, memory_order_release);
    result = LE_OK;
  } else {
    result = le_push_cmd(e, owned_command);
  }
  if (result == LE_OK && clocked) e->clock_commands_posted = sequence;
  return result;
}

typedef enum le_record_admission {
  LE_RECORD_ACQUIRE, LE_RECORD_FINISH, LE_RECORD_CANCEL, LE_RECORD_REFUSE
} le_record_admission;

/* Pure classification before either entrypoint may prepare capture resources. */
static le_record_admission le_classify_record(le_engine* e, int channel) {
  le_track* t = &e->tracks[channel];
  const int state = le_effective_state(t);
  if (le_launch_cancellable(t)) return LE_RECORD_CANCEL;
  if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) return LE_RECORD_FINISH;
  if (e->armed[channel] && load_i32(&t->a_pending) &&
      e->record_timing_command > atomic_load_explicit(&e->a_commands_published, memory_order_acquire)) {
    const int trigger = e->armed_trigger[channel];
    if (trigger == 0 || (trigger == 1 && (load_i32(&e->a_record_start) < 0))) return LE_RECORD_CANCEL;
    return LE_RECORD_REFUSE;
  }
  const int has_master = le_rig_effective_master_len(e) > 0 &&
      !(state == LE_TRACK_EMPTY && !le_grid_still_needed(e, channel));
  const int sound = (load_i32(&e->a_record_start) < 0) && state == LE_TRACK_EMPTY &&
      !(load_i32(&e->a_record_start) > 0 && !has_master);
  const int quantized = (le_effective_quantize(e, channel) ||
      (state == LE_TRACK_EMPTY && le_sync_quantize_active(e, channel))) &&
      has_master && le_transport_active(e);
  if (e->armed[channel] && load_i32(&t->a_pending)) {
    const int trigger = e->armed_trigger[channel];
    if ((sound && trigger == 1) || (!sound && quantized && trigger == 0)) return LE_RECORD_CANCEL;
    if (trigger == 2 || sound || quantized) return LE_RECORD_REFUSE;
  }
  return LE_RECORD_ACQUIRE;
}

static int32_t le_record_preflight(le_engine* e, int channel,
                                    const le_record_image* image) {
  if (!e) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (channel < 0 || channel >= e->track_count ||
      (image && !le_image_valid(e, channel, image))) return LE_ERR_INVALID;
  le_engine_drain_events(e);
  const le_record_admission kind = le_classify_record(e, channel);
  if (kind == LE_RECORD_REFUSE) return LE_ERR_INVALID;
  if (kind == LE_RECORD_ACQUIRE && e->record_start_command >
      atomic_load_explicit(&e->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  if (kind == LE_RECORD_ACQUIRE && load_i32(&e->a_record_start) < 0 &&
      le_effective_state(&e->tracks[channel]) == LE_TRACK_EMPTY) {
    if (e->input_routing_command > atomic_load_explicit(
        &e->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
    const uint32_t excluded = atomic_load_explicit(&e->a_excluded_input_mask, memory_order_relaxed);
    int source = 0;
    for (int l = 0; l < le_lanes_active(&e->tracks[channel]); ++l) {
      const int input = load_i32(&e->tracks[channel].lanes[l].a_input_channel);
      if (input >= 0 && input < e->in_channels && input < 32 &&
          !(excluded & (1u << input))) source = 1;
    }
    if (!source) return LE_ERR_INVALID;
  }
  if (kind == LE_RECORD_ACQUIRE && e->record_timing_command != 0 &&
      e->record_timing_command > atomic_load_explicit(
          &e->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  return LE_OK;
}

/* Whether preparing a fresh capture on effectively-EMPTY [t] would free, regrow
 * or zero PCM that already exists in its pool: an allocated live buffer below
 * the recording cap on any active lane (le_begin_empty_capture and
 * le_prepare_image_capture replace it), any allocated live buffer when the
 * capture `zero`es it (le_prepare_new_capture), or an allocated `shadow`
 * candidate below the `shadow_frames` this action will supply it at. A NULL
 * buffer is left lazy and a sufficient one is kept, so neither counts. */
static int le_capture_prep_touches_pcm(const le_engine* e, le_track* t, int zero,
                                       int shadow, int32_t shadow_frames) {
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    const le_lane* ln = &t->lanes[l];
    const int live = load_i32(&t->lanes[l].a_live);
    if (ln->pool[live] != NULL &&
        (zero || ln->pool_cap[live] < e->max_loop_frames)) return 1;
    if (shadow >= 0 && ln->pool[shadow] != NULL &&
        ln->pool_cap[shadow] < shadow_frames) return 1;
  }
  return 0;
}

static int32_t le_record_impl(le_engine* engine, int32_t channel,
                                const le_record_image* image) {
  const int32_t admission = le_record_preflight(engine, channel, image);
  if (admission != LE_OK) return admission;
  if (le_launch_cancellable(&engine->tracks[channel])) {
    /* Keep cancellation intent even if an earlier pair command removes the
     * countdown before this command drains. Never reinterpret it as acquire. */
    uint32_t sequence = engine->clock_commands_posted + 1u;
    if (sequence == 0) sequence = 1;
    const int result = le_push_cmd(engine, (le_command){.code = LE_CMD_RECORD,
        .clock = {channel, sequence, 1}});
    if (result == LE_OK) {
      engine->clock_commands_posted = sequence;
      /* Within its grace a launched take is emptied by this press
       * (handle_record), with no state command to ticket it: ticket it here. */
      engine->tracks[channel].empty_command = engine->commands_posted;
    }
    return result;
  }
  if (engine->armed[channel] && load_i32(&engine->tracks[channel].a_pending) &&
      engine->record_timing_command > atomic_load_explicit(&engine->a_commands_published, memory_order_acquire) &&
      le_classify_record(engine, channel) == LE_RECORD_CANCEL) {
    return le_cancel_arm(engine, channel);
  }
  /* Sole producer: the callback can only free space. Refuse before capture
   * preparation if the action cannot fit. Internal grid-clear may need a
   * second slot; its exact need is checked below before any history edits. */
  if (image && !le_record_capacity(engine, 1)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  /* Overdub is unavailable while Reverse is on (#1162, the RC-300/RC-505
   * rule): a punch-in on a track that reads — or will read, once its posted
   * toggles land — reversed is refused before any preparation. Presses that
   * finish a capture or cancel an arm or launch are not punch-ins and pass. */
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) &&
      le_effective_reversed(t) &&
      !(engine->armed[channel] && load_i32(&t->a_pending)) &&
      !load_i32(&t->a_pending_launch)) {
    return LE_ERR_REVERSED;
  }
  /* Capture is unavailable while Speed is not 1x (#1179): a record or
   * punch-in that would start now, or once the posted Speed requests land,
   * is refused before any preparation. Finishing a capture or cancelling an
   * arm or launch is not a capture start and passes. */
  if ((st == LE_TRACK_EMPTY || st == LE_TRACK_PLAYING ||
       st == LE_TRACK_STOPPED) &&
      !le_effective_speed_one(engine) &&
      !(engine->armed[channel] && load_i32(&t->a_pending)) &&
      !load_i32(&t->a_pending_launch)) {
    return LE_ERR_TRANSFORMED;
  }
  /* The track's length (k * base) — all lanes share it, so lane 0 is canonical.
   * Kept coherent with the effective state: the undo-to-empty / redo-from-empty
   * paths store it control-side when they post. */
  const int32_t len = load_i32(&t->lanes[0].a_len);
  /* Measured behind any queued restore: a press that lands while the only
   * take is on its way back records over that take's grid, not a fresh one. */
  int has_master = le_rig_effective_master_len(engine) > 0;
  const int redefine_grid = st == LE_TRACK_EMPTY &&
      !le_grid_still_needed(engine, channel);
  const int capture_has_master = has_master && !redefine_grid;
  const int sound_arm = (load_i32(&engine->a_record_start) < 0) && st == LE_TRACK_EMPTY &&
      !(load_i32(&engine->a_record_start) > 0 && !capture_has_master);
  const int sync_force_arm =
      st == LE_TRACK_EMPTY && le_sync_quantize_active(engine, channel);
  const int quantized_arm =
      (le_effective_quantize(engine, channel) || sync_force_arm) &&
      capture_has_master && le_transport_active(engine);
  /* Preparing a new capture while a structural command is unpublished
   * would allocate shadows for the old lane count. The callback could then
   * activate more lanes before RECORD, making their first Undo lose audio.
   * Existing captures can still finish/punch out. Published owned arms and
   * addressed stopped launches can still cancel, without preparing any new image,
   * buffer, shadow or history mutation. */
  if (engine->lane_growth_command > atomic_load_explicit(
          &engine->a_commands_published, memory_order_acquire) &&
      st != LE_TRACK_RECORDING && st != LE_TRACK_OVERDUBBING) {
    const int cancelling_arm = engine->armed[channel] &&
        load_i32(&t->a_pending) &&
        ((sound_arm && engine->armed_trigger[channel] == 1) ||
         (quantized_arm && engine->armed_trigger[channel] == 0));
    if (cancelling_arm) return le_cancel_arm(engine, channel);
    return LE_ERR_INVALID;
  }
  if (st != LE_TRACK_RECORDING && st != LE_TRACK_OVERDUBBING &&
      !load_i32(&t->a_pending_launch) &&
      !(engine->armed[channel] && load_i32(&t->a_pending))) {
    for (int lane = 0; lane < le_lanes_active(t); ++lane)
      if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane))
        return LE_ERR_INVALID;
  }
  /* #1146: a fresh capture on a track that only READS as EMPTY here. An
   * Undo-to-empty, Clear or cancelled take makes the control view EMPTY the
   * moment it is posted, but the callback block that applies it may still be
   * mid-frame on the previous content: mix_tracks_frame caches pool[live]
   * before it dereferences it, and a_state only changes when the command is
   * applied. The preparation below then frees (regrow), zeroes or replaces
   * exactly such buffers on this thread. Decide from what THIS action will
   * concretely do to existing PCM — the live buffers, and the one shadow slot
   * it will supply — and only when it touches some, require the track to be
   * actually EMPTY with the command that emptied it published
   * (a_commands_published, stored after the last frame of the block, at or
   * past empty_command): the block that applied it has completed, so no
   * pointer it or an earlier block captured is in use, and every later block
   * reads the track as EMPTY and captures none until this sole producer posts
   * a new start. A state ack alone is not that proof (it lands before the
   * block's frames finish); commands posted since — other tracks, settings —
   * need not have published. Refusal is LE_ERR_NOT_READY before any mutation,
   * so history, arm flags, mutes and the ring are untouched and a retry after
   * publication takes the ordinary path. Preparation that leaves existing PCM
   * alone (a cap-sized live buffer, a lazy or sufficient candidate) is admitted
   * exactly as before, so an accepted CANCEL/Undo-to-empty followed by a
   * defining capture still rides one batch
   * (test_record_image_grid_clear_is_in_capture_batch). Cancellations (a
   * second press on a pending arm) prepare nothing and are exempt; the
   * trigger-2 immediate case is refused below without touching PCM (the grid
   * redefinition it passes through drops history and posts no buffer edit).
   *
   * Residual: emptyings the audio thread decides on its own — a quantized
   * finish arm firing on a take that captured nothing, a launch commit
   * closing another channel's grace take (close_active_capture) — have no
   * command of their own to ticket; the ticket then dates from the command
   * that scheduled them, so the firing block itself is not fenced.
   *
   * Behaviour note: starts are ticketed too (see the RECORD post), so with a
   * master present a second Record press inside the block that starts the
   * take is refused as switch bounce — the take keeps recording and the host
   * drops its retry silently — where it used to become a void finish. Within
   * one block only bounce produces two presses (the pedal debounce is longer).
   * Without a master nothing is touched, so it is still admitted. */
  if (st == LE_TRACK_EMPTY &&
      !(engine->armed[channel] && load_i32(&t->a_pending) &&
        (sound_arm || quantized_arm || engine->armed_trigger[channel] == 2))) {
    /* Zeroing: every deferred arm, and an immediate start over a grid this
     * capture does not redefine (has_master survives the internal clear). */
    const int zero = sound_arm || quantized_arm || capture_has_master;
    int shadow = -1;
    int32_t shadow_frames = engine->max_loop_frames;
    if (le_capture_may_overdub(engine, channel, capture_has_master)) {
      int evict;
      if (image) {
        /* le_prepare_image_capture: live + outstanding excluded, history not. */
        shadow = track_select_slot(t, 0, 0, t->outstanding_count, &evict);
      } else if (!sound_arm && !quantized_arm) {
        /* le_post_dub_shadows after RECORD: redo and outstanding are gone by
         * then (le_begin_empty_capture); the undo stack survives unless the
         * grid-redefining clear resets it or it is erased-take history that
         * le_drop_clear_history drops. Deferred primitive arms allocate their
         * shadow later, through the drain, so they prepare none now. */
        const int history =
            (redefine_grid && (has_master || t->cancel_pending)) ||
                    t->clear_restore_pending || le_history_is_cleared(t)
                ? 0
                : t->undo_count;
        shadow = track_select_slot(t, history, 0, 0, &evict);
        shadow_frames = le_layer_slot_frames(engine, le_track_settled_len(t));
      }
    }
    if (le_capture_prep_touches_pcm(engine, t, zero, shadow, shadow_frames) &&
        !(load_i32(&t->a_state) == LE_TRACK_EMPTY &&
          t->empty_command <= atomic_load_explicit(&engine->a_commands_published,
                                                   memory_order_acquire))) {
      return LE_ERR_NOT_READY;
    }
  }
  int fresh_shadow = -1;
  int clear_first = 0;
  if (image && st == LE_TRACK_EMPTY) {
    const int cancelling_arm = (sound_arm || quantized_arm) &&
        engine->armed[channel] && load_i32(&t->a_pending);
    const int prearm = !cancelling_arm &&
        le_capture_may_overdub(engine, channel, capture_has_master);
    const int clear = redefine_grid && (has_master || t->cancel_pending);
    if (!le_record_capacity(engine, 1u + clear + prearm)) return LE_ERR_INVALID;
    if (prearm) {
      if (engine->armed[channel] && load_i32(&t->a_pending) &&
          engine->armed_trigger[channel] == 2) return LE_ERR_INVALID;
      fresh_shadow = le_prepare_image_capture(engine, channel);
      if (fresh_shadow < 0) return LE_ERR_INVALID;
    }
  }

  /* A fresh take on an otherwise-empty looper redefines the grid. Undo-to-
   * empty deliberately keeps the master (redo needs it), but once the user
   * records fresh — invalidating this track's redo — a ghost grid would lock
   * the new loop to the dead tempo (and a quantized press would arm for a
   * loop top the held clock never reaches). An internal clear resets the
   * master through handle_clear's all-empty path, making this the defining
   * recording — unless a sibling still needs the grid (content, undo, or an
   * undone-to-empty redo that resurrects onto it). */
  if (redefine_grid) {
    /* Nothing else holds the grid, so this take defines it — which is the rule
     * that retires every cleared track's restore point (#219), not just this
     * track's. A restore point records the master length it was cleared under;
     * once a new take redefines that base, putting the old take back would drop
     * it onto a grid it was never cut to. The way back dies with the old tempo.
     *
     * This runs whether or not there is a master to reset (a whole-rig clear
     * already zeroed it), so it must sit outside the has_master check below —
     * that one only decides whether an internal CLEAR is needed to reset a grid
     * that is still standing. */
    for (int32_t c = 0; c < engine->track_count; ++c) {
      le_drop_clear_history(&engine->tracks[c]);
    }
    /* A cancelled take still in flight (cancel_pending) will establish the
     * grid it would have set before this press lands; the internal clear
     * behind it resets that grid too, so this take defines its own. */
    if (has_master || t->cancel_pending) {
      if (image) {
        /* Preserve retirement staging before reclaiming history, but do not
         * run the general drain's shadow/queued-undo producers: the complete
         * CLEAR + capture sequence already owns the checked ring capacity.
         * CLEAR itself is published with the final record/arm below. */
        le_command evt;
        while (le_ring_pop(&engine->evt_ring, &evt))
          le_handle_event(engine, &evt, 0);
        le_prepare_clear(t, 0);
        le_finish_clear(engine, channel, 0, NULL);
        clear_first = 1;
        has_master = 0;
      } else if (le_engine_clear(engine, channel) == LE_OK) {
        has_master = 0;
      }
    }
  }

  /* No engine self-snapshot on record: the host (LooperRepository) is the sole
   * record-time snapshot authority and pushes each take's lane FX through the
   * command ring like any other lane edit. The engine is a pure sink — it holds
   * only what the host pushes, so there is no second, ring-deferred computation
   * to race or diverge (the dry-take-when-FX-monitored bug). The internal CLEAR
   * that may ride ahead of us (grid redefinition, above) resets only the master
   * grid / buffers via handle_clear — it does NOT touch lane FX — so the host's
   * pushed chain, queued before this record command, is never clobbered. */

  /* Sound-activated: a record press on an empty track arms a signal-triggered
   * start (LE_CMD_ARM with trigger 1); the audio thread begins recording the
   * first frame the input crosses the threshold. A second press cancels. Takes
   * precedence over quantize for the start — finalize/overdub presses (the
   * track is no longer EMPTY) fall through to the quantize/immediate paths.
   * A DEFINING press with count-in enabled skips this arm entirely (D9:
   * count-in wins when both are somehow set at once) and falls through to the
   * immediate path, where the audio thread starts the count-in. */
  if (sound_arm) {
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0; /* spent: the signal already fired it */
    }
    if (engine->armed[channel]) {
      /* B3b BUG 2 (adversarial review): armed[]/armed_trigger[] is shared
       * across every arm-capable command on this channel (auto-record here,
       * the quantize arm below, and le_engine_toggle_section's trigger 2).
       * A pending arm belonging to a DIFFERENT trigger must be rejected,
       * not silently cancelled — treating "someone else's live arm" as
       * "my own second press" would swallow their pending action with no
       * error to either caller. */
      if (engine->armed_trigger[channel] != 1) return LE_ERR_INVALID;
      engine->armed[channel] = 0;
      return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
    }
    engine->armed[channel] = 1;
    engine->armed_trigger[channel] = 1; /* input-level trigger */
    le_begin_empty_capture(engine, channel, image != NULL);
    le_prepare_new_capture(engine, t);
    const int32_t rc = le_post_record_image(engine, channel, LE_CMD_ARM, 1.0f,
                                           0, image, fresh_shadow, clear_first);
    if (rc == LE_OK) le_ticket_emptying(engine, channel); /* see the RECORD post */
    return rc;
  }

  /* Quantized: defer the action to the next base-loop top instead of acting on
   * the press, so captures align to the grid. The defining recording (no master
   * yet) always acts immediately — it sets the grid. So does a press while the
   * transport is held (everything parked/empty): the clock never ticks then, a
   * deferred arm would deadlock, and the held position IS the loop top, so
   * immediate is on-grid by definition. Per-track overrides win over the
   * global default.
   *
   * B3, D16: a Sync/Band non-primary EMPTY track's DEFINING recording is
   * ALSO force-armed here, regardless of the ordinary quantize setting —
   * the manual's "automatically quantized to keep them in sync with the
   * primary track" (song-mode-spec.md §1). Scoped to st == EMPTY only:
   * this is what makes the take START at the loop top (record_pos seeds to
   * e->clock.position, which the fire lands on exactly 0), the
   * precondition finalize_new_track's division-playback formula depends on
   * (mix_tracks_frame reads a division phase-locked to the primary's top,
   * which only holds if the take BEGAN there). Finalize / punch-in
   * quantization is unaffected — governed only by the ordinary setting,
   * unchanged. */
  if (quantized_arm) {
    /* If we armed this track but the boundary already fired it, the arm is
     * spent (published a_pending cleared); fall through to a fresh decision on
     * the now-current state. */
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0;
    }
    if (engine->armed[channel]) {
      /* B3b BUG 2 (adversarial review, see the auto-record branch above for
       * the full rationale): reject rather than cancel a DIFFERENT
       * trigger's pending arm. */
      if (engine->armed_trigger[channel] != 0) return LE_ERR_INVALID;
      /* Second press before the boundary cancels the pending action. */
      engine->armed[channel] = 0;
      return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
    }
    if (image && (st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) &&
        len > 0 && !le_prepare_image_punch_in(engine, channel))
      return LE_ERR_INVALID;
    /* Arm: do the one-time prep an immediate record would, then defer. */
    engine->armed[channel] = 1;
    engine->armed_trigger[channel] = 0; /* loop-top trigger */
    if (st == LE_TRACK_EMPTY) {
      le_begin_empty_capture(engine, channel, image != NULL);
      le_prepare_new_capture(engine, t);
    } else if (!image && (st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
      le_begin_punch_in(engine, channel, 0);
    }
    const int32_t rc = le_post_record_image(engine, channel, LE_CMD_ARM, 0.0f,
                                           0, image, fresh_shadow, clear_first);
    /* A quantized finish of a take that has captured nothing empties it when
     * the arm fires; the ticket covers the ARM's own block (the firing block
     * is autonomous — see the guard's residual note). A start is ticketed for
     * the same reason as the immediate RECORD post below. */
    if (rc == LE_OK && (st == LE_TRACK_EMPTY || st == LE_TRACK_RECORDING)) {
      le_ticket_emptying(engine, channel);
    }
    return rc;
  }

  /* Immediate (quantize off, or the defining recording). A pending Band
   * section-transport arm (trigger 2, le_engine_toggle_section) belongs to
   * a DIFFERENT command and must not be silently discarded here — B3b
   * BUG 2: LE_CMD_RECORD unconditionally zeroes pending_record/a_pending on
   * the audio thread with no way to tell whose arm it was clearing, so an
   * immediate record on a channel with a live toggle-section arm would
   * otherwise swallow the user's original toggle with zero error to either
   * caller. A genuinely spent arm (already fired: a_pending reads 0) still
   * decays as normal, regardless of trigger — nothing to protect there.
   * Scoped to trigger 2 specifically (not "any armed[channel]"): a stale
   * trigger-0/1 arm reaching here (e.g. quantize toggled off mid-arm)
   * predates B3b and must keep its existing behavior — falling through to
   * an immediate record — bit-identical for Multi/Sync. */
  if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
    engine->armed[channel] = 0;
  }
  if (engine->armed[channel] && engine->armed_trigger[channel] == 2) {
    return LE_ERR_INVALID;
  }
  if (st == LE_TRACK_EMPTY) {
    le_begin_empty_capture(engine, channel, image != NULL);
    if (has_master) le_prepare_new_capture(engine, t);
  }
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    if (image) {
      if (!le_prepare_image_punch_in(engine, channel)) return LE_ERR_INVALID;
    } else {
      le_begin_punch_in(engine, channel, 0);
    }
  }
  /* A deliberate press re-opens the punch-out latch: whatever an undo posted
   * before it, THIS command is the one the user means, and the next undo on
   * the pass it starts must be free to punch out again. */
  t->dub_punch_out_posted = 0;
  const int32_t rc = le_post_record_image(engine, channel, LE_CMD_RECORD, 0.0f,
      st == LE_TRACK_EMPTY && !has_master, image, fresh_shadow, clear_first);
  /* Finishing a take that has captured nothing empties the track (#1146).
   * The second press of such a pair lands inside the block that starts the
   * take, so this thread still reads it as EMPTY and classifies it as another
   * start — the audio thread applies it as the void finish. Ticket starts as
   * well as finishes, then: the ticket is consulted only while the track
   * reads EMPTY with that block unpublished, which is exactly this window.
   * Punch-ins on PLAYING/STOPPED content never empty and are left alone. */
  if (rc == LE_OK && (st == LE_TRACK_EMPTY || st == LE_TRACK_RECORDING)) {
    le_ticket_emptying(engine, channel);
  }
  /* Pre-arm ONE shadow slot for a fresh capture that is bound to run straight
   * into overdub (rec/dub, or a non-defining fixed multiple). Posted AFTER the
   * RECORD command so it orders behind handle_record's EMPTY-case drop of any
   * stale armed slots — the audio thread then arms this one during RECORDING,
   * and the finalize->overdub transition finds it already in hand, so the first
   * wrap's pass backs up on write and becomes its own undo layer. One slot, not
   * LE_DUB_SHADOWS: it is cap-sized (the length is not settled until finalize),
   * and the running session's replenish supplies the quantized spare right
   * after finalize. Image-aware starts already published their prepared slot
   * with the action above; deferred image arms retain it until actual start.
   * Primitive deferred arms still use the RECORDING poll pre-arm path. */
  if (rc == LE_OK && fresh_shadow < 0 && st == LE_TRACK_EMPTY &&
      le_capture_may_overdub(engine, channel, has_master)) {
    le_post_dub_shadows(engine, channel, 1);
  }
  return rc;
}

int32_t le_engine_record(le_engine* engine, int32_t channel) {
  return le_record_impl(engine, channel, NULL);
}

int32_t le_engine_record_with_image(le_engine* engine, int32_t channel,
                                     const le_record_image* image) {
  if (!image) return LE_ERR_INVALID;
  const int32_t admission = le_record_preflight(engine, channel, image);
  if (admission != LE_OK) return admission;
  if (le_classify_record(engine, channel) != LE_RECORD_ACQUIRE)
    return le_record_impl(engine, channel, NULL);
#ifdef LE_NATIVE_TESTS
  if (le_test_record_timing_hook) le_test_record_timing_hook(engine, 4);
#endif
  struct le_prepared_fx* recipes = le_fx_prepare_capture(engine, channel, image);
  if (image->fx_lane_mask && !recipes) return LE_ERR_INVALID;
  engine->record_fx_prepared = recipes;
  const int32_t rc = le_record_impl(engine, channel, image);
  engine->record_fx_prepared = NULL;
  if (rc == LE_OK) le_fx_recipe_admitted(engine, recipes, image->revision);
  else le_fx_recipe_abandon(recipes);
  return rc;
}

int32_t le_engine_stop_track(le_engine* engine, int32_t channel) {
  const int32_t rc = le_push(engine, LE_CMD_STOP, channel, 0.0f);
  if (rc == LE_OK) le_ticket_emptying(engine, channel); /* void take -> EMPTY */
  return rc;
}
int32_t le_engine_play(le_engine* engine, int32_t channel) {
  if (!engine || channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (le_launch_cancellable(&engine->tracks[channel]))
    return le_engine_cancel_arm(engine, channel);
  if (engine && engine->record_start_command > atomic_load_explicit(
      &engine->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  const int32_t rc = le_push(engine, LE_CMD_PLAY, channel, 0.0f);
  /* handle_play routes a track still in its launch grace to handle_record,
   * which empties the take: ticket a PLAY that drains against one (#1146). */
  if (rc == LE_OK) le_ticket_launch_cancel(engine, channel);
  return rc;
}
/* Builds the restore point for a clear about to be posted on `t` (control
 * thread), or returns 0 when there is nothing worth restoring — an already-empty
 * or zero-length track, or a history with no room left. Every field is read
 * BEFORE the caller mutates any of them.
 *
 * The mutes are snapshotted from the published atomics, so a mute command posted
 * but not yet applied is not seen here. That is the same snapshot tolerance the
 * rest of the control-side bookkeeping already accepts (le_track_set_len and
 * friends), and the failure mode is cosmetic: a restore may miss a mute the user
 * flipped in the same instant as the clear. */
static int le_build_restore_point(le_engine* engine, le_track* t,
                                  le_hist_entry* out) {
  if (t->undo_count >= LE_POOL_SLOTS) return 0; /* no room to push it */
  const int32_t st = le_effective_state(t);
  if (st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) return 0;
  const int32_t len = le_effective_len(t);
  if (len <= 0) return 0;

  le_hist_entry e = {0};
  e.kind = LE_HIST_CLEAR;
  e.clear_generation = t->dub_generation + 1;
  e.slot = load_i32(&t->lanes[0].a_live);
  e.len = len;
  e.state = st;
  /* Measured against what an in-flight restore will publish, not the wire:
   * a clear right behind a queued restore must record the grid that restore
   * re-establishes, or its own restore leaves the rig with content and no
   * master. */
  e.master_len = le_effective_master_len(engine, t);
  e.multiple = e.master_len > 0 && len >= e.master_len ? len / e.master_len
                                                        : load_i32(&t->a_multiple);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    if (load_i32(&t->lanes[l].a_muted)) e.muted_mask |= 1u << l;
  }
  *out = e;
  return 1;
}

/* The shared body of both clears. `push_restore` decides which one this is:
 * le_engine_clear_undoable keeps the track's history and pushes a LE_HIST_CLEAR
 * on top of it; le_engine_clear resets the history outright. Everything else —
 * the posted command, the generation bump, the reclaim — is identical, because
 * the audio thread's view of a clear does not depend on whether control kept a
 * way back. */
static int32_t le_clear_track(le_engine* engine, int32_t channel,
                              int push_restore) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
  }
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  /* An undoable nonempty Clear must never silently become destructive when
   * history cannot hold its point. Layer slots plus the pinned live slot bound
   * ordinary reachable history below this limit, including pending retirements. */
  if (push_restore && le_effective_state(t) != LE_TRACK_EMPTY &&
      t->undo_count >= LE_POOL_SLOTS) return LE_ERR_NOT_READY;
  le_hist_entry restore = {0};
  const int keep = push_restore && le_build_restore_point(engine, t, &restore);
  /* A user clear on a CAPTURING track (accepted design, slice 2): the take
   * is frozen STOPPED at the clear and kept restorable. Its length is not
   * known until the audio thread finalizes it, so the restore point is
   * completed by the Clear mailbox; arg_f = 1 asks handle_clear to
   * finalize first and report. */
  const int32_t est = le_effective_state(t);
  const int freeze = push_restore && !keep &&
                     (est == LE_TRACK_RECORDING || est == LE_TRACK_OVERDUBBING) &&
                     t->undo_count < LE_POOL_SLOTS;
  /* Push-then-mutate: only a clear the audio thread will actually apply may
   * reset the control-side bookkeeping (and bump the generation the audio
   * thread mirrors in handle_clear — one bump per applied CLEAR keeps the two
   * counters equal without sharing a variable). */
  const int32_t rc = le_push(engine, LE_CMD_CLEAR, channel, freeze ? 1.0f : 0.0f);
  if (rc != LE_OK) return rc;
  le_prepare_clear(t, freeze);
#ifdef LE_NATIVE_TESTS
  /* Deterministically schedule the audio consumer in the native regression.
   * No hook or call is compiled into the shipped engine. */
  extern void le_test_after_clear_posted(le_engine* engine);
  le_test_after_clear_posted(engine);
#endif
  /* Part 5 (D-LAYER): drain again, immediately before the reclaim below —
   * the initial drain at the top of this function catches whatever was
   * already in evt_ring, but the audio thread runs concurrently and could
   * push a fresh retire event for this track in the interim (a dub session's
   * tail can still be draining/retiring after punch-out, independent of
   * whatever triggered this clear). Every layer that reaches le_handle_retired
   * gets staged (le_stage_retired_layer) regardless of the generation check
   * that follows it, so this call's only job is to make sure any such event
   * is popped and staged BEFORE the generation bump below would otherwise
   * leave it sitting undrained while its slot becomes reclaimable — the same
   * race this part's own docs describe as narrowed, not eliminated, by a
   * control-thread-only fix. */
  le_engine_drain_events(engine);
  le_finish_clear(engine, channel, freeze, keep ? &restore : NULL);
  return LE_OK;
}

int32_t le_engine_clear(le_engine* engine, int32_t channel) {
  return le_clear_track(engine, channel, 0);
}

int32_t le_engine_clear_undoable(le_engine* engine, int32_t channel) {
  return le_clear_track(engine, channel, 1);
}

/* A history entry can survive an empty-rig mode change. Predict the current
 * mode's grid while a restore is queued, using the same rule as the callback. */
static int32_t le_restore_master_len(le_engine* engine, int32_t len,
                                     int32_t saved_master_len) {
  const int32_t mode = load_i32(&engine->a_looper_mode);
  if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) return 0;
  const int32_t master = le_rig_effective_master_len(engine);
  return master > 0 ? master : (saved_master_len > 0 ? saved_master_len : len);
}

/* A read-only projection: completing a report belongs to the normal event
 * drain, never to this query. In particular, querying a group must not execute
 * one of its queued taps before the remaining members have been checked. */
int32_t le_engine_history_mode_gate(le_engine* engine, uint32_t channels,
                                     int32_t redo) {
  if (engine == NULL || (redo != 0 && redo != 1)) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  const uint32_t valid = (1u << engine->track_count) - 1u;
  if (channels & ~valid) return LE_ERR_INVALID;
  if (channels == 0) return LE_OK;
  int restores_content = 0;
  for (int32_t c = 0; c < engine->track_count; ++c) {
    if (!(channels & (1u << c))) continue;
    le_track* t = &engine->tracks[c];
    if (t->clear_restore_pending || t->cancel_pending) return LE_ERR_NOT_READY;
    if ((!redo && le_history_is_cleared(t)) ||
        (redo && t->redo_count > 0 &&
         t->redo_stack[t->redo_count - 1].kind != LE_HIST_CLEAR &&
         le_effective_state(t) == LE_TRACK_EMPTY && t->empty_len > 0)) {
      restores_content = 1;
    }
  }
  /* Re-clears and same-span layer edits add no incompatible content. In
   * particular a grouped redo must not fence its own preceding re-clear.
   * PEEL and PROCESSED entries and redo-side PEEL markers (#1164) are
   * same-span swaps too: every kind test in this projection asks only
   * "is it CLEAR", so they fall with LAYER by construction. */
  if (!restores_content) return LE_OK;
  if (engine->clock_commands_posted !=
      atomic_load_explicit(&engine->a_clock_commands_applied,
                           memory_order_acquire)) return LE_ERR_NOT_READY;

  const int32_t mode = load_i32(&engine->a_looper_mode);
  const int independent = mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  int32_t lengths[LE_MAX_TRACKS];
  int32_t states[LE_MAX_TRACKS];
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* t = &engine->tracks[c];
    /* CANCEL presents EMPTY before its callback finalizes the captured span.
     * Even an unselected sibling can therefore establish the shared clock. */
    if (!independent && t->cancel_pending) return LE_ERR_NOT_READY;
    if (t->clear_cmd_ack >
        atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
      return LE_ERR_NOT_READY; /* an earlier clear may reset the shared clock */
    }
    /* Acquire finalized state before its length/master. A defining capture
     * publishes its clock before leaving RECORDING with release semantics. */
    states[c] = le_effective_state(t);
    lengths[c] = le_effective_len(t);
  }
  int32_t base = independent ? 0 : le_rig_effective_master_len(engine);
  if (!independent && base <= 0) {
    if (load_i32(&engine->a_counting_in)) return LE_ERR_NOT_READY;
    for (int32_t c = 0; c < engine->track_count; ++c) {
      if (states[c] == LE_TRACK_RECORDING ||
          (states[c] == LE_TRACK_EMPTY &&
           (engine->armed[c] || load_i32(&engine->tracks[c].a_pending)))) {
        return LE_ERR_NOT_READY; /* the defining take has no final span yet */
      }
    }
  }
  for (int32_t c = 0; c < engine->track_count; ++c) {
    if (!(channels & (1u << c))) continue;
    le_track* t = &engine->tracks[c];
    const int32_t state = states[c];
    int32_t restored = 0;
    int32_t saved_base = 0;
    if (!redo) {
      if (le_history_is_cleared(t)) {
        const le_hist_entry* entry = &t->undo_stack[t->undo_count - 1];
        restored = entry->len;
        saved_base = entry->master_len;
      } else if (t->undo_count == 0 &&
                 (state == LE_TRACK_PLAYING || state == LE_TRACK_STOPPED)) {
        lengths[c] = 0; /* undoing a base take preserves the shared clock */
      }
    } else if (t->redo_count > 0) {
      const le_hist_entry* entry = &t->redo_stack[t->redo_count - 1];
      if (entry->kind == LE_HIST_CLEAR) {
        lengths[c] = 0;
        int any_content = 0;
        for (int32_t other = 0; other < engine->track_count; ++other) {
          if (lengths[other] > 0 ||
              states[other] == LE_TRACK_RECORDING) {
            any_content = 1;
          }
        }
        if (!any_content) base = 0; /* the last clear drops the grid */
      } else if (state == LE_TRACK_EMPTY) {
        restored = t->empty_len;
      }
    }
    if (restored <= 0) continue; /* same-span layer edits need no new clock */
    lengths[c] = restored;
    if (independent) continue;
    if (base <= 0) {
      base = saved_base > 0 ? saved_base : restored;
    }
    for (int32_t other = 0; other < engine->track_count; ++other) {
      if (!le_mode_span_fits(mode, base, lengths[other])) {
        return LE_ERR_MODE_MISMATCH;
      }
    }
  }
  return LE_OK;
}

/* Performance event log, control-thread side (part 3, docs/design/
 * performance-event-log-format.md): the direct-atomic setters below (FX/
 * monitor params, the limiter, overdub feedback) and the common in-track
 * undo/redo swap bypass the command ring entirely, so they push into
 * perf.log_ctrl_ring instead of relying on apply_command's emission. Reads
 * a_perf_frames as a snapshot — accurate within one buffer, which is the
 * documented tolerance for these control-side events. No-op when not armed,
 * checked via the published atomic (this runs on the control thread, not the
 * audio thread, so e->perf.armed — the audio-thread-local mirror — must not
 * be read here). */
static void le_plog_push_ctrl(le_engine* engine, le_command cmd) {
  if (!atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return;
  }
  const uint64_t frame =
      atomic_load_explicit(&engine->a_perf_frames, memory_order_relaxed);
  le_perf_log_entry entry = {.frame = frame};
  if (!le_log_extract(&cmd, &entry.cmd)) return;
  if (!le_perf_log_ring_push(&engine->perf.log_ctrl_ring, entry)) {
    atomic_fetch_add_explicit(&engine->a_perf_log_ctrl_overruns, 1u,
                              memory_order_relaxed);
  }
}

/* Undo/redo run on the control thread: they swap the live pool index (atomic;
 * the audio thread's only window into the buffers) on EVERY active lane in
 * lockstep, so the one undo span moves all lanes together. Allowed only when
 * the track is not capturing AND no layer is in flight (tail/drain still
 * writing), so the audio thread sees a stable a_live — an undo tapped during
 * that window is queued and applied when the layer retires, never lost. */
/* Applies a clear restore point (control thread): the track comes back exactly
 * as the clear found it — content, length, multiple, state, mutes, and the
 * master grid if that clear reset it — with the erased take's layers still
 * stacked beneath, so undo keeps peeling from where it left off.
 *
 * Mirrors the redo-from-empty path's shape: control owns a_live and the
 * control-side length snapshot, the audio thread owns the state flip. The mutes
 * ride the ring AHEAD of the state flip, exactly as the resurrect path does, so
 * the track is never briefly audible with the wrong mute. */
static int32_t le_restore_clear(le_engine* engine, int32_t channel) {
  const int32_t gate = le_engine_history_mode_gate(engine, 1u << channel, 0);
  if (gate != LE_OK) return gate;
  le_track* t = &engine->tracks[channel];
  /* The gate acquired the Clear acknowledgement after the caller's drain.
   * Collect again before copying history or posting any restoration mutes. */
  le_collect_clear(engine, t);
  if (!le_history_is_cleared(t) ||
      !t->undo_stack[t->undo_count - 1].fade_ready) return LE_ERR_NOT_READY;
  const le_hist_entry e = t->undo_stack[t->undo_count - 1];
  const int32_t lanes = le_lanes_active(t);

  for (int32_t l = 0; l < lanes; ++l) {
    const float muted = (e.muted_mask & (1u << l)) ? 1.0f : 0.0f;
    le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                     .lanef = {channel, l, muted}});
  }
  le_command cmd = {.code = LE_CMD_RESTORE_CLEAR};
  cmd.restore.channel = channel;
  cmd.restore.len = e.len;
  cmd.restore.state = e.state;
  cmd.restore.master_len = e.master_len;
  cmd.restore.fade_amount = e.fade_amount;
  /* Staged before the push: the callback may apply this restore before the
   * publish below and looks the slot up at that frame (#1143). */
  const uint32_t image_id = le_stage_source_image(engine, channel, e.slot, e.len);
  if (le_push_cmd(engine, cmd) != LE_OK) return LE_ERR_INVALID;
#ifdef LE_NATIVE_TESTS
  if (le_test_fade_hook) le_test_fade_hook(engine, 4);
#endif

  t->undo_count--;
  /* Cannot fail: one entry off the undo stack for the one added here. */
  (void)le_redo_push(t, e);
  le_publish_live_image(engine, t, e.slot, image_id); /* [R1] clear-restore */
  /* Leftover armed shadows may be sized for a different loop; the audio thread
   * drops them when the command applies (same reclaim rule as redo-from-empty:
   * an EMPTY track has no layer in flight, so no retire event can be
   * mis-attributed). */
  t->outstanding_count = 0;
  le_mark_state_cmd(t, e.state);
  t->pending_len = e.len; /* what the restore will publish */
  t->pending_master_len = le_restore_master_len(engine, e.len, e.master_len);
  /* Length and multiple are DELIBERATELY not stored control-side here, unlike
   * the paths that empty a track. Those publish len 0 up front so a poll can
   * never catch EMPTY next to a stale nonzero length; this one runs the other
   * way, so doing the same would publish the restored length while a_state is
   * still EMPTY — manufacturing the very pair (EMPTY, len > 0) that the host's
   * 'depths-sane' invariant rejects. handle_restore_clear sets both, in that
   * order, so the track is only ever seen empty-and-lengthless or
   * restored-and-sized. Control-side decisions in the gap are safe without it:
   * le_mark_state_cmd below already makes le_effective_state report the
   * restored state. */
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
  le_plog_push_ctrl(engine,
                    (le_command){.code = LE_PLOG_UNDO, .arg_i = channel});
  return LE_OK;
}

int32_t le_engine_undo_restores_clear(le_engine* engine, int32_t channel) {
  if (engine == NULL) return 0;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return 0;
  }
  if (channel < 0 || channel >= engine->track_count) return 0;
  /* Drain first, for the same reason le_engine_undo does: a retire event still
   * in the ring would push a layer on top of the restore point, making the next
   * tap a peel rather than a restore. Answering from the undrained stack would
   * hand the caller a stale verdict it is about to act on. */
  le_engine_drain_events(engine);
  return le_history_is_cleared(&engine->tracks[channel]) ? 1 : 0;
}

int32_t le_engine_undo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  if (load_i32(&t->a_pending_launch)) return le_engine_cancel_arm(engine, channel);
  if (t->clear_restore_pending || t->cancel_pending) return LE_ERR_NOT_READY;
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_OVERDUBBING) {
    /* Accepted design (slice 2): undo mid-pass removes the pass. Punch out
     * NOW — a quantized punch-out arm would wait for the grid and keep
     * writing — and queue the peel: the pass retires as a layer once the
     * audio thread drains it, the queued tap swaps it out, and the swap
     * leaves it on the redo stack. A pass that wrote nothing still retires
     * (the pre-pass image) and the tap then peels the previous layer. */
    (void)le_cancel_arm(engine, channel);
    /* Once per punch-out. A second tap before the audio thread drains the
     * first would post a second RECORD, and the audio thread applies the
     * pair as punch-out then punch-IN: asking to remove two passes would
     * leave the track recording input again. The peel still queues, because
     * that is what the tap asked for. */
    if (!t->dub_punch_out_posted) {
      const int32_t rc = le_push(engine, LE_CMD_RECORD, channel, 0.0f);
      if (rc != LE_OK) return rc;
      t->dub_punch_out_posted = 1;
    }
    t->queued_undo++;
    return LE_OK;
  }
  if (st == LE_TRACK_RECORDING) {
    /* Accepted design (slice 2): undo during a take cancels it, keeping the
     * captured audio for an immediate-playback redo. The finalized length is
     * the audio thread's to decide, so the redo entry is filed when
     * LE_EVT_TAKE_CANCELLED comes back; checked here that it will fit. */
    if (t->redo_count >= LE_POOL_SLOTS) return LE_ERR_INVALID;
    (void)le_cancel_arm(engine, channel);
    const int32_t rc = le_push(engine, LE_CMD_CANCEL_TAKE, channel, 0.0f);
    if (rc != LE_OK) return rc;
    t->queued_undo = 0;
    t->cancel_pending = 1;
    le_mark_empty_cmd(engine, t);
    /* The published length is NOT zeroed here, unlike the undo-to-empty
     * path: the audio thread may decline the cancel (the take finalized in
     * the same block), and a take that keeps playing needs its length. The
     * audio thread zeroes it with the state when it applies the cancel; the
     * published state stays the capture's until then, so a poll never sees
     * EMPTY with a length. */
    return LE_OK;
  }
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    /* Same-span layers apply on retire — see le_apply_queued_undo. */
    t->queued_undo++;
    return LE_OK;
  }
  /* The flight flag cleared: its final retire event was pushed before the
   * clear, so one more drain is guaranteed to have it on the stack. */
  le_engine_drain_events(engine);
  /* A clear restore point on top means the last thing that happened to this
   * track was a clear, so undoing it puts the take back rather than peeling a
   * layer. Checked before the layer path: the layers beneath the mark are the
   * erased take's, and they only become peelable again once it is restored. */
  if (le_history_is_cleared(t)) return le_restore_clear(engine, channel);
  if (t->undo_count > 0) {
    le_undo_swap(engine, t);
    le_plog_push_ctrl(engine,
                      (le_command){.code = LE_PLOG_UNDO, .arg_i = channel});
    return LE_OK;
  }
  /* No stacked layers left: undoing the base recording itself empties the
   * track (pedal/UI see no content) while the redo stack keeps the live slot,
   * so redo can reinstate it layer by layer. The master grid is deliberately
   * kept — redo needs it, and a full reset stays Clear's job. */
  const int32_t len = le_effective_len(t);
  if ((st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) || len <= 0) {
    return LE_ERR_INVALID;
  }
  /* Checked BEFORE the command is posted: an undo-to-empty whose resurrect slot
   * did not make it onto the redo stack would empty the track with no way back —
   * worse than declining the tap. */
  if (t->redo_count >= LE_POOL_SLOTS) return LE_ERR_INVALID;
  if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) {
    return LE_ERR_INVALID;
  }
  /* An emptied track must not have a quantized/auto-record arm still pending —
   * it would fire a surprise fresh recording at the next loop top. */
  le_cancel_arm(engine, channel);
  (void)le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)));
  t->empty_len = len;
  le_mark_empty_cmd(engine, t);
  le_track_set_len(t, 0); /* coherent snapshot before the audio thread applies */
  store_i32(&t->a_multiple, 1);
  store_i32(&t->a_sync_divisor, 0); /* B3: coherent-snapshot mirror */
  store_i32(&t->a_redo_depth, t->redo_count);
  return LE_OK;
}

int32_t le_engine_clear_restore_pending(le_engine* engine, int32_t channel) {
  if (engine == NULL) return 0;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return 0;
  }
  if (channel < 0 || channel >= engine->track_count) return 0;
  le_engine_drain_events(engine);
  return engine->tracks[channel].clear_restore_pending ? 1 : 0;
}

int32_t le_engine_redo_reclears(le_engine* engine, int32_t channel) {
  if (engine == NULL) return 0;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return 0;
  }
  if (channel < 0 || channel >= engine->track_count) return 0;
  le_engine_drain_events(engine);
  const le_track* t = &engine->tracks[channel];
  return t->redo_count > 0 &&
                 t->redo_stack[t->redo_count - 1].kind == LE_HIST_CLEAR
             ? 1
             : 0;
}

int32_t le_engine_redo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  if (t->clear_restore_pending || t->cancel_pending) return LE_ERR_NOT_READY;
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_INVALID;
  }
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_INVALID; /* a fresh dub is in flight: nothing to redo */
  }
  if (t->redo_count == 0) return LE_ERR_INVALID;
  /* Redo of a restored clear: re-apply the clear the undo took back. It rides
   * the same undoable path, so the restore point returns to the undo stack and
   * the pair stays symmetric under repeated undo/redo. */
  if (t->redo_stack[t->redo_count - 1].kind == LE_HIST_CLEAR) {
    /* le_clear_track discards the whole redo branch on success (le_clear_redo),
     * so this entry goes either way — but only pop it once the clear is actually
     * posted. Popping first would drop the restore point on a failed push (ring
     * full), leaving the user with neither the redo nor the undo they had. */
    const int32_t rc = le_clear_track(engine, channel, 1);
    if (rc != LE_OK) return rc;
    le_plog_push_ctrl(engine,
                      (le_command){.code = LE_PLOG_REDO, .arg_i = channel});
    return LE_OK;
  }
  if (st == LE_TRACK_EMPTY) {
    /* Reinstate an undone-to-empty track: the redo-top slot is its base
     * content. The audio thread restores state/len/multiple on apply; the
     * length is stored control-side too so snapshots (and a racing record
     * press) are coherent immediately. */
    const int32_t len = t->empty_len;
    if (len <= 0) return LE_ERR_INVALID;
    const int32_t gate = le_engine_history_mode_gate(engine, 1u << channel, 1);
    if (gate != LE_OK) return gate;
    /* Resurrection is always audible: a leftover Stop-mute would otherwise
     * bring the track back playing-but-silent (dark LED, no sound). Mirrors
     * the record-from-empty rule; the unmutes ride the ring ahead of the
     * state flip. */
    const int32_t lanes = le_lanes_active(t);
    for (int32_t l = 0; l < lanes; ++l) {
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                       .lanef = {channel, l, 0.0f}});
    }
    /* Staged before the push (#1143): the handler flips PLAYING and the
     * callback looks the slot up at that frame. */
    const int32_t next = t->redo_stack[t->redo_count - 1].slot;
    const uint32_t image_id = le_stage_source_image(engine, channel, next, len);
    if (le_push_cmd(engine, (le_command){.code = LE_CMD_REDO_FROM_EMPTY,
                                         .lanei = {channel, 0, len}}) !=
        LE_OK) {
      return LE_ERR_INVALID;
    }
    t->redo_count--;
    le_publish_live_image(engine, t, next, image_id); /* [R1] redo-from-empty */
    t->empty_len = 0;
    /* Leftover armed shadows may be sized for a different loop; the audio
     * thread drops them when the command applies. Same no-in-flight argument
     * as the record-from-empty reclaim. */
    t->outstanding_count = 0;
    le_mark_state_cmd(t, LE_TRACK_PLAYING);
    t->pending_len = len;
    t->pending_master_len = le_restore_master_len(engine, len, 0);
    le_track_set_len(t, len);
    store_i32(&t->a_redo_depth, t->redo_count);
    return LE_OK;
  }
  const le_hist_entry top = t->redo_stack[t->redo_count - 1];
  if (top.kind == LE_HIST_PEEL) {
    /* Redo of an undone Peel (#1164): run the Peel motion again, keeping the
     * rest of the redo branch. By construction the LAYER it re-consumes is the
     * one the undo re-inserted, under the same PEEL entries. */
    int32_t skipped;
    const int idx = le_peel_target(t, &skipped);
    if (idx < 0) return LE_ERR_INVALID;
    t->redo_count--;
    le_peel_apply(engine, t, idx, skipped);
    le_publish_undo_depth(t);
    store_i32(&t->a_redo_depth, t->redo_count);
    le_plog_push_ctrl(engine,
                      (le_command){.code = LE_PLOG_REDO, .arg_i = channel});
    return LE_OK;
  }
  t->redo_count--;
  const uint32_t image_id = le_stage_source_image(engine, channel, top.slot,
                                                  load_i32(&t->lanes[0].a_len));
  /* The kind rides along: a PROCESSED entry undone and redone stays PROCESSED. */
  t->undo_stack[t->undo_count++] =
      le_hist_kind_entry(top.kind, load_i32(&t->lanes[0].a_live), 0);
  le_publish_live_image(engine, t, top.slot, image_id); /* [R1] redo swap */
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
  le_plog_push_ctrl(engine,
                    (le_command){.code = LE_PLOG_REDO, .arg_i = channel});
  return LE_OK;
}

int32_t le_engine_peel(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
#ifdef LE_NATIVE_TESTS
  if (le_test_peel_hook) le_test_peel_hook(engine, 1);
#endif
  le_track* t = &engine->tracks[channel];
  /* Never queued (accepted design §2.10: the in-progress layer is Undo's): a
   * Peel that meets a capture, a layer still draining, a Count-in launch or
   * any pending state command, cancel or Clear report is refused untouched,
   * and the host shows the refusal as an unlit LED. */
  if (load_i32(&t->a_pending_launch) || t->clear_restore_pending ||
      t->cancel_pending) {
    return LE_ERR_NOT_READY;
  }
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_NOT_READY;
  }
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_NOT_READY;
  }
  /* The flight flag cleared: the audio thread pushes the final retire event
   * BEFORE clearing it, so a retire that landed between the drain above and
   * this load is still in the ring. One more drain is guaranteed to have it on
   * the stack (le_engine_undo does the same); without it a Peel tapped right
   * after a punch-out would consume the layer beneath the one just retired
   * and the late retire would then file on top of the PEEL, out of order. */
  le_engine_drain_events(engine);
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_NOT_READY;
  }
  int32_t skipped;
  const int idx = le_peel_target(t, &skipped);
  if (idx < 0) return LE_ERR_INVALID; /* none remain, or not an overdub */
  le_command fact = {.code = LE_PLOG_PEEL};
  fact.peel_log.channel = channel;
  fact.peel_log.slot = t->undo_stack[idx].slot;
  fact.peel_log.previous = load_i32(&t->lanes[0].a_live);
  fact.peel_log.generation = t->dub_generation;
  le_peel_apply(engine, t, idx, skipped);
  le_clear_redo(t); /* Peel is an edit: the redo branch dies (§2.10) */
  le_publish_undo_depth(t);
  le_plog_push_ctrl(engine, fact);
  return LE_OK;
}
int32_t le_engine_set_track_volume(le_engine* engine, int32_t channel,
                                   float volume) {
  return le_push(engine, LE_CMD_SET_VOLUME, channel, volume);
}
int32_t le_engine_set_track_mute(le_engine* engine, int32_t channel,
                                 int32_t muted) {
  return le_push(engine, LE_CMD_SET_MUTE, channel, muted ? 1.0f : 0.0f);
}

int32_t le_engine_set_input_mask(le_engine* engine, int32_t channel,
                                 int32_t mask) {
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_INPUT_MASK,
                                          .trackmask = {channel,
                                                        (uint32_t)mask}});
}
int32_t le_engine_set_output_mask(le_engine* engine, int32_t channel,
                                  int32_t mask) {
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_MASK,
                                          .trackmask = {channel,
                                                        (uint32_t)mask}});
}

static int le_fade_image_valid(const le_fade_image* v) {
  return v && isfinite(v->amount) && v->amount >= 0 && v->amount <= 1 &&
      isfinite(v->target) && v->target >= 0 && v->target <= 1 &&
      isfinite(v->full_travel_seconds) &&
      ((v->full_travel_seconds == 0 && v->amount == v->target) ||
       (v->full_travel_seconds >= 0.5f && v->full_travel_seconds <= 30));
}

/* Reserves a receipt slot, writes it into the command through `slot_in_cmd`,
 * posts, and hands back the request id. Shared by every checked per-track
 * request with a callback verdict (Fade, Reverse); the caller has already
 * validated the payload. NOT_READY when every slot is owned. */
static int32_t le_request_admit(le_engine* e, le_command* cmd,
                                int32_t* slot_in_cmd, uint64_t* request) {
  if (e->next_request == UINT64_MAX) return LE_ERR_INVALID;
  int slot = 0;
  while (slot < LE_RING_CAPACITY && e->receipts[slot].request) ++slot;
  if (slot == LE_RING_CAPACITY) return LE_ERR_NOT_READY;
  const uint64_t id = ++e->next_request;
  e->receipts[slot].request = id;
  atomic_store_explicit(&e->receipts[slot].result, LE_ERR_NOT_READY,
                         memory_order_relaxed);
  *slot_in_cmd = slot;
  const int32_t result = le_push_cmd(e, *cmd);
  if (result != LE_OK) {
    e->receipts[slot].request = 0;
    return result;
  }
  e->receipts[slot].command = e->commands_posted;
  *request = id;
  return LE_OK;
}

static int32_t le_fade_admit(le_engine* e, int32_t channel,
                             le_fade_image image, int install,
                             uint64_t* request) {
  if (request) *request = 0;
  if (!e || !request || channel < 0 || channel >= e->track_count ||
      !le_fade_image_valid(&image)) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (image.lifetime != e->fade_lifetime) return LE_ERR_INVALID;
  le_command cmd = {.code = LE_CMD_FADE, .fade = {channel, 0, install, image}};
  return le_request_admit(e, &cmd, &cmd.fade.slot, request);
}

/* Reverse admission (#1162): see le_engine_toggle_reverse's contract. The
 * state read is the effective one (a posted Clear or Undo to empty already
 * counts); a pending arm or Count-in launch may fire into OVERDUBBING before
 * the toggle lands, so the request waits rather than racing it. */
static int32_t le_reverse_admit(le_engine* e, int32_t channel, int install,
                                int32_t target, uint64_t* request) {
  if (request) *request = 0;
  if (!e || !request) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (channel < 0 || channel >= e->track_count) return LE_ERR_INVALID;
  le_track* t = &e->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
      (!install && st == LE_TRACK_EMPTY)) return LE_ERR_INVALID;
  if (load_i32(&t->a_pending) || e->armed[channel] ||
      load_i32(&t->a_pending_launch)) return LE_ERR_NOT_READY;
  const int predicted = install ? target != 0 : !le_effective_reversed(t);
  le_command cmd = {.code = LE_CMD_REVERSE,
                    .reverse = {channel, 0, install, target != 0}};
  const int32_t result = le_request_admit(e, &cmd, &cmd.reverse.slot, request);
  if (result != LE_OK) return result;
  t->reverse_pending = predicted;
  t->reverse_posted++;
  return LE_OK;
}

int32_t le_engine_toggle_reverse(le_engine* e, int32_t channel,
                                 uint64_t* request) {
  return le_reverse_admit(e, channel, 0, 0, request);
}

int32_t le_engine_install_reverse(le_engine* e, int32_t channel,
                                  int32_t reversed, uint64_t* request) {
  return le_reverse_admit(e, channel, 1, reversed, request);
}

/* Speed admission (#1179): see le_engine_set_speed's contract. Refused while
 * any track captures, is armed or launching, or a count-in runs, by the
 * effective state, so a request never races a capture into existence; the
 * callback rechecks (le_speed_change_safe). */
int32_t le_engine_set_speed(le_engine* e, int32_t numer, int32_t denom,
                            uint64_t* request) {
  if (request) *request = 0;
  if (!e || !request) return LE_ERR_INVALID;
  const int valid = (numer == 1 && denom == 2) ||
      (denom == 1 && (numer == 1 || numer == 2 || numer == 4 || numer == 8));
  if (!valid) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (load_i32(&e->a_counting_in)) return LE_ERR_NOT_READY;
  for (int c = 0; c < e->track_count; ++c) {
    le_track* t = &e->tracks[c];
    const int32_t st = le_effective_state(t);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
        load_i32(&t->a_pending) || e->armed[c] ||
        load_i32(&t->a_pending_launch)) return LE_ERR_NOT_READY;
  }
  le_command cmd = {.code = LE_CMD_SET_SPEED, .speed = {0, numer, denom}};
  const int32_t result = le_request_admit(e, &cmd, &cmd.speed.slot, request);
  if (result != LE_OK) return result;
  e->speed_pending_one = numer == denom;
  e->speed_posted++;
  return LE_OK;
}

int32_t le_engine_toggle_fade(le_engine* e, int32_t channel, float seconds,
                              uint64_t* request) {
  if (request) *request = 0;
  if (!e || channel < 0 || channel >= e->track_count ||
      !isfinite(seconds) || seconds < 0.5f || seconds > 30) return LE_ERR_INVALID;
  const le_fade_image image = {1, 1, seconds, e->fade_lifetime,
      atomic_load_explicit(&e->tracks[channel].a_fade_generation, memory_order_seq_cst)};
  return le_fade_admit(e, channel, image, 0, request);
}

int32_t le_engine_install_fade(le_engine* e, int32_t channel,
                               const le_fade_image* image, uint64_t* request) {
  if (!image) { if (request) *request = 0; return LE_ERR_INVALID; }
  return le_fade_admit(e, channel, *image, 1, request);
}

int32_t le_engine_read_request_result(le_engine* e, uint64_t request,
                                      int32_t* result) {
  if (!e || !request || !result) return LE_ERR_INVALID;
  for (int i = 0; i < LE_RING_CAPACITY; ++i) {
    if (e->receipts[i].request != request) continue;
    if (e->receipts[i].command > atomic_load_explicit(
          &e->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
    *result = atomic_load_explicit(&e->receipts[i].result, memory_order_relaxed);
    e->receipts[i].request = 0;
    return LE_OK;
  }
  return LE_ERR_INVALID;
}

int32_t le_engine_set_record_offset(le_engine* engine, int32_t frames) {
  return le_push(engine, LE_CMD_SET_RECORD_OFFSET, frames, 0.0f);
}

int le_record_timing_valid(const le_record_timing_settings* v) {
  if (!v || v->default_timing < 0 || v->default_timing > 6 ||
      v->remembered_division < 0 || v->remembered_division > 5 ||
      (v->edit_mask & ~0x1ffu) ||
      (v->default_timing > 0 && v->remembered_division != v->default_timing - 1)) return 0;
  for (int c = 0; c < LE_MAX_TRACKS; ++c)
    if (v->track_timing[c] < -1 || v->track_timing[c] > 6) return 0;
  return 1;
}

int32_t le_engine_set_record_timing_settings(
    le_engine* e, const le_record_timing_settings* v) {
  if (!e || !le_record_timing_valid(v)) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (e->record_timing_command != 0 && e->record_timing_command >
      atomic_load_explicit(&e->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  const le_record_timing_readback prior = le_record_timing_read(e, 0);
  if (!(v->edit_mask & 1u) &&
      (prior.default_timing != v->default_timing ||
       prior.remembered_division != v->remembered_division)) return LE_ERR_INVALID;
  for (int c = 0; c < LE_MAX_TRACKS; ++c) {
    if (!(v->edit_mask & (2u << c)) && prior.track_timing[c] != v->track_timing[c]) return LE_ERR_INVALID;
    if (c < e->track_count) {
      const int state = le_effective_state(&e->tracks[c]);
      if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) return LE_ERR_INVALID;
    }
  }
  const uint32_t revision = e->record_timing_posted_revision + 2u;
  const le_command command = {.code = LE_CMD_SET_RECORD_TIMING,
    .timing = {.settings = *v, .revision = revision}};
  const int32_t result = le_push_cmd(e, command);
  if (result == LE_OK) {
    e->record_timing_posted_revision = revision;
    e->record_timing_command = e->commands_posted;
  }
  return result;
}


int32_t le_engine_cancel_arm(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  /* Always publish: a launch may be queued ahead of us but not yet visible
   * in the polled snapshot. DISARM is cancellation-only, so it cannot stop old
   * playback/capture or erase audio, and cannot consume a later FIFO request. */
  const int result = le_push(engine, LE_CMD_DISARM, channel, 0.0f);
  if (result == LE_OK) {
    engine->armed[channel] = 0;
    le_ticket_launch_cancel(engine, channel);
  }
  return result;
}

/* Every track a count-in cancellation can reach: each one in its launch grace
 * is emptied by handle_record when the cancellation applies. */
static void le_ticket_grace_cohort(le_engine* engine) {
  for (int32_t c = 0; c < engine->track_count; ++c) le_ticket_launch_cancel(engine, c);
}

int32_t le_engine_cancel_count_in(le_engine* engine) {
  const int32_t rc = le_push(engine, LE_CMD_CANCEL_COUNT_IN, 0, 0.0f);
  if (rc == LE_OK) le_ticket_grace_cohort(engine);
  return rc;
}

int32_t le_engine_stop_record_control(le_engine* engine, int32_t channel) {
  if (!engine || channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire))
    return LE_ERR_NOT_RUNNING;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  const int state = le_effective_state(t);
  int action = 0; /* immediate capture finish; callback never acquires */
  int cohort = load_i32(&engine->a_counting_in);
  for (int c = 0; c < engine->track_count; ++c)
    cohort |= load_i32(&engine->tracks[c].a_launch_grace);
#ifdef LE_NATIVE_TESTS
  if (le_test_stop_record_hook) le_test_stop_record_hook(engine, 1);
#endif
  /* A Stop that saw a countdown (or its launch grace) means "cancel the
   * cohort", never "finish a capture": post the cancel itself, so one that
   * lands after the commit and grace is a no-op instead of finalizing the
   * just-started defining take into a tiny master. */
  if (cohort) return le_engine_cancel_count_in(engine);
  if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) {
    const int quantized = le_effective_quantize(engine, channel) &&
        le_rig_effective_master_len(engine) > 0 && le_transport_active(engine);
    const int pending = engine->armed[channel] && load_i32(&t->a_pending);
    if (pending && (quantized ? engine->armed_trigger[channel] != 0
                              : engine->armed_trigger[channel] == 2))
      return LE_ERR_INVALID;
    if (quantized) action = pending ? 2 : 1;
  }
  const int result = le_push(engine, LE_CMD_STOP_RECORD_CONTROL, channel, (float)action);
  if (result == LE_OK && action) {
    engine->armed[channel] = action == 1;
    engine->armed_trigger[channel] = 0;
  }
  if (result == LE_OK) {
    /* Either half can empty a track: the count-in cancellation sweeps every
     * grace take, the finish may close a void take on this channel. */
    le_ticket_grace_cohort(engine);
    le_ticket_emptying(engine, channel);
  }
  return result;
}

int32_t le_engine_finalize_take(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  if (le_effective_state(t) != LE_TRACK_RECORDING) return LE_ERR_INVALID;
  /* The DEFINING take (nothing else holds the grid) is refused: finalizing it
   * here would let this call — in the app, a mode switch — set the session's
   * bar length to wherever the player happened to be mid-gesture. Same
   * question le_engine_record answers when it decides whether a fresh take
   * redefines the grid, asked from the other side; the master-length check is
   * the belt for the internal-CLEAR window where the published master has not
   * caught up with a grid redefinition already riding the ring. */
  if (load_i32(&engine->a_master_len) <= 0 ||
      !le_grid_still_needed(engine, channel)) {
    return LE_ERR_INVALID;
  }
  /* A LIVE pending arm on this channel — any trigger — belongs to another
   * command (B3b: armed[]/armed_trigger[] is shared across every arm-capable
   * command) and is refused, not consumed: the caller must retire it first
   * (le_engine_cancel_arm, which the app's FX entry already runs before this).
   * Finalizing under it would leave the arm to fire onto the settled loop as
   * a punch-in the user never asked for. A spent arm (already fired; the
   * published pending flag reads 0) is no obstacle — and armed[] is left
   * untouched either way, so this command provably cannot cancel anyone's
   * arm. */
  if (engine->armed[channel] && load_i32(&t->a_pending) != 0) {
    return LE_ERR_INVALID;
  }
  const int32_t rc = le_push(engine, LE_CMD_FINALIZE_TAKE, channel, 0.0f);
  if (rc == LE_OK) le_ticket_emptying(engine, channel); /* void take -> EMPTY */
  return rc;
}



/* ---- tempo grid (state + locks; see segno_engine_api.h's tempo section) ----
 * Plain le_push producers: validation that needs no engine state runs here on
 * the control thread; the D6 tempo lock is enforced on the AUDIO thread
 * (apply_command), the only side that owns track states — a locked command is
 * accepted by these wrappers and dropped there. */

int32_t le_engine_set_tempo(le_engine* engine, float bpm) {
  /* Clamped to 30..300 by the audio thread on apply (matching the old stack's
   * observable clamp-on-read behaviour). */
  return le_push(engine, LE_CMD_SET_TEMPO, 0, bpm);
}

int32_t le_engine_restore_tempo(le_engine* engine, float bpm, int32_t source) {
  if (engine == NULL || !le_restored_tempo_valid(bpm, source)) {
    return LE_ERR_INVALID;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (load_i32(&engine->a_counting_in) ||
      engine->clock_commands_posted !=
          atomic_load_explicit(&engine->a_clock_commands_applied,
                               memory_order_acquire)) return LE_ERR_NOT_READY;
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* t = &engine->tracks[c];
    const int32_t state = le_effective_state(t);
    if (state == LE_TRACK_PLAYING || state == LE_TRACK_RECORDING ||
        state == LE_TRACK_OVERDUBBING || engine->armed[c] ||
        load_i32(&t->a_pending) || t->cancel_pending ||
        t->clear_restore_pending ||
        t->state_cmds_posted !=
            atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
      return LE_ERR_NOT_READY;
    }
  }
  return le_push(engine, LE_CMD_RESTORE_TEMPO, source, bpm);
}

int32_t le_engine_set_time_signature(le_engine* engine, int32_t num,
                                     int32_t den) {
  /* Reject unsupported signatures outright (the audio thread re-validates so
   * a raw post_command cannot sneak one through either). */
  if (!le_grid_signature_valid(num, den)) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_TIME_SIGNATURE, num, (float)den);
}

int32_t le_engine_tap_tempo(le_engine* engine) {
  return le_push(engine, LE_CMD_TAP_TEMPO, 0, 0.0f);
}

int32_t le_engine_set_sync_tempo(le_engine* engine, int32_t on) {
  return le_push(engine, LE_CMD_SET_SYNC_TEMPO, 0, on ? 1.0f : 0.0f);
}


/* ---- looper mode (B2a, D4; see segno_engine_api.h's looper-mode section) ----
 * Control validates effective transport and spans before posting. The audio
 * thread rechecks the actual state and spans before applying, because earlier
 * queued commands can change the rig after this gate accepts the request. */

/* Whether the recorded spans fit [mode] as they are (accepted design, slice
 * 2), measured against le_mode_base_channel's base: MULTI needs whole
 * multiples of the shortest take; SYNC/BAND need whole multiples of the
 * primary or the divisions the engine plays (1/2, 1/4); SONG/FREE take
 * anything. */
/* The control thread's base pick, and the span it picked, from ONE read each.
 *
 * Two things separate it from [le_mode_base_channel], which the audio thread
 * shares. It measures [le_effective_len], so a restore or an emptying that is
 * posted but not yet applied is measured as the audio thread will find it —
 * the gate and the switch then agree instead of one accepting spans the other
 * re-clocks. And it hands back the length it chose, so the caller cannot
 * re-read a field the audio thread may have zeroed in between: that second
 * read is what made `len % base` a division by zero during the two writes
 * handle_clear's freeze path does in one block.
 *
 * Returns the channel, or -1 when nothing is recorded; *out_len carries its
 * length and is 0 in that case. */
static int32_t le_ctl_mode_base(le_engine* engine, int32_t mode,
                                int32_t* out_len) {
  *out_len = 0;
  if (mode == LE_LOOPER_MODE_MULTI) {
    int32_t best = -1;
    int32_t best_len = 0;
    for (int32_t c = 0; c < engine->track_count; ++c) {
      const int32_t len = le_effective_len(&engine->tracks[c]);
      if (len <= 0) continue;
      if (best < 0 || len < best_len) {
        best = c;
        best_len = len;
      }
    }
    *out_len = best_len;
    return best;
  }
  const int32_t crowned = load_i32(&engine->a_primary_track);
  if (crowned >= 0 && crowned < engine->track_count) {
    const int32_t len = le_effective_len(&engine->tracks[crowned]);
    if (len > 0) {
      *out_len = len;
      return crowned;
    }
  }
  for (int32_t c = 0; c < engine->track_count; ++c) {
    const int32_t len = le_effective_len(&engine->tracks[c]);
    if (len > 0) {
      *out_len = len;
      return c;
    }
  }
  return -1;
}

static int le_spans_fit_mode(le_engine* engine, int32_t mode) {
  if (mode == LE_LOOPER_MODE_SONG || mode == LE_LOOPER_MODE_FREE) return 1;
  int32_t base = 0;
  const int32_t base_ch = le_ctl_mode_base(engine, mode, &base);
  if (base_ch < 0 || base <= 0) return 1; /* an empty rig fits every mode */
  for (int32_t c = 0; c < engine->track_count; ++c) {
    const int32_t len = le_effective_len(&engine->tracks[c]);
    if (!le_mode_span_fits(mode, base, len)) return 0;
  }
  return 1;
}

int32_t le_engine_looper_mode_gate(le_engine* engine, int32_t mode) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (mode < LE_LOOPER_MODE_MULTI || mode > LE_LOOPER_MODE_FREE) {
    return LE_ERR_INVALID;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (mode == load_i32(&engine->a_looper_mode)) return LE_MODE_GATE_OPEN;
  le_engine_drain_events(engine);
  if (load_i32(&engine->a_counting_in)) return LE_MODE_GATE_CAPTURING;
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* t = &engine->tracks[c];
    const int32_t st = le_effective_state(t);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
        atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
      return LE_MODE_GATE_CAPTURING;
    }
  }
  for (int32_t c = 0; c < engine->track_count; ++c) {
    /* EITHER, not both. The audio thread blocks the switch on pending_record
     * alone, so an arm posted but not yet applied — armed here, not yet
     * published there — would pass a both-sides test and then be dropped on
     * the audio thread with the caller already told LE_OK. The reverse pair
     * (a disarm posted but not applied) reports QUEUED for the length of one
     * block; a refusal the next poll clears beats a switch that vanishes. */
    if (engine->armed[c] || load_i32(&engine->tracks[c].a_pending)) {
      return LE_MODE_GATE_QUEUED;
    }
  }
  if (!le_spans_fit_mode(engine, mode)) return LE_MODE_GATE_SPANS;
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* t = &engine->tracks[c];
    /* Effective on BOTH halves: le_restore_clear does not publish the length
     * it restores, so a raw read here reports a restored-but-unapplied track
     * as empty and the switch lands on spans this gate never measured. */
    if (le_effective_state(t) == LE_TRACK_PLAYING && le_effective_len(t) > 0) {
      return LE_MODE_GATE_PLAYING;
    }
  }
  return LE_MODE_GATE_OPEN;
}

static int32_t le_post_clock_command(le_engine* engine, int32_t code,
                                       int32_t value) {
  uint32_t sequence = engine->clock_commands_posted + 1;
  if (sequence == 0) sequence = 1; /* zero belongs to raw, untracked commands */
  const int32_t rc = le_push_cmd(engine, (le_command){.code = code,
                                                     .clock = {value, sequence}});
  if (rc == LE_OK) engine->clock_commands_posted = sequence;
  return rc;
}

static int32_t le_post_mode_with_presets(le_engine* engine, int32_t mode,
                                          const int32_t* bars, int32_t count) {
  const int32_t gate = le_engine_looper_mode_gate(engine, mode);
  if (gate < 0) return gate;
  if (gate == LE_MODE_GATE_CAPTURING || gate == LE_MODE_GATE_QUEUED ||
      gate == LE_MODE_GATE_SPANS) return LE_ERR_INVALID;
  if (count == 0 && mode == load_i32(&engine->a_looper_mode)) return LE_OK;
  uint32_t sequence = engine->clock_commands_posted + 1;
  if (sequence == 0) sequence = 1;
  le_command cmd = {.code = LE_CMD_SET_LOOPER_MODE,
                    .presets = {.mode = mode, .sequence = sequence,
                                .count = count}};
  if (count > 0) memcpy(cmd.presets.bars, bars, (size_t)count * sizeof(*bars));
  const int32_t result = le_push_cmd(engine, cmd);
  if (result == LE_OK) engine->clock_commands_posted = sequence;
  return result;
}

int32_t le_engine_set_looper_mode(le_engine* engine, int32_t mode) {
  return le_post_mode_with_presets(engine, mode, NULL, 0);
}

int32_t le_engine_set_looper_mode_with_presets(
    le_engine* engine, int32_t mode, const int32_t* bars, int32_t count) {
  const int32_t result = le_length_presets_check(engine, bars, count);
  if (result != LE_OK) return result;
  return le_post_mode_with_presets(engine, mode, bars, count);
}

/* ---- primary track / Sync + Band (B3/B3b, D16/D18) ---- */

int32_t le_engine_crown_primary(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_post_clock_command(engine, LE_CMD_CROWN_PRIMARY, channel);
}

/* One Shot is a live setting in every mode; the callback owns its pass edge. */

int32_t le_engine_set_one_shot(le_engine* engine, int32_t channel,
                               int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_ONE_SHOT, channel, enabled ? 1.0f : 0.0f);
}

int32_t le_engine_set_one_shot_mask(le_engine* engine, uint32_t channels,
                                    int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  const uint32_t valid = (1u << engine->track_count) - 1u;
  if (channels == 0 || (channels & ~valid) != 0) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_ONE_SHOT_MASK, (int32_t)channels,
                 enabled ? 1.0f : 0.0f);
}

/* Reuses le_engine_record's own quantize-arm TOGGLE shape (armed[] /
 * armed_trigger[], LE_CMD_ARM/DISARM) with trigger 2 instead of inventing
 * parallel bookkeeping. B3b BUG 2 (adversarial review): armed[]/
 * armed_trigger[] is shared with le_engine_record's own trigger-0/1 arms —
 * "a section-transport arm and a record arm can never coexist on the same
 * channel" is true only because BOTH sides now check armed_trigger[]
 * before treating a live arm as their own to cancel (see this function's
 * body and le_engine_record's two arm-check branches + its Immediate path)
 * — a DIFFERENT trigger's pending arm is rejected, never silently
 * cancelled. */
int32_t le_engine_toggle_section(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (load_i32(&engine->a_looper_mode) != LE_LOOPER_MODE_BAND) {
    return LE_ERR_INVALID;
  }
  const int32_t primary = load_i32(&engine->a_primary_track);
  if (primary < 0 || channel == primary) return LE_ERR_INVALID;
  /* B3b BUG 1 (adversarial review): every other primary-relative decision
   * in B3/B3b consults le_sync_quantize_active before trusting e->clock as
   * "the primary's cycle" — this entry point didn't. Without an
   * established primary, D16's own fallback applies: whoever records
   * first defines e->clock, which may be a NON-primary track (the crowned
   * primary itself might still be EMPTY). Arming trigger 2 in that state
   * would fire against that other track's own clock at its own loop top,
   * not "the primary's" — directly contradicting this function's
   * documented guarantee. Reject instead: section-transport is meaningless
   * without an established primary reference. */
  if (!le_sync_quantize_active(engine, channel)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (!le_transport_active(engine)) {
    /* The transport is HELD (every track stopped/empty): the primary's
     * clock never ticks then, so a deferred arm would never fire — the
     * same deadlock le_engine_record's quantize branch avoids for record
     * arms (see its comment above). The held position IS the primary's
     * loop top by definition, so act immediately instead of arming. */
    const int32_t rc = le_push(
        engine, st == LE_TRACK_STOPPED ? LE_CMD_PLAY : LE_CMD_STOP, channel, 0.0f);
    if (rc == LE_OK && st == LE_TRACK_RECORDING) {
      le_ticket_emptying(engine, channel); /* void take -> EMPTY */
    }
    return rc;
  }
  if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
    engine->armed[channel] = 0; /* spent: the boundary already fired it */
  }
  if (engine->armed[channel]) {
    /* B3b BUG 2 (adversarial review): reject rather than cancel a
     * DIFFERENT trigger's pending arm (le_engine_record's quantize arm,
     * trigger 0, or its auto-record arm, trigger 1) — see this function's
     * header doc. */
    if (engine->armed_trigger[channel] != 2) return LE_ERR_INVALID;
    /* Second call before the boundary fires cancels the pending toggle. */
    engine->armed[channel] = 0;
    return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
  }
  engine->armed[channel] = 1;
  engine->armed_trigger[channel] = 2; /* Band section-transport trigger */
  const int32_t rc = le_push(engine, LE_CMD_ARM, channel, 2.0f);
  /* The fired toggle stops a RECORDING take (le_fire_section_arm): a void one
   * empties. Covers the ARM's block; the firing block is autonomous. */
  if (rc == LE_OK && st == LE_TRACK_RECORDING) le_ticket_emptying(engine, channel);
  return rc;
}

/* ---- MIDI clock (Phase C/E, D15; see segno_engine_api.h's MIDI-clock
 * section) ---- */

int32_t le_engine_set_clock_mode(le_engine* engine, int32_t mode) {
  /* RECEIVE is Phase E's clock follower — stub the tri-state field now (so
   * that part can reuse it without a breaking rename) but reject it here,
   * same as any value outside the enum. */
  if (mode != LE_CLOCK_OFF && mode != LE_CLOCK_SEND) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_CLOCK_MODE, mode, 0.0f);
}

/* ---- click + count-in (A2; see segno_engine_api.h's click section) ---- */

int32_t le_engine_set_click_mode(le_engine* engine, int32_t mode) {
  if (!engine || mode < LE_CLICK_OFF || mode > LE_CLICK_PLAY_REC) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (engine->click_mode_command != 0 && engine->click_mode_command >
      atomic_load_explicit(&engine->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  for (int c = 0; c < engine->track_count; ++c) {
    const int state = load_i32(&engine->tracks[c].a_state);
    if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) return LE_ERR_INVALID;
  }
  const uint32_t revision = engine->click_mode_posted_revision + 1u;
  const int32_t result = le_push_cmd(engine, (le_command){
      .code = LE_CMD_SET_CLICK_MODE, .click = {.mode = mode, .revision = revision}});
  if (result == LE_OK) {
    engine->click_mode_posted_revision = revision;
    engine->click_mode_command = engine->commands_posted;
  }
  return result;
}

int32_t le_engine_set_click_output(le_engine* engine, int32_t mask) {
  /* trackmask arm (channel unused) so all 32 mask bits round-trip exactly,
   * like the other mask commands. Bits beyond the negotiated output range are
   * simply never summed into. */
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_CLICK_OUTPUT,
                                          .trackmask = {0, (uint32_t)mask}});
}

int32_t le_engine_set_click_volume(le_engine* engine, float volume) {
  /* Clamped to 0..LE_MAX_GAIN by the audio thread on apply (the SET_VOLUME
   * pattern). */
  return le_push(engine, LE_CMD_SET_CLICK_VOLUME, 0, volume);
}

int32_t le_engine_set_record_start(le_engine* engine, int32_t bars,
                                    int32_t sound_start, int32_t edit_kind) {
  if (!engine || (bars != 0 && bars != 1 && bars != 2 && bars != 4) ||
      (sound_start != 0 && sound_start != 1) || (bars > 0 && sound_start) ||
      edit_kind < LE_RECORD_START_COUNT_IN || edit_kind > LE_RECORD_START_RESTORE)
    return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) return LE_ERR_NOT_RUNNING;
  if (engine->record_start_command > atomic_load_explicit(
          &engine->a_commands_published, memory_order_acquire)) return LE_ERR_NOT_READY;
  for (int c = 0; c < engine->track_count; ++c) {
    const int state = load_i32(&engine->tracks[c].a_state);
    if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) return LE_ERR_INVALID;
  }
  const uint32_t revision = engine->record_start_posted_revision + 1u;
  const int32_t result = le_push_cmd(engine, (le_command){
      .code = LE_CMD_SET_RECORD_START,
      .record_start = {sound_start ? -1 : bars, edit_kind, revision}});
  if (result == LE_OK) {
    engine->record_start_posted_revision = revision;
    engine->record_start_command = engine->commands_posted;
  }
  return result;
}

int32_t le_engine_set_track_multiple(le_engine* engine, int32_t channel,
                                     int32_t multiple) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  /* 0 = inherit the global default; >= 1 fixes the next recording to that many
   * base loops. Applies to the next finalize; existing content is unchanged. */
  engine->target_multiple[channel] = multiple < 0 ? 0 : multiple;
  return LE_OK;
}

int32_t le_engine_set_default_multiple(le_engine* engine, int32_t multiple) {
  if (engine == NULL) return LE_ERR_INVALID;
  /* 0 = auto (round up on stop); >= 1 fixes inheriting tracks to K base loops. */
  engine->default_multiple = multiple < 0 ? 0 : multiple;
  return LE_OK;
}

/* ---- track length presets (A6, D17; see segno_engine_api.h's section doc for
 * the full preset x click-mode matrix) ---- */

static int32_t le_length_preset_check(le_engine* engine, int32_t bars) {
  if (bars < 0 || bars > LE_LENGTH_PRESET_MAX_BARS) return LE_ERR_INVALID;
  if (bars > 0) {
    /* D17 allocation guard: `bars` bars of the CURRENT time signature at the
     * slowest possible tempo (30 BPM, LE_GRID_TEMPO_MIN) must fit within
     * max_loop_frames — checked here, before recording starts, rather than
     * discovered mid-take. Any signature is possible pre-lock, so this reads
     * the signature live rather than assuming 4/4. A tempo at or above 30 BPM
     * (the engine's floor) only ever needs FEWER frames per bar, so passing
     * this check at 30 BPM guarantees every reachable actual tempo fits too. */
    int32_t num = load_i32(&engine->a_ts_num);
    if (num <= 0) num = 4;
    const int32_t sr = engine->sample_rate > 0 ? engine->sample_rate : 48000;
    const le_tempo_grid worst = {LE_GRID_TEMPO_MIN, num,
                                 load_i32(&engine->a_ts_den), sr};
    const double fpbar = le_grid_frames_per_bar(&worst);
    if (fpbar > 0.0 && (double)bars * fpbar > (double)engine->max_loop_frames) {
      return LE_ERR_CAPACITY;
    }
  }
  return LE_OK;
}

int32_t le_length_presets_check(le_engine* engine, const int32_t* bars,
                               int32_t count) {
  if (engine == NULL || bars == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (count != engine->track_count || count <= 0 || count > LE_MAX_TRACKS) {
    return LE_ERR_INVALID;
  }
  /* Recheck at callback consumption too: capture can begin after enqueue.
   * A vector controls future recordings and must not change during capture. */
  for (int32_t c = 0; c < count; ++c) {
    const int32_t state = atomic_load_explicit(
        &engine->tracks[c].a_state, memory_order_acquire);
    if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) {
      return LE_ERR_INVALID;
    }
  }
  for (int32_t c = 0; c < count; ++c) {
    const int32_t result = le_length_preset_check(engine, bars[c]);
    if (result != LE_OK) return result;
  }
  return LE_OK;
}

int32_t le_engine_set_track_length_preset(le_engine* engine, int32_t channel,
                                         int32_t bars) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  const int32_t result = le_length_preset_check(engine, bars);
  if (result != LE_OK) return result;
  return le_push(engine, LE_CMD_SET_LENGTH_PRESET, channel, (float)bars);
}

int32_t le_engine_set_track_length_presets(
    le_engine* engine, const int32_t* bars, int32_t count) {
  const int32_t result = le_length_presets_check(engine, bars, count);
  if (result != LE_OK) return result;
  le_command cmd = {.code = LE_CMD_SET_LENGTH_PRESETS,
                    .presets = {.count = count}};
  memcpy(cmd.presets.bars, bars, (size_t)count * sizeof(*bars));
  return le_push_cmd(engine, cmd);
}

int32_t le_engine_set_rec_dub(le_engine* engine, int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  engine->rec_dub = enabled ? 1 : 0;
  return LE_OK;
}

int32_t le_engine_set_master_gain(le_engine* engine, float gain) {
  /* Posted through the ring (drained on the audio thread, which clamps to 0..1
   * and publishes to a_master_gain_bits) so it orders with the rest of the
   * command stream, exactly like le_engine_set_track_volume. */
  return le_push(engine, LE_CMD_SET_MASTER_GAIN, 0, gain);
}

int32_t le_engine_set_tuner_input(le_engine* engine, int32_t input) {
  if (engine == NULL) return LE_ERR_INVALID;
  /* Posted through the ring so arming orders with the rest of the command
   * stream; the audio thread validates the channel against what the device
   * actually negotiated and resets the analysis state on every change. */
  return le_push(engine, LE_CMD_SET_TUNER_INPUT, input, 0.0f);
}

int32_t le_engine_set_limiter(le_engine* engine, int32_t enabled,
                              float ceiling) {
  if (engine == NULL) return LE_ERR_INVALID;
  /* Independent published atomics (no ordering vs. the command stream), so the
   * control thread stores them directly. Clamp the ceiling to a sane (0,1]. */
  if (ceiling <= 0.0f) ceiling = 0.99f;
  if (ceiling > 1.0f) ceiling = 1.0f;
  store_f32(&engine->a_limiter_ceiling_bits, ceiling);
  store_i32(&engine->a_limiter_enabled, enabled ? 1 : 0);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_LIMITER,
                                        .arg_i = enabled ? 1 : 0,
                                        .arg_f = ceiling});
  return LE_OK;
}

int32_t le_engine_set_overdub_feedback(le_engine* engine, float feedback) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (feedback < 0.0f) feedback = 0.0f;
  if (feedback > 1.0f) feedback = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, feedback);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_OVERDUB_FEEDBACK,
                                        .arg_f = feedback});
  return LE_OK;
}

int32_t le_engine_set_track_overdub_feedback(le_engine* engine,
                                             int32_t channel, float feedback) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (feedback < 0.0f) {
    feedback = -1.0f; /* inherit */
  } else if (feedback > 1.0f) {
    feedback = 1.0f;
  }
  store_f32(&engine->tracks[channel].a_overdub_fb_bits, feedback);
  le_plog_push_ctrl(engine,
                    (le_command){.code = LE_PLOG_SET_TRACK_OVERDUB_FEEDBACK,
                                 .arg_i = channel,
                                 .arg_f = feedback});
  return LE_OK;
}

/* Prepares a chain entry for [type]: lazily allocates its heap buffers and,
 * only when the type ACTUALLY changes (so a reorder does not wipe the user's
 * tweaks), seeds the type's default params. "Actually changes" is judged
 * against [type_pushed] — the control thread's shadow of the last
 * successfully pushed type — NOT the audio-published a_fx_type, which is
 * stale whenever the ring has not drained (device stopped, or two pushes in
 * one buffer) and would make a same-type re-push read as a change. The
 * change verdict is returned via [out_changed] so the caller can apply the
 * D-ENSEED enabled re-seed AFTER its ring push succeeds (a freshly placed
 * effect starts enabled — a stale disabled flag must never silently mute a
 * recycled slot; the same-type remove-then-re-add path is covered by
 * le_fx_seed_entering_slots in the count setters below). The per-type
 * allocation and defaults live behind the effect vtable (engine_fx.c:
 * le_fx_prepare / le_fx_defaults), so this stays generic — adding an effect
 * needs no edit here. Returns LE_OK, or LE_ERR_INVALID on allocation failure
 * (buffers left as they were). */
static int32_t le_fx_prepare_entry(le_fx_state* fx, const int32_t* type_pushed,
                                   _Atomic uint32_t a_param[][LE_FX_PARAMS],
                                   int32_t index, int32_t type,
                                   int32_t delay_cap, int32_t* out_changed) {
  const int32_t cap = delay_cap > 0 ? delay_cap : 48000;
  if (le_fx_prepare(fx, index, type, cap) != LE_OK) return LE_ERR_INVALID;
  *out_changed = type_pushed[index] != type;
  if (*out_changed) {
    float defaults[LE_FX_PARAMS];
    le_fx_defaults(type, defaults);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&a_param[index][p], defaults[p]);
    }
  }
  return LE_OK;
}

int32_t le_engine_set_lane_fx(le_engine* engine, int32_t channel, int32_t lane,
                              int32_t index, int32_t type) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t changed = 0;
  if (le_fx_prepare_entry(&ln->fx, ln->fx_type_pushed, ln->a_fx_param, index,
                          type, engine->fx_delay_frames, &changed) != LE_OK) {
    return LE_ERR_INVALID;
  }
  /* Publish the type via the ring so the audio thread resets the entry's DSP
   * state in lockstep. The delay pointer written above is made visible to the
   * audio thread by the ring's release/acquire pairing. The pushed-type
   * shadow and the D-ENSEED enabled re-seed apply only on a SUCCESSFUL push
   * — a rejected command must not leave a durable flag mutation behind. */
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_FX,
                                       .fx = {channel, lane, index, type}});
  if (rc == LE_OK) {
    ln->fx_type_pushed[index] = type;
    if (changed) store_i32(&ln->a_fx_enabled[index], 1);
    le_lane_fx_gen_bump(ln); /* chain identity moved (wet-cache fast path) */
  }
  return rc;
}

/* D-ENSEED's second half: a slot ENTERING the active window starts enabled.
 * The type-change re-seed (le_fx_prepare_entry) alone would leave a trap: a
 * remove-then-re-add of the SAME type only shrinks and regrows the count, so
 * a disabled flag left on the recycled slot would silently mute it. The
 * entering range comes from [count_pushed] — the control thread's shadow of
 * the last successfully pushed count — NOT the audio-published a_fx_count,
 * which is stale on an undrained ring and would make the seed clobber user
 * disables or miss recycled slots. Called only AFTER the count command was
 * accepted by the ring, so a rejected push mutates nothing; the offline
 * replay mirrors this on its strictly ordered replayed count
 * (perf_render.c). */
static void le_fx_seed_entering_slots(int32_t* count_pushed,
                                      _Atomic int32_t* a_enabled,
                                      int32_t new_count) {
  int32_t cur = *count_pushed;
  if (cur < 0) cur = 0;
  if (cur > LE_FX_MAX) cur = LE_FX_MAX;
  for (int32_t s = cur; s < new_count; ++s) store_i32(a_enabled + s, 1);
  *count_pushed = new_count;
}

int32_t le_engine_set_lane_fx_count(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t count,
                                    int32_t pre_count) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  /* Clamped against the count it travels with, never against the published
   * one: a Pre run longer than its chain would have the audio thread render
   * entries that are not there and the wet cache key a prefix that cannot be
   * rebuilt. */
  if (pre_count < 0) pre_count = 0;
  if (pre_count > count) pre_count = count;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_SET_LANE_FX_COUNT,
                           .fxcount = {channel, lane, count, pre_count}});
  if (rc == LE_OK) {
    le_fx_seed_entering_slots(&ln->fx_count_pushed, ln->a_fx_enabled, count);
    le_lane_fx_gen_bump(ln); /* chain identity moved (wet-cache fast path) */
  }
  return rc;
}

int32_t le_engine_set_lane_fx_param(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t index, int32_t param,
                                    float value) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  /* Params are plain published atomics read once per buffer; a direct store is
   * race-free and needs no ring command (unlike the type, which also resets
   * audio-thread DSP state). Works whether or not the device is running. */
  store_f32(&engine->tracks[channel].lanes[lane].a_fx_param[index][param],
            value);
  le_lane_fx_gen_bump(&engine->tracks[channel].lanes[lane]);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_LANE_FX_PARAM,
                           .fx = {channel, lane,
                                  LE_PLOG_FX_PARAM_PACK(index, param),
                                  (int32_t)f32_to_bits(value)}});
  return LE_OK;
}

/* The enabled flips follow the params pattern exactly: plain published atomics
 * read once per buffer, so a direct store is race-free and needs no ring
 * command — they work whether or not the device is running. The click-free
 * crossfade happens on the audio thread when the per-buffer snapshot observes
 * the new effective bit (fx_apply_chain). */
int32_t le_engine_set_lane_fx_enabled(le_engine* engine, int32_t channel,
                                      int32_t lane, int32_t index,
                                      int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  const int32_t on = enabled ? 1 : 0;
  store_i32(&engine->tracks[channel].lanes[lane].a_fx_enabled[index], on);
  le_lane_fx_gen_bump(&engine->tracks[channel].lanes[lane]);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_LANE_FX_ENABLED,
                                        .fx = {channel, lane, index, on}});
  return LE_OK;
}

int32_t le_engine_set_lane_fx_chain_enabled(le_engine* engine, int32_t channel,
                                            int32_t lane, int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  const int32_t on = enabled ? 1 : 0;
  store_i32(&engine->tracks[channel].lanes[lane].a_fx_chain_enabled, on);
  le_lane_fx_gen_bump(&engine->tracks[channel].lanes[lane]);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_LANE_FX_CHAIN_ENABLED,
                           .lanef = {channel, lane, on ? 1.0f : 0.0f}});
  return LE_OK;
}

int32_t le_engine_set_monitor_input(le_engine* engine, int32_t input,
                                    int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT, input,
                 enabled ? 1.0f : 0.0f);
}

/* The single-chain monitor setters address the input only. Output rides the
 * typed `trackmask` arm (channel = input); volume/mute the generic
 * { arg_i = input, arg_f = value } arm; FX type/count the `fx` / `fxcount` arms
 * (channel = input, lane field unused). */
int32_t le_engine_set_monitor_input_output(le_engine* engine, int32_t input,
                                           int32_t mask) {
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_MONITOR_INPUT_OUTPUT,
                                  .trackmask = {input, (uint32_t)mask}});
}

int32_t le_engine_set_monitor_input_volume(le_engine* engine, int32_t input,
                                           float volume) {
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_VOLUME, input, volume);
}

int32_t le_engine_set_monitor_input_pan(le_engine* engine, int32_t input,
                                        float pan) {
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_MONITOR_INPUT_PAN,
                                          .lanef = {input, 0, pan}});
}

int32_t le_engine_set_monitor_input_mute(le_engine* engine, int32_t input,
                                         int32_t muted) {
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_MUTE, input,
                 muted ? 1.0f : 0.0f);
}

int32_t le_engine_set_monitor_input_fx(le_engine* engine, int32_t input,
                                       int32_t index, int32_t type) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_monitor_input* m = &engine->monitors[input];
  int32_t changed = 0;
  if (le_fx_prepare_entry(&m->fx, m->fx_type_pushed, m->a_fx_param, index,
                          type, engine->fx_delay_frames, &changed) != LE_OK) {
    return LE_ERR_INVALID;
  }
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_MONITOR_INPUT_FX,
                                       .fx = {input, 0, index, type}});
  if (rc == LE_OK) {
    m->fx_type_pushed[index] = type;
    if (changed) store_i32(&m->a_fx_enabled[index], 1);
  }
  return rc;
}

int32_t le_engine_set_monitor_input_fx_count(le_engine* engine, int32_t input,
                                             int32_t count) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  le_monitor_input* m = &engine->monitors[input];
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_MONITOR_INPUT_FX_COUNT,
                                       .fxcount = {input, 0, count, 0}});
  if (rc == LE_OK) {
    le_fx_seed_entering_slots(&m->fx_count_pushed, m->a_fx_enabled, count);
  }
  return rc;
}

int32_t le_engine_set_monitor_input_fx_param(le_engine* engine, int32_t input,
                                             int32_t index, int32_t param,
                                             float value) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->monitors[input].a_fx_param[index][param], value);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_MONITOR_FX_PARAM,
                           .fx = {input, -1,
                                  LE_PLOG_FX_PARAM_PACK(index, param),
                                  (int32_t)f32_to_bits(value)}});
  return LE_OK;
}

/* Monitor twins of the lane enabled setters (same direct-atomic pattern; the
 * per-slot event mirrors 307's lane = -1 convention, the chain event the
 * generic monitor volume/mute shape). */
int32_t le_engine_set_monitor_input_fx_enabled(le_engine* engine, int32_t input,
                                               int32_t index, int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  const int32_t on = enabled ? 1 : 0;
  store_i32(&engine->monitors[input].a_fx_enabled[index], on);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_MONITOR_FX_ENABLED,
                                        .fx = {input, -1, index, on}});
  return LE_OK;
}

int32_t le_engine_set_monitor_input_fx_chain_enabled(le_engine* engine,
                                                     int32_t input,
                                                     int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  const int32_t on = enabled ? 1 : 0;
  store_i32(&engine->monitors[input].a_fx_chain_enabled, on);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED,
                           .arg_i = input,
                           .arg_f = on ? 1.0f : 0.0f});
  return LE_OK;
}

/* ---- Per-input conditioning stage (input conditioning, S1) ----
 * Both setters ride the ring (the per-input monitor command shape: the input
 * index in the addressed field, bounds vs LE_MAX_MONITORED_INPUTS) so the
 * audio thread — sole owner of the stage's biquad/envelope state — resets or
 * recomputes it in lockstep with the config change (an enable edge resets
 * state; a param change recomputes only its own section's coefficients).
 * Values are clamped by the audio thread on apply (le_cond_update_param);
 * the control side validates only addressing. NOT perf-logged: conditioning
 * is upstream of capture, so recorded PCM already embodies it. */

int32_t le_engine_set_input_conditioning(le_engine* engine, int32_t input,
                                         int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_INPUT_COND, input, enabled ? 1.0f : 0.0f);
}

int32_t le_engine_set_input_conditioning_param(le_engine* engine, int32_t input,
                                               int32_t param, float value) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (param < LE_COND_HPF_HZ || param > LE_COND_EXP_RELEASE_MS) {
    return LE_ERR_INVALID;
  }
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_INPUT_COND_PARAM,
                                  .lanef = {input, param, value}});
}

/* ---- Track-stage + output bus chains ----
 * The bus twins of the lane/monitor setter families above, on the two
 * le_fx_bus owners (le_track.bus / le_engine.outputs[k].fx, the Master
 * insert being bus 0's chain since slice 3b): type/count via the
 * ring (lockstep DSP reset on the audio thread), params + enable flags as
 * direct atomic stores (work while stopped), le_fx_prepare_entry's
 * control-thread allocation contract, and the same D-ENSEED pushed-shadow
 * discipline. Deliberately NO le_plog_push_ctrl anywhere here [R3]:
 * track/master chains are manifest-only per part 9's stems decision — the
 * arm manifest carries them from part 3, nothing replays them. */

int32_t le_engine_set_track_fx(le_engine* engine, int32_t channel,
                               int32_t index, int32_t type) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_fx_bus* b = &engine->tracks[channel].bus;
  int32_t changed = 0;
  if (le_fx_prepare_entry(&b->fx, b->fx_type_pushed, b->a_fx_param, index,
                          type, engine->fx_delay_frames, &changed) != LE_OK) {
    return LE_ERR_INVALID;
  }
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_TRACK_FX,
                                       .fx = {channel, 0, index, type}});
  if (rc == LE_OK) {
    b->fx_type_pushed[index] = type;
    if (changed) store_i32(&b->a_fx_enabled[index], 1);
  }
  return rc;
}

int32_t le_engine_set_track_fx_count(le_engine* engine, int32_t channel,
                                     int32_t count, int32_t pre_count) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  /* Clamped against the count it travels with, for the reason the lane's is:
   * a Pre run longer than its chain would have the render cover entries that
   * are not there. */
  if (pre_count < 0) pre_count = 0;
  if (pre_count > count) pre_count = count;
  le_fx_bus* b = &engine->tracks[channel].bus;
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_SET_TRACK_FX_COUNT,
                           .fxcount = {channel, 0, count, pre_count}});
  if (rc == LE_OK) {
    le_fx_seed_entering_slots(&b->fx_count_pushed, b->a_fx_enabled, count);
  }
  return rc;
}

int32_t le_engine_set_track_fx_param(le_engine* engine, int32_t channel,
                                     int32_t index, int32_t param,
                                     float value) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->tracks[channel].bus.a_fx_param[index][param], value);
  return LE_OK;
}

int32_t le_engine_set_track_fx_enabled(le_engine* engine, int32_t channel,
                                       int32_t index, int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  store_i32(&engine->tracks[channel].bus.a_fx_enabled[index],
            enabled ? 1 : 0);
  return LE_OK;
}

int32_t le_engine_set_track_fx_chain_enabled(le_engine* engine,
                                             int32_t channel,
                                             int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  store_i32(&engine->tracks[channel].bus.a_fx_chain_enabled, enabled ? 1 : 0);
  return LE_OK;
}

static int32_t le_output_bus_valid(int32_t bus) {
  return bus >= 0 && bus < LE_MAX_OUTPUT_BUSES;
}

int32_t le_engine_get_output_fx_snapshot(le_engine* engine, int32_t bus,
                                           le_output_fx_snapshot* out) {
  if (!engine || !out || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire) &&
      engine->perf.master_out_ch[0] / 2 == bus) {
    *out = engine->perf.output_fx;
    return LE_OK;
  }
  le_fx_bus* b = &engine->outputs[bus].fx;
  out->count = load_i32(&b->a_fx_count);
  out->chain_enabled = load_i32(&b->a_fx_chain_enabled);
  for (int i = 0; i < LE_FX_MAX; ++i) {
    out->type[i] = load_i32(&b->a_fx_type[i]);
    out->enabled[i] = load_i32(&b->a_fx_enabled[i]);
    for (int p = 0; p < LE_FX_PARAMS; ++p)
      out->params[i][p] = load_f32(&b->a_fx_param[i][p]);
  }
  return LE_OK;
}

int32_t le_engine_set_output_fx(le_engine* engine, int32_t bus, int32_t index,
                                int32_t type) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_fx_bus* b = &engine->outputs[bus].fx;
  int32_t changed = 0;
  if (le_fx_prepare_entry(&b->fx, b->fx_type_pushed, b->a_fx_param, index,
                          type, engine->fx_delay_frames, &changed) != LE_OK) {
    return LE_ERR_INVALID;
  }
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_FX,
                                       .fx = {bus, 0, index, type}});
  if (rc == LE_OK) {
    b->fx_type_pushed[index] = type;
    if (changed) store_i32(&b->a_fx_enabled[index], 1);
  }
  return rc;
}

int32_t le_engine_set_output_fx_count(le_engine* engine, int32_t bus,
                                      int32_t count) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  le_fx_bus* b = &engine->outputs[bus].fx;
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_FX_COUNT,
                                       .fxcount = {bus, 0, count, 0}});
  if (rc == LE_OK) {
    le_fx_seed_entering_slots(&b->fx_count_pushed, b->a_fx_enabled, count);
  }
  return rc;
}

int32_t le_engine_set_output_fx_param(le_engine* engine, int32_t bus,
                                      int32_t index, int32_t param,
                                      float value) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->outputs[bus].fx.a_fx_param[index][param], value);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_PARAM,
    .fx = {bus, 0, LE_PLOG_FX_PARAM_PACK(index, param), (int32_t)f32_to_bits(value)}});
  return LE_OK;
}

int32_t le_engine_set_output_fx_enabled(le_engine* engine, int32_t bus,
                                        int32_t index, int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  store_i32(&engine->outputs[bus].fx.a_fx_enabled[index], enabled ? 1 : 0);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_ENABLED,
    .fx = {bus, 0, index, enabled != 0}});
  return LE_OK;
}

int32_t le_engine_set_output_fx_chain_enabled(le_engine* engine, int32_t bus,
                                              int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  store_i32(&engine->outputs[bus].fx.a_fx_chain_enabled, enabled ? 1 : 0);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_CHAIN_ENABLED,
    .arg_i = bus, .arg_f = enabled != 0});
  return LE_OK;
}

/* ---- the All tracks recorded-mix chain (slice 3e) ----
 *
 * The output-bus setters' twin with one config and no bus argument. The only
 * real difference is the prepare: one shared chain drives one DSP instance
 * per output bus, so a type set has to allocate for every bus the configured
 * device has, and a failure on any of them leaves the type unpushed. */

/* Buses the configured device actually has. A type set prepares exactly
 * these, so a stereo interface allocates one instance's rings rather than
 * sixteen. A configure resets the chain (le_fx_bus_reset), and the repository
 * re-pushes it on the next start, so the instances are always prepared
 * against the device that is actually open. */
static int32_t le_all_tracks_bus_count(le_engine* engine) {
  int32_t n = (engine->out_channels + 1) / 2;
  if (n < 1) n = 1; /* an unconfigured engine still owns bus 0's instance */
  if (n > LE_MAX_OUTPUT_BUSES) n = LE_MAX_OUTPUT_BUSES;
  return n;
}

int32_t le_engine_set_all_tracks_fx(le_engine* engine, int32_t index,
                                    int32_t type) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  if (!le_record_capacity(engine, 1)) return LE_ERR_INVALID;
  le_fx_bus* b = &engine->all_tracks;
  const int32_t cap =
      engine->fx_delay_frames > 0 ? engine->fx_delay_frames : 48000;
  const int32_t buses = le_all_tracks_bus_count(engine);
  /* Every instance first: a half-prepared type would have one destination
   * play the effect and another play dry. */
  for (int32_t k = 0; k < buses; ++k) {
    if (le_fx_prepare(&engine->all_tracks_fx[k], index, type, cap) != LE_OK) {
      return LE_ERR_INVALID;
    }
  }
  const int32_t changed = b->fx_type_pushed[index] != type;
  if (changed) {
    float defaults[LE_FX_PARAMS];
    le_fx_defaults(type, defaults);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&b->a_fx_param[index][p], defaults[p]);
    }
  }
  const int32_t rc =
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_ALL_TRACKS_FX,
                                       .fx = {0, 0, index, type}});
  if (rc == LE_OK) {
    b->fx_type_pushed[index] = type;
    if (changed) store_i32(&b->a_fx_enabled[index], 1);
  }
  return rc;
}

int32_t le_engine_set_all_tracks_fx_count(le_engine* engine, int32_t count) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_SET_ALL_TRACKS_FX_COUNT,
                           .fxcount = {0, 0, count, 0}});
  if (rc == LE_OK) {
    le_fx_seed_entering_slots(&engine->all_tracks.fx_count_pushed,
                              engine->all_tracks.a_fx_enabled, count);
  }
  return rc;
}

int32_t le_engine_set_all_tracks_fx_param(le_engine* engine, int32_t index,
                                          int32_t param, float value) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->all_tracks.a_fx_param[index][param], value);
  return LE_OK;
}

int32_t le_engine_set_all_tracks_fx_enabled(le_engine* engine, int32_t index,
                                            int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  store_i32(&engine->all_tracks.a_fx_enabled[index], enabled ? 1 : 0);
  return LE_OK;
}

int32_t le_engine_set_all_tracks_fx_chain_enabled(le_engine* engine,
                                                  int32_t enabled) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  store_i32(&engine->all_tracks.a_fx_chain_enabled, enabled ? 1 : 0);
  return LE_OK;
}

/* ---- per-entry channel handling and level (slice 3e) ----
 *
 * The accepted design's rack input/output choices and rack level, on every
 * chain owner. Direct atomic publishes like the params: they change gain and
 * routing WITHIN an entry, never its DSP state, so there is nothing for the
 * audio thread to reset and no ring command to order against.
 *
 * The pan gains are precomputed here, exactly as a lane's are, so the
 * per-sample path is two multiplies. Centre is exact unity, so an entry left
 * alone is bit-identical to one with no channel handling at all.
 *
 * The five owners share one implementation, addressed by the published block;
 * the public wrappers below only resolve which block. */

/* Validate the complete tuple before any field is published. In particular,
 * a valid input choice cannot leak through a refused output choice. */
static int le_fx_channels_valid(int32_t index, int32_t in_mode, int32_t out_mode) {
  return index >= 0 && index < LE_FX_MAX &&
      in_mode >= LE_FX_CHAN_IN_STEREO && in_mode <= LE_FX_CHAN_IN_MONO &&
      out_mode >= LE_FX_CHAN_OUT_STEREO && out_mode <= LE_FX_CHAN_OUT_MONO;
}

static int32_t le_fx_chan_set_in(_Atomic int32_t* a_in, int32_t index,
                                 int32_t mode) {
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (mode < LE_FX_CHAN_IN_STEREO || mode > LE_FX_CHAN_IN_MONO) {
    return LE_ERR_INVALID;
  }
  store_i32(&a_in[index], mode);
  return LE_OK;
}

static int32_t le_fx_chan_set_out(_Atomic int32_t* a_out,
                                  _Atomic uint32_t* a_pan,
                                  _Atomic uint32_t* a_gl,
                                  _Atomic uint32_t* a_gr, int32_t index,
                                  int32_t mode, float placement) {
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (mode < LE_FX_CHAN_OUT_STEREO || mode > LE_FX_CHAN_OUT_MONO) {
    return LE_ERR_INVALID;
  }
  /* NaN reads as centre, the le_store_pan rule. */
  if (!(placement >= -1.0f)) placement = placement < -1.0f ? -1.0f : 0.0f;
  if (placement > 1.0f) placement = 1.0f;
  float gl;
  float gr;
  le_pan_gains(placement, &gl, &gr);
  store_f32(&a_gl[index], gl);
  store_f32(&a_gr[index], gr);
  store_f32(&a_pan[index], placement);
  store_i32(&a_out[index], mode);
  return LE_OK;
}

static int32_t le_fx_chan_set_level(_Atomic uint32_t* a_level, int32_t index,
                                    float level) {
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (!(level >= 0.0f)) level = 0.0f; /* NaN reads as silence */
  if (level > LE_MAX_GAIN) level = LE_MAX_GAIN;
  store_f32(&a_level[index], level);
  return LE_OK;
}

int32_t le_engine_set_lane_fx_channels(le_engine* engine, int32_t channel,
                                       int32_t lane, int32_t index,
                                       int32_t in_mode, int32_t out_mode,
                                       float placement, float level) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_LANE, channel, lane)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (!le_fx_channels_valid(index, in_mode, out_mode)) return LE_ERR_INVALID;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  const int32_t rc = le_fx_chan_set_in(ln->a_fx_chan_in, index, in_mode);
  if (rc != LE_OK) return rc;
  const int32_t rc2 =
      le_fx_chan_set_out(ln->a_fx_chan_out, ln->a_fx_chan_pan_bits,
                         ln->a_fx_chan_gl_bits, ln->a_fx_chan_gr_bits, index,
                         out_mode, placement);
  if (rc2 != LE_OK) return rc2;
  const int32_t rc3 =
      le_fx_chan_set_level(ln->a_fx_chan_level_bits, index, level);
  /* The channel handling is part of what the wet cache renders, so a change
   * moves the lane's chain identity like a param does. */
  if (rc3 == LE_OK) le_lane_fx_gen_bump(ln);
  return rc3;
}

int32_t le_engine_set_monitor_input_fx_channels(le_engine* engine,
                                                int32_t input, int32_t index,
                                                int32_t in_mode,
                                                int32_t out_mode,
                                                float placement, float level) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_MONITOR, input, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return LE_ERR_INVALID;
  if (!le_fx_channels_valid(index, in_mode, out_mode)) return LE_ERR_INVALID;
  le_monitor_input* m = &engine->monitors[input];
  const int32_t rc = le_fx_chan_set_in(m->a_fx_chan_in, index, in_mode);
  if (rc != LE_OK) return rc;
  const int32_t rc2 = le_fx_chan_set_out(
      m->a_fx_chan_out, m->a_fx_chan_pan_bits, m->a_fx_chan_gl_bits,
      m->a_fx_chan_gr_bits, index, out_mode, placement);
  if (rc2 != LE_OK) return rc2;
  return le_fx_chan_set_level(m->a_fx_chan_level_bits, index, level);
}

/* The three bus owners share one body; only the block differs. */
static int32_t le_fx_bus_set_channels(le_fx_bus* b, int32_t index,
                                      int32_t in_mode, int32_t out_mode,
                                      float placement, float level) {
  if (!le_fx_channels_valid(index, in_mode, out_mode)) return LE_ERR_INVALID;
  const int32_t rc = le_fx_chan_set_in(b->a_fx_chan_in, index, in_mode);
  if (rc != LE_OK) return rc;
  const int32_t rc2 = le_fx_chan_set_out(
      b->a_fx_chan_out, b->a_fx_chan_pan_bits, b->a_fx_chan_gl_bits,
      b->a_fx_chan_gr_bits, index, out_mode, placement);
  if (rc2 != LE_OK) return rc2;
  return le_fx_chan_set_level(b->a_fx_chan_level_bits, index, level);
}

int32_t le_engine_set_track_fx_channels(le_engine* engine, int32_t channel,
                                        int32_t index, int32_t in_mode,
                                        int32_t out_mode, float placement,
                                        float level) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_TRACK, channel, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_fx_bus_set_channels(&engine->tracks[channel].bus, index, in_mode,
                                out_mode, placement, level);
}

int32_t le_engine_set_output_fx_channels(le_engine* engine, int32_t bus,
                                         int32_t index, int32_t in_mode,
                                         int32_t out_mode, float placement,
                                         float level) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_OUTPUT, bus, 0)) return LE_ERR_INVALID;
  if (engine == NULL || !le_output_bus_valid(bus)) return LE_ERR_INVALID;
  return le_fx_bus_set_channels(&engine->outputs[bus].fx, index, in_mode,
                                out_mode, placement, level);
}

int32_t le_engine_set_all_tracks_fx_channels(le_engine* engine, int32_t index,
                                             int32_t in_mode, int32_t out_mode,
                                             float placement, float level) {
  if (le_fx_edit_pending(engine, LE_FX_OWNER_ALL_TRACKS, 0, 0)) return LE_ERR_INVALID;
  if (engine == NULL) return LE_ERR_INVALID;
  return le_fx_bus_set_channels(&engine->all_tracks, index, in_mode, out_mode,
                                placement, level);
}

int32_t le_engine_set_output_level(le_engine* engine, int32_t bus,
                                   float level) {
  if (!le_output_bus_valid(bus)) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_LEVEL,
                                          .lanef = {bus, 0, level}});
}

int32_t le_engine_set_output_mute(le_engine* engine, int32_t bus,
                                  int32_t muted) {
  if (!le_output_bus_valid(bus)) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_MUTE,
                                          .lanef = {bus, 0,
                                                    muted ? 1.0f : 0.0f}});
}

int32_t le_engine_set_output_mono(le_engine* engine, int32_t bus,
                                  int32_t mono) {
  if (!le_output_bus_valid(bus)) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_MONO,
                                          .lanef = {bus, 0,
                                                    mono ? 1.0f : 0.0f}});
}

int32_t le_engine_set_output_balance(le_engine* engine, int32_t bus,
                                     float balance) {
  if (!le_output_bus_valid(bus)) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_BALANCE,
                                          .lanef = {bus, 0, balance}});
}

int32_t le_engine_cut_sound(le_engine* engine) {
  return le_push(engine, LE_CMD_CUT_SOUND, 0, 0.0f);
}

int32_t le_perf_set_follow_output(le_engine* engine, int32_t follow) {
  if (engine == NULL) return LE_ERR_INVALID;
  store_i32(&engine->a_perf_follow_output, follow ? 1 : 0);
  return LE_OK;
}

/* ---- structural output gate ---- */

int32_t le_engine_set_output_enabled(le_engine* engine, int32_t output,
                                     int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (output < 0 || output >= LE_MAX_CHANNELS) return LE_ERR_INVALID;
  /* Posted through the ring so the gate edit orders with the rest of the command
   * stream and applies between buffers (RT-safe, no mid-buffer artifact). A gate
   * for an output beyond the device channel count is stored but never sounded. */
  return le_push(engine, LE_CMD_SET_OUTPUT_ENABLED, output,
                 enabled ? 1.0f : 0.0f);
}

/* Session persistence (le_engine_export_track / import_track / commit_session)
 * moved to engine_session.c (S1). */

/* ---- multi-lane control ---- */

int32_t le_engine_set_lane_count(le_engine* engine, int32_t channel,
                                 int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire))
    return LE_ERR_NOT_RUNNING;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (count < 1) count = 1;
  if (count > LE_MAX_LANES) count = LE_MAX_LANES;
  le_mix_settings mix = {.revision = 1, .lane_count_mask = 1u << channel};
  mix.lane_count[channel] = count;
  if (!le_mix_valid(engine, &mix)) return LE_ERR_INVALID;
  const int prepared = le_prepare_routing(engine, &mix);
  if (prepared != LE_OK) return prepared;
  /* Internal reclaim/import callers get queue acceptance, not publication.
   * The callback shares the same admission and activation path as SET_MIX;
   * its final block acknowledgement fences the next allocation. */
  const int rc = le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_COUNT,
    .lanei = {channel, 0, count}});
  if (rc == LE_OK) engine->lane_growth_command = engine->commands_posted;
  return rc;
}

/* #595: automatic trailing-lane reclaim, run when an un-route lands. Shrinks
 * the lane count past the longest TRAILING run of lanes that are both
 * un-routed and non-recoverable — holes in the middle stay exactly where they
 * are (compacting would move a recorded take onto another source, the rule
 * #594 exists to protect), and a lane whose audio is still live or restorable
 * (undo shadow / redo — the engine-owned a_recoverable, NOT the track-shared
 * length) is never dropped, so the shrink-then-regrow reset in
 * le_engine_set_lane_count can no longer eat a take undo could have brought
 * back. Called two ways: from the un-route itself with unrouted_lane set to
 * the just-freed index — whose command may still be in the ring, so it is
 * forced to -1 here while sibling lanes are judged by their published routing;
 * and from the event drain with unrouted_lane == -1, once every queued command
 * has applied and all routing is published, so a whole trailing run of a burst
 * of un-routes reclaims together (no index reads -1 spuriously, since valid
 * lane indices are >= 0). Declines silently while the track captures or a layer
 * is in flight (the same guard le_engine_set_lane_count enforces) — the next
 * un-route simply retries. */
static int le_trim_trailing_lanes(le_engine* engine, int32_t channel,
                                   int32_t unrouted_lane) {
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
      atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return 0;
  }
  const int32_t old = le_lanes_active(t);
  int32_t keep = old;
  while (keep > 1) {
    le_lane* ln = &t->lanes[keep - 1];
    /* An out-of-range default (le_lane_reset routes lane l to hardware input
     * l, which a smaller device does not have) reads >= 0 and counts as
     * routed — a declined trim, the safe direction. */
    const int32_t in = keep - 1 == unrouted_lane
                           ? -1
                           : load_i32(&ln->a_input_channel);
    if (in >= 0 || load_i32(&ln->a_recoverable)) break;
    keep--;
  }
  if (keep < old) return le_engine_set_lane_count(engine, channel, keep) == LE_OK;
  return 1;
}

/* The four lane setters address the lane by (channel, lane), carried as named
 * fields in the typed union. The handlers validate channel/lane, so the setters
 * only range-check lane here. */
int32_t le_engine_set_lane_input(le_engine* engine, int32_t channel,
                                 int32_t lane, int32_t input_channel) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  const int32_t rc = le_push_cmd(engine, (le_command){.code =
                                                          LE_CMD_SET_LANE_INPUT,
                                                      .lanei = {channel, lane,
                                                                input_channel}});
  /* #595: an accepted un-route may free trailing lane slots — reclaim them so
   * a track routed and un-routed repeatedly never strands at LE_MAX_LANES.
   * Only an explicit -1 triggers (a rejected/excluded channel the handler
   * maps to -1 is not the user freeing the lane).
   *
   * Two trim moments, one predicate. This immediate pass reclaims the
   * just-un-routed slot right away (its command may still be in the ring, so
   * it is treated as -1 by index). But sibling un-routes pushed earlier in the
   * SAME audio block are also still in the ring and read as routed, so a burst
   * would strand every trailing slot but the last. The pending flag re-runs
   * the trim from the event drain (le_engine_drain_events), after the block's
   * commands apply and routing publishes, so the whole trailing run frees once
   * the drain settles. Setting it is gated on the same explicit-un-route
   * predicate, so an out-of-range / excluded route that the handler maps to -1
   * is never swept by the drain pass either. */
  if (rc == LE_OK && input_channel < 0 &&
      atomic_load_explicit(&engine->a_configured, memory_order_acquire) &&
      channel >= 0 && channel < engine->track_count) {
    le_trim_trailing_lanes(engine, channel, lane);
    engine->tracks[channel].pending_lane_trim = 1;
  }
  return rc;
}

int32_t le_engine_set_lane_output(le_engine* engine, int32_t channel,
                                  int32_t lane, int32_t mask) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_OUTPUT,
                                          .lanei = {channel, lane, mask}});
}

int32_t le_engine_set_lane_volume(le_engine* engine, int32_t channel,
                                  int32_t lane, float volume) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_VOLUME,
                                          .lanef = {channel, lane, volume}});
}

int32_t le_engine_set_lane_pan(le_engine* engine, int32_t channel,
                               int32_t lane, float pan) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_PAN,
                                          .lanef = {channel, lane, pan}});
}

int32_t le_engine_set_track_solo(le_engine* engine, int32_t channel,
                                 int32_t solo) {
  if (!engine || channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_TRACK_SOLO, channel, solo ? 1.0f : 0.0f);
}

int32_t le_engine_set_input_trim(le_engine* engine, int32_t input,
                                 float gain) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_CHANNELS) return LE_ERR_INVALID;
  if (!(gain >= 0.0f)) gain = 0.0f; /* NaN lands on silence, not on unity */
  if (gain > LE_MAX_INPUT_TRIM) gain = LE_MAX_INPUT_TRIM;
  /* A direct store, like the enable flags: the capture reads it once per
   * block (relaxed), and it must hold while the engine is stopped so a
   * restart's re-apply lands before the first block. */
  store_f32(&engine->a_in_trim_bits[input], gain);
  return LE_OK;
}

int32_t le_engine_set_lane_mute(le_engine* engine, int32_t channel, int32_t lane,
                                int32_t muted) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                  .lanef = {channel, lane,
                                            muted ? 1.0f : 0.0f}});
}

/* ---- performance recording (arm/disarm the RT capture taps) ----
 * Control-thread lifecycle for le_perf_arm/disarm (segno_engine_api.h): ring
 * allocation/free lives here, following the control-allocates/publish pattern
 * le_post_dub_shadows and the FX delay lines use for RT-owned buffers, and
 * (for the free side) the plugin-slot quiescent-teardown handshake
 * (engine_plugin.c's clear_slot). */

#if defined(_WIN32)
#include <windows.h>
static void le_perf_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void le_perf_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* The handshake budget: two processed-buffer boundaries prove the audio thread
 * has drained LE_CMD_PERF_DISARM (cleared its local `armed` flag) and made its
 * last ring push, so the frees below can never race it; the 1 ms-per-spin cap
 * bounds teardown so it can never hang on a stalled device (mirrors
 * engine_plugin.c's clear_slot). */
#define LE_PERF_QUIESCE_BOUNDARIES 2
#define LE_PERF_QUIESCE_MAX_SPINS 200

static size_t le_perf_next_pow2(size_t n) {
  size_t p = 1;
  while (p < n) p <<= 1;
  return p;
}

/* Ring capacity in SAMPLES for `channels` at `sample_rate`: at least
 * LE_PERF_CAPTURE_SECONDS of audio, rounded up to the power of two
 * le_audio_ring requires. */
static size_t le_perf_ring_capacity(int32_t channels, int32_t sample_rate) {
  const size_t want =
      (size_t)channels * (size_t)sample_rate * LE_PERF_CAPTURE_SECONDS;
  return le_perf_next_pow2(want < 2 ? 2 : want);
}

/* The first one or two ENABLED output channels, in ascending index order — the
 * master capture pair (mono when only one is enabled). Returns the count found
 * (0, 1, or 2); out_ch[1] is left at -1 when only one is found. */
int le_perf_first_enabled_pair(le_engine* e, int32_t out_ch[2]) {
  out_ch[0] = -1;
  out_ch[1] = -1;
  const uint32_t mask =
      atomic_load_explicit(&e->a_output_enabled_mask, memory_order_relaxed);
  /* The first output BUS (slice 3b) with an enabled channel: the capture
   * is that bus's pair, so its pre-level tap has one bus to read. A single
   * enabled channel of the pair makes the capture mono. */
  /* The published mirror, not the plain configuration field: this runs from
   * le_engine_get_snapshot too, which reads every other channel count that
   * way. */
  const int32_t ch_out = load_i32(&e->a_out_channels);
  for (int32_t c = 0; c < ch_out && c < LE_MAX_CHANNELS; c += 2) {
    const int left = (mask & (1u << c)) != 0;
    const int right =
        c + 1 < ch_out && (mask & (1u << (c + 1))) != 0;
    if (!left && !right) continue;
    out_ch[0] = left ? c : c + 1;
    if (left && right) {
      out_ch[1] = c + 1;
      return 2;
    }
    return 1;
  }
  return 0;
}

/* Frees every ring allocated by an arm attempt that never reached the audio
 * thread (the command was never pushed, or push failed) — plain control-thread
 * cleanup, not a quiescent teardown, since nothing was published. */
static void le_perf_free_unpublished(le_engine* e, uint32_t monitors_done) {
  le_audio_ring_release(&e->perf.master_ring);
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (monitors_done & (1u << c)) {
      le_audio_ring_release(&e->perf.monitor_ring[c]);
    }
  }
}

int32_t le_perf_arm(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return LE_ERR_INVALID;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return LE_OK; /* already armed: idempotent */
  }
  if (engine->perf.drain != NULL) {
    /* A queued arm or incomplete disarm still owns these rings and worker.
     * Reallocating them would race that worker. Require successful disarm
     * before a new arm can take ownership. */
    return LE_ERR_DEVICE;
  }

  int32_t out_ch[2];
  const int found = le_perf_first_enabled_pair(engine, out_ch);
  if (found == 0) return LE_ERR_INVALID; /* nothing enabled to capture */

  const int32_t sr = engine->sample_rate > 0 ? engine->sample_rate : 48000;
  const size_t master_cap = le_perf_ring_capacity(found, sr);
  if (!le_audio_ring_alloc(&engine->perf.master_ring, master_cap)) {
    return LE_ERR_INVALID;
  }
  engine->perf.master_channels = found;
  engine->perf.master_out_ch[0] = out_ch[0];
  engine->perf.master_out_ch[1] = out_ch[1];
  /* The capture policy is frozen per take (accepted design): the flag as it
   * stands at arm, read by the audio thread through this plain field. */
  engine->perf.follow_output = load_i32(&engine->a_perf_follow_output);

  /* The monitor capture set is frozen at arm: whichever inputs are enabled
   * right now, and no others — an input enabled later is logged, not tapped
   * (umbrella scope for this part). Every captured monitor ring is stereo
   * (the monitor's own chain, e.g. a reverb, may decorrelate l/r).
   *
   * Clamped to the DEVICE's input count, not just LE_MAX_MONITORED_INPUTS
   * (#710). le_engine_set_monitor_input validates only against the array
   * bound, so a session saved on an 8-in interface and reloaded on a 2-in one
   * leaves monitors 2..7 enabled. Capturing them would open a stem the audio
   * thread can never fill — mix_monitors_frame taps only c < ch_in — so the
   * drain would silence-fill that file for the entire take. Harmless while
   * nothing counted the padding; now that a zero-fill raises the capture's
   * glitch flag, it would light the warning on every single capture and drown
   * the real signal. An input that does not exist is not a captured input. */
  uint32_t input_mask = 0;
  const int32_t monitor_ch_limit =
      (engine->in_channels > 0 && engine->in_channels < LE_MAX_MONITORED_INPUTS)
          ? engine->in_channels
          : LE_MAX_MONITORED_INPUTS;
  const size_t monitor_cap = le_perf_ring_capacity(2, sr);
  for (int32_t c = 0; c < monitor_ch_limit; ++c) {
    if (!load_i32(&engine->monitors[c].a_enabled)) continue;
    if (!le_audio_ring_alloc(&engine->perf.monitor_ring[c], monitor_cap)) {
      le_perf_free_unpublished(engine, input_mask);
      return LE_ERR_INVALID;
    }
    input_mask |= (1u << c);
  }
  engine->perf.input_mask = input_mask;

  atomic_store_explicit(&engine->a_perf_frames, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_overruns, 0u, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_zero_filled_frames, 0u,
                        memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_log_overruns, 0u, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_log_ctrl_overruns, 0u,
                        memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_layer_overruns, 0u,
                        memory_order_relaxed);
  /* Reset both perf-log rings so a fresh session never sees a stale entry
   * left over from a previous one — safe here (before LE_CMD_PERF_ARM is
   * pushed below) the same way publishing the audio rings above is: the
   * audio thread has not yet been told to start producing into log_ring, and
   * this control thread is the only producer for log_ctrl_ring. */
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  /* The layer-staging ring (part 5) needs a free-then-init, not a blind
   * re-init: the previous session's drain thread usually empties it in its
   * unconditional final drain cycle, but a drain thread that SELF-stopped
   * (write failure) died before later retires were staged — those entries
   * still own heap PCM and have no consumer left. le_perf_arm refuses to
   * run while a stale drain thread is alive, so this pop is race-free. */
  le_layer_staging_ring_drain_free(&engine->perf.layer_staging_ring);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);

  engine->perf.next_image_id = 0;
  /* A fresh image namespace (#1143): no entry from a previous capture may be
   * logged under this one's ids. Safe before LE_CMD_PERF_ARM is pushed for the
   * same reason the ring resets above are. */
  for (int32_t c = 0; c < LE_MAX_TRACKS; ++c) le_forget_slot_images(engine, c);
  /* Spawn the drain thread before publishing to the audio thread: it only
   * ever reads through le_audio_ring_pop (never allocates/frees the ring
   * buffers themselves), so starting it slightly early is harmless — it just
   * finds empty rings until the audio thread begins producing. Arming without
   * a working drain thread would silently drop every captured frame, so a
   * failure here aborts the whole arm. */
  engine->perf.drain = le_perf_drain_start(engine, capture_dir);
  if (engine->perf.drain == NULL) {
    le_perf_free_unpublished(engine, input_mask);
    engine->perf.input_mask = 0;
    return LE_ERR_DEVICE;
  }

  /* Push-then-mutate would be backwards here: the ring set must be fully
   * published (visible via the command ring's release/acquire pairing) BEFORE
   * the audio thread may touch it, so every field above is written first and
   * this push is what makes them visible. */
  const int32_t rc = le_push(engine, LE_CMD_PERF_ARM, 0, 0.0f);
  if (rc != LE_OK) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
    engine->perf.drain = NULL;
    le_perf_free_unpublished(engine, input_mask);
    engine->perf.input_mask = 0;
    return rc;
  }
  return LE_OK;
}

/* One window, formatted as `{calls=… late=… …}` into `buf`. Split out so the
 * summary below prints both windows through one definition instead of a
 * forty-argument fprintf whose two halves could drift apart. */
static void le_cbtel_format_window(const le_cb_window_snapshot* w, char* buf,
                                   size_t cap) {
  snprintf(buf, cap,
           "{calls=%llu periods=%llu late=%llu gaps=%llu max=%uus mean=%uus"
           " maxgap=%uus xrun=%llu/%llu/%llu/%llu"
           " hist=%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu}",
           (unsigned long long)w->calls, (unsigned long long)w->periods,
           (unsigned long long)w->late_periods,
           (unsigned long long)w->gap_events, w->max_us, w->mean_us,
           w->max_gap_us,
           (unsigned long long)w->xruns[LE_XRUN_PLAYBACK_UNDERRUN],
           (unsigned long long)w->xruns[LE_XRUN_CAPTURE_OVERRUN],
           (unsigned long long)w->xruns[LE_XRUN_PLAYBACK_RESYNC],
           (unsigned long long)w->xruns[LE_XRUN_BACKEND_OVERLOAD],
           (unsigned long long)w->buckets[0], (unsigned long long)w->buckets[1],
           (unsigned long long)w->buckets[2], (unsigned long long)w->buckets[3],
           (unsigned long long)w->buckets[4], (unsigned long long)w->buckets[5],
           (unsigned long long)w->buckets[6], (unsigned long long)w->buckets[7]);
}

/* One-line callback-telemetry summary, written to stderr when a capture
 * disarms (#722). The appliance runs under systemd, so stderr IS the journal
 * (`journalctl -u segno.service`) — the place a bench operator is already
 * looking. Emitted from the CONTROL thread: no formatting, no I/O, and no
 * allocation ever happens on the audio thread, which only bumps relaxed
 * atomics.
 *
 * Emitted on BOTH disarm outcomes. `stalled=1` marks the path where the
 * quiescent handshake timed out and le_perf_disarm bails with LE_ERR_DEVICE —
 * i.e. the device callback has stopped coming back, which is precisely when
 * these numbers matter most and precisely when a summary printed only on the
 * happy path would be missing.
 *
 * Silent unless a real device drove callbacks in the armed window, so the
 * device-free native test pump (and any never-started engine) prints nothing.
 * Both windows go on one line: the armed window is the suspect, the session
 * window is the control it has to be read against — "unarmed" is their
 * difference. */
static void le_perf_log_callback_telemetry(le_engine* engine, int stalled) {
  le_callback_telemetry tel;
  /* Sized for the pathological case — every 64-bit counter at 20 digits — so
   * the line is never silently truncated on a long-lived appliance. */
  char armed_buf[704];
  char session_buf[704];
  /* Read through the same projection le_engine_get_callback_telemetry uses, so
   * the journal line and the FFI pull can never disagree. */
  le_cb_timing_read(&engine->cb_timing, &tel);
  if (tel.armed.calls == 0) return;
  le_cbtel_format_window(&tel.armed, armed_buf, sizeof(armed_buf));
  le_cbtel_format_window(&tel.session, session_buf, sizeof(session_buf));
  fprintf(stderr,
          "segno/cbtel perf-disarm stalled=%d budget=%uus armed%s session%s\n",
          stalled ? 1 : 0, tel.budget_us, armed_buf, session_buf);
}

int32_t le_perf_disarm(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire) &&
      engine->perf.drain == NULL) {
    return LE_OK; /* already disarmed: idempotent */
  }
  const int32_t rc = le_push(engine, LE_CMD_PERF_DISARM, 0, 0.0f);
  if (rc != LE_OK) return rc; /* ring full: caller retries; still armed */

  /* Quiescent handshake (mirrors engine_plugin.c's clear_slot): wait for the
   * audio thread to cycle past two buffer boundaries after it pops the disarm
   * command, so no in-flight ring push can race the frees below. Only
   * meaningful while a device is actually driving the callback; a stopped or
   * never-started engine (the native test pump) has no concurrent writer, so
   * the queued commands are consumed synchronously before teardown. */
  if (load_i32(&engine->a_running)) {
    uint64_t last =
        atomic_load_explicit(&engine->a_frames, memory_order_acquire);
    int boundaries = 0;
    for (int spins = 0; spins < LE_PERF_QUIESCE_MAX_SPINS &&
                        boundaries < LE_PERF_QUIESCE_BOUNDARIES;
         ++spins) {
      le_perf_sleep_ms(1);
      const uint64_t now =
          atomic_load_explicit(&engine->a_frames, memory_order_acquire);
      if (now != last) {
        ++boundaries;
        last = now;
      }
    }
    if (boundaries < LE_PERF_QUIESCE_BOUNDARIES ||
        atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire) ||
        !le_engine_commands_settled(engine)) {
      /* The callback is stalled — do NOT free (a possible in-flight push
       * would be a use-after-free). Keep the rings and drain allocated: the
       * queued disarm may not have applied yet. A later successful
       * disarm (once the callback recovers) or le_engine_destroy reclaims
       * them. */
      /* Print the telemetry BEFORE bailing (#722). A stalled callback is the
       * single most interesting thing this instrument can catch, and this is
       * the one exit that would otherwise never reach the summary at the end
       * of the function — the numbers would go missing exactly when they are
       * worth the most. */
      le_perf_log_callback_telemetry(engine, /*stalled=*/1);
      return LE_ERR_DEVICE;
    }
  }

  if (!load_i32(&engine->a_running)) {
    /* Device-free pumps / a fully stopped device have no concurrent callback.
     * Consume a queued ARM then DISARM before releasing their resources; an
     * early return on a_perf_armed alone would leave a later orphan arm. */
    le_engine_process(engine, NULL, NULL, 0);
    if (atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire) ||
        !le_engine_commands_settled(engine)) return LE_ERR_DEVICE;
  }

  /* The audio thread has confirmed quiescent (or there is no concurrent
   * writer at all — the device-free test pump). Stop and join the drain
   * thread BEFORE freeing the rings below: it is the rings' last reader
   * (le_audio_ring_pop), and its own final drain-and-flush pass needs them
   * intact. */
  le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
  engine->perf.drain = NULL;

  le_audio_ring_release(&engine->perf.master_ring);
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (engine->perf.input_mask & (1u << c)) {
      le_audio_ring_release(&engine->perf.monitor_ring[c]);
    }
  }
  engine->perf.input_mask = 0;
  le_perf_log_callback_telemetry(engine, /*stalled=*/0);
  return LE_OK;
}

/* ---- performance-recording capture test seams (engine_internal.h) ---- *
 * Part 1 has no drain thread; these drain the rings directly for native-test
 * bit-parity assertions only. Single-threaded in tests (le_engine_process is
 * called synchronously, never concurrently with these), so no ring-pop race
 * against the audio-thread push side. */

int32_t le_engine_perf_master_pop_for_test(le_engine* engine, float* out,
                                           int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames <= 0) return 0;
  const int32_t ch = engine->perf.master_channels;
  if (ch <= 0) return 0;
  const size_t popped = le_audio_ring_pop(&engine->perf.master_ring, out,
                                          (size_t)max_frames * (size_t)ch);
  return (int32_t)(popped / (size_t)ch);
}

int32_t le_engine_perf_master_channels_for_test(le_engine* engine) {
  return engine == NULL ? 0 : engine->perf.master_channels;
}

int32_t le_engine_perf_monitor_pop_for_test(le_engine* engine, int32_t input,
                                            float* out, int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames <= 0) return 0;
  if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) return 0;
  if (!(engine->perf.input_mask & (1u << input))) return 0;
  const size_t popped = le_audio_ring_pop(&engine->perf.monitor_ring[input],
                                          out, (size_t)max_frames * 2);
  return (int32_t)(popped / 2);
}
