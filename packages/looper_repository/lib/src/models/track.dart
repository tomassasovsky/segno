import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:segno_engine/segno_engine.dart' hide TrackEffect;

/// What a pending arm waits for — the engine's own account of the boundary,
/// so the stage names it instead of guessing from the settings.
enum ArmTrigger {
  /// The quantize grid: the next loop top, or the chosen subdivision.
  grid,

  /// A signal at the recording input (Sound start).
  sound,

  /// A Band section toggle at the primary's loop top.
  section;

  /// Decodes the snapshot's `pending_trigger` code; `null` for none.
  static ArmTrigger? fromCode(int code) => switch (code) {
    0 => ArmTrigger.grid,
    1 => ArmTrigger.sound,
    2 => ArmTrigger.section,
    _ => null,
  };
}

/// A single looper track: a multi-lane container that owns the transport
/// (state, loop multiple, undo/redo depth) and its [lanes].
///
/// The scalar [volume]/[muted]/[inputMask]/[outputMask] fields mirror lane 0
/// so existing single-lane callers (the channel strip, the routing graph) keep
/// working; full per-lane state lives in [lanes]. [peak] is the exception: it
/// is the whole track's mixed level, not lane 0's (#655).
class Track extends Equatable {
  /// Creates a [Track].
  const Track({
    this.channel = 0,
    this.state = TrackState.empty,
    this.volume = 1,
    this.muted = false,
    this.lengthFrames = 0,
    this.peak = 0,
    this.undoDepth = 0,
    this.clearRestore = false,
    this.redoDepth = 0,
    this.multiple = 1,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.layerInFlight = false,
    this.pending = false,
    this.pendingTrigger,
    this.positionFrames = 0,
    this.lengthPresetBars = 0,
    this.lengthPresetOverride,
    this.oneShotOverride,
    this.recordTimingOverride,
    this.overdubDecayOverride,
    this.oneShot = false,
    this.lanes = const [],
    this.effects = const [],
    this.chainEnabled = true,
  });

  /// Track channel index (always 0 in the single-track phase).
  final int channel;

  /// Current state-machine phase.
  final TrackState state;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Captured length in frames (equals the master loop once finalized).
  final int lengthFrames;

  /// Peak level of the track's mixed output for the most recent block, in
  /// `0..1` — the one field that changes at the poll rate while audio flows.
  /// Kept out of [steadyProps] for that reason.
  final double peak;

  /// Available undo steps (overdub layers).
  ///
  /// A cleared track reports 0 here even though the erased take's layers are
  /// still held: they are not peelable until the clear itself is undone.
  /// See [clearRestore].
  final int undoDepth;

  /// Whether the next undo restores a cleared take rather than peeling a layer.
  final bool clearRestore;

  /// Available redo steps.
  final int redoDepth;

  /// Whether an overdub undo layer is still being captured or drained (the
  /// punch-tail window). Session capture waits this out before exporting.
  final bool layerInFlight;

  /// Whether a quantized/signal-triggered record arm is waiting to fire.
  final bool pending;

  /// What that arm waits for, or `null` while nothing is pending.
  final ArmTrigger? pendingTrigger;

  /// This track's own playhead in frames within [lengthFrames] — the engine
  /// has already applied the mode's position rule (a multiple's segment, a
  /// Sync division's folded phase, a Free/Song track's private clock), so
  /// [progress] is the track's own progress. While recording it is the write
  /// head instead. `0` for an empty track.
  ///
  /// Moves at the poll rate while the track plays, like [peak], and is kept
  /// out of [steadyProps] for the same reason: the progress bar subscribes
  /// to it in its own leaf.
  final int positionFrames;

  /// Track length in whole base loops (`>= 1`); `> 1` for a loop multiple.
  final int multiple;

  /// The DEFINING-recording length preset (A6, D17): `0` = AUTO, `1..64` =
  /// fixed N bars. Inert on a track that already has content; applies to the
  /// next defining recording only. See `LooperRepository.setTrackLengthPreset`.
  final int lengthPresetBars;

  /// This track's length preset override (accepted design, Length &
  /// quantize): `null` follows the default, `0` is an explicit Auto, else a
  /// fixed bar count. [lengthPresetBars] is what the engine holds (the
  /// effective preset). Cached like [recordTimingOverride]. Stored but
  /// inactive in Multi, where every track shares the default.
  final int? lengthPresetOverride;

  /// This track's Loop/Once override (accepted design, Playback & overdub):
  /// `null` follows the default, `true` plays once then stops, `false`
  /// loops. [oneShot] is what the engine holds. Cached like
  /// [recordTimingOverride].
  final bool? oneShotOverride;

  /// This track's record timing override (accepted design, Length &
  /// quantize): `null` follows the default in full, else the timing this
  /// track's own record and overdub requests wait for. A custom value equal
  /// to the current default stays custom, so later default changes do not
  /// reach it.
  ///
  /// Projected from the repository's own re-apply cache rather than from the
  /// engine snapshot, like `primaryTrack` and the FX chains: the cache is
  /// what the repository re-applies on every (re)start, so it holds the
  /// answer while the engine is stopped too. Carried here rather than read
  /// through a getter so a surface that shows the override is refreshed by
  /// the same stream as everything else it draws — including on a session
  /// load, which sets the overrides with no user gesture to hang a re-read
  /// off.
  final RecordTiming? recordTimingOverride;

  /// The quantize gate this track's override amounts to: `null` inherits the
  /// global gate, `false` forces the press immediate, `true` forces it to
  /// wait. What the older three-way surfaces read; [recordTimingOverride] is
  /// the full setting.
  bool? get quantizeOverride => recordTimingOverride?.quantize;

  /// This track's overdub decay override in percent (`0..100`; accepted
  /// design, Playback & overdub): `null` follows the default. Each overdub
  /// pass keeps `1 - decay / 100` of the existing layer before adding the
  /// new input; `0` keeps it all. Cached like [recordTimingOverride].
  final int? overdubDecayOverride;

  /// One Shot (song-mode-spec.md §2, B5c): `true` = this track plays once and
  /// then stops instead of looping. Settable in any looper mode, but only
  /// behaviorally active in Free/Song. See `LooperRepository.setOneShot`.
  final bool oneShot;

  /// Lane 0's recorded input as a bitmask (`1 << inputChannel`, or `0` when
  /// lane 0 records no input). Mirrors lane 0; per-lane inputs are in [lanes].
  final int inputMask;

  /// Bitmask of hardware output channels this track plays to (bit c => out c).
  /// Mirrors lane 0.
  final int outputMask;

  /// The track's lanes, in lane order. Each records one input into its own
  /// clean buffer; empty in synthetic/default tracks.
  final List<Lane> lanes;

  /// The track's stereo-bus (Track-stage) effects chain, in processing order —
  /// downstream of the per-lane chains (FX v3 part 1b). Empty == the engine's
  /// bit-identical per-lane routing path.
  final List<TrackEffect> effects;

  /// Whether the Track-stage chain is engaged (R15). Disabled == dry through
  /// the bus (NOT a return to per-lane routing; only emptying the chain does
  /// that).
  final bool chainEnabled;

  /// Whether this track spans more than one base loop.
  bool get isMultiple => multiple > 1;

  /// Whether the track holds recorded audio.
  bool get hasContent => state != TrackState.empty && lengthFrames > 0;

  /// Whether the track is actively capturing (recording or overdubbing).
  bool get isCapturing =>
      state == TrackState.recording || state == TrackState.overdubbing;

  /// Whether undo would do anything: peel an overdub layer, or put back a take
  /// the user cleared.
  bool get canUndo => undoDepth > 0 || clearRestore;

  /// Whether an undone overdub layer can be redone.
  bool get canRedo => redoDepth > 0;

  /// Normalized play position in `0..1`; `0` while the track has no length or
  /// is still recording its take (the engine publishes the growing write head
  /// as both position and length then, which is no position at all).
  double get progress => lengthFrames > 0 && state != TrackState.recording
      ? (positionFrames / lengthFrames).clamp(0.0, 1.0)
      : 0;

  /// Layers the performer hears: the base take plus every retired overdub
  /// pass. The base loop is not an engine undo layer (`undoDepth` counts
  /// retired passes only), but it is a layer, so it counts as the first.
  int get layers => undoDepth + (hasContent ? 1 : 0);

  /// Everything in [props] EXCEPT the live [peak] level and [positionFrames].
  ///
  /// Those two are the fields that change at the poll rate on a track that is
  /// merely playing, so they are the only ones that have to be subscribed at
  /// meter granularity. A surface that draws the tile AROUND a meter compares
  /// on
  /// this, and subscribes to [peak] separately in the meter leaf itself, so a
  /// moving level rebuilds the bar and nothing else (#646/#654/#832).
  ///
  /// This is the ONLY sanctioned way to ignore a moving level. Anything that
  /// wants a peak-insensitive comparison — a `context.select` projection, a
  /// `buildWhen`, a push gate on the second screen — compares on this rather
  /// than editing [props]; see the warning there.
  ///
  /// Listed out rather than derived from [props] so neither list is built
  /// twice per comparison (a `Track ==` is on the console's hot path). The
  /// two are locked to each other by a test — `props` is exactly this list
  /// plus [peak] and [positionFrames] — so a field added to one cannot
  /// silently miss the other.
  ///
  /// "Steady" means steady against a moving LEVEL, and nothing more — two
  /// other fields here move on their own, both deliberately left in:
  ///
  /// - A track that is RECORDING differs on every poll tick as [lengthFrames]
  ///   (and the recording lane's own) grow with the take. That is one tile
  ///   rebuilding while it records, not eight rebuilding because one of them
  ///   made a noise, so it is left alone — the tile draws `hasContent`, which
  ///   the growing length flips exactly once (#899).
  /// - [lanes] carries `Lane.cacheState`, which follows the background
  ///   renderer while `CacheTelemetryScope` enables telemetry: the Signal
  ///   face is visible and the track-indicator preference is on. Those
  ///   observed cache changes also rebuild the tile; closing Signal or
  ///   disabling indicators stops the telemetry reads.
  List<Object?> get steadyProps => [
    channel,
    state,
    volume,
    muted,
    lengthFrames,
    undoDepth,
    clearRestore,
    redoDepth,
    multiple,
    inputMask,
    outputMask,
    layerInFlight,
    pending,
    pendingTrigger,
    lengthPresetBars,
    lengthPresetOverride,
    oneShotOverride,
    recordTimingOverride,
    overdubDecayOverride,
    oneShot,
    lanes,
    effects,
    chainEnabled,
  ];

  /// Value equality over every field, [peak] and [positionFrames] INCLUDED —
  /// deliberately, and load-bearing.
  ///
  /// **Do not remove [peak] (or [positionFrames]) from this list.** The meters
  /// are fed through
  /// `LooperState ==`: `LooperRepository`'s poll drops a projection equal to
  /// the one before it (`if (next == _last) return`), so a field outside
  /// equality is a field that never reaches the UI at all. Taking [peak] out
  /// — tempting, because it is what makes a fresh `LooperState` arrive on
  /// every poll tick and so defeats any gate written as
  /// `identical(state, previous)` — would flatten all eight meters with no
  /// error and no failing widget test: they would simply stop moving.
  ///
  /// A caller that needs to ignore the moving level compares [steadyProps]
  /// instead. Locked by the tests in `test/models/track_test.dart`.
  @override
  List<Object?> get props => [
    channel,
    state,
    volume,
    muted,
    lengthFrames,
    undoDepth,
    clearRestore,
    redoDepth,
    multiple,
    inputMask,
    outputMask,
    layerInFlight,
    pending,
    pendingTrigger,
    lengthPresetBars,
    lengthPresetOverride,
    oneShotOverride,
    recordTimingOverride,
    overdubDecayOverride,
    oneShot,
    lanes,
    effects,
    chainEnabled,
    peak,
    positionFrames,
  ];
}
