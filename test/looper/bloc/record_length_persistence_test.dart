import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/looper.dart';
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
  test('ordinary track edit and immediately queued persistence flush share '
      'the confirmed owner', () async {
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
    final mix = testMixSettings(repository, settings: settings);
    final bloc = LooperBloc(
      repository: repository,
      settings: settings,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: repository),
      recordLengthControl: owner,
      recordTimingControl: FakeRecordTimingControl(),
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
      ..add(const LooperTrackLengthPresetChanged(7, 0))
      ..add(LooperPersistFlush(receipt: receipt));
    await store.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(receipt.isCompleted, isFalse);
    expect(owner.state.trackLengthPresetOverrides, isEmpty);
    expect(store.values['tempo.length_preset.7'], isNull);
    store.release.complete();
    await receipt.future;
    expect(store.values['tempo.length_preset.7'], 0);
    expect(owner.state.trackLengthPresetOverrides, {7: 0});
    expect(repository.trackLengthPresetOverrides, {7: 0});

    final reset = Completer<void>();
    bloc
      ..add(const LooperTrackLengthPresetChanged(7, null))
      ..add(LooperPersistFlush(receipt: reset));
    await reset.future;
    expect(store.values.containsKey('tempo.length_preset.7'), isFalse);
    expect(owner.state.trackLengthPresetOverrides, isEmpty);
    expect(repository.trackLengthPresetOverrides, isEmpty);
  });
}
