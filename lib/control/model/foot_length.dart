import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// The accepted Multiply / Divide action vocabulary, shared by display and
/// dispatch (#1168, pen section 16).
enum FootLengthAction {
  /// Record / Play the selected track, exactly as in Tracks.
  recordPlay,

  /// Undo the selected track's latest change, exactly as in Tracks.
  undo,

  /// Redo the selected track's latest undone change: Multiply's Undo hold,
  /// exactly as the Tracks Undo hold.
  redo,

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
  /// would leave half a beat at the current tempo.
  incompatible,

  /// The doubled loop would not fit in the loop memory.
  capacity,

  /// The engine refused for another reason.
  failed,
}

/// One physical pedal's semantics. A role without a [hold] fires on
/// contact; a role with one fires [press] on a release before the hold
/// threshold and [hold] once the threshold passes.
class FootLengthPedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootLengthPedal(this.press, {this.hold, this.slot});

  /// The action at contact, or at release when [hold] is set.
  final FootLengthAction press;

  /// The action a hold fires instead of [press], or null.
  final FootLengthAction? hold;

  /// Visible track slot, resolved against the bank when the action fires.
  final int? slot;
}

/// The halves Divide keeps, counted in bars when each half is whole bars,
/// else in beats (pen 16: "Bar 1", "Beats 1–2", "Beats 7–12").
class FootLengthHalves extends Equatable {
  /// Creates halves of [half] units each.
  const FootLengthHalves({required this.inBars, required this.half});

  /// Whether the units are bars (else beats).
  final bool inBars;

  /// Units in each half (`>= 1`).
  final int half;

  @override
  List<Object?> get props => [inBars, half];
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
    this.canUndo = false,
    this.canRedo = false,
    this.undoDepth = 0,
    this.bars,
    this.beats,
    this.totalBeats,
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

  /// Whether Undo has anything to undo on this track.
  final bool canUndo;

  /// Whether Redo has anything to redo on this track.
  final bool canRedo;

  /// Published undo steps on this track.
  final int undoDepth;

  /// The length in whole bars, or null without a known whole bar count.
  final int? bars;

  /// The length in whole beats when it is not whole bars (a Divide of a sole
  /// 1- or 3-bar loop leaves 2 or 6 beats), else null.
  final int? beats;

  /// The length in whole beats, whole bars or not, or null when it is not a
  /// whole number of beats.
  final int? totalBeats;

  /// Whether a length edit would be posted now.
  bool get available => hasContent && !busy;

  /// Why a length edit on this track would be refused before it reaches the
  /// engine, or null when it would be posted.
  FootLengthRefusal? get refusal => !hasContent
      ? FootLengthRefusal.empty
      : busy
      ? FootLengthRefusal.busy
      : null;

  /// The halves Divide would keep, or null when they are not whole beats.
  FootLengthHalves? get halves {
    if (!hasContent) return null;
    final whole = bars;
    if (whole != null && whole.isEven) {
      return FootLengthHalves(inBars: true, half: whole ~/ 2);
    }
    final count = totalBeats;
    if (count != null && count > 0 && count.isEven) {
      return FootLengthHalves(inBars: false, half: count ~/ 2);
    }
    return null;
  }

  @override
  List<Object?> get props => [
    channel,
    hasContent,
    busy,
    lengthFrames,
    multiple,
    syncDivisor,
    canUndo,
    canRedo,
    undoDepth,
    bars,
    beats,
    totalBeats,
  ];
}

/// The latest length edit the surface made, kept for the length panel's
/// outcome line ("Repeated to 4 bars", "First 1 bar kept") and Multiply's
/// Undo caption ("Length edit").
///
/// It describes the track only while the track is exactly as the edit left
/// it: the same length AND the same undo depth. The result is bound from the
/// published state once both have moved off what they were before the edit,
/// so an Undo of the edit, a second edit, or an overdub on top of it ends the
/// description, whatever order the length and the history are published in.
class FootLengthOutcome extends Equatable {
  /// Records [edit] on [channel], which was [fromFrames] long with
  /// [fromUndoDepth] undo steps before it; [toFrames] and [toUndoDepth] are
  /// the state it left, once published.
  const FootLengthOutcome({
    required this.channel,
    required this.edit,
    required this.fromFrames,
    this.fromUndoDepth = 0,
    this.toFrames,
    this.toUndoDepth,
  });

  /// No edit made on this visit.
  static const none = FootLengthOutcome(
    channel: -1,
    edit: LengthEdit.doubled,
    fromFrames: 0,
  );

  /// The edited track, or `-1` for [none].
  final int channel;

  /// What the edit did.
  final LengthEdit edit;

  /// The track's length before the edit.
  final int fromFrames;

  /// The track's undo depth before the edit.
  final int fromUndoDepth;

  /// The length the edit left, or null until it is published.
  final int? toFrames;

  /// The undo depth the edit left, or null until it is published.
  final int? toUndoDepth;

  /// Whether the edit's result is known.
  bool get bound => toFrames != null && toUndoDepth != null;

  /// This outcome with its result bound from [track] when [track] now shows
  /// the edit (both its length and its undo depth moved), else unchanged.
  FootLengthOutcome bindTo(FootLengthTrack track) {
    if (bound || track.channel != channel || !track.hasContent) return this;
    if (track.lengthFrames == fromFrames || track.undoDepth == fromUndoDepth) {
      return this;
    }
    return FootLengthOutcome(
      channel: channel,
      edit: edit,
      fromFrames: fromFrames,
      fromUndoDepth: fromUndoDepth,
      toFrames: track.lengthFrames,
      toUndoDepth: track.undoDepth,
    );
  }

  /// Whether this outcome still describes [track]: the edit's result is
  /// bound and the track is still exactly that length at that undo depth.
  bool describes(FootLengthTrack track) =>
      bound &&
      track.channel == channel &&
      track.hasContent &&
      track.lengthFrames == toFrames &&
      track.undoDepth == toUndoDepth;

  @override
  List<Object?> get props => [
    channel,
    edit,
    fromFrames,
    fromUndoDepth,
    toFrames,
    toUndoDepth,
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

  /// All eight tracks.
  final List<FootLengthTrack> tracks;

  /// The Multiply role table (pen 16 screens 01-02): Rec/Play, Stop and Undo
  /// (tap Undo, hold Redo) keep their Tracks meaning, Clear doubles the
  /// selected track and the track pedals select.
  static const multiplyRoles = <PedalButton, FootLengthPedal>{
    PedalButton.recPlay: FootLengthPedal(FootLengthAction.recordPlay),
    PedalButton.undo: FootLengthPedal(
      FootLengthAction.undo,
      hold: FootLengthAction.redo,
    ),
    PedalButton.clear: FootLengthPedal(FootLengthAction.doubleTrack),
    PedalButton.stop: FootLengthPedal(FootLengthAction.stop),
    PedalButton.mode: FootLengthPedal(FootLengthAction.exit),
    PedalButton.bank: FootLengthPedal(FootLengthAction.nextBank),
    PedalButton.track1: FootLengthPedal(FootLengthAction.selectTrack, slot: 0),
    PedalButton.track2: FootLengthPedal(FootLengthAction.selectTrack, slot: 1),
    PedalButton.track3: FootLengthPedal(FootLengthAction.selectTrack, slot: 2),
    PedalButton.track4: FootLengthPedal(FootLengthAction.selectTrack, slot: 3),
  };

  /// The Divide role table (pen 16 screens 03-08): Rec/Play and Stop keep
  /// their Tracks meaning, Undo keeps the first half (hold for Undo), Clear
  /// keeps the last half and the track pedals select.
  static const divideRoles = <PedalButton, FootLengthPedal>{
    PedalButton.recPlay: FootLengthPedal(FootLengthAction.recordPlay),
    PedalButton.undo: FootLengthPedal(
      FootLengthAction.firstHalf,
      hold: FootLengthAction.undo,
    ),
    PedalButton.clear: FootLengthPedal(FootLengthAction.lastHalf),
    PedalButton.stop: FootLengthPedal(FootLengthAction.stop),
    PedalButton.mode: FootLengthPedal(FootLengthAction.exit),
    PedalButton.bank: FootLengthPedal(FootLengthAction.nextBank),
    PedalButton.track1: FootLengthPedal(FootLengthAction.selectTrack, slot: 0),
    PedalButton.track2: FootLengthPedal(FootLengthAction.selectTrack, slot: 1),
    PedalButton.track3: FootLengthPedal(FootLengthAction.selectTrack, slot: 2),
    PedalButton.track4: FootLengthPedal(FootLengthAction.selectTrack, slot: 3),
  };

  /// The role table that drives captions, dispatch and physical LEDs in
  /// [mode]: Divide's in Divide, Multiply's otherwise.
  static Map<PedalButton, FootLengthPedal> rolesFor(InteractionMode mode) =>
      mode == InteractionMode.divide ? divideRoles : multiplyRoles;

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

  /// Whether the visible bank holds any recording.
  bool get bankHasContent => [
    for (var slot = 0; slot < 4; slot++) trackAt(slot),
  ].any((track) => track.hasContent);

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
  final bars = track.wholeBars(
    transport: looper.transport,
    sampleRate: looper.status.sampleRate,
  );
  final beats = track.wholeBeats(
    transport: looper.transport,
    sampleRate: looper.status.sampleRate,
  );
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
    canUndo: track.canUndo,
    canRedo: track.canRedo,
    undoDepth: track.undoDepth,
    bars: bars,
    beats: bars == null ? beats : null,
    totalBeats: beats,
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
