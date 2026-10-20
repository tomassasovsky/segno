import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/backing/model/backing_state.dart';
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
    this.sessionHasContent = true,
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

  /// Whether the open session holds something a restart would lose without
  /// a session save: recorded audio, or a prepared or loaded backing setup.
  /// Everything else in a session (settings, FX chains, the mix, bindings)
  /// is already in the settings store and comes back at boot. An unnamed
  /// session without content restarts and halts with no Save As and no
  /// session write. Defaults to true, so a snapshot that does not say keeps
  /// the save.
  final bool sessionHasContent;

  @override
  List<Object?> get props => [
    takeInFlight,
    transferInFlight,
    currentSessionName,
    sessionHasContent,
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
  BackingState backing = const BackingState(),
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
    sessionHasContent:
        looper.hasContent ||
        backing.prepared.isNotEmpty ||
        backing.loaded != null,
  );
}

/// Pure gate: a take or a transfer in flight refuses a restart or shutdown.
/// Everything else may proceed, and saves first whenever the session holds
/// anything to save.
bool powerRefused(PowerSnapshot snapshot) =>
    snapshot.takeInFlight || snapshot.transferInFlight;
