// coverage:ignore-file
// The one file in this package that touches a device node: the open / retry /
// read-loop / close machine around the codec, which the parser tests cover.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
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

// libc open(2) flags. O_NOCTTY keeps a serial line from becoming this
// process's controlling terminal, which would route its signals at us.
const _oRdonly = 0;
const _oWronly = 1;
const _oNoctty = 0x100;

/// The [PedalLink] over the appliance's link UART.
///
/// Owns the device for its whole lifetime: it configures the line with `stty`
/// (raw, 8N1, no echo — echo would loop the board's own bytes back at it),
/// reads it on a background isolate, and goes back to retrying if the device
/// is absent or a read or write fails. The uart overlay can land after the
/// app starts, so absence is a normal state, not an error.
///
/// The device is opened through libc rather than `dart:io`: a serial line is
/// not seekable and `File.open` refuses it (`Illegal seek`). Reads block for
/// up to one VTIME tick, so they live on their own isolate, exactly as the
/// appliance's power-key reader does; writes are a single `write(2)` from
/// here, which cannot block at this frame rate.
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

  ReceivePort? _fromReader;
  ReceivePort? _readerExited;
  StreamSubscription<dynamic>? _readerSub;
  Isolate? _reader;
  SendPort? _readerControl;
  int _writeFd = -1;
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
    if (_disposed || _writeFd < 0) return;
    final bytes = PedalLinkCodec.encode(message);
    final buffer = malloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final written = _libcWrite(_writeFd, buffer.cast(), bytes.length);
      if (written == bytes.length) return;
      _say('write to $_device returned $written of ${bytes.length}');
      unawaited(_reopen());
    } finally {
      malloc.free(buffer);
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
    if (!File(_device).existsSync()) {
      _say(
        '$_device is not present; is dtoverlay=uart3-pi5 applied? '
        'Retrying, backing off to ${_retryCeiling.inSeconds} s.',
      );
      _scheduleRetry();
      return;
    }
    try {
      // VMIN 0 / VTIME 1: a read returns whatever arrived within 100 ms, or
      // nothing — never blocks indefinitely, so the reader can be stopped.
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
      if (_disposed) return;

      final fd = _openDevice(_oWronly);
      if (fd < 0) {
        _say('opening $_device for writing failed');
        _scheduleRetry();
        return;
      }
      _writeFd = fd;

      final fromReader = ReceivePort();
      _fromReader = fromReader;
      _readerSub = fromReader.listen(_onReaderMessage);
      final exited = ReceivePort();
      _readerExited = exited;
      _reader = await Isolate.spawn(
        _readerMain,
        _ReaderArgs(fromReader.sendPort),
        debugName: 'pedal-link-reader',
        onExit: exited.sendPort,
      );
      if (_disposed) {
        await _close();
        return;
      }
      _parser
        ..droppedFrames = 0
        ..reset();
      _droppedSeen = 0;
      _noisy = false;
      _retry = _retryFloor; // the device is here; look again promptly next time
      _say('open on $_device at $_baud');
    } on Object catch (error) {
      _say('opening $_device failed: $error');
      await _close();
      _scheduleRetry();
    }
  }

  /// Handles one message from the reader isolate: a chunk of bytes, its
  /// control port at startup, or a failure string.
  void _onReaderMessage(dynamic message) {
    if (_disposed) return;
    if (message is SendPort) {
      _readerControl = message;
      return;
    }
    if (message is Uint8List) {
      final messages = _parser.push(message)..forEach(_inbound.add);
      _reportDrops(messages.length);
      return;
    }
    if (message is String) {
      _say('read from $_device failed: $message');
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

  Future<void> _close() async {
    // Ask the reader to close its own descriptor and leave. It checks between
    // reads, so this is bounded by one VTIME tick; wait for it to actually go
    // before opening the device again, or two readers would split one byte
    // stream. Kill is the backstop for a reader that never got the message.
    final reader = _reader;
    final exited = _readerExited;
    _reader = null;
    _readerExited = null;
    _readerControl?.send(null);
    _readerControl = null;
    if (reader != null) {
      if (exited != null) {
        await exited.first.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => null,
        );
        exited.close();
      }
      reader.kill(priority: Isolate.immediate);
    }
    await _readerSub?.cancel();
    _readerSub = null;
    _fromReader?.close();
    _fromReader = null;
    if (_writeFd >= 0) {
      _libcClose(_writeFd);
      _writeFd = -1;
    }
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

// --- libc, on this isolate ---------------------------------------------------

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(Pointer<Utf8>, int) _libcOpen = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');

final int Function(int, Pointer<Void>, int) _libcWrite = _libc
    .lookupFunction<
      Long Function(Int32, Pointer<Void>, Uint64),
      int Function(int, Pointer<Void>, int)
    >('write');

final int Function(int, Pointer<Void>, int) _libcRead = _libc
    .lookupFunction<
      Long Function(Int32, Pointer<Void>, Uint64),
      int Function(int, Pointer<Void>, int)
    >('read');

final int Function(int) _libcClose = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

/// glibc keeps `errno` per thread behind this accessor.
final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );

int _errno() => _errnoLocation().value;

/// Interrupted by a signal, and "nothing to read yet": both mean retry.
const _eintr = 4;
const _eagain = 11;

int _openDevice(int flags) {
  final path = _device.toNativeUtf8();
  try {
    return _libcOpen(path, flags | _oNoctty);
  } finally {
    malloc.free(path);
  }
}

// --- the reader isolate ------------------------------------------------------

final class _ReaderArgs {
  const _ReaderArgs(this.sendPort);

  final SendPort sendPort;
}

/// Reads the line until told to stop, forwarding every chunk to the link.
///
/// `read` blocks for up to one VTIME tick (100 ms), which is why this is an
/// isolate: the same shape the appliance's power-key reader uses. A zero-byte
/// return is that timeout, not end of file — a serial line has no end.
///
/// The loop yields to this isolate's own event loop on every pass. Without
/// that the stop message below could never be delivered — a synchronous loop
/// never returns to the event loop, and `Isolate.kill` at the default priority
/// waits for the current event, which is this function — so the link could
/// neither close its descriptor nor stop reading, and the next reopen would
/// leave two readers splitting one byte stream between them.
Future<void> _readerMain(_ReaderArgs args) async {
  final fd = _openDevice(_oRdonly);
  if (fd < 0) {
    args.sendPort.send('open for reading returned $fd');
    return;
  }

  // A message here — any message — means stop.
  var stopped = false;
  final control = ReceivePort()..listen((_) => stopped = true);
  args.sendPort.send(control.sendPort);

  const capacity = 64;
  final buffer = malloc<Uint8>(capacity);
  try {
    while (!stopped) {
      final n = _libcRead(fd, buffer.cast(), capacity);
      if (n < 0) {
        final error = _errno();
        // A signal delivered mid-read, or a line with nothing on it yet, is
        // not a broken port: retry rather than tearing the link down and
        // backing off, which would darken the panel for seconds.
        if (error == _eintr || error == _eagain) {
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        args.sendPort.send('read failed, errno $error');
        return;
      }
      if (n > 0) {
        args.sendPort.send(Uint8List.fromList(buffer.asTypedList(n)));
      }
      // Let the control port be serviced.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    malloc.free(buffer);
    _libcClose(fd);
    control.close();
  }
}
