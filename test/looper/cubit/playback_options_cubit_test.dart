import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/playback_options.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Store extends FakeKeyValueStore {
  Completer<void>? onceWrite;
  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == 'looper.default_one_shot') await onceWrite?.future;
    await super.setBool(key, value: value);
  }
}

void main() {
  late _Store store;
  late LooperRepository repository;
  late PlaybackSettings owner;
  late PlaybackOptionsCubit cubit;

  setUp(() {
    store = _Store();
    repository = LooperRepository(engine: FakeAudioEngine());
    owner = PlaybackSettings(
      repository: repository,
      settings: SettingsRepository(store: store),
    );
    cubit = PlaybackOptionsCubit(settings: owner);
  });
  tearDown(() async {
    await cubit.close();
    await owner.close();
    await repository.dispose();
  });

  blocTest<PlaybackOptionsCubit, PlaybackOptions>(
    'projects readiness and forwards explicit zero and false '
    'without inheritance',
    build: () => cubit,
    act: (cubit) async {
      expect(cubit.state.decaySnapshot, isNull);
      expect(cubit.state.oneShotSnapshot, isNull);
      await owner.load();
      await cubit.setOverdubDecay(40);
      await cubit.setDefaultOneShot(value: true);
      await cubit.setTrackOverdubDecay(channel: 0, percent: 0);
      await cubit.setTrackOneShot(channel: 0, oneShot: false);
      expect(cubit.state, same(owner.state));
      expect(cubit.state.decaySnapshot!.trackOverrides, {0: 0});
      expect(cubit.state.oneShotSnapshot!.trackOverrides, {0: false});
      expect(store.values['track_overdub_decay.0'], 0);
      expect(store.values['track_one_shot.0'], isFalse);
      await cubit.setTrackOverdubDecay(channel: 0, percent: null);
      await cubit.setTrackOneShot(channel: 0, oneShot: null);
      expect(cubit.state.decaySnapshot!.trackOverrides, isEmpty);
      expect(cubit.state.oneShotSnapshot!.trackOverrides, isEmpty);
    },
  );

  blocTest<PlaybackOptionsCubit, PlaybackOptions>(
    'closing and remounting a view leaves the accepted owner available',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      await cubit.close();
      expect(
        (await owner.decayControl.setOverdubDecay(
          const DecayAddress.defaults(),
          35,
        )).isOk,
        isTrue,
      );
      final reopened = PlaybackOptionsCubit(settings: owner);
      expect(reopened.state, same(owner.state));
      expect(reopened.state.overdubDecay, 35);
      await reopened.setDefaultOneShot(value: true);
      expect(owner.oneShotControl.oneShotSnapshot!.defaultOneShot, isTrue);
      await reopened.close();
    },
  );

  blocTest<PlaybackOptionsCubit, PlaybackOptions>(
    'an admitted write finishes after its UI projection closes',
    build: () => cubit,
    act: (cubit) async {
      await owner.load();
      final gate = Completer<void>();
      store.onceWrite = gate;
      final pending = cubit.setDefaultOneShot(value: true);
      await pumpEventQueue();
      await cubit.close();
      final closedState = cubit.state;
      gate.complete();
      await pending;
      expect(cubit.state, same(closedState));
      expect(owner.oneShotControl.oneShotSnapshot!.defaultOneShot, isTrue);
      expect(store.values['looper.default_one_shot'], isTrue);
      expect((await owner.oneShotOwner.flush()).isOk, isTrue);
    },
  );
}
