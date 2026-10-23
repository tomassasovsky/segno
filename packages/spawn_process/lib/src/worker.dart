import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
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
/// in this order: [started] or [failed]; then [stdout], [stderr], [eof] and
/// [exited], with [exited] once and [eof] last for each pipe.
abstract final class WorkerMessage {
  /// `[started, pid]`.
  static const started = 0;

  /// `[failed, errorCode, message]`: the program could not be started.
  static const failed = 1;

  /// `[stdout, Uint8List]`.
  static const stdout = 2;

  /// `[stderr, Uint8List]`.
  static const stderr = 3;

  /// `[eof, stdout or stderr]`: that pipe reached its end, or the worker
  /// stopped reading it.
  static const eof = 4;

  /// `[exited]`: the child has exited and is not reaped yet. The parent
  /// reaps it with `waitpid`, so the pid stays reserved until the parent
  /// knows the child is gone and a `kill` can never reach a recycled pid.
  static const exited = 5;
}

const _chunkBytes = 65536;

/// How long `poll` waits before the worker checks again whether the child
/// has exited. The worker wakes this often while a child runs.
const _tickMillis = 100;

/// How long the worker keeps reading after the child has exited. Output the
/// child wrote is already in the pipe and is read at once; what this bounds
/// is a program the child left running that still holds the pipes (a
/// helper's background job), which would otherwise keep the worker alive for
/// as long as it runs.
const drainMillis = 1000;

// The six pipe ends in the worker's descriptor table.
const _stdinRead = 0;
const _stdinWrite = 1;
const _stdoutRead = 2;
const _stdoutWrite = 3;
const _stderrRead = 4;
const _stderrWrite = 5;

/// The worker isolate's entry point: starts the program with `posix_spawnp`
/// in a process group of its own, writes its stdin, reads its stdout and
/// stderr, and reports its exit. Every call here may block; that is why it
/// runs on its own isolate.
///
/// The entry point is synchronous, so it runs on one thread from start to
/// end. That thread blocks SIGPIPE while it runs, so a write to a stdin the
/// child closed fails with EPIPE whether or not the process ignores SIGPIPE;
/// a SIGPIPE left pending is consumed before the mask is restored.
void runWorker(SpawnRequest request) {
  final arena = Arena();
  final fds = arena<Int32>(6);
  for (var i = 0; i < 6; i++) {
    fds[i] = -1;
  }
  final pipeSignal = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  final savedMask = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  libc.sigemptyset(pipeSignal);
  libc.sigaddset(pipeSignal, libc.sigpipe);
  libc.pthreadSigmask(libc.sigBlock, pipeSignal, savedMask);
  var pid = 0;
  var reported = false;
  try {
    pid = _start(request, fds, arena);
    if (pid > 0) {
      _pump(request, pid, fds, arena);
      reported = true;
    }
  } finally {
    if (pid > 0 && !reported) {
      // Something here threw after the child started: stop it and its
      // group, and still hand it to the parent to reap.
      libc.kill(-pid, libc.sigkill);
      _waitForExit(pid, arena);
      request.port.send(const [WorkerMessage.exited]);
    }
    for (var i = 0; i < 6; i++) {
      if (fds[i] >= 0) libc.close(fds[i]);
      fds[i] = -1;
    }
    _consumePendingSigpipe(pipeSignal, arena);
    libc.pthreadSigmask(libc.sigSetmask, savedMask, nullptr);
    arena.releaseAll();
  }
}

/// Opens the pipes and starts the child. Returns its pid, or 0 after sending
/// [WorkerMessage.failed].
int _start(SpawnRequest request, Pointer<Int32> fds, Arena arena) {
  final port = request.port;
  void fail(int error, String message) =>
      port.send([WorkerMessage.failed, error, message]);

  if (Platform.isLinux) {
    // Checked before anything is opened, so an old glibc fails cleanly.
    if (!libc.hasAddClosefrom) {
      fail(
        libc.enosys,
        'libc has no posix_spawn_file_actions_addclosefrom_np '
        '(glibc 2.34 or later is needed)',
      );
      return 0;
    }
  }
  for (final read in const [_stdinRead, _stdoutRead, _stderrRead]) {
    final error = _openPipe(fds + read);
    if (error != 0) {
      fail(error, libc.describeError(error));
      return 0;
    }
  }
  // The parent's ends never block: the loop below polls them.
  for (final end in const [_stdinWrite, _stdoutRead, _stderrRead]) {
    final flags = libc.fcntl(fds[end], libc.fGetfl, 0);
    if (flags < 0 ||
        libc.fcntl(fds[end], libc.fSetfl, flags | libc.oNonblock) < 0) {
      final error = libc.errno;
      fail(error, libc.describeError(error));
      return 0;
    }
  }

  final pid = arena<Int32>();
  final error = _spawn(request, fds, pid, arena);
  // The child's ends now belong to the child alone.
  for (final end in const [_stdinRead, _stdoutWrite, _stderrWrite]) {
    libc.close(fds[end]);
    fds[end] = -1;
  }
  if (error != 0) {
    fail(error, libc.describeError(error));
    return 0;
  }
  port.send([WorkerMessage.started, pid.value]);
  return pid.value;
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

/// Starts the child with its stdin, stdout and stderr on the pipes, every
/// other descriptor closed, so helpers never inherit the app's DRM, ALSA or
/// input descriptors, and in a process group of its own, so a kill reaches
/// whatever the child started too. Returns 0 or the error number.
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
    error = libc.fileActionsAddDup2(actions, fds[_stdinRead], 0);
    if (error == 0) {
      error = libc.fileActionsAddDup2(actions, fds[_stdoutWrite], 1);
    }
    if (error == 0) {
      error = libc.fileActionsAddDup2(actions, fds[_stderrWrite], 2);
    }
    // On macOS POSIX_SPAWN_CLOEXEC_DEFAULT below does the same.
    if (error == 0 && Platform.isLinux) {
      error = libc.fileActionsAddClosefrom(actions, 3);
    }
    if (error != 0) return error;

    // The child starts with no blocked signal, whatever this thread blocks
    // (SIGPIPE, see runWorker). Signal dispositions are left as they are, as
    // dart:io leaves them: glibc resets every handled signal to its default
    // in the child, and an ignored one stays ignored across exec.
    libc.sigemptyset(signals);
    error = libc.spawnattrSetsigmask(attributes, signals);
    if (error == 0) error = libc.spawnattrSetpgroup(attributes, 0);
    if (error == 0) {
      error = libc.spawnattrSetflags(
        attributes,
        libc.posixSpawnSetsigmask |
            libc.posixSpawnSetpgroup |
            (Platform.isMacOS ? libc.posixSpawnCloexecDefault : 0),
      );
    }
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

/// Writes stdin and forwards stdout and stderr until the child has exited
/// and both pipes are done: at their end, or [drainMillis] after the exit.
/// Closes each pipe end it finishes with and marks it -1 in [fds].
void _pump(SpawnRequest request, int pid, Pointer<Int32> fds, Arena arena) {
  final port = request.port;
  final input = request.stdin;
  var written = 0;
  Pointer<Uint8> inBytes = nullptr;
  if (input == null || input.isEmpty) {
    _close(fds, _stdinWrite);
  } else {
    inBytes = arena<Uint8>(input.length);
    inBytes.asTypedList(input.length).setAll(0, input);
  }

  final polls = arena<libc.PollFd>(3);
  final buffer = arena<Uint8>(_chunkBytes);
  final info = arena<Uint8>(libc.opaqueBytes);
  final clock = Stopwatch()..start();
  int? exitedAt;
  var pollFailures = 0;

  void finishPipe(int end) {
    _close(fds, end);
    port.send([
      WorkerMessage.eof,
      if (end == _stdoutRead) WorkerMessage.stdout else WorkerMessage.stderr,
    ]);
  }

  for (;;) {
    final pipesOpen = fds[_stdoutRead] >= 0 || fds[_stderrRead] >= 0;
    if (exitedAt != null && !pipesOpen) return;

    var count = 0;
    for (final (end, events) in const [
      (_stdoutRead, libc.pollin),
      (_stderrRead, libc.pollin),
      (_stdinWrite, libc.pollout),
    ]) {
      if (fds[end] < 0) continue;
      polls[count]
        ..fd = fds[end]
        ..events = events
        ..revents = 0;
      count++;
    }
    final wait = exitedAt == null
        ? _tickMillis
        : max(
            0,
            min(
              _tickMillis,
              drainMillis - (clock.elapsedMilliseconds - exitedAt),
            ),
          );
    // With no descriptor left, poll only waits out the tick.
    final ready = libc.poll(polls, count, wait);
    if (ready < 0) {
      // EINTR or ENOMEM: the next round tries again. errno is not read here,
      // since poll is not a leaf call.
      if (++pollFailures > 1000) throw StateError('poll keeps failing');
    } else {
      pollFailures = 0;
    }

    for (var i = 0; i < count && ready > 0; i++) {
      final revents = polls[i].revents;
      if (revents == 0) continue;
      final fd = polls[i].fd;
      if (fd == fds[_stdinWrite]) {
        final n = libc.write(fd, inBytes + written, input!.length - written);
        final error = n < 0 ? libc.errno : 0;
        if (n > 0) written += n;
        final retry =
            n < 0 &&
            (error == libc.eintr || error == libc.eagain) &&
            revents & libc.pollDone == 0;
        // EPIPE: the child closed stdin unread.
        if (written == input.length || (n < 0 && !retry)) {
          _close(fds, _stdinWrite);
        }
        continue;
      }
      final end = fd == fds[_stdoutRead] ? _stdoutRead : _stderrRead;
      final n = libc.read(fd, buffer, _chunkBytes);
      final error = n < 0 ? libc.errno : 0;
      if (n > 0) {
        port.send([
          if (end == _stdoutRead)
            WorkerMessage.stdout
          else
            WorkerMessage.stderr,
          Uint8List.fromList(buffer.asTypedList(n)),
        ]);
        continue;
      }
      final retry =
          n < 0 &&
          (error == libc.eintr || error == libc.eagain) &&
          revents & libc.pollDone == 0;
      if (!retry) finishPipe(end);
    }

    if (exitedAt == null && hasExited(pid, info)) {
      exitedAt = clock.elapsedMilliseconds;
      _close(fds, _stdinWrite);
      port.send(const [WorkerMessage.exited]);
    }
    if (exitedAt != null &&
        clock.elapsedMilliseconds - exitedAt >= drainMillis) {
      for (final end in const [_stdoutRead, _stderrRead]) {
        if (fds[end] >= 0) finishPipe(end);
      }
    }
  }
}

void _close(Pointer<Int32> fds, int end) {
  if (fds[end] < 0) return;
  libc.close(fds[end]);
  fds[end] = -1;
}

/// Waits, without reaping, until the child has exited.
void _waitForExit(int pid, Arena arena) {
  final info = arena<Uint8>(libc.opaqueBytes);
  final none = arena<libc.PollFd>();
  while (!hasExited(pid, info)) {
    libc.poll(none, 0, 10);
  }
}

/// Whether the child has exited, without reaping it. A child someone else
/// has already reaped (`ECHILD`) counts as exited: the parent's `waitpid`
/// then reports it. [info] is an [libc.opaqueBytes] block for `siginfo_t`.
bool hasExited(int pid, Pointer<Uint8> info) {
  info.asTypedList(libc.opaqueBytes).fillRange(0, libc.opaqueBytes, 0);
  final result = libc.waitid(
    libc.pPid,
    pid,
    info.cast(),
    libc.wexited | libc.wnowait | libc.wnohang,
  );
  if (result != 0) {
    final error = libc.errno;
    return error != libc.eintr;
  }
  // si_signo, at offset 0 on Linux and macOS, stays 0 when no child changed
  // state.
  return info.cast<Int32>().value != 0;
}

/// Takes a SIGPIPE a write raised on this thread, so restoring the mask
/// does not deliver it.
void _consumePendingSigpipe(Pointer<Void> pipeSignal, Arena arena) {
  final pending = arena<Uint8>(libc.opaqueBytes).cast<Void>();
  if (libc.sigpending(pending) != 0) return;
  if (libc.sigismember(pending, libc.sigpipe) != 1) return;
  libc.sigwait(pipeSignal, arena<Int32>());
}
