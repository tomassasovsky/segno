import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/update/appliance/system_appliance_env.dart';

/// Tests for the one thing in [SystemApplianceEnv] that is not plumbing: the
/// kill.
///
/// This class is excluded from coverage as an I/O boundary, and every fake in
/// the suite implements `abortPedalFlash` as `async { count++; }` — so nothing
/// anywhere exercised SIGTERM, the grace period, the SIGKILL escalation, the
/// handle release, or the cancel-vs-exit race. A `process.kill()` that signals
/// only the helper shell and leaves avrdude orphaned on the bootloader port
/// looks identical to a working one from behind those fakes, and shipped.
///
/// These drive a REAL `Process.start` of a shell stub, and assert on the
/// GRANDCHILD, because "the shell exited" is exactly the false positive that
/// hid the bug: a shell dies on SIGTERM in milliseconds while the command it
/// was waiting on carries on.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('segno-env-test'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A stub that outlived its kill would hold nothing here; best effort.
    }
  });

  /// Writes an executable stub helper and returns its path.
  String stub(String body) {
    final file = File('${dir.path}/helper.sh')..writeAsStringSync(body);
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  /// A stub shaped like the real helper: it backgrounds its long-running child
  /// (standing in for `timeout avrdude ...`), records the pid, and traps TERM
  /// to take that child down before exiting. The real helper's structure —
  /// what makes the app's SIGTERM reach avrdude at all.
  String trappingStub({required String pidFile, int exitCode = 143}) => stub('''
#!/bin/sh
child=""
stop() {
  if [ -n "\$child" ]; then
    kill -TERM "\$child" 2>/dev/null || true
    i=0
    while [ "\$i" -lt 3 ] && kill -0 "\$child" 2>/dev/null; do
      sleep 1
      i=\$((i + 1))
    done
    kill -KILL "\$child" 2>/dev/null || true
  fi
  exit $exitCode
}
trap stop TERM INT
sleep 120 &
child=\$!
echo "\$child" > "$pidFile"
echo "PROGRESS 50"
wait "\$child"
''');

  /// A stub that cannot be reasoned with: SIGTERM is ignored outright, so only
  /// the SIGKILL escalation ends it. Stands in for a helper blocked where the
  /// signal cannot be taken.
  ///
  /// It idles in one-second steps rather than one long `sleep` so that when
  /// the shell is killed the orphaned sleep releases the stdout pipe promptly
  /// — otherwise the stream this env exposes never ends and the test, not the
  /// production code, is what hangs.
  String deafStub({required String pidFile}) => stub('''
#!/bin/sh
trap '' TERM
echo \$\$ > "$pidFile"
echo "PROGRESS 50"
while true; do sleep 1; done
''');

  bool alive(int pid) =>
      Process.runSync('/bin/sh', ['-c', 'kill -0 $pid']).exitCode == 0;

  Future<void> awaitGone(int pid) async {
    for (var i = 0; i < 100 && alive(pid); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<int> awaitPidFile(String path) async {
    final file = File(path);
    for (var i = 0; i < 200; i++) {
      final text = file.existsSync() ? file.readAsStringSync().trim() : '';
      final pid = int.tryParse(text);
      if (pid != null) return pid;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the stub helper never reported its child pid');
  }

  /// Starts `flashPedal()` and waits for its first progress event, so the
  /// helper is provably running before anything is killed.
  ///
  /// `finished` completes when the stream ends, error included: a killed
  /// helper exits 143, which `_runHelper` republishes as a [ProcessException].
  /// Tests await it rather than cancelling, so that error lands in a listener
  /// instead of the test zone after the subscription is gone.
  Future<({StreamSubscription<double> sub, Future<void> finished})> startFlash(
    SystemApplianceEnv env,
  ) async {
    final first = Completer<void>();
    final done = Completer<void>();
    void end() {
      if (!first.isCompleted) first.complete();
      if (!done.isCompleted) done.complete();
    }

    // cancelOnError plus onDone end this subscription; the handle is returned
    // so the one test that needs an explicit early cancel can do it, and
    // everything else awaits `finished`.
    // ignore: cancel_subscriptions
    final sub = env.flashPedal().listen(
      (_) {
        if (!first.isCompleted) first.complete();
      },
      onError: (Object _) => end(),
      onDone: end,
      cancelOnError: true,
    );
    await first.future;
    return (sub: sub, finished: done.future);
  }

  group('abortPedalFlash', () {
    test('kills the helper AND the child it was waiting on', () async {
      // THE regression assertion. `process.kill()` signals the helper shell
      // only; the shell's exitCode then resolves in milliseconds while
      // avrdude carries on as an orphan still owning the Caterina bootloader
      // port — so the retry the kill exists to make safe races an unkilled
      // flasher for that port, which is what the whole seam is for.
      final pidFile = '${dir.path}/child.pid';
      final env = SystemApplianceEnv(
        helperPath: trappingStub(pidFile: pidFile),
      );
      final flash = await startFlash(env);
      final childPid = await awaitPidFile(pidFile);
      expect(alive(childPid), isTrue, reason: 'the stub child never started');

      await env.abortPedalFlash();

      expect(alive(childPid), isFalse, reason: 'the child was orphaned');
      await flash.finished;
    });

    test('escalates to SIGKILL when the helper ignores SIGTERM', () async {
      final pidFile = '${dir.path}/helper.pid';
      final env = SystemApplianceEnv(
        helperPath: deafStub(pidFile: pidFile),
        termGrace: const Duration(milliseconds: 300),
        killGrace: const Duration(seconds: 5),
      );
      final flash = await startFlash(env);
      final helperPid = await awaitPidFile(pidFile);
      expect(alive(helperPid), isTrue);

      await env.abortPedalFlash();

      // Returned because the process is actually gone, not because the grace
      // expired and it gave up.
      await awaitGone(helperPid);
      expect(alive(helperPid), isFalse);
      await flash.finished;
    });

    test('returns rather than hanging when even SIGKILL cannot land', () async {
      // A helper blocked in an uninterruptible USB write does not die on
      // SIGKILL until the kernel unblocks it, and `run()` awaits this call, so
      // an unbounded wait here holds a `dismissible: false` gate forever — the
      // console hostage the stall timer was added to prevent, one layer down.
      // Simulated with graces short enough that the stub outlives both.
      final env = SystemApplianceEnv(
        helperPath: deafStub(pidFile: '${dir.path}/helper.pid'),
        termGrace: const Duration(milliseconds: 50),
        killGrace: Duration.zero,
      );
      final flash = await startFlash(env);
      final helperPid = await awaitPidFile('${dir.path}/helper.pid');

      await expectLater(
        env.abortPedalFlash().timeout(const Duration(seconds: 5)),
        completes,
      );

      // The SIGKILL still lands eventually — the point is that the caller was
      // not made to wait for it.
      await awaitGone(helperPid);
      await flash.finished;
    });

    test('still kills a helper whose stream was already cancelled', () async {
      // The order the stall path actually uses: the subscription is cancelled
      // a microtask before the kill is asked for. If cancelling dropped the
      // handle, the wedged helper would escape the kill entirely and go on
      // holding the bootloader port.
      //
      // Exits 0 on the signal so nothing is left to deliver once the
      // subscription is gone: what is under test is the handle, not the code.
      final pidFile = '${dir.path}/child.pid';
      final env = SystemApplianceEnv(
        helperPath: trappingStub(pidFile: pidFile, exitCode: 0),
      );
      final flash = await startFlash(env);
      final childPid = await awaitPidFile(pidFile);
      // Not awaited, exactly as the stall path does it: awaiting a cancel on
      // this stream blocks until the helper exits, which is the thing the
      // kill has not happened yet to cause.
      unawaited(flash.sub.cancel());

      await env.abortPedalFlash();

      expect(alive(childPid), isFalse);
    });

    test(
      'concurrent callers share one kill and all wait for the death',
      () async {
        final pidFile = '${dir.path}/child.pid';
        final env = SystemApplianceEnv(
          helperPath: trappingStub(pidFile: pidFile),
        );
        final flash = await startFlash(env);
        final childPid = await awaitPidFile(pidFile);

        // The documented contract is "returns only once it is dead". A second
        // caller used to find the handle already nulled and return at once,
        // reporting a live flasher as dead.
        await Future.wait([env.abortPedalFlash(), env.abortPedalFlash()]);

        expect(alive(childPid), isFalse);
        await flash.finished;
      },
    );

    test('releases the handle when the helper exits on its own', () async {
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "PROGRESS 100"\n'),
      );
      await env.flashPedal().drain<void>();

      // Nothing is running, so this is a no-op — not a wait on a dead handle.
      await expectLater(
        env.abortPedalFlash().timeout(const Duration(seconds: 2)),
        completes,
      );
    });

    test('is a no-op when no flash was ever started', () async {
      final env = SystemApplianceEnv(helperPath: stub('#!/bin/sh\nexit 0\n'));
      await expectLater(env.abortPedalFlash(), completes);
    });

    test('does not throw when the helper is already reaped', () async {
      // Documented "Never throws", and it is awaited inside `run()`'s catch
      // block — a throw there escapes an unawaited `run()` as an uncaught
      // root-zone async error. That is not a logged annoyance: there is no
      // `runZonedGuarded` around `runApp`, and `bootstrap.dart` sets
      // `PlatformDispatcher.instance.onError` to return `false` on purpose so
      // the process tears down and segno.service restarts the kiosk. The gate
      // stranded on `flashing` would be the lesser half of it.
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "PROGRESS 50"\nsleep 0.2\n'),
      );
      final flash = await startFlash(env);
      await flash.finished;

      await expectLater(env.abortPedalFlash(), completes);
    });
  });

  group('powerOff', () {
    test('runs the helper poweroff verb', () async {
      final argsFile = '${dir.path}/args.txt';
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "\$1" > "$argsFile"\n'),
      );
      await env.powerOff();
      expect(File(argsFile).readAsStringSync().trim(), 'poweroff');
    });
  });

  group('flashPedal', () {
    test('republishes PROGRESS lines as [0, 1]', () async {
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "PROGRESS 0"\necho "PROGRESS 50"\n'),
      );
      expect(await env.flashPedal().toList(), [0.0, 0.5, 1.0]);
    });

    test('throws with the helper stderr on a non-zero exit', () async {
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "boom" >&2\nexit 1\n'),
      );
      await expectLater(
        env.flashPedal().toList(),
        throwsA(
          isA<ProcessException>().having((e) => e.message, 'message', 'boom'),
        ),
      );
    });
  });
}
