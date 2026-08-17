import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:update_repository/update_repository.dart';

class _FakeBackend implements PlatformUpdateBackend {
  _FakeBackend({
    this.supported = true,
    this.pending,
    this.pendingSequence,
    this.flashErrors = const [],
    this.progressBeforeError = const [],
    this.failureClass,
  });

  final bool supported;

  /// Constant `pedal-pending` answer, used once [pendingSequence] runs out.
  final String? pending;

  /// Consumed one per `pedal-pending` call, ahead of [pending].
  final List<String?>? pendingSequence;

  /// Errors for the first N flash calls; further calls get a fresh
  /// [controller] whose completion means success.
  final List<Object> flashErrors;

  /// Progress an erroring attempt reports before it dies, so a test can put a
  /// failure past the write phase without a stall.
  final List<double> progressBeforeError;

  /// What the failure marker says, or null for "no legible record".
  final PedalFlashFailureClass? failureClass;

  int pendingCalls = 0;
  int flashCalls = 0;
  int failureReads = 0;
  int abortCalls = 0;

  /// Interleaving of `flash` and `abort` calls, to prove no retry starts
  /// while a killed helper could still be alive.
  final calls = <String>[];
  StreamController<double>? controller;

  @override
  bool get isSupported => supported;

  @override
  Future<String?> pendingPedalFirmware() async {
    pendingCalls++;
    final sequence = pendingSequence;
    if (sequence != null && sequence.isNotEmpty) return sequence.removeAt(0);
    return pending;
  }

  @override
  Stream<double> flashPedalFirmware() {
    flashCalls++;
    calls.add('flash');
    if (flashCalls <= flashErrors.length) {
      final error = flashErrors[flashCalls - 1];
      final reported = progressBeforeError;
      return () async* {
        yield* Stream.fromIterable(reported);
        // Rethrown as-is so a test can script a non-Exception failure too.
        Error.throwWithStackTrace(error, StackTrace.current);
      }();
    }
    controller = StreamController<double>();
    return controller!.stream;
  }

  @override
  Future<PedalFlashFailureClass?> lastPedalFlashFailure() async {
    failureReads++;
    return failureClass;
  }

  @override
  Future<void> abortPedalFlash() async {
    abortCalls++;
    calls.add('abort');
  }

  @override
  String get channel => 'experimental';

  @override
  Future<void> setChannel(String channel) async {}

  @override
  Future<Version> currentVersion() async => Version.none;

  @override
  Future<Version> stagedVersion() async => Version.none;

  @override
  Future<UpdateManifest?> fetchManifest() async => null;

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      const Stream.empty();

  @override
  Future<void> applyAndRestart() async {}
}

void main() {
  PedalFirmwareCubit cubitOver(_FakeBackend backend) =>
      PedalFirmwareCubit(updates: UpdateRepository(backend: backend));

  group('PedalFirmwareCubit', () {
    test('goes idle without asking when updates are unsupported', () async {
      // Desktop and dev runs must not pay a process launch, and must never
      // draw the gate.
      final backend = _FakeBackend(supported: false, pending: '0.4.0');
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.idle);
      expect(cubit.state.blocksLooper, isFalse);
      expect(backend.pendingCalls, 0);
    });

    test('goes idle when nothing is pending', () async {
      final backend = _FakeBackend();
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.idle);
      expect(backend.flashCalls, 0);
    });

    test(
      'blocks the looper for the whole flash and releases it after',
      () async {
        final backend = _FakeBackend(pending: '0.4.0');
        final cubit = cubitOver(backend);
        addTearDown(cubit.close);

        final done = cubit.run();
        await pumpEventQueue();

        // The gate must be up before the first byte is written, not after the
        // first progress line: the touch reset happens immediately, and that is
        // the moment the footswitches go dead.
        expect(cubit.state.stage, PedalFirmwareStage.flashing);
        expect(cubit.state.blocksLooper, isTrue);
        expect(cubit.state.version, '0.4.0');
        expect(cubit.state.progress, 0);

        backend.controller!.add(0.5);
        await pumpEventQueue();
        expect(cubit.state.progress, 0.5);
        expect(cubit.state.blocksLooper, isTrue);

        await backend.controller!.close();
        await done;

        expect(cubit.state.stage, PedalFirmwareStage.idle);
        expect(cubit.state.blocksLooper, isFalse);
      },
    );

    test('a not-started failure retries silently, then succeeds', () async {
      // A dropped manifest fetch or a missed bootloader window self-heals on
      // the next try; the user never needs to hear about it.
      final backend = _FakeBackend(
        pending: '0.4.0',
        flashErrors: [Exception('manifest fetch failed')],
        failureClass: PedalFlashFailureClass.notStarted,
      );
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      final failedStages = <PedalFirmwareStage>[];
      final sub = cubit.stream.listen((s) => failedStages.add(s.stage));
      addTearDown(sub.cancel);

      final done = cubit.run();
      await pumpEventQueue();

      // Second attempt underway: still the flashing face, progress back at 0.
      expect(backend.flashCalls, 2);
      expect(cubit.state.stage, PedalFirmwareStage.flashing);
      expect(cubit.state.progress, 0);

      await backend.controller!.close();
      await done;

      expect(cubit.state.stage, PedalFirmwareStage.idle);
      // The retry was silent: failed was never shown.
      expect(failedStages, isNot(contains(PedalFirmwareStage.failed)));
    });

    test('a not-started failure surfaces after every attempt fails', () async {
      final backend = _FakeBackend(
        pending: '0.4.0',
        flashErrors: [
          Exception('fail 1'),
          Exception('fail 2'),
          Exception('fail 3'),
          Exception('fail 4'),
        ],
        failureClass: PedalFlashFailureClass.notStarted,
      );
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      await cubit.run();

      // Bounded: exactly maxAttempts, not one per error on offer.
      expect(backend.flashCalls, PedalFirmwareCubit.maxAttempts);
      expect(cubit.state.stage, PedalFirmwareStage.failed);
      expect(cubit.state.failureClass, PedalFlashFailureClass.notStarted);
      expect(cubit.state.error, contains('fail 3'));
      expect(cubit.state.blocksLooper, isTrue);

      cubit.dismiss();

      expect(cubit.state.blocksLooper, isFalse);
    });

    test(
      'an interrupted failure fails fast when the pedal does not re-present',
      () async {
        // The pedal is parked in its bootloader: pedal-pending sees no sketch
        // port and answers nothing. Re-touching a parked pedal cannot help
        // (recovery is slice 3), so the honest dialog appears immediately.
        final backend = _FakeBackend(
          pendingSequence: ['0.4.0'],
          flashErrors: [Exception('avrdude failed')],
          failureClass: PedalFlashFailureClass.interrupted,
        );
        final cubit = cubitOver(backend);
        addTearDown(cubit.close);

        await cubit.run();

        expect(backend.flashCalls, 1);
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
      },
    );

    test(
      'an interrupted failure retries while the pedal re-presents',
      () async {
        // avrdude died early enough that the sketch survived and came back —
        // the flash is worth another quiet try.
        final backend = _FakeBackend(
          pending: '0.4.0',
          flashErrors: [
            Exception('fail 1'),
            Exception('fail 2'),
            Exception('fail 3'),
          ],
          failureClass: PedalFlashFailureClass.interrupted,
        );
        final cubit = cubitOver(backend);
        addTearDown(cubit.close);

        await cubit.run();

        expect(backend.flashCalls, PedalFirmwareCubit.maxAttempts);
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
      },
    );

    test(
      'a stale not-started marker cannot launder a failure past the write '
      'phase',
      () async {
        // The marker gap is wider than stalls. EVERY path where the helper
        // dies without writing one — an OOM kill, a full /data, a `set -e`
        // abort on a line with no write_pedal_fail call — leaves an EARLIER
        // attempt's marker on disk. Trusting it alone is how a pedal with dead
        // switches gets told "your pedal still works on its previous
        // firmware". This attempt's own progress is the check.
        final backend = _FakeBackend(
          pendingSequence: ['0.4.0'],
          flashErrors: [Exception('helper vanished')],
          progressBeforeError: const [0.5],
          failureClass: PedalFlashFailureClass.notStarted,
        );
        final cubit = cubitOver(backend);
        addTearDown(cubit.close);

        await cubit.run();

        expect(backend.failureReads, greaterThan(0));
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
      },
    );

    test(
      'an interrupted marker still wins over an attempt that got nowhere',
      () async {
        // The other direction of the same rule: the more pessimistic of the
        // two signals decides, so a marker written by the helper itself is
        // never softened by this attempt failing early.
        final backend = _FakeBackend(
          pendingSequence: ['0.4.0'],
          flashErrors: [Exception('no manifest')],
          failureClass: PedalFlashFailureClass.interrupted,
        );
        final cubit = cubitOver(backend);
        addTearDown(cubit.close);

        await cubit.run();

        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
      },
    );

    test('an Error from the helper still reaches the failed dialog', () async {
      // `on Exception` would let this escape with the stall timer already
      // disarmed: stage stuck on flashing, blocksLooper true, no Continue —
      // an unrecoverable console lock, and run() is called unawaited so
      // nothing downstream would catch it either.
      final backend = _FakeBackend(
        pendingSequence: ['0.4.0'],
        flashErrors: [StateError('helper stream broke')],
      );
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.failed);
      expect(cubit.state.error, contains('helper stream broke'));
    });

    test('an illegible failure marker counts as interrupted', () async {
      // Comfort that cannot be proven must not be offered: with no legible
      // record of how far the flash got, the dialog must not promise the
      // previous firmware still runs.
      final backend = _FakeBackend(
        pendingSequence: ['0.4.0'],
        flashErrors: [Exception('helper died')],
      );
      final cubit = cubitOver(backend);
      addTearDown(cubit.close);

      await cubit.run();

      expect(backend.failureReads, greaterThan(0));
      expect(cubit.state.stage, PedalFirmwareStage.failed);
      expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
    });

    test('a helper that stops answering entirely is timed out', () {
      // Belt and braces over the helper's own budgets: a wedged process that
      // emits nothing must not hold the console hostage forever.
      fakeAsync((async) {
        final backend = _FakeBackend(pending: '0.4.0');
        final cubit = cubitOver(backend);

        var done = false;
        unawaited(cubit.run().whenComplete(() => done = true));
        async.flushMicrotasks();
        expect(cubit.state.stage, PedalFirmwareStage.flashing);

        // Every attempt gets the stall budget; all of them together must
        // still resolve.
        async.elapse(
          PedalFirmwareCubit.stallTimeout * PedalFirmwareCubit.maxAttempts +
              const Duration(seconds: 1),
        );

        expect(done, isTrue);
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        // The helper never reported reaching the write phase AND left no
        // legible marker, which is not the same as proving nothing was
        // written — a helper wedged before its first PROGRESS line looks
        // identical to one wedged after. Comfort that cannot be proven is not
        // offered, so an unreadable record reads as interrupted here exactly
        // as it does on the non-stall path.
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
        // Every stalled helper is KILLED before the next attempt begins —
        // two privileged flashers must never fight over the bootloader port.
        //
        // Two attempts, not maxAttempts: each stall costs stallTimeout, so the
        // third would start past retryBudget. That is the budget doing its
        // job — 12 minutes behind an undismissable gate instead of 18.
        expect(backend.calls, ['flash', 'abort', 'flash', 'abort']);
        unawaited(cubit.close());
      });
    });

    test('a stall after the write phase is interrupted, marker or not', () {
      // The killed helper wrote no marker, so whatever is on disk is from an
      // EARLIER attempt. A stale not-started record must not buy comfort for
      // a flash that had already been handed the bootloader port.
      fakeAsync((async) {
        final backend = _FakeBackend(
          // After the stall the pedal (wedged mid-write) presents no sketch
          // port: fail fast rather than retry.
          pendingSequence: ['0.4.0'],
          failureClass: PedalFlashFailureClass.notStarted,
        );
        final cubit = cubitOver(backend);

        var done = false;
        unawaited(cubit.run().whenComplete(() => done = true));
        async.flushMicrotasks();
        // The helper reaches the avrdude hand-off (PROGRESS 50), then wedges.
        backend.controller!.add(0.5);
        async
          ..flushMicrotasks()
          ..elapse(
            PedalFirmwareCubit.stallTimeout + const Duration(seconds: 1),
          );

        expect(done, isTrue);
        expect(backend.flashCalls, 1);
        expect(backend.abortCalls, 1);
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
        // The marker IS consulted on the stall path — it just loses here,
        // because this attempt's own progress is the more pessimistic of the
        // two signals.
        expect(backend.failureReads, 1);
        unawaited(cubit.close());
      });
    });

    test("a stall keeps an earlier attempt's interrupted marker", () {
      // The mirror of the test above, and the one that decides what the user
      // is told. This attempt stalls at progress 0, so on its own evidence it
      // "started nothing" — but [_flashOnce] reset that progress to zero, and
      // the marker on disk is an EARLIER attempt of this same campaign saying
      // a write had begun. Judging the stall on this attempt alone would
      // offer "your pedal still works on its previous firmware" for a pedal
      // holding a half-written image. The evidence outlives the attempt that
      // produced it.
      fakeAsync((async) {
        final backend = _FakeBackend(
          // No pending version on the second read: fail fast, one attempt.
          pendingSequence: ['0.4.0'],
          failureClass: PedalFlashFailureClass.interrupted,
        );
        final cubit = cubitOver(backend);

        var done = false;
        unawaited(cubit.run().whenComplete(() => done = true));
        async
          ..flushMicrotasks()
          ..elapse(
            PedalFirmwareCubit.stallTimeout + const Duration(seconds: 1),
          );

        expect(done, isTrue);
        expect(backend.abortCalls, 1);
        expect(cubit.state.stage, PedalFirmwareStage.failed);
        expect(cubit.state.failureClass, PedalFlashFailureClass.interrupted);
        expect(backend.failureReads, 1);
        unawaited(cubit.close());
      });
    });

    test(
      'closing mid-flash unwinds the attempt and kills the helper',
      () async {
        // The window is real: closing a window during the flash disposes the
        // provider while avrdude is mid-write. The stall timer must not stay
        // armed, the run future must unwind on its own (no stream event
        // needed), and no privileged flasher may outlive its supervisor.
        final backend = _FakeBackend(pending: '0.4.0');
        final cubit = cubitOver(backend);

        final done = cubit.run();
        await pumpEventQueue();
        await cubit.close();

        await expectLater(done, completes);
        expect(backend.abortCalls, 1);

        // Late stream events after close are swallowed, not emitted.
        backend.controller!.add(0.7);
        unawaited(backend.controller!.close());
        await pumpEventQueue();
        expect(cubit.state.stage, PedalFirmwareStage.flashing);
        expect(cubit.state.progress, 0);
      },
    );
  });
}
