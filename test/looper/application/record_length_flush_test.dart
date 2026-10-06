import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _GatedLengthStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'tempo.length_preset.7') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.setInt(key, value);
  }
}

void main() {
  test('an ordinary track edit and an immediately queued flush share the '
      'confirmed owner', () async {
    final repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    final store = _GatedLengthStore();
    final settings = SettingsRepository(store: store);
    await settings.saveLooperMode(LooperMode.free.code);
    final owner = RecordSettings(
      repository: repository,
      settings: settings,
    );
    await owner.load();
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      await owner.close();
      await repository.dispose();
    });
    var flushed = false;
    unawaited(owner.setTrackRecordLength(channel: 7, bars: 0));
    final receipt = owner.owner.flush().then((_) => flushed = true);
    await store.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    expect(owner.state.trackLengthPresetOverrides, isEmpty);
    expect(store.values['tempo.length_preset.7'], isNull);
    store.release.complete();
    await receipt;
    expect(store.values['tempo.length_preset.7'], 0);
    expect(owner.state.trackLengthPresetOverrides, {7: 0});
    expect(repository.trackLengthPresetOverrides, {7: 0});

    unawaited(owner.setTrackRecordLength(channel: 7, bars: null));
    await owner.owner.flush();
    expect(store.values.containsKey('tempo.length_preset.7'), isFalse);
    expect(owner.state.trackLengthPresetOverrides, isEmpty);
    expect(repository.trackLengthPresetOverrides, isEmpty);
  });
}
