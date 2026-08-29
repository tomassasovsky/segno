/*
 * engine_restore.h — the offline loop-close restoration worker (#697 S9).
 *
 * A second [B6]-style background worker, mirroring engine_cache.c's [R2]
 * contract clause by clause, that repairs a track's captured lanes AFTER a
 * loop closes: de-clip (restore_declip.c) then optional RNNoise denoise
 * (third_party/rnnoise, via the half-band resampler at 96 k). One job in
 * flight engine-wide, copy-at-enqueue with a rev-bump abort, and a
 * control-side commit that publishes the restored audio as one lockstep undo
 * layer (le_restore_commit_layer, engine_commands.c) — so the raw take is one
 * plain le_engine_undo away and the RT audio thread is untouched by
 * construction.
 *
 * Lifecycle mirrors the cache exactly: le_restore_init at the end of
 * le_engine_configure, le_restore_shutdown (join-before-free) from
 * le_engine_stop, the top of le_engine_configure, and le_engine_destroy, and
 * le_restore_tick driven from le_engine_drain_events beside le_cache_tick.
 */
#ifndef SEGNO_ENGINE_RESTORE_H
#define SEGNO_ENGINE_RESTORE_H

#include <stdint.h>

#include "segno_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_engine le_engine;

/* Allocates the restoration worker state and starts its background thread.
 * No-op if already initialized or on allocation failure (restoration then
 * quietly disabled — every le_engine_restore_track returns LE_ERR_INVALID and
 * audio is unaffected). Called at the end of le_engine_configure. */
void le_restore_init(le_engine* engine);

/* Join-before-free [R2](d): sets the shutdown flag, joins the worker, and
 * frees the job's copies/outputs. Every caller guarantees the audio thread is
 * stopped, so no quiescent window is needed (the restore worker never frees a
 * buffer the audio thread can hold — the published slot lives on in the lane
 * pool as an undo layer). Called from le_engine_stop, the top of
 * le_engine_configure, and le_engine_destroy BEFORE any pool free. */
void le_restore_shutdown(le_engine* engine);

/* One control-thread heartbeat: advance the chunked enqueue copy, collect a
 * finished job (publishing it on a still-matching rev [B5]), and mirror the
 * job's state into the track's a_restore_state. Driven from
 * le_engine_drain_events beside le_cache_tick. No-op until le_restore_init. */
void le_restore_tick(le_engine* engine);

/* Commits a completed restoration as ONE lockstep undo layer (control thread;
 * DEFINED in engine_commands.c, where the undo/slot machinery lives). Re-checks
 * the track's a_audio_rev against [audio_rev] and its length against [len]
 * [B5]; on a match it acquires a fresh pool slot, fills it per lane (the
 * restored PCM in restored[l] for lanes whose bit is set in [lane_mask], a
 * plain copy of the current live buffer for the rest), pushes the
 * pre-restoration live slot onto the undo stack as one lockstep layer, and
 * publishes the new slot as live via le_track_publish_live — which bumps
 * a_audio_rev and so invalidates and re-renders the wet cache. Returns LE_OK on
 * publish, or LE_ERR_INVALID on a rev/len mismatch, a capturing/ in-flight
 * track, or slot/allocation exhaustion (the caller discards restored[] either
 * way). */
int32_t le_restore_commit_layer(le_engine* engine, int32_t channel,
                                uint32_t lane_mask, uint32_t audio_rev,
                                int32_t len,
                                float* const restored[LE_MAX_LANES]);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_RESTORE_H */
