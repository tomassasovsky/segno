import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Sets a Linux serial line to raw 8N1 at [baud], with no echo, no flow
/// control and `VMIN 0` / `VTIME 1`: exactly what `stty -F device baud cs8
/// -parenb -cstopb raw -echo -crtscts clocal min 0 time 1` did, through
/// `termios` and no helper process. Starting
/// `stty` forked the app, which stalls the audio thread (#1367), and a pedal
/// can be plugged in mid-take.
///
/// It follows stty step by step: open the device read-only and
/// non-blocking, so a line with no carrier does not hold the open, clear
/// `O_NONBLOCK`, read the settings, change them, write them back with
/// `TCSADRAIN`, and read them again to check that the driver took every one
/// of them, since `tcsetattr` succeeds when it applies any. Throws a
/// [FileSystemException] naming [device] when a step fails.
void configureRawUart(String device, int baud) {
  final speed = _speeds[baud];
  if (speed == null) {
    throw ArgumentError.value(baud, 'baud', 'is not a standard serial rate');
  }
  final path = device.toNativeUtf8();
  final fd = _open(path, _oRdonly | _oNoctty | _oNonblock | _oCloexec);
  malloc.free(path);
  if (fd < 0) _fail('open', device);
  final wanted = calloc<_Termios>();
  final applied = calloc<_Termios>();
  try {
    final flags = _fcntl(fd, _fGetfl, 0);
    if (flags < 0 || _fcntl(fd, _fSetfl, flags & ~_oNonblock) < 0) {
      _fail('fcntl', device);
    }
    if (_tcgetattr(fd, wanted) != 0) _fail('tcgetattr', device);
    final mode = wanted.ref;

    // The stty arguments in order. <baud>:
    if (_cfsetispeed(wanted, speed) != 0 || _cfsetospeed(wanted, speed) != 0) {
      _fail('cfsetspeed', device);
    }
    mode
      // cs8 -parenb -cstopb
      ..cCflag = (mode.cCflag & ~_csize) | _cs8
      ..cCflag &= ~(_parenb | _cstopb)
      // raw, as stty defines it: no input processing at all, no output
      // processing, no signals and no canonical mode, VMIN 1 and VTIME 0.
      ..cIflag = 0
      ..cOflag &= ~_opost
      ..cLflag &= ~(_isig | _icanon | _xcase)
      ..cCc[_vmin] = 1
      ..cCc[_vtime] = 0
      // -echo -crtscts clocal
      ..cLflag &= ~_echo
      ..cCflag &= ~_crtscts
      ..cCflag |= _clocal
      // min 0 time 1: a read returns what has arrived within 100 ms.
      ..cCc[_vmin] = 0
      ..cCc[_vtime] = 1;

    if (_tcsetattr(fd, _tcsadrain, wanted) != 0) _fail('tcsetattr', device);
    if (_tcgetattr(fd, applied) != 0) _fail('tcgetattr', device);
    if (!_same(wanted, applied)) {
      throw FileSystemException(
        'the serial driver did not take every termios setting',
        device,
      );
    }
  } finally {
    calloc
      ..free(wanted)
      ..free(applied);
    _close(fd);
  }
}

/// Whether two settings match, compared as stty compares them.
bool _same(Pointer<_Termios> a, Pointer<_Termios> b) {
  final x = a.ref;
  final y = b.ref;
  if (x.cIflag != y.cIflag ||
      x.cOflag != y.cOflag ||
      x.cCflag != y.cCflag ||
      x.cLflag != y.cLflag ||
      x.cLine != y.cLine ||
      _cfgetispeed(a) != _cfgetispeed(b) ||
      _cfgetospeed(a) != _cfgetospeed(b)) {
    return false;
  }
  for (var i = 0; i < _nccs; i++) {
    if (x.cCc[i] != y.cCc[i]) return false;
  }
  return true;
}

Never _fail(String call, String device) {
  final error = _errnoLocation().value;
  throw FileSystemException(
    '$call failed',
    device,
    OSError(_strerror(error).toDartString(), error),
  );
}

/// glibc's `struct termios` on Linux (aarch64 and x86_64): four flag words,
/// the line discipline, 32 control characters and the two speeds, 60 bytes.
final class _Termios extends Struct {
  @Uint32()
  external int cIflag;

  @Uint32()
  external int cOflag;

  @Uint32()
  external int cCflag;

  @Uint32()
  external int cLflag;

  @Uint8()
  external int cLine;

  @Array(_nccs)
  external Array<Uint8> cCc;

  @Uint32()
  external int cIspeed;

  @Uint32()
  external int cOspeed;
}

// Linux values (asm-generic termbits, which aarch64 and x86_64 share).
const _nccs = 32;
const _vtime = 5;
const _vmin = 6;
const _opost = 0x1;
const _isig = 0x1;
const _icanon = 0x2;
const _xcase = 0x4;
const _echo = 0x8;
const _csize = 0x30;
const _cs8 = 0x30;
const _cstopb = 0x40;
const _parenb = 0x100;
const _clocal = 0x800;
const _crtscts = 0x80000000;
const _tcsadrain = 1;
const _oRdonly = 0;
const _oNoctty = 0x100;
const _oNonblock = 0x800;
const _oCloexec = 0x80000;
const _fGetfl = 3;
const _fSetfl = 4;

/// The `Bnnn` speed constants for the rates stty accepts by number.
const _speeds = <int, int>{
  1200: 0x9,
  2400: 0xb,
  4800: 0xc,
  9600: 0xd,
  19200: 0xe,
  38400: 0xf,
  57600: 0x1001,
  115200: 0x1002,
  230400: 0x1003,
  460800: 0x1004,
  500000: 0x1005,
  576000: 0x1006,
  921600: 0x1007,
  1000000: 0x1008,
};

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(Pointer<Utf8>, int) _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');

final int Function(int) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

/// `fcntl` is variadic; its third argument is declared as such.
final int Function(int, int, int) _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

final int Function(int, Pointer<_Termios>) _tcgetattr = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<_Termios>),
      int Function(int, Pointer<_Termios>)
    >('tcgetattr');

final int Function(int, int, Pointer<_Termios>) _tcsetattr = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Pointer<_Termios>),
      int Function(int, int, Pointer<_Termios>)
    >('tcsetattr');

final int Function(Pointer<_Termios>, int) _cfsetispeed = _libc
    .lookupFunction<
      Int32 Function(Pointer<_Termios>, Uint32),
      int Function(Pointer<_Termios>, int)
    >('cfsetispeed');

final int Function(Pointer<_Termios>, int) _cfsetospeed = _libc
    .lookupFunction<
      Int32 Function(Pointer<_Termios>, Uint32),
      int Function(Pointer<_Termios>, int)
    >('cfsetospeed');

final int Function(Pointer<_Termios>) _cfgetispeed = _libc
    .lookupFunction<
      Uint32 Function(Pointer<_Termios>),
      int Function(Pointer<_Termios>)
    >('cfgetispeed');

final int Function(Pointer<_Termios>) _cfgetospeed = _libc
    .lookupFunction<
      Uint32 Function(Pointer<_Termios>),
      int Function(Pointer<_Termios>)
    >('cfgetospeed');

final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );

final Pointer<Utf8> Function(int) _strerror = _libc
    .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
      'strerror',
    );
