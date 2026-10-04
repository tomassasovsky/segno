import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Store extends FakeKeyValueStore {
  Completer<void>? gate;
  @override
  Future<void> setBool(String key, {required bool value}) async {
    await gate?.future;
    await super.setBool(key, value: value);
  }
}

void main() {
  late _Store store;
  late LooperRepository repository;
  late RecordTimingSettings owner;
  late RecordTimingCubit cubit;

  setUp(() {
    store = _Store();
    repository = LooperRepository(engine: FakeAudioEngine());
    owner = RecordTimingSettings(
      repository: repository,
      settings: SettingsRepository(store: store),
    );
    cubit = RecordTimingCubit(settings: owner);
  });

  tearDown(() async {
    await cubit.close();
    await owner.close();
    await repository.dispose();
  });

  blocTest<RecordTimingCubit, RecordTimingState>(
    'projects initialization and forwards ordinary timing to its owner',
    build: () => cubit,
    act: (cubit) async {
      expect(cubit.state.recordTimingSnapshot, isNull);
      await owner.load();
      expect(cubit.state.recordTimingReady, isTrue);
      expect(cubit.state, same(owner.state));
      await cubit.setTiming(RecordTiming.quarter);
      expect(cubit.state, same(owner.state));
      expect(repository.defaultRecordTiming, RecordTiming.quarter);
      expect(store.values['looper.quantize'], isTrue);
      expect(store.values['tempo.quantize_div'], 3);
    },
  );

  blocTest<RecordTimingCubit, RecordTimingState>(
    'closing the borrowed projection does not retire the application owner',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      await cubit.close();
      expect((await owner.setTiming(RecordTiming.eighth)).isOk, isTrue);
      final reopened = RecordTimingCubit(settings: owner);
      expect(reopened.state, same(owner.state));
      expect(reopened.state.defaultTiming, RecordTiming.eighth);
      await reopened.setEnabled(value: false);
      expect(owner.state.defaultTiming, RecordTiming.immediately);
      expect(owner.state.rememberedDivision, GridDivision.eighth);
      await reopened.close();
    },
  );

  blocTest<RecordTimingCubit, RecordTimingState>(
    'an admitted write finishes after the UI projection closes',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      final gate = Completer<void>();
      store.gate = gate;
      final pending = cubit.setTiming(RecordTiming.quarter);
      await pumpEventQueue();
      await cubit.close();
      final closedState = cubit.state;
      gate.complete();
      await pending;
      expect(cubit.state, same(closedState));
      expect(owner.state.defaultTiming, RecordTiming.quarter);
      expect((await owner.flushRecordTiming()).isOk, isTrue);
      expect(store.values['tempo.quantize_div'], 3);
    },
  );
}
