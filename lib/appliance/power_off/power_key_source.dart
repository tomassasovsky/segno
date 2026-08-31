import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:segno/logging/app_log.dart';

/// A stream of short-presses of the rear power button.
abstract interface class PowerKeySource {
  /// Fires once per `KEY_POWER` down. Up and repeat are not forwarded.
  Stream<void> get presses;

  /// Releases the grab and the isolate, if any.
  Future<void> close();
}

/// Test double: call [emitPress] to simulate a short press.
final class FakePowerKeySource implements PowerKeySource {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get presses => _controller.stream;

  /// Fires one press.
  void emitPress() => _controller.add(null);

  @override
  Future<void> close() => _controller.close();
}

/// Opens an [EvdevPowerKeySource] on Linux when the update helper exists.
///
/// Returns null on desktop, on a Linux image without the helper, and in
/// tests that pass [isLinux] / [helperExists] false. Missing `pwr_button`
/// is a silent no-op inside the source, not a null here.
PowerKeySource? openAppliancePowerKeySource({
  required bool isLinux,
  required bool helperExists,
}) {
  if (!isLinux || !helperExists) return null;
  return EvdevPowerKeySource();
}

/// Blocking evdev reader for the Pi 5 `pwr_button` node, on a background
/// isolate in the **main** Flutter engine. The waveform window must never
/// construct this.
final class EvdevPowerKeySource implements PowerKeySource {
  /// Creates an [EvdevPowerKeySource] and starts the reader isolate.
  ///
  /// [devicePath] overrides the by-path / name scan — tests that point at a
  /// fake node pass it; production leaves it null.
  EvdevPowerKeySource({this.devicePath}) {
    _port = ReceivePort();
    _subscription = _port.listen(_onIsolateMessage);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _isolate = await Isolate.spawn(
        _isolateMain,
        _IsolateArgs(_port.sendPort, devicePath),
      );
    } on Object catch (error, stack) {
      AppLog.error(
        'power-key isolate failed to start',
        error: error,
        stack: stack,
      );
    }
  }

  /// Override for tests that point at a fake node. Null → by-path / name scan.
  final String? devicePath;

  late final ReceivePort _port;
  late final StreamSubscription<dynamic> _subscription;
  Isolate? _isolate;
  final StreamController<void> _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get presses => _controller.stream;

  void _onIsolateMessage(dynamic message) {
    if (message is SendPort) {
      // Isolate handshake — keep the isolate handle via the spawn future
      // is enough; the send port is how we could ask it to stop later.
      return;
    }
    if (message == _pressToken) {
      if (!_controller.isClosed) _controller.add(null);
      return;
    }
    if (message is String) {
      AppLog.warn(message);
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    _port.close();
    _isolate?.kill(priority: Isolate.immediate);
    await _controller.close();
  }
}

const _pressToken = 'press';

final class _IsolateArgs {
  const _IsolateArgs(this.sendPort, this.devicePath);

  final SendPort sendPort;
  final String? devicePath;
}

const _keyPower = 116;
const _evKey = 1;
const _eventSize = 24;
const _oRdonly = 0;
const _pwrButtonName = 'pwr_button';
const _byPath = '/dev/input/by-path/platform-pwr_button-event';

/// `EVIOCGRAB` = `_IOW('E', 0x90, int)`.
int get _eviocgrab => _ioc(dir: 1, type: 0x45, nr: 0x90, size: 4);

/// `EVIOCGNAME(len)` = `_IOC(_IOC_READ, 'E', 0x06, len)`.
int _eviocgname(int len) => _ioc(dir: 2, type: 0x45, nr: 0x06, size: len);

int _ioc({
  required int dir,
  required int type,
  required int nr,
  required int size,
}) => (dir << 30) | (size << 16) | (type << 8) | nr;

void _isolateMain(_IsolateArgs args) {
  final libc = DynamicLibrary.process();
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  final read = libc
      .lookupFunction<
        Long Function(Int32, Pointer<Void>, Uint64),
        int Function(int, Pointer<Void>, int)
      >('read');
  final closeFd = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final ioctl = libc
      .lookupFunction<
        Int32 Function(Int32, Uint64, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('ioctl');

  final path = args.devicePath ?? _resolveDevice(open, ioctl, closeFd);
  if (path == null) return;

  final pathPtr = path.toNativeUtf8();
  final fd = open(pathPtr, _oRdonly);
  malloc.free(pathPtr);
  if (fd < 0) {
    args.sendPort.send('power-key: open failed for $path');
    return;
  }

  final grab = calloc<Int32>()..value = 1;
  final grabbed = ioctl(fd, _eviocgrab, grab.cast());
  calloc.free(grab);
  if (grabbed < 0) {
    args.sendPort.send(
      'power-key: EVIOCGRAB failed; listening without exclusive grab',
    );
  }

  final buffer = calloc<Uint8>(_eventSize);
  try {
    while (true) {
      final n = read(fd, buffer.cast(), _eventSize);
      if (n < _eventSize) break;
      final bytes = buffer.asTypedList(_eventSize);
      final data = ByteData.sublistView(bytes);
      final type = data.getUint16(16, Endian.host);
      final code = data.getUint16(18, Endian.host);
      final value = data.getInt32(20, Endian.host);
      if (type == _evKey && code == _keyPower && value == 1) {
        args.sendPort.send(_pressToken);
      }
    }
  } finally {
    calloc.free(buffer);
    closeFd(fd);
  }
}

String? _resolveDevice(
  int Function(Pointer<Utf8>, int) open,
  int Function(int, int, Pointer<Void>) ioctl,
  int Function(int) closeFd,
) {
  if (File(_byPath).existsSync()) return _byPath;

  final dir = Directory('/dev/input');
  if (!dir.existsSync()) return null;
  for (final entity in dir.listSync()) {
    final name = entity.uri.pathSegments.last;
    if (!name.startsWith('event')) continue;
    final pathPtr = entity.path.toNativeUtf8();
    final fd = open(pathPtr, _oRdonly);
    malloc.free(pathPtr);
    if (fd < 0) continue;
    final buf = calloc<Uint8>(256);
    try {
      final n = ioctl(fd, _eviocgname(256), buf.cast());
      if (n < 0) continue;
      final deviceName = buf.cast<Utf8>().toDartString();
      if (deviceName == _pwrButtonName) return entity.path;
    } finally {
      calloc.free(buf);
      closeFd(fd);
    }
  }
  return null;
}
