part of 'fx_cubit.dart';

/// The Effects page's selection: the kind in view, and where each of the
/// three strips was left.
class FxState extends Equatable {
  /// Creates an [FxState].
  const FxState({
    this.kind = FxDestinationKind.liveInput,
    this.input = 0,
    this.track = 0,
    this.output = 0,
    this.part = FxTrackPart.whole,
  });

  /// An [FxState] pointed at [destination], with the other strips at their
  /// defaults.
  factory FxState.at(FxDestination destination) => FxState(
    kind: destination.kind,
    input: destination.kind == FxDestinationKind.liveInput
        ? destination.index
        : 0,
    track: destination.kind == FxDestinationKind.recordedTrack
        ? destination.index
        : 0,
    output: destination.kind == FxDestinationKind.output
        ? destination.index
        : 0,
    part: destination.part,
  );

  /// Which strip is showing.
  final FxDestinationKind kind;

  /// Where the Live inputs strip was left.
  final int input;

  /// Where the Recorded tracks strip was left ([FxDestination.allTracksIndex]
  /// for All tracks).
  final int track;

  /// Where the Outputs strip was left.
  final int output;

  /// Which part of [track] is selected.
  final FxTrackPart part;

  /// The selected source within the current kind.
  int get index => switch (kind) {
    FxDestinationKind.liveInput => input,
    FxDestinationKind.recordedTrack => track,
    FxDestinationKind.output => output,
  };

  /// Where the page is pointed.
  FxDestination get destination =>
      FxDestination(kind: kind, index: index, part: part);

  /// A copy with the given fields replaced. [index] writes the current kind's
  /// own remembered source.
  FxState copyWith({
    FxDestinationKind? kind,
    int? index,
    FxTrackPart? part,
  }) {
    final nextKind = kind ?? this.kind;
    return FxState(
      kind: nextKind,
      input: index != null && nextKind == FxDestinationKind.liveInput
          ? index
          : input,
      track: index != null && nextKind == FxDestinationKind.recordedTrack
          ? index
          : track,
      output: index != null && nextKind == FxDestinationKind.output
          ? index
          : output,
      part: part ?? this.part,
    );
  }

  @override
  List<Object?> get props => [kind, input, track, output, part];
}
