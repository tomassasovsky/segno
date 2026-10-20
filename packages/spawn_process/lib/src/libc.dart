import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The libc calls and constants the package uses, for Linux (glibc) and
/// macOS. Each value that differs between the two is chosen here, once.
///
/// The opaque libc types (`posix_spawn_file_actions_t`, `posix_spawnattr_t`,
/// `sigset_t`, `struct sigaction`) are allocated as zeroed blocks larger than
/// either platform's type: glibc's are 80, 336, 128 and 152 bytes, and
/// macOS's are 8, 8, 4 and 16.
///
/// Every call that cannot block is a leaf call (`isLeaf: true`), and so is
/// the `errno` lookup: between two leaf calls the VM runs no native code of
/// its own on the thread, so `errno` read right after a failing leaf call is
/// that call's. `posix_spawnp` (which waits for the child's exec) and `poll`
/// can block, so they are not leaf calls, and their callers do not read
/// `errno` after them.
const opaqueBytes = 512;

final DynamicLibrary _libc = DynamicLibrary.process();

final bool _linux = Platform.isLinux;

/// `EINTR`.
const eintr = 4;

/// `ECHILD`.
const echild = 10;

/// `ENOSYS`: 38 on Linux, 78 on macOS.
final int enosys = _linux ? 38 : 78;

/// `EAGAIN` (`EWOULDBLOCK`): 11 on Linux, 35 on macOS.
final int eagain = _linux ? 11 : 35;

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

/// `POLLERR`, `POLLHUP` and `POLLNVAL`: the descriptor is done.
const int pollDone = 0x8 | 0x10 | 0x20;

/// `P_PID`, for `waitid`.
const pPid = 1;

/// `WNOHANG`.
const wnohang = 1;

/// `WEXITED`.
const wexited = 4;

/// `WNOWAIT`: 0x01000000 on Linux, 0x20 on macOS.
final int wnowait = _linux ? 0x01000000 : 0x20;

/// `POSIX_SPAWN_SETPGROUP`.
const posixSpawnSetpgroup = 0x02;

/// `POSIX_SPAWN_SETSIGMASK`.
const posixSpawnSetsigmask = 0x08;

/// `POSIX_SPAWN_CLOEXEC_DEFAULT`, macOS only: the child starts with only the
/// descriptors the file actions name.
const posixSpawnCloexecDefault = 0x4000;

/// `SIGPIPE`.
const sigpipe = 13;

/// `SIGCHLD`: 17 on Linux, 20 on macOS.
final int sigchld = _linux ? 17 : 20;

/// `SIGKILL`.
const sigkill = 9;

/// `SIG_BLOCK`: 0 on Linux, 1 on macOS.
final int sigBlock = _linux ? 0 : 1;

/// `SIG_SETMASK`: 2 on Linux, 3 on macOS.
final int sigSetmask = _linux ? 2 : 3;

/// `SIG_IGN`, as the handler pointer's value.
const sigIgn = 1;

/// The offset of `sa_flags` in `struct sigaction`: after the handler and
/// glibc's 128-byte `sigset_t` on Linux, after the handler and macOS's
/// 4-byte one on macOS.
final int saFlagsOffset = _linux ? 136 : 12;

/// `SA_NOCLDWAIT`: 2 on Linux, 0x20 on macOS.
final int saNocldwait = _linux ? 2 : 0x20;

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

/// `posix_spawnp`. Not a leaf call: it returns once the child has exec'd.
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

int Function(Pointer<Void>) _voidCall(String name) => _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      name,
      isLeaf: true,
    );

/// `posix_spawn_file_actions_init`.
final int Function(Pointer<Void>) fileActionsInit = _voidCall(
  'posix_spawn_file_actions_init',
);

/// `posix_spawn_file_actions_destroy`.
final int Function(Pointer<Void>) fileActionsDestroy = _voidCall(
  'posix_spawn_file_actions_destroy',
);

/// `posix_spawn_file_actions_adddup2`.
final int Function(Pointer<Void>, int, int) fileActionsAddDup2 = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Int32),
      int Function(Pointer<Void>, int, int)
    >('posix_spawn_file_actions_adddup2', isLeaf: true);

/// Whether libc has `posix_spawn_file_actions_addclosefrom_np` (glibc 2.34
/// and later).
bool get hasAddClosefrom =>
    _libc.providesSymbol('posix_spawn_file_actions_addclosefrom_np');

/// `posix_spawn_file_actions_addclosefrom_np`, glibc 2.34 and later; see
/// [hasAddClosefrom]. macOS has no such call and uses
/// [posixSpawnCloexecDefault] instead.
final int Function(Pointer<Void>, int) fileActionsAddClosefrom = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('posix_spawn_file_actions_addclosefrom_np', isLeaf: true);

/// `posix_spawnattr_init`.
final int Function(Pointer<Void>) spawnattrInit = _voidCall(
  'posix_spawnattr_init',
);

/// `posix_spawnattr_destroy`.
final int Function(Pointer<Void>) spawnattrDestroy = _voidCall(
  'posix_spawnattr_destroy',
);

/// `posix_spawnattr_setflags`.
final int Function(Pointer<Void>, int) spawnattrSetflags = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int16),
      int Function(Pointer<Void>, int)
    >('posix_spawnattr_setflags', isLeaf: true);

/// `posix_spawnattr_setpgroup`.
final int Function(Pointer<Void>, int) spawnattrSetpgroup = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('posix_spawnattr_setpgroup', isLeaf: true);

/// `posix_spawnattr_setsigmask`.
final int Function(Pointer<Void>, Pointer<Void>) spawnattrSetsigmask = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('posix_spawnattr_setsigmask', isLeaf: true);

/// `sigemptyset`.
final int Function(Pointer<Void>) sigemptyset = _voidCall('sigemptyset');

/// `sigaddset`.
final int Function(Pointer<Void>, int) sigaddset = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('sigaddset', isLeaf: true);

/// `sigismember`.
final int Function(Pointer<Void>, int) sigismember = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('sigismember', isLeaf: true);

/// `sigpending`.
final int Function(Pointer<Void>) sigpending = _voidCall('sigpending');

/// `sigwait`. Only called for a signal [sigpending] reports, so it returns
/// at once.
final int Function(Pointer<Void>, Pointer<Int32>) sigwait = _libc
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Int32>),
      int Function(Pointer<Void>, Pointer<Int32>)
    >('sigwait', isLeaf: true);

/// `pthread_sigmask`.
final int Function(int, Pointer<Void>, Pointer<Void>) pthreadSigmask = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Void>, Pointer<Void>),
      int Function(int, Pointer<Void>, Pointer<Void>)
    >('pthread_sigmask', isLeaf: true);

/// `sigaction`, used only to read a disposition.
final int Function(int, Pointer<Void>, Pointer<Void>) sigaction = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Void>, Pointer<Void>),
      int Function(int, Pointer<Void>, Pointer<Void>)
    >('sigaction', isLeaf: true);

/// `pipe`.
final int Function(Pointer<Int32>) pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('pipe', isLeaf: true);

/// `pipe2`, Linux only.
final int Function(Pointer<Int32>, int) pipe2 = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>, Int32),
      int Function(Pointer<Int32>, int)
    >('pipe2', isLeaf: true);

/// `fcntl` with one int argument, for the flag commands only. It is
/// variadic, so the argument is declared as such: on macOS arm64 variadic
/// arguments go on the stack.
final int Function(int, int, int) fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl', isLeaf: true);

/// `close`. Only ever called on pipe ends, where it cannot block.
final int Function(int) close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
      isLeaf: true,
    );

/// `read`, on non-blocking pipe ends only.
final int Function(int, Pointer<Uint8>, int) read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('read', isLeaf: true);

/// `write`, on a non-blocking pipe end only.
final int Function(int, Pointer<Uint8>, int) write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('write', isLeaf: true);

/// `poll`. Not a leaf call: it waits. `nfds_t` is `unsigned long` on Linux
/// and `unsigned int` on macOS.
final int Function(Pointer<PollFd>, int, int) poll = _linux
    ? _libc.lookupFunction<
        Int32 Function(Pointer<PollFd>, UnsignedLong, Int32),
        int Function(Pointer<PollFd>, int, int)
      >('poll')
    : _libc.lookupFunction<
        Int32 Function(Pointer<PollFd>, UnsignedInt, Int32),
        int Function(Pointer<PollFd>, int, int)
      >('poll');

/// `waitpid`, with `WNOHANG` only.
final int Function(int, Pointer<Int32>, int) waitpid = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Int32),
      int Function(int, Pointer<Int32>, int)
    >('waitpid', isLeaf: true);

/// `waitid`, with `WNOHANG` only. The `siginfo_t` is passed as an opaque
/// zeroed block; only its first field, `si_signo`, is read, which is at
/// offset 0 on both platforms.
final int Function(int, int, Pointer<Void>, int) waitid = _libc
    .lookupFunction<
      Int32 Function(Int32, Uint32, Pointer<Void>, Int32),
      int Function(int, int, Pointer<Void>, int)
    >('waitid', isLeaf: true);

/// `kill`.
final int Function(int, int) kill = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
      isLeaf: true,
    );

final Pointer<Utf8> Function(int) _strerror = _libc
    .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
      'strerror',
      isLeaf: true,
    );

final Pointer<Int32> Function() _errnoLocation = _linux
    ? _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__errno_location',
            isLeaf: true,
          )
    : _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__error',
            isLeaf: true,
          );

/// The calling thread's `errno`. Read it right after the failing leaf call.
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
    >('_NSGetEnviron', isLeaf: true);

/// The message for an error number, as `strerror` gives it.
String describeError(int code) => _strerror(code).toDartString();

/// Whether the kernel reaps this process's children itself: `SIGCHLD` set
/// to `SIG_IGN`, or `SA_NOCLDWAIT`. Then no exit status can be collected.
bool get childrenAutoReaped {
  final action = calloc<Uint8>(opaqueBytes);
  try {
    if (sigaction(sigchld, nullptr, action.cast()) != 0) return false;
    final handler = action.cast<IntPtr>().value;
    final flags = (action + saFlagsOffset).cast<Int32>().value;
    return handler == sigIgn || flags & saNocldwait != 0;
  } finally {
    calloc.free(action);
  }
}
