import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Operating-system operations used by the UART connection lifecycle.
abstract interface class UartPedalIo {
  /// Whether the UART device node is present.
  bool exists(String device);

  /// Configures the UART as raw 8N1, without echo or flow control.
  Future<void> configure(String device, int baud);

  /// Opens one descriptor, returning a negative value on failure.
  int open(String device, {required bool forWriting});

  /// Writes bytes and returns the number accepted by the device.
  int write(int fd, Uint8List bytes);

  /// Closes a descriptor after its reader has stopped.
  void close(int fd);

  /// Starts a reader borrowing [fd]; the caller retains descriptor ownership.
  Future<UartPedalReader> startReader(int fd);
}

/// A UART reader whose termination can be awaited before freeing resources.
abstract interface class UartPedalReader {
  /// Received chunks, read errors, and completion on an unexpected exit.
  Stream<Uint8List> get bytes;

  /// Stops reading and releases its buffer after actual reader termination.
  Future<void> stop();
}

/// Linux UART operations. Serial descriptors use libc because a serial line
/// is not seekable and `File.open` rejects it with `Illegal seek`.
class NativeUartPedalIo implements UartPedalIo {
  /// Uses [allocator] for native buffers, allowing ownership to be checked
  /// with a counting allocator without opening a device.
  const NativeUartPedalIo({Allocator allocator = malloc})
    : _allocator = allocator;

  final Allocator _allocator;

  // The following calls require the Linux appliance's device/configuration.
  // The connection state machine and reader ownership are tested separately.
  // coverage:ignore-start
  @override
  bool exists(String device) => File(device).existsSync();

  @override
  Future<void> configure(String device, int baud) async {
    final result = await Process.run('stty', [
      '-F',
      device,
      '$baud',
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
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException('stty failed: ${result.stderr}', device);
    }
  }

  @override
  int open(String device, {required bool forWriting}) {
    final path = device.toNativeUtf8();
    try {
      // O_NOCTTY prevents a UART from becoming our controlling terminal.
      return _libcOpen(path, (forWriting ? 1 : 0) | 0x100);
    } finally {
      malloc.free(path);
    }
  }
  // coverage:ignore-end

  @override
  int write(int fd, Uint8List bytes) {
    final buffer = _allocator<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      return _libcWrite(fd, buffer.cast(), bytes.length);
    } finally {
      _allocator.free(buffer);
    }
  }

  @override
  void close(int fd) => _libcClose(fd);

  @override
  Future<UartPedalReader> startReader(int fd) =>
      _NativeReader.start(fd, _allocator);
}

/// The parent isolate owns the allocation, ports and reader handle. A killed
/// isolate never unwinds a finally block, so it must not own a native buffer.
class _NativeReader implements UartPedalReader {
  _NativeReader(this._buffer, this._allocator) {
    _messagesSub = _messages.listen((dynamic message) {
      if (_chunks.isClosed) return;
      if (message is Uint8List) {
        _chunks.add(message);
      } else if (message is String) {
        _chunks.addError(FileSystemException(message));
      }
    });
    _exitSub = _exited.listen((_) {
      _exit.complete();
      // A single-subscription stream buffers chunks until the link has
      // received the spawn result. Closing it must also work with no listener
      // when disposal was requested while spawning, so do not await done.
      unawaited(_chunks.close());
    });
  }

  final Pointer<Uint8> _buffer;
  final Allocator _allocator;
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _exited = ReceivePort();
  final StreamController<Uint8List> _chunks = StreamController<Uint8List>();
  late final StreamSubscription<dynamic> _messagesSub;
  late final StreamSubscription<dynamic> _exitSub;
  final Completer<void> _exit = Completer<void>();
  late final Isolate _isolate;
  Future<void>? _stopping;

  static Future<_NativeReader> start(int fd, Allocator allocator) async {
    final reader = _NativeReader(allocator<Uint8>(_readCapacity), allocator);
    try {
      reader._isolate = await Isolate.spawn(
        _readerMain,
        _ReaderArgs(reader._messages.sendPort, fd, reader._buffer.address),
        debugName: 'pedal-link-reader',
        onExit: reader._exited.sendPort,
      );
      return reader;
    } on Object {
      // coverage:ignore-start
      // VM spawn failure; no isolate received the borrowed pointer.
      await reader._release();
      rethrow;
      // coverage:ignore-end
    }
  }

  @override
  Stream<Uint8List> get bytes => _chunks.stream;

  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _isolate.kill(priority: Isolate.immediate);
    await _exit.future;
    await _release();
  }

  Future<void> _release() async {
    await _messagesSub.cancel();
    await _exitSub.cancel();
    _messages.close();
    _exited.close();
    unawaited(_chunks.close());
    _allocator.free(_buffer);
  }
}

const _readCapacity = 64;

final class _ReaderArgs {
  const _ReaderArgs(this.sendPort, this.fd, this.bufferAddress);
  final SendPort sendPort;
  final int fd;
  final int bufferAddress;
}

/// Borrows both descriptor and buffer. VMIN 0 / VTIME 1 makes read return
/// within 100 ms on the UART. The macrotask yield lets a kill request run.
Future<void> _readerMain(_ReaderArgs args) async {
  final buffer = Pointer<Uint8>.fromAddress(args.bufferAddress);
  for (;;) {
    final n = _libcRead(args.fd, buffer.cast(), _readCapacity);
    if (n < 0) {
      // coverage:ignore-start
      // Device read failures and glibc errno require the Linux UART boundary.
      final error = _errnoLocation().value;
      if (error != 4 && error != 11) {
        // EINTR and EAGAIN mean retry.
        args.sendPort.send('read failed, errno $error');
        return;
      }
      // coverage:ignore-end
    } else if (n > 0) {
      args.sendPort.send(Uint8List.fromList(buffer.asTypedList(n)));
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final DynamicLibrary _libc = DynamicLibrary.process();

// coverage:ignore-start
final int Function(Pointer<Utf8>, int) _libcOpen = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');

final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );
// coverage:ignore-end

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
