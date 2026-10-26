import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Sends a service notification to systemd (`READY=1`, `STATUS=...`): one or
/// more newline-separated `KEY=VALUE` assignments. Returns whether it was
/// sent.
typedef SystemdNotify = bool Function(String state);

/// How this process notifies systemd, or `null` when systemd is not
/// listening: off Linux, or when [environment] has no `NOTIFY_SOCKET` (any
/// service type but `notify`, desktop builds, tests).
SystemdNotify? systemdNotifyFromEnvironment(Map<String, String> environment) {
  if (!Platform.isLinux) return null;
  final socket = environment['NOTIFY_SOCKET'];
  if (socket == null || socket.isEmpty) return null;
  return UnixDatagramNotifier(socket).notify;
}

/// [SystemdNotify] speaking systemd's notify protocol itself: one datagram
/// to the `AF_UNIX` socket named by `NOTIFY_SOCKET`, a filesystem path or, with
/// a leading `@`, a name in the abstract namespace.
///
/// systemd documents the protocol as stable and meant to be reimplemented
/// (`sd_notify(3)`), and this is that, with libc through `dart:ffi`, rather
/// than `libsystemd.so.0`: nothing in the image names that library as a
/// dependency, and without it the app could never say it is ready, and would
/// be killed after `TimeoutStartSec` on every boot (#976). systemd attaches
/// the sender's credentials to the datagram itself, so `NotifyAccess=main`
/// holds for any thread of the app's process.
///
/// Linux only: the constants and `sockaddr_un` layout below are Linux's.
final class UnixDatagramNotifier {
  /// Creates a [UnixDatagramNotifier] for the socket at [socketPath].
  UnixDatagramNotifier(this.socketPath);

  /// `NOTIFY_SOCKET`.
  final String socketPath;

  static const _afUnix = 1;
  static const _sockDgram = 2;
  static const _sockCloexec = 0x80000;
  static const _msgDontwait = 0x40;
  static const _msgNosignal = 0x4000;

  /// `sizeof(struct sockaddr_un)` on Linux: a 2-byte family, then the path.
  static const _sunPathOffset = 2;
  static const _sunPathMax = 108;

  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final int Function(int, int, int) _socket = _libc
      .lookupFunction<
        Int32 Function(Int32, Int32, Int32),
        int Function(int, int, int)
      >(
        'socket',
      );
  static final int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>, int)
  _sendto = _libc
      .lookupFunction<
        IntPtr Function(
          Int32,
          Pointer<Uint8>,
          Size,
          Int32,
          Pointer<Uint8>,
          Uint32,
        ),
        int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>, int)
      >('sendto');
  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  /// Sends [state]; see [SystemdNotify].
  bool notify(String state) {
    final path = utf8.encode(socketPath);
    final abstract = path.first == 0x40; // '@'
    // A filesystem path needs room for its NUL; an abstract name is counted
    // exactly, its leading '@' standing for the leading NUL.
    if (path.length + (abstract ? 0 : 1) > _sunPathMax) return false;
    final message = utf8.encode(state);
    return using((arena) {
      final address = arena<Uint8>(_sunPathOffset + _sunPathMax);
      final view = address.asTypedList(_sunPathOffset + _sunPathMax)
        ..fillRange(0, _sunPathOffset + _sunPathMax, 0)
        // sa_family_t is native-endian; the Pi and every Linux host this
        // runs on are little-endian.
        ..[0] = _afUnix
        ..setRange(_sunPathOffset, _sunPathOffset + path.length, path);
      if (abstract) view[_sunPathOffset] = 0;
      final length = _sunPathOffset + path.length + (abstract ? 0 : 1);
      final buffer = arena<Uint8>(message.length);
      buffer.asTypedList(message.length).setAll(0, message);

      final fd = _socket(_afUnix, _sockDgram | _sockCloexec, 0);
      if (fd < 0) return false;
      try {
        final sent = _sendto(
          fd,
          buffer,
          message.length,
          _msgDontwait | _msgNosignal,
          address,
          length,
        );
        return sent == message.length;
      } finally {
        _close(fd);
      }
    });
  }
}
