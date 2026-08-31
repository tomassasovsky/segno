import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

/// What a short press of the rear power button should do.
enum PowerOffDisposition {
  /// A take is in flight — only Keep playing.
  refuse,

  /// Loops in RAM would vanish — Save / discard / Keep playing.
  confirm,

  /// Nothing that would vanish — skip the confirm and go to goodbye.
  skip,
}

/// A point-in-time reading of the work that would vanish on halt.
///
/// Built by the host from live cubit/bloc state; the gate itself is a pure
/// function of this snapshot so tests own the predicate without a widget tree.
class PowerOffSnapshot extends Equatable {
  /// Creates a [PowerOffSnapshot].
  const PowerOffSnapshot({
    this.takeInFlight = false,
    this.anyHasContent = false,
    this.currentSessionName,
  });

  /// A take that must not be discarded: capture, punch-tail, count-in, or
  /// an in-flight / recovering performance write.
  final bool takeInFlight;

  /// Any track holds recorded audio.
  final bool anyHasContent;

  /// Open named session, or null when Save would become Save As.
  final String? currentSessionName;

  @override
  List<Object?> get props => [takeInFlight, anyHasContent, currentSessionName];
}

/// Projects live feature state onto a [PowerOffSnapshot].
///
/// Count-in is the looper transport's own flag, not TransportClockState
/// running — that flag is also true while loops play, which is not in-flight.
PowerOffSnapshot powerOffSnapshotOf({
  required LooperState looper,
  required PerformanceRecorderState recorder,
  required SessionState session,
}) {
  return PowerOffSnapshot(
    takeInFlight:
        looper.tracks.any(
          (track) => track.isCapturing || track.pending || track.layerInFlight,
        ) ||
        looper.transport.countingIn ||
        recorder is PerformanceRecorderArmed ||
        recorder is PerformanceRecorderFinalizing ||
        recorder is PerformanceRecorderRendering ||
        (recorder is PerformanceRecorderIdle && recorder.recovering),
    anyHasContent: looper.tracks.any((track) => track.hasContent),
    currentSessionName: session.currentSessionName,
  );
}

/// Pure gate: in-flight take → refuse; idle with content → confirm; else skip.
PowerOffDisposition powerOffGate(PowerOffSnapshot snapshot) {
  if (snapshot.takeInFlight) return PowerOffDisposition.refuse;
  if (snapshot.anyHasContent) return PowerOffDisposition.confirm;
  return PowerOffDisposition.skip;
}
