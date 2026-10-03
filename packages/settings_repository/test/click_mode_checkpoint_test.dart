import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _Store extends Fake implements KeyValueStore {
  final values = <String, Object>{};
  bool drop = false;
  bool fail = false;
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<void> setInt(String key, int value) async {
    if (!drop) values[key] = value;
    if (fail) {
      fail = false;
      throw StateError('mutated');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (!drop) values.remove(key);
  }
}

void main() {
  test(
    'absence and explicit Off remain distinct across exact compensation',
    () async {
      final store = _Store();
      final settings = SettingsRepository(store: store);
      expect(await settings.readClickModeCheckpoint(), isNull);
      for (final prior in <int?>[null, 0, 1, 2, 3]) {
        await settings.restoreClickModeCheckpoint(prior);
        final checkpoint = await settings.readClickModeCheckpoint();
        store.fail = true;
        await expectLater(
          settings.restoreClickModeCheckpoint(3),
          throwsStateError,
        );
        await settings.restoreClickModeCheckpoint(checkpoint);
        expect(store.values.containsKey('tempo.click_mode'), prior != null);
        expect(store.values['tempo.click_mode'], prior);
      }
    },
  );
  test('malformed scalar is preserved until deliberately replaced', () async {
    final store = _Store();
    final settings = SettingsRepository(store: store);
    for (final bad in <Object>[-1, 4, '2', true, 1.5]) {
      store.values['tempo.click_mode'] = bad;
      await expectLater(settings.readClickModeCheckpoint(), throwsA(anything));
      expect(store.values['tempo.click_mode'], bad);
    }
    await settings.restoreClickModeCheckpoint(0);
    expect(await settings.readClickModeCheckpoint(), 0);
  });
  test(
    'silent loss of writes and removals is rejected by exact readback',
    () async {
      final store = _Store();
      final settings = SettingsRepository(store: store);
      store.drop = true;
      await expectLater(
        settings.restoreClickModeCheckpoint(0),
        throwsStateError,
      );
      store.values['tempo.click_mode'] = 2;
      await expectLater(
        settings.restoreClickModeCheckpoint(null),
        throwsStateError,
      );
      expect(store.values['tempo.click_mode'], 2);
    },
  );
}
