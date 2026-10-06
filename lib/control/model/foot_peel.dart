import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The accepted Peel action vocabulary, shared by display and dispatch.
enum FootPeelAction {
  /// Advance recording on the normal transport cursor.
  recordPlay,

  /// Stop recorded tracks; layers are kept.
  stop,

  /// Return to normal Tracks.
  exit,

  /// Remove the newest overdub layer of the slot's track.
  peelTrack,

  /// Show the other four tracks.
  nextBank,

  /// No meaning in this mode (Undo and Clear): a stray stomp edits nothing.
  none,
}

/// Why a Peel did not remove a layer. Every refused track press says which.
enum FootPeelRefusal {
  /// The track holds no recording.
  empty,

  /// Only the original take remains: there is no overdub to remove.
  originalOnly,

  /// The track is recording, finishing a pass or waiting for its Count-in.
  busy,

  /// The engine refused for another reason.
  failed,
}

/// One physical pedal's semantics. Every Peel action fires on contact; the
/// mode has no holds.
class FootPeelPedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootPeelPedal(this.press, {this.slot});

  /// The action at contact.
  final FootPeelAction press;

  /// Visible track slot, resolved against the bank when the action fires.
  final int? slot;
}

/// One track's published layers.
class FootPeelTrack extends Equatable {
  /// Creates a read of current repository facts.
  const FootPeelTrack({
    required this.channel,
    required this.hasContent,
    required this.layers,
    required this.busy,
  });

  /// Absolute zero-based channel.
  final int channel;

  /// Whether the track holds a recording. A busy recorded track still has
  /// content: it reads its real layer count, never "Empty".
  final bool hasContent;

  /// Layers the performer hears, the original included (`Track.layers`).
  final int layers;

  /// Whether the track is capturing, finishing a pass or waiting for its
  /// Count-in launch: the engine refuses a Peel until that ends.
  final bool busy;

  /// Whether a Peel would remove a layer now (`Track.canPeel`).
  bool get available => hasContent && !busy && layers > 1;

  /// Why a Peel on this track would be refused now, or null when it would
  /// run.
  FootPeelRefusal? get refusal => !hasContent
      ? FootPeelRefusal.empty
      : busy
      ? FootPeelRefusal.busy
      : layers <= 1
      ? FootPeelRefusal.originalOnly
      : null;

  @override
  List<Object?> get props => [channel, hasContent, layers, busy];
}

/// Shared semantic read model for captions, touch and physical feedback.
class FootPeelProjection extends Equatable {
  /// Creates a complete projection.
  const FootPeelProjection({required this.bank, required this.tracks});

  /// Shared rig bank (0 = tracks 1–4, 1 = tracks 5–8).
  final int bank;

  /// All eight tracks, so the overview spans both banks.
  final List<FootPeelTrack> tracks;

  /// One role table drives captions, dispatch and physical LEDs.
  static const pedalRoles = <PedalButton, FootPeelPedal>{
    PedalButton.recPlay: FootPeelPedal(FootPeelAction.recordPlay),
    PedalButton.stop: FootPeelPedal(FootPeelAction.stop),
    PedalButton.mode: FootPeelPedal(FootPeelAction.exit),
    PedalButton.undo: FootPeelPedal(FootPeelAction.none),
    PedalButton.clear: FootPeelPedal(FootPeelAction.none),
    PedalButton.bank: FootPeelPedal(FootPeelAction.nextBank),
    PedalButton.track1: FootPeelPedal(FootPeelAction.peelTrack, slot: 0),
    PedalButton.track2: FootPeelPedal(FootPeelAction.peelTrack, slot: 1),
    PedalButton.track3: FootPeelPedal(FootPeelAction.peelTrack, slot: 2),
    PedalButton.track4: FootPeelPedal(FootPeelAction.peelTrack, slot: 3),
  };

  /// The absolute track channel shown in visible [slot].
  int channelAt(int slot) => bank * 4 + slot;

  /// The track shown in visible [slot].
  FootPeelTrack trackAt(int slot) => tracks[channelAt(slot)];

  @override
  List<Object?> get props => [bank, tracks];
}

/// Reads one track's Peel facts; an unknown channel reads empty.
FootPeelTrack readFootPeelTrack(LooperState looper, int channel) {
  final track = looper.tracks
      .where((track) => track.channel == channel)
      .firstOrNull;
  return FootPeelTrack(
    channel: channel,
    hasContent: track?.hasContent ?? false,
    layers: track?.layers ?? 0,
    busy:
        track != null &&
        (track.isCapturing ||
            track.layerInFlight ||
            track.pendingLaunch != null),
  );
}

/// Projects layer facts; meters never enter equality.
FootPeelProjection projectFootPeel(LooperState looper, {required int bank}) =>
    FootPeelProjection(
      bank: bank.clamp(0, 1),
      tracks: List.unmodifiable([
        for (var channel = 0; channel < 8; channel++)
          readFootPeelTrack(looper, channel),
      ]),
    );
