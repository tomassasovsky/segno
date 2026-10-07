import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';

void main() {
  const named = PowerSnapshot(currentSessionName: 'set');
  const unnamed = PowerSnapshot();
  const inFlight = PowerSnapshot(
    takeInFlight: true,
    currentSessionName: 'set',
  );
  const transfer = PowerSnapshot(
    transferInFlight: true,
    currentSessionName: 'set',
  );

  group(PowerCubit, () {
    late List<String> log;
    late GuardRegistry guards;

    setUp(() {
      log = <String>[];
      guards = GuardRegistry();
    });

    PowerCubit build({
      FutureOr<void> Function({required bool retry})? flush,
      Future<void> Function()? storageSettled,
      Future<void> Function()? powerOff,
      Duration markHold = Duration.zero,
    }) {
      return PowerCubit(
        stopTransport: () => log.add('stop'),
        flush: flush ?? ({required retry}) => log.add('flush'),
        storageSettled:
            storageSettled ??
            () async {
              log.add('storage');
            },
        guards: guards,
        pedalGoodbye: () => log.add('pedal'),
        powerOff:
            powerOff ??
            () async {
              log.add('powerOff');
            },
        reboot: () async => log.add('reboot'),
        markHold: markHold,
      );
    }

    Future<void> save() async => log.add('save');

    Future<void> failingSave() async {
      log.add('save');
      throw StateError('disk full');
    }

    group('press', () {
      blocTest<PowerCubit, PowerState>(
        'opens Power options whether or not anything is recorded',
        build: build,
        act: (cubit) => cubit.press(unnamed),
        expect: () => const [PowerState(phase: PowerPhase.options)],
      );

      blocTest<PowerCubit, PowerState>(
        'refuses during a take',
        build: build,
        act: (cubit) => cubit.press(inFlight),
        expect: () => const [PowerState(phase: PowerPhase.refuse)],
      );

      blocTest<PowerCubit, PowerState>(
        'refuses during a transfer',
        build: build,
        act: (cubit) => cubit.press(transfer),
        expect: () => const [PowerState(phase: PowerPhase.refuse)],
      );

      blocTest<PowerCubit, PowerState>(
        'is ignored while the UI is up',
        build: build,
        seed: () => const PowerState(phase: PowerPhase.options),
        act: (cubit) => cubit.press(inFlight),
        expect: () => const <PowerState>[],
      );
    });

    blocTest<PowerCubit, PowerState>(
      'Cancel returns to idle and touches nothing',
      build: build,
      act: (cubit) => cubit
        ..press(named)
        ..dismiss(),
      expect: () => const [
        PowerState(phase: PowerPhase.options),
        PowerState(),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    test(
      'Restart: stop, flush, save, storage, then reboot exactly once',
      () async {
        final cubit = build()
          ..press(named)
          ..restart(named, save: save);
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'save', 'storage', 'pedal', 'reboot']);
        expect(
          cubit.state,
          const PowerState(
            phase: PowerPhase.goodbye,
            action: PowerAction.restart,
          ),
        );
        await cubit.close();
      },
    );

    test('Shut down: the same order, then powerOff', () async {
      final cubit = build()
        ..press(named)
        ..shutDown(named, save: save);
      await pumpEventQueue();
      expect(log, ['stop', 'flush', 'save', 'storage', 'pedal', 'powerOff']);
      expect(cubit.state.action, PowerAction.shutDown);
      await cubit.close();
    });

    test(
      'Restart from idle (Install and restart) runs the same path',
      () async {
        final cubit = build()..restart(named, save: save);
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'save', 'storage', 'pedal', 'reboot']);
        await cubit.close();
      },
    );

    test('Restart during a take is refused: no save, no reboot', () async {
      final cubit = build()..restart(inFlight, save: save);
      await pumpEventQueue();
      expect(cubit.state, const PowerState(phase: PowerPhase.refuse));
      expect(log, isEmpty);
      await cubit.close();
    });

    test('a take that started after the press refuses the commit', () async {
      final cubit = build()
        ..press(named)
        ..shutDown(inFlight, save: save);
      await pumpEventQueue();
      expect(cubit.state.phase, PowerPhase.refuse);
      expect(log, isEmpty);
      await cubit.close();
    });

    group('save failure', () {
      test('stays on: saveFailed, neither reboot nor powerOff', () async {
        final cubit = build()
          ..press(named)
          ..restart(named, save: failingSave);
        await pumpEventQueue();
        expect(
          cubit.state,
          const PowerState(
            phase: PowerPhase.saveFailed,
            action: PowerAction.restart,
          ),
        );
        expect(log, ['stop', 'flush', 'save']);
        expect(cubit.state.isDismissible, isTrue);
        await cubit.close();
      });

      test('a settings flush failure is a save failure too', () async {
        final cubit = build(
          flush: ({required retry}) => throw StateError('unconfirmed'),
        )..shutDown(named, save: save);
        await pumpEventQueue();
        expect(cubit.state.phase, PowerPhase.saveFailed);
        expect(log, ['stop']);
        await cubit.close();
      });

      test('Retry repeats the save with the repairing flush', () async {
        final attempts = <bool>[];
        var fail = true;
        final cubit =
            build(
              flush: ({required retry}) => attempts.add(retry),
            )..restart(
              named,
              save: () async {
                log.add('save');
                if (fail) throw StateError('disk full');
              },
            );
        await pumpEventQueue();
        expect(cubit.state.phase, PowerPhase.saveFailed);
        fail = false;
        cubit.retry(named);
        await pumpEventQueue();
        expect(attempts, [false, true]);
        expect(log, [
          'stop',
          'save',
          'stop',
          'save',
          'storage',
          'pedal',
          'reboot',
        ]);
        await cubit.close();
      });

      test('Retry still honours the take gate', () async {
        final cubit = build()..shutDown(named, save: failingSave);
        await pumpEventQueue();
        cubit.retry(inFlight);
        await pumpEventQueue();
        expect(cubit.state, const PowerState(phase: PowerPhase.refuse));
        expect(log, ['stop', 'flush', 'save']);
        await cubit.close();
      });

      test('Stay on returns to idle; nothing halts', () async {
        final cubit = build()..shutDown(named, save: failingSave);
        await pumpEventQueue();
        cubit.dismiss();
        expect(cubit.state, const PowerState());
        cubit.retry(named);
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'save']);
        await cubit.close();
      });
    });

    group('unnamed session', () {
      test('asks for Save As, then saves under the name', () async {
        final cubit = build()
          ..press(unnamed)
          ..restart(unnamed, save: () async => fail('not the named save'));
        expect(
          cubit.state,
          const PowerState(
            phase: PowerPhase.saveAs,
            action: PowerAction.restart,
          ),
        );
        expect(log, isEmpty);
        cubit.commitSaveAs(
          unnamed,
          save: () async => log.add('saveAs'),
        );
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'saveAs', 'storage', 'pedal', 'reboot']);
        await cubit.close();
      });

      test('cancelling Save As returns to idle', () async {
        final cubit = build()
          ..shutDown(unnamed, save: save)
          ..dismiss();
        expect(cubit.state, const PowerState());
        expect(log, isEmpty);
        await cubit.close();
      });
    });

    test('the save is not dismissible and ignores every input', () async {
      final saving = Completer<void>();
      final cubit = build()
        ..shutDown(
          named,
          save: () async {
            log.add('save');
            await saving.future;
          },
        );
      await pumpEventQueue();
      expect(cubit.state.phase, PowerPhase.saving);
      expect(cubit.state.isUiUp, isTrue);
      expect(cubit.state.isDismissible, isFalse);
      cubit
        ..press(named)
        ..dismiss()
        ..restart(named, save: save)
        ..retry(named);
      saving.complete();
      await pumpEventQueue();
      expect(log, ['stop', 'flush', 'save', 'storage', 'pedal', 'powerOff']);
      await cubit.close();
    });

    test(
      'with a storage lease held, reboot waits until it is released',
      () async {
        final released = Completer<void>();
        final cubit = build(
          storageSettled: () {
            log.add('storage');
            return released.future;
          },
        )..restart(named, save: save);
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'save', 'storage']);
        expect(cubit.state.phase, PowerPhase.saving);
        released.complete();
        await pumpEventQueue();
        expect(log, ['stop', 'flush', 'save', 'storage', 'pedal', 'reboot']);
        await cubit.close();
      },
    );

    test('holds the restart guard after the save, so no capture can '
        'start', () async {
      final cubit = build()..restart(named, save: save);
      await pumpEventQueue();
      expect(
        guards.blockers(GuardKind.capture, const GuardScope.internal()),
        [
          isA<ActiveOperation>().having(
            (op) => op.kind,
            'kind',
            GuardKind.restart,
          ),
        ],
      );
      await cubit.close();
      expect(guards.active, isEmpty);
    });

    test('an operation still holding a guard after the save keeps Segno '
        'on', () async {
      final cubit = build()
        ..restart(
          named,
          save: () async {
            guards.enter(
              GuardKind.sessionWrite,
              const GuardScope.internal(),
              purpose: 'save',
            );
          },
        );
      await pumpEventQueue();
      expect(cubit.state.phase, PowerPhase.saveFailed);
      expect(log, ['stop', 'flush']);
      await cubit.close();
    });

    test('closing during the save never sends a late halt', () async {
      final saving = Completer<void>();
      final cubit = build()..shutDown(named, save: () => saving.future);
      await pumpEventQueue();
      await cubit.close();
      saving.complete();
      await pumpEventQueue();
      expect(log, ['stop', 'flush']);
    });

    test('a failing helper freezes on the terminal face', () async {
      final cubit = build(powerOff: () async => throw StateError('helper'))
        ..shutDown(named, save: save);
      await pumpEventQueue();
      expect(cubit.state.phase, PowerPhase.goodbye);
      await cubit.close();
    });

    test('markHold delays the halt until after the terminal face', () {
      fakeAsync((async) {
        final cubit = build(markHold: const Duration(seconds: 2))
          ..shutDown(named, save: save);
        async.flushMicrotasks();
        expect(cubit.state.phase, PowerPhase.goodbye);
        expect(log, isNot(contains('powerOff')));
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        expect(log.last, 'powerOff');
        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });
  });
}
