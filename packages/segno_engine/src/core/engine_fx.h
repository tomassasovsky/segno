/*
 * engine_fx.h — the per-lane effects DSP island's cross-TU surface.
 *
 * The effects DSP lives in engine_fx.c (S1 split from engine.c): the built-in
 * effect kernels, the phase-vocoder / PSOLA octaver, the Freeverb reverb, and
 * the chain runner. This header exposes only what the rest of the engine needs:
 * the chain entry point (audio thread), the per-slot reset/free helpers (audio +
 * control thread), the active-octaver latency query (control thread), and the
 * one-time Hann-window init (control thread). The per-sample kernels (fx_drive,
 * fx_reverb, …) stay private to engine_fx.c.
 *
 * The phase-vocoder / PSOLA tuning constants live here too because the control
 * thread sizes the octaver's heap buffers (LE_PV_N / LE_PV_BINS) in
 * le_fx_prepare_entry — they are the single source of truth shared by the DSP
 * and its allocator.
 */
#ifndef SEGNO_ENGINE_FX_H
#define SEGNO_ENGINE_FX_H

#include <stdint.h>

#include "engine_private.h" /* le_fx_state, le_octaver_state, LE_FX_MAX/PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

/* --- Phase-vocoder octaver (LE_FX_OCTAVER, mode p3 < 0.5) tuning ------------- */
#define LE_PV_N 1024             /* STFT window (power of two) */
#define LE_PV_HOP 256            /* 4x overlap (HOP = N/4: the clean-PV minimum) */
#define LE_PV_BINS (LE_PV_N / 2 + 1)
#define LE_PV_LIFTER (LE_PV_N / 24) /* ~42: cepstral envelope lifter cutoff */

/* --- PSOLA octaver (mode p3 >= 0.5) tuning ---------------------------------- */
#define LE_PSOLA_AHOP 256    /* re-run pitch detection every this many samples */
#define LE_PSOLA_WIN 1600    /* YIN analysis window (integration + max lag) */
#define LE_PSOLA_MAXLAG 800  /* longest lag searched (60 Hz at 48 kHz) */
#define LE_PSOLA_THRESH 0.15f /* YIN absolute threshold for the first dip */
#define LE_PSOLA_THMAX 300   /* grain half-width cap: 2*THMAX < LE_PV_N (fits OLA) */

/* Enable-crossfade length: a slot's dry/wet ramp on an effective-enabled
 * transition, in milliseconds. Short enough to feel instant on a pedal stomp,
 * long enough to be click-free. */
#define LE_FX_ENABLE_RAMP_MS 5
/* Bypass tail drain bounds (le_fx_type_drains slots only): such a bypassed
 * slot keeps running on a silent feed for at most LE_FX_DRAIN_MAX_S seconds,
 * and settles as soon as its tail has stayed under LE_FX_DRAIN_FLOOR for
 * LE_FX_DRAIN_QUIET_MS. */
#define LE_FX_DRAIN_MAX_S 8
#define LE_FX_DRAIN_QUIET_MS 50
#define LE_FX_DRAIN_FLOOR 1e-4f

/* Applies a lane/monitor chain to one stereo sample in place, in chain order.
 * Stageless: every active entry processes both channels on the lane's own `fx`
 * DSP state. [count] is the active length; [types]/[params]/[enabled] are the
 * per-buffer snapshot — [enabled] carries one EFFECTIVE bit per slot
 * (chain-enabled && slot-enabled; NULL = all enabled).
 *
 * An enabled transition ramps over ~LE_FX_ENABLE_RAMP_MS per slot, and how
 * a disable behaves depends on whether the type carries a tail
 * (le_fx_type_drains):
 *  - A draining type (a ring-owning type with no reported latency: delay,
 *    echo, reverb) has the ramp scale its FEED, so new audio moves to the
 *    dry path while the tail already in its rings keeps sounding on a silent
 *    feed. It drains until quiet (LE_FX_DRAIN_FLOOR for
 *    LE_FX_DRAIN_QUIET_MS) or LE_FX_DRAIN_MAX_S, then is skipped entirely
 *    (bit-exact passthrough). This is the accepted "bypass sends new audio
 *    dry and drains old wet tails".
 *  - Every other type crossfades dry/wet on the full feed and settles with
 *    no drain: a kernel with no memory has no tail and a scaled feed would
 *    overshoot both endpoints through its own nonlinearity; a
 *    latency-bearing type (the octaver) holds a delayed copy of the dry
 *    signal, which summed onto the direct path would double the audio for
 *    the latency window; a hosted plugin owns its tail and has no flush
 *    seam, so its frozen tail fades back in on re-enable.
 * Re-enable from a SETTLED bypass resets a built-in slot's DSP state
 * (le_fx_entry_reset + le_fx_entry_clear_rings) at the edge, then ramps in —
 * stale tails never sound; a re-enable that lands mid-ramp or mid-drain keeps
 * the state, because the slot never stopped sounding. Audio thread
 * (le_engine_process), the offline render (perf_render), and the FX chain
 * test. */
void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled);

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay heads, one-pole memory, octaver runtime, reverb lines) so a
 * freshly engaged effect starts clean. Does NOT allocate/free the delay ring or
 * octaver heap buffers (the control thread owns those). Of the
 * enable-crossfade runtime it clears only the DRAIN state: a retyped slot has
 * no tail to drain, and a stale budget would let the next re-enable edge skip
 * its clean reset and read the previous type's ring. The ramp itself is left
 * alone (a type change must not disturb one in flight — see
 * le_fx_enable_seed_settled). Runs on the audio thread (SET_*_FX ring
 * handlers) and the control thread (lane/monitor reset). */
void le_fx_entry_reset(le_fx_state* fx, int slot);

/* Zeroes chain slot [slot]'s delay rings (both channels, [cap] floats each)
 * when allocated: the audio-thread half of "start clean" that
 * le_fx_entry_reset deliberately leaves out. One ring is cap floats, so
 * callers space these (see LE_FX_ENABLE_CLEAR_SPACING). */
void le_fx_entry_clear_rings(le_fx_state* fx, int slot, int cap);

/* Whether a bypassed slot of [type] drains its tail (a ring-owning type with
 * no reported latency: delay, echo, reverb) rather than crossfading out
 * (memoryless or latency-bearing types, and hosted plugins). */
int le_fx_type_drains(int32_t type);

/* Seeds chain slot [slot]'s enable-crossfade runtime SETTLED at enabled so a
 * freshly created (zeroed) le_fx_state does not fade in on first use. Call
 * once after creating/zeroing a standalone le_fx_state (lane/monitor reset,
 * offline render, VST3 plugin processors, test harnesses). */
void le_fx_enable_seed_settled(le_fx_state* fx, int slot);

/* Settles chain slot [slot]'s enable-crossfade runtime at fully BYPASSED.
 * For a slot the chain will NOT process while its effective enabled bit is 0
 * (per-buffer snapshots, le_engine_stop, the offline render's count/type
 * mirror): guarantees a processing gap never strands a ramp mid-fade, so
 * resumption always re-enters through the settled-edge reset (B7). */
void le_fx_enable_force_bypass(le_fx_state* fx, int slot);

/* Frees a chain slot's octaver phase-vocoder heap buffers (both channels) and
 * nulls them. Control-thread only (lane/monitor reset, engine destroy). */
void le_fx_free_octaver(le_fx_state* fx, int slot);

/* Frees EVERY heap buffer a standalone le_fx_state owns (both delay rings per
 * slot + the octaver heap) and nulls the pointers — the one teardown for
 * worker-private offline states (the wet-cache render, the perf_render
 * stems). Does NOT free the le_fx_state struct itself, and must not be used
 * on a LIVE chain owner's state (those interleave per-slot plugin teardown —
 * see le_engine_destroy). A future heap-owning effect adds its free HERE,
 * once, and every offline consumer inherits it. */
void le_fx_state_free_buffers(le_fx_state* fx);

/* Added latency (frames) of chain slot [slot]'s effect of [type] on `fx`, looked
 * up through the effect vtable — 0 for types that add none. Generic so a future
 * latency-bearing effect (or hosted plugin) reports through the same seam. Folded
 * into the published snapshot so the UI can warn about monitoring lag. Control
 * thread (le_max_fx_latency). */
int le_fx_added_latency(const le_fx_state* fx, int slot, int32_t type);

/* Lazily allocates chain slot [slot]'s heap buffers for effect [type] (delay
 * rings, octaver phase-vocoder buffers, …) on the control thread, sized from
 * [cap] (the per-slot ring capacity). Each type owns its allocation behind the
 * effect vtable, so adding an effect needs no edit here. Returns LE_OK (incl.
 * types that allocate nothing), or LE_ERR_INVALID on OOM (all-or-nothing — it
 * frees whatever it allocated this call). Control thread (le_fx_prepare_entry). */
int32_t le_fx_prepare(le_fx_state* fx, int slot, int32_t type, int cap);

/* Writes effect [type]'s default normalized params into out[LE_FX_PARAMS] (all
 * zero for LE_FX_NONE / unknown). Each type owns its defaults behind the vtable.
 * Seeded on a type change so a chain reorder does not wipe the user's tweaks. */
void le_fx_defaults(int32_t type, float out[LE_FX_PARAMS]);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_FX_H */
