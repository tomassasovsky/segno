import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The accepted Multiply / Divide action vocabulary, shared by display and
/// dispatch (#1168).
enum FootLengthAction {
  /// Double the selected track: Multiply.
  doubleTrack,

  /// Keep the first half of the selected track: Divide.
  firstHalf,

  /// Keep the last half of the selected track: Divide.
  lastHalf,

  /// Make the slot's track the selected one.
  selectTrack,

  /// Stop recorded tracks; lengths are kept.
  stop,

  /// Return to normal Tracks; lengths are kept.
  exit,

  /// Show the other four tracks.
  nextBank,
}

/// Why a length edit changed nothing. Every refused press on a recorded track
/// and every refused assigned edit says which.
enum FootLengthRefusal {
  /// The track holds no recording: nothing to double or halve.
  empty,

  /// The track is recording, finishing a pass, waiting for an arm or its
  /// Count-in, or another length change is still landing.
  busy,

  /// The new length does not fit the other loops, or a sole loop's half
  /// would not keep whole bars at the current tempo.
  incompatible,

  /// The doubled loop would not fit in the loop memory.
  capacity,

  /// The engine refused for another reason.
  failed,
}

/// One physical pedal's semantics. Every Multiply / Divide action fires on
/// contact; the mode has no holds.
class FootLengthPedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootLengthPedal(this.press, {this.slot});

  /// The action at contact.
  final FootLengthAction press;

  /// Visible track slot, resolved against the bank when the action fires.
  final int? slot;
}

/// One track's published length.
class FootLengthTrack extends Equatable {
  /// Creates a read of current repository facts.
  const FootLengthTrack({
    required this.channel,
    required this.hasContent,
    required this.busy,
    required this.lengthFrames,
    required this.multiple,
    required this.syncDivisor,
    this.bars,
  });

  /// Absolute zero-based channel.
  final int channel;

  /// Whether the track holds a recording. A busy recorded track keeps its
  /// real length, never "Empty".
  final bool hasContent;

  /// Whether the track is capturing, finishing a pass, waiting for an arm or
  /// its Count-in launch: the engine refuses a length edit until that ends.
  final bool busy;

  /// Published length in frames.
  final int lengthFrames;

  /// Whole base loops (`>= 1`); `1` while [syncDivisor] is set.
  final int multiple;

  /// A Sync/Band division of the base loop (`2` or `4`), else `0`.
  final int syncDivisor;

  /// The length in whole bars, or null without a known whole bar count.
  final int? bars;

  /// Whether a length edit would be posted now.
  bool get available => hasContent && !busy;

  /// Why a length edit on this track would be refused before it reaches the
  /// engine, or null when it would be posted.
  FootLengthRefusal? get refusal => !hasContent
      ? FootLengthRefusal.empty
      : busy
      ? FootLengthRefusal.busy
      : null;

  @override
  List<Object?> get props => [
    channel,
    hasContent,
    busy,
    lengthFrames,
    multiple,
    syncDivisor,
    bars,
  ];
}

/// Shared semantic read model for captions, touch and physical feedback.
class FootLengthProjection extends Equatable {
  /// Creates a complete projection.
  const FootLengthProjection({
    required this.bank,
    required this.cursor,
    required this.tracks,
  });

  /// Shared rig bank (0 = tracks 1–4, 1 = tracks 5–8).
  final int bank;

  /// The selected track every edit acts on (the shared cursor).
  final int cursor;

  /// All eight tracks, so the overview spans both banks.
  final List<FootLengthTrack> tracks;

  /// One role table drives captions, dispatch and physical LEDs. Rec/Play
  /// doubles (Multiply belongs to the record family), Undo and Clear keep a
  /// half (Divide); the track pedals select.
  static const pedalRoles = <PedalButton, FootLengthPedal>{
    PedalButton.recPlay: FootLengthPedal(FootLengthAction.doubleTrack),
    PedalButton.undo: FootLengthPedal(FootLengthAction.firstHalf),
    PedalButton.clear: FootLengthPedal(FootLengthAction.lastHalf),
    PedalButton.stop: FootLengthPedal(FootLengthAction.stop),
    PedalButton.mode: FootLengthPedal(FootLengthAction.exit),
    PedalButton.bank: FootLengthPedal(FootLengthAction.nextBank),
    PedalButton.track1: FootLengthPedal(FootLengthAction.selectTrack, slot: 0),
    PedalButton.track2: FootLengthPedal(FootLengthAction.selectTrack, slot: 1),
    PedalButton.track3: FootLengthPedal(FootLengthAction.selectTrack, slot: 2),
    PedalButton.track4: FootLengthPedal(FootLengthAction.selectTrack, slot: 3),
  };

  /// The edit each editing action makes, or null for the other actions.
  static LengthEdit? editOf(FootLengthAction action) => switch (action) {
    FootLengthAction.doubleTrack => LengthEdit.doubled,
    FootLengthAction.firstHalf => LengthEdit.firstHalf,
    FootLengthAction.lastHalf => LengthEdit.lastHalf,
    _ => null,
  };

  /// The absolute track channel shown in visible [slot].
  int channelAt(int slot) => bank * 4 + slot;

  /// The track shown in visible [slot].
  FootLengthTrack trackAt(int slot) => tracks[channelAt(slot)];

  /// The selected track.
  FootLengthTrack get selected => tracks[cursor];

  @override
  List<Object?> get props => [bank, cursor, tracks];
}

/// Reads one track's length facts; an unknown channel reads empty.
FootLengthTrack readFootLengthTrack(LooperState looper, int channel) {
  final track = looper.tracks
      .where((track) => track.channel == channel)
      .firstOrNull;
  if (track == null) {
    return FootLengthTrack(
      channel: channel,
      hasContent: false,
      busy: false,
      lengthFrames: 0,
      multiple: 1,
      syncDivisor: 0,
    );
  }
  return FootLengthTrack(
    channel: channel,
    hasContent: track.hasContent,
    busy:
        track.isCapturing ||
        track.layerInFlight ||
        track.pending ||
        track.pendingLaunch != null,
    lengthFrames: track.lengthFrames,
    multiple: track.multiple,
    syncDivisor: track.syncDivisor,
    bars: track.wholeBars(
      transport: looper.transport,
      sampleRate: looper.status.sampleRate,
    ),
  );
}

/// Projects length facts; meters never enter equality.
FootLengthProjection projectFootLength(
  LooperState looper, {
  required int bank,
  required int cursor,
}) => FootLengthProjection(
  bank: bank.clamp(0, 1),
  cursor: cursor.clamp(0, 7),
  tracks: List.unmodifiable([
    for (var channel = 0; channel < 8; channel++)
      readFootLengthTrack(looper, channel),
  ]),
);
