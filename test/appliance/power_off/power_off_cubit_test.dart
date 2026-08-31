import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

PowerOffCubit _cubit({
  List<String>? log,
  Future<void> Function()? powerOff,
  PowerOffTakeLock? takeLock,
}) {
  final events = log ?? <String>[];
  return PowerOffCubit(
    flush: () => events.add('flush'),
    pedalGoodbye: () => events.add('pedal'),
    powerOff:
        powerOff ??
        () async {
          events.add('powerOff');
        },
    takeLock: takeLock,
    markHold: Duration.zero,
  );
}

void main() {
  const empty = PowerOffSnapshot();
  const loops = PowerOffSnapshot(anyHasContent: true);
  const named = PowerOffSnapshot(
    anyHasContent: true,
    currentSessionName: 'set',
  );
  const inFlight = PowerOffSnapshot(anyCapturingOrPending: true);

  group(PowerOffCubit, () {
    test(
      'Keep playing leaves loops/session unchanged and does not halt',
      () async {
        final log = <String>[];
        final cubit = _cubit(log: log);
        addTearDown(cubit.close);

        cubit.press(loops);
        expect(cubit.state.phase, PowerOffPhase.confirm);
        cubit.keepPlaying();

        expect(cubit.state.phase, PowerOffPhase.idle);
        await _settle();
        expect(log, isEmpty);
      },
    );

    test('second press while UI is up is a no-op', () {
      final cubit = _cubit();
      addTearDown(cubit.close);

      cubit
        ..press(loops)
        ..press(inFlight);

      expect(cubit.state.phase, PowerOffPhase.confirm);
    });

    test('in-flight take → refuse', () {
      final cubit = _cubit();
      addTearDown(cubit.close);
      cubit.press(inFlight);
      expect(cubit.state.phase, PowerOffPhase.refuse);
    });

    test('empty skip-confirm latches goodbye then halt', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);

      cubit.press(empty);
      expect(cubit.state.isUiUp, isTrue);
      await _settle();

      expect(cubit.state.phase, PowerOffPhase.goodbye);
      expect(log, ['flush', 'pedal', 'powerOff']);
    });

    test('discard flushes then pedal goodbye then powerOff', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);

      cubit
        ..press(loops)
        ..powerOffWithoutSaving(loops);
      await _settle();

      expect(log, ['flush', 'pedal', 'powerOff']);
    });

    test('Keep playing is ignored once committed', () async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      cubit
        ..press(empty)
        ..keepPlaying();
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.goodbye);
    });

    test('re-check at discard morphs to refuse', () {
      final cubit = _cubit();
      addTearDown(cubit.close);
      cubit
        ..press(loops)
        ..powerOffWithoutSaving(inFlight);
      expect(cubit.state.phase, PowerOffPhase.refuse);
    });

    test('unnamed Save emits saveAs and does not halt', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..press(loops)
        ..saveAndPowerOff(loops);
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.saveAs);
      expect(log, isEmpty);
    });

    test('named save failure does not call powerOff', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..press(named)
        ..saveAndPowerOff(
          named,
          save: () async => throw StateError('disk full'),
        );
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.saveFailed);
      expect(log, isEmpty);
    });

    test('named save success then halt', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..press(named)
        ..saveAndPowerOff(named, save: () async => log.add('save'));
      await _settle();
      expect(log, ['save', 'flush', 'pedal', 'powerOff']);
      expect(cubit.state.phase, PowerOffPhase.goodbye);
    });

    test('take lock is up while UI is up', () {
      final lock = PowerOffTakeLock();
      final cubit = _cubit(takeLock: lock);
      addTearDown(cubit.close);
      cubit.press(loops);
      expect(lock.locked, isTrue);
      cubit.keepPlaying();
      expect(lock.locked, isFalse);
    });

    test('beginSaving then saveCompleted halts', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..beginSaving();
      expect(cubit.state.phase, PowerOffPhase.saving);
      cubit.saveCompleted();
      await _settle();
      expect(log, ['flush', 'pedal', 'powerOff']);
      expect(cubit.state.phase, PowerOffPhase.goodbye);
    });

    test('saveFailed does not halt', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..press(loops)
        ..saveAndPowerOff(loops)
        ..saveFailed();
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.saveFailed);
      expect(log, isEmpty);
    });

    test('Save As methods are no-ops from idle', () async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      cubit
        ..beginSaving()
        ..saveCompleted()
        ..saveFailed();
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(log, isEmpty);
    });

    test('halt failure freezes on the mark', () async {
      final cubit = _cubit(powerOff: () async => throw StateError('no logind'));
      addTearDown(cubit.close);
      cubit.press(empty);
      await _settle();
      expect(cubit.state.phase, PowerOffPhase.goodbye);
    });
  });
}
