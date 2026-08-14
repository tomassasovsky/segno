part of 'transport_clock_cubit.dart';

/// What the transport clock reads: how long the transport has run, and
/// whether it is counting right now.
class TransportClockState extends Equatable {
  /// Creates a [TransportClockState].
  const TransportClockState({
    this.elapsed = Duration.zero,
    this.running = false,
  });

  /// Time the transport has spent running (monotonic — see
  /// [TransportClockCubit]'s stopwatch rationale), truncated to whole seconds
  /// (the displayed granularity). Holds across a stop; zeroed when a session
  /// load replaces the rig or the rig empties.
  final Duration elapsed;

  /// Whether the clock is counting — any track capturing or sounding, or a
  /// count-in in progress.
  final bool running;

  @override
  List<Object?> get props => [elapsed, running];
}
