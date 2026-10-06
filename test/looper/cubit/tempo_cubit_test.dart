import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Store extends FakeKeyValueStore {
  Completer<void>? modeWrite;
  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'tempo.click_mode') await modeWrite?.future;
    await super.setInt(key, value);
  }
}

void main() {
  late _Store store;
  late LooperRepository repository;
  late TempoSettings owner;
  late TempoCubit cubit;

  setUp(() {
    store = _Store();
    repository = LooperRepository(engine: FakeAudioEngine());
    owner = TempoSettings(
      repository: repository,
      settings: SettingsRepository(store: store),
    );
    cubit = TempoCubit(settings: owner);
  });
  tearDown(() async {
    await cubit.close();
    await owner.close();
    await repository.dispose();
  });

  blocTest<TempoCubit, TempoState>(
    'publishes independent initialization and forwards ordinary UI choices',
    build: () => cubit,
    act: (cubit) async {
      expect(cubit.state.confirmedClickMode, isNull);
      expect(cubit.state.recordStartSnapshot, isNull);
      await owner.clickModeOwner.load();
      expect(cubit.state.confirmedClickMode, ClickMode.recFirst);
      expect(cubit.state.recordStartSnapshot, isNull);
      await owner.recordStartOwner.load();
      expect(cubit.state.recordStartSnapshot?.settings.countInBars, 1);
      await cubit.setCountInBars(2);
      expect(cubit.state, same(owner.state));
      expect(repository.recordStartSettings.countInBars, 2);
      expect(store.values['tempo.count_in_bars'], 2);
    },
  );

  blocTest<TempoCubit, TempoState>(
    'closing and remounting the projection leaves the accepted owner alive',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      await cubit.close();
      expect((await owner.clickModeOwner.set(ClickMode.playRec)).isOk, isTrue);
      final reopened = TempoCubit(settings: owner);
      expect(reopened.state, same(owner.state));
      expect(reopened.state.confirmedClickMode, ClickMode.playRec);
      await reopened.setClickVolume(.5);
      expect(owner.clickVolumeOwner.value, .5);
      await reopened.close();
    },
  );

  blocTest<TempoCubit, TempoState>(
    'an admitted mode transaction completes after its UI projection closes',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      final gate = Completer<void>();
      store.modeWrite = gate;
      final pending = cubit.setClickMode(ClickMode.rec);
      await pumpEventQueue();
      await cubit.close();
      final closedState = cubit.state;
      gate.complete();
      await pending;
      expect(cubit.state, same(closedState));
      expect(owner.state.confirmedClickMode, ClickMode.rec);
      expect(store.values['tempo.click_mode'], 1);
      expect((await owner.clickModeOwner.flush()).isOk, isTrue);
    },
  );
}
