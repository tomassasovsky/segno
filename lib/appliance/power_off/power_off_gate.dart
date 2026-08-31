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
    this.anyCapturingOrPending = false,
    this.layerInFlight = false,
    this.countingIn = false,
    this.performanceInFlight = false,
    this.performanceRecovering = false,
    this.anyHasContent = false,
    this.currentSessionName,
  });

  /// Any track is recording, overdubbing, or waiting on a quantized arm.
  final bool anyCapturingOrPending;

  /// A punch-tail is still draining onto a track.
  final bool layerInFlight;

  /// The count-in click is already sounding.
  final bool countingIn;

  /// Performance capture is Armed / Finalizing / Rendering.
  final bool performanceInFlight;

  /// Boot salvage is still writing a crashed capture.
  final bool performanceRecovering;

  /// Any track holds recorded audio.
  final bool anyHasContent;

  /// Open named session, or null when Save would become Save As.
  final String? currentSessionName;

  /// A take that must not be discarded: capture, punch-tail, count-in, or
  /// an in-flight / recovering performance write.
  bool get takeInFlight =>
      anyCapturingOrPending ||
      layerInFlight ||
      countingIn ||
      performanceInFlight ||
      performanceRecovering;

  @override
  List<Object?> get props => [
    anyCapturingOrPending,
    layerInFlight,
    countingIn,
    performanceInFlight,
    performanceRecovering,
    anyHasContent,
    currentSessionName,
  ];
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
    anyCapturingOrPending: looper.tracks.any(
      (track) => track.isCapturing || track.pending,
    ),
    layerInFlight: looper.tracks.any((track) => track.layerInFlight),
    countingIn: looper.transport.countingIn,
    performanceInFlight:
        recorder is PerformanceRecorderArmed ||
        recorder is PerformanceRecorderFinalizing ||
        recorder is PerformanceRecorderRendering,
    performanceRecovering:
        recorder is PerformanceRecorderIdle && recorder.recovering,
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
