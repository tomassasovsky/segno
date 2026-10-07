/*
 * engine_cache.h — the Loop-stage wet cache's cross-TU seam (FX v3 part 2).
 *
 * The cache's control/worker machinery (scheduler, job queue, the single
 * render worker [B6], memory accounting + LRU eviction) lives in
 * engine_cache.c behind the opaque `struct le_fx_cache` pointer on le_engine.
 * This header exposes only the three lifecycle/tick hooks the rest of the
 * engine calls; everything the AUDIO thread needs (le_lane.a_wet,
 * le_track.a_audio_rev, le_wet_entry) is in engine_private.h — the audio
 * thread never calls into this TU.
 *
 * NOT the FFI surface (the log/test-only telemetry accessors are declared in
 * segno_engine_api.h and defined in engine_cache.c) and NOT the test surface —
 * the private contract between the engine's own TUs.
 */
#ifndef SEGNO_ENGINE_CACHE_H
#define SEGNO_ENGINE_CACHE_H

#include "engine_private.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Settle debounce [B2][B3]: no render is scheduled until the lane's cache key
 * has been unchanged for this long. Continuously-moving state (param sweeps,
 * volume moves — D-VOL) folds into the key, so it resets this window on every
 * change. Measured in PROCESSED FRAMES (a_frames scaled by the sample rate),
 * not wall time, so the device-free native tests are deterministic — and it
 * lives here (not TU-private in engine_cache.c) so those tests derive their
 * pump counts from this one definition. */
#define LE_CACHE_SETTLE_MS 250

/* Transpose's source renders settle for 100 ms (#1179): foot steps are
 * discrete, while the Pre print's 250 ms window exists for parameter sweeps.
 * Same frame-count measure as above. */
#define LE_CACHE_SOURCE_SETTLE_MS 100

/* How a Transpose source is rendered, shared by the cache worker and the
 * offline renderer so a stem reproduces the live render exactly: the
 * stretcher's cheaper preset with the 8 kHz tonality limit its README
 * recommends, a fixed seed (a re-render of the same key is byte-identical),
 * and a 20 ms equal-power fold over the loop point (le_stretch_render_loop). */
#define LE_CACHE_SOURCE_SEED 1179u
#define LE_CACHE_SOURCE_FOLD_MS 20

/* Allocates the cache state and starts the render worker (control thread; the
 * tail of le_engine_configure, after the pools exist). A thread-start failure
 * leaves engine->cache NULL — caching silently disabled, every lane live. */
void le_cache_init(le_engine* engine);

/* Joins the worker and frees every cache allocation — entries, in-flight job
 * buffers, the state struct (control thread). MUST run before any pool or
 * wet-buffer free [R2]: called from le_engine_stop, the top of
 * le_engine_configure, and le_engine_destroy, in each case after the device
 * (and so the audio thread) is stopped, which is why the frees here need no
 * quiescent handshake. Idempotent; safe when never initialized. */
void le_cache_shutdown(le_engine* engine);

/* One control-thread scheduler pass: collects finished renders (publishing
 * only those whose key still matches [B5]), re-evaluates every lane's key
 * against the settle debounce [B2][B3], enqueues copy-at-enqueue render jobs
 * [R2], and enforces the memory cap via LRU eviction. Called from
 * le_engine_drain_events, i.e. on the UI's snapshot-poll cadence. */
void le_cache_tick(le_engine* engine);

/* #595 (D3): immediately retracts and reclaims the cached entries of lanes
 * [from, to) on [channel] — the lane-count shrink seam. The freed lanes'
 * published wet pointers are retracted (the ordinary graveyard/quiescent
 * discipline, never a raw free) so a later re-grow meets le_lane_reset's
 * defaults with no stale render still published under the lane index. The
 * tick's deactivated-lane reclaim remains the backstop for a render that
 * completes after this call. Control thread; safe with a NULL/never-init
 * cache. */
void le_cache_evict_lanes(le_engine* engine, int32_t channel, int32_t from,
                          int32_t to);

/* ---- Offline chain rendering shared by the cache and the render recipe ----
 *
 * A chain frozen at one instant: the entries an offline render processes, in
 * the form fx_apply_chain reads. `effective` is chain_on && slot enabled
 * (D-EFFBITS); `chan`/`chan_any` the per-entry channel handling (slice 3e). */
typedef struct le_fx_frozen_chain {
  int32_t count; /* entries frozen */
  int32_t pre;   /* leading Pre entries (0 for stages without the split) */
  int32_t type[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t effective[LE_FX_MAX];
  int32_t chan_any;
  le_fx_chan chan[LE_FX_MAX];
} le_fx_frozen_chain;

/* Fills a frozen chain from snapshotted locals (the cache schedulers'). */
void le_fx_frozen_fill(le_fx_frozen_chain* c, int32_t count, int32_t pre,
                       int32_t chain_on, const int32_t* types,
                       const int32_t* enabled,
                       const float params[LE_FX_MAX][LE_FX_PARAMS],
                       const le_fx_chan* chan, int32_t chan_any);

/* Freezes a lane's or a bus's whole chain from its published atomics (the
 * two owners share the field names). */
#define LE_FX_FROZEN_CAPTURE(out, owner)                                      \
  le_fx_frozen_capture((out), &(owner)->a_fx_count, &(owner)->a_fx_pre_count, \
                       &(owner)->a_fx_chain_enabled, (owner)->a_fx_type,      \
                       (owner)->a_fx_enabled, (owner)->a_fx_param,            \
                       (owner)->a_fx_chan_in, (owner)->a_fx_chan_out,         \
                       (owner)->a_fx_chan_gl_bits, (owner)->a_fx_chan_gr_bits, \
                       (owner)->a_fx_chan_level_bits)
void le_fx_frozen_capture(le_fx_frozen_chain* c, _Atomic int32_t* count,
                          _Atomic int32_t* pre, _Atomic int32_t* chain_on,
                          _Atomic int32_t* type, _Atomic int32_t* enabled,
                          _Atomic uint32_t (*param)[LE_FX_PARAMS],
                          _Atomic int32_t* chan_in, _Atomic int32_t* chan_out,
                          _Atomic uint32_t* gl, _Atomic uint32_t* gr,
                          _Atomic uint32_t* level);

/* 1 when any entry in [from, to) has `type` (LE_FX_NONE: any real entry). */
int le_fx_frozen_has(const le_fx_frozen_chain* c, int32_t from, int32_t to,
                     int32_t type);

/* The bits fx_apply_chain reads when only entries [from, to) may process. */
void le_fx_frozen_bits(const le_fx_frozen_chain* c, int32_t from, int32_t to,
                       int32_t out[LE_FX_MAX]);

/* Seeds a calloc'd heap state for entries [0, count): effective entries in
 * [from, to) settled wet, everything else settled bypass, every entry reset,
 * and the entries in [from, to) prepared (a hosted plugin slot stays NULL and
 * renders dry). Returns LE_OK or LE_ERR_INVALID on an allocation failure
 * (never a silent dry slot). The caller frees with le_fx_state_free_buffers. */
int32_t le_fx_frozen_state_init(le_fx_state* fx, const le_fx_frozen_chain* c,
                                int32_t from, int32_t to, int32_t cap);

/* The print: `len` frames of `src` (mono x `vol`, or interleaved stereo when
 * `stereo`) through entries [0, count) of `c`, rendered twice back to back
 * with the second pass kept (RENDER-TWICE-KEEP-SECOND), into `out` (2 x len
 * interleaved). `abort_fn` (may be NULL) is polled every 4096 frames.
 * Returns LE_OK, LE_ERR_INVALID (allocation) or LE_ERR_NOT_READY (aborted). */
int32_t le_fx_print(const le_fx_frozen_chain* c, int32_t count,
                    const float* src, int stereo, float vol, int32_t len,
                    int32_t sample_rate, int32_t cap, float* out,
                    int (*abort_fn)(void*), void* arg);

/* ---- The render recipe's seams into the cache (engine_render.c) ---- */

/* 1 while le_cache_shutdown is joining the worker: a render recipe's print
 * running on the worker stops at its next abort check. */
int le_cache_shutting_down(le_engine* engine);

/* 1 when the callback publishes the track's PCM as readable and every
 * command is settled — the cache's own copy-at-enqueue gate. */
int le_cache_source_ready(le_engine* engine, int32_t channel);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_CACHE_H */
