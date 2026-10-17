import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

/// A point-in-time reading of what a restart or shutdown has to respect.
///
/// Built by the host from live cubit/bloc state; the gate itself is a pure
/// function of this snapshot so tests own the predicate without a widget tree.
class PowerSnapshot extends Equatable {
  /// Creates a [PowerSnapshot].
  const PowerSnapshot({
    this.takeInFlight = false,
    this.transferInFlight = false,
    this.currentSessionName,
  });

  /// A take that must not be discarded: capture, punch-tail, count-in, or
  /// an in-flight / recovering performance write.
  final bool takeInFlight;

  /// A write to a storage destination (export, backup, copy) or a USB eject
  /// is in progress: halting mid-write or mid-unmount is what the guard is
  /// for (accepted behaviour §7.8, "Transfers/eject guard it").
  final bool transferInFlight;

  /// Open named session, or null when the save becomes Save As.
  final String? currentSessionName;

  @override
  List<Object?> get props => [
    takeInFlight,
    transferInFlight,
    currentSessionName,
  ];
}

/// Projects live feature state onto a [PowerSnapshot].
///
/// Count-in is the looper transport's own flag, not TransportClockState
/// running — that flag is also true while loops play, which is not in-flight.
PowerSnapshot powerSnapshotOf({
  required LooperState looper,
  required PerformanceRecorderState recorder,
  required SessionState session,
  bool transferInFlight = false,
}) {
  return PowerSnapshot(
    takeInFlight:
        looper.tracks.any(
          (track) => track.isCapturing || track.pending || track.layerInFlight,
        ) ||
        looper.transport.countingIn ||
        recorder is PerformanceRecorderArmed ||
        recorder is PerformanceRecorderFinalizing ||
        recorder is PerformanceRecorderRendering ||
        (recorder is PerformanceRecorderIdle && recorder.recovering),
    transferInFlight: transferInFlight,
    currentSessionName: session.currentSessionName,
  );
}

/// Pure gate: a take or a transfer in flight refuses a restart or shutdown.
/// Everything else may proceed, and always saves first.
bool powerRefused(PowerSnapshot snapshot) =>
    snapshot.takeInFlight || snapshot.transferInFlight;
