import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The libc calls and constants the package uses, for Linux (glibc) and
/// macOS. Each value that differs between the two is chosen here, once.
///
/// The opaque libc types (`posix_spawn_file_actions_t`, `posix_spawnattr_t`,
/// `sigset_t`) are allocated as zeroed blocks larger than either platform's
/// type: glibc's are 80, 336 and 128 bytes, and macOS's are 8, 8 and 4.
const opaqueBytes = 512;

final DynamicLibrary _libc = DynamicLibrary.process();

final bool _linux = Platform.isLinux;

/// `EINTR`.
const eintr = 4;

/// `ECHILD`.
const echild = 10;

/// `EAGAIN` (`EWOULDBLOCK`): 11 on Linux, 35 on macOS.
final int eagain = _linux ? 11 : 35;

/// `EPIPE`.
const epipe = 32;

/// `F_GETFL`.
const fGetfl = 3;

/// `F_SETFL`.
const fSetfl = 4;

/// `F_SETFD`.
const fSetfd = 2;

/// `FD_CLOEXEC`.
const fdCloexec = 1;

/// `O_NONBLOCK`: 04000 on Linux, 0x4 on macOS.
final int oNonblock = _linux ? 0x800 : 0x4;

/// `O_CLOEXEC` on Linux, for `pipe2`.
const oCloexecLinux = 0x80000;

/// `POLLIN`.
const pollin = 0x1;

/// `POLLOUT`.
const pollout = 0x4;

/// `POLLERR`.
const pollerr = 0x8;

/// `POLLHUP`.
const pollhup = 0x10;

/// `POLLNVAL`.
const pollnval = 0x20;

/// `P_PID`, for `waitid`.
const pPid = 1;

/// `WNOHANG`.
const wnohang = 1;

/// `WEXITED`.
const wexited = 4;

/// `WNOWAIT`: 0x01000000 on Linux, 0x20 on macOS.
final int wnowait = _linux ? 0x01000000 : 0x20;

/// `POSIX_SPAWN_SETSIGMASK`.
const posixSpawnSetsigmask = 0x08;

/// `POSIX_SPAWN_CLOEXEC_DEFAULT`, macOS only: the child starts with only the
/// descriptors the file actions name.
const posixSpawnCloexecDefault = 0x4000;

/// `struct pollfd`, the same on Linux and macOS.
final class PollFd extends Struct {
  /// The descriptor.
  @Int32()
  external int fd;

  /// The requested events.
  @Int16()
  external int events;

  /// The returned events.
  @Int16()
  external int revents;
}

/// `posix_spawnp`.
final int Function(
  Pointer<Int32>,
  Pointer<Utf8>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Utf8>>,
  Pointer<Pointer<Utf8>>,
)
posixSpawnp = _libc
    .lookupFunction<
      Int32 Function(
        Pointer<Int32>,
        Pointer<Utf8>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      ),
      int Function(
        Pointer<Int32>,
        Pointer<Utf8>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      )
    >('posix_spawnp');

/// `posix_spawn_file_actions_init`.
final int Function(Pointer<Void>) fileActionsInit = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawn_file_actions_init',
    );

/// `posix_spawn_file_actions_destroy`.
final int Function(Pointer<Void>) fileActionsDestroy = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawn_file_actions_destroy',
    );

/// `posix_spawn_file_actions_adddup2`.
final int Function(Pointer<Void>, int, int) fileActionsAddDup2 = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Int32),
      int Function(Pointer<Void>, int, int)
    >('posix_spawn_file_actions_adddup2');

/// `posix_spawn_file_actions_addclosefrom_np`, glibc 2.34 and later. macOS
/// has no such call and uses [posixSpawnCloexecDefault] instead.
final int Function(Pointer<Void>, int) fileActionsAddClosefrom = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('posix_spawn_file_actions_addclosefrom_np');

/// `posix_spawnattr_init`.
final int Function(Pointer<Void>) spawnattrInit = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawnattr_init',
    );

/// `posix_spawnattr_destroy`.
final int Function(Pointer<Void>) spawnattrDestroy = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawnattr_destroy',
    );

/// `posix_spawnattr_setflags`.
final int Function(Pointer<Void>, int) spawnattrSetflags = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int16),
      int Function(Pointer<Void>, int)
    >('posix_spawnattr_setflags');

/// `posix_spawnattr_setsigmask`.
final int Function(Pointer<Void>, Pointer<Void>) spawnattrSetsigmask = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('posix_spawnattr_setsigmask');

/// `sigemptyset`.
final int Function(Pointer<Void>) sigemptyset = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'sigemptyset',
    );

/// `pipe`.
final int Function(Pointer<Int32>) pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('pipe');

/// `pipe2`, Linux only.
final int Function(Pointer<Int32>, int) pipe2 = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>, Int32),
      int Function(Pointer<Int32>, int)
    >('pipe2');

/// `fcntl` with one int argument. It is variadic, so the argument is declared
/// as such: on macOS arm64 variadic arguments go on the stack.
final int Function(int, int, int) fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

/// `close`.
final int Function(int) close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

/// `read`.
final int Function(int, Pointer<Uint8>, int) read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('read');

/// `write`.
final int Function(int, Pointer<Uint8>, int) write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('write');

/// `poll`. `nfds_t` is `unsigned long` on Linux and `unsigned int` on macOS.
final int Function(Pointer<PollFd>, int, int) poll = _linux
    ? _libc.lookupFunction<
        Int32 Function(Pointer<PollFd>, UnsignedLong, Int32),
        int Function(Pointer<PollFd>, int, int)
      >('poll')
    : _libc.lookupFunction<
        Int32 Function(Pointer<PollFd>, UnsignedInt, Int32),
        int Function(Pointer<PollFd>, int, int)
      >('poll');

/// `waitpid`.
final int Function(int, Pointer<Int32>, int) waitpid = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Int32),
      int Function(int, Pointer<Int32>, int)
    >('waitpid');

/// `waitid`. The `siginfo_t` is passed as an opaque zeroed block; only its
/// first field, `si_signo`, is read, which is at offset 0 on both platforms.
final int Function(int, int, Pointer<Void>, int) waitid = _libc
    .lookupFunction<
      Int32 Function(Int32, Uint32, Pointer<Void>, Int32),
      int Function(int, int, Pointer<Void>, int)
    >('waitid');

/// `kill`.
final int Function(int, int) kill = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );

/// `strerror`.
final Pointer<Utf8> Function(int) strerror = _libc
    .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
      'strerror',
    );

final Pointer<Int32> Function() _errnoLocation = _linux
    ? _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__errno_location',
          )
    : _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__error',
          );

/// The calling thread's `errno`. Read it right after the failing call: the
/// Dart VM may run other native code on this thread between two FFI calls.
int get errno => _errnoLocation().value;

/// The process environment, `environ`, which the child inherits as
/// `Process.start` gives it. macOS exposes it through `_NSGetEnviron`.
Pointer<Pointer<Utf8>> get environ => _linux
    ? _libc.lookup<Pointer<Pointer<Utf8>>>('environ').value
    : _nsGetEnviron().value;

final Pointer<Pointer<Pointer<Utf8>>> Function() _nsGetEnviron = _libc
    .lookupFunction<
      Pointer<Pointer<Pointer<Utf8>>> Function(),
      Pointer<Pointer<Pointer<Utf8>>> Function()
    >('_NSGetEnviron');

/// The message for an error number, as `strerror` gives it.
String describeError(int code) => strerror(code).toDartString();
