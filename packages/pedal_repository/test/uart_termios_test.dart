@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/src/uart_pedal_io.dart';
import 'package:pedal_repository/src/uart_termios.dart';

/// Drives [configureRawUart] on pseudo-terminals, which keep every termios
/// setting a serial driver would, and compares the result with what `stty`
/// itself does to a second, identical pseudo-terminal.
void main() {
  late List<int> masters;

  setUp(() => masters = []);
  tearDown(() => masters.forEach(_close));

  /// Opens a new pseudo-terminal and returns its slave device path.
  String pty() {
    final master = _posixOpenpt(_oRdwr | _oNoctty);
    expect(master, greaterThanOrEqualTo(0));
    masters.add(master);
    expect(_grantpt(master), 0);
    expect(_unlockpt(master), 0);
    return _ptsname(master).toDartString();
  }

  test('sets exactly what stty set', () {
    final ours = pty();
    final theirs = pty();
    expect(_termios(ours), _termios(theirs), reason: 'identical before');

    configureRawUart(ours, 115200);
    final stty = Process.runSync('stty', [
      '-F',
      theirs,
      '115200',
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
    expect(stty.exitCode, 0, reason: '${stty.stderr}');

    expect(_termios(ours), _termios(theirs));
  });

  test('NativeUartPedalIo.configure leaves the line raw 8N1 at the rate, '
      'with VMIN 0 and VTIME 1', () async {
    final device = pty();
    await const NativeUartPedalIo().configure(device, 115200);
    final mode = ByteData.sublistView(Uint8List.fromList(_termios(device)));
    expect(mode.getUint32(0, Endian.host), 0, reason: 'c_iflag');
    expect(mode.getUint32(4, Endian.host) & 0x1, 0, reason: 'OPOST');
    final cflag = mode.getUint32(8, Endian.host);
    expect(cflag & 0x30, 0x30, reason: 'CS8');
    expect(cflag & (0x40 | 0x100 | 0x80000000), 0, reason: 'CSTOPB PARENB');
    expect(cflag & 0x800, 0x800, reason: 'CLOCAL');
    expect(cflag & 0x100f, 0x1002, reason: 'B115200');
    expect(mode.getUint32(12, Endian.host) & (0x1 | 0x2 | 0x8), 0);
    expect(mode.getUint8(17 + 6), 0, reason: 'VMIN');
    expect(mode.getUint8(17 + 5), 1, reason: 'VTIME');
  });

  test('NativeUartPedalIo.configure reports a failure from its isolate', () {
    expect(
      const NativeUartPedalIo().configure('/dev/null', 115200),
      throwsA(
        isA<FileSystemException>()
            .having((e) => e.path, 'path', '/dev/null')
            .having((e) => e.message, 'message', 'tcgetattr failed'),
      ),
    );
  });

  test('names the device when it cannot be opened', () {
    expect(
      () => configureRawUart('/dev/segno-no-such-uart', 115200),
      throwsA(
        isA<FileSystemException>()
            .having((e) => e.path, 'path', '/dev/segno-no-such-uart')
            .having((e) => e.osError?.errorCode, 'errno', 2),
      ),
    );
  });

  test('names the device when it is not a terminal', () {
    expect(
      () => configureRawUart('/dev/null', 115200),
      throwsA(
        isA<FileSystemException>()
            .having((e) => e.path, 'path', '/dev/null')
            .having((e) => e.message, 'message', 'tcgetattr failed'),
      ),
    );
  });

  test('rejects a rate stty would not take by number', () {
    expect(() => configureRawUart(pty(), 12345), throwsArgumentError);
  });
}

/// The 60 bytes of glibc's `struct termios` for [device].
List<int> _termios(String device) {
  final path = device.toNativeUtf8();
  final fd = _open(path, _oRdonly | _oNoctty | _oNonblock);
  malloc.free(path);
  expect(fd, greaterThanOrEqualTo(0));
  final buffer = calloc<Uint8>(60);
  try {
    expect(_tcgetattr(fd, buffer), 0);
    return List.of(buffer.asTypedList(60));
  } finally {
    calloc.free(buffer);
    _close(fd);
  }
}

const _oRdonly = 0;
const _oRdwr = 2;
const _oNoctty = 0x100;
const _oNonblock = 0x800;

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(int) _posixOpenpt = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('posix_openpt');

final int Function(int) _grantpt = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('grantpt');

final int Function(int) _unlockpt = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('unlockpt');

final Pointer<Utf8> Function(int) _ptsname = _libc
    .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
      'ptsname',
    );

final int Function(Pointer<Utf8>, int) _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');

final int Function(int) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

final int Function(int, Pointer<Uint8>) _tcgetattr = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('tcgetattr');
