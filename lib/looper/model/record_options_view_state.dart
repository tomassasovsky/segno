import 'package:equatable/equatable.dart';
import 'package:segno/looper/model/record_options.dart';

/// Presentation acknowledgement for the most recent length edit.
enum LengthEditPhase { pending, applied, refused }

/// One view intent; nullable bars retain the Use default distinction.
final class LengthEditAttempt extends Equatable {
  const LengthEditAttempt({
    required this.id,
    required this.channel,
    required this.bars,
    required this.phase,
  });
  final int id;
  final int? channel;
  final int? bars;
  final LengthEditPhase phase;

  @override
  List<Object?> get props => [id, channel, bars, phase];
}

/// Accepted owner projection plus presentation-only edit acknowledgement.
final class RecordOptionsViewState extends Equatable {
  const RecordOptionsViewState({required this.options, this.lengthAttempt});
  final RecordOptions options;
  final LengthEditAttempt? lengthAttempt;

  @override
  List<Object?> get props => [options, lengthAttempt];
}
