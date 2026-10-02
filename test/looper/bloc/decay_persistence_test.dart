import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _GatedDecayStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'track_overdub_decay.7') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.setInt(key, value);
  }
}

void main() {
  test('ordinary track edit and immediately queued persistence flush share '
      'the confirmed owner', () async {
    final repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    final store = _GatedDecayStore();
    final settings = SettingsRepository(store: store);
    final owner = PlaybackOptionsCubit(
      repository: repository,
      settings: settings,
    );
    await owner.load();
    final mix = testMixSettings(repository, settings: settings);
    final bloc = LooperBloc(
      repository: repository,
      settings: settings,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: repository),
      decayControl: owner,
    );
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      await bloc.close();
      await owner.close();
      await mix.close();
      await repository.dispose();
    });
    final receipt = Completer<void>();
    bloc
      ..add(const LooperTrackOverdubDecayChanged(7, percent: 55))
      ..add(LooperPersistFlush(receipt: receipt));
    await store.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(receipt.isCompleted, isFalse);
    expect(owner.state.trackOverdubDecayOverrides, isEmpty);
    expect(store.values['track_overdub_decay.7'], isNull);
    store.release.complete();
    await receipt.future;
    expect(store.values['track_overdub_decay.7'], 55);
    expect(owner.state.trackOverdubDecayOverrides, {7: 55});
    expect(repository.trackOverdubDecayOverrides, {7: 55});

    final reset = Completer<void>();
    bloc
      ..add(const LooperTrackOverdubDecayChanged(7, percent: null))
      ..add(LooperPersistFlush(receipt: reset));
    await reset.future;
    expect(store.values.containsKey('track_overdub_decay.7'), isFalse);
    expect(owner.state.trackOverdubDecayOverrides, isEmpty);
    expect(repository.trackOverdubDecayOverrides, isEmpty);
  });
}
