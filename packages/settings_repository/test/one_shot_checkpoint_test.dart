import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _Store extends Fake implements KeyValueStore {
  final values = <String, Object>{};
  bool discard = false;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (!discard) values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  group('Once scalar checkpoint', () {
    late _Store store;
    late SettingsRepository settings;
    setUp(() {
      store = _Store();
      settings = SettingsRepository(store: store);
    });
    test(
      'absence and explicit false restore exactly without sibling writes',
      () async {
        store.values['sentinel'] = 17;
        expect(await settings.readOneShotCheckpoint(channel: null), isNull);
        await settings.restoreOneShotCheckpoint(channel: null, oneShot: false);
        await settings.restoreOneShotCheckpoint(channel: 7, oneShot: false);
        expect(await settings.readOneShotCheckpoint(channel: null), isFalse);
        expect(await settings.readOneShotCheckpoint(channel: 7), isFalse);
        await settings.restoreOneShotCheckpoint(channel: null, oneShot: null);
        await settings.restoreOneShotCheckpoint(channel: 7, oneShot: null);
        expect(store.values, {'sentinel': 17});
      },
    );
    test('discarded writes refuse and later writers still work', () async {
      store.discard = true;
      await expectLater(
        settings.restoreOneShotCheckpoint(channel: null, oneShot: true),
        throwsStateError,
      );
      store.discard = false;
      await settings.restoreOneShotCheckpoint(channel: null, oneShot: false);
      expect(await settings.readOneShotCheckpoint(channel: null), isFalse);
    });
    test('malformed stored values remain preserved', () async {
      store.values['track_one_shot.7'] = 'broken';
      await expectLater(
        settings.readOneShotCheckpoint(channel: 7),
        throwsA(isA<TypeError>()),
      );
      expect(store.values['track_one_shot.7'], 'broken');
    });
    test('invalid coordinates cannot create hidden keys', () async {
      await expectLater(
        settings.readOneShotCheckpoint(channel: 8),
        throwsArgumentError,
      );
      expect(store.values, isEmpty);
    });
  });
}
