import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';
import 'package:segno/visualizer/screen_link.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

/// [WaveformWindowService] for an embedder that runs the readout as its own
/// engine on its own output (ivi-homescreen on the appliance).
///
/// The embedder, not the app, creates the readout screen, and it exists from
/// boot. So "open" here means "the readout engine has announced itself, and is
/// told to draw", and "close" means "told to draw nothing". Frames and readouts
/// travel over the screen link (see `screen_link.dart`) and are acknowledged
/// by the readout, which keeps this service's contract: a push that never
/// lands completes with an error, so the caller re-queues it.
class ScreenLinkWaveformService implements WaveformWindowService {
  /// Creates a [ScreenLinkWaveformService].
  ScreenLinkWaveformService({
    PortDirectory directory = const IsolateNameServerDirectory(),
    this.readyTimeout = const Duration(seconds: 10),
    this.ackTimeout = const Duration(seconds: 2),
  }) : _directory = directory;

  final PortDirectory _directory;

  /// How long [open] waits for the readout engine to announce itself.
  final Duration readyTimeout;

  /// How long a push waits for the readout to acknowledge it.
  final Duration ackTimeout;

  ReceivePort? _inbox;
  SendPort? _screen;
  Completer<void>? _ready;
  var _open = false;
  var _seq = 0;
  final _acks = <int, Completer<void>>{};

  /// Last acknowledged samples and readout: the diffs that keep the link
  /// quiet, with the same revision discipline as
  /// [DesktopMultiWindowWaveformService].
  Float32List? _lastSamples;
  var _sampleRevision = 0;
  PerformanceReadout? _lastReadout;
  var _readoutRevision = 0;

  @override
  void Function(ReadoutControl control)? onControl;

  @override
  void Function()? onWindowReady;

  @override
  bool get isOpen => _open;

  /// Publishes this end's inbox and greets a readout that came up first.
  ///
  /// The two engines start concurrently. Whichever publishes second finds the
  /// other and speaks first: the readout announces itself on start, and this
  /// side's [ScreenLinkOp.hello] prompts the announcement the readout could not
  /// make when nobody was listening yet.
  void _listen() {
    if (_inbox != null) return;
    final inbox = _inbox = ReceivePort('segno screen link (main)')
      ..listen(_onMessage);
    _directory.publish(screenLinkMainPort, inbox.sendPort);
    _directory.lookup(screenLinkReadoutPort)?.send({'op': ScreenLinkOp.hello});
  }

  void _onMessage(Object? message) {
    if (message is! Map<Object?, Object?>) return;
    switch (message['op']) {
      case ScreenLinkOp.ready:
        final port = message['port'];
        if (port is! SendPort) return;
        _screen = port;
        // An announcing readout holds nothing, so every diff here is void, and
        // anything still awaiting an ack from an earlier announcement will
        // never get one.
        _forgetScreenState();
        onWindowReady?.call();
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
        if (_open) port.send({'op': ScreenLinkOp.show});
      case ScreenLinkOp.ack:
        final seq = message['seq'];
        if (seq is int) _acks.remove(seq)?.complete();
      case ScreenLinkOp.control:
        final control = message['control'];
        if (control is Map<Object?, Object?>) {
          onControl?.call(ReadoutControl.fromMap(control));
        }
    }
  }

  void _forgetScreenState() {
    _lastSamples = null;
    _lastReadout = null;
    _sampleRevision++;
    _readoutRevision++;
    final pending = _acks.values.toList();
    _acks.clear();
    for (final ack in pending) {
      ack.completeError(StateError('the readout screen restarted'));
    }
  }

  @override
  Future<bool> open({String title = 'Segno — Output'}) async {
    _listen();
    if (_open) return true;
    if (_screen == null) {
      final ready = _ready ??= Completer<void>();
      var arrived = true;
      await ready.future.timeout(
        readyTimeout,
        onTimeout: () => arrived = false,
      );
      if (!arrived) return false;
    }
    _open = true;
    _screen?.send({'op': ScreenLinkOp.show});
    return true;
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _forgetScreenState();
    _screen?.send({'op': ScreenLinkOp.hide});
  }

  @override
  Future<void> pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) async {
    if (!_open) return;
    final payload = waveformFramePayload(
      samples: samples,
      progress: progress,
      selectedTrack: selectedTrack,
      lastSent: _lastSamples,
    );
    final carriesSamples = payload.containsKey('samples');
    final revision = carriesSamples ? ++_sampleRevision : _sampleRevision;
    if (carriesSamples) _lastSamples = null;
    await _request({
      'op': ScreenLinkOp.waveform,
      'progress': progress,
      'selectedTrack': selectedTrack,
      if (carriesSamples) 'samples': packSamples(samples),
    });
    if (carriesSamples && revision == _sampleRevision) _lastSamples = samples;
  }

  @override
  Future<void> pushReadout(PerformanceReadout readout) async {
    if (!_open) return;
    if (readout == _lastReadout) return;
    final revision = ++_readoutRevision;
    _lastReadout = null;
    await _request({
      'op': ScreenLinkOp.readout,
      'readout': sendableCopy(readout.toMap()),
    });
    if (revision == _readoutRevision) _lastReadout = readout;
  }

  /// Sends [message] with a fresh `seq` and completes when the readout
  /// acknowledges it; throws when it does not within [ackTimeout].
  Future<void> _request(Map<String, Object?> message) async {
    final screen = _screen;
    if (screen == null) throw StateError('the readout screen is not linked');
    final seq = ++_seq;
    final ack = _acks[seq] = Completer<void>();
    screen.send({...message, 'seq': seq});
    try {
      await ack.future.timeout(ackTimeout);
    } finally {
      _acks.remove(seq);
    }
  }
}
