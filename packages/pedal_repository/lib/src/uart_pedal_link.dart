// coverage:ignore-file
// The one file in this package that touches a device node: the open / retry /
// read-loop / close machine around the codec, which the parser tests cover.

import 'dart:async';
import 'dart:io';

import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';

/// Where the console board's link lands on the appliance: the Pi 5's uart3
/// (GPIO8/9, `dtoverlay=uart3-pi5`), which the board's ribbon carries to the
/// Pico 2's UART0.
const _device = '/dev/ttyAMA3';

/// The line settings the board expects; the same on both ends.
const _baud = 115200;

/// How soon to look again after the device turns out to be absent or a step
/// of the open fails, and the ceiling that delay backs off to. The overlay
/// usually lands within a retry or two of launch; a unit that is simply
/// misconfigured should not fork `stty` every two seconds forever.
const _retryFloor = Duration(seconds: 2);
const _retryCeiling = Duration(seconds: 30);

/// The [PedalLink] over the appliance's link UART.
///
/// Owns the device for its whole lifetime: it opens the node when it exists,
/// keeps retrying while it does not (the uart overlay can land after the app
/// starts), configures the line with `stty` (raw, 8N1, no echo — echo would
/// loop the board's own bytes back at it), reads it on a bounded loop, and
/// goes back to retrying if a read or write fails. Nothing here blocks for
/// longer than one read timeout, so [dispose] is bounded whether or not a
/// board is talking.
///
/// Every state change is reported through the `log` callback, one line each,
/// so the appliance's persistent log says why a panel is dark.
class UartPedalLink implements PedalLink {
  /// Creates the link and starts opening the device.
  UartPedalLink({void Function(String message)? log}) : _log = log {
    unawaited(_open());
  }

  final void Function(String message)? _log;
  final PedalLinkParser _parser = PedalLinkParser();
  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();

  RandomAccessFile? _reader;
  RandomAccessFile? _writer;
  Future<void>? _readLoop;
  Future<void>? _closing;
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
    final writer = _writer;
    if (_disposed || writer == null) return;
    try {
      writer.writeFromSync(PedalLinkCodec.encode(message));
    } on FileSystemException catch (error) {
      _say('write to $_device failed: $error');
      unawaited(_reopen());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    await (_closing ?? _close());
    await _inbound.close();
  }

  Future<void> _open() async {
    if (_disposed) return;
    final file = File(_device);
    if (!file.existsSync()) {
      _say(
        '$_device is not present; is dtoverlay=uart3-pi5 applied? '
        'Retrying, backing off to ${_retryCeiling.inSeconds} s.',
      );
      _scheduleRetry();
      return;
    }
    // Held here, not in the fields, until both are open: a failure part-way
    // (the node readable but not writable, say) must close what did open, or
    // every retry leaks a descriptor.
    RandomAccessFile? reader;
    RandomAccessFile? writer;
    try {
      // VMIN 0 / VTIME 1: a read returns whatever arrived within 100 ms, or
      // nothing — never blocks indefinitely, so the read loop can be stopped.
      final stty = await Process.run('stty', [
        '-F',
        _device,
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
        _say('stty failed on $_device: ${stty.stderr}');
        _scheduleRetry();
        return;
      }
      reader = await file.open();
      writer = await file.open(mode: FileMode.writeOnlyAppend);
      if (_disposed) {
        // dispose() ran while stty / open were in flight; nothing else will
        // close these.
        await reader.close();
        await writer.close();
        return;
      }
      _reader = reader;
      _writer = writer;
      _parser
        ..droppedFrames = 0
        ..reset();
      _droppedSeen = 0;
      _noisy = false;
      _retry = _retryFloor; // the device is here; look again promptly next time
      _say('open on $_device at $_baud');
      _readLoop = _read(reader);
    } on Object catch (error) {
      _say('opening $_device failed: $error');
      await _discard(reader);
      await _discard(writer);
      _scheduleRetry();
    }
  }

  static Future<void> _discard(RandomAccessFile? handle) async {
    try {
      await handle?.close();
    } on Object {
      // Already on the failure path; the retry is the recovery.
    }
  }

  Future<void> _read(RandomAccessFile reader) async {
    try {
      while (!_disposed && identical(_reader, reader)) {
        final chunk = await reader.read(64);
        if (chunk.isEmpty) continue;
        final messages = _parser.push(chunk)..forEach(_inbound.add);
        _reportDrops(messages.length);
      }
    } on Object catch (error) {
      if (_disposed) return;
      _say('read from $_device failed: $error');
      unawaited(_reopen());
    }
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

  Future<void> _reopen() async {
    await _close();
    _scheduleRetry();
  }

  Future<void> _close() {
    final closing = _closing;
    if (closing != null) return closing;
    return _closing = () async {
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
      _closing = null;
    }();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry, () => unawaited(_open()));
    final next = _retry * 2;
    _retry = next > _retryCeiling ? _retryCeiling : next;
  }

  /// Logs [message] unless it is the same line as the last one, so a device
  /// that stays absent costs one line, not one every retry.
  void _say(String message) {
    if (message == _lastLogged) return;
    _lastLogged = message;
    _log?.call('pedal link: $message');
  }
}
