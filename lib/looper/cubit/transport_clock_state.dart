part of 'transport_clock_cubit.dart';

/// What the transport clock reads: how long the transport has run, and
/// whether it is counting right now.
class TransportClockState extends Equatable {
  /// Creates a [TransportClockState].
  const TransportClockState({
    this.elapsed = Duration.zero,
    this.running = false,
  });

  /// Wall time the transport has spent running, truncated to whole seconds
  /// (the displayed granularity — see [TransportClockCubit]'s tick
  /// discipline). Holds across a stop; zero only while the rig is empty.
  final Duration elapsed;

  /// Whether the clock is counting — any track capturing or sounding, or a
  /// count-in in progress.
  final bool running;

  @override
  List<Object?> get props => [elapsed, running];
}
