import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:segno_engine/segno_engine.dart' hide TrackEffect;

/// What a pending arm waits for — the engine's own account of the boundary,
/// so the stage names it instead of guessing from the settings.
enum ArmTrigger {
  /// The quantize grid: the next loop top, or the chosen subdivision.
  grid,

  /// A signal at the recording input (Sound start).
  sound,

  /// A Band section toggle at the primary's loop top.
  section,

  /// A Song or Band Record waiting for the sounding section's end (#1323).
  handoff;

  /// Decodes the snapshot's `pending_trigger` code; `null` for none.
  static ArmTrigger? fromCode(int code) => switch (code) {
    0 => ArmTrigger.grid,
    1 => ArmTrigger.sound,
    2 => ArmTrigger.section,
    3 => ArmTrigger.handoff,
    _ => null,
  };
}

/// A single looper track: a multi-lane container that owns the transport
/// (state, loop multiple, undo/redo depth) and its [lanes].
///
/// The scalar [volume]/[muted]/[inputMask]/[outputMask] fields mirror lane 0
/// so existing single-lane callers (the channel strip, the routing graph) keep
/// working; full per-lane state lives in [lanes]. Live levels are not here:
/// they arrive on `LooperRepository.meterLevels` (#1301).
class Track extends Equatable {
  /// Creates a [Track].
  const Track({
    this.channel = 0,
    this.state = TrackState.empty,
    this.volume = 1,
    this.fade = const FadeImage(),
    this.reversed = false,
    this.transpose = (stored: 0, effective: 0),
    this.followTempoOverride,
    this.pitchModeOverride,
    this.pitchEffectiveCents = 0,
    this.muted = false,
    this.pan = 0,
    this.solo = false,
    this.lengthFrames = 0,
    this.undoDepth = 0,
    this.clearRestore = false,
    this.redoDepth = 0,
    this.peelDepth = 0,
    this.multiple = 1,
    this.syncDivisor = 0,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.layerInFlight = false,
    this.pending = false,
    this.pendingLaunch,
    this.pendingTrigger,
    this.lengthPresetBars = 0,
    this.lengthPresetOverride,
    this.recordTimingOverride,
    this.overdubDecayOverride,
    this.oneShot = false,
    this.oneShotOverride,
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

  /// Native Fade image, separate from saved Mixer gain.
  final FadeImage fade;

  /// Whether the track reads its recorded material backward (Reverse,
  /// #1162): a callback-owned performance transform like [fade], never an
  /// audio edit. Toggled by `LooperRepository.toggleReverse`; reset to forward
  /// with the material. A reversed track refuses punch-ins
  /// (`EngineResult.reversed`).
  final bool reversed;

  /// The track's Transpose (#1179): `stored` is the pitch the player set,
  /// `effective` the pitch sounding — 0 while the render is pending or
  /// refused and while Transpose is bypassed (`LooperState.transposeBypass`),
  /// so a face shows the wait instead of claiming a pitch. Stepped by
  /// `LooperRepository.transposeTrack`; reset to 0 with the material. A track
  /// with a stored pitch refuses punch-ins (`EngineResult.transformed`) unless
  /// Transpose is bypassed, its render pending or not.
  final TransposePitch transpose;

  /// This track's Follow tempo override (#1179); null inherits
  /// `LooperState.defaultFollowTempo`. The repository's accepted setting.
  final bool? followTempoOverride;

  /// This track's Pitch override (#1179); null inherits
  /// `LooperState.defaultPitchMode`.
  final PitchMode? pitchModeOverride;

  /// The pitch a tempo retime puts on what the track sounds now, in cents
  /// (#1179): 0 at its own tempo or once its time-stretched render plays;
  /// the tempo ratio's shift while that render is pending, or with Pitch
  /// following the speed. Speed and Transpose are not included.
  final int pitchEffectiveCents;

  /// Whether the track is muted.
  final bool muted;

  /// The track's pan, `-1` (left) .. `1` (right) (accepted design, Mixer).
  /// Offsets every lane's recorded image; see `LooperRepository.setTrackPan`.
  final double pan;

  /// Whether the track is soloed: while any track is, only soloed tracks
  /// route. Independent of [muted].
  final bool solo;

  /// Captured length in frames, including divisions and independent takes.
  final int lengthFrames;

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

  /// Overdub layers Peel can still remove: the layers above the newest
  /// history entry that is neither an overdub nor a peel. 0 on an empty or
  /// cleared track. The original take is never counted: Peel stops at it.
  final int peelDepth;

  /// Whether an overdub undo layer is still being captured or drained (the
  /// punch-tail window). Session capture waits this out before exporting.
  final bool layerInFlight;

  /// Whether a quantized/signal-triggered record arm is waiting to fire.
  final bool pending;

  /// This track’s action waiting for the shared Count-in downbeat.
  final PendingLaunchAction? pendingLaunch;

  /// What that arm waits for, or `null` while nothing is pending.
  final ArmTrigger? pendingTrigger;

  /// Track length in whole base loops (`>= 1`); `> 1` for a loop multiple.
  final int multiple;

  /// A Sync/Band division of the base loop (`2` or `4`), else `0`.
  final int syncDivisor;

  /// The DEFINING-recording length preset (A6, D17): `0` = AUTO, `1..64` =
  /// fixed N bars. Inert on a track that already has content; applies to the
  /// next defining recording only. See `LooperRepository.setTrackLengthPreset`.
  final int lengthPresetBars;

  /// Explicit future-recording length: null inherits, zero is Custom Auto.
  final int? lengthPresetOverride;

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

  /// Effective playback choice in every mode: `true` finishes the current
  /// pass and stops this track; `false` keeps looping.
  final bool oneShot;

  /// Playback override: `null` follows the shared default. Explicit Loop
  /// (`false`) remains custom even when the default is also Loop.
  final bool? oneShotOverride;

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

  /// Whether the track's loop plays back, muted or not (playing or
  /// overdubbing).
  bool get isRunning =>
      state == TrackState.playing || state == TrackState.overdubbing;

  /// Whether undo would do anything: peel an overdub layer, or put back a take
  /// the user cleared.
  bool get canUndo => undoDepth > 0 || clearRestore;

  /// Whether an undone overdub layer can be redone.
  bool get canRedo => redoDepth > 0;

  /// Whether Peel would remove a layer right now: one remains above the
  /// original, and the track is not capturing, draining a layer or waiting
  /// for a Count-in launch (the engine refuses those, so the LED stays off).
  bool get canPeel =>
      peelDepth > 0 && !isCapturing && !layerInFlight && pendingLaunch == null;

  /// Layers the performer hears: the base take plus every overdub pass still
  /// stacked on it. Derived from [peelDepth], not [undoDepth]: a peel removes
  /// a layer while leaving a history entry behind, so the undo depth stays
  /// constant as the audible layer count drops. The base loop is not an
  /// engine history entry, but it is a layer, so it counts as the first.
  int get layers => peelDepth + (hasContent ? 1 : 0);

  /// Completed take length in whole bars, or `null` without a known whole
  /// musical length. Recording growth never establishes a completed count.
  ///
  /// The engine's established master grid divides the recorded audio exactly,
  /// even when the nominal BPM differs. Without that grid, [sampleRate] and
  /// denominator-note BPM determine the duration of [TransportState.tsNum]
  /// beats. One frame of rounding is allowed; fractional bars remain unknown.
  int? wholeBars({
    required TransportState transport,
    required int sampleRate,
  }) {
    final perBeat = _framesPerBeat(transport, sampleRate);
    if (perBeat == null || transport.tsNum <= 0) return null;
    return _whole(perBeat * transport.tsNum);
  }

  /// Completed take length in whole beats (denominator notes), or `null`
  /// without a known whole count, on the same grid as [wholeBars]. A Divide
  /// of a sole 1-bar loop leaves 2 beats and no whole bar (#1168).
  int? wholeBeats({
    required TransportState transport,
    required int sampleRate,
  }) {
    final perBeat = _framesPerBeat(transport, sampleRate);
    return perBeat == null ? null : _whole(perBeat);
  }

  /// One beat in frames: the master grid's own when it exists, else the
  /// nominal tempo's; null without either.
  double? _framesPerBeat(TransportState transport, int sampleRate) {
    if (!hasContent || state == TrackState.recording) return null;
    if (transport.masterLengthFrames > 0 && transport.loopBeats > 0) {
      return transport.masterLengthFrames / transport.loopBeats;
    }
    if (transport.masterLengthFrames > 0 &&
        transport.loopBars > 0 &&
        transport.tsNum > 0) {
      return transport.masterLengthFrames /
          (transport.loopBars * transport.tsNum);
    }
    if (sampleRate <= 0 ||
        transport.tempoSource == TempoSource.none ||
        !transport.tempoBpm.isFinite ||
        transport.tempoBpm <= 0) {
      return null;
    }
    return sampleRate * 60 / transport.tempoBpm;
  }

  /// [lengthFrames] in whole [unit]s within a frame of rounding, else null.
  int? _whole(double unit) {
    final count = lengthFrames / unit;
    if (!count.isFinite) return null;
    final whole = count.round();
    return whole > 0 && (lengthFrames - whole * unit).abs() <= 1 ? whole : null;
  }

  @override
  List<Object?> get props => [
    channel,
    state,
    volume,
    fade,
    reversed,
    transpose,
    followTempoOverride,
    pitchModeOverride,
    pitchEffectiveCents,
    muted,
    pan,
    solo,
    lengthFrames,
    undoDepth,
    clearRestore,
    redoDepth,
    peelDepth,
    multiple,
    syncDivisor,
    inputMask,
    outputMask,
    layerInFlight,
    pending,
    pendingLaunch,
    pendingTrigger,
    lengthPresetBars,
    lengthPresetOverride,
    recordTimingOverride,
    overdubDecayOverride,
    oneShot,
    oneShotOverride,
    lanes,
    effects,
    chainEnabled,
  ];
}
