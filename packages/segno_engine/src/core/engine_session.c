/*
 * engine_session.c — session persistence (export / import / commit).
 *
 * THREAD OWNERSHIP: control thread. Export reads, and import fills, a lane's loop
 * buffer directly — safe because both target a track the audio thread is not
 * recording (export when not capturing; import only into an EMPTY track, whose
 * buffers the audio thread does not touch). Commit is the one ring-posted step
 * (le_push), so the audio thread establishes the master and starts the imported
 * tracks in lockstep. Split out of engine.c (S1).
 *
 * Lane buffers are mono (one sample per frame), so a stem is just the loop
 * samples; routing to channels is a playback concern, not stored. Export/import
 * address any lane: le_engine_export_track / le_engine_import_track are the
 * lane-0 conveniences over the _lane variants. Per-overdub-layer export/import
 * (undo/redo persistence) is a later revision.
 */
#include <stdint.h>
#include <string.h>

#include "engine_core.h"     /* le_push */
#include "engine_private.h"  /* le_engine, le_track, le_lane, load/store_i32 */
#include "segno_engine_api.h"

/* Sole control producer reserves room before changing imported material.
 * The consumer can only free slots between this check and the final push. */
static int le_import_fade_room(le_engine* e) {
  const size_t tail = atomic_load_explicit(&e->ring.tail, memory_order_relaxed);
  const size_t head = atomic_load_explicit(&e->ring.head, memory_order_acquire);
  return tail - head < e->ring.capacity - 1;
}

int32_t le_engine_export_track(le_engine* engine, int32_t channel, float* out,
                               int32_t max_frames) {
  if (engine == NULL || out == NULL) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (max_frames <= 0) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[0];
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return 0;
  memcpy(out, ln->pool[live], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_export_track_lane(le_engine* engine, int32_t channel,
                                    int32_t lane, float* out,
                                    int32_t max_frames) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (max_frames <= 0) return LE_ERR_INVALID;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return 0;
  memcpy(out, ln->pool[live], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_track_lane(le_engine* engine, int32_t channel,
                                    int32_t lane, const float* pcm,
                                    int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (frames <= 0) return LE_ERR_INVALID;
  /* A queued shrink still owns its old buffers until the callback finishes
   * the complete block. EMPTY alone cannot release that lifetime. */
  if (engine->lane_growth_command > atomic_load_explicit(
        &engine->a_commands_published, memory_order_acquire)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  /* Importing targets an empty track: its buffers are not read by the audio
   * thread, so the control thread can fill any lane directly. An undone-to-empty
   * track qualifies, but its redo stack must go first — the live buffer being
   * overwritten IS the redo-top snapshot, so advertising canRedo afterwards
   * would resurrect the imported content, not the undone take. */
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  /* A posted-but-unapplied state flip (undo-to-empty / redo-from-empty /
   * clear) makes the raw EMPTY reading unreliable — reject rather than race
   * the command; session loads retry trivially. */
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  /* Reject (rather than silently truncate) a stem that exceeds the buffer cap,
   * so a corrupted/foreign loop fails loudly instead of loading clipped. */
  if (frames > engine->max_loop_frames) return LE_ERR_INVALID;
  if (lane == 0 && !le_import_fade_room(engine)) return LE_ERR_NOT_READY;
  /* Lane 0 is the primary import: it resets the track's redo/empty accounting
   * (a fresh session take has no undo history). Additional lanes only fill
   * their own buffer — they share the track's one undo span, so they must not
   * touch its stacks. Growing lane_count activates the imported lane for
   * playback after commit; a newly activated lane defaults to its standard
   * record route (input == lane index) but is NEVER reset for lane 0, whose
   * buffer/config we are filling here. */
  if (lane == 0) {
    t->redo_count = 0;
    t->empty_len = 0;
    store_i32(&t->a_redo_depth, 0);
    t->start_iter = 0;
  }
  if (lane >= le_lanes_active(t)) {
    for (int32_t l = le_lanes_active(t); l <= lane; ++l) {
      le_lane_reset(&t->lanes[l], l);
    }
    atomic_store_explicit(&t->lane_count, lane + 1, memory_order_release);
  }
  le_lane* ln = &t->lanes[lane];
  const int live = load_i32(&ln->a_live);
  /* The import target must hold the full cap (a later capture over it can
   * grow to max_loop_frames, and the tail is zeroed to the cap below); undo
   * may have left a quantized snapshot slot live. Track is EMPTY: safe. */
  if (!le_lane_ensure_slot(ln, live, engine->max_loop_frames)) {
    return LE_ERR_INVALID;
  }
  const size_t span = (size_t)frames;
  const size_t cap = (size_t)engine->max_loop_frames;
  /* #1143: the live slot's PCM changes under a possibly staged identity. */
  le_forget_slot_images(engine, channel);
  memcpy(ln->pool[live], pcm, span * sizeof(float));
  if (span < cap) {
    memset(ln->pool[live] + span, 0, (cap - span) * sizeof(float));
  }
  store_i32(&ln->a_len, frames);
  /* #595: imported content IS captured audio — the recoverable flag rides the
   * session round-trip (export only ever covers lanes that recorded, so this
   * is the load half of that round-trip). Keeps the trailing trim off the
   * lane if it is later un-routed. */
  store_i32(&ln->a_recoverable, 1);
  le_audio_rev_bump(t); /* [R1] session load: imported content replaces all */
  le_track_forget_slot_keys(t);
  if (lane == 0) (void)le_push(engine, LE_CMD_RESET_TRANSFORMS, channel, 0);
  return LE_OK;
}

int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                               const float* pcm, int32_t frames) {
  return le_engine_import_track_lane(engine, channel, 0, pcm, frames);
}

/* Maps an export ordinal (0 = oldest undo layer ... undo_count = live ...
 * then the redo images) to the pool slot that holds it. The linear timeline
 * is undo_stack[0..undo_count) then a_live then the redo stack read
 * newest-adjacent-first (redo_stack[redo_count-1] is the layer immediately
 * above live — see le_undo_swap in engine_commands.c). Image-bearing entries
 * only: a redo-side PEEL marker (slot -1, #1164) holds no image and is skipped,
 * so an ordinal never tears on one. Returns -1 for an ordinal past the end. */
static int32_t le_layer_slot_for_ordinal(const le_track* t, int32_t ordinal,
                                          int32_t live) {
  const int32_t undo_c = t->undo_count;
  if (ordinal < undo_c) return t->undo_stack[ordinal].slot;
  if (ordinal == undo_c) return live;
  int32_t j = ordinal - undo_c - 1; /* 0-based into the post-live images */
  for (int32_t k = t->redo_count - 1; k >= 0; --k) {
    if (t->redo_stack[k].slot < 0) continue;
    if (j-- == 0) return t->redo_stack[k].slot;
  }
  return -1;
}

int32_t le_engine_export_history(le_engine* engine, int32_t channel,
                                 int32_t* kinds, int32_t* skipped,
                                 int32_t max, int32_t* undo_count) {
  if (engine == NULL || kinds == NULL || skipped == NULL ||
      undo_count == NULL || max < 0) {
    return LE_ERR_INVALID;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  const le_track* t = &engine->tracks[channel];
  /* The raw stack split, read with the entries: the published a_undo_depth is
   * gated (0 while a content-giving command is in flight, until the next
   * drain republishes it), so a caller that split these entries by it could
   * misread the live image's ordinal (#1164 review finding 1). */
  *undo_count = t->undo_count;
  int32_t n = 0;
  for (int32_t i = 0; i < t->undo_count; ++i, ++n) {
    if (n >= max) continue;
    kinds[n] = t->undo_stack[i].kind;
    skipped[n] = t->undo_stack[i].skipped;
  }
  for (int32_t k = t->redo_count - 1; k >= 0; --k, ++n) {
    if (n >= max) continue;
    kinds[n] = t->redo_stack[k].kind;
    skipped[n] = t->redo_stack[k].skipped;
  }
  return n;
}

int32_t le_engine_export_layer(le_engine* engine, int32_t channel, int32_t lane,
                               int32_t ordinal, float* out, int32_t max_frames) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (ordinal < 0 || max_frames <= 0) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  le_lane* ln = &t->lanes[lane];
  /* a_live is written in lockstep across lanes, so any lane's copy names the
   * shared live slot; the undo/redo stacks are track-owned slot indices. An
   * ordinal past the image-bearing entries maps to -1. */
  const int32_t slot =
      le_layer_slot_for_ordinal(t, ordinal, load_i32(&ln->a_live));
  if (slot < 0) return LE_ERR_INVALID;
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  if (ln->pool[slot] == NULL) return 0;
  memcpy(out, ln->pool[slot], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_layer(le_engine* engine, int32_t channel, int32_t lane,
                               int32_t ordinal, const float* pcm,
                               int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  /* The slot index IS the ordinal (le_engine_finalize_history rebuilds the
   * stacks on the same numbering), so it must fit the pool (R1 cap). */
  if (ordinal < 0 || ordinal >= LE_POOL_SLOTS) return LE_ERR_INVALID;
  if (frames <= 0 || frames > engine->max_loop_frames) return LE_ERR_INVALID;
  /* A queued shrink still owns its old buffers until the callback finishes
   * the complete block. EMPTY alone cannot release that lifetime. */
  if (engine->lane_growth_command > atomic_load_explicit(
        &engine->a_commands_published, memory_order_acquire)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  /* Activate the lane if this is the first layer landing on it; a grown lane
   * takes its standard record route (input == lane index). Never reset a lane
   * already being filled. */
  if (lane >= le_lanes_active(t)) {
    for (int32_t l = le_lanes_active(t); l <= lane; ++l) {
      le_lane_reset(&t->lanes[l], l);
    }
    atomic_store_explicit(&t->lane_count, lane + 1, memory_order_release);
  }
  le_lane* ln = &t->lanes[lane];
  /* Undo/redo layers are quantized to the loop length (as the live rig sizes
   * them); no path record-grows an imported slot, so full max_loop_frames is
   * unnecessary. The final size must be allocated BEFORE the copy — a later
   * ensure_slot to a larger size frees and re-zeroes the buffer. */
  int32_t want =
      ((frames + LE_LAYER_QUANTUM - 1) / LE_LAYER_QUANTUM) * LE_LAYER_QUANTUM;
  if (want > engine->max_loop_frames) want = engine->max_loop_frames;
  if (!le_lane_ensure_slot(ln, ordinal, want)) return LE_ERR_INVALID;
  le_forget_slot_images(engine, channel); /* #1143: slot content redefined */
  memcpy(ln->pool[ordinal], pcm, (size_t)frames * sizeof(float));
  if (frames < want) {
    memset(ln->pool[ordinal] + frames, 0,
           (size_t)(want - frames) * sizeof(float));
  }
  /* Every layer of a lane shares the loop length; set it idempotently. */
  store_i32(&ln->a_len, frames);
  store_i32(&ln->a_recoverable, 1); /* #595: see le_engine_import_track_lane */
  return LE_OK;
}

int32_t le_engine_finalize_history(le_engine* engine, int32_t channel,
                                   const int32_t* kinds,
                                   const int32_t* skipped, int32_t count,
                                   int32_t undo_count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (count < 0 || undo_count < 0 || undo_count > count) return LE_ERR_INVALID;
  if (count > 0 && (kinds == NULL || skipped == NULL)) return LE_ERR_INVALID;
  const int32_t redo_count = count - undo_count;
  if (undo_count >= LE_POOL_SLOTS || redo_count > LE_POOL_SLOTS) {
    return LE_ERR_INVALID; /* the stacks' capacity */
  }
  /* Strict (#1164): every entry must be one the live engine can hold where it
   * sits. A PEEL on the redo side is a marker without an image; everywhere
   * else every entry names one image. Mirrored by Dart's
   * TrackHistory.malformation, which refuses the same Sessions at decode. */
  int32_t images = undo_count + 1;
  for (int32_t i = 0; i < count; ++i) {
    const int32_t kind = kinds[i];
    const int redo = i >= undo_count;
    if (kind != LE_HIST_LAYER && kind != LE_HIST_CLEAR &&
        kind != LE_HIST_PEEL && kind != LE_HIST_PROCESSED) {
      return LE_ERR_INVALID;
    }
    /* No stack holds LE_POOL_SLOTS entries above a layer. */
    if (skipped[i] < 0 || skipped[i] >= LE_POOL_SLOTS) return LE_ERR_INVALID;
    if (kind != LE_HIST_PEEL && skipped[i] != 0) return LE_ERR_INVALID;
    /* A CLEAR restore point is only ever the deepest redo entry: on the undo
     * side it empties the track (never captured), and le_restore_clear moves
     * it to an empty redo stack while le_clear_track drops the redo branch.
     * Its redo needs no payload: it re-clears from the live state. */
    if (kind == LE_HIST_CLEAR && (!redo || i != count - 1)) {
      return LE_ERR_INVALID;
    }
    /* An undo-side PEEL skipped at most the PEEL run directly beneath it —
     * those entries sat above the layer it consumed — unless the run reaches
     * the bottom: pool eviction removes the oldest entries, and Undo clamps
     * its re-insertion there (le_undo_swap). */
    if (kind == LE_HIST_PEEL && !redo) {
      int32_t run = 0;
      while (run < i && kinds[i - 1 - run] == LE_HIST_PEEL) ++run;
      if (skipped[i] > run && run < i) return LE_ERR_INVALID;
    }
    if (redo && kind != LE_HIST_PEEL) ++images;
  }
  if (images > LE_POOL_SLOTS) return LE_ERR_INVALID; /* R1 cap */
  /* Walk the redo side as Redo would: a PEEL marker re-peels, so a layer must
   * be reachable through PEEL entries when Redo reaches it — otherwise Redo
   * refuses forever and strands every image beneath the marker. */
  {
    int32_t sim[2 * LE_POOL_SLOTS];
    int32_t depth = 0;
    for (int32_t i = 0; i < undo_count; ++i) sim[depth++] = kinds[i];
    for (int32_t i = undo_count; i < count; ++i) {
      if (kinds[i] != LE_HIST_PEEL) {
        sim[depth++] = kinds[i];
        continue;
      }
      int32_t target = depth - 1;
      while (target >= 0 && sim[target] == LE_HIST_PEEL) --target;
      if (target < 0 || sim[target] != LE_HIST_LAYER) return LE_ERR_INVALID;
      for (int32_t k = target + 1; k < depth; ++k) sim[k - 1] = sim[k];
      sim[depth - 1] = LE_HIST_PEEL;
    }
  }
  /* A queued shrink still owns its old buffers until the callback finishes
   * the complete block. EMPTY alone cannot release that lifetime. */
  if (engine->lane_growth_command > atomic_load_explicit(
        &engine->a_commands_published, memory_order_acquire)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  const int32_t lanes = le_lanes_active(t);
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if (len <= 0) return LE_ERR_INVALID;
  /* Every active lane must hold every image ordinal at the same length (the
   * stacks are shared in lockstep) — reject a torn/partial reconstruction
   * rather than publish it. */
  for (int32_t l = 0; l < lanes; ++l) {
    if (load_i32(&t->lanes[l].a_len) != len) return LE_ERR_INVALID;
    for (int32_t s = 0; s < images; ++s) {
      /* Every restored slot must be allocated AND large enough to hold the loop
       * length: a mismatched-length stage (differing frames per ordinal) could
       * leave a slot shorter than `len`, which playback/export would then read
       * past. Reject rather than publish an out-of-bounds layer. */
      if (t->lanes[l].pool[s] == NULL) return LE_ERR_INVALID;
      if (t->lanes[l].pool_cap[s] < len) return LE_ERR_INVALID;
    }
  }
  if (!le_import_fade_room(engine)) return LE_ERR_NOT_READY;
  /* Slot index == image ordinal: the undo entries occupy [0, undo_count), the
   * live buffer sits at undo_count, and the redo images follow top-down
   * (mirror of le_layer_slot_for_ordinal); a redo marker names slot -1. */
  int32_t image = 0;
  for (int32_t i = 0; i < undo_count; ++i) {
    t->undo_stack[i] = le_hist_kind_entry(kinds[i], image++, skipped[i]);
  }
  t->undo_count = undo_count;
  const int32_t live = image++;
  for (int32_t j = 0; j < redo_count; ++j) {
    const int32_t i = undo_count + j;
    const int32_t slot = kinds[i] == LE_HIST_PEEL ? -1 : image++;
    t->redo_stack[redo_count - 1 - j] =
        le_hist_kind_entry(kinds[i], slot, skipped[i]);
  }
  t->redo_count = redo_count;
  t->empty_len = 0;
  t->start_iter = 0;
  /* [R1] session load (layered): the reconstructed stack's live slot is
   * published here — the layers imported while EMPTY (le_engine_import_layer)
   * become playable content at this swap, so this is the one bump for the
   * whole layered reconstruction (structural via le_track_publish_live).
   * Image 0 (#1143): imported PCM has no staged copy in a running capture, so
   * a stem that reaches it fails truthfully (323/0) rather than guessing. */
  le_forget_slot_images(engine, channel);
  le_publish_live_image(engine, t, live, 0, 0);
  store_i32(&t->a_undo_depth, undo_count);
  store_i32(&t->a_peel_depth, le_peel_depth(t));
  store_i32(&t->a_redo_depth, redo_count);
  (void)le_push(engine, LE_CMD_RESET_TRANSFORMS, channel, 0);
  return LE_OK;
}

int32_t le_engine_commit_session(le_engine* engine, int32_t base_frames,
                                  int32_t loop_bars) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (base_frames <= 0 || loop_bars < 0 || loop_bars > INT32_MAX / 15) {
    return LE_ERR_INVALID;
  }
  /* Free/Song mode (B2b, adversarial-review BUG 2 fix; broadened to SONG by
   * B4): session import establishes ONE shared base length for every
   * imported track (LE_CMD_COMMIT_SESSION's handler, engine_process.c) —
   * meaningless, and actively harmful, for Free/Song mode's independent
   * per-track lengths (song-mode-spec §2: Song's transport is "structurally
   * identical" to Free's): it would set the shared master clock to nonzero
   * while a_looper_mode is FREE or SONG, violating the invariant every
   * other Free/Song-mode code path in this file relies on (the master
   * clock stays permanently dormant in both modes). Free/Song-mode session
   * import is a documented gap (see the handler's doc) that a later PR
   * (A7/B5c territory) needs to solve with a proper per-track free_clock
   * restore from the manifest — not this single-base commit. Rejecting
   * synchronously here, before the command is even posted, is cleaner than
   * a silent partial no-op: the caller (the session-load path) gets an
   * actionable LE_ERR_INVALID instead of imported tracks quietly failing to
   * establish playable state. The audio-thread handler carries its own
   * defensive copy of this same guard for the raw le_engine_post_command
   * escape hatch, which can post this command directly and bypass this
   * wrapper. */
  const int32_t mode = load_i32(&engine->a_looper_mode);
  if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
    return LE_ERR_INVALID;
  }
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_COMMIT_SESSION,
                                  .session = {.base_frames = base_frames,
                                              .loop_bars = loop_bars}});
}
