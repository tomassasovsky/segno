import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _Store extends Fake implements KeyValueStore {
  final values = <String, Object>{};
  final writes = <String>[];
  String? fail;
  bool discard = false;
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  Future<void> _write(String key, Object? value) async {
    writes.add(key);
    if (!discard) {
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
    }
    if (fail == key) {
      fail = null;
      throw StateError('after mutation');
    }
  }

  @override
  Future<void> setInt(String key, int value) => _write(key, value);
  @override
  Future<void> setBool(String key, {required bool value}) => _write(key, value);
  @override
  Future<void> remove(String key) => _write(key, null);
}

void main() {
  late _Store store;
  late SettingsRepository settings;
  setUp(() {
    store = _Store();
    settings = SettingsRepository(store: store);
  });
  const all = (
    quantize: true,
    division: 3,
    trackOverrides: {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 0},
  );
  final keys = [
    'looper.quantize',
    'tempo.quantize_div',
    for (var c = 0; c < 8; c++) 'track_record_timing.$c',
  ];
  for (final key in keys) {
    test('exact checkpoint compensates a mutating failure at $key', () async {
      store.values['unrelated'] = 'untouched';
      final before = await settings.readRecordTimingCheckpoint();
      store.fail = key;
      await expectLater(
        settings.restoreRecordTimingCheckpoint(all),
        throwsStateError,
      );
      await settings.restoreRecordTimingCheckpoint(before);
      expect(store.values, {'unrelated': 'untouched'});
      final restored = await settings.readRecordTimingCheckpoint();
      expect(restored.quantize, before.quantize);
      expect(restored.division, before.division);
      expect(restored.trackOverrides, before.trackOverrides);
    });
  }
  test(
    'unchanged tuple writes nothing and explicit zero remains a member',
    () async {
      await settings.restoreRecordTimingCheckpoint(all);
      store.writes.clear();
      final saved = await settings.readRecordTimingCheckpoint();
      await settings.restoreRecordTimingCheckpoint(saved);
      expect(store.writes, isEmpty);
      expect(saved.trackOverrides[0], 0);
      expect(saved.trackOverrides[7], 0);
      expect(() => saved.trackOverrides[0] = 3, throwsUnsupportedError);
    },
  );
  test(
    'every malformed scalar is preserved and rejects the full image',
    () async {
      for (final key in keys) {
        for (final bad in <Object>[
          'broken',
          if (key == 'looper.quantize') 1 else -1,
          if (key == 'tempo.quantize_div') 6 else 7,
        ]) {
          store.values
            ..clear()
            ..[key] = bad;
          await expectLater(
            settings.readRecordTimingCheckpoint(),
            throwsA(anything),
          );
          expect(store.values, {key: bad});
          expect(store.writes, isEmpty);
        }
      }
    },
  );
  test('discarded writes cannot produce confirmation', () async {
    store.discard = true;
    await expectLater(
      settings.restoreRecordTimingCheckpoint(all),
      throwsStateError,
    );
    expect(store.values, isEmpty);
  });
  test('out of range coordinates are rejected before writing any scalar', () {
    expect(
      () => settings.restoreRecordTimingCheckpoint((
        quantize: true,
        division: 3,
        trackOverrides: {8: 0},
      )),
      throwsFormatException,
    );
    expect(store.writes, isEmpty);
  });
}
