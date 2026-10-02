import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';

void main() {
  const empty = PowerOffSnapshot();
  const loops = PowerOffSnapshot(anyHasContent: true);
  const named = PowerOffSnapshot(
    anyHasContent: true,
    currentSessionName: 'set',
  );
  const inFlight = PowerOffSnapshot(takeInFlight: true);

  group(PowerOffCubit, () {
    late List<String> log;

    setUp(() => log = <String>[]);

    PowerOffCubit buildCubit({Future<void> Function()? powerOff}) {
      return PowerOffCubit(
        flush: ({required retry}) => log.add('flush'),
        pedalGoodbye: () => log.add('pedal'),
        powerOff:
            powerOff ??
            () async {
              log.add('powerOff');
            },
        markHold: Duration.zero,
      );
    }

    test('halt waits for a delayed confirmed MIDI settings flush', () async {
      final receipt = Completer<void>();
      final cubit = PowerOffCubit(
        flush: ({required retry}) async {
          log.add('flush');
          await receipt.future;
          log.add('saved');
        },
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      )..press(empty);
      await Future<void>.delayed(Duration.zero);
      expect(log, ['flush']);
      receipt.complete();
      await Future<void>.delayed(Duration.zero);
      expect(log, ['flush', 'saved', 'pedal', 'powerOff']);
      await cubit.close();
    });

    test(
      'pending settings lock shutdown and refuse duplicate requests',
      () async {
        final receipt = Completer<void>();
        final cubit = PowerOffCubit(
          flush: ({required retry}) async {
            expect(retry, isFalse);
            log.add('flush');
            await receipt.future;
          },
          pedalGoodbye: () => log.add('pedal'),
          powerOff: () async => log.add('powerOff'),
          markHold: Duration.zero,
        )..press(empty);
        expect(cubit.state.phase, PowerOffPhase.flushing);
        expect(cubit.state.isUiUp, isTrue);
        expect(cubit.state.isDismissible, isFalse);
        cubit
          ..press(empty)
          ..powerOffWithoutSaving(empty)
          ..retryPowerOff(empty)
          ..keepPlaying();
        expect(log, ['flush']);
        receipt.complete();
        await Future<void>.delayed(Duration.zero);
        expect(log, ['flush', 'pedal', 'powerOff']);
        await cubit.close();
      },
    );

    test('explicit Retry recovers once before halting', () async {
      final attempts = <bool>[];
      final cubit = PowerOffCubit(
        flush: ({required retry}) async {
          attempts.add(retry);
          if (!retry) throw StateError('Click rollback pending');
        },
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      )..press(empty);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.phase, PowerOffPhase.flushFailed);
      expect(log, isEmpty);
      cubit.retryPowerOff(empty);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, [false, true]);
      expect(log, ['pedal', 'powerOff']);
      await cubit.close();
    });

    test(
      'Retry rechecks recording and Keep playing dismisses failure',
      () async {
        final cubit = PowerOffCubit(
          flush: ({required retry}) => throw StateError('storage unavailable'),
          pedalGoodbye: () => log.add('pedal'),
          powerOff: () async => log.add('powerOff'),
          markHold: Duration.zero,
        )..press(empty);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.phase, PowerOffPhase.flushFailed);
        cubit.retryPowerOff(inFlight);
        expect(cubit.state.phase, PowerOffPhase.refuse);
        cubit.keepPlaying();
        expect(cubit.state.phase, PowerOffPhase.idle);
        cubit.press(empty);
        await Future<void>.delayed(Duration.zero);
        cubit.keepPlaying();
        expect(cubit.state.phase, PowerOffPhase.idle);
        expect(log, isEmpty);
        await cubit.close();
      },
    );

    test('closing during flush never sends a late halt', () async {
      final receipt = Completer<void>();
      final cubit = PowerOffCubit(
        flush: ({required retry}) => receipt.future,
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      )..press(empty);
      await cubit.close();
      receipt.complete();
      await Future<void>.delayed(Duration.zero);
      expect(log, isEmpty);
    });

    blocTest<PowerOffCubit, PowerOffState>(
      'Keep playing leaves loops/session unchanged and does not halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..keepPlaying(),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'second press while UI is up is a no-op',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..press(inFlight),
      expect: () => [const PowerOffState(phase: PowerOffPhase.confirm)],
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'in-flight take → refuse',
      build: buildCubit,
      act: (cubit) => cubit.press(inFlight),
      expect: () => [const PowerOffState(phase: PowerOffPhase.refuse)],
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'Keep playing from refuse returns to idle',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(inFlight)
        ..keepPlaying(),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.refuse),
        const PowerOffState(),
      ],
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'empty skip-confirm latches goodbye then halt',
      build: buildCubit,
      act: (cubit) => cubit.press(empty),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
      verify: (_) {
        expect(log, ['flush', 'pedal', 'powerOff']);
      },
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'discard flushes then pedal goodbye then powerOff',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..powerOffWithoutSaving(loops),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
      verify: (_) => expect(log, ['flush', 'pedal', 'powerOff']),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'Keep playing is ignored once committed',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(empty)
        ..keepPlaying(),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
    );

    blocTest<PowerOffCubit, PowerOffState>(
      're-check at discard morphs to refuse',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..powerOffWithoutSaving(inFlight),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.refuse),
      ],
    );

    blocTest<PowerOffCubit, PowerOffState>(
      're-check at Save morphs to refuse and does not save',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(
          inFlight,
          save: () async => log.add('save'),
        ),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.refuse),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'unnamed Save emits saveAs and does not halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(loops),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveAs),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'keepPlaying from saveAs aborts halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..keepPlaying(),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveAs),
        const PowerOffState(),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'named save failure does not call powerOff',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(named)
        ..saveAndPowerOff(
          named,
          save: () async => throw StateError('disk full'),
        ),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saving),
        const PowerOffState(phase: PowerOffPhase.saveFailed),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'named save success then halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(named)
        ..saveAndPowerOff(named, save: () async => log.add('save')),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saving),
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
      verify: (_) => expect(log, ['save', 'flush', 'pedal', 'powerOff']),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'isUiUp is true while UI is up',
      build: buildCubit,
      act: (cubit) => cubit.press(loops),
      expect: () => [const PowerOffState(phase: PowerOffPhase.confirm)],
      verify: (cubit) => expect(cubit.state.isUiUp, isTrue),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'commitSave from saveAs then halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..commitSave(loops, () async => log.add('save')),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveAs),
        const PowerOffState(phase: PowerOffPhase.saving),
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
      verify: (_) => expect(log, ['save', 'flush', 'pedal', 'powerOff']),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'commitSave failure does not halt',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..commitSave(loops, () async => throw StateError('disk full')),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveAs),
        const PowerOffState(phase: PowerOffPhase.saving),
        const PowerOffState(phase: PowerOffPhase.saveFailed),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'commitSave re-checks the gate and refuses an in-flight take',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..commitSave(inFlight, () async => log.add('save')),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveAs),
        const PowerOffState(phase: PowerOffPhase.refuse),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'named save without a helper fails closed',
      build: buildCubit,
      act: (cubit) => cubit
        ..press(named)
        ..saveAndPowerOff(named),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.confirm),
        const PowerOffState(phase: PowerOffPhase.saveFailed),
      ],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'commitSave is a no-op from idle',
      build: buildCubit,
      act: (cubit) => cubit.commitSave(empty, () async => log.add('save')),
      wait: const Duration(milliseconds: 1),
      expect: () => <PowerOffState>[],
      verify: (_) => expect(log, isEmpty),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'halt failure freezes on the mark',
      build: () => buildCubit(
        powerOff: () async {
          log.add('powerOff');
          throw StateError('no logind');
        },
      ),
      act: (cubit) => cubit.press(empty),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.goodbye),
      ],
      verify: (_) => expect(log, ['flush', 'pedal', 'powerOff']),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'a throwing flush keeps the device on and offers recovery',
      build: () => PowerOffCubit(
        flush: ({required retry}) {
          log.add('flush');
          throw StateError('store down');
        },
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      ),
      act: (cubit) => cubit.press(empty),
      wait: const Duration(milliseconds: 1),
      expect: () => [
        const PowerOffState(phase: PowerOffPhase.flushing),
        const PowerOffState(phase: PowerOffPhase.flushFailed),
      ],
      verify: (_) => expect(log, ['flush']),
    );

    test('markHold delays powerOff until after the mark', () {
      fakeAsync((async) {
        final cubit = PowerOffCubit(
          flush: ({required retry}) => log.add('flush'),
          pedalGoodbye: () => log.add('pedal'),
          powerOff: () async => log.add('powerOff'),
          markHold: const Duration(milliseconds: 40),
        );
        final held = cubit..press(empty);
        async.flushMicrotasks();
        expect(log, ['flush', 'pedal']);
        expect(held.state.phase, PowerOffPhase.goodbye);
        async.elapse(const Duration(milliseconds: 39));
        expect(log, ['flush', 'pedal']);
        async
          ..elapse(const Duration(milliseconds: 2))
          ..flushMicrotasks();
        expect(log, ['flush', 'pedal', 'powerOff']);
      });
    });
  });
}
