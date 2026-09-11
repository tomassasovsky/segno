import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// Which kind of sound the Effects page is pointed at — the pen's Sound type
/// row (`Live inputs` / `Recorded tracks` / `Outputs`).
///
/// Not a second spelling of [FxStage]: a kind is what the SOURCE STRIP shows,
/// and the recorded kind covers three different stages (a part's own chain,
/// a whole track's, and the All tracks chain) behind one strip.
enum FxDestinationKind {
  /// A hardware input's live chain.
  liveInput,

  /// A recorded track — its parts, the whole track, or All tracks.
  recordedTrack,

  /// One output destination's post-sum chain.
  output,
}

/// Which part of the selected recorded track is being edited.
///
/// `Whole track` is a distinct processing target, not "all the parts at once":
/// it names the track's own stereo bus, downstream of every part.
sealed class FxTrackPart extends Equatable {
  const FxTrackPart();

  /// The whole track's own chain.
  static const FxTrackPart whole = FxWholeTrack._();

  /// One separately recorded part (lane [lane]).
  static FxTrackPart part(int lane) => FxRecordedPart(lane);
}

/// The whole track's own chain, downstream of its parts.
final class FxWholeTrack extends FxTrackPart {
  const FxWholeTrack._();

  @override
  List<Object?> get props => const [];
}

/// One separately recorded part of the selected track.
final class FxRecordedPart extends FxTrackPart {
  /// Creates an [FxRecordedPart] naming lane [lane].
  const FxRecordedPart(this.lane);

  /// The lane within the selected track.
  final int lane;

  @override
  List<Object?> get props => [lane];
}

/// Where the Effects page is pointed: the kind, the source within that kind,
/// and — for a recorded track — which part of it.
///
/// One value rather than three loose fields, because the three only mean
/// anything together: `track 2` names nothing without the kind that says it
/// is a track, and a part index names nothing without the track.
class FxDestination extends Equatable {
  /// Creates an [FxDestination].
  const FxDestination({
    required this.kind,
    required this.index,
    this.part = FxTrackPart.whole,
  });

  /// A live input's chain.
  const FxDestination.liveInput(int input)
    : this(kind: FxDestinationKind.liveInput, index: input);

  /// A recorded track's chain — its whole-track bus unless [part] says
  /// otherwise.
  const FxDestination.recordedTrack(int channel, {FxTrackPart? part})
    : this(
        kind: FxDestinationKind.recordedTrack,
        index: channel,
        part: part ?? FxTrackPart.whole,
      );

  /// The All tracks recorded-mix chain.
  ///
  /// Carried as a recorded-kind destination with [allTracksIndex], because
  /// that is where the pen puts it: beside Track 8 in the same strip, not in
  /// a fourth kind of its own.
  const FxDestination.allTracks()
    : this(kind: FxDestinationKind.recordedTrack, index: allTracksIndex);

  /// One output destination's chain.
  const FxDestination.output(int bus)
    : this(kind: FxDestinationKind.output, index: bus);

  /// The [index] that means All tracks rather than a track channel.
  static const int allTracksIndex = -1;

  /// Which strip this destination lives in.
  final FxDestinationKind kind;

  /// The source within [kind]: the input channel, the track channel (or
  /// [allTracksIndex]), or the output destination.
  final int index;

  /// Which part of a recorded track is selected. Meaningless for the other
  /// kinds, and for All tracks, which has no parts.
  final FxTrackPart part;

  /// Whether this is the All tracks recorded-mix chain.
  bool get isAllTracks =>
      kind == FxDestinationKind.recordedTrack && index == allTracksIndex;

  /// Whether this destination's placement is the player's to choose.
  ///
  /// Live inputs and individual recorded tracks or parts carry the Pre/Post
  /// switch; All tracks and the outputs omit it because their stage is fixed
  /// after their respective mixes (accepted design, FX 4).
  bool get placementIsEditable => switch (kind) {
    FxDestinationKind.liveInput => true,
    FxDestinationKind.recordedTrack => !isAllTracks,
    FxDestinationKind.output => false,
  };

  /// Which placement a NEW instance takes here: inputs default Pre, recorded
  /// destinations default Post, and the fixed stages resolve to Post.
  FxPlacement get defaultPlacement => kind == FxDestinationKind.liveInput
      ? FxPlacement.pre
      : FxPlacement.post;

  /// The chain this destination names, or `null` when the selection does not
  /// name one (a recorded track with no such part).
  FxAddress? get address => switch (kind) {
    FxDestinationKind.liveInput => FxAddress(
      stage: FxStage.input,
      index: index,
    ),
    FxDestinationKind.recordedTrack when isAllTracks => const FxAddress(
      stage: FxStage.allTracks,
    ),
    FxDestinationKind.recordedTrack => switch (part) {
      FxWholeTrack() => FxAddress(stage: FxStage.track, index: index),
      FxRecordedPart(:final lane) => FxAddress(
        stage: FxStage.loop,
        index: index,
        lane: lane,
      ),
    },
    FxDestinationKind.output => FxAddress(stage: FxStage.output, index: index),
  };

  /// A copy with the given fields replaced.
  FxDestination copyWith({
    FxDestinationKind? kind,
    int? index,
    FxTrackPart? part,
  }) => FxDestination(
    kind: kind ?? this.kind,
    index: index ?? this.index,
    part: part ?? this.part,
  );

  @override
  List<Object?> get props => [kind, index, part];
}
