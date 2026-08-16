// The `Array<Uint32>` index operator the fixed-width telemetry arrays
// (`le_cb_window_snapshot.buckets` / `.xruns`) are read through is a dart:ffi
// extension, so the library has to be imported for it to be in scope.
import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:segno_engine/src/engine_config.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// The maximum number of lanes a single track can hold, mirroring the native
/// `LE_MAX_LANES`. Referenced (not re-typed) so it can never drift from the C.
const int kMaxLanes = LE_MAX_LANES;

/// The number of hardware inputs the live-monitor path covers, mirroring the
/// native `LE_MAX_MONITORED_INPUTS`. Referenced (not re-typed) so it can never
/// drift from the C.
///
/// Not "the inputs the rig can use": an input past this can still be RECORDED
/// into a lane, it simply cannot be monitored. The old name for this
/// (`kMaxInputs`) read as the former, and was misread that way at least once
/// (#558) — capping what a socket could be NAMED at eight.
const int kMaxMonitoredInputs = LE_MAX_MONITORED_INPUTS;

/// Phase of the loopback round-trip latency harness.
///
/// Mirrors the native `le_latency_state` enum.
enum LatencyState {
  /// No measurement has been requested.
  idle,

  /// An impulse has been emitted and the engine is waiting for it to return.
  measuring,

  /// A measurement completed; [EngineSnapshot.measuredLatencyMs] is valid.
  done,

  /// No loopback signal was detected within the measurement window.
  timeout;

  /// Maps a native `le_latency_state` integer to a [LatencyState].
  static LatencyState fromCode(int code) => switch (code) {
    0 => LatencyState.idle,
    1 => LatencyState.measuring,
    2 => LatencyState.done,
    3 => LatencyState.timeout,
    _ => LatencyState.idle,
  };
}

/// The per-track looper state machine.
///
/// Mirrors the native `le_track_state` enum.
enum TrackState {
  /// No audio captured yet.
  empty,

  /// Capturing the first pass (or overwriting one loop on a new track).
  recording,

  /// Summing input into the existing loop.
  overdubbing,

  /// Looping playback.
  playing,

  /// Playback halted; the loop buffer is retained.
  stopped;

  /// Maps a native `le_track_state` integer to a [TrackState].
  static TrackState fromCode(int code) => switch (code) {
    0 => TrackState.empty,
    1 => TrackState.recording,
    2 => TrackState.overdubbing,
    3 => TrackState.playing,
    4 => TrackState.stopped,
    _ => TrackState.empty,
  };
}

/// Where the current tempo came from (D7 precedence:
/// `external > (manual | tapped, last writer wins) > derived`).
///
/// Mirrors the native `le_tempo_source` enum. [external] is reserved for the
/// Phase E MIDI-clock follower and unused by anything in this slice.
enum TempoSource {
  /// No tempo has ever been set; [EngineSnapshot.tempoBpm] reads `0`.
  none,

  /// Set via `TempoControl.setTempo` (last writer wins against [tapped]).
  manual,

  /// Set via `TempoControl.tapTempo` (last writer wins against [manual]).
  tapped,

  /// Derived from a defining loop finalized with loop↔tempo sync on (D7).
  /// Survives clearing the loop that produced it — only an explicit reset
  /// returns the source to [none].
  derived,

  /// Reserved: MIDI clock receive (Phase E). Unused here.
  external;

  /// Maps a native `le_tempo_source` integer to a [TempoSource]. Unknown
  /// values map to [TempoSource.none].
  static TempoSource fromCode(int code) => switch (code) {
    0 => TempoSource.none,
    1 => TempoSource.manual,
    2 => TempoSource.tapped,
    3 => TempoSource.derived,
    4 => TempoSource.external,
    _ => TempoSource.none,
  };
}

/// Musical quantization / click granularity.
///
/// Mirrors the native `le_grid_div` enum (`tempo_grid.h`). The note values
/// are ABSOLUTE — a [quarter] is a quarter note regardless of the current
/// time signature, since the grid's beat unit is the signature's denominator
/// note (see `tempo_grid.h`'s header doc).
enum GridDivision {
  /// No quantization grid (default).
  off,

  /// One bar.
  bar,

  /// A half note.
  half,

  /// A quarter note.
  quarter,

  /// An eighth note.
  eighth,

  /// A sixteenth note.
  sixteenth;

  /// The native `le_grid_div` integer for this division.
  int get code => switch (this) {
    GridDivision.off => 0,
    GridDivision.bar => 1,
    GridDivision.half => 2,
    GridDivision.quarter => 3,
    GridDivision.eighth => 4,
    GridDivision.sixteenth => 5,
  };

  /// Maps a native `le_grid_div` integer to a [GridDivision]. Unknown values
  /// map to [GridDivision.off].
  static GridDivision fromCode(int code) => switch (code) {
    0 => GridDivision.off,
    1 => GridDivision.bar,
    2 => GridDivision.half,
    3 => GridDivision.quarter,
    4 => GridDivision.eighth,
    5 => GridDivision.sixteenth,
    _ => GridDivision.off,
  };
}

/// Click (metronome) audibility mode — a 4-value mode (Sheeran manual
/// §5.9.1) that gates WHEN the click voice sounds; WHERE it sounds is the
/// click output mask (`TempoControl.setClickOutput`, default no outputs).
///
/// Mirrors the native `le_click_mode` enum.
enum ClickMode {
  /// Never audible (count-ins still run, silently).
  off,

  /// Audible while any track records or overdubs.
  rec,

  /// Audible only during the DEFINING first-layer recording (including its
  /// count-in).
  recFirst,

  /// Audible whenever the transport plays or records.
  playRec;

  /// The native `le_click_mode` integer for this mode.
  int get code => switch (this) {
    ClickMode.off => 0,
    ClickMode.rec => 1,
    ClickMode.recFirst => 2,
    ClickMode.playRec => 3,
  };

  /// Maps a native `le_click_mode` integer to a [ClickMode]. Unknown values
  /// map to [ClickMode.off].
  static ClickMode fromCode(int code) => switch (code) {
    0 => ClickMode.off,
    1 => ClickMode.rec,
    2 => ClickMode.recFirst,
    3 => ClickMode.playRec,
    _ => ClickMode.off,
  };
}

/// The five architectural looper modes (B2a, D4/D10 —
/// `2026-07-22-feat-tempo-aware-looper-modes-plan.md`).
///
/// [multi] is today's behavior (independent per-track loops) and stays the
/// default. The other four values do not have their SEMANTICS implemented
/// yet — Sync's primary-track sync + divisions, Song's section sequencing,
/// Band's primary + quantized sections, and Free's per-track independent
/// clocks all land in later parts (B2b onward). This part is only the field
/// plus the D4 content-lock gate that guards switching it: the engine
/// silently rejects `LooperModeControl.setLooperMode` while any track has
/// content, and its audio path stays the [multi] behavior regardless of
/// which value is published.
///
/// This is a DIFFERENT axis from `InteractionMode` (record/mute — what a
/// track press does): the two names never coexist (D10) and must not be
/// confused with each other.
///
/// Mirrors the native `le_looper_mode` enum.
enum LooperMode {
  /// Independent per-track loops — today's behavior, and the default.
  multi,

  /// Primary-track ("crown") sync with multiples and divisions. Semantics
  /// land in part B3; unimplemented here.
  sync,

  /// Section sequencing. Semantics land in part B4; unimplemented here.
  song,

  /// Primary track plus independently start/stoppable, quantized section
  /// tracks. Semantics land in part B3; unimplemented here.
  band,

  /// Independent per-track clocks. Semantics land in part B2b;
  /// unimplemented here.
  free;

  /// The native `le_looper_mode` integer for this mode.
  int get code => switch (this) {
    LooperMode.multi => 0,
    LooperMode.sync => 1,
    LooperMode.song => 2,
    LooperMode.band => 3,
    LooperMode.free => 4,
  };

  /// Maps a native `le_looper_mode` integer to a [LooperMode]. Unknown
  /// values map to [LooperMode.multi].
  static LooperMode fromCode(int code) => switch (code) {
    0 => LooperMode.multi,
    1 => LooperMode.sync,
    2 => LooperMode.song,
    3 => LooperMode.band,
    4 => LooperMode.free,
    _ => LooperMode.multi,
  };
}

/// An immutable per-lane projection of the native `le_lane_snapshot`.
///
/// A lane is a track's fundamental recordable unit: it records one hardware
/// input ([inputChannel], `-1` = none) into its own clean mono buffer and plays
/// that buffer — through its own effect chain — to the outputs in [outputMask].
@immutable
class LaneSnapshot {
  /// Creates a [LaneSnapshot].
  const LaneSnapshot({
    required this.inputChannel,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.lengthFrames,
    required this.rms,
    required this.peak,
  });

  /// An empty lane recording no input.
  const LaneSnapshot.empty()
    : inputChannel = -1,
      outputMask = 0x3,
      volume = 1,
      muted = false,
      lengthFrames = 0,
      rms = 0,
      peak = 0;

  /// Projects a native `le_lane_snapshot` into a [LaneSnapshot].
  factory LaneSnapshot.fromNative(le_lane_snapshot native) => LaneSnapshot(
    inputChannel: native.input_channel,
    outputMask: native.output_mask,
    volume: native.volume,
    muted: native.muted != 0,
    lengthFrames: native.length_frames,
    rms: native.rms,
    peak: native.peak,
  );

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// Bitmask of hardware output channels this lane plays to (bit c => out c).
  final int outputMask;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Captured length of this lane's buffer in frames.
  final int lengthFrames;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LaneSnapshot &&
          runtimeType == other.runtimeType &&
          inputChannel == other.inputChannel &&
          outputMask == other.outputMask &&
          volume == other.volume &&
          muted == other.muted &&
          lengthFrames == other.lengthFrames &&
          rms == other.rms &&
          peak == other.peak;

  @override
  int get hashCode => Object.hash(
    inputChannel,
    outputMask,
    volume,
    muted,
    lengthFrames,
    rms,
    peak,
  );
}

/// An immutable per-track projection of the native `le_track_snapshot`.
///
/// A track is a multi-lane container: it owns the transport (state, multiple,
/// undo/redo depth) and its [lanes]. The scalar [volume]/[muted]/[lengthFrames]/
/// [rms]/[peak]/[inputMask]/[outputMask] fields mirror lane 0 for back-compat
/// single-lane accessors; per-lane state lives in [lanes].
@immutable
class TrackSnapshot {
  /// Creates a [TrackSnapshot].
  const TrackSnapshot({
    required this.state,
    required this.volume,
    required this.muted,
    required this.lengthFrames,
    required this.undoDepth,
    required this.rms,
    required this.peak,
    this.clearRestore = false,
    this.redoDepth = 0,
    this.multiple = 1,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.layerInFlight = false,
    this.pending = false,
    this.lengthPresetBars = 0,
    this.oneShot = false,
    this.lanes = const <LaneSnapshot>[],
  });

  /// An empty track.
  const TrackSnapshot.empty()
    : state = TrackState.empty,
      volume = 1,
      muted = false,
      lengthFrames = 0,
      undoDepth = 0,
      clearRestore = false,
      redoDepth = 0,
      rms = 0,
      peak = 0,
      multiple = 1,
      inputMask = 0x1,
      outputMask = 0x3,
      layerInFlight = false,
      pending = false,
      lengthPresetBars = 0,
      oneShot = false,
      lanes = const <LaneSnapshot>[];

  /// Projects a native `le_track_snapshot` into a [TrackSnapshot].
  ///
  /// [lanes] are read separately (via `le_engine_get_lane`, one per active
  /// lane) because this ffi version cannot index a native struct array; their
  /// length is `native.lane_count`.
  factory TrackSnapshot.fromNative(
    le_track_snapshot native, [
    List<LaneSnapshot> lanes = const [],
  ]) => TrackSnapshot(
    state: TrackState.fromCode(native.state),
    volume: native.volume,
    muted: native.muted != 0,
    lengthFrames: native.length_frames,
    undoDepth: native.undo_depth,
    clearRestore: native.clear_restore != 0,
    redoDepth: native.redo_depth,
    rms: native.rms,
    peak: native.peak,
    multiple: native.multiple,
    inputMask: native.input_mask,
    outputMask: native.output_mask,
    layerInFlight: native.layer_in_flight != 0,
    pending: native.pending != 0,
    lengthPresetBars: native.length_preset_bars,
    oneShot: native.one_shot != 0,
    lanes: lanes,
  );

  /// State-machine phase.
  final TrackState state;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Captured length in frames (equals `multiple` × the master length).
  final int lengthFrames;

  /// Track length in whole base loops (`>= 1`); `> 1` for a loop multiple.
  final int multiple;

  /// Available undo steps (overdub layers).
  final int undoDepth;

  /// Whether the next undo on this track restores a take cleared via
  /// `clearUndoable` rather than peeling an overdub layer.
  ///
  /// A cleared track reports [undoDepth] 0 — its erased take's layers are held
  /// but not peelable until the restore point above them is undone — so this is
  /// what says "undo would do something" there.
  final bool clearRestore;

  /// Available redo steps.
  final int redoDepth;

  /// Whether an overdub undo layer is still being captured or drained (the
  /// punch-tail window). Session capture waits this out before exporting.
  final bool layerInFlight;

  /// Whether a quantized/signal-triggered record arm is waiting to fire.
  final bool pending;

  /// The DEFINING-recording length preset (A6, D17): `0` = AUTO, `1..64` =
  /// fixed N bars. Inert on a track that already has content; applies to the
  /// next defining recording only. See `TempoControl.setTrackLengthPreset`.
  final int lengthPresetBars;

  /// One Shot (song-mode-spec.md §2, B4/B5c): when `true`, this track plays
  /// once and then stops instead of looping. Settable in any looper mode via
  /// `LooperModeControl.setOneShot`, but only behaviorally active in
  /// Free/Song. A per-track SETTING, not content — survives a clear/
  /// undo-to-empty and a mode switch, but resets to `false` on a fresh
  /// (re)start of the engine (unlike [lengthPresetBars]'s live behavior,
  /// which persists — see `LooperRepository`'s re-apply cache for the
  /// Dart-side mirror of this reset).
  final bool oneShot;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  /// Lane 0's recorded input as a bitmask (`1 << inputChannel`, or `0` when
  /// lane 0 records no input). Mirrors lane 0; per-lane inputs are in [lanes].
  final int inputMask;

  /// Bitmask of hardware output channels this track plays to (bit c => out c).
  /// Mirrors lane 0.
  final int outputMask;

  /// Per-lane snapshots, in lane order.
  ///
  /// Populated by the native engine's `snapshot()` with one entry per active
  /// lane (read via `le_engine_get_lane`); empty in synthetic snapshots such as
  /// [TrackSnapshot.empty].
  final List<LaneSnapshot> lanes;

  /// The number of active lanes (equals [lanes] length).
  int get laneCount => lanes.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackSnapshot &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          volume == other.volume &&
          muted == other.muted &&
          lengthFrames == other.lengthFrames &&
          multiple == other.multiple &&
          undoDepth == other.undoDepth &&
          redoDepth == other.redoDepth &&
          rms == other.rms &&
          peak == other.peak &&
          inputMask == other.inputMask &&
          outputMask == other.outputMask &&
          layerInFlight == other.layerInFlight &&
          pending == other.pending &&
          lengthPresetBars == other.lengthPresetBars &&
          oneShot == other.oneShot &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode => Object.hash(
    state,
    volume,
    muted,
    lengthFrames,
    multiple,
    undoDepth,
    redoDepth,
    rms,
    peak,
    inputMask,
    outputMask,
    layerInFlight,
    pending,
    lengthPresetBars,
    oneShot,
    Object.hashAll(lanes),
  );
}

/// A class of real device dropout, as counted by [CallbackWindowStats.xruns].
///
/// Mirrors the native `le_xrun_kind`; the ordinals are the array indices the
/// engine tallies into, so the order is load-bearing.
enum XrunKind {
  /// `snd_pcm_writei` returned `-EPIPE`: the card ran out of audio to play.
  playbackUnderrun,

  /// `snd_pcm_readi` returned `-EPIPE`: we did not read capture in time.
  captureOverrun,

  /// The slipped-playback drop+prepare resync — a stream that fell behind the
  /// hardware pointer with no XRUN raised, resynced by the ALSA backend.
  playbackResync,

  /// The Windows ASIO driver's `kAsioOverload` notification.
  backendOverload,
}

/// One accumulation window of audio-callback telemetry (native issue #722).
///
/// The audio callback measuring its own lateness: how long each device callback
/// took against the period budget, how far apart consecutive callbacks arrived,
/// and how many real backend dropouts happened. The pure-Dart projection of
/// `le_cb_window_snapshot`.
///
/// Two windows are published side by side on [EngineSnapshot] — one for the
/// whole device session and one reset by every performance arm — because the
/// question this instrument exists to answer is comparative: is the callback
/// worse *while a capture is armed*? Counts subtract ([calls], [lateCalls],
/// [gapEvents], [xruns]); maxima do not, which is why both windows report their
/// own.
@immutable
class CallbackWindowStats {
  /// Creates a [CallbackWindowStats].
  const CallbackWindowStats({
    this.calls = 0,
    this.lateCalls = 0,
    this.gapEvents = 0,
    this.maxUs = 0,
    this.meanUs = 0,
    this.maxGapUs = 0,
    this.buckets = const [0, 0, 0, 0, 0, 0, 0, 0],
    this.xruns = const [0, 0, 0, 0],
  });

  /// Projects a native `le_cb_window_snapshot`.
  factory CallbackWindowStats.fromNative(le_cb_window_snapshot native) =>
      CallbackWindowStats(
        calls: native.calls,
        lateCalls: native.late_calls,
        gapEvents: native.gap_events,
        maxUs: native.max_us,
        meanUs: native.mean_us,
        maxGapUs: native.max_gap_us,
        buckets: [
          for (var i = 0; i < LE_CB_BUCKETS; i++) native.buckets[i],
        ],
        xruns: [for (var i = 0; i < LE_XRUN_KINDS; i++) native.xruns[i]],
      );

  /// The all-zero window: no device has run, so nothing was measured.
  static const CallbackWindowStats empty = CallbackWindowStats();

  /// Device callbacks observed in this window.
  final int calls;

  /// Of those, the ones whose duration exceeded the period budget — a missed
  /// deadline, which is what a click sounds like at a 64-frame period.
  final int lateCalls;

  /// Consecutive callback *entries* more than 1.5 periods apart: the device
  /// did not come back on time. The derived starvation signal, and the only
  /// one available on CoreAudio, where the backend reports no xruns at all.
  final int gapEvents;

  /// Worst callback duration in this window, in microseconds.
  final int maxUs;

  /// Mean callback duration in this window, in microseconds.
  final int meanUs;

  /// Worst entry-to-entry gap in this window, in microseconds; `0` when none
  /// exceeded the 1.5-period threshold.
  final int maxGapUs;

  /// Duration histogram, `LE_CB_BUCKETS` (8) wide. Bucket `i` counts callbacks
  /// whose duration fell in `[i/8, (i+1)/8)` of the period budget; the last
  /// bucket is open-ended and so also holds every over-budget call.
  ///
  /// This is what separates "one huge stall" from "many marginal ones" — the
  /// same [lateCalls] with completely different causes.
  final List<int> buckets;

  /// Real backend dropouts, indexed by [XrunKind.index].
  final List<int> xruns;

  /// Dropouts of [kind] in this window.
  int xrunsOf(XrunKind kind) =>
      kind.index < xruns.length ? xruns[kind.index] : 0;

  /// Every dropout class summed.
  int get xrunTotal => xruns.fold(0, (a, b) => a + b);

  /// Whether anything at all went wrong in this window: a missed deadline, a
  /// starved device, or a backend dropout.
  bool get hasTrouble => lateCalls > 0 || gapEvents > 0 || xrunTotal > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallbackWindowStats &&
          runtimeType == other.runtimeType &&
          calls == other.calls &&
          lateCalls == other.lateCalls &&
          gapEvents == other.gapEvents &&
          maxUs == other.maxUs &&
          meanUs == other.meanUs &&
          maxGapUs == other.maxGapUs &&
          _listEquals(buckets, other.buckets) &&
          _listEquals(xruns, other.xruns);

  @override
  int get hashCode => Object.hash(
    calls,
    lateCalls,
    gapEvents,
    maxUs,
    meanUs,
    maxGapUs,
    Object.hashAll(buckets),
    Object.hashAll(xruns),
  );

  @override
  String toString() =>
      'CallbackWindowStats(calls: $calls, late: $lateCalls, '
      'gaps: $gapEvents, max: ${maxUs}us, mean: ${meanUs}us, '
      'xruns: $xrunTotal)';
}

/// An immutable, lock-free snapshot of the native audio engine's state.
///
/// Published by the engine's audio thread and read by Dart on a render-rate
/// timer. The pure-Dart projection of the native `le_snapshot` struct.
@immutable
class EngineSnapshot {
  /// Creates an [EngineSnapshot] with explicit values.
  const EngineSnapshot({
    required this.isRunning,
    required this.sampleRate,
    required this.bufferFrames,
    required this.framesProcessed,
    required this.xrunCount,
    required this.inputRms,
    required this.inputPeak,
    required this.outputRms,
    required this.latencyState,
    required this.measuredLatencyMs,
    this.devicePresent = false,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.excludedInputMask = 0,
    this.inputClipMask = 0,
    this.inputCondMask = 0,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
    this.recordOffsetFrames = 0,
    this.fxAddedLatencyFrames = 0,
    this.masterGain = 1,
    this.tunerHz = 0,
    this.tunerConfidence = 0,
    this.tunerInput = -1,
    this.activeBackend = AudioBackend.miniaudio,
    this.outputEnabledMask = 0xFFFFFFFF,
    this.isPerfArmed = false,
    this.perfFrames = 0,
    this.perfOverruns = 0,
    this.perfZeroFilledFrames = 0,
    this.perfStopped = false,
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.syncTempo = true,
    this.quantizeDiv = GridDivision.off,
    this.loopBars = 0,
    this.currentBeat = 0,
    this.clickMode = ClickMode.off,
    this.clickMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.countingIn = false,
    this.countInBeatsLeft = 0,
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.callbackBudgetUs = 0,
    this.callbackSession = CallbackWindowStats.empty,
    this.callbackArmed = CallbackWindowStats.empty,
    this.tracks = const [],
  });

  /// The snapshot of an engine that has never started.
  const EngineSnapshot.initial()
    : isRunning = false,
      devicePresent = false,
      sampleRate = 0,
      bufferFrames = 0,
      inputChannels = 0,
      outputChannels = 0,
      excludedInputMask = 0,
      inputClipMask = 0,
      inputCondMask = 0,
      framesProcessed = 0,
      xrunCount = 0,
      inputRms = 0,
      tunerHz = 0,
      tunerConfidence = 0,
      tunerInput = -1,
      inputPeak = 0,
      outputRms = 0,
      latencyState = LatencyState.idle,
      measuredLatencyMs = -1,
      masterLengthFrames = 0,
      masterPositionFrames = 0,
      recordOffsetFrames = 0,
      fxAddedLatencyFrames = 0,
      masterGain = 1,
      activeBackend = AudioBackend.miniaudio,
      outputEnabledMask = 0xFFFFFFFF,
      isPerfArmed = false,
      perfFrames = 0,
      perfOverruns = 0,
      perfZeroFilledFrames = 0,
      perfStopped = false,
      tempoBpm = 0,
      tempoSource = TempoSource.none,
      tsNum = 4,
      tsDen = 4,
      syncTempo = true,
      quantizeDiv = GridDivision.off,
      loopBars = 0,
      currentBeat = 0,
      clickMode = ClickMode.off,
      clickMask = 0,
      clickVolume = 1,
      countInBars = 0,
      countingIn = false,
      countInBeatsLeft = 0,
      looperMode = LooperMode.multi,
      primaryTrack = -1,
      callbackBudgetUs = 0,
      callbackSession = CallbackWindowStats.empty,
      callbackArmed = CallbackWindowStats.empty,
      tracks = const [];

  /// Projects a native `le_snapshot` struct (scalars) plus the already-read
  /// [tracks] into an [EngineSnapshot].
  ///
  /// Tracks are read separately (via `le_engine_get_track`) because this ffi
  /// version cannot index a native struct array.
  factory EngineSnapshot.fromNative(
    le_snapshot native,
    List<TrackSnapshot> tracks,
  ) => EngineSnapshot(
    isRunning: native.running != 0,
    devicePresent: native.device_present != 0,
    sampleRate: native.sample_rate,
    bufferFrames: native.buffer_frames,
    inputChannels: native.input_channels,
    outputChannels: native.output_channels,
    excludedInputMask: native.excluded_input_mask,
    inputClipMask: native.input_clip_mask,
    inputCondMask: native.input_cond_mask,
    framesProcessed: native.frames_processed,
    xrunCount: native.xrun_count,
    inputRms: native.input_rms,
    tunerHz: native.tuner_hz,
    tunerConfidence: native.tuner_confidence,
    tunerInput: native.tuner_input,
    inputPeak: native.input_peak,
    outputRms: native.output_rms,
    latencyState: LatencyState.fromCode(native.latency_state),
    measuredLatencyMs: native.measured_latency_ms,
    masterLengthFrames: native.master_length_frames,
    masterPositionFrames: native.master_position_frames,
    recordOffsetFrames: native.record_offset_frames,
    fxAddedLatencyFrames: native.fx_added_latency_frames,
    masterGain: native.master_gain,
    activeBackend: AudioBackend.fromNative(native.active_backend),
    outputEnabledMask: native.output_enabled_mask,
    isPerfArmed: native.perf_armed != 0,
    perfFrames: native.perf_frames,
    perfOverruns: native.perf_overruns,
    perfZeroFilledFrames: native.perf_zero_filled_frames,
    perfStopped: native.perf_stopped != 0,
    tempoBpm: native.tempo_bpm,
    tempoSource: TempoSource.fromCode(native.tempo_source),
    tsNum: native.ts_num,
    tsDen: native.ts_den,
    syncTempo: native.sync_tempo != 0,
    quantizeDiv: GridDivision.fromCode(native.quantize_div),
    loopBars: native.loop_bars,
    currentBeat: native.current_beat,
    clickMode: ClickMode.fromCode(native.click_mode),
    clickMask: native.click_mask,
    clickVolume: native.click_volume,
    countInBars: native.count_in_bars,
    countingIn: native.counting_in != 0,
    countInBeatsLeft: native.count_in_beats_left,
    looperMode: LooperMode.fromCode(native.looper_mode),
    primaryTrack: native.primary_track,
    callbackBudgetUs: native.cb_budget_us,
    callbackSession: CallbackWindowStats.fromNative(native.cb_session),
    callbackArmed: CallbackWindowStats.fromNative(native.cb_armed),
    tracks: tracks,
  );

  /// Whether the audio device is open and the callback is running.
  final bool isRunning;

  /// Whether the pinned (or default) device is currently present.
  ///
  /// Distinct from [isRunning]: a device can be lost (e.g. unplugged) while the
  /// engine object still reports running until it is restarted. Flips to
  /// `false` on a device-lost / rerouted / interrupted notification.
  final bool devicePresent;

  /// Negotiated device sample rate in Hz.
  final int sampleRate;

  /// Negotiated device period (buffer) size in frames.
  final int bufferFrames;

  /// Negotiated hardware capture channel count.
  final int inputChannels;

  /// Negotiated hardware playback channel count.
  final int outputChannels;

  /// Bitmask of input channels excluded as loopback (never recorded, monitored,
  /// or routable). `0` when nothing is excluded (always so off macOS).
  final int excludedInputMask;

  /// HOT inputs: bit `c` set means a rail-run — `LE_CLIP_RUN` (4) consecutive
  /// raw samples at `|s| >= LE_CLIP_LEVEL` (0.999) — was seen on input `c`
  /// within the last `LE_CLIP_HOLD_MS` (1500 ms) of processed audio.
  ///
  /// Detected on the RAW device buffer, upstream of the conditioning stage,
  /// so a clipped input flags HOT even when the expander/HPF has reshaped
  /// what records. Loopback-excluded inputs never flag.
  final int inputClipMask;

  /// Conditioning activity: bit `c` set means input `c`'s conditioning stage
  /// is currently active — enabled AND not loopback-excluded, i.e. the stage
  /// actually runs on the audio path (the truth for a "conditioning on"
  /// badge; a stage enabled on an excluded channel reads `0` here).
  final int inputCondMask;

  /// Total frames processed by the audio callback since the device started.
  final int framesProcessed;

  /// Device dropouts (xruns) since the device started, as reported by the
  /// backend. The Windows ASIO backend tallies the driver's overload
  /// notifications; the miniaudio backends (macOS / Linux) expose no portable
  /// xrun signal, so this stays `0` there. Monotonic; resets on each start.
  final int xrunCount;

  /// The chromatic tuner's detected fundamental in Hz, or `0` when the armed
  /// input carries no pitch this frame. Always `0` while [tunerInput] is `-1`.
  final double tunerHz;

  /// How periodic the analysed frame was, in `0..1`. Lets a reader hold the
  /// last good note through the gaps between picks rather than flickering.
  final double tunerConfidence;

  /// The hardware input the tuner is armed on, or `-1` when disarmed. Distinct
  /// from a zero [tunerHz]: armed-and-silent and not-armed need different
  /// words on screen.
  final int tunerInput;

  /// Input RMS level for the most recent block, in `0..1`.
  final double inputRms;

  /// Input peak level for the most recent block, in `0..1`.
  final double inputPeak;

  /// Output RMS level for the most recent block, in `0..1`.
  final double outputRms;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in milliseconds, valid only when
  /// [latencyState] is [LatencyState.done]; otherwise `-1` or stale.
  final double measuredLatencyMs;

  /// Master loop length in frames; `0` until the first recording is finalized.
  final int masterLengthFrames;

  /// Current master loop playhead in frames.
  final int masterPositionFrames;

  /// Record-offset latency compensation in frames (auto-set by a measurement).
  final int recordOffsetFrames;

  /// Added latency (frames) of the highest-latency effect engaged in any
  /// audible or monitored lane chain — the maximum across active effects. Today
  /// only the formant-preserving octaver contributes (~21 ms); `0` when no
  /// octaver is engaged. Purely informational (see [fxAddedLatencyMs]); never
  /// feeds [recordOffsetFrames] or any compensation.
  final int fxAddedLatencyFrames;

  /// [fxAddedLatencyFrames] expressed in milliseconds at the current
  /// [sampleRate]; `0` when no effect adds latency or the rate is unknown.
  double get fxAddedLatencyMs =>
      sampleRate > 0 ? fxAddedLatencyFrames * 1000 / sampleRate : 0;

  /// Global master output gain in `0..1`, applied post-mix to the final output.
  /// Unity (`1.0`) by default and after every fresh start.
  final double masterGain;

  /// The device backend actually running (negotiated). Always
  /// [AudioBackend.miniaudio] today; in Part 2 a requested-ASIO open that fell
  /// back reports [AudioBackend.miniaudio] here.
  final AudioBackend activeBackend;

  /// Structural output gate: bit c set => hardware output c is enabled (a
  /// routing target). A cleared bit removes it from the mix while its stored
  /// route masks are preserved (re-enabling restores them). All outputs are
  /// enabled by default; only bits in `[0, outputChannels)` are meaningful.
  /// (The domain-level `LooperState.isOutputEnabled` interprets this bit.)
  final int outputEnabledMask;

  /// Whether performance-recording capture is armed (`AudioEngine.perfArm` /
  /// `AudioEngine.perfDisarm`) — the RT taps are actively copying the master
  /// output (and each captured monitor input) into the capture rings.
  final bool isPerfArmed;

  /// Frames processed since the most recent `AudioEngine.perfArm`, regardless
  /// of any capture ring dropping frames. `0` when never armed.
  final int perfFrames;

  /// Capture frames dropped (a full ring) since the most recent
  /// `AudioEngine.perfArm`. `0` when never armed or nothing has overflowed.
  final int perfOverruns;

  /// Frames of digital silence the capture drain SUBSTITUTED into the take
  /// since the most recent `AudioEngine.perfArm`, summed over every file it
  /// writes.
  ///
  /// Broader than [perfOverruns], which only counts frames the audio thread
  /// could not enqueue: silence also gets written for audio that was counted
  /// but never tapped. Read it as zero vs non-zero — non-zero means the take
  /// contains silence the performer did not play, so the recorder latches it
  /// into the capture's glitch flag alongside [perfOverruns] (#710).
  final int perfZeroFilledFrames;

  /// Whether the capture drain thread stopped ITSELF because a write failed —
  /// disk full, a quota, a read-only remount, an I/O error.
  ///
  /// Distinct from a capture that is simply not armed: this says one WAS armed
  /// and died. Without it the stop was invisible to the app — the capture
  /// stayed armed, its handles stayed open, and finalize never ran (#652).
  final bool perfStopped;

  // ---- tempo grid (A1) ----

  /// Denominator-note beats per minute; `0` when [tempoSource] is
  /// [TempoSource.none] (no tempo ever set).
  final double tempoBpm;

  /// Where [tempoBpm] came from (D7 precedence).
  final TempoSource tempoSource;

  /// Time-signature numerator (default `4`).
  final int tsNum;

  /// Time-signature denominator, `4` or `8` (default `4`).
  final int tsDen;

  /// Whether loop↔grid sync is on (default `true`): finalizing the DEFINING
  /// loop establishes the loop↔grid relationship (bar count / tempo
  /// derivation — see `TempoControl.setSyncTempo`).
  final bool syncTempo;

  /// Musical quantization granularity (default [GridDivision.off]).
  final GridDivision quantizeDiv;

  /// Whole bars in the master loop, or `0` when no grid relationship exists
  /// (sync off, no loop, or the loop predates any grid). The loop's audio
  /// length is never altered by the grid — this is a derived count.
  final int loopBars;

  /// Beat index (`0..tsNum-1`) within the bar: loop-driven, or driven by the
  /// count-in / free-running click; `0` when idle.
  final int currentBeat;

  // ---- click + count-in (A2) ----

  /// Click audibility mode (default [ClickMode.off]).
  final ClickMode clickMode;

  /// Bitmask of hardware output channels the click sounds on (bit c => out
  /// c). Default `0`: no outputs until explicitly routed.
  final int clickMask;

  /// Click volume in `0..LE_MAX_GAIN` (default `1`) — the click's only gain
  /// stage; master gain and the limiter never touch it.
  final double clickVolume;

  /// Count-in length in measures; `0` = off (default).
  final int countInBars;

  /// Whether a count-in is currently running.
  final bool countingIn;

  /// Beat countdown while counting in: the number of count-in beats still to
  /// come, INCLUSIVE of the one currently sounding (a one-bar 4/4 count-in
  /// reads 4, 3, 2, 1, then 0 as the recording starts). `0` when idle.
  final int countInBeatsLeft;

  // ---- looper mode (B2a) ----

  /// The five-mode axis (default [LooperMode.multi]). Locked (rejected,
  /// no-op) while any track has content (D4) — see [LooperMode]'s class doc.
  /// No semantics beyond the field exist yet for the non-multi values.
  final LooperMode looperMode;

  // ---- primary track (B3/B5c, D18) ----

  /// The crowned primary track's channel index, or `-1` when none has ever
  /// been crowned (default). Set by `LooperModeControl.crownPrimary`; only
  /// behaviorally meaningful in Sync/Band, but the designation itself
  /// persists across a clear/undo-to-empty and every mode switch (D18) —
  /// there is no "un-crown" call, so this only ever moves to another
  /// in-range channel, never back to `-1`, once first crowned.
  final int primaryTrack;

  // ---- audio-callback telemetry (#722) ----

  /// The period deadline every callback duration is judged against, in
  /// microseconds — `bufferFrames / sampleRate`. `0` when no device has been
  /// opened, which is also the "telemetry inert" state: nothing is measured.
  final int callbackBudgetUs;

  /// Callback telemetry for the whole device session (reset on every fresh
  /// configure/start, exactly like [xrunCount]).
  final CallbackWindowStats callbackSession;

  /// Callback telemetry since the most recent performance arm.
  ///
  /// Compare against [callbackSession] to answer #722's question — the
  /// difference of the two count fields is the unarmed control. Not cleared by
  /// a disarm, so the numbers survive for a summary read after the fact.
  final CallbackWindowStats callbackArmed;

  /// Per-track snapshots (length == active track count).
  final List<TrackSnapshot> tracks;

  /// The number of tracks.
  int get trackCount => tracks.length;

  TrackSnapshot get _track0 =>
      tracks.isNotEmpty ? tracks.first : const TrackSnapshot.empty();

  /// Track 0 state (back-compat single-track accessor).
  TrackState get trackState => _track0.state;

  /// Track 0 volume (back-compat single-track accessor).
  double get trackVolume => _track0.volume;

  /// Track 0 mute (back-compat single-track accessor).
  bool get trackMuted => _track0.muted;

  /// Track 0 length (back-compat single-track accessor).
  int get trackLengthFrames => _track0.lengthFrames;

  /// Track 0 undo depth (back-compat single-track accessor).
  int get trackUndoDepth => _track0.undoDepth;

  /// Track 0 RMS (back-compat single-track accessor).
  double get trackRms => _track0.rms;

  /// Track 0 peak (back-compat single-track accessor).
  double get trackPeak => _track0.peak;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineSnapshot &&
          runtimeType == other.runtimeType &&
          isRunning == other.isRunning &&
          devicePresent == other.devicePresent &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          excludedInputMask == other.excludedInputMask &&
          inputClipMask == other.inputClipMask &&
          inputCondMask == other.inputCondMask &&
          framesProcessed == other.framesProcessed &&
          xrunCount == other.xrunCount &&
          tunerHz == other.tunerHz &&
          tunerConfidence == other.tunerConfidence &&
          tunerInput == other.tunerInput &&
          inputRms == other.inputRms &&
          inputPeak == other.inputPeak &&
          outputRms == other.outputRms &&
          latencyState == other.latencyState &&
          measuredLatencyMs == other.measuredLatencyMs &&
          masterLengthFrames == other.masterLengthFrames &&
          masterPositionFrames == other.masterPositionFrames &&
          recordOffsetFrames == other.recordOffsetFrames &&
          fxAddedLatencyFrames == other.fxAddedLatencyFrames &&
          masterGain == other.masterGain &&
          activeBackend == other.activeBackend &&
          outputEnabledMask == other.outputEnabledMask &&
          isPerfArmed == other.isPerfArmed &&
          perfFrames == other.perfFrames &&
          perfOverruns == other.perfOverruns &&
          perfZeroFilledFrames == other.perfZeroFilledFrames &&
          perfStopped == other.perfStopped &&
          tempoBpm == other.tempoBpm &&
          tempoSource == other.tempoSource &&
          tsNum == other.tsNum &&
          tsDen == other.tsDen &&
          syncTempo == other.syncTempo &&
          quantizeDiv == other.quantizeDiv &&
          loopBars == other.loopBars &&
          currentBeat == other.currentBeat &&
          clickMode == other.clickMode &&
          clickMask == other.clickMask &&
          clickVolume == other.clickVolume &&
          countInBars == other.countInBars &&
          countingIn == other.countingIn &&
          countInBeatsLeft == other.countInBeatsLeft &&
          looperMode == other.looperMode &&
          primaryTrack == other.primaryTrack &&
          callbackBudgetUs == other.callbackBudgetUs &&
          callbackSession == other.callbackSession &&
          callbackArmed == other.callbackArmed &&
          _listEquals(tracks, other.tracks);

  @override
  int get hashCode => Object.hashAll([
    isRunning,
    devicePresent,
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    excludedInputMask,
    inputClipMask,
    inputCondMask,
    framesProcessed,
    xrunCount,
    inputRms,
    tunerHz,
    tunerConfidence,
    tunerInput,
    inputPeak,
    outputRms,
    latencyState,
    measuredLatencyMs,
    masterLengthFrames,
    masterPositionFrames,
    recordOffsetFrames,
    fxAddedLatencyFrames,
    masterGain,
    activeBackend,
    outputEnabledMask,
    isPerfArmed,
    perfFrames,
    perfOverruns,
    perfZeroFilledFrames,
    perfStopped,
    tempoBpm,
    tempoSource,
    tsNum,
    tsDen,
    syncTempo,
    quantizeDiv,
    loopBars,
    currentBeat,
    clickMode,
    clickMask,
    clickVolume,
    countInBars,
    countingIn,
    countInBeatsLeft,
    looperMode,
    primaryTrack,
    callbackBudgetUs,
    callbackSession,
    callbackArmed,
    ...tracks,
  ]);

  @override
  String toString() =>
      'EngineSnapshot(running: $isRunning, '
      'devicePresent: $devicePresent, '
      'sampleRate: $sampleRate, tracks: $trackCount, '
      'backend: ${activeBackend.name}, '
      'master: $masterPositionFrames/$masterLengthFrames, '
      'latency: ${latencyState.name}/$measuredLatencyMs ms)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
