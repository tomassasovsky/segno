import 'package:flutter/foundation.dart';
import 'package:looper_repository/src/models/fx_chain_envelope.dart';
import 'package:looper_repository/src/models/input_monitor.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/output_setup.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:segno_engine/segno_engine.dart' show LooperMode, RecordTiming;

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
    this.pan = 0,
    this.recordTiming,
    this.overdubDecay,
  });

  /// The track's Mixer pan (slice 3), `-1..1`.
  final double pan;

  /// Track channel index.
  final int channel;

  /// The track's lanes, each with its own audio, routing, and mix. Lane 0 is
  /// first — it is the primary import that resets the track's undo state.
  final List<SessionRigLane> lanes;

  /// The track's record timing override (slice 2b); `null` = follows the
  /// default. Restored on session load.
  final RecordTiming? recordTiming;

  /// The track's overdub decay override in percent (slice 2b); `null` =
  /// follows the default. Restored on session load like [recordTiming].
  final int? overdubDecay;
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
    this.masterChain = const FxChainEnvelope(),
    this.monitors = const [],
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.lengthPresetOverrides = const {},
    this.onceOverrides = const {},
    this.recordTiming,
    this.overdubDecay,
    this.inputSetup = const InputSetup(),
    this.outputSetup = const OutputSetup(),
  });

  /// The session's DEFAULT record timing (slice 2b); `null` leaves the live
  /// default alone.
  ///
  /// Session-level, beside [SessionRigTrack.recordTiming], which overrides it
  /// per track. Restoring the overrides without the default they override
  /// would leave a track that follows the default on whatever the app was
  /// last set to.
  final RecordTiming? recordTiming;

  /// The session's DEFAULT overdub decay in percent (slice 2b); `null` leaves
  /// the live default alone. Session-level, like [recordTiming].
  final int? overdubDecay;

  /// The per-input capture setup the session was saved with (slice 3):
  /// trims, pans and pairs. Restored on apply; the monitors' pans follow it.
  final InputSetup inputSetup;

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

  /// The session's single Master insert chain; the empty enabled envelope when
  /// it defines none (a v4-or-earlier manifest always does).
  final FxChainEnvelope masterChain;

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

  /// Every channel's length preset override (A6, slice 2c), keyed by
  /// channel: `0` = an explicit Auto, `1..64` = a fixed bar count; a channel
  /// absent here follows the default. Session-level rather than on
  /// [SessionRigTrack], since a channel can carry an override with no
  /// content (nothing recorded on it yet) and would have no track entry to
  /// ride on. Restored on session load; it only governs a FUTURE defining
  /// recording, so it is inert for the audio the load just imported.
  final Map<int, int> lengthPresetOverrides;

  /// Every channel's Loop/Once override (song-mode-spec.md §2, B5c; slice
  /// 2c), keyed by channel: `true` = plays once then stops, `false` = loops;
  /// a channel absent here follows the default. Session-level for the same
  /// reason as [lengthPresetOverrides]. Restored on session load — see
  /// `LooperRepository.applySession`'s reset-then-restore handling.
  final Map<int, bool> onceOverrides;
}
