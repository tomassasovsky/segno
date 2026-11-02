part of 'audio_warm_up_cubit.dart';

/// Where the console is in an audio warm-up (#1533).
enum AudioWarmUpStatus {
  /// No warm-up runs: the player's config is open, or audio is stopped.
  idle,

  /// The device runs the warm-up config, and the cubit waits for the console
  /// to settle before it opens the player's.
  settling,
}

/// State of [AudioWarmUpCubit].
class AudioWarmUpState extends Equatable {
  /// Creates an [AudioWarmUpState].
  const AudioWarmUpState({this.status = AudioWarmUpStatus.idle});

  /// The current warm-up status.
  final AudioWarmUpStatus status;

  @override
  List<Object?> get props => [status];
}
