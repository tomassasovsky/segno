import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:segno/visualizer/performance_readout.dart';
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

  /// Whether the readout should be drawn: set by [open], cleared by [close].
  var _open = false;

  /// Whether an [open] is waiting for the readout to announce itself. The
  /// announcement opens the link itself (see [_onMessage]), and a [close] in
  /// the meantime cancels that rather than racing it.
  var _opening = false;

  /// Bumped by every [open] that waits, so a wait that times out only gives
  /// up on its own behalf, not on a newer [open] sharing the same [_ready].
  var _openGeneration = 0;
  var _seq = 0;
  final _acks = <int, Completer<void>>{};

  /// Last acknowledged samples and readout: the diffs that keep the link
  /// quiet. A revision that moved while a push was in flight leaves the diff
  /// empty, so the next push carries everything again.
  Float32List? _lastSamples;
  var _sampleRevision = 0;
  PerformanceReadout? _lastReadout;
  var _readoutRevision = 0;

  @override
  void Function()? onWindowActivity;

  @override
  void Function(({double x, double y}) tap)? onCalibrationTap;

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
        // The link is open BEFORE anyone hears of the announcement: the caller
        // re-seeds the readout from [onWindowReady], and a push made while
        // still closed would be dropped without the error that makes the
        // caller retry it — on a quiet rig, a blank waveform for good.
        if (_opening) {
          _opening = false;
          _open = true;
        }
        // A closed link has nothing to re-seed: the next open starts from
        // scratch anyway.
        if (_open) {
          port.send({'op': ScreenLinkOp.show});
          onWindowReady?.call();
        } else {
          // Say so: a readout left showing by an earlier main screen would
          // otherwise hold its last picture.
          port.send({'op': ScreenLinkOp.hide});
        }
        final ready = _ready;
        _ready = null;
        if (ready != null && !ready.isCompleted) ready.complete();
      case ScreenLinkOp.ack:
        final seq = message['seq'];
        if (seq is int) _acks.remove(seq)?.complete();
      case ScreenLinkOp.activity:
        onWindowActivity?.call();
      case ScreenLinkOp.calibrationTap:
        final x = message['x'];
        final y = message['y'];
        if (x is num && y is num) {
          onCalibrationTap?.call((x: x.toDouble(), y: y.toDouble()));
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

  /// Returns once the readout is reachable, `true`, or [readyTimeout] passed
  /// without it announcing itself, `false`. A [close] while waiting leaves the
  /// readout blank either way.
  @override
  Future<bool> open() async {
    _listen();
    if (_open) return true;
    if (_screen != null) {
      _open = true;
      _screen!.send({'op': ScreenLinkOp.show});
      return true;
    }
    _opening = true;
    final generation = ++_openGeneration;
    final ready = _ready ??= Completer<void>();
    var arrived = true;
    await ready.future.timeout(
      readyTimeout,
      onTimeout: () => arrived = false,
    );
    if (!arrived && generation == _openGeneration) _opening = false;
    return arrived;
  }

  /// Calibration does not depend on the readout preference: the 7" is
  /// calibrated whether or not it is showing the readout, and the readout
  /// goes back to what it was showing when calibration ends.
  @override
  Future<bool> showCalibrationTarget(
    ({double x, double y})? target, {
    String label = '',
  }) async {
    _listen();
    final screen = _screen;
    if (screen == null) return false;
    screen.send({
      'op': ScreenLinkOp.calibrate,
      'target': target == null ? null : [target.x, target.y],
      'label': label,
    });
    return true;
  }

  @override
  Future<void> close() async {
    // Listening even to close: a readout that announces itself later is then
    // told to stay blank (see [_onMessage]).
    _listen();
    _opening = false;
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
    final message = waveformFramePayload(
      samples: samples,
      progress: progress,
      selectedTrack: selectedTrack,
      lastSent: _lastSamples,
    );
    final carriesSamples = message.containsKey('samples');
    final revision = carriesSamples ? ++_sampleRevision : _sampleRevision;
    if (carriesSamples) {
      _lastSamples = null;
      message['samples'] = packSamples(samples);
    }
    message['op'] = ScreenLinkOp.waveform;
    await _request(message);
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
    message['seq'] = seq;
    screen.send(message);
    try {
      await ack.future.timeout(ackTimeout);
    } finally {
      _acks.remove(seq);
    }
  }
}
