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
    this.updateInFlight = false,
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

  /// An update is downloading or installing, online or from a USB drive.
  /// A reboot mid-install leaves the inactive slot half written, and one
  /// with an earlier build staged boots into that build.
  final bool updateInFlight;

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
    updateInFlight,
    currentSessionName,
    sessionHasContent,
  ];
}

/// Projects live feature state onto a [PowerSnapshot].
///
/// [backing] is null when no backing player is mounted; the session then
/// counts as having content.
///
/// Count-in is the looper transport's own flag, not TransportClockState
/// running — that flag is also true while loops play, which is not in-flight.
PowerSnapshot powerSnapshotOf({
  required LooperState looper,
  required PerformanceRecorderState recorder,
  required SessionState session,
  required BackingState? backing,
  bool transferInFlight = false,
  bool updateInFlight = false,
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
    updateInFlight: updateInFlight,
    currentSessionName: session.currentSessionName,
    // An unknown backing (no player mounted) counts as content: the save
    // is kept rather than a setup dropped unseen.
    sessionHasContent:
        looper.hasContent ||
        backing == null ||
        backing.prepared.isNotEmpty ||
        backing.loaded != null,
  );
}

/// Why a restart or shutdown is refused.
enum PowerRefusal {
  /// A take is in flight.
  take,

  /// An update is downloading or installing.
  update,

  /// A storage write or a USB eject is in progress.
  transfer,
}

/// Pure gate: what refuses a restart or shutdown in [snapshot], or null when
/// it may proceed (saving first whenever the session holds anything to
/// save). A take comes first, then an update, then a transfer: a USB update
/// package's copy is both an update and a transfer, and reads as the update.
PowerRefusal? powerRefusal(PowerSnapshot snapshot) {
  if (snapshot.takeInFlight) return PowerRefusal.take;
  if (snapshot.updateInFlight) return PowerRefusal.update;
  if (snapshot.transferInFlight) return PowerRefusal.transfer;
  return null;
}
