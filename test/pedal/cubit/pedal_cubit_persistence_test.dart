import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';

const _key = 'pedal.ctrl_calibration.0';
const _ends = PedalCtrlCalibration(min: 24, max: 200);

class _ControlledStore extends FakeKeyValueStore {
  Completer<String?>? read;
  Completer<void>? write;
  bool failRead = false;
  bool failWrite = false;
  bool failRemove = false;
  final reads = <String>[];
  int writes = 0;
  int removals = 0;

  @override
  Future<String?> getString(String key) async {
    reads.add(key);
    if (key == _key) {
      if (failRead) throw StateError('cannot read preferences');
      final pending = read;
      if (pending != null) return pending.future;
    }
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    writes++;
    await write?.future;
    if (failWrite) throw StateError('cannot save preferences');
    await super.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    removals++;
    if (failRemove) throw StateError('cannot remove preferences');
    await super.remove(key);
  }
}

void main() {
  late _ControlledStore store;
  late FakePedalLink link;
  late PedalRepository pedal;
  late PedalCubit cubit;

  void create() {
    link = FakePedalLink();
    pedal = PedalRepository(link);
    cubit = PedalCubit(
      pedal: pedal,
      settings: SettingsRepository(store: store),
    );
  }

  Future<void> sweep() async {
    cubit.beginCtrlCalibration(PedalCtrlJack.ctrl1);
    link.hello();
    for (final value in [0, 255]) {
      link.emit(
        CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.expression,
          value: value,
        ),
      );
    }
    await pumpEventQueue();
  }

  setUp(() => store = _ControlledStore());
  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
  });

  test('reset waits for a pending initial read and remains reset', () async {
    store.read = Completer<String?>();
    create();
    final reset = cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);
    expect(cubit.state.calibrationBusy, isTrue);
    expect(store.removals, 0);

    store.read!.complete('24,200');
    await reset;

    expect(store.removals, 1);
    expect(store.values[_key], isNull);
    expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
    expect(cubit.state.calibrated, isEmpty);
    expect(cubit.state.calibrationBusy, isFalse);
  });

  test('a new calibration wins over a delayed initial read', () async {
    store.read = Completer<String?>();
    create();
    await sweep();
    final save = cubit.finishCtrlCalibration();
    expect(store.writes, 0);

    store.read!.complete('24,200');
    await save;

    expect(store.values[_key], '0,255');
    expect(
      pedal.ctrlCalibration(PedalCtrlJack.ctrl1),
      const PedalCtrlCalibration(min: 0, max: 255),
    );
    expect(cubit.state.calibrating, isNull);
  });

  test('read failure is reported and other jacks still load', () async {
    store
      ..failRead = true
      ..values['pedal.ctrl_calibration.1'] = '30,230';
    create();
    await pumpEventQueue();

    expect(cubit.state.calibrationError, PedalCalibrationError.load);
    expect(cubit.state.calibrated, {PedalCtrlJack.ctrl2});
    expect(
      pedal.ctrlCalibration(PedalCtrlJack.ctrl2),
      const PedalCtrlCalibration(min: 30, max: 230),
    );
  });

  test('a failed save keeps the previous ends and can be retried', () async {
    store.values[_key] = '24,200';
    create();
    await pumpEventQueue();
    await sweep();
    store.failWrite = true;

    await cubit.finishCtrlCalibration();

    expect(cubit.state.calibrationError, PedalCalibrationError.save);
    expect(cubit.state.calibrationBusy, isFalse);
    expect(cubit.state.calibrating, PedalCtrlJack.ctrl1);
    expect(cubit.state.calibrationSeen?.isUsable, isTrue);
    expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), _ends);
    expect(store.values[_key], '24,200');

    store.failWrite = false;
    await cubit.finishCtrlCalibration();
    expect(cubit.state.calibrationError, isNull);
    expect(cubit.state.calibrating, isNull);
    expect(store.values[_key], '0,255');
  });

  test('a failed reset leaves the stored and active ends intact', () async {
    store.values[_key] = '24,200';
    create();
    await pumpEventQueue();
    store.failRemove = true;

    await cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);

    expect(cubit.state.calibrationError, PedalCalibrationError.reset);
    expect(cubit.state.calibrationBusy, isFalse);
    expect(cubit.state.calibrated, {PedalCtrlJack.ctrl1});
    expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), _ends);
    expect(store.values[_key], '24,200');

    store.failRemove = false;
    await cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);
    expect(cubit.state.calibrationError, isNull);
    expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
    expect(store.values[_key], isNull);
  });

  test('pending save holds the active ends and excludes other edits', () async {
    store.values[_key] = '24,200';
    create();
    await pumpEventQueue();
    await sweep();
    store.write = Completer<void>();
    final save = cubit.finishCtrlCalibration();
    await pumpEventQueue();

    expect(cubit.state.calibrationBusy, isTrue);
    expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), _ends);
    await cubit.finishCtrlCalibration();
    await cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);
    cubit
      ..cancelCtrlCalibration()
      ..beginCtrlCalibration(PedalCtrlJack.ctrl2);
    expect(cubit.state.calibrating, PedalCtrlJack.ctrl1);
    expect(store.writes, 1);
    expect(store.removals, 0);

    store.write!.complete();
    await save;
    expect(cubit.state.calibrationBusy, isFalse);
    expect(store.values[_key], '0,255');
  });

  for (final save in [true, false]) {
    test(
      'close cancels a queued ${save ? 'save' : 'reset'} before storage',
      () async {
        store.read = Completer<String?>();
        create();
        await sweep();
        final mutation = save
            ? cubit.finishCtrlCalibration()
            : cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);
        await cubit.close();
        store.read!.complete('24,200');
        await mutation;

        expect(store.writes, 0);
        expect(store.removals, 0);
        expect(store.reads, [_key]);
        expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
      },
    );
  }

  for (final fail in [false, true]) {
    test(
      'close drains an in-flight ${fail ? 'failed' : 'successful'} write',
      () async {
        create();
        await pumpEventQueue();
        await sweep();
        store
          ..write = Completer<void>()
          ..failWrite = fail;
        final save = cubit.finishCtrlCalibration();
        await pumpEventQueue();
        final closing = cubit.close();
        expect(link.disposed, isFalse);

        store.write!.complete();
        await save;
        await closing;

        expect(link.disposed, isTrue);
        expect(cubit.isClosed, isTrue);
        expect(store.values[_key], fail ? isNull : '0,255');
        expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
      },
    );
  }

  test('closed cubit ignores calibration actions', () async {
    create();
    await pumpEventQueue();
    await cubit.close();

    cubit
      ..beginCtrlCalibration(PedalCtrlJack.ctrl1)
      ..cancelCtrlCalibration();
    await cubit.finishCtrlCalibration();
    await cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);

    expect(store.writes, 0);
    expect(store.removals, 0);
  });
}
