import 'package:flutter/foundation.dart';
import 'package:looper_repository/src/models/fx_chain_envelope.dart';
import 'package:looper_repository/src/models/input_monitor.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/output_setup.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:segno_engine/segno_engine.dart'
    show ClickMode, GridDivision, LooperMode, RecordTiming, TempoSource;

/// One lane's restored audio, routing, and mix inside a [SessionRigTrack].
///
/// Carries the lane's ordered audio [layers] (part 1 restores one live buffer;
/// the undo/redo layers are a later revision) plus its routing/mix. [liveIndex]
/// (== [undoCount]) selects the currently playing buffer.
@immutable
class SessionRigLane {
  /// Creates a [SessionRigLane].
  const SessionRigLane({
    required this.lane,
    required this.layers,
    required this.volume,
    required this.muted,
    required this.outputMask,
    required this.inputChannel,
    this.pan = 0,
    this.balance = 1,
    this.undoCount = 0,
    this.redoCount = 0,
  });

  /// The lane's recorded image (slice 3): where its input sat when the take
  /// started, before the track's own pan (`Lane.imagePan`).
  final double pan;

  /// The gain the input pair's balance gave the lane's side when the take
  /// started, `0..1` (`Lane.balance`); [volume] is the level.
  final double balance;

  /// Lane index within the track.
  final int lane;

  /// The lane's mono audio buffers, oldest undo → live → newest redo.
  final List<Float32List> layers;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Bitmask of output channels this lane plays to (bit c => output c).
  final int outputMask;

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// Number of leading [layers] that are undo snapshots.
  final int undoCount;

  /// Number of trailing [layers] that are redo snapshots.
  final int redoCount;

  /// Index into [layers] of the live (currently playing) buffer.
  int get liveIndex => undoCount;

  /// The lane's live (currently playing) buffer.
  Float32List get livePcm => layers[liveIndex];
}

/// One track's restored lanes inside a [SessionRig].
@immutable
class SessionRigTrack {
  /// Creates a [SessionRigTrack].
  const SessionRigTrack({
    required this.channel,
    required this.lanes,
  });

  /// Track channel index.
  final int channel;

  /// The track's lanes, each with its own audio, routing, and mix. Lane 0 is
  /// first — it is the primary import that resets the track's undo state.
  final List<SessionRigLane> lanes;
}

/// One hardware input's live-monitor configuration inside a [SessionRig] —
/// the Input stage of the four-stage FX model.
@immutable
class SessionRigMonitor {
  /// Creates a [SessionRigMonitor].
  const SessionRigMonitor({
    required this.input,
    required this.mode,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.effects,
    this.chainEnabled = true,
  });

  /// Hardware input index.
  final int input;

  /// What the session asks this input's monitor to do.
  final MonitorMode mode;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above
  /// unity).
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor's effect chain (empty = the clean/dry path).
  final List<TrackEffect> effects;

  /// Whether the monitor's WHOLE chain is engaged (R15). `true` for a
  /// v4-or-earlier manifest — migration defaults every level to enabled.
  final bool chainEnabled;
}

/// Everything a saved session defines, expressed in looper-domain types.
///
/// The bloc layer builds this from a decoded session manifest and hands it to
/// `LooperRepository.applySession` — the ONE session-apply path — so the
/// repositories stay decoupled (a repository never imports a repository).
/// Chains the rig does NOT define are explicitly reset on apply: a legacy
/// manifest with no chains loads as "all chains cleared", never "whatever was
/// lying around".
///
/// Every one of the four FX stages travels here as a decoded
/// [FxChainEnvelope] — entries plus the chain-enabled flag plus (for the Loop
/// stage) inheritance provenance — because those flags live INSIDE the
/// manifest's opaque chain string, not in manifest fields of their own (R15).
/// The Input stage is the exception in shape only: a monitor already carries
/// routing/mix, so its chain rides [SessionRigMonitor.effects] +
/// [SessionRigMonitor.chainEnabled] rather than a nested envelope.
///
/// A transient apply-time DTO (built once from a decoded bundle, consumed once
/// by `LooperRepository.applySession`); it is immutable but carries no value
/// equality by design — it is never compared, only applied.
@immutable
class SessionRig {
  /// Creates a [SessionRig].
  const SessionRig({
    this.baseLengthFrames = 0,
    this.tracks = const [],
    this.laneChains = const {},
    this.trackChains = const {},
    this.outputChains = const {},
    this.allTracksChain = const FxChainEnvelope(),
    this.monitors = const [],
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.recordTiming = RecordTiming.immediately,
    this.overdubDecay = 0,
    this.defaultOneShot = false,
    this.defaultLengthPresetBars = 0,
    this.defaultMultiple = 0,
    this.trackRecordTimingOverrides = const {},
    this.trackOverdubDecayOverrides = const {},
    this.trackOneShotOverrides = const {},
    this.trackLengthPresetOverrides = const {},
    this.loopBars = 0,
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.syncTempo = true,
    this.quantizeDiv = GridDivision.off,
    this.clickMode = ClickMode.off,
    this.clickMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.recDub = false,
    this.autoRecord = false,
    this.inputSetup = const InputSetup.empty(),
    this.laneInputs = const {},
    this.laneOutputs = const {},
    this.laneCounts = const {},
    this.trackLevels = const {},
    this.trackPans = const {},
    this.outputSetup = const OutputSetup(),
  });

  /// Whole-track gain intent, including tracks without recorded audio.
  final Map<int, double> trackLevels;

  /// Track pan intent, including tracks without recorded audio.
  final Map<int, double> trackPans;

  /// Default recording timing, shared by tracks with no override.
  final RecordTiming recordTiming;

  /// Default decay percentage.
  final int overdubDecay;

  /// Default playback: Once when true, Loop when false.
  final bool defaultOneShot;

  /// Default length for future recordings: zero is Auto, otherwise bars.
  final int defaultLengthPresetBars;

  /// Default future recording length (`0` = Auto).
  final int defaultMultiple;

  /// Explicit timing overrides, independent of whether a track has audio.
  final Map<int, RecordTiming> trackRecordTimingOverrides;

  /// Explicit decay overrides; missing entries inherit the default.
  final Map<int, int> trackOverdubDecayOverrides;

  /// Explicit playback overrides; custom false values are retained.
  final Map<int, bool> trackOneShotOverrides;

  /// Future recording length presets, independent of recorded audio.
  final Map<int, int> trackLengthPresetOverrides;

  /// Saved musical tempo; zero means no tempo was established.
  final double tempoBpm;

  /// Exact musical grid span; zero means no established grid.
  final int loopBars;

  /// Origin of the saved musical tempo.
  final TempoSource tempoSource;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// Whether recorded loops follow the musical grid.
  final bool syncTempo;

  /// Grid subdivision retained even when quantization is disabled.
  final GridDivision quantizeDiv;

  /// Click playback condition.
  final ClickMode clickMode;

  /// Click destination channel mask.
  final int clickMask;

  /// Click gain.
  final double clickVolume;

  /// Count-in bars; exclusive with sound-activated start.
  final int countInBars;

  /// Whether completing a take enters overdub.
  final bool recDub;

  /// Whether an armed take waits for sound.
  final bool autoRecord;

  /// The per-input capture setup the session was saved with (slice 3):
  /// trims, pans and pairs. Restored on apply; the monitors' pans follow it.
  final InputSetup inputSetup;

  /// Content-independent future source assignments, including empty tracks.
  final Map<(int, int), int> laneInputs;

  /// Content-independent playback routes, including future lane slots.
  final Map<(int, int), int> laneOutputs;

  /// Active source lane counts, including tracks without captured PCM.
  final Map<int, int> laneCounts;

  /// The output setup the session was saved with (slice 3b): every
  /// destination's level, mute, Stereo/Mono and balance. Restored on apply.
  final OutputSetup outputSetup;

  /// The base (master) loop length in frames; `0` for an empty session.
  final int baseLengthFrames;

  /// The tracks holding audio, with their restored mix.
  final List<SessionRigTrack> tracks;

  /// Every Loop-stage (per-lane) chain the session defines, keyed by
  /// `(channel, lane)`. Chains exist independently of audio, so keys may
  /// reference tracks with no [tracks] entry.
  final Map<(int, int), FxChainEnvelope> laneChains;

  /// Every Track-stage (per-track stereo bus) chain the session defines, keyed
  /// by track channel. Empty for a v4-or-earlier manifest, which could not
  /// describe this stage — and an absent channel is RESET on apply, not left
  /// carrying the previous session's bus chain (R17).
  final Map<int, FxChainEnvelope> trackChains;

  /// Every output destination's post-sum chain the session defines, keyed by
  /// bus (slice 3f). An absent destination is RESET on apply rather than left
  /// carrying the previous session's chain, like [trackChains].
  final Map<int, FxChainEnvelope> outputChains;

  /// The session's single All tracks recorded-mix chain (slice 3e); the empty
  /// enabled envelope when it defines none (every v7-or-earlier manifest).
  final FxChainEnvelope allTracksChain;

  /// The per-input live monitors (Input stage) the session defines.
  final List<SessionRigMonitor> monitors;

  /// The session's looper mode (schema v4, B5c). Restored unconditionally on
  /// apply, like [baseLengthFrames] — a session with no tracks still carries a
  /// mode choice.
  final LooperMode looperMode;

  /// The session's crowned primary track (D18), or `-1` when the session
  /// saved none. Pushed as the explicit crown on apply; a session without one
  /// gets the engine's own crown (its lowest recorded track) once the import
  /// commits.
  final int primaryTrack;
}
