import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart' show ReopenOutcome;

/// What the most recent device reopen did with the recorded loops (#1140).
///
/// Carried on `EngineStatus.reopen` from the reopen until the next deliberate
/// start, so the connectivity notice that fires when the device reads present
/// again can say whether the loops survived. A fully retained reopen is the
/// ordinary "reconnected" case; [ReopenOutcome.retainedPartial] names the
/// tracks that were dropped because a Clear, Undo, Redo or cancel on them was
/// still unapplied when the device went away; a `cleared*` outcome means the
/// device came back with another sample rate (or loop cap) and every loop was
/// cleared — the saved Session is the way back.
class EngineReopened extends Equatable {
  /// Creates an [EngineReopened].
  const EngineReopened({
    required this.outcome,
    required this.droppedTracks,
    required this.previousSampleRate,
    required this.sampleRate,
  });

  /// The engine's verdict.
  final ReopenOutcome outcome;

  /// Bitmask (bit `t` = track `t`) of the tracks a
  /// [ReopenOutcome.retainedPartial] reopen dropped; `0` otherwise.
  final int droppedTracks;

  /// The sample rate the loops were recorded at (the previous session's).
  final int previousSampleRate;

  /// The sample rate the device came back at.
  final int sampleRate;

  /// Whether any recorded material survived.
  bool get keepsMaterial => outcome.keepsMaterial;

  /// Whether every loop survived untouched.
  bool get retainedAll => outcome == ReopenOutcome.retained;

  /// The dropped tracks as channel indices, ascending.
  List<int> get droppedChannels => [
    for (var channel = 0; channel < 32; channel++)
      if (droppedTracks & (1 << channel) != 0) channel,
  ];

  @override
  List<Object?> get props => [
    outcome,
    droppedTracks,
    previousSampleRate,
    sampleRate,
  ];
}
