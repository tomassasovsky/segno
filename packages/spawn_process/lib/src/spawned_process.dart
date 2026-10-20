import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:spawn_process/src/libc.dart' as libc;
import 'package:spawn_process/src/worker.dart';

/// A program started by [startProcess]: the subset of `dart:io`'s [Process]
/// that the app uses.
final class SpawnedProcess {
  SpawnedProcess._(this.pid, this._executable, this._arguments) {
    // An exit code nobody awaits must not surface as an uncaught error.
    _exitCode.future.ignore();
  }

  /// The child's process id.
  final int pid;

  final String _executable;
  final List<String> _arguments;
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();
  var _finished = false;

  /// The child's stdout. It is read whether or not anything listens, so a
  /// child never blocks on a full pipe; what nobody reads is buffered.
  Stream<List<int>> get stdout => _stdout.stream;

  /// The child's stderr, read like [stdout].
  Stream<List<int>> get stderr => _stderr.stream;

  /// The exit code: the program's own, or the negative signal number when a
  /// signal ended it, as `dart:io` reports it.
  ///
  /// It completes once the child has exited, which can be before [stdout]
  /// and [stderr] close when the child left something running that holds
  /// them.
  Future<int> get exitCode => _exitCode.future;

  /// Sends [signal] to the child's process group: the child and whatever it
  /// started, such as a helper's `ddcutil`, which would otherwise hold its
  /// pipes open. Returns `false` once the worker has finished with the
  /// child, or when the signal could not be sent.
  ///
  /// The child runs in a group of its own, whose id is its pid. The child is
  /// reaped on this isolate after the worker saw it exit, so until then the
  /// pid is not reused; after that the group id stays reserved while a
  /// member of the group lives, which is what keeps the pipes open.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_finished) return false;
    return libc.kill(-pid, signal.signalNumber) == 0;
  }

  void _handle(List<Object?> message) {
    switch (message[0]) {
      case WorkerMessage.stdout:
        _stdout.add(message[1]! as Uint8List);
      case WorkerMessage.stderr:
        _stderr.add(message[1]! as Uint8List);
      case WorkerMessage.eof:
        unawaited(
          (message[1] == WorkerMessage.stdout ? _stdout : _stderr).close(),
        );
      case WorkerMessage.exited:
        _reap();
    }
  }

  /// Collects the exit status of the zombie the worker reported, waiting on
  /// this child's pid only.
  void _reap() {
    final status = calloc<Int32>();
    try {
      int result;
      int error;
      do {
        result = libc.waitpid(pid, status, libc.wnohang);
        error = result < 0 ? libc.errno : 0;
      } while (result < 0 && error == libc.eintr);
      if (result == pid) {
        _exitCode.complete(_decode(status.value));
        return;
      }
      final String reason;
      if (error != libc.echild) {
        reason = 'waitpid failed: ${libc.describeError(error)}';
      } else if (libc.childrenAutoReaped) {
        reason =
            'its exit status is lost: SIGCHLD is ignored in this process '
            '(SIG_IGN or SA_NOCLDWAIT), so the kernel reaps children itself';
      } else {
        reason =
            'its exit status was collected by another waiter: something in '
            'this process started a child with dart:io Process while this '
            'one ran';
      }
      _exitCode.completeError(
        ProcessException(_executable, _arguments, reason, error),
      );
    } finally {
      calloc.free(status);
    }
  }

  /// The worker isolate exited. After a normal run everything is complete
  /// by now; whatever is not fails with [error].
  void _stopped(Object error) {
    _finished = true;
    for (final pipe in [_stdout, _stderr]) {
      if (pipe.isClosed) continue;
      pipe.addError(error);
      unawaited(pipe.close());
    }
    if (!_exitCode.isCompleted) _exitCode.completeError(error);
  }

  static int _decode(int status) {
    final signal = status & 0x7f;
    return signal == 0 ? (status >> 8) & 0xff : -signal;
  }
}

/// Starts [executable] with [arguments], looked up on `PATH` when it has no
/// slash, with `posix_spawnp` on a worker isolate, never with `fork`.
///
/// [stdin], when given, is written to the child's stdin, which is then
/// closed; without it the child's stdin is closed at once. The child keeps
/// only stdin, stdout and stderr: every other descriptor of the app is
/// closed in it. Throws a [ProcessException] when the program cannot be
/// started.
Future<SpawnedProcess> startProcess(
  String executable,
  List<String> arguments, {
  List<int>? stdin,
}) async {
  final events = ReceivePort('spawn_process');
  final started = Completer<SpawnedProcess>();
  SpawnedProcess? process;
  events.listen((message) {
    if (message == null) {
      // The worker isolate exited (onExit).
      events.close();
      final error = StateError(
        'the spawn worker for $executable stopped before it finished',
      );
      if (!started.isCompleted) started.completeError(error);
      process?._stopped(error);
      return;
    }
    final list = message as List<Object?>;
    if (list.first is String) {
      // An uncaught error in the worker (onError): [error, stack].
      final error = RemoteError('${list[0]}', '${list[1]}');
      if (!started.isCompleted) started.completeError(error);
      process?._stopped(error);
      return;
    }
    switch (list.first) {
      case WorkerMessage.started:
        process = SpawnedProcess._(list[1]! as int, executable, arguments);
        started.complete(process);
      case WorkerMessage.failed:
        started.completeError(
          ProcessException(
            executable,
            arguments,
            list[2]! as String,
            list[1]! as int,
          ),
        );
      default:
        process!._handle(list);
    }
  });
  try {
    await Isolate.spawn(
      runWorker,
      SpawnRequest(
        events.sendPort,
        executable,
        List.of(arguments),
        stdin == null ? null : Uint8List.fromList(stdin),
      ),
      onExit: events.sendPort,
      onError: events.sendPort,
      debugName: 'spawn_process',
    );
  } on Object {
    events.close();
    rethrow;
  }
  return started.future;
}

/// Runs [executable] with [arguments] to completion, like `Process.run`: the
/// result carries the exit code and the stdout and stderr decoded as UTF-8.
///
/// [stdin] is written to the child as UTF-8. With a [timeout], the call
/// throws a [TimeoutException] when it expires, without waiting for the
/// child to go. A child still running then is killed with SIGKILL, with its
/// process group, unless [killOnTimeout] is `false`: then it runs on to its
/// own end, for a helper that must not stop halfway.
Future<ProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  String? stdin,
  Duration? timeout,
  bool killOnTimeout = true,
}) async {
  final process = await startProcess(
    executable,
    arguments,
    stdin: stdin == null ? null : utf8.encode(stdin),
  );
  // Awaited after the exit code; an error before then must not go uncaught.
  final stdout = _collect(process.stdout)..ignore();
  final stderr = _collect(process.stderr)..ignore();
  Future<ProcessResult> finish() async {
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, await stdout, await stderr);
  }

  if (timeout == null) return finish();
  final result = Completer<ProcessResult>();
  final timer = Timer(timeout, () {
    if (result.isCompleted) return;
    if (killOnTimeout) process.kill(ProcessSignal.sigkill);
    result.completeError(
      TimeoutException('$executable did not finish', timeout),
    );
  });
  finish()
      .then(
        (value) {
          timer.cancel();
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          timer.cancel();
          if (!result.isCompleted) result.completeError(error, stack);
        },
      )
      .ignore();
  return result.future;
}

Future<String> _collect(Stream<List<int>> stream) async {
  final bytes = await stream.fold(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}
