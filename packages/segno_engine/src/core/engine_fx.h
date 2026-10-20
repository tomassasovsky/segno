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
                                  * a POWER OF TWO: le_pv_hop_phase masks with
                                  * LE_PV_HOP - 1 */
#define LE_PV_BINS (LE_PV_N / 2 + 1)
#define LE_PV_LIFTER (LE_PV_N / 24) /* ~42: cepstral envelope lifter cutoff */

/* Analysis-hop stagger (#915). Every octaver instance used to start its hop
 * counter at 0, so all instances ran their four length-LE_PV_N FFTs on the
 * same sample index, forever: at 64-frame blocks one callback in four carried
 * the whole pile. Measured on the console at 96 kHz / 64 frames, two
 * synchronized stereo octavers missed the 667 us deadline on every heavy
 * block.
 *
 * An instance's hop PHASE is one of four QUARTERS of the hop, 0, 64, 128 or
 * 192 samples after the reset that seeded it:
 *
 *     phase = LE_PV_STAGGER_QUARTER * ((owner quarter + slot) mod 4)
 *
 * Four points exactly a quarter apart land in four different callbacks of a
 * quarter's length whatever their offset, so the spread holds at any reset
 * offset, including a recipe applied inside a block. Any spread finer than
 * the lattice would not: two phases closer than a quarter can share a
 * callback once shifted. The guarantee, for instances reset at the same
 * instant (one publish, one prepared edit, a session load):
 *
 *  - slots of one chain whose indexes differ mod 4 run in different 64-frame
 *    callbacks, so any four consecutive slots use all four;
 *  - the same slot on tracks t .. t+3 (lane 0), on lanes l .. l+3 of one
 *    track, on monitors c .. c+3, on output buses k .. k+3, and on all-tracks
 *    instances k .. k+3, runs in four different 64-frame callbacks.
 *
 * With four callbacks per hop, a fifth instance always shares one, and two
 * axes cannot both be kept apart: slot s on track t + 1 shares a quarter
 * with slot s + 1 on track t. Instances reset at different instants keep
 * whatever relative phase those instants give them; anchoring to an absolute
 * clock is #941. Spreading only the start does not reduce the work; the hop
 * split in the rack plan (#887, part 9) removes the dependence on phase. */
#define LE_PV_STAGGER_QUARTER (LE_PV_HOP / 4)

static inline int32_t le_fx_hop_mask(uint32_t p) {
  return (int32_t)(p & (uint32_t)(LE_PV_HOP - 1));
}

/* The base phase of an owner whose quarter is [q] (taken mod 4). */
static inline int32_t le_fx_quarter_seed(uint32_t q) {
  return (int32_t)((q & 3u) * (uint32_t)LE_PV_STAGGER_QUARTER);
}

/* The hop-stagger seed (le_fx_state::hop_seed) of track [track]'s lane
 * [lane] (le_fx_bus_hop_seed: its bus). le_engine_create seeds
 * every owner through these functions, and the OFFLINE renderers that stand
 * in for a live owner (the wet cache, the render recipe, the performance stem
 * render) copy the seed of the owner they reproduce: a different seed is a
 * different phase-vocoder realization of the same octaver, which the cache
 * would swap in at a loop top as a step (a click), and which a stem would
 * export as something other than what was heard.
 *
 * Lane l of track t takes quarter t + l, so the same slot on consecutive
 * tracks and on consecutive lanes spreads. The bus takes t + 2: with nine
 * owners per track and four quarters something must share, and lane 0 and
 * the bus are the pair a track most often uses together. The other kinds are
 * offset so the first of each runs apart from track 0's lane 0 and bus:
 * monitor c takes c + 1 (a live input's effects beside a loop's), output bus
 * k takes k + 3. The all-tracks instances take k + 2, the one pairing left to
 * share with a track bus, because a chain on every track at once and one on
 * a single track's bus are the least likely to both hold pitch effects.
 *
 * Unsigned arithmetic, masked: perf_render's track index comes from a
 * manifest on disk and is only checked for being non-negative. */
static inline int32_t le_fx_lane_hop_seed(int32_t track, int32_t lane) {
  return le_fx_quarter_seed((uint32_t)track + (uint32_t)lane);
}
static inline int32_t le_fx_bus_hop_seed(int32_t track) {
  return le_fx_quarter_seed((uint32_t)track + 2u);
}
static inline int32_t le_fx_monitor_hop_seed(int32_t source) {
  return le_fx_quarter_seed((uint32_t)source + 1u);
}
static inline int32_t le_fx_output_hop_seed(int32_t bus) {
  return le_fx_quarter_seed((uint32_t)bus + 3u);
}
static inline int32_t le_fx_all_tracks_hop_seed(int32_t bus) {
  return le_fx_quarter_seed((uint32_t)bus + 2u);
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
/* Bypassed tail-owning slots settle only after a complete delay-ring
 * horizon below the floor, with this minimum quiet window. */
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
 *    a complete delay-ring horizon, at least LE_FX_DRAIN_QUIET_MS),
 *    then is skipped entirely
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
/* Applies one whole-track gain between the Pre prefix and Post suffix. */
void fx_apply_chain_with_gain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled, int gain_at, float gain);

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

/* Seeds slot [slot]'s OCTAVER runtime settled at [params]: the three param
 * smoothers already at their targets and the mode crossfade already resolved
 * onto the mode params[3] selects. The octaver's analogue of
 * le_fx_enable_seed_settled, for an offline render standing in for a lane
 * whose octaver has been running since before the capture: from
 * le_fx_entry_reset's state the shift smoother ramps ~5 ms up from unison,
 * and a PSOLA slot spends ~15 ms fading the wet leg out and ~15 ms back in
 * before the mode flips, none of which the live lane was doing.
 *
 * It cannot settle the analysis-hop phase: the live counter is its phase plus
 * an elapsed-frame count nothing records. Caller passes an octaver slot (no
 * type check). Control thread / offline only, after le_fx_entry_reset. */
void le_fx_octaver_seed_settled(le_fx_state* fx, int slot, const float* params);

/* Settles chain slot [slot]'s enable-crossfade runtime at fully BYPASSED.
 * For a slot the chain will NOT process while its effective enabled bit is 0
 * (per-buffer snapshots, le_engine_stop, the offline render's count/type
 * mirror): guarantees a processing gap never strands a ramp mid-fade, so
 * resumption always re-enters through the settled-edge reset (B7). */

/* Whether slot [slot]'s enable ramp is already parked at bypass, so
 * [le_fx_enable_force_bypass] would write nothing.
 *
 * The per-buffer settle sweep walks every slot up to LE_FX_MAX, and beyond a
 * chain's active count almost all of them are in exactly this state — zeroed
 * at reset and left there. Audio-thread-owned plain reads, so the check costs
 * less than the published bit the sweep would otherwise load. */
int le_fx_enable_settled_bypassed(const le_fx_state* fx, int slot);
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

/* --- Resumable YIN pass ------------------------------------------------------
 *
 * le_psola_detect_band split at its two pausable points, so a caller that
 * cannot afford the whole (lags x integration) difference function in one
 * callback can spread it. See le_yin_pass in engine_private.h for why, and
 * tuner_slice in engine_process.c for the only sliced caller. All three run on
 * the audio thread and allocate nothing.
 *
 * Sets up a pass over `n` contiguous samples of `x` at `sr` Hz, searching
 * [min_hz, max_hz]. `dp` is the caller's d'(tau) scratch, `dp_cap` its length
 * in floats; the pass needs maxlag + 1, where maxlag is min(sr/min_hz,
 * LE_PSOLA_MAXLAG, n/2). Both `x` and `dp` are borrowed and must stay alive
 * and unchanged until le_yin_finish. Returns 0 — no pass started, and the
 * caller should read the frame as unpitched — for a nonsense band, a window
 * too short for the band, a `dp` too small, or a frame under the silence
 * floor. */
int le_yin_begin(le_yin_pass* p, const float* x, int n, int sr, int min_hz,
                 int max_hz, float* dp, int dp_cap);

/* Accumulates lags until at least `budget` difference-function inner
 * iterations have been spent, or the pass completes. A negative budget runs
 * the pass to completion in one call. One whole lag always runs, so a budget
 * under one integration length still makes progress. Returns 1 once every lag
 * is in (and le_yin_finish may be called), else 0. */
int le_yin_step(le_yin_pass* p, long budget);

/* Peak-picks a COMPLETED pass: writes the parabolic-interpolated period in
 * samples to *out_period and the voicing confidence in [0,1] to *out_voiced,
 * and returns 1 when the frame reads as confidently voiced. */
int le_yin_finish(const le_yin_pass* p, float* out_period, float* out_voiced);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_FX_H */
