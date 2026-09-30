import 'dart:async';
import 'dart:typed_data';

import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/uart_pedal_io.dart';

/// The Pi 5's uart3 (GPIO8/9) reaches the console board's Pico 2 UART0.
const _device = '/dev/ttyAMA3';
const _baud = 115200;
const _retryFloor = Duration(seconds: 2);
const _retryCeiling = Duration(seconds: 30);

/// Owns the console board's UART link, retrying when it cannot be opened or
/// when a reader or write fails. Byte parsing and connection lifecycle run
/// here; [UartPedalIo] contains the operating-system boundary.
///
/// Disposal waits for any pending open and for the reader to exit before
/// releasing its descriptors. Concurrent failures share one recovery, so a
/// late close cannot tear down a replacement connection.
class UartPedalLink implements PedalLink {
  /// Starts opening the appliance UART. [io] allows device-free lifecycle
  /// tests; production uses the native UART implementation.
  UartPedalLink({UartPedalIo? io, void Function(String message)? log})
    : _io = io ?? const NativeUartPedalIo(),
      _log = log {
    _startOpen();
  }

  final UartPedalIo _io;
  final void Function(String message)? _log;
  final PedalLinkParser _parser = PedalLinkParser();
  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();

  UartPedalReader? _reader;
  StreamSubscription<Uint8List>? _readerSub;
  int _readFd = -1;
  int _writeFd = -1;
  Future<void>? _opening;
  Future<void>? _closing;
  Future<void>? _recovering;
  Future<void>? _disposing;
  Timer? _retryTimer;
  String? _lastLogged;
  Duration _retry = _retryFloor;
  int _droppedSeen = 0;
  bool _noisy = false;
  bool _disposed = false;

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) {
    if (_disposed || _recovering != null || _writeFd < 0) return;
    final bytes = PedalLinkCodec.encode(message);
    try {
      final written = _io.write(_writeFd, bytes);
      if (written == bytes.length) return;
      _say('write to $_device returned $written of ${bytes.length}');
    } on Object catch (error) {
      _say('write to $_device failed: $error');
    }
    _reopen();
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    await _opening;
    await _recovering;
    await _close();
    await _inbound.close();
  }

  void _startOpen() {
    if (_disposed || _opening != null) return;
    _opening = _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    try {
      if (!_io.exists(_device)) {
        _say(
          '$_device is not present; is dtoverlay=uart3-pi5 applied? '
          'Retrying, backing off to ${_retryCeiling.inSeconds} s.',
        );
        _scheduleRetry();
        return;
      }
      await _io.configure(_device, _baud).timeout(const Duration(seconds: 5));
      if (_disposed) return;
      _writeFd = _io.open(_device, forWriting: true);
      if (_writeFd < 0) throw StateError('opening for writing failed');
      _readFd = _io.open(_device, forWriting: false);
      if (_readFd < 0) throw StateError('opening for reading failed');
      _reader = await _io.startReader(_readFd);
      // A pending spawn must settle before disposal can release descriptors.
      // The disposer owns cleanup when it was requested during this await.
      if (_disposed) return;
      _parser
        ..droppedFrames = 0
        ..reset();
      _droppedSeen = 0;
      _noisy = false;
      _readerSub = _reader!.bytes.listen(
        _onBytes,
        onError: (Object error) {
          _say('read from $_device failed: $error');
          _reopen();
        },
        onDone: () {
          _say('the reader stopped unexpectedly');
          _reopen();
        },
      );
      _retry = _retryFloor;
      _say('open on $_device at $_baud');
    } on Object catch (error) {
      _say('opening $_device failed: $error');
      await _close();
      _scheduleRetry();
    }
  }

  void _onBytes(Uint8List bytes) {
    if (_disposed || _recovering != null) return;
    final messages = _parser.push(bytes)..forEach(_inbound.add);
    _reportDrops(messages.length);
  }

  /// Logs the two edges of a noisy line rather than the noise itself: one
  /// line when frames start being dropped, one with the total when good
  /// frames come through again. A line that is nothing but noise — the board
  /// held in reset while it is reflashed, a wrong baud, a floating RX — then
  /// costs two lines instead of one per read, which would churn the
  /// persistent log through its rotation and evict the breadcrumb that
  /// matters. [messages] is how many good frames the last chunk finished.
  void _reportDrops(int messages) {
    final dropped = _parser.droppedFrames;
    if (dropped > _droppedSeen) {
      _droppedSeen = dropped;
      if (!_noisy) {
        _noisy = true;
        _say('dropping frames on $_device; the total follows when it settles');
      }
      return;
    }
    if (_noisy && messages > 0) {
      _noisy = false;
      _say('$dropped frame(s) dropped on $_device in all; frames are arriving');
    }
  }

  void _reopen() {
    if (_disposed || _recovering != null) return;
    _recovering = _recover().whenComplete(() => _recovering = null);
  }

  Future<void> _recover() async {
    await _opening;
    await _close();
    _scheduleRetry();
  }

  Future<void> _close() =>
      _closing ??= _closeResources().whenComplete(() => _closing = null);

  Future<void> _closeResources() async {
    final reader = _reader;
    final readFd = _readFd;
    final writeFd = _writeFd;
    _reader = null;
    _readFd = -1;
    _writeFd = -1;
    await _readerSub?.cancel();
    _readerSub = null;
    // stop() confirms actual isolate exit, not merely a kill request.
    await reader?.stop();
    if (readFd >= 0) _io.close(readFd);
    if (writeFd >= 0) _io.close(writeFd);
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry, _startOpen);
    final next = _retry * 2;
    _retry = next > _retryCeiling ? _retryCeiling : next;
  }

  void _say(String message) {
    if (message == _lastLogged) return;
    _lastLogged = message;
    _log?.call('pedal link: $message');
  }
}
