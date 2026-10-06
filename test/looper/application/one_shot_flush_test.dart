import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _GatedOneShotStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == 'track_one_shot.7') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.setBool(key, value: value);
  }
}

void main() {
  test('an ordinary track edit and an immediately queued flush share '
      'the confirmed owner', () async {
    final repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    final store = _GatedOneShotStore();
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
    unawaited(owner.oneShotControl.setTrackOneShot(channel: 7, oneShot: false));
    final receipt = owner.oneShotOwner.flush();
    await store.entered.future;
    await Future<void>.delayed(Duration.zero);
    var flushed = false;
    unawaited(receipt.then((_) => flushed = true));
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    expect(owner.state.trackOneShotOverrides, isEmpty);
    expect(store.values['track_one_shot.7'], isNull);
    store.release.complete();
    expect((await receipt).isOk, isTrue);
    expect(store.values['track_one_shot.7'], false);
    expect(owner.state.trackOneShotOverrides, {7: false});
    expect(repository.trackOneShotOverrides, {7: false});

    unawaited(owner.oneShotControl.setTrackOneShot(channel: 7, oneShot: null));
    expect((await owner.oneShotOwner.flush()).isOk, isTrue);
    expect(store.values.containsKey('track_one_shot.7'), isFalse);
    expect(owner.state.trackOneShotOverrides, isEmpty);
    expect(repository.trackOneShotOverrides, isEmpty);
  });
}
