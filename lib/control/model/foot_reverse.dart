import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The accepted Reverse action vocabulary, shared by display and dispatch.
enum FootReverseAction {
  /// Advance recording on the normal transport cursor.
  recordPlay,

  /// Stop recorded tracks; directions are kept.
  stop,

  /// Return to normal Tracks; directions are kept.
  exit,

  /// Turn the slot's track around at its current position.
  toggleTrack,

  /// Show the other four tracks.
  nextBank,

  /// No meaning in this mode (Undo and Clear): a stray stomp edits nothing.
  none,
}

/// One physical pedal's semantics. Every Reverse action fires on contact;
/// the mode has no holds.
class FootReversePedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootReversePedal(this.press, {this.slot});

  /// The action at contact.
  final FootReverseAction press;

  /// Visible track slot, resolved against the bank when the action fires.
  final int? slot;
}

/// One track's published direction.
class FootReverseTrack extends Equatable {
  /// Creates a read of current repository facts.
  const FootReverseTrack({
    required this.channel,
    required this.available,
    required this.reversed,
  });

  /// Absolute zero-based channel.
  final int channel;

  /// Whether the track holds settled recorded material it can turn around.
  final bool available;

  /// Callback-published direction.
  final bool reversed;

  @override
  List<Object?> get props => [channel, available, reversed];
}

/// Shared semantic read model for captions, touch and physical feedback.
class FootReverseProjection extends Equatable {
  /// Creates a complete projection.
  const FootReverseProjection({required this.bank, required this.tracks});

  /// Shared rig bank (0 = tracks 1–4, 1 = tracks 5–8).
  final int bank;

  /// All eight tracks, so the overview spans both banks.
  final List<FootReverseTrack> tracks;

  /// One role table drives captions, dispatch and physical LEDs.
  static const pedalRoles = <PedalButton, FootReversePedal>{
    PedalButton.recPlay: FootReversePedal(FootReverseAction.recordPlay),
    PedalButton.stop: FootReversePedal(FootReverseAction.stop),
    PedalButton.mode: FootReversePedal(FootReverseAction.exit),
    PedalButton.undo: FootReversePedal(FootReverseAction.none),
    PedalButton.clear: FootReversePedal(FootReverseAction.none),
    PedalButton.bank: FootReversePedal(FootReverseAction.nextBank),
    PedalButton.track1: FootReversePedal(
      FootReverseAction.toggleTrack,
      slot: 0,
    ),
    PedalButton.track2: FootReversePedal(
      FootReverseAction.toggleTrack,
      slot: 1,
    ),
    PedalButton.track3: FootReversePedal(
      FootReverseAction.toggleTrack,
      slot: 2,
    ),
    PedalButton.track4: FootReversePedal(
      FootReverseAction.toggleTrack,
      slot: 3,
    ),
  };

  /// The absolute track channel shown in visible [slot].
  int channelAt(int slot) => bank * 4 + slot;

  /// The track shown in visible [slot].
  FootReverseTrack trackAt(int slot) => tracks[channelAt(slot)];

  @override
  List<Object?> get props => [bank, tracks];
}

/// Projects direction facts; meters never enter equality.
FootReverseProjection projectFootReverse(
  LooperState looper, {
  required int bank,
}) {
  FootReverseTrack read(int channel) {
    final track = looper.tracks
        .where((track) => track.channel == channel)
        .firstOrNull;
    return FootReverseTrack(
      channel: channel,
      available:
          track != null &&
          track.hasContent &&
          !track.isCapturing &&
          !track.pending,
      reversed: track?.reversed ?? false,
    );
  }

  return FootReverseProjection(
    bank: bank.clamp(0, 1),
    tracks: List.unmodifiable([
      for (var channel = 0; channel < 8; channel++) read(channel),
    ]),
  );
}
