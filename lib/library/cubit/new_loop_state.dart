part of 'new_loop_cubit.dart';

/// What a new loop starts with.
enum NewLoopStart {
  /// Empty tracks: today's New loop.
  emptyTracks,

  /// Ed's setup: tracks 1 to 4 named and each given an Ed's Rack sound.
  edsSetup,
}

/// Where Ed's setup's sounds are.
enum EdsSetupStatus {
  /// Not asked for yet.
  idle,

  /// Being read.
  loading,

  /// Read, and they fit the effects budget.
  ready,

  /// One of them is missing or unreadable.
  missing,

  /// Read, but they would go over the effects budget.
  overBudget,
}

/// State of the [NewLoopCubit].
class NewLoopState extends Equatable {
  /// Creates a [NewLoopState].
  const NewLoopState({
    this.start = NewLoopStart.emptyTracks,
    this.eds = EdsSetupStatus.idle,
    this.template,
  });

  /// The chosen start.
  final NewLoopStart start;

  /// Where Ed's setup's sounds are.
  final EdsSetupStatus eds;

  /// Ed's setup, once read.
  final NewLoopTemplate? template;

  /// The template Start new loop applies: Ed's setup when it is chosen and
  /// ready, else none.
  NewLoopTemplate? get chosenTemplate =>
      start == NewLoopStart.edsSetup && eds == EdsSetupStatus.ready
      ? template
      : null;

  /// Whether Start new loop can run.
  bool get canStart =>
      start == NewLoopStart.emptyTracks || chosenTemplate != null;

  /// Returns a copy with the given fields replaced.
  NewLoopState copyWith({
    NewLoopStart? start,
    EdsSetupStatus? eds,
    NewLoopTemplate? template,
  }) => NewLoopState(
    start: start ?? this.start,
    eds: eds ?? this.eds,
    template: template ?? this.template,
  );

  @override
  List<Object?> get props => [start, eds, template];
}
