import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
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
  test('an ordinary track edit and an immediately queued flush share '
      'the confirmed owner', () async {
    final repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    final store = _GatedDecayStore();
    final settings = SettingsRepository(store: store);
    final owner = PlaybackSettings(
      repository: repository,
      settings: settings,
    );
    await owner.load();
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      await owner.close();
      await repository.dispose();
    });
    unawaited(owner.decayControl.setTrackOverdubDecay(channel: 7, percent: 55));
    final receipt = owner.decayOwner.flush();
    await store.entered.future;
    await Future<void>.delayed(Duration.zero);
    var flushed = false;
    unawaited(receipt.then((_) => flushed = true));
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    expect(owner.state.trackOverdubDecayOverrides, isEmpty);
    expect(store.values['track_overdub_decay.7'], isNull);
    store.release.complete();
    expect((await receipt).isOk, isTrue);
    expect(store.values['track_overdub_decay.7'], 55);
    expect(owner.state.trackOverdubDecayOverrides, {7: 55});
    expect(repository.trackOverdubDecayOverrides, {7: 55});

    unawaited(
      owner.decayControl.setTrackOverdubDecay(channel: 7, percent: null),
    );
    expect((await owner.decayOwner.flush()).isOk, isTrue);
    expect(store.values.containsKey('track_overdub_decay.7'), isFalse);
    expect(owner.state.trackOverdubDecayOverrides, isEmpty);
    expect(repository.trackOverdubDecayOverrides, isEmpty);
  });
}
