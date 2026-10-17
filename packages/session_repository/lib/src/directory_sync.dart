import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _Open = int Function(Pointer<Utf8> path, int flags);
typedef _FdNative = Int32 Function(Int32 fd);
typedef _Fd = int Function(int fd);

/// The C library's `open`, `fsync` and `close`, looked up once; null where
/// they are not reachable this way (Windows).
final ({_Open open, _Fd fsync, _Fd close})? _libc = () {
  if (!Platform.isLinux && !Platform.isMacOS) return null;
  try {
    final lib = DynamicLibrary.process();
    return (
      open: lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), _Open>(
        'open',
      ),
      fsync: lib.lookupFunction<_FdNative, _Fd>('fsync'),
      close: lib.lookupFunction<_FdNative, _Fd>('close'),
    );
  } on Object {
    return null;
  }
}();

/// Flushes the directory [path]'s own entries to disk (`fsync` on the
/// directory), so a rename inside it is durable when this returns, not
/// only once the filesystem next commits. Dart has no API for it.
///
/// Best effort: on a platform without the call, or when it fails, the
/// rename is still atomic, only its durability waits for the filesystem.
void syncDirectory(String path) {
  final libc = _libc;
  if (libc == null) return;
  final native = path.toNativeUtf8();
  try {
    // O_RDONLY is 0 on Linux and macOS.
    final fd = libc.open(native, 0);
    if (fd < 0) return;
    libc
      ..fsync(fd)
      ..close(fd);
  } finally {
    malloc.free(native);
  }
}
