import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:spawn_process/src/libc.dart' as libc;

/// What the parent isolate asks a worker to start.
final class SpawnRequest {
  /// Creates a [SpawnRequest].
  const SpawnRequest(this.port, this.executable, this.arguments, this.stdin);

  /// Where the worker sends its [WorkerMessage]s.
  final SendPort port;

  /// The program, looked up on `PATH` when it has no slash.
  final String executable;

  /// The arguments after `argv[0]`.
  final List<String> arguments;

  /// Bytes written to the child's stdin before it is closed, or `null` to
  /// close stdin at once.
  final Uint8List? stdin;
}

/// The tags of the lists a worker sends. Every message is `[tag, ...]`, sent
/// in this order: [started] or [failed]; then [stdout], [stderr] and [eof]
/// in any order; [exited] once the child has exited.
abstract final class WorkerMessage {
  /// `[started, pid]`.
  static const started = 0;

  /// `[failed, errorCode, message]`: the program could not be started.
  static const failed = 1;

  /// `[stdout, Uint8List]`.
  static const stdout = 2;

  /// `[stderr, Uint8List]`.
  static const stderr = 3;

  /// `[eof, stdout or stderr]`: that pipe reached its end.
  static const eof = 4;

  /// `[exited]`: the child has exited and is not reaped yet. The parent
  /// reaps it with `waitpid`, so the pid stays reserved until the parent
  /// knows the child is gone and a `kill` can never reach a recycled pid.
  static const exited = 5;
}

const _chunkBytes = 65536;

/// How long `poll` waits before the worker checks whether the child has
/// exited while something it started still holds the pipes open.
const _exitCheckMillis = 100;

/// The worker isolate's entry point: starts the program with `posix_spawnp`,
/// writes its stdin, reads its stdout and stderr, and waits for it to exit.
/// Every call here may block; that is why it runs on its own isolate.
void runWorker(SpawnRequest request) {
  final arena = Arena();
  try {
    _run(request, arena);
  } finally {
    arena.releaseAll();
  }
}

void _run(SpawnRequest request, Arena arena) {
  final port = request.port;
  // stdin read and write ends, stdout read and write ends, stderr read and
  // write ends.
  final fds = arena<Int32>(6);
  for (var i = 0; i < 6; i++) {
    fds[i] = -1;
  }
  for (var i = 0; i < 3; i++) {
    final error = _openPipe(fds + 2 * i);
    if (error != 0) {
      _closeAll(fds);
      port.send([WorkerMessage.failed, error, libc.describeError(error)]);
      return;
    }
  }

  final pid = arena<Int32>();
  final error = _spawn(request, fds, pid, arena);
  // The child's ends now belong to the child alone.
  for (final end in const [0, 3, 5]) {
    libc.close(fds[end]);
    fds[end] = -1;
  }
  if (error != 0) {
    _closeAll(fds);
    port.send([WorkerMessage.failed, error, libc.describeError(error)]);
    return;
  }
  port.send([WorkerMessage.started, pid.value]);
  _pump(request, pid.value, fds[1], fds[2], fds[4], arena);
}

/// Opens a pipe whose two ends are close-on-exec, so a program another
/// thread starts at the same moment cannot inherit them. Returns 0 or the
/// error number.
int _openPipe(Pointer<Int32> ends) {
  if (Platform.isLinux) {
    return libc.pipe2(ends, libc.oCloexecLinux) == 0 ? 0 : libc.errno;
  }
  if (libc.pipe(ends) != 0) return libc.errno;
  for (var i = 0; i < 2; i++) {
    if (libc.fcntl(ends[i], libc.fSetfd, libc.fdCloexec) != 0) {
      return libc.errno;
    }
  }
  return 0;
}

void _closeAll(Pointer<Int32> fds) {
  for (var i = 0; i < 6; i++) {
    if (fds[i] >= 0) libc.close(fds[i]);
    fds[i] = -1;
  }
}

/// Starts the child with its stdin, stdout and stderr on the pipes and every
/// other descriptor closed, so helpers never inherit the app's DRM, ALSA or
/// input descriptors. Returns 0 or the error number.
int _spawn(
  SpawnRequest request,
  Pointer<Int32> fds,
  Pointer<Int32> pid,
  Arena arena,
) {
  final actions = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  final attributes = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  final signals = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  var error = libc.fileActionsInit(actions);
  if (error != 0) return error;
  error = libc.spawnattrInit(attributes);
  if (error != 0) {
    libc.fileActionsDestroy(actions);
    return error;
  }
  try {
    error = libc.fileActionsAddDup2(actions, fds[0], 0);
    if (error == 0) error = libc.fileActionsAddDup2(actions, fds[3], 1);
    if (error == 0) error = libc.fileActionsAddDup2(actions, fds[5], 2);
    // On macOS POSIX_SPAWN_CLOEXEC_DEFAULT below does the same.
    if (error == 0 && Platform.isLinux) {
      error = libc.fileActionsAddClosefrom(actions, 3);
    }
    if (error != 0) return error;

    // The child starts with no blocked signal, whatever this thread blocks.
    // Signal dispositions are left as they are, as dart:io leaves them: glibc
    // resets every handled signal to its default in the child, and an
    // ignored one (SIGPIPE, which systemd and the Dart VM ignore) stays
    // ignored across exec.
    libc.sigemptyset(signals);
    error = libc.spawnattrSetsigmask(attributes, signals);
    if (error != 0) return error;
    error = libc.spawnattrSetflags(
      attributes,
      libc.posixSpawnSetsigmask |
          (Platform.isMacOS ? libc.posixSpawnCloexecDefault : 0),
    );
    if (error != 0) return error;

    final argv = arena<Pointer<Utf8>>(request.arguments.length + 2);
    argv[0] = request.executable.toNativeUtf8(allocator: arena);
    for (var i = 0; i < request.arguments.length; i++) {
      argv[i + 1] = request.arguments[i].toNativeUtf8(allocator: arena);
    }
    argv[request.arguments.length + 1] = nullptr;

    return libc.posixSpawnp(
      pid,
      argv[0],
      actions,
      attributes,
      argv,
      libc.environ,
    );
  } finally {
    libc.spawnattrDestroy(attributes);
    libc.fileActionsDestroy(actions);
  }
}

/// Writes stdin, forwards stdout and stderr until both pipes reach their end,
/// and reports the exit once the child is a zombie.
void _pump(
  SpawnRequest request,
  int pid,
  int stdinFd,
  int stdoutFd,
  int stderrFd,
  Arena arena,
) {
  final port = request.port;
  final input = request.stdin;
  var inFd = stdinFd;
  var outFd = stdoutFd;
  var errFd = stderrFd;
  var written = 0;
  Pointer<Uint8> inBytes = nullptr;
  if (input == null || input.isEmpty) {
    libc.close(inFd);
    inFd = -1;
  } else {
    inBytes = arena<Uint8>(input.length);
    inBytes.asTypedList(input.length).setAll(0, input);
    // A full pipe must not stop the loop from reading the child's output.
    final flags = libc.fcntl(inFd, libc.fGetfl, 0);
    libc.fcntl(inFd, libc.fSetfl, flags | libc.oNonblock);
  }

  final polls = arena<libc.PollFd>(3);
  final buffer = arena<Uint8>(_chunkBytes);
  final info = arena<Uint8>(libc.opaqueBytes);
  var exited = false;

  while (outFd >= 0 || errFd >= 0) {
    var count = 0;
    for (final (fd, events) in [
      (outFd, libc.pollin),
      (errFd, libc.pollin),
      (inFd, libc.pollout),
    ]) {
      if (fd < 0) continue;
      polls[count]
        ..fd = fd
        ..events = events
        ..revents = 0;
      count++;
    }
    final ready = libc.poll(polls, count, exited ? -1 : _exitCheckMillis);
    if (ready < 0) {
      if (libc.errno == libc.eintr) continue;
      break;
    }
    if (ready == 0) {
      if (!exited && _hasExited(pid, info)) {
        exited = true;
        port.send(const [WorkerMessage.exited]);
      }
      continue;
    }
    for (var i = 0; i < count; i++) {
      final fd = polls[i].fd;
      if (polls[i].revents == 0) continue;
      if (fd == inFd) {
        final n = libc.write(inFd, inBytes + written, input!.length - written);
        if (n > 0) written += n;
        final error = n < 0 ? libc.errno : 0;
        // EPIPE: the child closed stdin unread. SIGPIPE is ignored in the
        // app (the Dart VM and systemd both ignore it), so write reports it.
        if (written == input.length ||
            (n < 0 && error != libc.eintr && error != libc.eagain)) {
          libc.close(inFd);
          inFd = -1;
        }
        continue;
      }
      final n = libc.read(fd, buffer, _chunkBytes);
      if (n > 0) {
        port.send([
          if (fd == outFd) WorkerMessage.stdout else WorkerMessage.stderr,
          Uint8List.fromList(buffer.asTypedList(n)),
        ]);
        continue;
      }
      if (n < 0) {
        final error = libc.errno;
        if (error == libc.eintr || error == libc.eagain) continue;
      }
      libc.close(fd);
      port.send([
        WorkerMessage.eof,
        if (fd == outFd) WorkerMessage.stdout else WorkerMessage.stderr,
      ]);
      if (fd == outFd) {
        outFd = -1;
      } else {
        errFd = -1;
      }
    }
  }
  for (final fd in [inFd, outFd, errFd]) {
    if (fd >= 0) libc.close(fd);
  }

  if (!exited) {
    // Blocks until the child exits, without reaping it.
    while (libc.waitid(
              libc.pPid,
              pid,
              info.cast(),
              libc.wexited | libc.wnowait,
            ) !=
            0 &&
        libc.errno == libc.eintr) {}
  }
  if (!exited) port.send(const [WorkerMessage.exited]);
}

/// Whether the child has exited, without reaping it. A child someone else
/// has already reaped (`ECHILD`) counts as exited: the parent's `waitpid`
/// then reports it.
bool _hasExited(int pid, Pointer<Uint8> info) {
  info.asTypedList(libc.opaqueBytes).fillRange(0, libc.opaqueBytes, 0);
  final result = libc.waitid(
    libc.pPid,
    pid,
    info.cast(),
    libc.wexited | libc.wnowait | libc.wnohang,
  );
  if (result != 0) return libc.errno == libc.echild;
  // si_signo, at offset 0 on Linux and macOS, stays 0 when no child changed
  // state.
  return info.cast<Int32>().value != 0;
}
