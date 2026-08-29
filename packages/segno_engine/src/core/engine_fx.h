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
#define LE_PV_HOP 256            /* 4x overlap (HOP = N/4: the clean-PV minimum);
                                  * a POWER OF TWO — le_fx_lane_hop_seed and
                                  * le_pv_hop_phase mask with LE_PV_HOP - 1 */
#define LE_PV_BINS (LE_PV_N / 2 + 1)
#define LE_PV_LIFTER (LE_PV_N / 24) /* ~42: cepstral envelope lifter cutoff */

/* Analysis-hop stagger: the three axes an octaver instance is addressed by, and
 * the step each one moves its hop phase by within [0, LE_PV_HOP).
 *
 * The point of the stagger is that instances which run TOGETHER hop on
 * different sample indices, so their length-LE_PV_N FFT frames land in
 * different audio callbacks instead of all in one. The runs that actually
 * occur are short and they are the three axes below, so the steps are chosen
 * to maximise the MINIMUM spacing along each — verified exhaustively over the
 * odd-and-even step space, these are the joint optimum:
 *
 *   OWNER  8 tracks (plus one group holding the monitor inputs and the master
 *          insert), i.e. the SAME lane and slot on every track — the shape a
 *          per-track octaver takes. Step 27 -> 27 apart.
 *   LANE   one track's 8 lanes and then its bus, 9 in a row. Step 57 -> 28
 *          apart, the optimum for 9 points in 256.
 *   SLOT   one chain's 8 slots. Step 32 -> exactly 32 apart, so with the
 *          appliance's 32-frame callback each slot hops in its OWN callback.
 *
 * All 81 chain owners get distinct base phases, and the full 9 x 9 x 8 space
 * of possible instances covers all 256 phases (the most a 256-wide phase can
 * do for 648 addresses). NOTE the axes must stay SEPARATE: folding owner and
 * lane into one running index and scaling it by a single multiplier m makes
 * the owner step 9m (mod 256), which for every m collapses one of the two
 * axes into a clump far tighter than a callback. */
#define LE_PV_STAGGER_OWNER_STEP 27
#define LE_PV_STAGGER_LANE_STEP 57
#define LE_PV_STAGGER_SLOT_STEP 32

/* The hop-stagger seed (le_fx_state::hop_seed) that le_engine_create hands
 * track [track]'s lane [lane]: that chain's BASE analysis-hop phase, to which
 * engine_fx.c's le_pv_hop_phase adds the per-slot step. The engine numbers
 * every chain owner it holds through this one function: a track's LE_MAX_LANES
 * lanes, then its bus one past them at lane == LE_MAX_LANES; the monitor
 * inputs and the master insert are lanes 0..LE_MAX_MONITORED_INPUTS of the one
 * group past the last track, track == LE_MAX_TRACKS.
 *
 * Exposed (rather than kept private to engine.c) because the OFFLINE renderers
 * that stand in for a live lane — the loop-stage wet cache (engine_cache.c)
 * and the performance stem render (perf_render.c) — build their own heap
 * le_fx_state and MUST seed it with the seed of the lane they reproduce. A
 * different seed is a different phase-vocoder realization of the same octaver:
 * the cache would then swap a differently-realized wet in at a loop top (a
 * step discontinuity — a click), and an exported stem would not reproduce what
 * was heard. */
static inline int32_t le_fx_lane_hop_seed(int32_t track, int32_t lane) {
  /* Unsigned and masked, not signed-and-%: the only caller that does not pass
   * a bounded engine index is perf_render, whose track comes from a manifest
   * on disk and is only checked for being non-negative. Signed overflow there
   * would be UB, and C's sign-preserving % would then hand back a NEGATIVE
   * phase — which le_pv_tick uses to index the OLA accumulator. */
  const uint32_t base = (uint32_t)track * (uint32_t)LE_PV_STAGGER_OWNER_STEP +
                        (uint32_t)lane * (uint32_t)LE_PV_STAGGER_LANE_STEP;
  return (int32_t)(base & (uint32_t)(LE_PV_HOP - 1));
}

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

/* Applies a lane/monitor chain to one stereo sample in place, in chain order.
 * Stageless: every active entry processes both channels on the lane's own `fx`
 * DSP state. [count] is the active length; [types]/[params]/[enabled] are the
 * per-buffer snapshot — [enabled] carries one EFFECTIVE bit per slot
 * (chain-enabled && slot-enabled; NULL = all enabled).
 *
 * An enabled transition crossfades dry/wet over ~LE_FX_ENABLE_RAMP_MS per
 * slot. Disable fades the slot's wet output — tail included — to dry, then
 * skips the slot entirely once settled (bit-exact passthrough, NO tail spill
 * on bypass [B7]: the tail never keeps ringing into the dry signal).
 * Re-enable resets a built-in slot's DSP state (le_fx_entry_reset + a
 * ring-content clear) at the edge, then ramps in from dry — stale tails
 * never sound. A hosted plugin slot keeps its own internal state (no flush
 * seam yet); its frozen tail fades back in. Audio thread
 * (le_engine_process), the offline render (perf_render), and the FX chain
 * test. */
void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled);

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay heads, one-pole memory, octaver runtime, reverb lines) so a
 * freshly engaged effect starts clean. Does NOT allocate/free the delay ring or
 * octaver heap buffers (the control thread owns those), and does NOT touch the
 * enable-crossfade runtime (a type change must not disturb an in-flight enable
 * ramp — see le_fx_enable_seed_settled). Runs on the audio thread
 * (SET_*_FX ring handlers) and the control thread (lane/monitor reset). */
void le_fx_entry_reset(le_fx_state* fx, int slot);

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
