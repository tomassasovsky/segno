import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';
import 'package:segno/visualizer/waveform_window_args.dart';
import 'package:segno/visualizer/waveform_window_channel.dart';

/// Manages the secondary output-waveform window: opening/closing it and pushing
/// waveform frames to it. Injected into the app so tests use a no-op.
abstract interface class WaveformWindowService {
  /// Whether the waveform window is currently open.
  bool get isOpen;

  /// Opens the waveform window (idempotent).
  ///
  /// [title] sets the OS window title; defaults to English when omitted.
  /// Returns `true` once the window is ready, or `false` if it failed to signal
  /// readiness within the timeout — so the caller can surface the failure
  /// instead of degrading silently.
  Future<bool> open({String title = 'Segno — Output'});

  /// Closes the waveform window (idempotent).
  Future<void> close();

  /// Sends a waveform frame (loop peaks + playhead [progress] in `0..1`) to the
  /// open window; no-op if closed.
  ///
  /// [samples] are sent ONLY when they differ from the last frame sent. The
  /// source is a loop-indexed peak buffer the engine writes while capturing,
  /// so through plain playback all 512 values stand still and only [progress]
  /// moves — and re-sending them would copy 2 KB, encode it, and hop the
  /// platform channel thirty times a second to redraw the same picture. The
  /// window holds the last samples it was given, so a samples-free frame
  /// moves the playhead over the waveform already on screen.
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

  /// Handler for control commands the sub-window's volume overlay sends back
  /// (#698) — the channel's first sub→main control path. The app shell sets
  /// this to a callback that applies the command through the same blocs the
  /// main UI uses; `null` drops commands on the floor.
  abstract void Function(ReadoutControl control)? onControl;

  /// Fired when a sub-window announces it is up — and therefore that it is
  /// holding NOTHING.
  ///
  /// Both send diffs (here and in any gate the caller keeps in front of this)
  /// are beliefs about what the second screen already shows, so a window that
  /// comes back without this side closing it — an orphan reclaimed after a
  /// hot restart, a sub-window re-announcing itself — invalidates them. The
  /// service drops its own; this is how the caller hears about it and drops
  /// the one the service cannot reach.
  abstract void Function()? onWindowReady;
}

/// Opens a real second OS window via `desktop_multi_window` and streams
/// waveform frames to it over [waveformWindowChannel].
class DesktopMultiWindowWaveformService implements WaveformWindowService {
  WindowController? _controller;
  static Completer<void>? _readyCompleter;

  /// Last readout actually sent — the diff that keeps the channel quiet.
  /// Cleared on close so a re-opened window is re-seeded from scratch.
  /// Static to match [_readyCompleter]: the channel itself is process-wide.
  static PerformanceReadout? _lastReadout;

  /// Last waveform samples actually sent, for the same reason and with the
  /// same lifecycle as [_lastReadout]: a fresh window has no held samples, so
  /// closing must force the next frame to carry them.
  static Float32List? _lastSamples;
  static var _mainChannelRegistered = false;

  /// Static like [_readyCompleter]: the channel handler is process-wide, so
  /// whichever instance last set a handler owns command delivery.
  static void Function(ReadoutControl control)? _controlHandler;

  /// Static for the same reason as [_controlHandler].
  static void Function()? _readyHandler;

  @override
  void Function(ReadoutControl control)? get onControl => _controlHandler;

  @override
  set onControl(void Function(ReadoutControl control)? handler) {
    _controlHandler = handler;
  }

  @override
  void Function()? get onWindowReady => _readyHandler;

  @override
  set onWindowReady(void Function()? handler) {
    _readyHandler = handler;
  }

  /// Closes sub-windows left over from a hot restart. Dart state is reset but
  /// native windows from `desktop_multi_window` survive.
  static Future<void> closeOrphanWindows() async {
    await _ensureMainChannelRegistered();
    final current = await WindowController.fromCurrentEngine();
    for (final controller in await WindowController.getAll()) {
      if (controller.windowId == current.windowId) continue;
      if (WaveformWindowArgs.isWaveformWindow(controller.arguments)) {
        await waveformWindowChannel
            .invokeMethod('window_close')
            .catchError((Object _) => null);
      }
    }
  }

  @override
  bool get isOpen => _controller != null;

  static Future<void> _ensureMainChannelRegistered() async {
    if (_mainChannelRegistered) return;
    await waveformWindowChannel.setMethodCallHandler((call) async {
      if (call.method == waveformWindowReadyMethod) {
        // A window announcing itself holds NOTHING yet. Every send diff is a
        // belief about what is already on the second screen, so they all have
        // to be dropped here as well as in [close]: a sub-window engine that
        // comes back without this side closing it (an orphan reclaimed after
        // a hot restart, a re-announced window) would otherwise be fed
        // progress-only frames forever and show an empty waveform under a
        // moving playhead. [onWindowReady] carries the same news to the gate
        // the caller keeps in front of `pushReadout`, which this side cannot
        // reach.
        _lastSamples = null;
        _lastReadout = null;
        _readyHandler?.call();
        // Guarded: a re-announce (the path the comment above names) arrives
        // with the completer from the last open already completed, and
        // completing twice throws out of this channel handler.
        final ready = _readyCompleter;
        if (ready != null && !ready.isCompleted) ready.complete();
      }
      if (call.method == waveformWindowControlMethod) {
        final arguments = call.arguments;
        if (arguments is Map<Object?, Object?>) {
          _controlHandler?.call(ReadoutControl.fromMap(arguments));
        }
      }
      return null;
    });
    _mainChannelRegistered = true;
  }

  @override
  Future<bool> open({String title = 'Segno — Output'}) async {
    if (_controller != null) return true;
    await closeOrphanWindows();
    await _ensureMainChannelRegistered();

    _readyCompleter = Completer<void>();
    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: WaveformWindowArgs.encode(title: title),
      ),
    );
    _controller = controller;

    // The sub-window signals readiness over the channel; a timeout means it
    // never came up. Report that so the caller can show an operator-visible
    // indicator instead of leaving a dark second screen.
    var ready = true;
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => ready = false,
    );
    await controller.show();
    return ready;
  }

  @override
  Future<void> close() async {
    _controller = null;
    _readyCompleter = null;
    _lastReadout = null;
    _lastSamples = null;
    await waveformWindowChannel
        .invokeMethod('window_close')
        .catchError((Object _) => null);
    await closeOrphanWindows();
  }

  @override
  Future<void> pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) async {
    if (_controller == null) return;
    final payload = waveformFramePayload(
      samples: samples,
      progress: progress,
      selectedTrack: selectedTrack,
      lastSent: _lastSamples,
    );
    final carriesSamples = payload.containsKey('samples');
    if (carriesSamples) _lastSamples = samples;
    try {
      await waveformWindowChannel.invokeMethod('waveform', payload);
    } on Object {
      // The frame never landed, so the window does NOT hold these peaks —
      // forget them. Without this the diff is armed on a delivery that
      // failed: through steady playback the loop-indexed buffer stands still,
      // so `samples` would be suppressed on every later frame too and the
      // second screen would freeze with only the playhead moving, for the
      // rest of the set.
      //
      // Guarded on identity, like [pushReadout]: a slow frame failing after a
      // later one has already landed must not discard peaks the window really
      // does hold. Rethrown because clearing this alone is not enough — the
      // caller drives the frames now, and has to send another one.
      if (carriesSamples && identical(_lastSamples, samples)) {
        _lastSamples = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> pushReadout(PerformanceReadout readout) async {
    if (_controller == null) return;
    if (readout == _lastReadout) return;
    _lastReadout = readout;
    try {
      await waveformWindowChannel.invokeMethod('readout', readout.toMap());
    } on Object {
      // Same self-heal as [pushWaveform]: a readout the window never received
      // must not sit in the diff as one it did, or the next equal readout is
      // dropped. Rethrown rather than swallowed because this diff is only the
      // second of two — the caller holds one in front of it, and clearing
      // only this one would leave the caller never rebuilding the readout to
      // re-send.
      if (identical(_lastReadout, readout)) _lastReadout = null;
      rethrow;
    }
  }
}

/// A no-op service for tests and platforms without multi-window support.
class NoopWaveformWindowService implements WaveformWindowService {
  @override
  bool get isOpen => false;

  @override
  void Function(ReadoutControl control)? onControl;

  @override
  void Function()? onWindowReady;

  @override
  Future<bool> open({String title = 'Segno — Output'}) async => true;

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
/// re-sending it would copy 2 KB, encode it and hop the platform channel
/// thirty times a second to redraw the same shape. Comparing the floats
/// in-process is far cheaper than shipping them.
///
/// A `null` [lastSent] is never equal to anything: nothing has been sent yet,
/// so the frame must carry samples to seed the window.
///
/// Pure so the diff can be proven without a second OS window — the same
/// discipline `waveformWindowPlacement` uses for its own decision.
@visibleForTesting
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
