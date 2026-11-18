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

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
#include <pmmintrin.h> /* _MM_SET_DENORMALS_ZERO_MODE (DAZ) */
#include <xmmintrin.h> /* _MM_SET_FLUSH_ZERO_MODE (FTZ) */
#endif

/* Flush denormals to zero on the calling thread. Decaying FX tails (reverb/
 * delay/phase-vocoder) trend toward ~1e-30, and denormal arithmetic can be
 * orders of magnitude slower — a CPU spike that shows up as a buffer underrun
 * (dropout / click), not as wrong audio. FTZ+DAZ make the FPU treat those as
 * zero. Per thread: the audio thread sets it each callback (negligible cost),
 * and every worker that runs an FX chain offline (the wet cache and render
 * worker, the stem render) sets it at its start, so an offline render rounds
 * the way the live chain does (#887 part 4). No-op where unsupported; the
 * inaudible denormals simply remain. */
static inline void le_flush_denormals(void) {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#elif defined(__aarch64__)
  uint64_t fpcr;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
  fpcr |= (1ull << 24); /* FZ: flush-to-zero */
  __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr));
#endif
}

#ifdef __cplusplus
extern "C" {
#endif

/* --- Phase-vocoder octaver (LE_FX_OCTAVER, mode p3 < 0.5) tuning ------------- */
/* The rate the octaver's kernel runs at, whatever the engine's: at other
 * rates fx_octaver_run resamples to and from it (#1547). */
#define LE_OCT_RATE 48000
/* Each of fx_octaver_run's two rings, samples (a power of two). */
#define LE_OCT_RS_RING 512
#define LE_PV_N 1024             /* STFT window (power of two) */
#define LE_PV_HOP 256            /* 4x overlap (HOP = N/4: the clean-PV minimum);
                                  * a POWER OF TWO: le_pv_hop_phase masks with
                                  * LE_PV_HOP - 1 */
#define LE_PV_BINS (LE_PV_N / 2 + 1)
#define LE_PV_LIFTER (LE_PV_N / 24) /* ~42: cepstral envelope lifter cutoff */
/* The hop split (#887 part 9): a frame's work runs in steps over the
 * thirteen slots 16 ticks apart from its analysis to its synthesis (#1755;
 * four stages a quarter apart before it), so a 32-frame callback at the
 * kernel's 48 kHz carries two slots, whatever the hop phase. A longer
 * period runs more of them in one callback and gains nothing, but pays the
 * same latency: the engine keeps one schedule for every host. The synthesis runs
 * LE_PV_SYNTH_TICK ticks after the analysis and its first sample is emitted
 * on that tick, so the output runs that much later than an unsplit frame's:
 * the octaver's latency is LE_PV_LATENCY in both modes (PSOLA reads its
 * input the same ticks further back, so the dry tap does not move on a mode
 * switch). */
#define LE_PV_SYNTH_TICK (3 * LE_PV_HOP / 4)
#define LE_PV_LATENCY (LE_PV_N + LE_PV_SYNTH_TICK)
/* The overlap-add accumulator: a frame written at the synthesis tick ends on
 * its last element. */
#define LE_PV_OUT LE_PV_LATENCY
/* A frame's state between stages, per channel: the window (reused for the
 * inverse transform), the spectrum, magnitude, true frequency and envelope;
 * then a second voice's synthesis spectrum and its running phases (the Dual
 * Octaver's Octave 2, #1464), which persist from frame to frame; then the
 * shift's own, carried between its two steps (#1755). */
#define LE_PV_SCRATCH (LE_PV_N + 11 * LE_PV_BINS)

/* Analysis-hop stagger (#915). Every octaver instance used to start its hop
 * counter at 0, so all instances ran their four length-LE_PV_N FFTs on the
 * same sample index, forever: at 64-frame blocks one callback in four ran
 * every instance's FFTs. Measured on the console at 96 kHz / 64 frames, two
 * synchronized stereo octavers missed the 667 us deadline on every heavy
 * block.
 *
 * An instance's hop PHASE is one of four QUARTERS of the hop:
 *
 *     phase = LE_PV_STAGGER_QUARTER * ((owner quarter + slot) mod 4)
 *
 * and its analysis ticks (the PV frame's first stage, or PSOLA's YIN pass)
 * fall on the engine frames c with (c + phase) mod LE_PV_HOP equal to 0
 * (#941); the PV frame's later steps follow in its slots (above). The hop is
 * anchored to the engine's own frame count, not to the instant the instance
 * was reset, so the spread holds for instances added at any time: one added
 * to a second track long after the first keeps its quarter, and so does a
 * slot a chain stomp re-enables late. With callbacks of a quarter's length
 * (64 frames at the console's period), four instances on four quarters run
 * their heavy ticks in four different callbacks:
 *
 *  - slots of one chain whose indexes differ mod 4, so any four consecutive
 *    slots use all four;
 *  - the same slot on tracks t .. t+3 (lane 0), on lanes l .. l+3 of one
 *    track, on monitors c .. c+3, on output buses k .. k+3, and on all-tracks
 *    instances k .. k+3.
 *
 * With four callbacks per hop, a fifth instance always shares one, and two
 * axes cannot both be kept apart: slot s on track t + 1 shares a quarter
 * with slot s + 1 on track t. Spreading the work does not reduce it. Since
 * the hop split (above), every quarter carries some of a PV frame's steps
 * whatever the phase, so the phase only decides which steps land in which
 * callback; PSOLA's YIN pass starts on one tick a hop. */
#define LE_PV_STAGGER_QUARTER (LE_PV_HOP / 4)

/* Engine frame [top]'s place on the grid of [len]-frame laps (#1620): where a
 * clock LFO's print is keyed, since such an LFO repeats lap after lap only
 * from tops on the same grid. */
static inline uint32_t le_fx_lap_position(uint32_t top, int32_t len) {
  return len > 0 ? top % (uint32_t)len : 0u;
}

/* Whether [ent] may play from a lap that began at engine frame [top]: always
 * for a print without a clock LFO, and for one with a clock LFO only on the
 * lap grid it was rendered from (#1620). */
static inline int le_wet_entry_lap_matches(const le_wet_entry* ent,
                                           uint32_t top) {
  return ent->lap_tag == 0 ||
         ent->lap_tag == le_fx_lap_position(top, ent->len) + 1u;
}

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
#define LE_PSOLA_MAXLAG 800  /* the YIN detector's longest lag (le_yin_begin) */
/* Pitch detection (#913), at the kernel's LE_OCT_RATE. A coarse YIN pass
 * runs on the window decimated by LE_PSOLA_DECIM (24 kHz): LE_PSOLA_DWIN
 * decimated samples, 33 ms, searched from LE_PSOLA_MIN_HZ to
 * LE_PSOLA_MAX_HZ. A narrow pass over the last LE_PSOLA_RAW samples refines
 * a voiced one to a kernel sample, as the tuner does. A pass starts every
 * hop, about every 5 ms, and averages LE_PSOLA_WORK_PER_TICK iterations a
 * tick (a credit, carried tick to tick), so it spreads over its hop instead
 * of landing in one callback. A 64-frame callback is charged at most
 * 64 x 896 = 57k of it, plus one lag of overshoot; it works out up to
 * LE_YIN_GROUP - 1 lags more ahead of their charge (le_lag_sums), each a
 * fraction of a lag alone's cost (#1755). */
#define LE_PSOLA_DECIM 2
#define LE_PSOLA_DWIN 800
#define LE_PSOLA_MIN_HZ 60
#define LE_PSOLA_MAX_HZ 1000
#define LE_PSOLA_RAW 2048
#define LE_PSOLA_WORK_PER_TICK 896
/* Where PSOLA's detection state starts in the octaver scratch (16-byte
 * aligned, after the frame arrays), and the scratch's whole length. */
#define LE_PS_STATE_OFF ((LE_PV_SCRATCH + 3) & ~3)
/* What fx_octaver keeps between samples and the phase vocoder between a
 * frame's steps (#1755), after PSOLA's state in the scratch (heap), so the
 * octaver's state in le_fx_state keeps the size the mixer's structs embed:
 * the shift's ratio for the smoothed shift ratio_shift and the gain dip's
 * gain for its position dip_xfade (cached: 0 until the first), and the
 * shift's peaks, the region it is at and that region's first bin. */
typedef struct le_oct_aux {
  int32_t cached;
  float ratio_shift;
  float ratio;
  float dip_xfade;
  float dip_g;
  int32_t shift_np;
  int32_t shift_r;
  int32_t shift_start;
} le_oct_aux;
#define LE_OCT_AUX_OFF \
  (LE_PS_STATE_OFF + (int)((sizeof(le_psola_pass) + 3) / 4))
#define LE_PV_SCRATCH_ALLOC \
  (LE_OCT_AUX_OFF + (int)((sizeof(le_oct_aux) + 3) / 4))
static inline le_psola_pass* le_ps(le_octaver_state* o) {
  return (le_psola_pass*)(void*)(o->scratch + LE_PS_STATE_OFF);
}
static inline le_oct_aux* le_oa(le_octaver_state* o) {
  return (le_oct_aux*)(void*)(o->scratch + LE_OCT_AUX_OFF);
}
#define LE_PSOLA_THRESH 0.15f /* YIN absolute threshold for the first dip */
/* Grain half-width cap. A grain is laid around LE_PV_N / 2 ahead of the read
 * pointer in the LE_PV_N-long OLA accumulator, so its half-width must stay
 * under LE_PV_N / 2: 500 keeps grains overlapping for periods up to 1000
 * samples (48 Hz), past the detector's longest (LE_PSOLA_MIN_HZ). */
#define LE_PSOLA_THMAX 500
/* How far behind the head PSOLA reads its input, so its latency matches the
 * split phase vocoder's (LE_PV_LATENCY). */
#define LE_PSOLA_LAG (LE_PV_LATENCY - LE_PV_N)
/* The deepest FIFO read of either mode: PSOLA's refinement window, which
 * lies past its decimated pitch window, the dry tap and the PV window, and
 * is copied when the coarse pass finishes, up to a hop after the window
 * ended (le_psola_coarse_done). A smaller ring would wrap onto recent input,
 * so fx_octaver passes such a slot through dry. */
#define LE_OCT_REACH (LE_PSOLA_LAG + LE_PSOLA_RAW + LE_PSOLA_AHOP)

/* --- The Dual Octaver's low band (#1467) -------------------------------------
 * The vocoder's 1024-point frame cannot part a bass note from the octave
 * below it (a bin is 93.75 Hz at 96 kHz), so its down voices fell 25 to 40
 * dB short on bass where the Looper X's sit at 0 dB. Below the crossover the
 * Dual Octaver's down voices come from the time domain instead: the input
 * low-passed (a Linkwitz-Riley pair at LE_OCT_LOW_HZ), read back at the
 * voice's ratio by a tap that jumps forward one detected period whenever it
 * falls a period behind, a short fade covering each jump (pitch-synchronous
 * grains, resampled so the formants move with the pitch, as the vocoder's
 * do here). The vocoder hands over the regions below the crossover in the
 * same proportion, so the two bands sum to one voice. Detection is YIN on
 * the band decimated by LE_OCT_LOW_DECIM, from LE_OCT_LOW_MIN_HZ to
 * LE_OCT_LOW_MAX_HZ (1.25 x the crossover; the band fades out by 1.15 x);
 * a band it hears no pitch in (silence, a chord) fades out and the vocoder
 * plays it as before. The taps centre on the octaver's latency less the
 * crossover's group delay, so the effect's latency stays LE_PV_LATENCY.
 *
 * Fit to the s15bass and s7oct captures (#891, #1467). The Looper X's down
 * voices sit at 0.0 dB from 110 Hz to 4 kHz, 1.3 dB down (Octave 1) and 3.0
 * dB down (Octave 2) at 82 Hz, and it shifts nothing at 41 or 55 Hz (it
 * plays the input as it is). So the band starts at 60 Hz and comes in over
 * a smoothstep to LE_OCT_LOW_FULL_HZ, which puts Octave 1 at -1.3 dB at 82
 * Hz; below 60 Hz the vocoder plays the down voices as before. The
 * crossover splits the error on the voice's second harmonic evenly between
 * the 82 and 110 Hz harmonic tones (the capture: -11.3 and -6.0 dB; 200 Hz
 * gave -9.0 and -13.2, 250 Hz -7.4 and -9.9, 300 Hz -6.7 and -8.1). */
#define LE_OCT_LOW_HZ 250.0
#define LE_OCT_LOW_DECIM 16 /* 3 kHz */
#define LE_OCT_LOW_MIN_HZ 60
#define LE_OCT_LOW_FULL_HZ 89.0f
#define LE_OCT_LOW_MAX_HZ 312

/* The cadence of a heap-state kind's update hook (le_fx_kinds), in engine
 * frames: it runs once per this many frames of the engine clock, at a phase
 * set by the owner's hop-stagger seed and the slot, live and offline alike,
 * so an offline render recomputes on the same frames as the chain it
 * reproduces. A power of two, divisible by four. */
#define LE_FX_UPDATE_FRAMES 32

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
 *  - A draining type (one that holds a tail in rings and reports no
 *    latency: delay, echo and reverb, whose rings `prepare` allocates, and
 *    the spring, whose ring is in its kind block) has the ramp scale its
 *    FEED, so new audio moves to the
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

/* Entries [from, count) of the chain alone (#1741): the earlier ones neither
 * run nor have their state touched. With fx_apply_chain over [0, from)
 * first ([counted] 1: that walk counted the frame), the two are the whole
 * chain with the signal between them in hand: the heard image's tap of an
 * input chain's Pre run, and a lane's Post run over its heard image. */
void fx_apply_chain_from(le_fx_state* fx, int sr, int cap, float* l,
                         float* r, int from, int count, const int32_t* types,
                         const float params[LE_FX_MAX][LE_FX_PARAMS],
                         const int32_t* enabled, int counted);

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay heads, one-pole memory, octaver runtime, reverb lines) so a
 * freshly engaged effect starts clean. [type] is the kind the slot runs from
 * here on: the octaver runtime and its heap buffers are touched only for a
 * kind of the octaver family (le_fx_type_hops), because the control thread
 * may be preparing those buffers for a coming retype while the slot runs
 * another kind (#1522), and the kind's delay rings, when allocated, become
 * known to the calling thread (le_fx_state::ring_known). A live slot's
 * buffers are prepared before its kind lands, so perf_render, which replays
 * retypes and Cuts, prepares first too. Does NOT allocate/free the delay
 * ring or octaver heap buffers (the control thread owns those). Of the
 * enable-crossfade runtime it clears only the DRAIN state: a retyped slot has
 * no tail to drain, and a stale budget would let the next re-enable edge skip
 * its clean reset and read the previous type's ring. The ramp itself is left
 * alone (a type change must not disturb one in flight — see
 * le_fx_enable_seed_settled). Runs on the audio thread (SET_*_FX ring
 * handlers) and the control thread (lane/monitor reset). */
void le_fx_entry_reset(le_fx_state* fx, int slot, int32_t type);

/* Zeroes the delay rings chain slot [slot] runs on as [type] ([cap] floats
 * each) when allocated: the audio-thread half of "start clean" that
 * le_fx_entry_reset deliberately leaves out. Of the delay rings, only those
 * [type] runs on or an earlier kind of the slot left: another may be in the
 * making on the control thread for a coming retype (#1522). One ring is cap
 * floats, so callers space these (see LE_FX_ENABLE_CLEAR_SPACING). */
void le_fx_entry_clear_rings(le_fx_state* fx, int slot, int cap,
                             int32_t type);

/* Settles slot [slot] for an entry of [type] that has just replaced another
 * there (a recipe's renewed slot): its DSP state is reset, and the slot
 * re-enters through the enable edge when it was [sounding] (inside the chain's
 * active count, so the chain was running the entry it held) or holds a tail
 * (delay rings, or a draining kind's ring). The edge ramps the new entry in
 * over LE_FX_ENABLE_RAMP_MS, so it never switches in at full in one sample
 * over the one the chain was running (#1452), and clears the rings spaced by
 * LE_FX_ENABLE_CLEAR_SPACING, so the old entry's tail never sounds through
 * the new one and no one callback clears every ring. A slot past the old
 * count keeps its ramp: a slot leaving the chain dropped its enabled bit, so
 * the per-buffer sweep parked it at bypass, and a slot that never held an
 * entry takes the new one settled from its first frame, as a render seeds it.
 * Audio thread (le_fx_recipe_apply). */
void le_fx_entry_renew(le_fx_state* fx, int slot, int32_t type, int sounding);

/* Whether a bypassed slot of [type] drains its tail (a ring-owning type with
 * no reported latency: delay, echo, reverb) rather than crossfading out
 * (memoryless or latency-bearing types, and hosted plugins). */
int le_fx_type_drains(int32_t type);

/* Whether [type] runs a free-running modulator (the chorus's and the Mod's
 * LFOs, the doubler's random delays, the vinyl's noise, the degrade's hold, the
 * LPF's self-oscillation or its beat-locked LFO), which sounds different
 * on each lap of a loop: a chain holding one is never wet-cached, since one
 * lap's print would repeat where live does not. Any thread. */
int le_fx_type_free_running(int32_t type);

/* Whether an entry of [type] at settings [p] (its first
 * le_fx_param_width(type) cells), at engine rate [sr], runs a free-running
 * modulator that is heard: le_fx_type_free_running, with its mix (or the
 * vinyl's noise, the degrade's hold below [sr], the LPF's resonance past
 * its oscillation point or its LFO depth above 0; the Mod's depth and mix,
 * or the depth alone for its tremolo) actually doing something; the
 * doubler always is. On the octaver's kernel (#1624): the octaver's mix, the
 * Dual Octaver's mix with a voice up, the Whammy off unison; Smart Tune
 * always.
 * Any thread. */
int le_fx_entry_free_running(int32_t type, const float* p, int sr);

/* Whether [type] runs an LFO on the engine clock (#1620): the tremolo and
 * the echo's wow (le_clock_lfo, engine_fx.c). Such a print is rendered
 * against the clock of the loop top it stands in for, so the caches key it
 * on where that top sits on the loop's lap grid. */
int le_fx_type_clock_lfo(int32_t type);

/* Whether an entry of [type] at settings [p], heard, runs a clock LFO that
 * does not complete a whole number of cycles (within a tolerance per kind,
 * engine_fx.c) in a
 * loop of [len] frames at [sr]: each lap of it sounds different, so it plays
 * live, like a free-running modulator (#1620). Any thread. */
int le_fx_entry_lfo_drifts(int32_t type, const float* p, int32_t len, int sr);

/* Whether slot [slot] of [fx], holding [type], has a clock LFO still sliding
 * back onto the clock after a rate move (#1620). Audio thread (the thread
 * that runs the chain). */
int le_fx_lfo_relocking(const le_fx_state* fx, int slot, int32_t type);

/* Seeds chain slot [slot]'s enable-crossfade runtime SETTLED at enabled so a
 * freshly created (zeroed) le_fx_state does not fade in on first use. Call
 * once after creating/zeroing a standalone le_fx_state (lane/monitor reset,
 * offline render, test harnesses). */
void le_fx_enable_seed_settled(le_fx_state* fx, int slot);

/* Settles slot [slot]'s enable crossfade at [effective]: settled wet when 1,
 * settled bypass when 0. How an offline render (the wet cache, the render
 * recipe, the stem render) starts each slot where the live owner holds it:
 * a calloc'd zero state would fade the chain in at frame 0, and an enabled
 * seed on a disabled slot would fade out an effect that was never heard. */
void le_fx_enable_seed_at(le_fx_state* fx, int slot, int effective);

/* Makes slot [slot]'s rack output side (le_fx_state::rack_mix) settle at its
 * rack's state on the next sample instead of ramping there. For a fresh
 * structure (a recipe landing) and for a print engaging, where the rendered
 * audio already carries the rack's output side and the live chain must stop
 * applying it at once. le_fx_enable_seed_settled does it too. */
void le_fx_rack_reset(le_fx_state* fx, int slot);

/* Seeds slot [slot]'s OCTAVER runtime settled at [params]: its param
 * smoothers already at their targets and no mode crossfade under way. The
 * octaver's analogue of le_fx_enable_seed_settled, for an offline render
 * standing in for a lane whose octaver has been running since before the
 * capture: from
 * le_fx_entry_reset's state the shift, tone and mix smoothers ramp for
 * ~5 ms from unison and dry, which the live lane was not doing. The mode,
 * and the Dual Octaver's switched shift, need no seeding: a slot just reset
 * takes them within a latency (fx_octaver, #1482).
 *
 * The analysis-hop schedule needs no settling: it follows the clock the
 * render sets (le_fx_state::clock), which reproduces the live one. Caller
 * passes a slot on the hop (le_fx_type_hops) and the octaver settings it
 * runs (le_fx_octaver_settings, whose cell 5 sets the wet voice's level as
 * 1 minus it, below 0 for a boost, so raw octaver params, zero there, seed
 * it at full level); no type check.
 * Control thread / offline only, after le_fx_entry_reset. */
void le_fx_octaver_seed_settled(le_fx_state* fx, int slot, const float* params);
/* Whether [type] runs the octaver's kernel on the hop clock (the octaver,
 * the Whammy, the Dual Octaver and Smart Tune): the kinds an offline render
 * (the render recipe, the stems) seeds on the live owner's hop. */
int le_fx_type_hops(int32_t type);
#ifdef LE_NATIVE_TESTS
/* Native tests only: when set, the chain hands each pitch-kind entry
 * (le_fx_type_hops) to this instead of its kernel, and the kernel runs only
 * when it returns 0 (test_pitch_oracle.c runs the kernels frozen before
 * #1755 through it, test/pitch_ref/pitch_ref.c). */
typedef int (*le_fx_test_process_fn)(le_fx_state* fx, int slot, int32_t type,
                                     int sr, int cap, float* l, float* r,
                                     const float* p);
extern le_fx_test_process_fn le_fx_test_process_hook;
/* Smart Tune's per-tick settings (engine_fx.c), for that copy. */
void le_fx_test_st_tick(le_fx_state* fx, int slot, const float* p, float* q);
#endif
/* Puts a Pumper slot's depth glide at [params]'s, and its duck at the one
 * the beat of the frame [fx] is at gives, as a slot that has been running
 * is: what an offline render seeds a Pumper with, once its tempo and clock
 * are set. */
void le_fx_pumper_seed_settled(le_fx_state* fx, int slot, const float* params,
                               int sr);
/* The octaver settings slot [s] of [type] runs: [params] themselves for the
 * octaver (cells 5 to 8 zero: no cut, a linear mix, no second voice, no low
 * band), the
 * Whammy's pedal and range mapped for the Whammy, Smart Tune's fully wet
 * PSOLA at unison (its shift follows the detected pitch), and the Dual
 * Octaver's high mode, Octave 1 level, mix and Octave 2 level mapped for it
 * (the voice's level as 1 minus cell 5, which goes below 0 where its trim
 * boosts; 1 in cell 6: an equal-power mix, a switched shift and a second
 * voice, Octave 2's level in cell 7, and Octave 1's level untrimmed in
 * cell 8, for the low band, #1467). [out] holds LE_FX_PARAMS. */
void le_fx_octaver_settings(int32_t type, const float* params, float* out);

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

/* The octaver's formant envelope: the low-quefrency cepstrum of log|X|
 * (quefrencies below LE_PV_LIFTER) turned back into a magnitude, for the
 * LE_PV_BINS magnitudes in [mag], into env[LE_PV_BINS]. Reads the shared
 * octaver tables, so an octaver must have been prepared (le_fx_prepare) first.
 * Audio thread (the phase-vocoder frame) and the native test. */
void le_octaver_envelope(const float* mag, float* env);

/* Frees a chain slot's octaver phase-vocoder heap buffers (both channels) and
 * nulls them. Control-thread only (lane/monitor reset, engine destroy). */
void le_fx_free_octaver(le_fx_state* fx, int slot);
/* The heap a Dual Octaver slot's low band (#1467) takes, both channels, on
 * top of the octaver's buffers: its kernel runs at LE_OCT_RATE at every
 * rate. Any thread. */
size_t le_fx_low_band_bytes(void);
/* The heap an octaver kind's slot takes at [sr] on top of its input ring:
 * its kernel's buffers and, away from LE_OCT_RATE, its resamplers' rings,
 * both channels. Any thread. */
size_t le_fx_octaver_bytes(int sr);

/* Frees every heap buffer chain slot [slot] owns: its delay rings, its
 * octaver buffers and its per-kind state. The one call an owner reset or
 * destroy makes per slot, so a future heap-owning kind adds its free to it
 * once. Control-thread only, where the audio thread no longer reads the
 * slot. */
void le_fx_free_slot(le_fx_state* fx, int slot);

/* Frees chain slot [slot]'s per-kind state (every block it holds) and
 * forgets it. Control-thread only, where the audio thread no longer reads
 * the slot, like le_fx_free_delay. */
void le_fx_free_kinds(le_fx_state* fx, int slot);

/* Frees the per-kind table itself, after le_fx_free_kinds on every slot.
 * Owner destroy only (le_engine_destroy, le_fx_state_free_buffers). */
void le_fx_free_kind_table(le_fx_state* fx);

/* Frees a chain slot's delay rings (both channels) and nulls them. Control-
 * thread only, like le_fx_free_octaver. The rings are le_rt_alloc storage
 * (rt_alloc.h), so every owner releases them here and never with free(). */
void le_fx_free_delay(le_fx_state* fx, int slot);

/* Frees EVERY heap buffer a standalone le_fx_state owns (both delay rings per
 * slot + the octaver heap) and nulls the pointers — the one teardown for
 * worker-private offline states (the wet-cache render, the perf_render
 * stems). Does NOT free the le_fx_state struct itself, and must not be used
 * on a LIVE chain owner's state (those interleave per-slot plugin teardown —
 * see le_engine_destroy). A future heap-owning effect adds its free HERE,
 * once, and every offline consumer inherits it. */
void le_fx_state_free_buffers(le_fx_state* fx);

/* Added latency (frames) of chain slot [slot]'s effect of [type] on `fx` at
 * [sr], looked up through the effect vtable — 0 for types that add none. The
 * octaver's is the same at every rate; an oversampling waveshaper's depends
 * on the rate (its factor and filters do). Generic so a future
 * latency-bearing effect (or hosted plugin) reports through the same seam. Folded
 * into the published snapshot so the UI can warn about monitoring lag. Control
 * thread (le_max_fx_latency). */
int le_fx_added_latency(const le_fx_state* fx, int slot, int32_t type, int sr);

/* Lazily allocates chain slot [slot]'s heap buffers for effect [type] (delay
 * rings, octaver phase-vocoder buffers, …) on the control thread, sized from
 * [cap] (the per-slot ring capacity). Each type owns its allocation behind the
 * effect vtable, so adding an effect needs no edit here. Returns LE_OK (incl.
 * types that allocate nothing), or LE_ERR_INVALID on OOM (all-or-nothing — it
 * frees whatever it allocated this call). Control thread (le_fx_prepare_entry). */
int32_t le_fx_prepare(le_fx_state* fx, int slot, int32_t type, int cap);

/* How many of an entry's LE_FX_PARAMS settings effect [type] reads: its
 * descriptor count (le_fx_param_count), and 0 for LE_FX_NONE, a hosted plugin
 * and an unknown code. Everything that copies or folds a chain's parameters
 * (the per-buffer snapshot, the wet-cache key, the offline renders, the perf
 * log) stops here, so the width costs one table load per entry. Any thread.
 *
 * LE_FX_WIDTHS is one past the last le_fx_type code; engine_fx.c checks it
 * against its effect table. */
#define LE_FX_WIDTHS 33
extern const uint8_t le_fx_widths[LE_FX_WIDTHS];
static inline int32_t le_fx_param_width(int32_t type) {
  return type > 0 && type < LE_FX_WIDTHS ? (int32_t)le_fx_widths[type] : 0;
}

/* Whether [type] is a built-in an entry may be set to: none or a built-in
 * effect, not a hosted plugin (which arrives through its own call) nor an
 * unknown code. */
static inline int le_fx_settable_type(int32_t type) {
  return type >= LE_FX_NONE && type < LE_FX_WIDTHS && type != LE_FX_PLUGIN;
}

/* Writes effect [type]'s default normalized params into out[LE_FX_PARAMS] (all
 * zero for LE_FX_NONE / unknown). Each type owns its defaults behind the vtable.
 * Seeded on a type change so a chain reorder does not wipe the user's tweaks. */
void le_fx_defaults(int32_t type, float out[LE_FX_PARAMS]);

/* --- Resumable YIN pass ------------------------------------------------------
 *
 * le_psola_detect_band split at its two pausable points, so a caller that
 * cannot afford the whole (lags x integration) difference function in one
 * callback can spread it. See le_yin_pass in engine_private.h for why, and
 * tuner_slice in engine_process.c and le_psola_pass_tick in engine_fx.c for
 * the two sliced callers. All three run on the audio thread and allocate
 * nothing.
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

/* le_yin_step, its lags worked out LE_YIN_GROUP at a time ahead of their
 * charge (le_lag_sums, engine_fx.c) into the caller's [sums]: the same
 * budget and the same results, for a fraction of a lag alone's cost each
 * (#1755). [sums] must be the same LE_YIN_GROUP doubles, untouched between
 * calls, for the whole pass (a group is worked out only at its first lag);
 * NULL takes the lags one at a time, which is le_yin_step. The PSOLA
 * octaver's and the Dual Octaver's passes run it with sums in their heap
 * state; the tuner keeps le_yin_step, so the callback's le_engine_process,
 * which inlines its slice and calls these in this unit, is the code it
 * was. */
int le_yin_step_lanes(le_yin_pass* p, long budget, double* sums);

/* Peak-picks a COMPLETED pass: writes the parabolic-interpolated period in
 * samples to *out_period and the voicing confidence in [0,1] to *out_voiced,
 * and returns 1 when the frame reads as confidently voiced. */
int le_yin_finish(const le_yin_pass* p, float* out_period, float* out_voiced);

/* --- Device-rate refinement of a coarse period ------------------------------
 *
 * A coarse period from a decimated pass is accurate to a fraction of a
 * DECIMATED sample. The refinement walks the plain difference function at the
 * device rate over lags [coarse - span, coarse + span + 1] and interpolates
 * the minimum. Plain difference rather than YIN's normalized form: the octave
 * decision is the coarse pass's, and this pass only locates a minimum it is
 * already next to. Shared by the tuner and the PSOLA octaver; all three run
 * on the audio thread and allocate nothing.
 *
 * Opens a refinement of [coarse] (device samples) over a window of [n]
 * samples. Returns 0, nothing to refine, when the lags would fall under 2 or
 * past n / 2 (fewer than two periods in the window): the caller keeps the
 * coarse period. [span] is at most LE_REFINE_SPAN_MAX. */
int le_refine_begin(le_lag_refine* r, float coarse, int span, int n);

/* The RBJ cookbook sections, designed in double and a0-normalized into
 * [c] (b0 b1 b2 a1 a2): the 12 dB/octave cuts, the shelves and the peak at
 * [hz] (held under 0.49 of [sr]), Q [q], and for a shelf or the peak a gain
 * of [db]. The EQ's bands and the other kinds' voicings design with it. */
enum { LE_EQ_LOWCUT, LE_EQ_LOW, LE_EQ_LOMID, LE_EQ_HIMID, LE_EQ_HIGH,
       LE_EQ_HIGHCUT };
void le_eq_design(int kind, double hz, double db, double q, int sr,
                  double c[5]);

/* Accumulates lags over window [x] until at least [budget] inner iterations
 * are charged (one whole lag always runs; the lags are worked out
 * LE_YIN_GROUP at a time, so up to LE_YIN_GROUP - 1 of them ahead of their
 * charge, #1755). Returns 1 once every lag is in. */
int le_refine_step(le_lag_refine* r, const float* x, long budget);

/* The completed refinement's minimum, interpolated, or [coarse] when the
 * minimum sits on an edge of the searched band. */
float le_refine_finish(const le_lag_refine* r, float coarse);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_FX_H */
