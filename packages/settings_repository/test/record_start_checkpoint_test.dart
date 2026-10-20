import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _Store extends Fake implements KeyValueStore {
  final values = <String, Object>{};
  int failWrite = 0;
  bool drop = false;
  Completer<void>? gate;
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setInt(String key, int value) async {
    if (!drop) values[key] = value;
    await gate?.future;
    if (failWrite > 0 && --failWrite == 0) throw StateError('partial pair');
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (!drop) values[key] = value;
    if (failWrite > 0 && --failWrite == 0) throw StateError('partial pair');
  }

  @override
  Future<void> remove(String key) async {
    if (!drop) values.remove(key);
  }
}

void main() {
  test(
    'exact independent absence and explicit Off survive compensation',
    () async {
      for (final prior in [
        (countInBars: null, soundStart: null),
        (countInBars: 0, soundStart: null),
        (countInBars: null, soundStart: false),
        (countInBars: null, soundStart: true),
        (countInBars: 2, soundStart: false),
      ]) {
        final store = _Store();
        final settings = SettingsRepository(store: store);
        await settings.restoreRecordStartCheckpoint(prior);
        final exact = Map<String, Object>.of(store.values);
        store.failWrite = 2;
        await expectLater(
          settings.saveRecordStartSettings(countInBars: 4, soundStart: false),
          throwsStateError,
        );
        await settings.restoreRecordStartCheckpoint(prior);
        expect(store.values, exact);
        expect(await settings.readRecordStartCheckpoint(), prior);
      }
    },
  );

  test('strict malformed pair preserves raw values', () async {
    final store = _Store();
    final settings = SettingsRepository(store: store);
    for (final bars in <Object>[-1, 3, 5, 16, 64, '1', true, 1.5]) {
      store.values['tempo.count_in_bars'] = bars;
      await expectLater(
        settings.readRecordStartCheckpoint(),
        throwsA(anything),
      );
      expect(store.values['tempo.count_in_bars'], bars);
    }
    store.values['tempo.count_in_bars'] = 2;
    store.values['looper.auto_record'] = true;
    await expectLater(
      settings.readRecordStartCheckpoint(),
      throwsFormatException,
    );
    expect(store.values, {
      'tempo.count_in_bars': 2,
      'looper.auto_record': true,
    });
    store.values['tempo.count_in_bars'] = 0;
    store.values['looper.auto_record'] = 'false';
    await expectLater(settings.readRecordStartCheckpoint(), throwsA(anything));
    expect(store.values['looper.auto_record'], 'false');
  });

  test('checkpoint read waits for both scalars of a queued write', () async {
    final store = _Store()..gate = Completer<void>();
    final settings = SettingsRepository(store: store);
    final write = settings.saveRecordStartSettings(
      countInBars: 2,
      soundStart: false,
    );
    var completed = false;
    final read = settings.readRecordStartCheckpoint().then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(store.values, {'tempo.count_in_bars': 2});
    expect(completed, isFalse);
    store.gate!.complete();
    await write;
    expect(await read, (countInBars: 2, soundStart: false));
  });

  test('silent scalar loss and removal loss fail verification', () async {
    final store = _Store()..drop = true;
    final settings = SettingsRepository(store: store);
    await expectLater(
      settings.saveRecordStartSettings(countInBars: 1, soundStart: false),
      throwsStateError,
    );
    store.values.addAll({'tempo.count_in_bars': 0, 'looper.auto_record': true});
    await expectLater(
      settings.restoreRecordStartCheckpoint((
        countInBars: null,
        soundStart: null,
      )),
      throwsStateError,
    );
    expect(store.values, {
      'tempo.count_in_bars': 0,
      'looper.auto_record': true,
    });
  });
}
