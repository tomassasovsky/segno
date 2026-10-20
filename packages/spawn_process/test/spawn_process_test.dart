@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:spawn_process/spawn_process.dart';
import 'package:test/test.dart';

/// These tests start real programs. They must not share the process with a
/// `dart:io` child: the VM's `wait()` thread would reap theirs (see the
/// library documentation). `dart_test.yaml` runs them from source for that
/// reason, since the default kernel compiler keeps a frontend server child
/// running in the test runner.
void main() {
  group('runProcess', () {
    test('returns stdout, stderr and the exit code', () async {
      final result = await runProcess('/bin/sh', [
        '-c',
        'echo out; echo err >&2; exit 3',
      ]);
      expect(result.exitCode, 3);
      expect(result.stdout, 'out\n');
      expect(result.stderr, 'err\n');
      expect(result.pid, greaterThan(0));
    });

    test('passes each argument through unchanged', () async {
      final result = await runProcess('/bin/sh', [
        '-c',
        r'printf "%s|" "$@"',
        'sh',
        'two words',
        '',
        r'$HOME',
      ]);
      expect(result.stdout, r'two words||$HOME|');
    });

    test('looks a bare name up on PATH', () async {
      final result = await runProcess('sh', ['-c', 'echo found']);
      expect(result.stdout, 'found\n');
    });

    test('gives the child the app environment', () async {
      final result = await runProcess('/bin/sh', ['-c', r'printf %s "$HOME"']);
      expect(result.stdout, Platform.environment['HOME']);
    });

    test('writes stdin and closes it', () async {
      final result = await runProcess('/bin/cat', const [], stdin: 'key\n');
      expect(result.stdout, 'key\n');
    });

    test('closes stdin at once when there is none', () async {
      final result = await runProcess('/bin/cat', const []);
      expect(result.exitCode, 0);
      expect(result.stdout, isEmpty);
    });

    test('moves more than a pipe holds in both directions', () async {
      final input = List.filled(1 << 20, 'x').join();
      final result = await runProcess('/bin/cat', const [], stdin: input);
      expect(result.stdout, input);
    });

    test('finishes when the child exits without reading stdin', () async {
      final result = await runProcess('/bin/sh', [
        '-c',
        'exit 0',
      ], stdin: List.filled(1 << 20, 'x').join());
      expect(result.exitCode, 0);
    });

    test('reports a signal as its negative number', () async {
      final result = await runProcess('/bin/sh', ['-c', r'kill -TERM $$']);
      expect(result.exitCode, -ProcessSignal.sigterm.signalNumber);
    });

    test('decodes malformed UTF-8 without throwing', () async {
      final result = await runProcess('/usr/bin/printf', [r'\377ok']);
      expect(result.stdout, endsWith('ok'));
    });

    test('throws a ProcessException for a missing program', () async {
      await expectLater(
        runProcess('/nonexistent/helper', const ['a']),
        throwsA(
          isA<ProcessException>()
              .having((e) => e.executable, 'executable', '/nonexistent/helper')
              .having((e) => e.arguments, 'arguments', ['a'])
              .having((e) => e.errorCode, 'errorCode', 2),
        ),
      );
    });

    test('kills a child that outlives the timeout', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        runProcess('/bin/sleep', const [
          '10',
        ], timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('kills the whole process group on a timeout', () async {
      final dir = Directory.systemTemp.createTempSync('spawn-timeout');
      addTearDown(() => dir.deleteSync(recursive: true));
      final marker = File('${dir.path}/survived');
      await expectLater(
        runProcess('/bin/sh', [
          '-c',
          '(sleep 0.5; : > "${marker.path}") & wait',
        ], timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(marker.existsSync(), isFalse);
    });

    test('leaves the child running when told not to kill it', () async {
      final dir = Directory.systemTemp.createTempSync('spawn-no-kill');
      addTearDown(() => dir.deleteSync(recursive: true));
      final marker = File('${dir.path}/finished');
      await expectLater(
        runProcess(
          '/bin/sh',
          ['-c', 'sleep 0.3; : > "${marker.path}"'],
          timeout: const Duration(milliseconds: 50),
          killOnTimeout: false,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(marker.existsSync(), isFalse);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(marker.existsSync(), isTrue);
    });

    test('returns the result when the child beats the timeout', () async {
      final result = await runProcess('/bin/sh', [
        '-c',
        'echo fast',
      ], timeout: const Duration(seconds: 10));
      expect(result.stdout, 'fast\n');
    });

    test('reports a failure before the timeout as itself', () async {
      await expectLater(
        runProcess(
          '/nonexistent/helper',
          const [],
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<ProcessException>()),
      );
    });

    test('runs many children at once', () async {
      final results = await Future.wait([
        for (var i = 0; i < 24; i++)
          runProcess('/bin/sh', ['-c', 'echo $i; exit ${i % 4}']),
      ]);
      for (var i = 0; i < 24; i++) {
        expect(results[i].stdout, '$i\n');
        expect(results[i].exitCode, i % 4);
      }
    });
  });

  group('startProcess', () {
    test('streams stdout while the child runs', () async {
      final process = await startProcess('/bin/sh', [
        '-c',
        r'echo one; read line; echo "$line"',
      ], stdin: utf8.encode('two\n'));
      final lines = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      expect(lines, ['one', 'two']);
      expect(await process.exitCode, 0);
    });

    test('kill sends SIGTERM by default', () async {
      final process = await startProcess('/bin/sleep', const ['10']);
      expect(process.kill(), isTrue);
      expect(await process.exitCode, -ProcessSignal.sigterm.signalNumber);
    });

    test('kill sends the given signal', () async {
      final process = await startProcess('/bin/sleep', const ['10']);
      expect(process.kill(ProcessSignal.sigkill), isTrue);
      expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
    });

    test('kill is false once the child has been reaped', () async {
      final process = await startProcess('/bin/sh', const ['-c', 'exit 0']);
      await process.exitCode;
      expect(process.kill(), isFalse);
    });

    test('drains output nobody listens to', () async {
      final process = await startProcess('/bin/sh', [
        '-c',
        'head -c 1048576 /dev/zero; exit 4',
      ]);
      expect(await process.exitCode, 4);
    });

    test('reports the exit while a grandchild holds the pipes', () async {
      final process = await startProcess('/bin/sh', [
        '-c',
        'sleep 2 & exit 5',
      ]);
      var stdoutDone = false;
      unawaited(process.stdout.drain<void>().then((_) => stdoutDone = true));
      expect(
        await process.exitCode.timeout(const Duration(seconds: 1)),
        5,
      );
      expect(stdoutDone, isFalse);
    });

    test('kill reaches what the child started, so the pipes close', () async {
      // The background sleep holds stdout, as a helper's ddcutil holds its
      // stderr. Killing only the shell would leave the pipe open.
      final process = await startProcess('/bin/sh', [
        '-c',
        'sleep 30 & echo up; sleep 30',
      ]);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final done = Completer<void>();
      final watch = Stopwatch();
      lines.listen((line) {
        if (line == 'up') {
          watch.start();
          expect(process.kill(ProcessSignal.sigkill), isTrue);
        }
      }, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 5));
      // At its end at once, well inside the drain bound after the exit.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 700)));
      expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
    });

    test('stops reading a second after the exit when a grandchild holds '
        'the pipes', () async {
      final process = await startProcess('/bin/sh', [
        '-c',
        'sleep 30 & exit 5',
      ]);
      try {
        expect(await process.exitCode, 5);
        final watch = Stopwatch()..start();
        await process.stdout.drain<void>().timeout(const Duration(seconds: 5));
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        // The worker is done with it, so kill() no longer reaches the group.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(process.kill(), isFalse);
      } finally {
        _kill(-process.pid, ProcessSignal.sigkill.signalNumber);
      }
    });

    test('reports ECHILD when another waiter took the exit status', () async {
      // What the Dart VM's exit-code thread does while a dart:io child runs:
      // wait for a child and reap it. Here it is done on purpose, before this
      // isolate can handle the worker's report.
      final process = await startProcess('/bin/sh', const ['-c', 'exit 0']);
      final status = calloc<Int32>();
      try {
        expect(_waitpid(process.pid, status, 0), process.pid);
      } finally {
        calloc.free(status);
      }
      await expectLater(
        process.exitCode,
        throwsA(
          isA<ProcessException>()
              .having((e) => e.errorCode, 'errorCode', 10)
              .having((e) => e.message, 'message', contains('dart:io')),
        ),
      );
    });

    test('closes every descriptor but stdio in the child', () async {
      // A descriptor opened without O_CLOEXEC, as a DRM or ALSA one might be.
      final path = '/dev/null'.toNativeUtf8();
      final fd = _open(path, 0);
      malloc.free(path);
      expect(fd, greaterThan(2));
      try {
        final result = await runProcess('/bin/sh', [
          '-c',
          'if [ -e /dev/fd/$fd ]; then echo open; else echo closed; fi',
        ]);
        expect(result.stdout, 'closed\n');
      } finally {
        _close(fd);
      }
    });
  });
}

final int Function(Pointer<Utf8>, int) _open = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');

final int Function(int) _close = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

final int Function(int, int) _kill = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );

final int Function(int, Pointer<Int32>, int) _waitpid = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Int32),
      int Function(int, Pointer<Int32>, int)
    >('waitpid');
