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
  void pushWaveform(Float32List samples, double progress, String selectedTrack);

  /// Pushes the performance readout, but ONLY when it differs from the last
  /// one pushed.
  ///
  /// The waveform rides a per-frame timer because its samples change every
  /// frame; the readout does not. Diffing here is what keeps a playing loop
  /// from re-serialising eight track records sixty times a second across an
  /// engine boundary.
  void pushReadout(PerformanceReadout readout);

  /// Handler for control commands the sub-window's volume overlay sends back
  /// (#698) — the channel's first sub→main control path. The app shell sets
  /// this to a callback that applies the command through the same blocs the
  /// main UI uses; `null` drops commands on the floor.
  abstract void Function(ReadoutControl control)? onControl;
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

  @override
  void Function(ReadoutControl control)? get onControl => _controlHandler;

  @override
  set onControl(void Function(ReadoutControl control)? handler) {
    _controlHandler = handler;
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
        _readyCompleter?.complete();
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
  void pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) {
    if (_controller == null) return;
    final payload = waveformFramePayload(
      samples: samples,
      progress: progress,
      selectedTrack: selectedTrack,
      lastSent: _lastSamples,
    );
    final carriesSamples = payload.containsKey('samples');
    if (carriesSamples) _lastSamples = samples;
    unawaited(
      waveformWindowChannel.invokeMethod('waveform', payload).catchError((
        Object _,
      ) {
        // The frame never landed, so the window does NOT hold these peaks —
        // forget them. Without this the diff is armed on a delivery that
        // failed: through steady playback the loop-indexed buffer stands
        // still, so `samples` would be suppressed on every later frame too
        // and the second screen would freeze with only the playhead moving,
        // for the rest of the set. Clearing makes the next frame re-seed it,
        // which is how a dropped frame healed itself before the diff existed.
        if (carriesSamples) _lastSamples = null;
        return null;
      }),
    );
  }

  @override
  void pushReadout(PerformanceReadout readout) {
    if (_controller == null) return;
    if (readout == _lastReadout) return;
    _lastReadout = readout;
    unawaited(
      waveformWindowChannel.invokeMethod('readout', readout.toMap()).catchError(
        (Object _) {
          // Same self-heal as [pushWaveform]: a readout the window never
          // received must not sit in the diff as one it did, or the next
          // equal readout is dropped and the second screen holds stale
          // facts until something else about the rig changes.
          if (identical(_lastReadout, readout)) _lastReadout = null;
          return null;
        },
      ),
    );
  }
}

/// A no-op service for tests and platforms without multi-window support.
class NoopWaveformWindowService implements WaveformWindowService {
  @override
  bool get isOpen => false;

  @override
  void Function(ReadoutControl control)? onControl;

  @override
  Future<bool> open({String title = 'Segno — Output'}) async => true;

  @override
  Future<void> close() async {}

  @override
  void pushReadout(PerformanceReadout readout) {}

  @override
  void pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) {}
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
