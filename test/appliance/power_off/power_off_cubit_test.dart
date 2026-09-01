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
        flush: () => log.add('flush'),
        pedalGoodbye: () => log.add('pedal'),
        powerOff:
            powerOff ??
            () async {
              log.add('powerOff');
            },
        markHold: Duration.zero,
      );
    }

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
      expect: () => [const PowerOffState(phase: PowerOffPhase.goodbye)],
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
      expect: () => [const PowerOffState(phase: PowerOffPhase.goodbye)],
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
      expect: () => [const PowerOffState(phase: PowerOffPhase.goodbye)],
      verify: (_) => expect(log, ['flush', 'pedal', 'powerOff']),
    );

    blocTest<PowerOffCubit, PowerOffState>(
      'a throwing flush still goodbyes and powerOffs',
      build: () => PowerOffCubit(
        flush: () {
          log.add('flush');
          throw StateError('store down');
        },
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      ),
      act: (cubit) => cubit.press(empty),
      wait: const Duration(milliseconds: 1),
      expect: () => [const PowerOffState(phase: PowerOffPhase.goodbye)],
      verify: (_) => expect(log, ['flush', 'pedal', 'powerOff']),
    );

    test('markHold delays powerOff until after the mark', () {
      fakeAsync((async) {
        final cubit = PowerOffCubit(
          flush: () => log.add('flush'),
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
