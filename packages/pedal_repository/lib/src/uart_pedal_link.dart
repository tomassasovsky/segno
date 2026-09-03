// coverage:ignore-file
// The one file in this package that touches a device node. Its logic is a
// handful of dart:io calls around the codec, which the parser tests cover.

import 'dart:async';
import 'dart:io';

import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';

/// Where the console board's link lands on the appliance: the Pi 5's uart3
/// (GPIO8/9, `dtoverlay=uart3-pi5`), which the board's ribbon carries to the
/// Pico 2's UART0.
const kConsolePedalDevice = '/dev/ttyAMA3';

/// The line settings the board expects; the same on both ends.
const kConsolePedalBaud = 115200;

/// The [PedalLink] over a Linux serial device.
///
/// Owns the device for its whole lifetime: it opens the device path when the
/// node exists, keeps retrying while it does not (the uart overlay can
/// land after the app starts), configures the line with `stty` (raw, 8N1, no
/// echo — echo would loop the board's own bytes back at it), reads it on a
/// bounded loop, and goes back to retrying if a read or write fails. Nothing
/// here blocks for longer than one read timeout, so [dispose] is bounded
/// whether or not a board is talking.
///
/// Every state change is reported through the `log` callback, one line each,
/// so the appliance's persistent log says why a panel is dark.
class UartPedalLink implements PedalLink {
  /// Creates the link and starts opening `path`.
  UartPedalLink({
    String path = kConsolePedalDevice,
    int baud = kConsolePedalBaud,
    Duration retry = const Duration(seconds: 2),
    void Function(String message)? log,
  }) : _path = path,
       _baud = baud,
       _retry = retry,
       _log = log {
    unawaited(_open());
  }

  final String _path;
  final int _baud;
  final Duration _retry;
  final void Function(String message)? _log;
  final PedalLinkParser _parser = PedalLinkParser();
  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();

  RandomAccessFile? _reader;
  RandomAccessFile? _writer;
  Future<void>? _readLoop;
  Timer? _retryTimer;
  String? _lastLogged;
  bool _disposed = false;

  /// The device this link opens.
  String get path => _path;

  /// Whether the device is currently open.
  bool get isOpen => _writer != null;

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) {
    final writer = _writer;
    if (_disposed || writer == null) return;
    try {
      writer.writeFromSync(PedalLinkCodec.encode(message));
    } on FileSystemException catch (error) {
      _say('write to $_path failed: $error');
      unawaited(_reopen());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    await _close();
    await _inbound.close();
  }

  Future<void> _open() async {
    if (_disposed) return;
    final file = File(_path);
    if (!file.existsSync()) {
      _say(
        '$_path is not present; is dtoverlay=uart3-pi5 applied? '
        'Retrying every ${_retry.inSeconds} s.',
      );
      _scheduleRetry();
      return;
    }
    try {
      // VMIN 0 / VTIME 1: a read returns whatever arrived within 100 ms, or
      // nothing — never blocks indefinitely, so the read loop can be stopped.
      final stty = await Process.run('stty', [
        '-F',
        _path,
        '$_baud',
        'cs8',
        '-parenb',
        '-cstopb',
        'raw',
        '-echo',
        '-crtscts',
        'clocal',
        'min',
        '0',
        'time',
        '1',
      ]).timeout(const Duration(seconds: 5));
      if (stty.exitCode != 0) {
        _say('stty failed on $_path: ${stty.stderr}');
        _scheduleRetry();
        return;
      }
      _reader = await file.open();
      _writer = await file.open(mode: FileMode.writeOnlyAppend);
      _say('open on $_path at $_baud');
      _readLoop = _read(_reader!);
    } on Object catch (error) {
      _say('opening $_path failed: $error');
      await _close();
      _scheduleRetry();
    }
  }

  Future<void> _read(RandomAccessFile reader) async {
    try {
      while (!_disposed && identical(_reader, reader)) {
        final chunk = await reader.read(64);
        if (chunk.isNotEmpty) _parser.push(chunk).forEach(_inbound.add);
      }
    } on Object catch (error) {
      if (_disposed) return;
      _say('read from $_path failed: $error');
      unawaited(_reopen());
    }
  }

  Future<void> _reopen() async {
    await _close();
    _scheduleRetry();
  }

  Future<void> _close() async {
    final reader = _reader;
    final writer = _writer;
    _reader = null;
    _writer = null;
    // The loop notices _reader changed on its next (≤ 100 ms) read.
    final loop = _readLoop;
    _readLoop = null;
    if (loop != null) await loop;
    await reader?.close();
    await writer?.close();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry, () => unawaited(_open()));
  }

  /// Logs [message] unless it is the same line as the last one, so a device
  /// that stays absent costs one line, not one every retry.
  void _say(String message) {
    if (message == _lastLogged) return;
    _lastLogged = message;
    _log?.call('pedal link: $message');
  }
}
