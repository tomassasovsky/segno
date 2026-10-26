import 'dart:async';
import 'dart:typed_data';

import 'package:segno/visualizer/performance_readout.dart';

/// Manages the readout on the Track display (the 7"): showing and hiding it and
/// pushing waveform frames to it. The appliance's is the screen link
/// (`ScreenLinkWaveformService`); tests and the macOS dev host use the no-op.
abstract interface class WaveformWindowService {
  /// Whether the waveform window is currently open.
  bool get isOpen;

  /// Opens the waveform window (idempotent).
  ///
  /// Returns `true` once the window is ready, or `false` if it failed to signal
  /// readiness within the timeout — so the caller can surface the failure
  /// instead of degrading silently.
  Future<bool> open();

  /// Closes the waveform window (idempotent).
  Future<void> close();

  /// Sends a waveform frame (the selected track's loop peaks + its playhead
  /// [progress] in `0..1`) to the open window; no-op if closed.
  ///
  /// [samples] are omitted only after their delivery is acknowledged. The
  /// source spans the selected track's full loop and is refreshed during
  /// playback. Identical samples need not cross the screen link again:
  /// the window retains the acknowledged shape while samples-free frames
  /// move its playhead. Selection sends the new track's shape even when its
  /// display name matches the previous track.
  ///
  /// The returned future completes when the frame has been delivered, and
  /// **with an error when it never landed**. Frames are produced by events
  /// now, not by a timer, so on a rig that is not moving there is no next
  /// frame to heal a lost one: a caller must re-request one on that error or
  /// the second screen keeps whatever it last drew.
  Future<void> pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  );

  /// Pushes the performance readout, but ONLY when it differs from the last
  /// one pushed.
  ///
  /// The waveform rides the engine poll because its playhead moves with it;
  /// the readout does not. Diffing here is what keeps a playing loop from
  /// re-serialising eight track records sixty times a second across an engine
  /// boundary.
  ///
  /// The returned future completes when the readout has been delivered, and
  /// **with an error when it never landed**. Callers that keep a change gate
  /// of their own in front of this must clear it on that error, or a readout
  /// that was built once and dropped in flight is never rebuilt and the
  /// second screen holds stale facts for the rest of the set.
  Future<void> pushReadout(PerformanceReadout readout);

  /// Fired when the readout announces it is up — and therefore that it is
  /// holding NOTHING.
  ///
  /// Both send diffs (here and in any gate the caller keeps in front of this)
  /// are beliefs about what the second screen already shows, so a readout that
  /// comes back without this side closing it invalidates them. The service
  /// drops its own; this is how the caller hears about it and drops the one
  /// the service cannot reach.
  abstract void Function()? onWindowReady;

  /// Shows a touch calibration [target] on the Track display, a point in its
  /// normalized coordinates, with [label] saying which step it is; a `null`
  /// [target] ends calibration there. Returns `false` when the Track display
  /// cannot be reached, so there is nothing to calibrate.
  Future<bool> showCalibrationTarget(
    ({double x, double y})? target, {
    String label = '',
  });

  /// Fired with each tap on the Track display while it shows a calibration
  /// target, as a point in its normalized coordinates.
  abstract void Function(({double x, double y}) tap)? onCalibrationTap;

  /// Fired when a player touches the readout: activity on the Track
  /// display, which wakes an idle-dimmed console like a touch on the main
  /// one.
  abstract void Function()? onWindowActivity;
}

/// A no-op service: tests, and the macOS dev host, which has no Track display.
class NoopWaveformWindowService implements WaveformWindowService {
  @override
  bool get isOpen => false;

  @override
  void Function()? onWindowReady;

  @override
  void Function()? onWindowActivity;

  @override
  void Function(({double x, double y}) tap)? onCalibrationTap;

  @override
  Future<bool> open() async => true;

  @override
  Future<bool> showCalibrationTarget(
    ({double x, double y})? target, {
    String label = '',
  }) async => false;

  @override
  Future<void> close() async {}

  @override
  Future<void> pushReadout(PerformanceReadout readout) async {}

  @override
  Future<void> pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) async {}
}

/// The `waveform` payload for one frame, given the [lastSent] peaks.
///
/// Progress and the track label ride every frame — the playhead is what
/// actually moves. The peaks ride only when they differ from [lastSent]:
/// through plain playback the loop-indexed peak buffer stands still, and
/// re-sending it would copy 2 KB, pack it and cross the screen link
/// thirty times a second to redraw the same shape. Comparing the floats
/// in-process is far cheaper than shipping them.
///
/// A `null` [lastSent] is never equal to anything: nothing has been sent yet,
/// so the frame must carry samples to seed the window.
///
/// Pure so the diff can be proven without a second engine.
Map<String, Object?> waveformFramePayload({
  required Float32List samples,
  required double progress,
  required String selectedTrack,
  required Float32List? lastSent,
}) => {
  if (!_sameSamples(samples, lastSent)) 'samples': samples,
  'progress': progress,
  'selectedTrack': selectedTrack,
};

bool _sameSamples(Float32List a, Float32List? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
