/*
 * segno_engine_api.h — the C ABI exposed to Dart via FFI.
 *
 * This is the single header consumed by ffigen. Everything here is POD or an
 * opaque handle; no C++; no callbacks into Dart. The audio callback that backs
 * this API performs no allocation, locking, or I/O (see engine.c).
 *
 * Scope: device lifecycle, per-input live monitoring, level metering, a loopback
 * round-trip latency harness, the lock-free command ring, and a multi-track,
 * multi-lane looper. Each track owns up to LE_MAX_LANES lanes; a lane records
 * one hardware input into its own clean mono buffer (never merged with sibling
 * lanes) with per-lane routing / volume / mute / effects, while the track owns
 * the shared transport (record / master-loop length / overdub / loop playback /
 * loop multiples / clear) and one undo span across all its lanes.
 */
#ifndef SEGNO_ENGINE_API_H
#define SEGNO_ENGINE_API_H

#include <stdint.h>

/* Maximum number of hardware input/output channels the engine opens and routes.
 * Per-track buffers are mono; tracks record from one input channel and play to
 * any subset of the output channels (see le_track_snapshot.output_mask). */
#define LE_MAX_CHANNELS 32

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define LE_EXPORT __declspec(dllexport)
#else
#define LE_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Result codes returned by lifecycle calls. */
typedef enum le_result {
  LE_OK = 0,
  LE_ERR_INVALID = -1,       /* null handle or bad argument */
  LE_ERR_ALREADY_RUNNING = -2,
  LE_ERR_NOT_RUNNING = -3,
  LE_ERR_DEVICE = -4,        /* miniaudio failed to init/start the device */
  LE_ERR_UNSUPPORTED = -5,   /* a plugin's bus topology is not a stereo (or
                              * mono-adaptable) effect — instrument / multi-bus /
                              * sidechain / wrong channel count (D-BUS); an
                              * audio file outside the decoder's whitelist
                              * (#1200) */
  LE_ERR_CAPACITY = -6,      /* a requested allocation would exceed engine
                              * capacity (A6, D17): N bars of the current
                              * signature at the slowest possible tempo (30
                              * BPM) would not fit in max_loop_frames */
  LE_ERR_MODE_MISMATCH = -7, /* history would not fit the current mode/clock */
  LE_ERR_NOT_READY = -8,     /* a pending command/report prevents a safe decision */
  LE_ERR_REVERSED = -9,      /* a punch-in on a reversed track (#1162): overdub
                              * is unavailable while Reverse is on */
  /* -10 .. -17 are assigned to other work (the numbering ledger). */
  LE_ERR_NOT_FOUND = -18,    /* the file (or a directory on its path) does not
                              * exist (#1198) */
  LE_ERR_TRUNCATED = -19,    /* the file exists but is shorter than the range
                              * it must hold (#1198) */

  /* -10 and -11 belong to pitch/time (#1179). */
  LE_ERR_TOO_LONG = -12, /* a backing file over LE_BACKING_MAX_SECONDS (#1200) */
} le_result;

/* Latency-harness phase, mirrored in le_snapshot.latency_state. */
typedef enum le_latency_state {
  LE_LATENCY_IDLE = 0,
  LE_LATENCY_MEASURING = 1, /* impulse emitted, waiting for it to return */
  LE_LATENCY_DONE = 2,      /* measured_latency_ms is valid */
  LE_LATENCY_TIMEOUT = 3,   /* no loopback detected within the window */
} le_latency_state;

/* Per-track state machine, mirrored in le_snapshot.track_state. */
typedef enum le_track_state {
  LE_TRACK_EMPTY = 0,
  LE_TRACK_RECORDING = 1,    /* capturing the first pass (defines the loop) */
  LE_TRACK_OVERDUBBING = 2,  /* summing input into the existing loop */
  LE_TRACK_PLAYING = 3,
  LE_TRACK_STOPPED = 4,      /* buffer retained, playback halted */
} le_track_state;

/* Where the current tempo came from, mirrored in le_snapshot.tempo_source
 * (D7 precedence). MANUAL and TAPPED are last-writer-wins; DERIVED is set only
 * when a defining loop finalizes with sync on and the source was NONE (a set
 * tempo is never re-derived); EXTERNAL is reserved for the Phase E MIDI-clock
 * follower and unused here. A DERIVED tempo survives clearing the loop that
 * produced it (the "dead tempo" lesson): only an explicit reset returns the
 * source to NONE. */
typedef enum le_tempo_source {
  LE_TEMPO_SOURCE_NONE = 0,     /* no tempo set; tempo_bpm reads 0 */
  LE_TEMPO_SOURCE_MANUAL = 1,   /* LE_CMD_SET_TEMPO */
  LE_TEMPO_SOURCE_TAPPED = 2,   /* LE_CMD_TAP_TEMPO */
  LE_TEMPO_SOURCE_DERIVED = 3,  /* derived from a defining loop (D7) */
  LE_TEMPO_SOURCE_EXTERNAL = 4, /* reserved: MIDI clock receive (Phase E) */
} le_tempo_source;

/* Click (metronome) audibility mode, mirrored in le_snapshot.click_mode — a
 * 4-value mode per the Sheeran manual §5.9.1, replacing the old boolean
 * metronome (D5). It gates WHEN the click voice sounds; WHERE it sounds is the
 * click output mask (le_engine_set_click_output — default no outputs).
 * Count-in clicks are audible in every mode except OFF while counting. */
typedef enum le_click_mode {
  LE_CLICK_OFF = 0,       /* never audible (count-ins still run, silently) */
  LE_CLICK_REC = 1,       /* while any track records or overdubs */
  LE_CLICK_REC_FIRST = 2, /* only during the DEFINING first-layer recording
                           * (incl. its count-in) */
  LE_CLICK_PLAY_REC = 3,  /* whenever the transport plays or records */
} le_click_mode;

/* The five architectural looper modes (B2a, D4/D10), mirrored in
 * le_snapshot.looper_mode. MULTI is today's behavior — independent per-track
 * loops, the whole engine as it exists before this series — and stays the
 * default. Sync/Band (primary-track sync + multiples/divisions, B3/B3b),
 * Free (independent per-track clocks, B2b), and Song (independent per-track
 * sections, B4) all have their full behavior as of this part; B2a itself was
 * only the field plus a content gate; the accepted content rules (slice 2)
 * engine_process.c) that guards switching it, with every value's audio path
 * staying MULTI behavior until its own part landed. This is a DIFFERENT axis
 * from InteractionMode (Dart-only: record/mute, what a track press does) —
 * the two never coexist under the same name (D10) and must not be
 * confused. */
typedef enum le_looper_mode {
  LE_LOOPER_MODE_MULTI = 0, /* default: independent per-track loops (today's
                             * behavior, unchanged by this part) */
  LE_LOOPER_MODE_SYNC = 1,  /* primary-track sync + multiples/divisions (B3) */
  /* Song (B4): a "section" IS a track (song-mode-spec.md §2 Q1) — up to
   * LE_MAX_TRACKS independent sections, each started/stopped directly via
   * its OWN track press (record/play/stop), exactly like every other mode's
   * per-track controls. No separate section object, no advance gesture (the
   * plan's original `advanceSection` was explicitly dropped once the manual
   * research showed no such gesture exists on the Sheeran — see the spec's
   * six B1 answers). Structurally IDENTICAL to Free's transport (independent
   * lengths, no primary, no shared grid obligation): B4 reuses B2b's
   * per-track clock machinery outright by broadening every FREE-only gate to
   * also cover SONG (see free_clock's doc, engine_private.h) rather than
   * inventing a parallel mechanism. */
  LE_LOOPER_MODE_SONG = 2,
  LE_LOOPER_MODE_BAND = 3,  /* primary + independently-quantized sections
                             * (B3) */
  LE_LOOPER_MODE_FREE = 4,  /* independent per-track clocks (B2b) */
} le_looper_mode;

/* Why a looper-mode change is refused, or what it will do first — the answer
 * of le_engine_looper_mode_gate. Codes are >= 0 so they never collide with
 * the LE_ERR_* results that function can also return. */
typedef enum le_mode_gate {
  LE_MODE_GATE_OPEN = 0,      /* the change applies as posted */
  LE_MODE_GATE_CAPTURING = 1, /* a take or an overdub pass is being captured
                               * (or a count-in runs): finish it first */
  LE_MODE_GATE_QUEUED = 2,    /* an armed action has neither fired nor been
                               * cancelled: let it land or cancel it first */
  LE_MODE_GATE_SPANS = 3,     /* the recorded spans do not fit the target
                               * mode (see le_engine_looper_mode_gate) */
  LE_MODE_GATE_PLAYING = 4,   /* loops are playing: le_engine_set_looper_mode
                               * stops every playing track before switching */
} le_mode_gate;

/* MIDI clock tri-state (Phase C/E, D15), mirrored in le_snapshot.clock_mode.
 * `off` and `send` are fully implemented by this part (C1): a native 24-PPQN
 * emitter (src/midi/le_midi_clock.h) drives 0xF8/Start/Stop through the
 * grid/transport each block whenever `send` is active AND the looper mode is
 * Multi/Sync/Band (manual-verified: Song and Free stay silent regardless of
 * this field — see le_engine_set_clock_mode). `receive` is REJECTED by the
 * setter for now — the enum value exists so Phase E (clock follower) can
 * reuse this same tri-state field without a breaking rename, per the index
 * plan's "Phase 5 reuses the tri-state clock_mode introduced here". Send and
 * receive are mutually exclusive by construction (only one non-off value is
 * ever accepted at a time). */
typedef enum le_clock_mode {
  LE_CLOCK_OFF = 0,     /* default: no MIDI clock I/O */
  LE_CLOCK_SEND = 1,    /* segno is MIDI clock master (C1) */
  LE_CLOCK_RECEIVE = 2, /* segno follows an external clock (Phase E; the
                         * setter rejects this value until then) */
} le_clock_mode;

/* Atomic recording-start edits retain their distinct transient semantics. */
typedef enum le_record_start_edit_kind {
  LE_RECORD_START_COUNT_IN = 0,
  LE_RECORD_START_SOUND = 1,
  LE_RECORD_START_RESTORE = 2,
} le_record_start_edit_kind;

/* Supported count-in lengths are exactly 0, 1, 2 and 4 bars. */
#define LE_COUNT_IN_MAX_BARS 4

/* Maximum track length preset in bars (A6, D17;
 * le_engine_set_track_length_preset). 0 is AUTO, not a bar count. */
#define LE_LENGTH_PRESET_MAX_BARS 64

/* Classification of a cable-free loopback path used to auto-measure latency.
 * All of these capture the *digital* round-trip (output → OS mixer → capture);
 * they exclude DAC/ADC converter latency, so they under-report the true analog
 * round-trip. A physical loopback cable remains the only true analog measure. */
typedef enum le_loopback_kind {
  LE_LOOPBACK_NONE = 0,
  LE_LOOPBACK_BACKEND = 1,   /* device backend's built-in output loopback */
  LE_LOOPBACK_MONITOR = 2,  /* PulseAudio "Monitor of ..." source (Linux) */
  LE_LOOPBACK_VIRTUAL = 3,  /* named virtual driver (BlackHole, VB-Cable, ...) */
} le_loopback_kind;

/* Result of loopback detection. `device_name` is the capture device to open for
 * an auto-measurement (empty for the backend's built-in loopback, which the
 * duplex engine does not auto-route). */
typedef struct le_loopback_info {
  int32_t available; /* 0/1 */
  int32_t kind;      /* le_loopback_kind */
  char device_name[256];
} le_loopback_info;

/* Command codes posted into the engine's SPSC ring. */
typedef enum le_command_code {
  LE_CMD_NONE = 0,
  LE_CMD_MEASURE_LATENCY = 1,
  LE_CMD_RECORD = 2,    /* record / finalize-loop / toggle overdub */
  LE_CMD_STOP = 3,      /* halt playback (retain buffer) */
  LE_CMD_PLAY = 4,      /* resume playback */
  LE_CMD_CLEAR = 5,     /* erase the track, back to empty */
  LE_CMD_UNDO = 6,      /* remove the last overdub layer */
  LE_CMD_SET_VOLUME = 7,/* arg_f = 0..LE_MAX_GAIN */
  LE_CMD_SET_MUTE = 8,  /* arg_f = 0 (unmute) or 1 (mute) */
  /* ---- tempo grid (D6/D7). SET_TEMPO / SET_TIME_SIGNATURE / TAP_TEMPO are
   * REJECTED (no-op) while the tempo is locked: any track has content AND a
   * grid exists (loop_bars > 0 or tempo_source != none). Only clearing every
   * track releases the lock. */
  LE_CMD_SET_TEMPO = 9,  /* arg_f = bpm, clamped to 30..300; sets
                          * tempo_source = manual (last writer wins) */
  LE_CMD_SET_TIME_SIGNATURE = 10, /* arg_i = numerator, arg_f = denominator
                                   * (4 or 8); validated to the 17 supported
                                   * signatures (le_grid_signature_valid,
                                   * tempo_grid.h) — others are dropped */
  LE_CMD_TAP_TEMPO = 11, /* two taps set the tempo from their interval; sets
                          * tempo_source = tapped (last writer wins) */
  LE_CMD_SET_SYNC_TEMPO = 12, /* arg_f = 0/1: whether finalizing a defining
                               * loop establishes the loop<->grid relationship
                               * (bar count / tempo derivation — see
                               * le_engine_set_sync_tempo) */
  LE_CMD_SET_RECORD_OFFSET = 13, /* arg_i = round-trip latency in frames */
  LE_CMD_SET_INPUT_MASK = 14,    /* route a track's record sources (arg_f =
                                  * track, arg_i = input bitmask) */
  LE_CMD_SET_OUTPUT_MASK = 15,   /* route a track's playback destinations
                                  * (arg_f = track, arg_i = output bitmask) */
  LE_CMD_ARM = 16,    /* arg_i = track: arm a quantized record (fire at loop
                       * top). arg_f selects the trigger: 0 = grid/loop-top
                       * (quantize), 1 = input level (auto-record), 2 = Band
                       * section transport (B3b) -- a play/stop TOGGLE on a
                       * content-bearing non-primary track, deferred to the
                       * next primary-track loop top rather than a record
                       * action; see le_engine_toggle_section. */
  LE_CMD_DISARM = 17, /* arg_i = track: cancel a pending quantized record
                       * (any trigger). */
  /* ---- click + count-in (A2, D5/D9). The click is its own routable source:
   * since slice 3b it sums into the channels of its output mask BEFORE the
   * output buses, so a destination's chain, level and mute, the master gain,
   * the limiter and metering all apply, and a performance capture contains it
   * when it is routed to the captured bus. None of these commands is
   * perf-logged, so stems and the offline master never contain it. */
  LE_CMD_SET_CLICK_MODE = 19, /* typed mode + revision; raw posts rejected. */
  LE_CMD_SET_LANE_FX = 20, /* set a lane chain entry's type (and reset its DSP
                            * state). arg_i = (channel << 16) | (lane << 8) |
                            * index, arg_f = le_fx_type. */
  LE_CMD_SET_LANE_FX_COUNT = 21, /* set a lane's active chain length.
                                  * arg_i = (channel << 16) | (lane << 8) |
                                  * count. */
  LE_CMD_SET_CLICK_OUTPUT = 22,  /* click output routing. trackmask arm:
                                  * channel unused, mask = output bitmask
                                  * (default 0 = no outputs). */
  LE_CMD_COMMIT_SESSION = 23,    /* session commit: base_frames and loop_bars;
                                  * publish grid with imported tracks stopped */
  LE_CMD_SET_CLICK_VOLUME = 24,  /* arg_f = 0..LE_MAX_GAIN (the click's ONLY
                                  * gain stage — master gain never applies). */
  LE_CMD_SET_RECORD_START = 25, /* typed pair + edit kind + callback receipt */
  /* ---- multi-lane recording (a track owns an array of lanes) ----
   * Each lane records one hardware input into its own clean mono buffer; all
   * lanes of a track share one transport and one undo span. Count activation
   * and these RT-concurrent lane edits go through the ring; control-side
   * preparation allocates before activation. Argument packing differs per
   * command so a 32-bit mask / a negative channel / a float volume each
   * round-trips exactly (see the lane setters). */
  LE_CMD_SET_LANE_INPUT = 26,  /* lane records this input channel (-1 = none).
                                * arg_f = channel*LE_MAX_LANES + lane,
                                * arg_i = input channel (or -1). */
  LE_CMD_SET_LANE_OUTPUT = 27, /* lane playback destinations.
                                * arg_f = channel*LE_MAX_LANES + lane,
                                * arg_i = output bitmask. */
  LE_CMD_SET_LANE_VOLUME = 28, /* lane playback gain.
                                * arg_i = channel*LE_MAX_LANES + lane,
                                * arg_f = 0..LE_MAX_GAIN. */
  LE_CMD_SET_LANE_MUTE = 29,   /* lane mute.
                                * arg_i = channel*LE_MAX_LANES + lane,
                                * arg_f = 0/1. */
  /* ---- per-input live monitor (one slot per hardware input) ----
   * Each hardware input has a SINGLE live-monitor chain: input-level enable gates
   * the whole input, then the input's live signal runs through its own effect
   * chain / routing / volume / mute. An empty chain is the clean (dry) path. Never
   * recorded, independent of all track state. The chain you monitor live is the
   * chain that is snapshot-copied onto a track lane when you record into it (a
   * clean monitor chain leaves the lane's own staged chain untouched). The
   * monitor commands are keyed by input only (no per-lane index): the FX commands
   * carry (input, index, type) in the typed `fx` arm (lane unused), the count in
   * `fxcount` (lane unused); output rides the `trackmask` arm (channel = input);
   * volume/mute use the generic { arg_i = input, arg_f = value } arm. */
  LE_CMD_SET_MONITOR_INPUT = 30, /* enable/disable a hardware input's monitor.
                                  * arg_i = input, arg_f = enabled (0/1). */
  LE_CMD_SET_MONITOR_INPUT_FX = 31, /* set the input's chain entry type (and reset
                                     * its DSP state). fx arm: channel = input,
                                     * index, type (lane unused). */
  LE_CMD_SET_MONITOR_INPUT_FX_COUNT = 32, /* set the input's active chain length.
                                           * fxcount arm: channel = input, count
                                           * (lane unused). */
  LE_CMD_SET_MONITOR_INPUT_OUTPUT = 33, /* input monitor playback destinations.
                                         * trackmask arm: channel = input, mask. */
  LE_CMD_SET_MONITOR_INPUT_VOLUME = 34, /* input monitor gain.
                                         * arg_i = input, arg_f = 0..LE_MAX_GAIN. */
  LE_CMD_SET_MONITOR_INPUT_MUTE = 35,   /* input monitor mute.
                                         * arg_i = input, arg_f = 0/1. */
  LE_CMD_SET_MASTER_GAIN = 36, /* global post-mix output gain. arg_f = 0..1. */
  LE_CMD_SET_OUTPUT_ENABLED = 37, /* structural output gate (preserves routes).
                                   * arg_i = output index, arg_f = enabled (0/1).
                                   * A disabled output is skipped in the mix
                                   * fan-out regardless of any lane/monitor mask
                                   * pointing at it; masks are untouched. */
  LE_CMD_DUB_SHADOW = 38, /* supply a shadow pool slot for per-pass overdub
                           * layer capture. lanei arm: channel, value = slot
                           * (lane unused). Lane buffers are allocated by the
                           * control thread before the push. */
  LE_CMD_UNDO_TO_EMPTY = 39,   /* undo past the base layer: track to EMPTY,
                                * len 0, master grid kept. arg_i = track. */
  LE_CMD_REDO_FROM_EMPTY = 40, /* reinstate an undone-to-empty track. lanei
                                * arm: channel, value = restored length. The
                                * control thread already swapped a_live. */
  LE_CMD_RESTORE_CLEAR = 43,   /* undo of an undoable clear: reinstate a cleared
                                * track. `restore` arm. Distinct from REDO_FROM_
                                * EMPTY because it restores the pre-clear STATE
                                * (which may be STOPPED) and re-establishes the
                                * master grid a whole-rig clear reset — REDO_
                                * FROM_EMPTY only ever reads the clock. The
                                * control thread already swapped a_live. */

  /* ---- performance-recording capture (arm/disarm the RT taps) ----
   * Zero-payload commands: the control thread allocates the capture rings and
   * writes the frozen config (master.perf_master_out_ch / .perf_input_mask,
   * struct le_engine.perf, engine_private.h) directly into engine state BEFORE
   * pushing the command, then the ring's release/acquire ordering makes that
   * state visible to the audio thread once it pops — the same
   * control-allocates/publish pattern as le_post_dub_shadows and the FX delay
   * lines, so no payload is needed. */
  LE_CMD_PERF_ARM = 41,    /* begin publishing to the perf capture rings */
  LE_CMD_PERF_DISARM = 42, /* stop; control frees the rings after a quiescent
                            * handshake once the audio thread acks this */

  /* ---- track length presets (A6, D17) ----
   * A per-track DEFINING-recording length preset, orthogonal to the existing
   * fixed-multiple machinery (le_effective_multiple / target_multiple,
   * engine_private.h): the multiple mechanism fixes a NON-defining track's
   * length in whole BASE loops once a master already exists; this preset
   * governs the DEFINING (first/master) recording itself — before any base
   * loop length exists — and drives whether tempo, bar count, or both are
   * derived from it (see le_arm_length_preset_target / finalize_master,
   * engine_process.c). Values 0 (AUTO) or 1..LE_LENGTH_PRESET_MAX_BARS
   * (fixed N bars) round-trip identically; anything else is clamped by the
   * audio thread on apply, matching every other per-track setter. Inert on
   * an already-recorded track until it is re-recorded. */
  LE_CMD_SET_LENGTH_PRESET = 44, /* arg_i = channel, arg_f = bars (0 = AUTO,
                                  * 1..LE_LENGTH_PRESET_MAX_BARS = fixed). */

  /* ---- looper mode (B2a, D4) ----
   * The five-mode axis (le_looper_mode). LOCKED (silently rejected, no-op)
   * over capture, pending arms, playing takes or incompatible spans —
   * le_looper_mode_switch_blocked,
   * the audio-thread twin of le_engine_looper_mode_gate. See the looper-mode
   * section of the control API for the content rules. */
  LE_CMD_SET_LOOPER_MODE = 45, /* arg_i = le_looper_mode (0..4) */

  /* ---- primary track / Sync + Band (B3, D16/D18) ----
   * Designates track [arg_i] the "crowned" primary track for Sync/Band's
   * multiple-or-division sync (a_primary_track) — the explicit TIMING
   * HANDOFF. Accepted in ANY mode (the crown is a persistent per-session
   * designation per D18 — it simply has no effect outside Sync/Band);
   * rejected only for an out-of-range channel. There is no "un-crown"
   * command: the engine itself clears the designation when every track is
   * empty, and crowns the first completed take while nothing is crowned
   * (le_primary_reconcile, engine_process.c — the accepted-design rule
   * that supersedes D18's never-auto-assign reading). See
   * le_sync_quantize_active (engine_private.h) for how this gates Sync/Band's
   * finalize + section-transport behavior. */
  LE_CMD_CROWN_PRIMARY = 46, /* arg_i = channel */

  /* One Shot: a per-track setting in every mode. Finishes the current
   * playback pass; explicit launch after automatic end starts at frame zero
   * without moving the shared musical clock. See le_engine_set_one_shot. */
  LE_CMD_SET_ONE_SHOT = 47, /* arg_i = channel, arg_f = 0/1 */

  /* ---- MIDI clock (Phase C/E, D15) ----
   * The tri-state le_clock_mode. Not perf-logged, for the same reason as
   * LE_CMD_SET_LOOPER_MODE above (clock output is a routing/sync concern,
   * not a captured audible source — the emitter sums nothing into the mix,
   * it only ever pushes bytes out through le_midi_out_send). */
  LE_CMD_SET_CLOCK_MODE = 48, /* arg_i = le_clock_mode. RECEIVE (2) is
                               * rejected — see le_engine_set_clock_mode. */

  /* ---- Track-stage chains (FX v3 part 1b) ----
   * The bus twins of the lane / monitor FX commands: type/count ride the ring
   * so the audio thread resets the entry's DSP state in lockstep, while
   * params and the enable flags are direct atomic stores (no command). They
   * reuse the typed `fx` / `fxcount` arms with the lane field unused. NONE of
   * these are perf-logged: track chains are manifest-only (part 9's stems
   * decision — the arm manifest carries them from part 3; nothing replays
   * them). The output-bus chains (65, 66) follow the same rules. */
  LE_CMD_SET_TRACK_FX = 49, /* set a track's Track-stage chain entry type (and
                             * reset its DSP state). fx arm: channel, index,
                             * type (lane unused). */
  LE_CMD_SET_TRACK_FX_COUNT = 50, /* set a track's Track-stage active chain
                                   * length. fxcount arm: channel, count
                                   * (lane unused). */

  /* Arm the chromatic tuner on one hardware input, or -1 to disarm. arg_i =
   * channel. The gate is the contract, not an optimization: a disarmed tuner
   * runs no detection at all. Not perf-logged — the tuner changes no
   * output. (51 and 52 were the Master insert family, retired in slice 3b
   * when that insert became output bus 0's chain; the codes stay
   * unallocated so an old event log can never be misread.) */
  LE_CMD_SET_TUNER_INPUT = 53,

  /* ---- per-input conditioning stage (input conditioning, S1) ----
   * A fixed utility stage per hardware input — HPF + mains-hum notches +
   * downward expander — applied ONCE per block into a conditioned copy of the
   * input buffer, upstream of BOTH the lane fan-out and the monitor split
   * (WYSIWYG: what you monitor is what records). Deliberately NOT an
   * le_fx_type chain entry: it cannot be reordered or removed per-chain, it
   * does not enter chain fingerprints, and its params are real units (Hz, dB,
   * ms), not normalized 0..1. Metering, the clip detector, and the latency
   * harness keep reading the RAW device buffer; the sound-activated record
   * trigger deliberately reads the CONDITIONED magnitude so mains hum cannot
   * false-arm a threshold recording. Zero added buffering latency by design
   * (IIR biquads + a no-lookahead envelope follower — no FIR, no lookahead),
   * so record_offset semantics are untouched. Loopback-excluded inputs are
   * never conditioned. Both commands ride the ring (like the monitor-input
   * commands, `channel` = input index, bounds vs LE_MAX_MONITORED_INPUTS) so
   * the audio thread resets/recomputes its thread-local DSP state in lockstep
   * with the config change. Neither is perf-logged: conditioning is upstream
   * of capture, so recorded PCM already embodies it (nothing replays it). */
  LE_CMD_SET_INPUT_COND = 54,       /* enable/disable input conditioning.
                                     * arg_i = input, arg_f = enabled (0/1).
                                     * An enable EDGE resets the stage's DSP
                                     * state (no stale filter ring). */
  LE_CMD_SET_INPUT_COND_PARAM = 55, /* set one conditioning parameter.
                                     * lanef arm: channel = input,
                                     * lane = le_cond_param, value = real-unit
                                     * value (clamped by the audio thread on
                                     * apply). */

  /* Immediate finalize (#405): ends track arg_i's live RECORDING take NOW —
   * or does nothing. Unlike LE_CMD_RECORD, whose meaning depends on the state
   * it lands on (start / finalize / punch-in / punch-out), this command
   * re-checks its precondition on the audio thread and is a strict no-op
   * anywhere else, so a state change in the one-block window between
   * le_engine_finalize_take's control-side guards and the apply can never
   * turn it into a capture start or a punch-in/out. Pending Count-in members
   * use explicit cancellation instead. Not itself perf-logged (the resulting
   * LE_PLOG_RECORD_END is logged by the actual finalization). */
  LE_CMD_FINALIZE_TAKE = 56,
  /* Cancel a take in progress on arg_i (le_engine_undo while RECORDING): the
   * take is finalized at its captured length exactly as a press would end
   * it — grid, tempo derivation and loop span included — and the track then
   * reads EMPTY with that finalized content held for redo, which plays it
   * immediately (LE_CMD_REDO_FROM_EMPTY). LE_EVT_TAKE_CANCELLED carries the
   * finalized length back so the control thread can file the redo entry. */
  LE_CMD_CANCEL_TAKE = 57,
  /* Exact musical tempo restoration on a stopped rig. arg_i = tempo source,
   * arg_f = BPM (0 only with NONE). Rechecked by the callback. */
  LE_CMD_RESTORE_TEMPO = 58,
  /* One queued command updates a subset of tracks together. arg_i = track
   * bitmask, arg_f = 0/1; uses the same pass semantics as SET_ONE_SHOT. */
  LE_CMD_SET_ONE_SHOT_MASK = 59,
  /* Named bounded payload: all configured tracks' future length presets. */
  LE_CMD_SET_LENGTH_PRESETS = 61,
  /* Lane pan (accepted design, slice 3). lanef arm: channel, lane, value in
   * -1..1 (clamped). Placement of the lane's stereo pair across its first two
   * masked outputs, applied after the lane's chain: a unity-centre balance
   * law (see le_engine_set_lane_pan). Perf-logged like volume. */
  LE_CMD_SET_LANE_PAN = 62,
  /* Track solo. Generic arm: arg_i = channel, arg_f != 0 = soloed. While any
   * track is soloed, only soloed tracks route (mute is untouched and still
   * gates on its own). Perf-logged. */
  LE_CMD_SET_TRACK_SOLO = 63,
  /* Monitor pan. lanef arm: channel = input, value in -1..1. The monitor
   * mirror of LE_CMD_SET_LANE_PAN. Perf-logged. */
  LE_CMD_SET_MONITOR_INPUT_PAN = 64,
  LE_CMD_SET_MIX = 65, /* one bounded, atomic mix transaction */
  LE_CMD_RECORD_IMAGE = 66, /* RECORD/ARM plus its frozen input image */
  /* Output bus facts (slice 3b). lanef arm: channel = bus, value. Level
   * 0..1, mute/mono as 0/1 in value, balance -1..1. Perf-logged. */
  LE_CMD_SET_OUTPUT_LEVEL = 67,
  LE_CMD_SET_OUTPUT_MUTE = 68,
  LE_CMD_SET_OUTPUT_MONO = 69,
  LE_CMD_SET_OUTPUT_BALANCE = 70,
  /* Output bus chain entry type / active length: fx / fxcount arms with
   * channel = bus; bus 0's chain is what the app calls the Master insert. */
  LE_CMD_SET_OUTPUT_FX = 71,
  LE_CMD_SET_OUTPUT_FX_COUNT = 72,
  /* Cut all sound (accepted design): stops every audible recorded track and
   * the count-in, and clears every effect tail on every chain (lane, track,
   * monitor, output) while keeping their settings; the snapshot's
   * tail_reset_rev advances. Monitors keep their preferences: new live
   * input sounds again at once. Perf-logged. */
  LE_CMD_CUT_SOUND = 73,
  LE_CMD_SET_LANE_COUNT = 74, /* internal structural activation; callback-owned */
  /* All tracks recorded-mix chain entry type / active length (slice 3e): the
   * fx / fxcount arms with channel = 0 (there is one such chain). One shared
   * config; the audio thread runs it once per output bus over the recorded
   * contribution to that bus. */
  LE_CMD_SET_ALL_TRACKS_FX = 75,
  LE_CMD_SET_ALL_TRACKS_FX_COUNT = 76,

  /* Event codes (audio thread -> control thread, on the engine's evt_ring —
   * the reverse SPSC direction; numbered apart from the commands for clarity). */
  LE_EVT_LAYER_RETIRED = 100, /* a completed overdub-pass snapshot. evt arm:
                               * channel, slot, generation. */
  LE_EVT_TAKE_CANCELLED = 101, /* LE_CMD_CANCEL_TAKE landed: lanei arm —
                                * channel, value = the finalized length the
                                * emptied track holds for redo (0: nothing
                                * was captured, nothing to redo). */
  LE_CMD_SET_FX_RECIPE = 77,
  LE_CMD_SET_RECORD_TIMING = 78, /* one complete timing vector and receipt */
  LE_CMD_STOP_RECORD_CONTROL = 79, /* cohort cancel or non-acquiring capture finish */
  LE_CMD_CANCEL_COUNT_IN = 80, /* only the shared launch cohort/grace */
  LE_CMD_FADE = 81, /* checked internal Fade request; never raw-posted */
  LE_CMD_RESET_TRANSFORMS = 82, /* internal material-import transform reset
                                 * (Fade and direction); never raw-posted */
  LE_CMD_REVERSE = 83, /* checked internal Reverse request; never raw-posted */
  /* ---- backing player (#1200; 88-95 reserved for it, 93-95 unused). Typed
   * producers only (le_engine_backing_*): LOAD and STAGE_NEXT carry an owned
   * buffer pointer, so raw posts of any of these are refused. None is
   * perf-logged: the backing never reaches stems or the offline master. */
  LE_CMD_BACKING_LOAD = 88,       /* buffer + item token + play flag */
  LE_CMD_BACKING_STAGE_NEXT = 89, /* buffer (NULL clears) + item token */
  LE_CMD_BACKING_CLEAR = 90,      /* unload current and staged */
  LE_CMD_BACKING_TRANSPORT = 91,  /* arg_i = le_backing_transport_op */
  LE_CMD_BACKING_SEEK = 92,       /* arg_i = frame of the loaded buffer */
} le_command_code;

/* Per-lane / per-monitor-input effects: each lane (and each live monitor input)
 * carries an ordered chain of up to LE_FX_MAX entries, each with a type and
 * LE_FX_PARAMS normalized (0..1) parameters. The chain is non-destructive (the
 * recording is ALWAYS dry; effects color playback only) and every active entry
 * applies in chain order. The cap exists only so the audio thread reads a
 * fixed-size, allocation-free array — it is not a CPU limit: the audio path
 * iterates the ACTIVE count, and the per-slot DSP heap (delay rings, the
 * octaver's vocoder buffers) is allocated lazily on first use, so an unused
 * slot costs nothing but its place in the struct.
 *
 * Raised from 8 to 64 in slice 3f. The accepted FX design builds a chain out
 * of RACKS — named groups of pedals — and one factory rack is about six, so
 * eight slots held roughly one rack where the design shows ten. Sixty-four
 * holds ten full racks.
 *
 * The per-buffer snapshots live in engine-owned scratch rather than growing
 * the callback stack. Recipe commands carry retained prepared pointers, so
 * raising this ceiling does not enlarge each command-ring entry. */
#define LE_FX_MAX 64
#define LE_FX_PARAMS 4

/* Built-in effect types. Designed so a hosted VST3/CLAP plugin can later slot
 * in as just another type. Each type reads its entry's LE_FX_PARAMS normalized
 * values:
 *   DRIVE:   p0 = drive amount, p1 = output level
 *   FILTER:  p0 = cutoff, p1 = resonance        (resonant low-pass)
 *   DELAY:   p0 = time, p1 = feedback, p2 = wet mix
 *   TREMOLO: p0 = rate, p1 = depth
 *   OCTAVER: p0 = shift (0 = -2 oct, .5 = unison, 1 = +2 oct), p1 = tone,
 *            p2 = mix, p3 = mode (< .5 = phase vocoder, >= .5 = PSOLA; stored
 *            but inert until the formant-preserving rewrite reads it)
 * Every other type leaves its unused trailing params (including p3) at 0; no
 * non-octaver effect reads p3.
 *   ECHO:    p0 = time, p1 = feedback, p2 = mix  (tape-style, damped repeats)
 *   REVERB:  p0 = size, p1 = damping, p2 = mix   (Schroeder room tail; a mono
 *            input yields a decorrelated stereo tail spread across the first two
 *            output channels of the lane/monitor mask) */
typedef enum le_fx_type {
  LE_FX_NONE = 0,
  LE_FX_DRIVE = 1,
  LE_FX_FILTER = 2,
  LE_FX_DELAY = 3,
  LE_FX_TREMOLO = 4,
  LE_FX_OCTAVER = 5,
  LE_FX_ECHO = 6,
  LE_FX_REVERB = 7,
  /* A hosted VST3/CLAP plugin. Unlike the built-ins this row carries no fixed
   * params and no DSP state in le_fx_state — its `process` forwards to a plugin
   * host owned by an le_plugin_slot, loaded on the control thread (see
   * le_engine_set_lane_plugin). An LE_FX_PLUGIN entry whose slot is not yet
   * published (or is being torn down) renders dry passthrough. */
  LE_FX_PLUGIN = 8,
} le_fx_type;

/* Which device backend to open. The default (0) opens miniaudio's default
 * backend for the platform (Core Audio on macOS, the Linux preference list) —
 * the only backend this engine ships. */
typedef enum le_audio_backend {
  LE_BACKEND_MINIAUDIO = 0, /* default: miniaudio's default platform backend */
  /* Reserved. Was Windows ASIO; the backend went with the desktop targets, but
   * the value stays claimed so a persisted setting written by an older build
   * still parses instead of being reinterpreted as another backend. */
  LE_BACKEND_ASIO = 1,
} le_audio_backend;

/* A hardware audio device discovered by enumeration (le_enumerate_*).
 *
 * `id` is an opaque, backend-specific token suitable for pinning a device via
 * le_config.playback_device_id / capture_device_id. On every string-id backend
 * (CoreAudio, ALSA, PulseAudio, sndio) it is the device's native id string; it
 * round-trips byte-for-byte back into le_config. `name` is the human-readable
 * label; `is_default` marks the system default for that direction. */
typedef struct le_device_info {
  char id[256];
  char name[256];
  int32_t is_default;      /* 0/1 */
  /* The device's channel count in the direction it was enumerated in: a
   * capture device fills input_channels, a playback device output_channels,
   * and the other stays 0 — a playback device reports what it can play and
   * never the other way round. An ASIO driver is duplex and fills both.
   * 0 = UNKNOWN, not "no channels": a device that cannot answer keeps it, and
   * a count is omitted rather than printed as a zero. */
  int32_t input_channels;
  int32_t output_channels;
  /* ASIO-only: the driver's selectable buffer sizes and supported sample rates,
   * probed by le_enumerate_asio_drivers so the UI can offer the driver's real
   * options instead of a generic list. Count 0 for non-ASIO devices (the UI
   * then keeps its default lists). Sizes/rates are ascending; the buffer set
   * always includes the driver's preferred size. */
  int32_t asio_buffer_sizes[8];
  int32_t asio_buffer_count;
  int32_t asio_sample_rates[8];
  int32_t asio_sample_rate_count;
} le_device_info;

/* Requested device configuration. Any channel field set to 0 uses the device
 * default; counts are clamped to LE_MAX_CHANNELS. */
typedef struct le_config {
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t max_loop_frames; /* per-track buffer cap; 0 => default (8 min @ sr) */
  int32_t use_loopback_capture; /* 1 = capture from a detected loopback device */
  int32_t input_channels;  /* hardware capture channels (0 => device default) */
  int32_t output_channels; /* hardware playback channels (0 => device default) */
  /* Pin a specific device by id (an `id` from le_enumerate_*). An empty string
   * opens the system default (the unchanged behaviour). use_loopback_capture
   * overrides capture_device_id when a loopback device is detected. */
  char playback_device_id[256];
  char capture_device_id[256];
  /* le_audio_backend to open. Every value resolves to miniaudio via
   * le_select_backend; the field stays so persisted configs still round-trip. */
  int32_t backend;
  /* Reserved, alongside LE_BACKEND_ASIO. Always empty and ignored. */
  char asio_driver[256];
} le_config;

/* Maximum number of simultaneous looper tracks (two banks of four). */
#define LE_MAX_TRACKS 8

/* Default and fixed-track recording choices: 0 immediately, 1 loop start,
 * 2 bar, 3 half, 4 quarter, 5 eighth, 6 sixteenth. Track -1 inherits. */
typedef struct le_record_timing_settings {
  int32_t default_timing;
  int32_t remembered_division;
  int32_t track_timing[LE_MAX_TRACKS];
  uint32_t edit_mask; /* bit 0 default, bits 1..8 track intentions */
} le_record_timing_settings;



/* Lanes a single track may own: one lane per hardware input it records. A lane
 * is the fundamental recordable unit — one clean mono buffer fed by one input —
 * and a track owns up to this many, all sharing one transport and undo span.
 * Lane buffers are allocated lazily (only recorded/counted lanes), so the
 * worst-case LE_MAX_TRACKS * LE_MAX_LANES does not inflate idle memory. */
#define LE_MAX_LANES 8

/* Input channels the live-monitor path covers, [0, LE_MAX_MONITORED_INPUTS).
 * Bounds the per-input monitor array (le_engine_set_monitor_input and friends)
 * and the per-input capture rings beside it.
 *
 * Every hardware input the engine can open can be monitored (accepted
 * design, slice 3: an 18-input interface monitors channel 18 exactly as
 * well as channel 1), so this is LE_MAX_CHANNELS. It stays a distinct name
 * from LE_MAX_LANES, which bounds a different thing (lanes per track), and
 * the monitor arrays are sized by it, never by the lane ceiling. Each
 * le_monitor_input is about 3.3 KB, so 32 of them cost ~106 KB. */
#define LE_MAX_MONITORED_INPUTS LE_MAX_CHANNELS

/* Output destinations (accepted design, slice 3b): output bus k is the
 * hardware pair (2k, 2k + 1); the last bus of an odd-count device is its one
 * channel. Every source's output mask still says which channels it reaches;
 * a bus is what those channels share downstream: one effect chain over the
 * sum of everything routed there (live inputs, loops, click), then its
 * level, Stereo/Mono, balance and mute. See le_engine_set_output_level. */
#define LE_MAX_OUTPUT_BUSES (LE_MAX_CHANNELS / 2)

typedef struct le_output_fx_snapshot {
  int32_t count, chain_enabled;
  int32_t type[LE_FX_MAX], enabled[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
} le_output_fx_snapshot;

/* ---- Input clip ("HOT") detector (input clip, S2) ---- *
 * Always on, no parameters, RAW path: LE_CLIP_RUN or more CONSECUTIVE samples
 * at |s| >= LE_CLIP_LEVEL on a non-loopback input latch that input's bit in
 * le_snapshot.input_clip_mask, held for LE_CLIP_HOLD_MS past the last detected
 * run (a persisting rail keeps refreshing the hold). The run requirement is
 * the point: a one-or-two-sample full-scale transient is music, while a flat
 * run at the rail is the clamp signature of an overdriven ADC. Detection reads
 * the RAW device buffer — upstream of the conditioning stage — so a clipped
 * input flags HOT even when the expander/HPF has reshaped what records. */
#define LE_CLIP_LEVEL 0.999f
#define LE_CLIP_RUN 4
#define LE_CLIP_HOLD_MS 1500

/* Ceiling for a per-lane / per-monitor channel volume. 2.0 is +6.02 dB, so the
 * UI can boost a quiet take/input up to +6 dB rather than only attenuate from
 * unity (1.0 = 0 dB). The output limiter downstream still guards the bus. */
#define LE_MAX_GAIN 2.0f

/* Ceiling of le_engine_set_input_trim's linear capture gain: +12 dB. The
 * accepted range is -24..+12 dB in half-decibel steps; the floor is 0. */
#define LE_MAX_INPUT_TRIM 3.98107170553f

/* One user-visible mix edit. Masks address only the supplied entries; all
 * values are finite and bounded. Lane index = track * LE_MAX_LANES + lane.
 * The caller supplies a nonzero revision, published only after the entire
 * edit applies. The engine copies this POD into one command, never retains
 * the caller's pointer. No state changes on validation/queue refusal. */
typedef struct le_mix_settings {
  uint32_t revision;
  uint32_t track_gain_mask;
  float track_gain[LE_MAX_TRACKS]; /* after whole-track Pre, before Post */
  uint64_t lane_mask, image_mask;
  uint32_t monitor_mask, trim_mask, solo_mask, solo_values;
  float lane_gain[LE_MAX_TRACKS * LE_MAX_LANES];
  float lane_pan[LE_MAX_TRACKS * LE_MAX_LANES];
  /* Source image is separate from live lane gain and track pan offset. */
  float image_gain[LE_MAX_TRACKS * LE_MAX_LANES];
  float image_pan[LE_MAX_TRACKS * LE_MAX_LANES];
  float monitor_gain[LE_MAX_CHANNELS], monitor_pan[LE_MAX_CHANNELS];
  float input_trim[LE_MAX_CHANNELS];
  uint32_t output_mask, output_muted, output_mono;
  float output_level[LE_MAX_OUTPUT_BUSES], output_balance[LE_MAX_OUTPUT_BUSES];
  /* Future capture assignments and playback routes share this publication.
   * Source guards include pair edits even when no assignment changes. */
  uint64_t routing_input_mask, routing_output_mask;
  uint32_t lane_count_mask, source_track_mask;
  int32_t lane_input[LE_MAX_TRACKS * LE_MAX_LANES];
  uint32_t lane_output[LE_MAX_TRACKS * LE_MAX_LANES];
  int32_t lane_count[LE_MAX_TRACKS];
} le_mix_settings;

typedef struct le_engine le_engine;

/* One bounded command; enqueue is not application. The full snapshot carries
 * the coherent applied tuple and its even receipt revision/result. */
LE_EXPORT int32_t le_engine_set_record_timing_settings(
    le_engine* engine, const le_record_timing_settings* settings);

typedef struct le_plugin_slot le_plugin_slot;

/* Complete structural recipe, copied before admission. Hosted pointers must
 * belong to this chain or have been prepared by this engine. */
typedef struct le_fx_recipe {
  int32_t count, pre_count, enabled;
  int32_t type[LE_FX_MAX], slot_enabled[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t input_mode[LE_FX_MAX], output_mode[LE_FX_MAX];
  float placement[LE_FX_MAX], level[LE_FX_MAX];
  le_plugin_slot* plugin[LE_FX_MAX];
} le_fx_recipe;

typedef enum le_fx_owner {
  LE_FX_OWNER_LANE = 0,
  LE_FX_OWNER_TRACK = 1,
  LE_FX_OWNER_MONITOR = 2,
  LE_FX_OWNER_ALL_TRACKS = 3,
  LE_FX_OWNER_OUTPUT = 4,
} le_fx_owner;

/* Structural changes publish in one callback command. A pending structural
 * edit fences granular writes to that chain until publication. Refusal leaves
 * the active recipe and prepared-plugin ownership unchanged. */
LE_EXPORT int32_t le_engine_set_fx_recipe(le_engine* engine, int32_t owner,
    int32_t channel, int32_t lane, uint32_t revision, const le_fx_recipe* recipe);
LE_EXPORT uint32_t le_engine_fx_recipe_revision(le_engine* engine, int32_t owner,
    int32_t channel, int32_t lane);
LE_EXPORT int32_t le_engine_prepare_plugin(le_engine* engine,
    const char* plugin_id, le_plugin_slot** out_slot);
LE_EXPORT int32_t le_engine_discard_prepared_plugin(le_engine* engine,
    le_plugin_slot* slot);
LE_EXPORT int32_t le_engine_prepare_plugin_param(le_engine* engine,
    le_plugin_slot* slot, uint32_t param_id, double value);

/* Source context frozen at the accepted record/arm gesture. The image is
 * applied only when capture starts, including count-in/signal/grid starts.
 * Cancelling an arm drops it without changing existing lane playback.
 * gain is source balance (0..1); pan is source position (-1..1). Live lane
 * level and track pan offset remain independent throughout an arm.
 * image_revision survives short takes and finalization until reconfigure. */
typedef struct le_record_image {
  uint32_t revision, lane_mask;
  float gain[LE_MAX_LANES], pan[LE_MAX_LANES];
  /* Optional per-lane recipes frozen with this arm. The producer copies the
   * array during this call; the caller retains its own memory. */
  uint32_t fx_lane_mask;
  const le_fx_recipe* lane_fx;
} le_record_image;



/* Number of points in the loop visualization buffer (le_engine_read_visual):
 * one peak per loop position, spanning exactly one master loop. */
#define LE_VIZ_POINTS 512

/* Per-lane state published via le_engine_get_lane: one recordable input lane of
 * a track. A lane records exactly one hardware input (input_channel, -1 = none)
 * into its own clean mono buffer and plays back to the outputs in output_mask,
 * scaled by volume and gated by muted. length_frames is the lane's recorded
 * length (all lanes of a track share the same length via the one transport). */
typedef struct le_lane_snapshot {
  int32_t input_channel; /* hardware input this lane records (-1 = none) */
  uint32_t output_mask;  /* bitmask of output channels this lane plays to */
  float volume;          /* 0..LE_MAX_GAIN */
  int32_t muted;         /* 0/1 */
  int32_t length_frames; /* frames captured into this lane's buffer */
  float rms;             /* 0..1 */
  float peak;            /* 0..1 */
  /* Trailing (#595): 0/1 — this lane captured audio that is still live or
   * restorable (clear-restore shadow / redo stack). THE per-lane "holds
   * content" signal: length_frames is track-shared (the write head publishes
   * the same growing length onto every active lane), so it cannot answer
   * whether a specific lane's slot is safe to reclaim. Drops to 0 only once
   * nothing on the lane can come back. */
  int32_t recoverable;
  /* Trailing (accepted design, slice 3): the lane's pan, -1 (left) .. 1
   * (right), 0 centre — see le_engine_set_lane_pan. */
  float pan;
} le_lane_snapshot;

/* Per-track state published in le_snapshot.tracks.
 *
 * A track is a multi-lane container: it owns the transport (state, multiple,
 * undo/redo depth) and up to lane_count lanes. The volume/muted/length/
 * input_mask/output_mask/rms/peak fields mirror lane 0 for backward
 * compatibility (a track always has at least one lane); per-lane state is read
 * with le_engine_get_lane. */
/* One coherent Fade image. Lifetime/generation bind an install to the engine
 * configuration and recorded material that were observed by the caller. */
typedef struct le_fade_image {
  float amount, target, full_travel_seconds;
  uint64_t lifetime, generation;
} le_fade_image;

typedef struct le_track_snapshot {
  le_fade_image fade;
  uint64_t fade_revision;
  int32_t state;         /* le_track_state */
  float volume;          /* lane 0 volume, 0..LE_MAX_GAIN */
  int32_t muted;         /* lane 0 mute, 0/1 */
  int32_t length_frames; /* frames captured (== multiple * master length) */
  int32_t multiple;      /* track length in whole base loops (>= 1) */
  int32_t undo_depth;    /* available undo steps (overdub layers). A track
                          * cleared via le_engine_clear_undoable reads 0 here
                          * even though its erased take's layers are still held:
                          * they are not peelable until the restore point above
                          * them is undone. See clear_restore. */
  int32_t clear_restore; /* 1 when the next le_engine_undo restores a cleared
                          * take rather than peeling a layer — i.e. "undo would
                          * do something" on a track whose undo_depth is 0. */
  int32_t redo_depth;    /* available redo steps */
  float rms;             /* lane 0 RMS, 0..1 */
  float peak;            /* lane 0 peak, 0..1 */
  uint32_t input_mask;   /* lane 0 input as a bitmask (1 << input_channel, or 0
                          * when lane 0 records no input) */
  uint32_t output_mask;  /* lane 0 output mask */
  int32_t lane_count;    /* number of active lanes (1..LE_MAX_LANES) */
  int32_t layer_in_flight; /* 0/1: an overdub undo layer is still being
                            * captured/drained (punch tail window). Session
                            * capture waits this out before exporting. */
  int32_t pending;         /* 0/1: a quantized/signal arm is waiting to fire */
  /* Trailing (A6, D17): the DEFINING-recording length preset — 0 = AUTO,
   * 1..LE_LENGTH_PRESET_MAX_BARS = fixed N bars. Inert on a track that
   * already has content; applies to the next defining recording only. See
   * le_engine_set_track_length_preset. */
  int32_t length_preset_bars;
  /* Trailing (B3, D16): 0 = this track's length is an ordinary multiple of
   * the base loop (see `multiple` above — the common case in every mode,
   * including Sync/Band multiples). 2 or 4 = this track is a SYNC DIVISION:
   * it plays a repeating 1/2 or 1/4 slice of the primary track's length,
   * phase-locked to the primary's loop top (`multiple` reads 1, inertly, for
   * a division track). Only ever nonzero in Sync/Band mode on a non-primary
   * track. See le_sync_quantize_active (engine_private.h) for how it's set. */
  int32_t sync_divisor;
  /* Trailing (B4, One Shot): 0/1, default 0. Live in every mode; see
   * le_engine_set_one_shot for playback and relaunch semantics. */
  int32_t one_shot;
  /* Trailing (#819): the monotonic per-track id of the currently-SETTLED take
   * — the take the RECORD_END that last finalized this track logged, published
   * from le_track.a_settled_take_id. 0 means the track never finalized a take
   * in this session (still empty, or only ever held pre-arm content with no id
   * yet). The performance-capture pipeline writes it onto the disarm manifest's
   * lane-0 entry as `takeId`, and the offline renderer (perf_render.c) matches
   * it against the RECORD_END payloads to anchor the settled image by identity
   * rather than by "first RECORD_END on the channel". */
  int32_t settled_take_id;
  /* Trailing (#697 S9, offline loop-close restoration): 0 idle, 1 queued (the
   * enqueue copy is in flight or the job is waiting for the worker), 2 running
   * (the worker's de-clip/denoise DSP is in flight). A completed pass publishes
   * its result as an ordinary undo layer, so undo_depth/clear_restore carry the
   * revert affordance — this field is only the in-progress indicator. See
   * le_engine_restore_track. */
  int32_t restore_state;
  /* Trailing (accepted design, slice 1): this track's OWN playhead in frames
   * within its own length — a multiple's segment offset, a Sync division's
   * folded phase and a Free/Song track's private clock are all already
   * applied, so `position_frames / length_frames` is the track's progress
   * without the reader re-deriving the mode's position rule. It is the read
   * index of the block's LAST frame (so one behind master_position_frames,
   * which is advanced after each frame); while RECORDING it is the write
   * head instead (frames captured so far). 0 for an empty or never-played
   * track. Published once per block beside the level. */
  int32_t position_frames;
  /* Trailing (accepted design, slice 1): what the arm reported by `pending`
   * waits for — 0 = the quantize grid (next loop top / subdivision), 1 = a
   * signal at the recording input (Sound start), 2 = a Band section toggle
   * at the primary's loop top; -1 while nothing is pending. The stage names
   * the boundary from this rather than guessing from the settings. */
  int32_t pending_trigger;
  /* ---- per-track record timing and decay overrides (accepted design,
   * slice 2b; trailing). What the engine holds, so a surface and a session
   * capture read the setting back rather than what was last sent. */
  int32_t quantize_override; /* -1 inherit, 0 forced off, 1 forced on
                              * (record timing vector) */
  int32_t quantize_div_override; /* -1 inherit, else le_grid_div
                                  * (record timing vector) */
  float overdub_feedback_override; /* negative = inherit, else 0..1
                                    * (le_engine_set_track_overdub_feedback) */
  /* Trailing (accepted design, slice 3): the Mixer's per-track facts. */
  int32_t solo; /* 0/1 — le_engine_set_track_solo; independent of muted */
  /* Absolute stereo peaks AFTER volume, pan and track FX, BEFORE output
   * routing/downmix and the master bus. Values may exceed unity (clipping
   * headroom); never clamped to 1. A mono destination folds the pair later
   * and need not equal either meter. 0 when no enabled route is audible. */
  float peak_l;
  float peak_r;
  uint32_t image_revision; /* last image applied at capture start */
  int32_t pending_launch; /* 0 none, 1 Record, 2 Play, 3 Overdub: shared Count-in */
  /* A just-committed member can still be canceled in the next command drain.
   * This is cancellation authority, not pending membership or fresh admission. */
  int32_t count_in_cancel_grace;
  /* Trailing (#1162, Reverse): 0 forward, 1 reversed — the callback-owned
   * read direction of the track's recorded material, published with every
   * accepted le_engine_toggle_reverse / le_engine_install_reverse and reset to
   * forward with the material (Clear, Undo to empty, a new capture, import).
   * A performance transform, not an audio edit: never in the undo history. */
  int32_t reversed;
  /* Trailing (#1164): how many overdub layers le_engine_peel can still remove
   * — the LAYER entries above the newest history entry that is neither an
   * overdub nor a peel. Published under undo_depth's gates, so an EMPTY track
   * reads 0 here too. The host derives its layer count from this: PEEL
   * entries keep undo_depth constant while a layer disappears. */
  int32_t peel_depth;
} le_track_snapshot;

/* ===================== Audio-callback telemetry (#722) =====================
 *
 * The audio callback measuring its OWN lateness. Until this existed nothing on
 * the miniaudio backends (Linux/macOS) counted a missed deadline: xrun_count was
 * fed only by the Windows ASIO overload notification, so the appliance could not
 * tell a callback that ran long from one that ran fine. Observation only — no
 * audio behaviour depends on any of it.
 *
 * WHAT IS MEASURED, and where: the device backend's data callback wraps
 * le_engine_process between two monotonic clock reads (engine_miniaudio.c), so a
 * duration here is what the DEVICE's callback thread actually spent, and an
 * entry-to-entry gap is what the DEVICE actually experienced.
 *
 * THE UNIT IS A PERIOD SERVICE, NOT A CALLBACK. miniaudio's duplex loop does not
 * hand the engine one period per callback: it delivers min(capture, playback)
 * chunks, split further by the converter's stack buffer and by short readi()
 * returns, so one hardware period is typically serviced by k back-to-back
 * callbacks. Neither obvious per-callback deadline survives that:
 *
 *   - judging every callback against a FULL period under-reports badly (a
 *     callback doing a k-th of the work gets k times the deadline it needs, so a
 *     struggling device reads "all clear");
 *   - judging it against its own frames/rate over-reports just as badly, because
 *     le_engine_process has a fixed per-block cost — the command drain, the
 *     per-lane and per-monitor snapshot loops, the metering publish — that does
 *     NOT shrink with the block. A 16-frame tail block would be given 166 us for
 *     overhead a 64-frame block absorbs inside 666 us, and would land in the
 *     over-budget bucket every single time on perfectly healthy hardware.
 *
 * So consecutive callbacks are summed until they cover at least one nominal
 * period, and THAT total is judged against the frames it actually covered. The
 * fixed overhead is amortised over a real period by construction, which is also
 * the true deadline: the work for one period must fit inside one period. calls
 * stays as raw context (how many callbacks made up those services).
 *
 * budget_us is the nominal period deadline, buffer_frames / sample_rate — a
 * constant for the device session, and what the gap detector is measured
 * against.
 *
 * TWO WINDOWS, because the bug being hunted (#722: clicks ONLY while a
 * performance capture is armed) is a comparison, not an absolute: `session`
 * accumulates for the whole device session (reset per configure/start, exactly
 * like xrun_count), `armed` is reset by every le_perf_arm and so covers only
 * the armed window. "Unarmed" is read as the difference of the counts; the two
 * maxima are reported separately because a maximum cannot be subtracted.
 *
 * ON HEALTHY HARDWARE EVERY JUDGED FIELD READS ZERO: late_periods, gap_events,
 * max_gap_us and xruns are all 0, and the histogram sits in the low buckets.
 * That is a deliberate design constraint — an instrument that cries wolf on a
 * working rig is worse than no instrument, because the bench then chases it. */

/* Duration-histogram resolution. Bucket i counts period services whose total
 * duration fell in [i/8, (i+1)/8) of the deadline for the frames they covered;
 * the last bucket is the open-ended ">= 7/8" danger zone and therefore also
 * holds every over-budget service (which `late_periods` counts exactly). A
 * histogram distinguishes "one huge stall" from "many marginal ones" — the two
 * have completely different causes. */
#define LE_CB_BUCKETS 8

/* Dropout classes counted per window. The three ALSA ones come from the direct
 * ALSA duplex path (miniaudio's -EPIPE recoveries and the playback-slip resync);
 * OVERLOAD is the Windows ASIO driver's kAsioOverload notification. */
typedef enum le_xrun_kind {
  LE_XRUN_PLAYBACK_UNDERRUN = 0, /* writei() -EPIPE: the card ran out of audio */
  LE_XRUN_CAPTURE_OVERRUN = 1,   /* readi()  -EPIPE: we did not read in time */
  LE_XRUN_PLAYBACK_RESYNC = 2,   /* the slipped-playback drop+prepare resync */
  LE_XRUN_BACKEND_OVERLOAD = 3,  /* ASIO kAsioOverload */
} le_xrun_kind;

/* How many le_xrun_kind values there are — the per-window tally array width.
 * A macro rather than a trailing enum member so the enum stays free of a
 * sentinel that is not a kind (it crosses the FFI boundary as a Dart enum). */
#define LE_XRUN_KINDS 4

/* One accumulation window of callback telemetry. Every counter is monotonic
 * within its window and is only ever cleared by the event that owns the window
 * (a fresh configure/start for the session window; le_perf_arm for the armed
 * one). Counts are 64-bit throughout — a 32-bit histogram bucket at ~1500
 * callbacks/second wraps inside a month, and this has to stay readable on an
 * appliance that has been up since the last OTA. Durations are microseconds: a
 * nanosecond figure would overflow uint32 after 4.3 s and nothing here is finer
 * than a microsecond anyway. */
typedef struct le_cb_window_snapshot {
  uint64_t calls;   /* device callbacks observed — raw context, never judged */
  uint64_t periods; /* period services completed (see the note above) */
  /* Services whose summed duration exceeded the deadline for the frames they
   * covered: the engine did not finish a period's work inside a period. THE
   * number to read — this is what a dropout is made of. */
  uint64_t late_periods;
  /* Entry-to-entry gaps longer than 1.5 NOMINAL PERIODS: the DERIVED
   * "the callback did not come back on time" signal, and the only one
   * available on CoreAudio, where miniaudio exposes nothing.
   *
   * WHAT IT CAN AND CANNOT DISTINGUISH. An entry-to-entry span contains the
   * previous callback's OWN duration, so a gap event says the callback stream
   * stalled — not whose fault it was. Two different causes reach it:
   *   - the device starved us: we returned promptly and it still came back
   *     late. Then `late_periods` stays flat and this moves alone, which is the
   *     reading the bench table is built on;
   *   - WE ran long: any single callback taking more than 1.5 nominal periods
   *     forces a gap event on the next entry by arithmetic alone. So this is
   *     NOT independent of `late_periods` — a badly overloaded engine moves
   *     both, and the pair moving together means "we were slow", not "two
   *     separate problems". (A merely late period service is not enough: the
   *     threshold is per-callback spacing, and a service is often several
   *     callbacks. It takes one callback past 1.5 periods.)
   * Read the two TOGETHER, never this one alone.
   *
   * Measured against the nominal period and NOT against the last block's
   * budget: on the split duplex loop the callbacks for one period arrive in a
   * burst and are then followed by a normal ~one-period wait, so a threshold
   * scaled to a sub-period block would fire at every single period boundary on
   * completely healthy hardware.
   *
   * NOT double-counted against `xruns`: an ALSA -EPIPE recovery also stalls the
   * loop, so a gap arriving within a few periods of a counted recovery is
   * suppressed. One physical dropout is counted once, under one name, and
   * max_gap_us is never pinned by a recovery stall — while a genuine stall
   * later in the session still registers. The suppressor excuses BACKEND
   * recoveries only; it does not excuse our own overrun, which is why the
   * coupling above is real and documented rather than filtered away. A device
   * reroute or a system audio interruption breaks the timeline instead of
   * producing a gap, so switching the default device mid-session reads 0. */
  uint64_t gap_events;
  uint32_t max_us;     /* worst period-service duration seen */
  uint32_t mean_us;    /* mean period-service duration over `periods` */
  uint32_t max_gap_us; /* worst counted gap (0 when none exceeded) */
  uint64_t buckets[LE_CB_BUCKETS]; /* service histogram; see LE_CB_BUCKETS */
  /* Real backend dropouts, indexed by le_xrun_kind: the per-class breakdown of
   * the flat xrun_count on le_snapshot.
   *
   * Over the session window these sum to xrun_count for every kind THIS BUILD
   * KNOWS — which is every kind any shipping backend produces (ALSA passes
   * 0/1/2, ASIO passes 3), so the sum holds today. It is not an invariant for
   * all time: a dropout reported with a kind outside le_xrun_kind increments
   * xrun_count but lands in no bucket, deliberately, because the headline
   * number's job is "a real dropout happened" and an unclassifiable one still
   * happened. Folding it into an existing bucket instead would corrupt the
   * breakdown; dropping it entirely would under-report reality. */
  uint64_t xruns[LE_XRUN_KINDS];
} le_cb_window_snapshot;

/* The whole instrument, read through le_engine_get_callback_telemetry.
 *
 * Deliberately NOT part of le_snapshot. These counters move on every audio
 * callback, and le_snapshot is projected at render rate into a value object
 * whose equality drives the app's rebuild dedupe — carrying them there would
 * make every projection unequal to the last and rebuild an idle rig
 * continuously, which is CPU pressure invented by the instrument that exists to
 * find CPU pressure. This is a pull for a bench or a diagnostics screen, and it
 * has no side effects (unlike le_engine_get_snapshot, which also drains the
 * engine's event ring). */
typedef struct le_callback_telemetry {
  /* The nominal period deadline in microseconds: buffer_frames / sample_rate.
   * 0 = no device has been opened, which is also the "inert" state in which
   * nothing at all is accumulated. */
  uint32_t budget_us;
  le_cb_window_snapshot session; /* since the device started */
  le_cb_window_snapshot armed;   /* since the most recent le_perf_arm */
} le_callback_telemetry;

/* Lock-free snapshot of engine state, published by the audio thread and read by
 * Dart on a render-rate timer. Fields are individually atomic; readers may see
 * a one-frame-stale mix across fields, which is fine for metering/UI. */
typedef struct le_snapshot {
  int32_t running;            /* 0/1: device is open and the callback is live */
  /* 0/1: the pinned (or default) device is currently present. DISTINCT from
   * `running`: a device can be lost (device_present == 0) while the engine
   * object still "runs" until it is restarted. Set from the RT-adjacent device
   * notification callback; the Dart layer derives a higher-level isConnected
   * from it and drives any reconnection (no reconnection happens in native). */
  int32_t device_present;
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t input_channels;     /* negotiated hardware capture channels */
  int32_t output_channels;    /* negotiated hardware playback channels */
  /* Bitmask of input channels excluded from recording/monitoring/routing
   * because their hardware (Core Audio) label matches "loopback". Such channels
   * are skipped in the capture average and in monitoring, and are stripped from
   * any track input mask. Always 0 off macOS / when no label matches. */
  uint32_t excluded_input_mask;
  uint64_t frames_processed;  /* total frames seen by the callback */
  /* Device dropouts (xruns) since the device started, as reported by the
   * backend, every class summed. The Windows ASIO backend tallies the driver's
   * kAsioOverload notifications; the direct ALSA path tallies miniaudio's
   * -EPIPE recoveries and its slipped-playback resyncs (#722), so this finally
   * moves on Linux. Still 0 on CoreAudio, which exposes no xrun signal at all —
   * read le_callback_telemetry's gap detector there. The per-class breakdown is
   * le_cb_window_snapshot.xruns; see its note for how the two relate.
   * Monotonic; cleared on each fresh start. */
  uint32_t xrun_count;
  float input_rms;            /* 0..1 */
  float input_peak;           /* 0..1 */
  float output_rms;           /* 0..1 */
  int32_t latency_state;      /* le_latency_state */
  double measured_latency_ms; /* valid when latency_state == LE_LATENCY_DONE */

  /* Looper transport (free mode: the first finalized recording sets the one
   * master loop length; everything else plays/overdubs against it). */
  int32_t master_length_frames;   /* 0 until the first recording is finalized */
  int32_t master_position_frames; /* current loop playhead */

  /* Record-offset latency compensation (frames). Recorded/overdubbed input is
   * written this many frames earlier in the loop so it aligns with what the
   * player heard. Auto-set by a latency measurement; manually overridable. */
  int32_t record_offset_frames;

  /* Added latency (frames) of the highest-latency effect active in any audible
   * or monitored lane chain — the MAXIMUM across active effects, so it stays
   * forward-compatible as effects accrue. Today the formant-preserving octaver
   * is the only contributor (~LE_PV_N frames; both PV and PSOLA modes report the
   * same value); every other effect adds 0, so this reads 0 whenever no octaver
   * is engaged. The Dart layer divides by sample_rate to show milliseconds and
   * warn a performer monitoring through the octaver. PURELY informational: this
   * does NOT feed record_offset_frames or any compensation — it only surfaces
   * the lag so the UI can suggest the lower-latency choice. */
  int32_t fx_added_latency_frames;

  /* Global master output gain (0..1) applied post-mix to the final output, after
   * every track/lane/monitor lane has summed in. 1.0 (unity) by default and on
   * every fresh configure. Set via le_engine_set_master_gain. */
  float master_gain;

  /* le_audio_backend actually running (negotiated). On Windows this is always
   * ASIO; on macOS/Linux it is the miniaudio backend. */
  int32_t active_backend;

  /* Structural output gate, one bit per hardware output channel (bit c => output
   * c is ENABLED). A disabled output is removed as a mix target — skipped in the
   * fan-out regardless of any lane/monitor mask pointing at it — while its stored
   * route masks are preserved (turning it back on restores them). Default: all
   * enabled (every bit in [0, output_channels) set) on a fresh configure, so the
   * absence of any gate is "all outputs on". Outputs beyond the device channel
   * count are reported enabled but never sounded. Set via
   * le_engine_set_output_enabled. */
  uint32_t output_enabled_mask;

  /* Performance-recording capture (le_perf_arm / le_perf_disarm). No separate
   * status ABI — these three atomics are the whole surface for this slice
   * (part 2 adds file-drain progress alongside them). */
  int32_t perf_armed;      /* 0/1: the RT taps are live */
  uint64_t perf_frames;    /* frames processed since the most recent arm */
  uint32_t perf_overruns;  /* dropped capture frames (ring full) since arm */
  /* Frames of digital silence the drain thread SUBSTITUTED into the capture
   * files since arm, because the audio they should have held never reached
   * it, summed over every file it writes (master + each monitored input).
   * A superset of perf_overruns' consequences: every dropped frame is
   * zero-filled, but a zero-fill can also come from audio that was counted
   * (perf_frames) yet never tapped. Read it as zero vs non-zero: non-zero
   * means the take contains silence the performer did not play -- #710's
   * audible flickers -- so the app latches it into the capture's glitch
   * flag exactly like perf_overruns. The per-gap positions stay in the
   * sidecar's `overrun_gaps`; this is the never-saturating total. */
  uint64_t perf_zero_filled_frames;
  /* 0/1: the drain thread stopped ITSELF because a write failed -- disk full,
   * a quota, a read-only remount, an I/O error. Published here because the
   * stop was otherwise invisible to the app: the thread stopped, the capture
   * stayed "armed", its handles stayed open, and finalize never ran, leaving
   * raw .pcm that was not even recoverable (#640, #652). Latches for the life
   * of the capture; cleared by the next arm. */
  int32_t perf_stopped;

  /* ---- Chromatic tuner (le_engine_set_tuner_input) ----
   *
   * Placed with the other metering floats rather than at the struct tail
   * because the trailing block below documents itself as offset-stable for
   * readers built against the older layout, and these are new fields on a
   * struct that is rebuilt from the header on every generation — the Dart
   * binding is generated, so there is no hand-written reader to keep. */
  float tuner_hz;         /* detected fundamental; 0 = no pitch this frame */
  float tuner_confidence; /* 0..1, YIN's voicing score for that frame */
  /* Echo of the armed channel, -1 when disarmed. Earns its place: without it
   * the UI cannot tell "armed and silent" from "not armed yet", and those two
   * need different words on screen. */
  int32_t tuner_input;

  /* Tracks. */
  int32_t track_count; /* number of usable tracks (<= LE_MAX_TRACKS) */
  le_track_snapshot tracks[LE_MAX_TRACKS];

  /* ---- tempo grid (trailing on purpose: every pre-existing field keeps its
   * offset, so a reader built against the old layout still reads correctly).
   * All default to grid-off values; with no tempo ever set and quantize off,
   * the engine's behavior is identical to the tempo-free build. */
  float tempo_bpm;      /* denominator-note beats per minute; 0 = unset */
  int32_t ts_num;       /* time-signature numerator (default 4) */
  int32_t ts_den;       /* time-signature denominator, 4 or 8 (default 4) */
  int32_t sync_tempo;   /* 0/1: loop<->grid sync on finalize (default 1) */
  int32_t quantize_div; /* le_grid_div granularity (default 0 = off) */
  int32_t tempo_source; /* le_tempo_source (default 0 = none) */
  /* Whole bars in the master loop, or 0 when no grid relationship exists
   * (sync off, no loop, or the loop predates any grid). The loop's AUDIO
   * length is never altered by the grid — bars is a derived count. */
  int32_t loop_bars;
  int32_t current_beat; /* 0..ts_num-1 within the bar: loop-driven, or driven
                         * by the count-in / free-running click; 0 idle */

  /* ---- click + count-in (A2; trailing for the same offset-stability reason
   * as the tempo block above). All default to click-off values: mode off,
   * mask 0 (unrouted), volume 1, count-in 0 bars — the untouched engine is
   * bit-identical to the click-free build. */
  int32_t click_mode;   /* le_click_mode (default 0 = off) */
  /* Exact command receipt: acquire commands_settled BEFORE a synchronous
   * snapshot read; do not admit another mode write until the read completes.
   * Revision advances on callback acceptance/refusal, including same-value
   * requests. It resets on configure; the actual mode survives configure. */
  uint32_t click_mode_revision;
  int32_t click_mode_result; /* LE_OK or LE_ERR_INVALID; prior mode on refusal */
  uint32_t click_mask;  /* click output bitmask (default 0 = no outputs) */
  float click_volume;   /* 0..LE_MAX_GAIN (default 1); the click's only gain */
  int32_t count_in_bars; /* count-in length in measures; 0 = off (default) */
  uint32_t record_start_revision;
  int32_t record_start_result; /* prior pair remains on callback refusal */
  int32_t counting_in;   /* 0/1: a count-in is currently running */
  /* Beat countdown while counting in: the number of count-in beats still to
   * come, INCLUSIVE of the one currently sounding (a one-bar 4/4 count-in
   * reads 4, 3, 2, 1, then 0 as the recording starts). 0 when idle. */
  int32_t count_in_beats_left;

  /* ---- looper mode (B2a, D4; trailing for the same offset-stability reason
   * as the tempo/click blocks above). Default MULTI (0) — an untouched
   * engine's mode reads MULTI, today's behavior. See le_looper_mode's doc for
   * the content-lock gate and what each value means. */
  int32_t looper_mode; /* le_looper_mode (default 0 = MULTI) */

  /* ---- primary track (B3, D18 as revised by the accepted design; trailing
   * for the same offset-stability reason as the blocks above). -1 = none
   * (default, and again whenever every track is empty). The engine crowns
   * the FIRST COMPLETED TAKE while nothing is crowned; an explicit re-crown
   * (le_engine_crown_primary) is the timing handoff. The designation
   * survives the primary alone being cleared/undone-to-empty while a sibling
   * still holds audio (so its re-record re-establishes it), and dies with
   * the last take. Every mode publishes it; it only GATES timing in
   * Sync/Band (see le_sync_quantize_active). */
  int32_t primary_track;

  /* ---- MIDI clock (Phase C, D15; trailing for the same offset-stability
   * reason as the blocks above). le_clock_mode; default 0 = OFF, so an
   * untouched engine emits no clock bytes. See le_engine_set_clock_mode. */
  int32_t clock_mode;

  /* ---- input clip detector + conditioning activity (input clip, S2;
   * trailing for the same offset-stability reason as the blocks above).
   * Both default to 0 — an untouched engine reports no HOT input and no
   * active conditioning. */
  /* Bit c: HOT — a rail-run (LE_CLIP_RUN consecutive raw samples at
   * |s| >= LE_CLIP_LEVEL) was seen on input c within the last
   * LE_CLIP_HOLD_MS of processed audio. Detected on the RAW device buffer,
   * so the flag reflects the ADC even when the conditioning stage has ducked
   * or notched what records. Loopback-excluded inputs never flag. */
  uint32_t input_clip_mask;
  /* Bit c: input c's conditioning stage is currently ACTIVE — enabled AND
   * not loopback-excluded, i.e. the stage actually runs on the audio path
   * (the UI truth for a "conditioning on" badge; a stage enabled on an
   * excluded channel reads 0 here because it never runs). */
  uint32_t input_cond_mask;
  /* Trailing (accepted design, slice 1): the master bus's absolute peak over
   * the most recent block, 0..1 (1.0 = full scale), read AFTER the master
   * gain and limiter — what actually reaches the outputs. Sums can clip when
   * no single track does, so the stage footer meters this rather than the
   * per-track peaks. Sibling of output_rms above. */
  float output_peak;
  /* ---- record start settings (accepted design, slice 2b; trailing).
   * Quantize is the control-side gate; auto_record and count_in_bars are
   * decoded together from the callback's applied recording-start choice.
   * le_engine_set_record_start publishes the exclusive pair together. */
  int32_t quantize;    /* 0/1: the global loop-grid record quantize gate */
  int32_t auto_record; /* 0/1: sound-activated record start */
  float overdub_feedback; /* the global coefficient, 0..1 (default 1) */
  /* ---- per-channel meters and capture trim (accepted design, slice 3;
   * trailing). Absolute block peaks may exceed unity; they are not clamped.
   * input_peaks[c] is input c's RAW device level (before conditioning and
   * trim, like input_clip_mask, so a hot ADC reads hot however the trim is
   * set); monitor_peaks[c] is its post-chain/gain/pan stereo peak BEFORE
   * output folding (0 while off, muted or without an enabled route).
   * output_peaks[c] follows master gain/limiter but EXCLUDES click.
   * input_trim[c] is the capture gain le_engine_set_input_trim holds
   * (linear, default 1). Indexed by hardware channel; entries past the
   * device's channel count read 0 (trim 1). */
  float input_peaks[LE_MAX_CHANNELS];
  float monitor_peaks[LE_MAX_CHANNELS];
  float output_peaks[LE_MAX_CHANNELS];
  float input_trim[LE_MAX_CHANNELS];
  uint32_t mix_revision; /* last wholly applied mix transaction */
  /* ---- output buses (slice 3b; trailing). output_bus_count is how many
   * the device has ((output_channels + 1) / 2); entries past it read the
   * defaults. */
  int32_t output_bus_count;
  float output_level[LE_MAX_OUTPUT_BUSES];   /* 0..1, default 1 */
  int32_t output_muted[LE_MAX_OUTPUT_BUSES]; /* 0/1 */
  int32_t output_mono[LE_MAX_OUTPUT_BUSES];  /* 0/1 */
  float output_balance[LE_MAX_OUTPUT_BUSES]; /* -1..1 */
  /* Advances on every Cut all sound the audio thread applied. */
  uint32_t tail_reset_rev;
  /* The capture policy of the armed take (1 = Follow output volume), or the
   * policy the next arm would freeze while not armed. */
  int32_t perf_follow_output;
  /* The output bus the armed take captures (the first bus with an enabled
   * channel at arm), or the one the next arm would capture; -1 when no
   * output is enabled. The offline render replays this bus's level and
   * mute under Follow output volume. */
  int32_t perf_capture_bus;
  float perf_output_level;
  int32_t perf_output_muted;
  uint32_t perf_capture_mask;
  uint32_t perf_output_enabled_mask;
  /* NOTE: the audio-callback telemetry (#722) is deliberately NOT here — see
   * le_callback_telemetry and le_engine_get_callback_telemetry. */
  /* One coherent applied timing tuple, never producer desired state. */
  uint32_t record_timing_revision;
  int32_t record_timing_result;
  int32_t record_timing_overrides[LE_MAX_TRACKS];
} le_snapshot;

/* ============================ Plugin hosting ==============================
 * Discovery of installed VST3 / CLAP audio-effect plugins. This first slice is
 * SCAN ONLY: no plugin is loaded into the audio graph, no audio thread is
 * touched. The whole surface runs on the control thread and an engine-owned
 * dedicated scan thread (see le_plugin_scan_begin) — never the audio callback.
 *
 * The hosting backends are compiled only in a SEGNO_ENABLE_PLUGINS build (macOS
 * today); other builds link a stub that reports "no plugins" so the symbols
 * always resolve over FFI. */

/* The plugin format a descriptor was discovered in. */
typedef enum le_plugin_format {
  LE_PLUGIN_VST3 = 0,
  LE_PLUGIN_CLAP = 1,
} le_plugin_format;

/* One discovered plugin class. Fixed-size POD so it round-trips over FFI like
 * le_device_info. A *failed* candidate (a file that could not be loaded or
 * described) is reported as an entry with an EMPTY `id` and `name`/`path` set to
 * the offending file, so a single broken plugin surfaces in the list instead of
 * aborting the scan (umbrella D-SCAN). The Dart layer treats `id == ""` as the
 * unavailable/failed marker. */
typedef struct le_plugin_desc {
  char id[256];    /* VST3 TUID as 32 hex chars / CLAP descriptor id — stable
                    * identity. Empty for a failed-to-scan entry. */
  char name[128];
  char vendor[128];
  char path[1024]; /* the .vst3 bundle / .clap file the class lives in */
  int32_t format;  /* le_plugin_format */
  uint32_t version; /* packed major<<16 | minor<<8 | patch, parsed from the
                     * plugin's version string (0 if unknown) */
} le_plugin_desc;

/* Opaque engine handle. */


LE_EXPORT int32_t le_engine_set_mix(le_engine* engine,
                                    const le_mix_settings* settings);
LE_EXPORT int32_t le_engine_record_with_image(le_engine* engine, int32_t channel,
                                              const le_record_image* image);

/* Returns the miniaudio + engine version string (never NULL). */
LE_EXPORT const char* le_version(void);

/* Detects a cable-free loopback capture path (PulseAudio monitor / virtual
 * driver / backend built-in loopback) by enumerating capture devices. Fills
 * *out and returns LE_OK, or LE_ERR_INVALID for a null argument / enumeration
 * failure. */
LE_EXPORT int32_t le_detect_loopback(le_loopback_info* out);

/* Enumerates the host's playback (output) devices into `out`, a caller-allocated
 * array with room for `max` entries, and writes the number filled into *count
 * (clamped to `max`). Returns LE_OK, or LE_ERR_INVALID for a null argument,
 * non-positive `max`, or an enumeration failure. Uses a transient ma_context, so
 * it is safe to call while an engine is already started. */
LE_EXPORT int32_t le_enumerate_playback_devices(le_device_info* out, int32_t max,
                                                int32_t* count);

/* Like le_enumerate_playback_devices but for capture (input) devices. */
LE_EXPORT int32_t le_enumerate_capture_devices(le_device_info* out, int32_t max,
                                               int32_t* count);

/* Reserved: always writes *count = 0 and returns LE_OK. ASIO was the Windows
 * duplex backend and went with the desktop targets; the symbol stays exported so
 * the Dart layer can keep calling it unconditionally. Returns LE_ERR_INVALID for
 * a null argument / non-positive `max`. */
LE_EXPORT int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                            int32_t* count);

/* ---- Plugin scanning (control thread; runs on a dedicated scan thread) ----
 *
 * le_plugin_scan_begin spawns ONE dedicated OS scan thread (the engine has no
 * thread pool) that walks the standard VST3 / CLAP install locations and loads
 * each candidate under a per-candidate guard, so one broken plugin yields a
 * "failed" entry rather than aborting the scan (D-SCAN). Dart polls
 * le_plugin_scan_poll on a timer and reads finished entries with
 * le_plugin_scan_get. The scan thread never touches the audio callback, so a
 * scan is safe while the engine is running.
 *
 * Only one scan runs at a time. `rescan != 0` is a hint to ignore any native
 * caching (none in this slice — caching lives in the Dart catalog). */

/* Starts an async scan. Returns LE_OK once the scan thread is launched, or
 * LE_ERR_INVALID for a null engine, LE_ERR_ALREADY_RUNNING if a scan is already
 * in progress. */
LE_EXPORT int32_t le_plugin_scan_begin(le_engine* engine, int32_t rescan);

/* Polls scan progress. Any out-pointer may be NULL. *done is 0 while scanning,
 * 1 once the scan thread has finished (or was cancelled). *found is the number
 * of entries currently retrievable via le_plugin_scan_get (grows as the scan
 * proceeds and includes failed entries). *scanned / *total are candidate files
 * processed / discovered. Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_plugin_scan_poll(le_engine* engine, int32_t* done,
                                      int32_t* found, int32_t* scanned,
                                      int32_t* total);

/* Copies the descriptor at `index` (0-based, < the last polled *found) into
 * *out. Returns LE_OK, or LE_ERR_INVALID for a null argument / out-of-range
 * index. Safe to call during or after a scan. */
LE_EXPORT int32_t le_plugin_scan_get(le_engine* engine, int32_t index,
                                     le_plugin_desc* out);

/* Requests cancellation and joins the scan thread (blocks briefly until the
 * in-flight candidate finishes). Idempotent; safe when no scan is running.
 * Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_plugin_scan_cancel(le_engine* engine);

/* ---- Plugin slot lifecycle (control thread; D-LIFE) ----
 *
 * An opaque handle to a plugin loaded into one lane / monitor FX chain slot.
 * Valid from a successful le_engine_set_*_plugin until that slot is cleared or
 * the engine is destroyed. The heavy work — instancing, activation, buffer
 * allocation — runs on the CONTROL thread; the audio thread only ever reads an
 * atomically-published "ready" flag and forwards samples. No plugin is ever
 * created, destroyed, or dylib-loaded on the audio callback. */


/* Loads the plugin identified by `plugin_id` (a scanned le_plugin_desc.id) into
 * FX chain slot `index` of a lane (channel, lane) or a monitor input. The load
 * + activate happen here on the control thread, BYPASSED, then the slot is
 * atomically published so the audio thread begins forwarding to it; until ready
 * the slot renders dry passthrough (no click). On success the chain entry's type
 * becomes LE_FX_PLUGIN and *out_slot receives the handle. The entry is activated
 * in the chain the same way as a built-in, via le_engine_set_lane_fx_count /
 * le_engine_set_monitor_input_fx_count. Returns LE_OK, LE_ERR_INVALID for a bad
 * argument / unknown plugin_id, or LE_ERR_DEVICE on a plugin load/activate
 * failure. (out_slot may be NULL if the caller does not need the handle.) */
LE_EXPORT int32_t le_engine_set_lane_plugin(le_engine* engine, int32_t channel,
                                            int32_t lane, int32_t index,
                                            const char* plugin_id,
                                            le_plugin_slot** out_slot);
LE_EXPORT int32_t le_engine_set_monitor_plugin(le_engine* engine, int32_t input,
                                               int32_t index,
                                               const char* plugin_id,
                                               le_plugin_slot** out_slot);

/* Clears a plugin slot: the audio thread is signalled to stop forwarding to it,
 * and the host is destroyed on the control thread only AFTER a published-
 * quiescent handshake (so there is never a use-after-free or an audio-thread
 * free). The chain entry returns to LE_FX_NONE. Idempotent on an empty slot.
 * Returns LE_OK or LE_ERR_INVALID. */
LE_EXPORT int32_t le_engine_clear_lane_plugin(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t index);
LE_EXPORT int32_t le_engine_clear_monitor_plugin(le_engine* engine,
                                                 int32_t input, int32_t index);

/* ---- Plugin parameters (control thread; D-PARAM) ----
 *
 * A plugin's parameters are a VARIABLE-LENGTH list sourced live from the plugin
 * — separate from the built-in fixed 4-float LE_FX_PARAMS surface, which is left
 * untouched. Values are PLAIN (not normalized): VST3's normalized params are
 * converted via normalizedParamToPlain; CLAP params are already plain. */

/* Bit flags for le_plugin_param_info.flags. */
typedef enum le_plugin_param_flags {
  LE_PARAM_AUTOMATABLE = 1 << 0,
  LE_PARAM_READONLY = 1 << 1,
  LE_PARAM_BYPASS = 1 << 2,
  LE_PARAM_HIDDEN = 1 << 3,
  LE_PARAM_STEPPED = 1 << 4,
} le_plugin_param_flags;

/* One plugin parameter's metadata. Fixed-size POD for FFI, like le_plugin_desc. */
typedef struct le_plugin_param_info {
  uint32_t id;        /* stable param id (VST3 ParamID / CLAP clap_id) */
  char name[128];
  char unit[32];
  double min;
  double max;
  double def;         /* default plain value */
  int32_t step_count; /* 0 = continuous; >0 = discrete steps */
  uint32_t flags;     /* le_plugin_param_flags bitmask */
} le_plugin_param_info;

/* The number of parameters the plugin in `slot` exposes. Returns LE_OK, or
 * LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_param_count(le_plugin_slot* slot, int32_t* count);

/* Copies the metadata of the parameter at `index` (0-based, < count) into *out.
 * Returns LE_OK, or LE_ERR_INVALID for a null argument / out-of-range index. */
LE_EXPORT int32_t le_plugin_param_info_at(le_plugin_slot* slot, int32_t index,
                                          le_plugin_param_info* out);

/* Reads the current plain value of parameter `id` into *plain. Returns LE_OK,
 * or LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_param_get(le_plugin_slot* slot, uint32_t id,
                                      double* plain);

/* Sets parameter `id` to the plain `value`. THREAD-SAFE: enqueues onto the
 * slot's lock-free SPSC ring, drained into the SDK's own event mechanism
 * (VST3 IParameterChanges / CLAP clap_input_events) at the top of the next
 * process() — never a direct store from the audio thread (D-PARAM). Returns
 * LE_OK, or LE_ERR_INVALID for a null slot. */
LE_EXPORT int32_t le_plugin_param_set(le_plugin_slot* slot, uint32_t id,
                                      double value);

/* Formats parameter `id`'s plain `value` to the plugin's own display string
 * (e.g. "-6.0 dB", "Lowpass"), copied NUL-terminated into out[out_size]. Lets
 * the UI label discrete params and read out continuous ones in real units.
 * CONTROL THREAD. Returns LE_OK, LE_ERR_INVALID for a null argument, or
 * LE_ERR_UNSUPPORTED when the plugin offers no text for it. */
LE_EXPORT int32_t le_plugin_param_value_text(le_plugin_slot* slot, uint32_t id,
                                             double value, char* out,
                                             int32_t out_size);

/* ---- Native editor window (MAIN THREAD; macOS only) ---- */

/* Opens the plugin's own native editor in a HOST-OWNED top-level OS window
 * (D-WIN) — not embedded in the Flutter tree. Idempotent: a second call while
 * the editor is already open is a no-op success. Returns LE_OK, LE_ERR_INVALID
 * for a null slot, or LE_ERR_UNSUPPORTED when the plugin has no editor / the
 * platform view type is unsupported (or on a non-macOS build). */
LE_EXPORT int32_t le_plugin_editor_open(le_plugin_slot* slot);

/* Force-closes the editor window and detaches the plugin view (D-WIN teardown).
 * Idempotent: closing an already-closed editor is a no-op success. Returns
 * LE_OK, or LE_ERR_INVALID for a null slot. */
LE_EXPORT int32_t le_plugin_editor_close(le_plugin_slot* slot);

/* Writes 1 into *open if the editor window is currently open, else 0. Returns
 * LE_OK, or LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_editor_is_open(le_plugin_slot* slot, int32_t* open);

/* ---- Opaque plugin state, for session persistence (MAIN THREAD; D-P1) ---- */

/* Writes the byte size of the plugin's current opaque state into *bytes.
 * Returns LE_OK, LE_ERR_INVALID for a null argument, or LE_ERR_UNSUPPORTED when
 * the plugin exposes no state (then *bytes is 0). */
LE_EXPORT int32_t le_plugin_state_size(le_plugin_slot* slot, int32_t* bytes);

/* Captures the plugin's opaque state into `buf` (capacity `cap`), writing the
 * full byte size into *written. If `cap` is smaller than *written (or `buf` is
 * NULL), nothing is copied — the caller should retry with a buffer of at least
 * *written bytes. Returns LE_OK, LE_ERR_INVALID for a null slot/`written`, or
 * LE_ERR_UNSUPPORTED when the plugin has no state. */
LE_EXPORT int32_t le_plugin_state_get(le_plugin_slot* slot, uint8_t* buf,
                                      int32_t cap, int32_t* written);

/* Restores the plugin from an opaque state blob previously captured with
 * le_plugin_state_get. Returns LE_OK, LE_ERR_INVALID for a null slot (or null
 * `buf` with `bytes` > 0), or LE_ERR_UNSUPPORTED when the plugin rejects it. */
LE_EXPORT int32_t le_plugin_state_set(le_plugin_slot* slot, const uint8_t* buf,
                                      int32_t bytes);

/* Allocates an engine. Returns NULL on allocation failure. */
LE_EXPORT le_engine* le_engine_create(void);

/* Stops (if running) and frees the engine. Safe to call with NULL. */
LE_EXPORT void le_engine_destroy(le_engine* engine);

/* Opens the default duplex device with `config` and starts the audio callback.
 * Allocates the track buffers before the device starts. Returns LE_OK or an
 * le_result error. */
LE_EXPORT int32_t le_engine_start(le_engine* engine, const le_config* config);

/* Stops and closes the device. Returns LE_OK or an le_result error. */
LE_EXPORT int32_t le_engine_stop(le_engine* engine);

/* What le_engine_reopen did with the recorded material (#1140). */
typedef enum le_reopen_outcome {
  LE_REOPEN_RETAINED = 0,     /* loops, history, Fade kept; tracks STOPPED */
  LE_REOPEN_CLEARED_RATE = 1, /* the device negotiated another sample rate */
  LE_REOPEN_CLEARED_CAP = 2,  /* max_loop_frames differs from the buffers */
  LE_REOPEN_RETAINED_PARTIAL = 3, /* retained, except the tracks named in the
                                   * dropped mask: a Clear/Undo/Redo/cancel or
                                   * Session commit on them was still
                                   * unapplied at the loss */
} le_reopen_outcome;

/* Reopens the audio device after a loss WITHOUT discarding the recorded loops
 * (#1140). Requires a stopped (le_engine_stop) engine that was started
 * before: LE_ERR_ALREADY_RUNNING while running, LE_ERR_NOT_RUNNING when never
 * configured (a cold engine goes through le_engine_start). Opens the device
 * like le_engine_start, then — at the same negotiated sample rate and loop
 * cap — keeps every lane's PCM, the undo/redo history, loop multiples, take
 * ids and the crown, and brings each content track back STOPPED at the loop
 * head with its Fade frozen (the ramp resumes toward its target at the
 * original full-travel rate on the next Play). A take still capturing at the
 * loss is dropped: a first recording leaves its track EMPTY, an in-progress
 * overdub pass is reverted sample-exactly (committed layers stay), a take
 * still in its seam crossfade or trailing fold goes with it. Recording never
 * resumes. A track whose Clear/Undo/Redo/cancel or Session commit the audio
 * thread never applied is dropped the same way — EMPTY, its history gone —
 * and named in *dropped_track_mask (bit t = track t, NULL to not ask), with
 * *outcome LE_REOPEN_RETAINED_PARTIAL; every other track is retained. A
 * drop that empties the rig resets the master as a clear does. Only another
 * sample rate or loop cap clears the whole engine, exactly as le_engine_start
 * does, with *outcome LE_REOPEN_CLEARED_RATE / _CAP and a zero mask. A
 * running performance capture ends with DEVICE_CHANGED either way. Every
 * setting the host replays after a start (routing, mix, FX, monitors,
 * conditioning, output gates) is reset here too; routes to inputs or outputs
 * the new device lacks stay silent.
 *
 * Returns LE_OK or an le_result error. A failed open changes nothing (the
 * material is still held, still stopped, *outcome and the mask untouched), so
 * the caller may retry. A failed start returns LE_ERR_DEVICE with the material
 * already settled per *outcome — still retained and stopped on
 * LE_REOPEN_RETAINED / _PARTIAL. */
LE_EXPORT int32_t le_engine_reopen(le_engine* engine, const le_config* config,
                                   int32_t* outcome,
                                   int32_t* dropped_track_mask);

/* ---- device-free test pump ----
 *
 * The two calls a test harness needs to drive the engine deterministically
 * with NO audio device: configure the tracks/buffers, then pump blocks through
 * the same block processor the real device callback runs. Exactly how the
 * native test suite (src/test/test_engine_core.c) exercises the engine; the
 * Dart sequence fuzzer uses these through the generated bindings. NOT part of
 * the app's runtime surface — the app always goes through le_engine_start. */

/* Allocates/resets the track buffers and marks the engine configured, without
 * opening a device. `max_loop_frames <= 0` selects the default (30 s). */
LE_EXPORT int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                                      int32_t input_channels,
                                      int32_t output_channels,
                                      int32_t max_loop_frames);

/* le_engine_reopen without the device: the retention decision, the material
 * settle and the runtime reset, on an engine le_engine_configure (or a
 * previous start) already configured. `max_loop_frames <= 0` selects the
 * default, as in le_engine_configure. Same preconditions, results, *outcome
 * values and dropped-track mask as le_engine_reopen. */
LE_EXPORT int32_t le_engine_reopen_configured(le_engine* engine,
                                              int32_t sample_rate,
                                              int32_t input_channels,
                                              int32_t output_channels,
                                              int32_t max_loop_frames,
                                              int32_t* outcome,
                                              int32_t* dropped_track_mask);

/* Flips the published device-present flag to 0 while the engine keeps
 * running — what the backend's device-lost notification does — so a host
 * driving the device-free pump can rehearse its reconnect path (a stop,
 * then le_engine_reopen_configured) without a device to unplug. */
LE_EXPORT void le_engine_mark_device_lost(le_engine* engine);

/* Processes one block exactly like the device callback: drains the command
 * ring, records/mixes `frames` frames from `input` (interleaved f32, may be
 * NULL for silence) into `output`, advances the transport, publishes
 * metering/undo events. frames == 0 still drains rings and advances the
 * per-block maintenance (the test suites' `drain` idiom). */
LE_EXPORT void le_engine_process(le_engine* engine, float* output,
                                 const float* input, uint32_t frames);

/* Copies the current state snapshot into *out. No-op if either pointer is NULL.
 */
LE_EXPORT void le_engine_get_snapshot(le_engine* engine, le_snapshot* out);

/* Copies the audio-callback telemetry (#722) into *out. No-op if either pointer
 * is NULL; a never-started engine fills zeros.
 *
 * Its own entry point rather than a block on le_snapshot, for two reasons. It
 * is a DIAGNOSTIC PULL — a bench readout, a support screen — not render-rate
 * state, and keeping it off le_snapshot is what guarantees a per-callback
 * counter can never leak into the app's projected state and defeat its rebuild
 * dedupe. And it is SIDE-EFFECT FREE: le_engine_get_snapshot also runs
 * le_engine_drain_events (collecting retired undo layers), which a diagnostic
 * read has no business triggering. Pure relaxed atomic loads; safe from the
 * control thread at any time, running or not. */
LE_EXPORT void le_engine_get_callback_telemetry(le_engine* engine,
                                                le_callback_telemetry* out);

/* Copies track `channel`'s snapshot into *out. Out-of-range channels yield an
 * empty track. No-op if either pointer is NULL. */
LE_EXPORT void le_engine_get_track(le_engine* engine, int32_t channel,
                                   le_track_snapshot* out);

/* Copies up to `max_points` of the loop waveform — peaks of the mixed output
 * indexed by position across exactly one master loop (bucket 0 = loop start),
 * each in 0..1 — into `out`; returns the number written. Pair with the
 * snapshot's master_position/master_length for the playhead. Lock-free read of
 * the audio thread's loop-visualization buffer; empty until a loop exists. */
LE_EXPORT int32_t le_engine_read_visual(le_engine* engine, float* out,
                                        int32_t max_points);

/* Copies a single track's waveform over its full recorded length (channel
 * 0..track_count-1). Pair with the track snapshot's position_frames and
 * length_frames. The shape is retained while stopped and cleared when its
 * take is removed; a first recording gains its shape as playback sweeps it. */
LE_EXPORT int32_t le_engine_read_track_visual(le_engine* engine,
                                              int32_t channel, float* out,
                                              int32_t max_points);

/* Name of the active duplex/playback device, or "" if not running. The returned
 * pointer is owned by the engine and valid until the next start/stop. */
LE_EXPORT const char* le_engine_device_name(le_engine* engine);

/* Posts a command into the engine's SPSC ring (drained by the audio thread).
 * Returns LE_OK, LE_ERR_NOT_RUNNING, or LE_ERR_INVALID (ring full / bad args).
 */
LE_EXPORT int32_t le_engine_post_command(le_engine* engine, int32_t code,
                                         int32_t arg_i, float arg_f);

/* Convenience: triggers a single loopback latency measurement. Requires an
 * output->input loopback path. */
LE_EXPORT int32_t le_engine_measure_latency(le_engine* engine);

/* ---- looper control (per channel) ---- *
 * These post ring commands targeting track `channel` (0..track_count-1).
 * le_engine_record additionally takes the one-level undo snapshot on the calling
 * thread when it begins an overdub (the track is read-only on the audio thread
 * at that moment), so the audio callback only performs an O(1) buffer swap to
 * undo — never a copy. */
LE_EXPORT int32_t le_engine_record(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_stop_track(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_play(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_clear(le_engine* engine, int32_t channel);
/* Clear that leaves a restore point: identical to le_engine_clear, except the
 * track's history survives with a LE_HIST_CLEAR entry pushed on top, so the next
 * le_engine_undo puts the take back — content, length, multiple, state, mutes,
 * and the master grid if this clear reset it — with the erased take's overdub
 * layers still peelable beneath it. le_engine_redo then re-clears.
 *
 * Use this for a USER clear. le_engine_clear stays the destructive one, and must
 * remain so for its two non-user callers: session load, and the internal clear
 * le_engine_record posts to redefine the grid when recording onto an otherwise-
 * empty looper (which would otherwise leave a bogus restore point on every take).
 *
 * The restore point is dropped — and this decays to a plain clear — when the
 * track has nothing to restore (already empty / zero length), when a fresh
 * recording on this track overwrites the live slot it names, or when the pool
 * runs out of room for it. `undo` is never a promise, only an offer. */
LE_EXPORT int32_t le_engine_clear_undoable(le_engine* engine, int32_t channel);
/* Undo on track [channel]: peels the most recent overdub pass, restores a
 * cleared take, or empties the track past its base take (redo-ably). During
 * a capture (accepted design, slice 2):
 *   - OVERDUBBING: the pass punches out now (not at the grid) and the layer
 *     it was writing is peeled as soon as it retires, so the track plays its
 *     pre-pass audio; redo puts the partial pass back without resuming the
 *     capture. A pass that had written nothing peels the previous layer.
 *   - RECORDING: the take is cancelled — finalized at its captured length
 *     (a defining take still establishes the grid it would have) and held
 *     for redo while the track reads EMPTY; redo plays it immediately
 *     (LE_CMD_CANCEL_TAKE / LE_EVT_TAKE_CANCELLED).
 * A user clear (le_engine_clear_undoable) on a capturing track freezes the
 * take STOPPED at the clear and keeps it restorable the same way. An undo
 * that reaches the engine while the take is already ending (a finalize that
 * landed in the same block) is declined: the take stays as it finalized.
 * Restoring completed audio returns LE_ERR_MODE_MISMATCH when it would not
 * fit the current mode/clock, or LE_ERR_NOT_READY while its required report
 * or preceding clock changes are pending. Neither refusal changes history,
 * audio, mutes, or transport; retry after an explicit compatible mode choice
 * or after pending work settles. */
LE_EXPORT int32_t le_engine_undo(le_engine* engine, int32_t channel);
/* Projects the selected channels' next undo (redo = 0) or redo (redo = 1)
 * in ascending channel order without consuming history or posting commands.
 * Returns LE_OK when the resulting recovered spans fit the current mode and
 * clock, LE_ERR_MODE_MISMATCH when they do not, or LE_ERR_NOT_READY while a
 * selected recovery length or an earlier clear/mode/crown/defining-record
 * command is pending, including a sibling cancellation that may establish
 * the shared clock.
 * Invalid handles, masks, or redo values return LE_ERR_INVALID; an engine
 * that is not configured returns LE_ERR_NOT_RUNNING. An empty mask is valid.
 * A group must preflight its whole mask before executing members in ascending
 * order. On either refusal the caller must leave the entire group untouched.
 * Free/Song accept arbitrary completed spans once pending work settles. */
LE_EXPORT int32_t le_engine_history_mode_gate(le_engine* engine,
                                              uint32_t channels, int32_t redo);

/* Whether the NEXT le_engine_undo on `channel` would restore a cleared take
 * (1) rather than peel an overdub layer or empty the track (0). Also 0 for an
 * invalid channel or a stopped engine.
 *
 * For a host that has to put back state the engine does not own — the take's FX
 * chains, say. Ask BEFORE undoing: afterwards the answer describes the next tap,
 * not the one just made. Deriving it from a snapshot instead would race — the
 * snapshot publishes a_state, which does not flip until the audio thread applies
 * the restore, whereas this reads the control thread's own history stack and is
 * exact the moment it returns. */
LE_EXPORT int32_t le_engine_undo_restores_clear(le_engine* engine,
                                                int32_t channel);
/* Whether a user clear on a capturing track has frozen the take and its
 * restore point is still to be filed (1) — the next le_engine_undo_restores_
 * clear answer will be 1 once the audio thread's report lands. 0 otherwise,
 * for an invalid channel or a stopped engine. A host grouping clears asks
 * this beside le_engine_undo_restores_clear to know which tracks the clear
 * can give back. */
LE_EXPORT int32_t le_engine_clear_restore_pending(le_engine* engine,
                                                  int32_t channel);
/* Whether the NEXT le_engine_redo on `channel` re-applies a clear that an
 * undo took back (1) rather than re-stacking an overdub layer or
 * resurrecting an undone-to-empty track (0). The redo twin of
 * le_engine_undo_restores_clear, for the same host bookkeeping. */
LE_EXPORT int32_t le_engine_redo_reclears(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_redo(le_engine* engine, int32_t channel);
/* Removes the newest overdub layer as one history entry (#1164): the pre-pass
 * image becomes live, the removed image is kept for le_engine_undo, and the
 * Redo branch is dropped. Never touches the original take: Peel consumes the
 * topmost overdub layer reachable through earlier peels only, so the deepest
 * layer (the pre-first-overdub image) is swapped in but never consumed, and
 * any non-overdub history above the layers (a clear, a loop-close restoration)
 * blocks it. Undo of a Peel restores the layer; Redo re-peels. A synchronous
 * control-thread swap like the in-track undo: no command, no receipt.
 * LE_ERR_INVALID when no overdub layer can be peeled (none remain, the track
 * is empty or cleared, or the newest edit is not an overdub); LE_ERR_NOT_READY
 * while the track captures, drains a layer, or has a pending state command,
 * cancel, Clear report or Count-in launch — never queued, nothing mutated. */
LE_EXPORT int32_t le_engine_peel(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_set_track_volume(le_engine* engine, int32_t channel,
                                             float volume);
LE_EXPORT int32_t le_engine_set_track_mute(le_engine* engine, int32_t channel,
                                           int32_t muted);

/* Routes track `channel`'s record sources to the input channels set in `mask`
 * (a bitmask; bit c => hardware input channel c). Selected inputs are averaged
 * into the track's mono buffer. Bits beyond the negotiated input-channel range
 * are ignored. */
LE_EXPORT int32_t le_engine_set_input_mask(le_engine* engine, int32_t channel,
                                           int32_t mask);

/* Routes track `channel`'s playback to the output channels set in `mask` (a
 * bitmask; bit c => hardware output channel c). Bits beyond the negotiated
 * output-channel range are ignored. */
LE_EXPORT int32_t le_engine_set_output_mask(le_engine* engine, int32_t channel,
                                            int32_t mask);

/* ---- multi-lane recording ---- *
 * A track owns up to LE_MAX_LANES lanes; each records one hardware input into
 * its own clean mono buffer (never merged with sibling lanes) and plays back
 * through its own routing/volume/mute. All lanes of a track share one
 * transport (record/stop/play/clear/undo are track-addressed and fan out to
 * every active lane) and one undo span. The track-addressed setters above
 * (volume/mute/input/output mask) operate on lane 0 for backward
 * compatibility. */

/* Internal structural count command. Valid count is 1..LE_MAX_LANES.
 * Allocates only newly needed inactive buffers on the control thread and
 * queues activation; LE_OK means accepted, not published. Await commandsSettled
 * before depending on the count or importing. A prior count command retains
 * its buffer lifetime through the end of the callback block. Shrinking refuses
 * recoverable lanes. Retained routing and effects remain attached to their
 * lane identities. User routing edits use the atomic mix transaction instead. */
LE_EXPORT int32_t le_engine_set_lane_count(le_engine* engine, int32_t channel,
                                           int32_t count);

/* Routes lane [lane] of track [channel] to record from hardware input
 * [input_channel] (-1 = record nothing). Bits beyond the negotiated input range
 * or loopback-excluded channels record silence. */
LE_EXPORT int32_t le_engine_set_lane_input(le_engine* engine, int32_t channel,
                                           int32_t lane, int32_t input_channel);

/* Routes lane [lane] of track [channel]'s playback to the output channels set
 * in [mask] (bit c => output channel c). Bits beyond the output range are
 * ignored. */
LE_EXPORT int32_t le_engine_set_lane_output(le_engine* engine, int32_t channel,
                                            int32_t lane, int32_t mask);

/* Sets lane [lane] of track [channel]'s playback gain, clamped to
 * 0..LE_MAX_GAIN (2.0, +6.02 dB headroom above unity). */
LE_EXPORT int32_t le_engine_set_lane_volume(le_engine* engine, int32_t channel,
                                            int32_t lane, float volume);

/* Mutes or unmutes lane [lane] of track [channel]. */
LE_EXPORT int32_t le_engine_set_lane_mute(le_engine* engine, int32_t channel,
                                          int32_t lane, int32_t muted);

/* Sets lane [lane] of track [channel]'s pan, -1 (left) .. 1 (right), 0 centre
 * (accepted design, slice 3). A lane's output is a stereo pair (mono content
 * reads as an equal pair until a stereo effect spreads it); the pan scales
 * that pair before le_fx_route places it, with a unity-centre balance law:
 * the near side stays at unity and the far side falls on a quarter-sine
 * (left = cos(max(pan, 0) * pi/2), right = cos(max(-pan, 0) * pi/2)). Centre
 * is therefore bit-identical to an unpanned lane, and hard left is the left
 * output alone. A single masked output receives the (l + r) / 2 mid as
 * before, so pan on a mono route is a plain attenuation. Applied on the
 * legacy per-lane route and on the summed track bus alike; the loop-stage
 * wet cache stores the unpanned render, so a pan change never invalidates
 * it. Reset to centre by (re)configure, like volume; remembered and
 * re-applied by the caller. */
LE_EXPORT int32_t le_engine_set_lane_pan(le_engine* engine, int32_t channel,
                                         int32_t lane, float pan);

/* Solos or un-solos track [channel] (accepted design, slice 3). While any
 * track is soloed, only soloed tracks route to the outputs; every other
 * track's lanes keep playing (their chains keep running, their meters keep
 * reading the dry content) but route nothing, exactly as a muted lane does.
 * Independent of mute: a soloed muted track is still silent, and clearing
 * every solo leaves the mutes as they were. Monitors are not tracks and are
 * unaffected. Reset by (re)configure. */
LE_EXPORT int32_t le_engine_set_track_solo(le_engine* engine, int32_t channel,
                                           int32_t solo);

/* Sets hardware input [input]'s capture trim (accepted design, slice 3):
 * a linear gain, default 1, applied to the sample a lane RECORDS from that
 * input and to nothing else — the monitor path, the input meters, the clip
 * detector, the sound-activated trigger and the tuner all read the
 * untrimmed input: raw for meters/clipping, conditioned for trigger/tuner.
 * Clamped to 0..LE_MAX_INPUT_TRIM. Takes
 * effect on the next block (a direct store, so it works while stopped);
 * reset to 1 by (re)configure. */
LE_EXPORT int32_t le_engine_set_input_trim(le_engine* engine, int32_t input,
                                           float gain);

/* Copies lane [lane] of track [channel]'s snapshot into *out. Out-of-range
 * channels/lanes yield an empty lane. No-op if either pointer is NULL. */
LE_EXPORT void le_engine_get_lane(le_engine* engine, int32_t channel,
                                  int32_t lane, le_lane_snapshot* out);

/* Sets the record-offset latency compensation in frames (clamped >= 0). */
LE_EXPORT int32_t le_engine_set_record_offset(le_engine* engine,
                                              int32_t frames);

/* Cancels track [channel]'s pending record arm, whatever armed it — the
 * quantized loop-top arm, the signal-triggered (auto-record) arm, or a Band
 * section toggle. No-op (LE_OK) when the track is not armed.
 *
 * Returns LE_OK only when the cancel actually reached the audio thread. The
 * disarm rides the command ring, so it can be refused (a full ring behind
 * stalled callbacks, or an engine that is not configured) — and a caller that
 * needs "nothing fires later" must treat that as the arm still being live,
 * not as a cancel.
 *
 * This is the UNCONDITIONAL cancel. le_engine_record also cancels an arm, but
 * only as the second half of a press: it must first match the arm's trigger
 * (a foreign trigger is rejected with LE_ERR_INVALID rather than swallowed)
 * and its cancelling branches are gated on the conditions that created the arm
 * still holding — with the transport parked, or quantize since turned off, the
 * same call falls through and STARTS a capture instead. A caller that means
 * "make sure nothing fires later" — the app's FX-mode entry, which hands the
 * user a surface with no transport controls — needs this, not that. */
/* Explicit transport intents, resolved atomically by the callback. Rec Stop
 * cancels the shared launch cohort/grace, otherwise finishes only an actual
 * cursor capture with normal Record timing. It never acquires a new take.
 * Cancel Count-in touches only that cohort/grace, never ordinary arms or an
 * older running capture. Both report queue/admission refusal synchronously. */
LE_EXPORT int32_t le_engine_stop_record_control(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_cancel_count_in(le_engine* engine);

LE_EXPORT int32_t le_engine_cancel_arm(le_engine* engine, int32_t channel);

/* Finalizes track [channel]'s live NON-DEFINING recording take NOW,
 * unconditionally — the counterpart to le_engine_cancel_arm above: cancel_arm
 * kills the PENDING (an arm that has not fired), this kills the LIVE (a take
 * already capturing). The finalize is exactly what a quantize-off record
 * press does today — never off-grid: the length rounds UP to whole base
 * loops, the unfilled tail is the digital silence the capture prep wrote,
 * with the stopped-early seam treatment applied — but it skips the quantize
 * deferral, the auto-record arm toggle, and the shared arm machinery
 * entirely, so it can neither arm a take nor cancel (or consume) anyone
 * else's arm, and it never continues into overdub (rec/dub is a record-press
 * meaning; the take settles to PLAYING).
 *
 * Refuses (LE_ERR_INVALID) unless the take is safe to end here:
 * - the track is not RECORDING (EMPTY, PLAYING, OVERDUBBING, STOPPED, or a
 *   parked transport — nothing starts, nothing punches in or out);
 * - the take is the DEFINING one (nothing else holds the grid): ending it
 *   would let this call set the session's bar length mid-gesture, so the
 *   defining take keeps running and the caller falls back to
 *   capture-survives;
 * - the channel still has a live pending arm (any trigger): the arm belongs
 *   to another command and must be retired first (le_engine_cancel_arm) —
 *   finalizing under it would leave it to fire onto the settled loop later.
 *
 * Pending Count-in members are retired explicitly with cancel_arm.
 *
 * Like cancel_arm, LE_OK means the command actually reached the ring; the
 * audio thread re-checks the RECORDING/non-defining precondition on apply,
 * so a state change racing the post degrades to a no-op, never to a start. */
LE_EXPORT int32_t le_engine_finalize_take(le_engine* engine, int32_t channel);

/* ---- tempo grid ----
 * Grid state + locks (A1) and the click + count-in built on them (A2); the
 * musical (subdivision) arm machinery lands in a later part. With every
 * default in place (no tempo ever set, quantize_div off, click mode off,
 * count-in 0) the engine behaves exactly like the tempo-free build.
 *
 * Tempo LOCK (D6): while any track has content AND a grid exists
 * (loop_bars > 0 or tempo_source != none), set_tempo / set_time_signature /
 * tap_tempo are accepted but IGNORED by the audio thread (the published state
 * is unchanged). Clearing every track releases the lock; the tempo VALUE and
 * its source survive the clear (a derived tempo outlives its source loop). */

/* Sets the tempo in denominator-note beats per minute, clamped to 30..300.
 * Sets tempo_source = manual; ignored while the tempo is locked. */
LE_EXPORT int32_t le_engine_set_tempo(le_engine* engine, float bpm);
/* Restores a session's exact musical tempo and its source while stopped.
 * NONE requires BPM 0; MANUAL/TAPPED/DERIVED require finite BPM in 30..300.
 * EXTERNAL is live clock state and cannot be restored by a session.
 * Invalid arguments return LE_ERR_INVALID; unconfigured engines return
 * LE_ERR_NOT_RUNNING. Sounding/capturing/armed tracks or unacknowledged
 * transport changes return LE_ERR_NOT_READY without posting. The callback
 * rechecks transport before applying. Post after clear settlement and before
 * the new session's mode/crown/import commands. No audio or loop span changes. */
LE_EXPORT int32_t le_engine_restore_tempo(le_engine* engine, float bpm,
                                          int32_t source);

/* Sets the time signature. Only the 17 Sheeran signatures are valid — x/4 for
 * num 2..7 and x/8 for num 5..15 — anything else returns LE_ERR_INVALID
 * without posting. Ignored while the tempo is locked. */
LE_EXPORT int32_t le_engine_set_time_signature(le_engine* engine, int32_t num,
                                               int32_t den);

/* Registers a tap; two taps set the tempo from their interval (intervals
 * outside the 30..300 BPM window are ignored, so a stale first tap never
 * yields an absurd tempo). Sets tempo_source = tapped on success; taps are
 * ignored entirely while the tempo is locked. */
LE_EXPORT int32_t le_engine_tap_tempo(le_engine* engine);

/* Enables/disables loop<->grid sync (default ON). When on, finalizing the
 * DEFINING loop establishes the grid relationship: with a tempo already set
 * (manual/tapped/derived) the loop's whole-bar count is rounded to the
 * existing grid and the tempo is untouched; with no tempo set (source none)
 * a tempo is derived from the loop per D7 (whole bars in the current
 * signature, BPM in 30..300, nearest 120) and tempo_source becomes derived.
 * The loop's AUDIO length is never altered either way. When off, the loop
 * stays free-form (loop_bars 0, tempo untouched) — the tempo-free behavior. */
LE_EXPORT int32_t le_engine_set_sync_tempo(le_engine* engine, int32_t on);

/* ---- looper mode (B2a; content rules per the accepted design, slice 2) ----
 * The five architectural looper modes (le_looper_mode). Mode is a
 * session-level choice. With recorded audio it changes only when the takes
 * fit the target and the rig is not capturing or waiting on an armed action:
 *   - MULTI needs whole multiples of the shortest populated track;
 *   - SYNC and BAND need every populated track to be a whole multiple of the
 *     primary's span, or one of the divisions the engine plays (a half or a
 *     quarter of it); the primary is the crowned track when it holds a take,
 *     else the lowest populated track;
 *   - SONG and FREE take independent spans as they are.
 * No take is trimmed, repeated, stretched or padded to fit: an unfit set is
 * refused (LE_MODE_GATE_SPANS). Playing loops are stopped first — the
 * switch itself lands on a stopped rig, so every playhead restarts from the
 * top — and stopped loops stay stopped: the performer starts them again.
 * Mode switching is NOT a pedal action (D4). Persists across configure()
 * exactly like tempo_source: seeded once in le_engine_create, never reset by
 * configure — and untouched by clear-all. */

/* What le_engine_set_looper_mode would do with [mode] right now: one of
 * le_mode_gate (>= 0), or LE_ERR_INVALID for a bad handle/mode and
 * LE_ERR_NOT_RUNNING for an unconfigured engine. Selecting the current mode
 * is always LE_MODE_GATE_OPEN (a no-op). Ask before offering the choice: an
 * LE_MODE_GATE_PLAYING answer is what a "stop loops and switch"
 * confirmation stands for. */
LE_EXPORT int32_t le_engine_looper_mode_gate(le_engine* engine, int32_t mode);

/* Sets the looper mode (le_looper_mode, 0..4). Values outside the enum
 * return LE_ERR_INVALID without posting. Refused with LE_ERR_INVALID while
 * the gate above reads CAPTURING, QUEUED or SPANS; with PLAYING every
 * playing track is stopped in the same command after callback revalidation; a
 * no-op (LE_OK) for the current mode. Landing on the audio thread, a switch
 * over recorded audio re-clocks the takes for the target: the shared master
 * is established from the shortest take for MULTI or the primary for
 * SYNC/BAND (or goes dormant for SONG/FREE, whose tracks run their own clocks), and each take's multiple or division
 * is re-derived from its unchanged length. Content, layers, history, mutes
 * and lane settings are untouched. */
LE_EXPORT int32_t le_engine_set_looper_mode(le_engine* engine, int32_t mode);

/* Atomically switches mode and replaces every track's future length preset.
 * bars/count obey le_engine_set_track_length_presets. One queued command
 * rechecks the mode gate before stopping playback, switching mode or applying
 * any preset. A refused callback gate leaves all three unchanged; successful
 * enqueue alone is not proof of application. The current mode changes presets
 * only, without stopping playback. Existing PCM and history are untouched. */
LE_EXPORT int32_t le_engine_set_looper_mode_with_presets(
    le_engine* engine, int32_t mode, const int32_t* bars, int32_t count);

/* ---- primary track / Sync + Band (B3/B3b, decisions D16/D18) ----
 * Sync: one primary track; every other track's DEFINING recording is
 * auto-quantized (D16) to the nearest of {1/4, 1/2, 1, 2, 4} times the
 * primary's established length — a multiple (1/2/4) plays like today's
 * fixed-multiple tracks; a division (1/4, 1/2) plays a repeating slice of
 * ITS OWN (shorter) buffer, phase-locked to the primary's loop top. Band
 * layers the SAME primary/multiple-division machinery, plus non-primary
 * "section" tracks that start/stop independently — see
 * le_engine_toggle_section. Both are inert until a primary is crowned AND
 * that primary already has an established (single-base-loop) length; until
 * then Sync/Band's non-primary tracks record exactly like Multi (D16
 * fallback). */

/* Crowns [channel] the primary track — the explicit timing handoff (D18).
 * Rejects only an out-of-range channel; accepted in every looper mode (the
 * crown persists regardless of mode) though it only gates timing in
 * Sync/Band. There is no "un-crown" call: the engine crowns the first
 * completed take on its own and clears the crown when the session empties
 * (LE_CMD_CROWN_PRIMARY's doc). */
LE_EXPORT int32_t le_engine_crown_primary(le_engine* engine, int32_t channel);

/* Toggles Band section transport (D19 §2 Q3) on [channel]: a play/stop
 * press on a non-primary, content-bearing track in BAND mode, deferred
 * (quantized) to the next time the PRIMARY track returns to its loop top —
 * matching the manual's "quantized to the primary track" section semantics,
 * genuinely different from Sync (where non-primary tracks are locked to
 * always play, never independently started/stopped). A second call before
 * the boundary fires cancels the pending toggle (mirrors le_engine_record's
 * quantize-arm toggle shape). Returns LE_ERR_INVALID outside BAND mode, for
 * the primary track itself, or for a still-EMPTY track (nothing to
 * start/stop — a section reaches this only after its own defining,
 * sync-quantized recording has finalized). */
LE_EXPORT int32_t le_engine_toggle_section(le_engine* engine,
                                           int32_t channel);

/* ---- One Shot (B4, Sheeran manual §5.9.4; every mode since slice 2b) ----
 * "A track plays just once and then stops" — the manual's tool for a
 * non-looping section (an intro/outro, or a one-off sample bed), "particularly
 * useful for playing backing tracks". A per-track boolean, available in all
 * five looper modes (accepted design, Playback & overdub): the track plays
 * to the end of its own lap and stops itself, without stopping other tracks
 * or the shared clock. What "its own lap" means per mode:
 *   - Free/Song: one full turn of the track's OWN clock (le_loop_clock_tick's
 *     boundary return on free_clock; advance_track_clock_frame);
 *   - Multi/Sync/Band: the track's lap is a derived point on the ONE shared
 *     master clock — a k-multiple ends when the master wraps back to the
 *     track's first segment, a Sync/Band division every base/n frames, a
 *     plain 1x take at the master wrap (le_shared_clock_one_shots). A fresh
 *     take already set to Once plays a complete lap before stopping. An
 *     explicit launch after automatic end instead starts that track's audio
 *     at frame zero and plays exactly one pass, even while siblings play.
 *     Its playback origin changes; the shared musical capture clock does not.
 *     Recovery retains shared phase and does not perform this relaunch.
 * Enabling Once during a pass finishes that pass. A record or overdub
 * request queued for the lap end on a Once track wins over the stop: the
 * new pass runs, and Once ends the track at that pass's end. The stop reuses
 * handle_stop's exact PLAYING/OVERDUBBING -> STOPPED transition (pending
 * mutes land the same way a manual Stop press would; an overdub in flight
 * ends its capture and drains/retires normally) and logs a synthetic STOP.
 * A sibling's launch never automatically resumes an ended Once track. */

/* Sets track [channel]'s One Shot flag (0/1). Rejects only an out-of-range
 * channel; accepted and live in every looper mode (see the class doc
 * above). A SETTING, not content: like
 * a_length_preset_bars and target_multiple, it is untouched by clear /
 * undo-to-empty / mode switches — handle_clear's per-track reset
 * (engine_process.c) deliberately does not include it, the same "cleared
 * content starts fresh, configured PREFERENCES survive" split every other
 * per-track setting in this engine already follows. A cleared-then-re-
 * recorded one-shot track is one-shot again on its next take, with no need
 * to re-flag it. */
LE_EXPORT int32_t le_engine_set_one_shot(le_engine* engine, int32_t channel,
                                         int32_t enabled);

/* Updates all selected One Shot flags with one queued command. Bit c in
 * channels selects track c. A zero mask or any bit outside track_count is
 * invalid. A full command ring refuses the entire update without changing
 * any track; accepted updates land together before the next audio block.
 * Per-track default/override provenance remains the caller's responsibility. */
LE_EXPORT int32_t le_engine_set_one_shot_mask(le_engine* engine,
                                              uint32_t channels,
                                              int32_t enabled);

/* ---- MIDI clock (Phase C/E, decision D15) ----
 * The tri-state le_clock_mode (off / send / receive). This part (C1)
 * implements send: a native 24-PPQN emitter (src/midi/le_midi_clock.h) drives
 * 0xF8 clock ticks plus Start/Stop through the existing verbatim
 * le_midi_out_send transport, gated on the transport actually running
 * (recording/overdubbing/playing — manual-verified, not free-running while
 * idle) AND the looper mode being Multi/Sync/Band (Song/Free stay silent
 * regardless of this field). */

/* Sets the MIDI clock mode (le_clock_mode: 0 off, 1 send). RECEIVE (2) and
 * any value outside the enum return LE_ERR_INVALID without posting — receive
 * is Phase E's clock follower, not yet implemented; this setter stubs the
 * tri-state field now so that part can reuse it without a breaking rename. */
LE_EXPORT int32_t le_engine_set_clock_mode(le_engine* engine, int32_t mode);

/* ---- click + count-in (A2, decisions D5/D9) ----
 * The click is a synthesized voice (sine 1000 Hz on beats / 1500 Hz on the
 * bar downbeat, 30 ms linear decay) with its OWN output routing, volume and
 * pan, summed into its masked output channels BEFORE the output buses (slice
 * 3b): a destination's chain, level and mute process it, master gain, the
 * limiter and output metering apply, and a performance capture contains it
 * when it is routed to the captured bus. It is never perf-logged, so stems,
 * the offline master and bounces never contain it. It defaults to NO
 * outputs: nothing sounds until a mask is assigned. */

/* Enqueues one callback-confirmed click mode; capturing refuses, arms do not.
 * One request at a time. Confirm via commands_settled then snapshot receipt.
 * Raw LE_CMD_SET_CLICK_MODE posts are invalid. Sets mode (le_click_mode, 0..3).
 * Values outside the
 * enum return LE_ERR_INVALID. Default off. */
LE_EXPORT int32_t le_engine_set_click_mode(le_engine* engine, int32_t mode);

/* Routes the click to the output channels set in [mask] (bit c => hardware
 * output channel c; bits beyond the negotiated range are ignored). Default 0:
 * the click sounds on no outputs until explicitly routed. */
LE_EXPORT int32_t le_engine_set_click_output(le_engine* engine, int32_t mask);

/* Sets the click volume, clamped to 0..LE_MAX_GAIN (default 1.0). This is the
 * click's only gain stage — master gain and the limiter never touch it. */
LE_EXPORT int32_t le_engine_set_click_volume(le_engine* engine, float volume);

/* Sets the click pan, clamped to -1..1 (default 0). The click is mono; the
 * pan places it in the first masked pair with the unity-centre law of
 * le_engine_set_lane_pan (the near side stays at unity), and further masked
 * channels get the pair's mid, as every routed source does. Centre is
 * bit-identical to an unpanned click. A direct store: works while stopped,
 * persists across configure like the other click settings. NaN is refused. */
LE_EXPORT int32_t le_engine_set_click_pan(le_engine* engine, float pan);

/* ---- backing player (#1200) ----
 * One engine-owned stereo voice played from RAM, independent of the loops:
 * loop Stop, Undo, Clear and mode changes never touch it; Cut sound stops and
 * rewinds it at once. It sums into its masked output channels after the live
 * monitors and the click and BEFORE the output buses, exactly like the click:
 * output FX, level, Mono and mute process it; master gain, the limiter and
 * output metering see it; a performance capture contains it when it is routed
 * to the captured bus. It is never perf-logged, so stems, the offline master
 * and loop takes never contain it.
 *
 * Buffers: le_backing_buffer_from_pcm (and, later, a file decoder) create an
 * interleaved stereo float32 buffer at a given rate, owned by the caller. A
 * successful le_engine_backing_load / _stage_next transfers ownership to the
 * engine; on any refusal the caller still owns it. The engine frees buffers
 * only on the control thread: in le_engine_backing_state (the collect point),
 * before every load or stage, at configure, at reopen and at destroy, never
 * on the audio thread. At most LE_BACKING_MAX_BUFFERS buffers and
 * LE_BACKING_BUDGET_BYTES of PCM are engine-owned at once. A load or stage
 * past either bound reads LE_ERR_NOT_READY while a buffer is in transit (one
 * posted and not yet applied by the callback, or a replaced one still fading
 * out or waiting to be handed back: retry after one block), else
 * LE_ERR_CAPACITY.
 *
 * Handoff protocol. Only the audio thread changes which buffer is loaded or
 * staged: loads, stages and clears travel the command ring in posting order,
 * and an End = Next advance happens inside the callback, so no control-side
 * swap can race it. The callback hands a buffer it will never read again back
 * through one of LE_BACKING_MAX_BUFFERS return slots (release store); the
 * control thread exchanges the slot empty (acquire) before freeing. A return
 * slot always exists for every engine-owned buffer, so a return never fails;
 * should one ever find no free slot, the callback refuses the End = Next
 * advance (stops with LE_BACKING_EV_NEXT_MISSING) rather than lose or
 * overwrite a buffer.
 *
 * Declick: Pause, Stop, a seek while playing, a replace while playing and
 * Clear while playing fade the outgoing sound out over LE_BACKING_RAMP_MS on
 * a second, overlapping voice; a resume or a seek while playing fades the new
 * position in over the same time. A Play from the very start, an End =
 * Repeat wrap and an End = Next continuation are sample-exact and unfaded.
 *
 * Lifetimes: configure frees every buffer; a retained reopen keeps the loaded
 * and staged buffers and returns the transport to Stopped at 0; both bump
 * le_backing_state.epoch. The settings (output mask, level, pan, End) are
 * direct stores seeded once at create and persist across configure, like the
 * click settings. */
#define LE_BACKING_MAX_BUFFERS 4
/* 1.5 GiB: two 15-minute 96 kHz stereo buffers (691 MB each) plus headroom,
 * the backing's share of the appliance memory budget (#1200 plan, M1). */
#define LE_BACKING_BUDGET_BYTES (1536ll * 1024 * 1024)
#define LE_BACKING_RAMP_MS 5

typedef struct le_backing_buffer le_backing_buffer;

/* Copies [frames] interleaved frames of [channels] (1 or 2) at [sample_rate]
 * into a new stereo buffer (mono is duplicated into both sides). Any thread.
 * LE_ERR_INVALID on NULL, frames <= 0, channels outside 1..2, a
 * non-positive rate or any non-finite sample (a NaN or Inf would poison the
 * output-bus FX state for good); LE_ERR_CAPACITY when the allocation
 * fails. */
LE_EXPORT int32_t le_backing_buffer_from_pcm(const float* interleaved,
                                             int32_t frames, int32_t channels,
                                             int32_t sample_rate,
                                             le_backing_buffer** out);
LE_EXPORT int32_t le_backing_buffer_frames(const le_backing_buffer* buffer);
LE_EXPORT int32_t le_backing_buffer_rate(const le_backing_buffer* buffer);
/* Writes [buckets] per-bucket absolute peaks (max of both sides) over the
 * whole buffer into [out]; returns the count written, or LE_ERR_INVALID. */
LE_EXPORT int32_t le_backing_buffer_peaks(const le_backing_buffer* buffer,
                                          float* out, int32_t buckets);
/* ---- the audio-file decoder (#1200; the app's one decoder of audio
 * samples: the backing player, the Library preview and recording recovery
 * all read files here) --
 * Accepted, by our own header check before any decoder sees the file: WAV
 * (RIFF) with 16/24/32-bit PCM or 32-bit float, plain or EXTENSIBLE, and
 * MPEG Layer III. Sources must be mono or stereo, 8-192 kHz, at a rate the
 * converter reaches from every engine rate (44.1, 48, 88.2 and 96 kHz).
 * Everything else is LE_ERR_UNSUPPORTED: 8-bit or 64-bit WAV, ADPCM, mu-law,
 * A-law, RIFX, RF64, BW64, Wave64, AIFF, FLAC (compiled out until #1235),
 * Ogg, MPEG Layer I/II, more channels or another rate. A file that claims an
 * accepted format but is inconsistent (a chunk past the end of the file, a
 * short `fact` chunk, a block align that does not match, a length other than
 * the one stated, a float sample that is non-finite or more than 60 dB over
 * full scale) is LE_ERR_INVALID. No input can make these loop: reads and
 * seeks stay inside the file and stop after a bounded amount of work. Any
 * thread but the audio thread; no engine handle;
 * nothing here touches engine state. */

/* The longest whole file accepted, in seconds of source audio. */
#define LE_BACKING_MAX_SECONDS 900
/* What a decode must leave free (MemAvailable on Linux) for loops, capture
 * and the system: the appliance memory budget's floor (#1200 plan, M1). */
#define LE_MEM_RESERVE_BYTES (512ll * 1024 * 1024)

typedef struct le_backing_decode_info {
  int32_t source_rate;     /* the file's own rate */
  int32_t source_channels; /* 1 or 2 */
  int64_t source_frames;   /* frames decoded, at the source rate */
  int32_t truncated;       /* a bounded read stopped before the end */
} le_backing_decode_info;

/* Decodes [path] into a new stereo buffer at [sample_rate] (mono plays as
 * dual mono), converting the rate with the band-limited offline converter
 * after exact half-band halving for reductions below one half.
 *
 * Whole file (start_frame 0, max_frames 0): refused past
 * LE_BACKING_MAX_SECONDS (LE_ERR_TOO_LONG, before reading when the length is
 * stated), and refused as damaged when it decodes to a length other than the
 * one it states. Bounded read (a preview, a recording part): starts at the
 * first output frame at or after [start_frame] (source frames) and keeps at
 * most [max_frames] output frames, setting info->truncated when the file goes
 * on; its samples are exactly the whole-file decode's at the same positions.
 *
 * Refuses with LE_ERR_CAPACITY when the decode's peak (the source, the
 * planes a halving works on, and the output) would leave less than
 * LE_MEM_RESERVE_BYTES available, or an allocation fails. LE_ERR_UNSUPPORTED
 * and LE_ERR_INVALID as above; LE_ERR_INVALID also for bad arguments and a
 * missing or unreadable file. [info] (may be NULL) is filled as far as the
 * file was read. */
LE_EXPORT int32_t le_backing_decode_file(const char* path, int32_t sample_rate,
                                         int64_t start_frame,
                                         int32_t max_frames,
                                         le_backing_buffer** out,
                                         le_backing_decode_info* info);

/* Decodes all of [path] in small chunks, retaining no PCM, to prove it plays
 * and to measure it: fills [info] and [buckets] per-bucket absolute peaks
 * (max of both sides; buckets may be 0). The same refusals as a whole-file
 * decode, minus the memory one; a file it accepts decodes at every engine
 * rate. What an import runs before it keeps a file. */
LE_EXPORT int32_t le_backing_probe_file(const char* path,
                                        le_backing_decode_info* info,
                                        float* peaks, int32_t buckets);

/* The buffer's interleaved stereo float32 samples (frames x 2), for a
 * consumer that copies them (the Library preview). */
LE_EXPORT const float* le_backing_buffer_pcm(const le_backing_buffer* buffer);

/* Frees a buffer the caller still owns. NULL is a no-op. */
LE_EXPORT void le_backing_buffer_free(le_backing_buffer* buffer);

typedef enum le_backing_transport {
  LE_BACKING_STOPPED = 0,
  LE_BACKING_PLAYING = 1,
  LE_BACKING_PAUSED = 2,
} le_backing_transport;

typedef enum le_backing_transport_op {
  LE_BACKING_OP_PLAY = 0,  /* from the position; resume fades in */
  LE_BACKING_OP_PAUSE = 1, /* fade out, keep the position */
  LE_BACKING_OP_STOP = 2,  /* fade out, rewind to 0 */
} le_backing_transport_op;

typedef enum le_backing_end {
  LE_BACKING_END_STOP = 0,   /* stop and rewind (default) */
  LE_BACKING_END_REPEAT = 1, /* wrap to frame 0, no gap */
  LE_BACKING_END_NEXT = 2,   /* continue into the staged buffer, else stop */
} le_backing_end;

typedef enum le_backing_end_event {
  LE_BACKING_EV_NONE = 0,
  LE_BACKING_EV_STOPPED = 1,
  LE_BACKING_EV_REPEATED = 2,
  LE_BACKING_EV_ADVANCED = 3,
  LE_BACKING_EV_NEXT_MISSING = 4,
} le_backing_end_event;

/* Replaces the loaded buffer at the next block: the old one fades out if it
 * was sounding; the new one starts at frame 0, playing when [play] is 1,
 * else Stopped. [item] is the caller's token, reported back in the state.
 * LE_ERR_INVALID: NULL, a buffer the engine already owns, a rate other than
 * the engine's, or the command ring full. LE_ERR_NOT_RUNNING: not
 * configured. Past LE_BACKING_MAX_BUFFERS or LE_BACKING_BUDGET_BYTES:
 * LE_ERR_NOT_READY while a buffer is in transit, else LE_ERR_CAPACITY (see
 * Buffers above). */
LE_EXPORT int32_t le_engine_backing_load(le_engine* engine,
                                         le_backing_buffer* buffer,
                                         int32_t item, int32_t play);
/* Stages the buffer End = Next continues into (NULL clears the stage). Same
 * ownership and refusals as le_engine_backing_load. */
LE_EXPORT int32_t le_engine_backing_stage_next(le_engine* engine,
                                               le_backing_buffer* buffer,
                                               int32_t item);
/* Unloads the loaded and staged buffers (fading out a sounding one). */
LE_EXPORT int32_t le_engine_backing_clear(le_engine* engine);
/* le_backing_transport_op; a no-op with nothing loaded. */
LE_EXPORT int32_t le_engine_backing_transport(le_engine* engine, int32_t op);
/* Moves the loaded buffer's position to [frame], clamped to its length;
 * playing or paused is kept. A no-op with nothing loaded. */
LE_EXPORT int32_t le_engine_backing_seek(le_engine* engine, int32_t frame);
/* le_backing_end; LE_ERR_INVALID outside the enum. Direct store. */
LE_EXPORT int32_t le_engine_backing_set_end(le_engine* engine, int32_t mode);
/* Output channel bitmask (bit c = hardware output c), default 0 = unrouted.
 * Direct store. */
LE_EXPORT int32_t le_engine_backing_set_output(le_engine* engine,
                                               int32_t mask);
/* Gain, clamped to 0..LE_MAX_GAIN (default 1); NaN refused. Direct store. */
LE_EXPORT int32_t le_engine_backing_set_level(le_engine* engine, float gain);
/* Balance, clamped to -1..1 (default 0) with the unity-centre law; NaN
 * refused. Direct store. */
LE_EXPORT int32_t le_engine_backing_set_pan(le_engine* engine, float pan);

typedef struct le_backing_state {
  uint32_t epoch;      /* bumps at configure and at every reopen */
  int32_t item;        /* loaded buffer's token, -1 none */
  int32_t next_item;   /* staged buffer's token, -1 none */
  int32_t transport;   /* le_backing_transport */
  int32_t position;    /* frames into the loaded buffer */
  int32_t frames;      /* loaded buffer length, 0 none */
  uint32_t end_count;  /* bumps on every end-of-buffer handling */
  int32_t last_end;    /* le_backing_end_event of the latest one */
  int32_t end_mode;    /* le_backing_end */
  uint32_t mask;
  float level;
  float pan;
  float click_pan;
  int32_t owned;       /* buffers the engine owns after this collect */
  int64_t owned_bytes; /* their PCM bytes */
} le_backing_state;

/* Reads the published state (as of the last processed block) and frees every
 * buffer the audio thread has finished with. Control thread. LE_ERR_INVALID
 * on NULL arguments. */
LE_EXPORT int32_t le_engine_backing_state(le_engine* engine,
                                          le_backing_state* out);

/* Enqueues a coherent Count-in/Sound-start pair. Bars must be 0, 1, 2 or 4;
 * sound_start must be 0/1 and cannot be enabled with positive bars. Actual
 * capture refuses, including capture begun earlier in the same callback.
 * Count edits cancel a countdown; positive Count also cancels Sound arms.
 * Sound-on cancels countdowns, Sound-off cancels Sound arms. Restore cancels
 * both. One unpublished request is reserved; raw posts are invalid.
 * Acquire commands_settled BEFORE a synchronous snapshot read to classify its
 * new revision/result; no other mode writer may run between those calls. */
LE_EXPORT int32_t le_engine_set_record_start(le_engine* engine, int32_t bars,
    int32_t sound_start, int32_t edit_kind);

/* Fixes track [channel]'s loop length to [multiple] whole base loops (>= 1), or
 * 0 to inherit the global default (le_engine_set_default_multiple). Applies to
 * the next recording; existing content is unchanged. */
LE_EXPORT int32_t le_engine_set_track_multiple(le_engine* engine,
                                               int32_t channel,
                                               int32_t multiple);

/* Sets the global default loop length used by tracks that inherit (target 0):
 * [multiple] whole base loops (>= 1), or 0 to auto-round-up on stop. */
LE_EXPORT int32_t le_engine_set_default_multiple(le_engine* engine,
                                                 int32_t multiple);

/* ---- track length presets (A6, D17) ----
 * A per-track preset governing the DEFINING (first/master) recording only —
 * orthogonal to le_engine_set_track_multiple above, which fixes a
 * NON-defining track's length once a master already exists. Implements the
 * Sheeran manual's preset x click-mode matrix (song-mode-spec.md §1):
 *   - AUTO (0) + click off: tempo AND bar count are both derived from the
 *     recording (unchanged A1 sync_grid_to_loop path).
 *   - AUTO (0) + click on: bar count only is derived; an already-set tempo is
 *     never re-derived. With NO tempo set, this falls back to deriving both
 *     (the same as click off) — there is nothing else to preserve.
 *   - N bars + click off: the recording proceeds as an ordinary manual take;
 *     on finalize, tempo is derived from recorded-length / N — UNCONDITIONALLY,
 *     even over an existing manual/tapped tempo (the manual's explicit rule for
 *     this preset; distinct from AUTO's D7 "never re-derive" precedence).
 *   - N bars + click on: REQUIRES a tempo already set (source != none) at the
 *     moment recording begins, so frames-per-bar is computable — the defining
 *     recording then auto-finalizes into overdub at exactly N bars' worth of
 *     frames. An early record press before N bars disarms the preset (closes
 *     normally, like AUTO, per D17's general early-press rule). With NO tempo
 *     set at record start, auto-finalize cannot be armed (there is no way to
 *     know how many frames N bars is) — this degrades to the N-bars + click-off
 *     behavior: an ordinary manual take, tempo derived from length / N on
 *     finalize (documented A6 judgment call).
 * In every case the loop's AUDIO length is never altered — only tempo/bars are
 * set to describe it. Requires loop<->grid sync on (le_engine_set_sync_tempo);
 * with sync off the preset is dormant (matches a plain grid-off recording).
 * Preset changes on an already-recorded track are inert until the track is
 * cleared and re-recorded (stored, not retroactively applied). */

/* Sets track [channel]'s length preset: 0 = AUTO, or 1..
 * LE_LENGTH_PRESET_MAX_BARS to fix the defining recording to N bars (see the
 * matrix above). Returns LE_ERR_INVALID for a bad channel/bars, or
 * LE_ERR_CAPACITY when N bars of the CURRENT time signature at the slowest
 * possible tempo (30 BPM) would exceed the engine's max_loop_frames — checked
 * here, before recording starts, so a doomed preset is rejected outright
 * rather than silently failing mid-take. This is a best-effort check against
 * the signature live NOW: nothing locks the signature/tempo between setting
 * the preset and actually recording (no track has content yet, so D6's lock
 * does not apply), so a change in between can still make an N-bars+click-on
 * take's auto-finalize target unreachable. That case is re-guarded with the
 * ACTUAL live grid when recording starts (engine_process.c's
 * le_arm_length_preset_target) — an unreachable target is never armed, so
 * the take degrades cleanly to the click-off derive-from-length path at
 * finalize instead of silently stalling. */
LE_EXPORT int32_t le_engine_set_track_length_preset(le_engine* engine,
                                                     int32_t channel,
                                                     int32_t bars);

/* Replaces all configured tracks' future length presets in one command.
 * count must equal the configured track count and each bars entry must be
 * 0..LE_LENGTH_PRESET_MAX_BARS and pass the single-track capacity rule above.
 * The caller array is copied before return. Invalid/unconfigured/full-queue
 * requests change nothing. The callback rechecks all capacity constraints
 * before applying any entry; existing PCM and capture targets are unchanged. */
LE_EXPORT int32_t le_engine_set_track_length_presets(
    le_engine* engine, const int32_t* bars, int32_t count);

/* Sets the second-press "rec/dub" mode: when enabled, finalizing a recording
 * with a record press continues into overdub instead of playback. A stop press
 * always ends in playback/stopped. Independent of this setting, a track recorded
 * over an existing master that auto-finishes (reaches its loop length with no
 * press) always continues into overdub, so layering stays live rather than
 * auto-stopping to playback the moment the loop completes. */
LE_EXPORT int32_t le_engine_set_rec_dub(le_engine* engine, int32_t enabled);

/* Sets the global master output gain (clamped to 0..1), applied post-mix to the
 * final output after all tracks/lanes/monitors have summed in. Unity (1.0) by
 * default and after every fresh configure; published in le_snapshot.master_gain.
 */
LE_EXPORT int32_t le_engine_set_master_gain(le_engine* engine, float gain);

/* Arms the chromatic tuner on hardware input `input`, or disarms it with -1.
 *
 * The tuner taps the input BEFORE any lane or effect, which is what tuning
 * wants: the player is tuning the instrument, not the patch. It does not mute,
 * gate, or otherwise touch the signal — the console keeps playing while you
 * tune, and the face says so instead.
 *
 * Results ride the snapshot as `tuner_hz` / `tuner_confidence` /
 * `tuner_input`. Detection is gated on the arm, so disarming (or never arming)
 * costs nothing. */
LE_EXPORT int32_t le_engine_set_tuner_input(le_engine* engine, int32_t input);

/* Enables/disables the master peak limiter and sets its ceiling (clamped to
 * (0,1], default 0.99). The limiter is applied post master-gain so the summed
 * output of all tracks, overdub layers, and monitoring cannot exceed the ceiling
 * and hard-clip in the driver; below the ceiling it is bit-transparent. OFF by
 * default and after every fresh configure (the host app turns it on). */
LE_EXPORT int32_t le_engine_set_limiter(le_engine* engine, int32_t enabled,
                                        float ceiling);

/* Sets the overdub feedback coefficient (clamped to [0,1], default 1.0). While a
 * track is overdubbing, its existing content at the write head is scaled by this
 * before the new layer is summed in: 1.0 is the classic additive overdub (older
 * layers persist forever and can build toward clipping); below 1.0 decays older
 * layers each pass so the loop self-limits. Applies only during overdub passes,
 * never plain playback. */
LE_EXPORT int32_t le_engine_set_overdub_feedback(le_engine* engine,
                                                 float feedback);

/* Sets track [channel]'s overdub feedback override (accepted design, slice
 * 2b): a negative [feedback] inherits the global coefficient
 * (le_engine_set_overdub_feedback); otherwise the value is clamped to [0,1]
 * and used for this track's overdub passes. Live: a change during a pass
 * reaches the write head through a ~10 ms ramp, never a step, so the
 * retained layer has no level seam. Like the global coefficient, only
 * overdub passes apply it; playback never decays. */
LE_EXPORT int32_t le_engine_set_track_overdub_feedback(le_engine* engine,
                                                       int32_t channel,
                                                       float feedback);

/* Sets chain entry [index] (0..LE_FX_MAX-1) on lane [lane] of track [channel] to
 * [type]. Changing the type resets that entry's DSP state; LE_FX_DELAY lazily
 * allocates the entry's delay line (on this calling thread) and seeds the type's
 * default parameters. Every active entry colors playback in order. This sets
 * the entry's value only; use le_engine_set_lane_fx_count to make entries
 * active. */
LE_EXPORT int32_t le_engine_set_lane_fx(le_engine* engine, int32_t channel,
                                        int32_t lane, int32_t index,
                                        int32_t type);

/* Sets the active chain length on lane [lane] of track [channel] to [count]
 * (0..LE_FX_MAX): only entries [0, count) are processed, in order.
 *
 * [pre_count] (0..count, clamped) splits that order into the take's own
 * processing and what runs after its player. Entries [0, pre_count) are PRE:
 * the loop-stage cache renders exactly them from the lane's dry recording and
 * swaps the result in at a loop boundary, so they are heard as part of the
 * take and a track Stop takes their tails with it. Entries [pre_count, count)
 * are POST: they always run live over whichever source is playing, and their
 * tails drain past a Stop. The recording itself stays dry either way — the
 * print is a rendered copy, never a write back into the take.
 *
 * pre_count travels with count in one command so the audio thread never sees
 * a split naming more Pre entries than the chain has. 0 is the default and
 * means an all-Post chain. */
LE_EXPORT int32_t le_engine_set_lane_fx_count(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t count,
                                              int32_t pre_count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of chain entry [index] on lane
 * [lane] of track [channel] to [value] (clamped to 0..1). The parameter's
 * meaning depends on the entry's le_fx_type. */
LE_EXPORT int32_t le_engine_set_lane_fx_param(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t index,
                                              int32_t param, float value);

/* Enables/disables chain entry [index] on lane [lane] of track [channel]
 * without losing its type or parameters. Direct atomic publish (no ring
 * command), so it works whether or not the device is running. On the running
 * audio thread the transition is a click-free ~5 ms dry/wet crossfade with NO
 * tail spill on bypass: the disabled entry's wet output — tail included —
 * fades out over the ramp, then the entry renders bit-exact passthrough.
 * Re-enabling resets a built-in entry's DSP state, so stale tails never
 * sound (a hosted plugin keeps its own state and its tail resumes).
 * Entries default to enabled; an ACTUAL type change via le_engine_set_lane_fx
 * re-seeds the flag to 1 (a same-type re-set leaves it untouched), and a
 * slot entering the active window via le_engine_set_lane_fx_count starts
 * enabled. */
LE_EXPORT int32_t le_engine_set_lane_fx_enabled(le_engine* engine,
                                                int32_t channel, int32_t lane,
                                                int32_t index, int32_t enabled);

/* Enables/disables lane [lane] of track [channel]'s WHOLE effect chain in one
 * atomic flip, without touching the per-entry flags (re-enabling restores
 * them). Same contract as le_engine_set_lane_fx_enabled: direct atomic
 * publish, works while stopped, click-free ~5 ms ramp on the running audio
 * thread, no tail spill on bypass, built-in DSP state reset on re-enable.
 * Default enabled. */
LE_EXPORT int32_t le_engine_set_lane_fx_chain_enabled(le_engine* engine,
                                                      int32_t channel,
                                                      int32_t lane,
                                                      int32_t enabled);

/* ---- per-input live monitor ---- *
 * Each hardware input has a SINGLE live-monitor chain: input-level enable gates
 * the whole input, then the live signal runs through one effect chain / routing /
 * volume / mute. An empty chain is the clean (dry) path. The monitored signal is
 * NEVER recorded and is independent of all track state (record/play/overdub), so
 * an input can be monitored whether or not any track is using it. The chain you
 * monitor live is the chain that is snapshot-copied onto a track lane the moment
 * you record into that input (le_engine_record), so a take sounds like what you
 * heard; the copy is a deep copy taken on the control thread (never recorded into
 * the buffer — playback re-applies it), so later input-chain edits do not alter
 * earlier takes. */

/* Enables or disables live monitoring of hardware input [input]. When enabled,
 * the input routes per its own output mask; a loopback-excluded input is never
 * monitored regardless of [enabled]. */
LE_EXPORT int32_t le_engine_set_monitor_input(le_engine* engine, int32_t input,
                                              int32_t enabled);

/* Routes hardware input [input]'s monitor chain to the output channels set in
 * [mask] (bit c => output channel c). Bits beyond the output range are ignored. */
LE_EXPORT int32_t le_engine_set_monitor_input_output(le_engine* engine,
                                                     int32_t input, int32_t mask);

/* Sets hardware input [input]'s monitor output gain to [volume] (clamped to
 * 0..LE_MAX_GAIN, i.e. 2.0/+6.02 dB headroom above unity). The default is 1.0
 * (unity). */
LE_EXPORT int32_t le_engine_set_monitor_input_volume(le_engine* engine,
                                                     int32_t input, float volume);

/* Mutes or unmutes hardware input [input]'s monitor. */
LE_EXPORT int32_t le_engine_set_monitor_input_mute(le_engine* engine,
                                                   int32_t input, int32_t muted);

/* Sets hardware input [input]'s monitor pan, -1..1 (accepted design, slice
 * 3): the same unity-centre balance law as le_engine_set_lane_pan, applied
 * to the monitor's stereo pair after its chain and gain. */
LE_EXPORT int32_t le_engine_set_monitor_input_pan(le_engine* engine,
                                                  int32_t input, float pan);

/* Sets chain entry [index] (0..LE_FX_MAX-1) on hardware input [input]'s monitor
 * chain to [type]. Changing the type resets that entry's DSP state; LE_FX_DELAY
 * lazily allocates the entry's delay line (on this calling thread) and seeds the
 * type's default parameters. Use le_engine_set_monitor_input_fx_count to make
 * entries active. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx(le_engine* engine, int32_t input,
                                                 int32_t index, int32_t type);

/* Sets hardware input [input]'s monitor active chain length to [count]
 * (0..LE_FX_MAX): only entries [0, count) are processed, in order. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_count(le_engine* engine,
                                                       int32_t input,
                                                       int32_t count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of hardware input [input]'s monitor
 * chain entry [index] to [value] (clamped to 0..1). Its meaning depends on the
 * entry's le_fx_type. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_param(le_engine* engine,
                                                       int32_t input,
                                                       int32_t index,
                                                       int32_t param, float value);

/* Enables/disables hardware input [input]'s monitor chain entry [index] — the
 * monitor twin of le_engine_set_lane_fx_enabled, with the identical contract:
 * direct atomic publish (no ring, works while stopped), click-free ~5 ms
 * dry/wet crossfade on the running audio thread, no tail spill on bypass,
 * built-in DSP state reset on re-enable, default enabled, and an ACTUAL type
 * change via le_engine_set_monitor_input_fx re-seeds the flag to 1. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_enabled(le_engine* engine,
                                                         int32_t input,
                                                         int32_t index,
                                                         int32_t enabled);

/* Enables/disables hardware input [input]'s WHOLE monitor chain in one atomic
 * flip without touching the per-entry flags — the monitor twin of
 * le_engine_set_lane_fx_chain_enabled, same contract. Default enabled. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_chain_enabled(le_engine* engine,
                                                               int32_t input,
                                                               int32_t enabled);

/* ---- Per-input conditioning stage (input conditioning, S1) ---- *
 * One fixed, non-reorderable utility stage per hardware input, upstream of
 * BOTH the lane fan-out and the monitor split — see LE_CMD_SET_INPUT_COND's
 * doc for the full placement contract. Three sections, in processing order:
 *
 *   1. High-pass filter — 2nd-order Butterworth biquad. Kills DC / sub-sonic
 *      rumble before it stacks across overdub layers.
 *   2. Mains-hum notch bank — up to 8 fixed-Q (~30) notch biquads at integer
 *      multiples of the mains base frequency (50/100/150/200 Hz by default).
 *   3. Downward expander — abs -> one-pole envelope (fixed ~5 ms attack, no
 *      lookahead) -> polynomial under-threshold gain law: for ratio 1:R the
 *      settled output level below threshold is thr * (env/thr)^R (quadratic
 *      under threshold at the default 2.0), evaluated with integer powers +
 *      a linear blend for fractional ratios — no log/exp per sample. Stops
 *      idle noise floor accumulating in the recording across stacked lanes.
 *
 * Parameters are REAL UNITS (Hz / dB / ms), deliberately unlike the
 * normalized 0..1 le_fx_type params. Values are clamped by the audio thread
 * on apply (mirrors LE_CMD_SET_LENGTH_PRESET). */
typedef enum le_cond_param {
  LE_COND_HPF_HZ = 0,           /* high-pass cutoff Hz; 0 = section off.
                                 * Default 40. Clamped to 0..2000. */
  LE_COND_HUM_HZ = 1,           /* mains base Hz (50/60); 0 = section off.
                                 * Default 50. Clamped to 0..500. */
  LE_COND_HUM_HARMONICS = 2,    /* notches incl. base, 1..8. Default 4
                                 * (50/100/150/200 at the 50 Hz base). */
  LE_COND_EXP_THRESHOLD_DB = 3, /* downward expander threshold. Default -55.
                                 * Clamped to -120..0. */
  LE_COND_EXP_RATIO = 4,        /* 1:N downward. Default 2.0. Clamped to
                                 * 1..10; 1.0 = section off (unity). */
  LE_COND_EXP_RELEASE_MS = 5,   /* Default 150. Clamped to 1..5000. Attack
                                 * fixed ~5 ms; no lookahead. */
} le_cond_param;

/* Enables or disables the conditioning stage on hardware input [input]
 * (0..LE_MAX_MONITORED_INPUTS-1). Disabled by default — the untouched engine
 * is bit-identical to the conditioning-free build. An enable EDGE resets the
 * stage's filter/envelope state so a re-engaged stage never rings with stale
 * history. A loopback-excluded input's stage never runs regardless of this
 * flag (the latency harness owns those channels). */
LE_EXPORT int32_t le_engine_set_input_conditioning(le_engine* engine,
                                                   int32_t input,
                                                   int32_t enabled);

/* Sets conditioning parameter [param] (le_cond_param) of hardware input
 * [input] to [value] in that parameter's REAL unit (Hz / dB / ms / ratio —
 * see le_cond_param). The audio thread clamps on apply and recomputes the
 * affected section's coefficients in lockstep (resetting only that section's
 * filter state, so a live tweak never rings with coefficients it was not
 * filtered by). */
LE_EXPORT int32_t le_engine_set_input_conditioning_param(le_engine* engine,
                                                         int32_t input,
                                                         int32_t param,
                                                         float value);

/* ---- Offline loop-close restoration (input conditioning, S9) ---- *
 * The restoration counterpart to the live conditioning stage above: after a
 * loop closes, a background worker repairs the CAPTURED lanes — de-clip
 * (reconstruct the peaks a converter flattened) then optional RNNoise denoise
 * — and publishes the result as one lockstep undo layer, so a plain
 * le_engine_undo reverts to the raw take. It runs entirely off the RT audio
 * thread (a copy-at-enqueue worker mirroring the wet cache), so it never adds
 * playback latency, and it is opt-in per input via the flags below. Policy
 * lives in the app: the engine only restores what it is asked to, when it is
 * asked. Progress surfaces through le_track_snapshot.restore_state. */
typedef enum le_restore_flags {
  LE_RESTORE_DECLIP = 1,  /* de-clip pass (restore_declip.c), at the full rate */
  LE_RESTORE_DENOISE = 2, /* RNNoise denoise — passthrough at 48 kHz, a 2:1
                           * half-band resample at 96 kHz, skipped at other
                           * rates (de-clip still runs). */
} le_restore_flags;

/* Queues an offline restoration pass over track [channel]'s captured lanes
 * (control thread). [lane_mask] selects which lanes to repair (bit l = lane l,
 * restricted to the track's active lanes); [flags] is a bitwise-OR of
 * le_restore_flags. The pass runs on a background worker and publishes its
 * result as one undo layer once complete — never touching the RT audio
 * thread's latency. Returns LE_OK once the job is queued, or LE_ERR_INVALID
 * for a null/out-of-range handle, empty flags or lane mask, a track that is
 * RECORDING/OVERDUBBING or has an overdub layer in flight, a track with no
 * captured content, or a restoration already in flight (one job engine-wide).
 * A queued pass whose take moves before it commits (a new overdub, an undo)
 * is discarded, never published. */
LE_EXPORT int32_t le_engine_restore_track(le_engine* engine, int32_t channel,
                                          uint32_t lane_mask, uint32_t flags);

/* Cancels an in-flight restoration on track [channel] (control thread): a job
 * still copying is dropped immediately; one already on the worker aborts at
 * its next lane boundary and its result is discarded rather than published.
 * Returns LE_OK when a matching job was found and signalled, or LE_ERR_INVALID
 * for a null/out-of-range handle or when no restoration for [channel] is in
 * flight. */
LE_EXPORT int32_t le_engine_cancel_restore(le_engine* engine, int32_t channel);

/* ---- Track-stage (per-track stereo bus) chain (FX v3 part 1b) ---- *
 * Each track owns ONE Track-stage chain, downstream of its per-lane chains.
 * While the chain is EMPTY (count 0 — the default and the state every
 * existing session loads into) the engine's per-lane routing is bit-identical
 * to the chain never having existed. When non-empty, the track's audible
 * lanes sum into one stereo pair, the chain runs once per frame on it, and
 * the wet result routes via the UNION of those lanes' enabled output masks —
 * a documented behavior change that only occurs when track FX are added to a
 * divergent-mask configuration. Topology keys off emptiness, not enabled: a
 * non-empty but disabled chain keeps the bus topology (the part-1a bypass
 * makes it dry), so an enable stomp toggles DSP, never routing. The chain
 * ticks every frame it is non-empty (delay tails / LFO phase stay continuous
 * over silence) and routes only while some lane is audible.
 *
 * Track/Master chains sit post-capture: they do not affect record alignment,
 * so fx_added_latency_frames (monitored-path record alignment) is unchanged
 * by anything set here. */

/* Sets Track-stage chain entry [index] (0..LE_FX_MAX-1) of track [channel] to
 * [type]. Changing the type resets that entry's DSP state; delay-lined types
 * lazily allocate their buffers on this calling thread and seed the type's
 * default parameters. Use le_engine_set_track_fx_count to make entries
 * active. */
LE_EXPORT int32_t le_engine_set_track_fx(le_engine* engine, int32_t channel,
                                         int32_t index, int32_t type);

/* Sets track [channel]'s Track-stage active chain length to [count]
 * (0..LE_FX_MAX): only entries [0, count) are processed, in order. Count 0
 * (empty) restores the bit-identical per-lane routing path.
 *
 * [pre_count] (0..count, clamped) splits that order the way a lane's does.
 * Entries [0, pre_count) are PRE: the engine renders them over the COMBINED
 * material of the track's parts — each part's dry recording through that
 * part's own chain, at its level, pan and mute, summed — and swaps the result
 * in at the track's loop top, so they are heard as part of the take. Entries
 * [pre_count, count) are POST: always live over whatever is playing, and
 * their tails drain past a Stop. The recordings themselves stay dry; the
 * render is a copy, and every part, overdub layer and undo step survives it.
 *
 * A part's Post entries keep their live tails. A track with part Post or
 * hosted part plugins therefore runs its Pre chain live instead of printing
 * that upstream processing; the cache telemetry reports the obstruction. */
LE_EXPORT int32_t le_engine_set_track_fx_count(le_engine* engine,
                                               int32_t channel, int32_t count,
                                               int32_t pre_count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of track [channel]'s Track-stage
 * chain entry [index] to [value] (clamped to 0..1). Direct atomic publish —
 * works whether or not the device is running. */
LE_EXPORT int32_t le_engine_set_track_fx_param(le_engine* engine,
                                               int32_t channel, int32_t index,
                                               int32_t param, float value);

/* Enables/disables track [channel]'s Track-stage chain entry [index] — the
 * bus twin of le_engine_set_lane_fx_enabled, identical contract: direct
 * atomic publish (no ring, works while stopped), click-free ~5 ms dry/wet
 * crossfade on the running audio thread, no tail spill on bypass, built-in
 * DSP state reset on re-enable, default enabled, and an ACTUAL type change
 * via le_engine_set_track_fx re-seeds the flag to 1. Never changes routing
 * topology (see the section doc above). */
LE_EXPORT int32_t le_engine_set_track_fx_enabled(le_engine* engine,
                                                 int32_t channel, int32_t index,
                                                 int32_t enabled);

/* Enables/disables track [channel]'s WHOLE Track-stage chain in one atomic
 * flip without touching the per-entry flags — the bus twin of
 * le_engine_set_lane_fx_chain_enabled, same contract. Default enabled.
 * Disabling yields dry-through-the-bus, NOT a return to per-lane routing —
 * only emptying the chain does that. */
LE_EXPORT int32_t le_engine_set_track_fx_chain_enabled(le_engine* engine,
                                                       int32_t channel,
                                                       int32_t enabled);

/* ---- output buses (accepted design, slice 3b) ----
 * Bus [bus] is the hardware pair (2 bus, 2 bus + 1). After every source has
 * summed onto the outputs (tracks, monitors, the click), each bus runs its
 * chain over its pair, then applies its level (0..1, default 1), Mono (the
 * pair averaged onto both channels; balance then disabled), balance (-1..1,
 * the unity-centre law of le_engine_set_lane_pan: it attenuates one side)
 * and mute (silence; the level is kept). The global master gain and limiter
 * follow. A bus a source is not routed to is untouched by that source.
 * Bus 0's chain is what the app calls the Master insert. All remembered by
 * the caller and reset by (re)configure. */
LE_EXPORT int32_t le_engine_set_output_level(le_engine* engine, int32_t bus,
                                             float level);
LE_EXPORT int32_t le_engine_set_output_mute(le_engine* engine, int32_t bus,
                                            int32_t muted);
LE_EXPORT int32_t le_engine_set_output_mono(le_engine* engine, int32_t bus,
                                            int32_t mono);
LE_EXPORT int32_t le_engine_set_output_balance(le_engine* engine, int32_t bus,
                                               float balance);
/* Bus [bus]'s chain, the bus twin of the Track-stage family: the type
 * change resets that entry's DSP state, buffers allocate on this calling
 * thread, defaults are seeded on an actual change; count clamps to
 * 0..LE_FX_MAX; params and the enable flags are direct stores that work
 * while stopped. While a chain is EMPTY its bus passes bit-identical. FX
 * kernels are strict stereo; a single-channel last bus processes l == r.
 * Post-capture: leaves fx_added_latency_frames untouched. */
LE_EXPORT int32_t le_engine_get_output_fx_snapshot(le_engine* engine,
    int32_t bus, le_output_fx_snapshot* out);
LE_EXPORT int32_t le_engine_set_output_fx(le_engine* engine, int32_t bus,
                                          int32_t index, int32_t type);
LE_EXPORT int32_t le_engine_set_output_fx_count(le_engine* engine, int32_t bus,
                                                int32_t count);
LE_EXPORT int32_t le_engine_set_output_fx_param(le_engine* engine, int32_t bus,
                                                int32_t index, int32_t param,
                                                float value);
LE_EXPORT int32_t le_engine_set_output_fx_enabled(le_engine* engine,
                                                  int32_t bus, int32_t index,
                                                  int32_t enabled);
LE_EXPORT int32_t le_engine_set_output_fx_chain_enabled(le_engine* engine,
                                                        int32_t bus,
                                                        int32_t enabled);

/* Cut all sound (accepted design, slice 3b): see LE_CMD_CUT_SOUND. Posted
 * through the ring; returns LE_ERR_NOT_RUNNING while stopped (nothing
 * sounds then). Every built-in chain's state AND its delay rings clear in
 * the one callback that applies the command, unlike a chain stomp's spaced
 * re-enable clears: deferring a slot means passing it dry, and dry is the
 * wrong output for a fully wet effect. The cost is therefore proportional
 * to the rings actually allocated (one is sample_rate floats per channel),
 * paid once on a deliberate press. A hosted plugin has no reset seam, so
 * its own tail is not cut. */
LE_EXPORT int32_t le_engine_cut_sound(le_engine* engine);

/* Whether capture applies the selected output bus's level and mute (1),
 * or taps after its chain before those controls (0,
 * the default: adjusting the PA during a performance does not alter the
 * saved performance; accepted design, "Follow output volume"). A direct
 * store, frozen into the take at le_perf_arm, so a running take keeps the
 * policy it was armed with; le_snapshot.perf_follow_output publishes the
 * armed take's policy, or the pending one while disarmed. This is a
 * PREFERENCE, not device state: unlike the mix settings it is NOT reset by
 * (re)configure, so a device change or reconnect leaves it as the player
 * set it. */
LE_EXPORT int32_t le_perf_set_follow_output(le_engine* engine, int32_t follow);

/* ---- Loop-stage wet cache (FX v3 part 2) ---- *
 * A background worker renders a stable lane chain's whole loop offline; the
 * audio thread plays the cached stereo result at zero FX CPU and falls back
 * to live processing the same buffer on ANY key change (param edit, enable
 * flip, volume move, content revision bump). The cache is invisible in the
 * signal contract — "when in doubt, play live" — and this surface is
 * log/test-only in v3 (the lane-card debug glyph is a later part [R27]). */

/* Default wet-cache memory budget in bytes (appliance-tuned: ~5 stereo 30 s
 * entries at 48 kHz). Seeded once in le_engine_create; persists across
 * configure like the tempo/click settings. */
#define LE_CACHE_DEFAULT_CAP_BYTES (64ll * 1024 * 1024)

/* Per-lane cache telemetry states (le_lane_cache_info.state). */
typedef enum le_cache_state {
  LE_CACHE_LIVE = 0,            /* no valid entry; playing live */
  LE_CACHE_RENDERING = 1,       /* a render for the current key is in flight */
  LE_CACHE_CACHED = 2,          /* a published entry matches the current key */
  LE_CACHE_FAILED_RETRYING = 3, /* last render failed (e.g. OOM); will retry */
  LE_CACHE_GAVE_UP = 4,         /* permanently live; see `reason` */
} le_cache_state;

/* Why a lane's cache gave up (le_lane_cache_info.reason; NONE otherwise). */
typedef enum le_cache_reason {
  LE_CACHE_REASON_NONE = 0,
  LE_CACHE_REASON_PLUGIN = 1, /* chain hosts a plugin slot: an offline render
                               * would pass it dry, so the lane stays live */
  LE_CACHE_REASON_RENDER_FAILED = 2, /* repeated render failures */
  LE_CACHE_REASON_PART_POST = 3, /* a part Post chain must keep live tails */
} le_cache_reason;

/* Snapshot of one lane's cache state (le_engine_get_lane_cache). */
typedef struct le_lane_cache_info {
  int32_t state;      /* le_cache_state */
  int32_t reason;     /* le_cache_reason (meaningful when state == GAVE_UP) */
  int32_t engaged;    /* 1 while the audio thread is playing cached (racy
                       * telemetry read of an audio-thread-local flag) */
  int32_t entry_frames; /* published entry length in frames (0 = none) */
  int32_t renders;    /* completed renders for this lane (cache-hot asserts) */
  uint32_t audio_rev; /* the track's current content revision [R1] */
} le_lane_cache_info;

/* Fills [out] with lane [lane] of track [channel]'s cache telemetry. Control
 * thread; also drains events / runs a scheduler tick first, so polling this is
 * enough to drive the cache forward in a device-free test. */
/* The whole-track Pre print's telemetry (slice 3e): the lane query's twin,
 * one per track. `reason` is where the engine says WHY a track's Pre run is
 * running live rather than printed — a part carrying a Post entry (the print
 * would have to bake it, and a baked tail cannot drain past a Stop), a hosted
 * plugin, a budget that does not fit, a render that failed. Log/test-only in
 * v3, like the lane query. */
LE_EXPORT int32_t le_engine_get_track_cache(le_engine* engine, int32_t channel,
                                            le_lane_cache_info* out);

LE_EXPORT int32_t le_engine_get_lane_cache(le_engine* engine, int32_t channel,
                                           int32_t lane,
                                           le_lane_cache_info* out);

/* Fills out[channel * LE_MAX_LANES + lane] for EVERY lane of every active
 * track behind a single drain + scheduler tick — the batch form of
 * le_engine_get_lane_cache for a poller that wants all lanes at once. The
 * per-lane accessor costs a full drain per call, so an 8-track poll through it
 * runs 16-32 control-thread sweeps per tick; this runs exactly one (#418).
 * [capacity] is the number of le_lane_cache_info slots at [out] and must be at
 * least track_count * LE_MAX_LANES (LE_MAX_TRACKS * LE_MAX_LANES always
 * suffices). Returns the number of slots filled, or LE_ERR_INVALID. Control
 * thread. */
LE_EXPORT int32_t le_engine_get_all_lane_caches(le_engine* engine,
                                                le_lane_cache_info* out,
                                                int32_t capacity);

/* Sets the wet-cache memory budget in BYTES (stereo entries at 2x frames,
 * toggled pairs, and in-flight enqueue copies all count against it). 0
 * disables caching and frees every entry (every lane plays live); negative is
 * clamped to 0. Direct store + an immediate eviction pass on the control
 * thread — no ring command (no heap pointer crosses to the audio thread
 * here; entries publish through their own atomic seam). The default is
 * appliance-tuned (LE_CACHE_DEFAULT_CAP_BYTES, 64 MiB). */
/* ---- the All tracks recorded-mix chain (slice 3e) ----
 *
 * The accepted design's third FX destination, beside the live inputs and the
 * per-track chains: "the single shared chain applied after the loop tracks are
 * combined". It is NOT the output bus — an output chain processes every source
 * routed to it (live monitoring, the click, backing), where this one processes
 * the recorded tracks alone, and runs before those other sources join.
 *
 * Its entries are always Post: the stage has no dry original of its own,
 * because it processes a sum computed live from lanes that each own their own
 * recording. There is no Pre count here.
 *
 * ONE config, N instances. Since slice 3b every source picks its own output
 * destinations, so the combined recorded mix is a per-destination quantity —
 * a track on Main and a track on Monitor are two different mixes. The chain
 * runs once per output bus, over the recorded contribution to that bus, on
 * that bus's own filter memory. Setting a type prepares every bus of the
 * configured device; le_engine_configure re-prepares them.
 *
 * An EMPTY chain (the default) leaves the per-track routing path bit-identical
 * to the pre-slice-3e engine — topology keys off emptiness, exactly like the
 * track bus. */
LE_EXPORT int32_t le_engine_set_all_tracks_fx(le_engine* engine, int32_t index,
                                              int32_t type);
LE_EXPORT int32_t le_engine_set_all_tracks_fx_count(le_engine* engine,
                                                    int32_t count);
LE_EXPORT int32_t le_engine_set_all_tracks_fx_param(le_engine* engine,
                                                    int32_t index,
                                                    int32_t param, float value);
LE_EXPORT int32_t le_engine_set_all_tracks_fx_enabled(le_engine* engine,
                                                      int32_t index,
                                                      int32_t enabled);
LE_EXPORT int32_t le_engine_set_all_tracks_fx_chain_enabled(le_engine* engine,
                                                            int32_t enabled);

/* ---- per-entry channel handling and level (slice 3e) ----
 *
 * The accepted design puts an input choice, an output choice and a level
 * around each instance in a chain: the input choice before its effects, the
 * output choice and then the level after them.
 *
 *   in_mode   0 Stereo (default, left and right as they arrive)
 *             1 Left only   — the incoming left on both sides
 *             2 Right only  — the incoming right on both sides
 *             3 Mono sum    — their average on both sides
 *   out_mode  0 Stereo (default) — keeps what the effects made; [placement]
 *                                  is a BALANCE over the two sides
 *             1 Mono            — averages them; [placement] is a PAN
 *   placement -1..1, centre 0 (default). One unity-centre law, the same the
 *             lanes, monitors and output buses use, so centre is exactly
 *             unity and a hard side is exactly silent.
 *   level     0..LE_MAX_GAIN, unity 1 (default). Applied last.
 *
 * Set as one call, because the four values are one control surface and a
 * half-applied change would be audible. Direct atomic publishes: they change
 * gain within an entry, never its DSP state, so nothing resets and there is
 * no ring command to order against. An entry left at its defaults is
 * bit-identical to one with no channel handling at all.
 *
 * A BYPASSED entry passes the signal through exactly as it arrived — the
 * choices belong to the entry, so they leave with it. */
LE_EXPORT int32_t le_engine_set_lane_fx_channels(le_engine* engine,
                                                 int32_t channel, int32_t lane,
                                                 int32_t index,
                                                 int32_t in_mode,
                                                 int32_t out_mode,
                                                 float placement, float level);
LE_EXPORT int32_t le_engine_set_monitor_input_fx_channels(
    le_engine* engine, int32_t input, int32_t index, int32_t in_mode,
    int32_t out_mode, float placement, float level);
LE_EXPORT int32_t le_engine_set_track_fx_channels(le_engine* engine,
                                                  int32_t channel,
                                                  int32_t index,
                                                  int32_t in_mode,
                                                  int32_t out_mode,
                                                  float placement, float level);
LE_EXPORT int32_t le_engine_set_output_fx_channels(le_engine* engine,
                                                   int32_t bus, int32_t index,
                                                   int32_t in_mode,
                                                   int32_t out_mode,
                                                   float placement,
                                                   float level);
LE_EXPORT int32_t le_engine_set_all_tracks_fx_channels(
    le_engine* engine, int32_t index, int32_t in_mode, int32_t out_mode,
    float placement, float level);

LE_EXPORT int32_t le_engine_set_fx_cache_cap(le_engine* engine, int64_t bytes);

/* Current wet-cache memory accounting in bytes (entries + in-flight copies).
 * Log/test-only telemetry. */
LE_EXPORT int64_t le_engine_fx_cache_used_bytes(le_engine* engine);

/* Track [channel]'s current content revision (a_audio_rev [R1]) — exposed so
 * the bump-site audit tests can assert every content mutation bumps. Returns
 * 0 for an out-of-range channel. */
LE_EXPORT uint32_t le_engine_track_audio_rev(le_engine* engine,
                                             int32_t channel);

/* ---- structural output gate ---- *
 * Turns hardware output [output] on/off as a routing target. A disabled output is
 * skipped in the mix fan-out regardless of any lane/monitor mask pointing at it,
 * while the stored masks are left untouched (re-enabling restores them). This is
 * distinct from a level mute: it changes the routing graph, not a gain. RT-safe
 * (applies mid-record without artifacts). A gate state for an output beyond the
 * device's channel count is stored but never affects audio. All outputs are
 * enabled by default and on every fresh configure. */
LE_EXPORT int32_t le_engine_set_output_enabled(le_engine* engine, int32_t output,
                                               int32_t enabled);

/* ---- performance recording (RT capture taps + capture-to-disk; parts 1-2 of
 * the DAW-export stack) ---- *
 * While armed, the audio thread copies two kinds of streams into pre-published
 * lock-free rings: the post-limiter master output (stereo from the first
 * enabled output pair; mono when the device has only one), and each hardware
 * input actively monitored AT ARM (post-monitor-FX, pre-route; frozen for the
 * whole arm session — an input enabled later is not retroactively captured).
 * Rings are allocated control-side at arm (>= 2 s of audio at the device rate)
 * and published to the audio thread with LE_CMD_PERF_ARM; on overflow the
 * audio thread drops the frame and increments the overrun atomic — it never
 * blocks or allocates. Status (armed / frames / overruns) is exposed only via
 * le_snapshot; there is no separate query call.
 *
 * A dedicated background drain thread (perf_drain.h; spawned by le_perf_arm,
 * joined by le_perf_disarm) empties those rings into raw PCM temp files plus a
 * `performance.json` sidecar under the capture directory, flushed every
 * ~250 ms. WAV headers are written only at finalize (a later part): a crash
 * mid-capture leaves salvageable raw PCM + a parseable sidecar, never a
 * truncated WAV. */

/* Arms performance-recording capture: allocates the master + per-monitor
 * rings, freezes the captured input set from whichever inputs are currently
 * monitored, publishes them to the audio thread, and starts the drain thread
 * writing into `capture_dir` (created if it does not already exist).
 * Idempotent (a second call while already armed is a no-op success — the
 * armed session's original `capture_dir` keeps draining; the repeat call's
 * `capture_dir` argument is still required to be non-null/non-empty but is
 * otherwise unused). Returns LE_OK, LE_ERR_NOT_RUNNING (not configured),
 * LE_ERR_INVALID (null/empty `capture_dir`, no output enabled to capture, or
 * ring allocation failure), or LE_ERR_DEVICE (the drain thread could not be
 * started — e.g. the directory could not be created — or a previous disarm's
 * quiescent wait bailed out and left a stale drain session still live). */
LE_EXPORT int32_t le_perf_arm(le_engine* engine, const char* capture_dir);

/* Disarms performance-recording capture: tells the audio thread to stop
 * writing, waits for a published-quiescent handshake to confirm it has (so
 * there is never a use-after-free or an audio-thread free) — mirroring the
 * plugin-slot teardown handshake — then stops and joins the drain thread
 * (which runs one final drain-and-flush pass) before freeing the rings.
 * Idempotent (a second call while already disarmed is a no-op success).
 * Returns LE_OK, or LE_ERR_DEVICE if the callback could not be confirmed
 * quiescent (a stalled device; the rings and drain thread are left
 * retracted-but-running and are reclaimed by a later retry or at
 * le_engine_destroy). */
LE_EXPORT int32_t le_perf_disarm(le_engine* engine);

/* Total and available bytes of the volume holding `path`, into
 * `*out_total_bytes` and `*out_free_bytes`. Returns LE_OK, LE_ERR_INVALID
 * (null/empty `path` or a null output), or LE_ERR_DEVICE if the platform
 * refused to answer (a path that does not exist, a filesystem that cannot
 * report). Both outputs are zeroed on failure so a stale read cannot leak.
 * Engine-free: it is a question about a directory, not about a running
 * capture, so it is also the check made BEFORE arming one, and the figure the
 * Storage page draws for Internal and for each removable volume (#1177).
 *
 * It is here rather than in the caller because the caller is Dart, which has no
 * free-space API at all — and the shell-out that filled that gap turned out to
 * be the most expensive thing on the appliance's real-time path. `Process.run`
 * is fork() + exec(), fork() holds mmap_lock for write for milliseconds while it
 * copies a 1.7 GB address space's page tables, and under PREEMPT_RT the audio
 * thread's next page fault sleeps behind it. A capture re-checked its volume
 * every 4.75 s, so a take forked the whole app twelve times a minute; every
 * audible dropout measured on the Pi 5 bench landed within 3 ms of one (#806).
 *
 * Answering it in C also keeps the struct layout in C. `statvfs` is shaped
 * differently on glibc and on macOS, and a Dart-side layout guess would not
 * fail loudly — it would report a plausible wrong number and stop a take that
 * had room.
 *
 * ALL THREE PLATFORMS ANSWER, which is a deliberate widening: the `df` this
 * replaced returned "cannot answer" on Windows, so the free-space floor (#640)
 * has never applied there. It does now. That is the behaviour the floor was
 * written for, but it is a change on a platform the click work did not
 * otherwise touch, so it is stated here rather than left to be discovered. */
LE_EXPORT int32_t le_volume_space(const char* path, uint64_t* out_total_bytes,
                                  uint64_t* out_free_bytes);

/* fsync(2) on the directory at `path`, so the entries in it — a file renamed
 * into it, a file created in it — survive a power cut or a pulled drive. A
 * file's own fsync makes its bytes durable but not its name: on ext4 a copy
 * that returned within the commit interval could otherwise come back after a
 * power cut as a part file with no final name (#1177, #1195). Dart has no way
 * to open a directory, so the storage repository asks here.
 *
 * LE_ERR_INVALID on a NULL or empty path; LE_ERR_DEVICE when the path cannot
 * be opened as a directory or the sync fails. LE_OK on Windows without doing
 * anything: NTFS journals its directory entries. Control thread only; it can
 * take as long as the device's flush. */
LE_EXPORT int32_t le_sync_dir(const char* path);

/* ---- recorded-audio identity and durable publication (#1198) ----
 * Engine-free, like le_volume_space: questions about bytes and paths, safe to
 * call from any thread and from a Dart background isolate with no engine.
 *
 * Recorded audio is identified by the SHA-256 of its sample payload, so an
 * intact copy is recognised wherever it is and whatever it is called, and a
 * damaged or different file never passes for it (accepted behaviour 6.10:
 * "same name is not enough"). `out` receives the 32-byte digest. */

/* SHA-256 of `length` bytes at `data` (`data` may be NULL only when `length`
 * is 0). Returns LE_OK, or LE_ERR_INVALID for a NULL `out`, a NULL `data`
 * with a non-zero length, or a length this platform cannot address. */
LE_EXPORT int32_t le_digest_bytes(const void* data, uint64_t length,
                                  uint8_t* out);

/* SHA-256 of `length` bytes of the regular file at `path` (UTF-8) starting at
 * byte `offset`; `length` = UINT64_MAX means through the end of the file.
 * Reads in 64 KiB chunks, so a multi-gigabyte recording costs no memory.
 * Returns LE_OK; LE_ERR_INVALID for a NULL or empty `path` or NULL `out`;
 * LE_ERR_NOT_FOUND when nothing exists at `path`; LE_ERR_TRUNCATED when the
 * file is shorter than `offset` + `length` (a damaged file never yields a
 * digest of what happens to be left); LE_ERR_DEVICE when it cannot be opened
 * for another reason, is not a regular file, or a read fails. The codes tell
 * a missing recording from a damaged one without a separate stat that the
 * file could change under. */
LE_EXPORT int32_t le_digest_file(const char* path, uint64_t offset,
                                 uint64_t length, uint8_t* out);

/* Incremental SHA-256 over memory the caller feeds in pieces, so a large
 * buffer in another language's heap is hashed through a small native window
 * instead of being copied whole. `state` is caller-owned, at least
 * LE_DIGEST_STATE_BYTES long and 8-byte aligned; begin initialises it,
 * update adds `length` bytes, end writes the 32-byte digest to `out` (the
 * state must be begun again before reuse). Each returns LE_OK, or
 * LE_ERR_INVALID for a NULL state or out, a `state_bytes` below
 * LE_DIGEST_STATE_BYTES, NULL `data` with a non-zero length, or a length this
 * platform cannot address. */
/* Keep this a plain number: ffigen only exports a macro that is a literal,
 * and the Dart side sizes its state buffer from the generated constant. */
#define LE_DIGEST_STATE_BYTES 128
LE_EXPORT int32_t le_digest_begin(void* state, uint64_t state_bytes);
LE_EXPORT int32_t le_digest_update(void* state, const void* data,
                                   uint64_t length);
LE_EXPORT int32_t le_digest_end(void* state, uint8_t* out);

/* Makes the directory entries of `path` durable: open + fsync on POSIX, which
 * is what makes a rename into that directory survive a power cut (fsync on
 * the renamed file does not cover its name). Dart cannot open a directory, so
 * the atomic publication of a bundle (tmp, fsync, rename, then this) needs it
 * here. On Windows there is no directory handle to flush; it reports only
 * whether the directory exists. Returns LE_OK; LE_ERR_INVALID for a NULL or
 * empty `path`; LE_ERR_DEVICE when the directory cannot be opened or the sync
 * fails. */
LE_EXPORT int32_t le_fs_sync_dir(const char* path);

/* ---- offline performance renderer (parts 7-8 of the DAW-export stack) ----
 * Reconstructs, from a FINALIZED capture directory (part 6's
 * `performance.json` + `events.log` + `loops/` + retired-layer PCM), on a
 * dedicated worker thread: full-length per-track dry stems (part 7,
 * `stems/dry/track<channel>.wav`), per-track wet (FX-applied) stems and a
 * reconstructed master bus (part 8, `stems/wet/track<channel>.wav` +
 * `stems/wet/master.wav`: track sum + master gain + limiter — this
 * feature's golden-parity guardrail against the live-captured master).
 * Reads exclusively from disk — no live-engine dependency — so a render can
 * run concurrently with live looping, and a crash-salvage render is free. */

/* Starts an offline render of the finalized capture at `capture_dir`: spawns
 * a worker thread that writes `stems/dry/track<channel>.wav` +
 * `stems/wet/track<channel>.wav` under `capture_dir` for every non-empty
 * track, then `stems/wet/master.wav` once every channel has been processed,
 * with poll-based progress. Returns LE_OK once the worker thread is
 * launched (this call never blocks on the render itself), LE_ERR_INVALID
 * for a null engine/capture_dir or an empty capture_dir, or
 * LE_ERR_ALREADY_RUNNING if a render is already active on this engine. */
LE_EXPORT int32_t le_perf_render_begin(le_engine* engine,
                                       const char* capture_dir);

/* Reads the current render's progress: `*done` (0 while rendering, 1 once
 * finished), `*progress_pct` (0..100, monotonic), `*track_count` (how many
 * entries `le_perf_render_track_status` can currently read — grows
 * progressively as each track's stem completes, not only once `*done`).
 * Safe to call whether or not a render is active — with none active,
 * `*done` reads 1, `*progress_pct` reads 100, `*track_count` reads 0. Any
 * output pointer may be NULL to skip that field. Returns LE_OK while
 * rendering, with none active, or after a finished render; after a render
 * that could not read a complete, valid manifest it returns that terminal
 * failure (LE_ERR_INVALID for unusable data, LE_ERR_DEVICE when the worker
 * could not allocate) with `*done` 1 and no invented track results. Returns
 * LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_perf_render_poll(le_engine* engine, int32_t* done,
                                     int32_t* progress_pct,
                                     int32_t* track_count);

/* Reads render result `index`'s (0..track_count-1, from the most recent
 * le_perf_render_poll) track channel and outcome (`*succeeded`: 1 if its
 * stem was written, 0 on a per-stem failure — the umbrella's "partial
 * success" posture: one failed stem does not abort the others). `*succeeded`
 * reflects BOTH the dry and wet stem for that channel — either one failing
 * marks the track failed, since a wet stem with no matching dry source is
 * not a usable partial result. Returns LE_OK, or LE_ERR_INVALID for a null
 * engine / out-of-range index. */
LE_EXPORT int32_t le_perf_render_track_status(le_engine* engine,
                                              int32_t index, int32_t* channel,
                                              int32_t* succeeded);

/* Cancels an in-progress render and joins the worker thread; a no-op when no
 * render is active. Cancellation is checked once per per-track work chunk
 * (never mid-stem), so this only returns once the worker has actually
 * stopped, leaving no partial stem file for whichever track was in flight.
 * Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_perf_render_cancel(le_engine* engine);

/* ---- effect-chain fingerprints (control thread; FX divergence detection) ---- *
 * An order-sensitive 64-bit hash of a lane's / monitor's PUBLISHED effect chain:
 * for each of the a_fx_count active entries, its type, plus (for a built-in) its
 * LE_FX_PARAMS float parameter bits — a plugin entry contributes its type only
 * (its params live in the plugin host, not a_fx_param). The empty chain hashes
 * to the FNV-1a offset basis. This is DETECTION only, not a chain readback: the
 * Dart repository owns the chain and computes the identical hash over its cache,
 * so a debug assert / the sequence fuzzer can catch a cache-vs-engine divergence
 * without the engine ever narrating the chain back. Scanned on the control thread
 * off the published a_fx_* atomics (the race-free seam, like le_max_fx_latency);
 * the audio thread never reads it. Out-of-range args return 0. */
LE_EXPORT uint64_t le_engine_lane_fx_fingerprint(le_engine* engine,
                                                 int32_t channel, int32_t lane);
LE_EXPORT uint64_t le_engine_monitor_fx_fingerprint(le_engine* engine,
                                                    int32_t input);

/* ---- session persistence ---- *
 * Save: read each track's loop PCM with le_engine_export_track. Load: clear the
 * engine (so every track is EMPTY), le_engine_import_track each stem, then
 * le_engine_commit_session to establish the master with tracks stopped. Per-track
 * buffers are mono (one sample per frame). */

/* Copies up to `max_frames` frames of track `channel`'s mono loop into `out`;
 * returns the number of frames written (the track length, clamped to
 * `max_frames`), or 0 on a bad argument / empty track. Reads the live buffer —
 * call when the track is not capturing. */
LE_EXPORT int32_t le_engine_export_track(le_engine* engine, int32_t channel,
                                         float* out, int32_t max_frames);

/* Copies up to `max_frames` frames of track `channel`'s lane `lane` mono loop
 * into `out`; returns the number of frames written (the lane's length,
 * clamped to `max_frames`), 0 for a valid-but-empty lane, or LE_ERR_INVALID
 * for an out-of-range channel/lane or a non-positive `max_frames`. On a
 * successful (valid-argument) call this is byte-identical to
 * le_engine_export_track (which is equivalent to lane 0 and untouched by
 * this addition) — call when the track is not capturing. The two functions
 * intentionally diverge on invalid-argument return codes: this one
 * distinguishes LE_ERR_INVALID from 0 because it has a `lane` argument to
 * validate separately; le_engine_export_track has no such argument and
 * returns 0 uniformly for any bad input. */
LE_EXPORT int32_t le_engine_export_track_lane(le_engine* engine,
                                              int32_t channel, int32_t lane,
                                              float* out, int32_t max_frames);

/* Loads `frames` mono frames of PCM into track `channel`'s buffer and records
 * the length. The track must be EMPTY (LE_ERR_INVALID otherwise); the unfilled
 * tail is zeroed. The track becomes STOPPED on le_engine_commit_session. Returns
 * LE_OK or an le_result error. Equivalent to le_engine_import_track_lane with
 * lane == 0. */
LE_EXPORT int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                                         const float* pcm, int32_t frames);

/* Loads `frames` mono frames of PCM into track `channel`'s lane `lane`, the
 * multi-lane restore counterpart of le_engine_export_track_lane. The track must
 * be EMPTY (LE_ERR_INVALID otherwise); the unfilled tail is zeroed. Importing a
 * lane >= the current active count grows lane_count to activate it for playback
 * (the new lane takes its standard record route, input == lane index). Lane 0 is
 * the primary import and resets the track's redo/empty accounting; additional
 * lanes only fill their own buffer (they share the track's one undo span). Call
 * lane 0 first, then each further lane, then le_engine_commit_session. Returns
 * LE_OK or an le_result error. */
LE_EXPORT int32_t le_engine_import_track_lane(le_engine* engine, int32_t channel,
                                              int32_t lane, const float* pcm,
                                              int32_t frames);

/* ---- overdub-layer (undo/redo) persistence ---- *
 * A track's full history is its list of entries (le_engine_export_history)
 * plus the ordered set of pool buffers per lane they name:
 * undo_stack[0..undo_count) (oldest first), then the live buffer, then the
 * redo stack read top-down. le_engine_export_layer reads the buffers by a
 * linear image `ordinal`, and le_engine_import_layer + le_engine_finalize_history
 * rebuild them with their kinds. The stacks are track-owned and shared across
 * lanes in lockstep, so every lane carries the same image count at the same
 * ordinals. */

/* Copies up to `max_frames` frames of track `channel`'s lane `lane` image at
 * `ordinal` into `out`. Ordinals run oldest→newest: `[0, undo_count)` are the
 * undo snapshots, `undo_count` is the live buffer, and the redo snapshots
 * follow, newest-adjacent first; a redo-side peel marker holds no image and
 * takes no ordinal (le_engine_export_history). Returns the frames written (the
 * loop length, clamped to `max_frames`), 0 for an empty layer, or
 * LE_ERR_INVALID for an out-of-range channel/lane/ordinal or non-positive
 * `max_frames`. Control thread; call when the track is not capturing. */
LE_EXPORT int32_t le_engine_export_layer(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t ordinal,
                                         float* out, int32_t max_frames);

/* Loads `frames` mono frames into track `channel`'s lane `lane` at image
 * `ordinal` (which becomes the pool slot index), staging a reconstruction into
 * an EMPTY track. Call once per (lane, ordinal) — ordinals contiguous from 0 —
 * then le_engine_finalize_history, then le_engine_commit_session. Importing a
 * lane >= the active count activates it. Returns LE_OK, or LE_ERR_INVALID for a
 * non-EMPTY track, an `ordinal` past the pool cap, or an oversized `frames`. */
LE_EXPORT int32_t le_engine_import_layer(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t ordinal,
                                         const float* pcm, int32_t frames);

/* Publishes a track reconstructed by le_engine_import_layer with its history
 * (#1164): `count` entries in le_engine_export_history order (`kinds[i]`,
 * `skipped[i]`), the first `undo_count` of them on the undo stack and the rest
 * on the redo stack top-down. Image-bearing entries take slot == image ordinal,
 * the live buffer is slot `undo_count`, and a redo-side peel entry becomes a
 * marker without an image; every active lane is republished in lockstep with
 * its undo, redo and peel depths. Strict: LE_ERR_INVALID for a non-EMPTY
 * track, an unknown kind, a `skipped` outside [0, LE_POOL_SLOTS) or nonzero on
 * a kind other than peel, a clear restore point anywhere but the last entry
 * on the redo side, an undo-side peel whose `skipped` exceeds the run of peel
 * entries directly beneath it (unless that run reaches the bottom: pool
 * eviction), a redo-side peel marker that would find no layer to peel when
 * Redo reaches it, more images than LE_POOL_SLOTS, or a torn reconstruction
 * (an image ordinal not staged on every active lane, or lanes at different
 * lengths). Returns LE_OK otherwise. */
LE_EXPORT int32_t le_engine_finalize_history(le_engine* engine, int32_t channel,
                                             const int32_t* kinds,
                                             const int32_t* skipped,
                                             int32_t count, int32_t undo_count);

/* Lists track `channel`'s history entries in image-ordinal order (#1164):
 * the undo stack oldest first, then the redo stack top-down. `kinds[i]` is the
 * entry's kind (0 overdub layer, 1 clear restore point, 2 peel, 3 loop-close
 * restoration) and `skipped[i]` its peel payload (0 for every other kind). A
 * redo-side peel entry is a marker without an image: le_engine_export_layer's
 * ordinals count image-bearing entries only, so a track's image count is
 * `undo_count + 1 + (redo entries that are not peel markers)`. Writes at most
 * `max` entries, stores the undo stack's entry count in `*undo_count` (the
 * first `*undo_count` entries are the undo side and ordinal `*undo_count` is
 * the live image), and returns the track's TOTAL entry count (which may exceed
 * `max`), or LE_ERR_INVALID for a bad handle, channel, NULL pointer or
 * negative `max`. `*undo_count` is the raw stack count, not the snapshot's
 * undo_depth: that one reads 0 while a content-giving command (a clear
 * restore) is in flight, so a Session capture must split by this value.
 * Control thread. */
LE_EXPORT int32_t le_engine_export_history(le_engine* engine, int32_t channel,
                                           int32_t* kinds, int32_t* skipped,
                                           int32_t max, int32_t* undo_count);

/* Establishes the master loop at `base_frames` and parks every imported track
 * (EMPTY with a loaded length) STOPPED at its whole-loop multiple
 * (length / base_frames). Restores exactly `loop_bars` musical bars over that
 * span; zero keeps the loop grid-free even when a tempo is known. The caller
 * restores tempo/source/signature before this commit. Does not infer bars
 * from BPM or change audio length. Requires base_frames > 0 and loop_bars in
 * 0..INT32_MAX/15 (the largest supported signature has 15 beats). Posts one
 * command; returns LE_OK or an le_result error.
 */
LE_EXPORT int32_t le_engine_commit_session(le_engine* engine,
                                           int32_t base_frames,
                                           int32_t loop_bars);

/* Fade admission returns a nonzero request id only on LE_OK. Toggle resolves
 * the opposite target on the callback, with a 0.5..30 second full traversal.
 * Install accepts amount/target 0..1; zero seconds requires amount == target.
 * Both use bounded receipt storage and leave the image unchanged on refusal. */
LE_EXPORT int32_t le_engine_toggle_fade(le_engine* engine, int32_t channel,
                                       float seconds, uint64_t* request);
LE_EXPORT int32_t le_engine_install_fade(le_engine* engine, int32_t channel,
                                        const le_fade_image* image,
                                        uint64_t* request);
/* Reverse (#1162): flips, or installs, the read direction of track
 * [channel]'s recorded material at its current position, click-free. Speed
 * and pitch are unchanged; a STOPPED track stays stopped and plays reversed
 * from its re-entry coordinate. Admission returns a nonzero request id only on
 * LE_OK; the callback decides and the receipt below carries its verdict.
 * Toggle refusals: LE_ERR_INVALID for a bad channel or a track that reads
 * EMPTY, RECORDING or OVERDUBBING; LE_ERR_NOT_READY while an arm or Count-in
 * launch is pending on the track (it may fire into OVERDUBBING before the
 * toggle lands) or when no receipt slot is free; LE_ERR_NOT_RUNNING when not
 * configured. Install accepts an EMPTY track that already holds imported
 * material (Session recall, before the commit) and otherwise refuses like
 * toggle. The callback refuses either (receipt LE_ERR_INVALID) while a punch
 * tail is still writing or the loop has no length. Overdubbing into a
 * reversed track is refused by le_engine_record with LE_ERR_REVERSED. */
LE_EXPORT int32_t le_engine_toggle_reverse(le_engine* engine, int32_t channel,
                                          uint64_t* request);
LE_EXPORT int32_t le_engine_install_reverse(le_engine* engine, int32_t channel,
                                           int32_t reversed, uint64_t* request);
/* Consumes one completed Fade or Reverse result. Returns NOT_READY before
 * callback publication, INVALID for an absent/consumed/retired id; otherwise
 * OK and fills result. */
LE_EXPORT int32_t le_engine_read_request_result(le_engine* engine,
                                               uint64_t request,
                                               int32_t* result);

/* Read-only control-thread query: 1 when every successfully queued command
 * has been consumed (including rejected/no-op outcomes) and the callback has
 * published its resulting snapshot values; 0 while pending, unconfigured or
 * null. Acquire this before taking the snapshot for a running-session save.
 * Does not wait or drain. Direct atomic setters need no command settlement;
 * active capture and pending overdub layers still require their own checks. */
LE_EXPORT int32_t le_engine_commands_settled(le_engine* engine);

/* ---- native USB MIDI input (foot-pedal control) ---- *
 *
 * A self-contained capture seam, independent of the audio engine lifecycle: it
 * enumerates the host's MIDI *input* ports, opens one, and pushes raw Note/CC
 * messages to a registered callback for the Dart controller pipeline to map
 * (CC 80-83 -> record/stop/undo/clear by default). Captured natively on all
 * three desktop OSes (CoreMIDI / ALSA sequencer / WinMM) so the footswitch ->
 * action latency stays tight and consistent.
 *
 * SysEx / real-time / aftertouch / pitch-bend / program-change are dropped at
 * the native layer, so the callback only ever sees Note On/Off and Control
 * Change. The OS MIDI callback does no allocation, locking, or blocking I/O on
 * its hot path (it parses + pushes to a lock-free SPSC ring); a drain step
 * invokes the callback off that thread. Entirely separate from the audio
 * command ring -- never a second producer on it. */

/* A MIDI input port discovered by le_midi_enumerate.
 *
 * `id` is a per-OS stable token for re-selecting the same device across replug:
 * the CoreMIDI kMIDIPropertyUniqueID (macOS), or the port name (ALSA, WinMM).
 * `name` is the human-readable label. `is_default` marks a system-preferred
 * input where the OS exposes one (always 0 on ALSA/WinMM, which have none). */
typedef struct le_midi_info {
  char id[256];
  char name[256];
  int32_t is_default; /* 0/1 */
} le_midi_info;

/* Raw MIDI input callback: one Note On/Off or Control Change message.
 * `status` carries the message type in its high nibble and the channel in its
 * low nibble; `data1`/`data2` are the two data bytes (CC number/value or note/
 * velocity). `ts_us` is a per-OS monotonic capture timestamp in microseconds,
 * carried for future quantization (unused by the default control path).
 *
 * Invoked off the OS MIDI thread via the drain step. With Dart's
 * NativeCallable.listener the delivery is marshalled onto the isolate event
 * loop, so the registered function may run any Dart code. */
typedef void (*le_midi_event_cb)(uint8_t status, uint8_t data1, uint8_t data2,
                                 uint64_t ts_us);

/* Opaque MIDI capture handle (one open input port at a time). */
typedef struct le_midi le_midi;

/* Allocates a MIDI capture handle bound to the compiled-in per-OS backend.
 * Returns NULL on allocation failure or when no backend is available for the
 * platform. */
LE_EXPORT le_midi* le_midi_create(void);

/* Closes any open port and frees the handle. Safe to call with NULL. */
LE_EXPORT void le_midi_destroy(le_midi* m);

/* Enumerates the host's MIDI input ports into `out` (room for `max` entries),
 * writing the number filled into *count (clamped to `max`). Returns LE_OK, or
 * LE_ERR_INVALID for a null argument / non-positive `max`. Degrades to
 * *count = 0, LE_OK when the platform has no backend or no ports. Uses a
 * transient OS handle, so it is safe to call while a port is open. */
LE_EXPORT int32_t le_midi_enumerate(le_midi_info* out, int32_t max,
                                    int32_t* count);

/* Opens the input port whose `id` matches an `id` from le_midi_enumerate and
 * begins capture, delivering messages to `cb`. Re-opening switches the device
 * (the previous port is closed first), so this is idempotent for re-selection.
 * Returns LE_OK, LE_ERR_INVALID (null handle / cb), LE_ERR_DEVICE (port not
 * found or could not be opened, e.g. in use). */
LE_EXPORT int32_t le_midi_open(le_midi* m, const char* id,
                               le_midi_event_cb cb);

/* Stops capture and closes the open port. Idempotent (a no-op when nothing is
 * open). After it returns the callback registered by le_midi_open is guaranteed
 * not to be invoked again. Returns LE_OK or LE_ERR_INVALID (null handle). */
LE_EXPORT int32_t le_midi_close(le_midi* m);

/* ---- native USB MIDI output (foot-pedal LED feedback) ---- *
 *
 * The send side of the same transport, kept as a fully independent handle from
 * the input capture (le_midi above): a pedal binds one input source AND one
 * output destination of the same physical device, but the two are separate OS
 * ports with separate ids. This seam enumerates the host's MIDI *output* ports,
 * opens one, and sends raw MIDI bytes to it — short channel-voice / real-time
 * messages and System Exclusive alike. It has no callback, no ring, and no
 * worker thread: le_midi_out_send synchronously hands the bytes to the OS.
 *
 * segno uses it to push the pedal's LED state frames (checksummed 7-bit SysEx)
 * and the loop-top real-time pulse. The bytes are sent verbatim; framing,
 * 7-bit packing, and checksums are the Dart/firmware contract, not this layer's
 * concern. Reuses le_midi_info for enumeration (id/name/is_default). */

/* Opaque MIDI output handle (one open output port at a time). */
typedef struct le_midi_out le_midi_out;

/* Allocates a MIDI output handle bound to the compiled-in per-OS backend.
 * Returns NULL on allocation failure or when no backend is available for the
 * platform. */
LE_EXPORT le_midi_out* le_midi_out_create(void);

/* Closes any open port and frees the handle. Safe to call with NULL. */
LE_EXPORT void le_midi_out_destroy(le_midi_out* m);

/* Enumerates the host's MIDI output ports into `out` (room for `max` entries),
 * writing the number filled into *count (clamped to `max`). Returns LE_OK, or
 * LE_ERR_INVALID for a null argument / non-positive `max`. Degrades to
 * *count = 0, LE_OK when the platform has no backend or no ports. The `id`s
 * mirror the input seam's scheme (CoreMIDI unique id / ALSA client name / WinMM
 * device name) but address *destinations*, so an output id is not interchangeable
 * with an input id even for the same physical device. */
LE_EXPORT int32_t le_midi_out_enumerate(le_midi_info* out, int32_t max,
                                        int32_t* count);

/* Opens the output port whose `id` matches an `id` from le_midi_out_enumerate.
 * Re-opening switches the device (the previous port is closed first), so this is
 * idempotent for re-selection. Returns LE_OK, LE_ERR_INVALID (null handle),
 * LE_ERR_DEVICE (port not found or could not be opened). */
LE_EXPORT int32_t le_midi_out_open(le_midi_out* m, const char* id);

/* Closes the open output port. Idempotent (a no-op when nothing is open).
 * Returns LE_OK or LE_ERR_INVALID (null handle). */
LE_EXPORT int32_t le_midi_out_close(le_midi_out* m);

/* Sends `len` raw MIDI bytes to the open port. `data` may be a short
 * channel-voice or System real-time message (1-3 bytes) or a complete System
 * Exclusive message (`0xF0` … `0xF7`); the backend routes long vs short
 * appropriately. The call is synchronous — the bytes are owned only for its
 * duration. Returns LE_OK, LE_ERR_INVALID (null handle / data, non-positive
 * len), or LE_ERR_DEVICE (no port open or the OS rejected the send). */
LE_EXPORT int32_t le_midi_out_send(le_midi_out* m, const uint8_t* data,
                                   int32_t len);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_API_H */
