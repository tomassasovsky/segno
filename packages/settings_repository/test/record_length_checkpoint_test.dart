import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _Store extends Fake implements KeyValueStore {
  final values = <String, Object>{};
  bool discard = false;
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<void> setInt(String key, int value) async {
    if (!discard) values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  group('Record length checkpoints', () {
    late _Store store;
    late SettingsRepository settings;
    setUp(() {
      store = _Store();
      settings = SettingsRepository(store: store);
    });
    test(
      'all slots preserve explicit Auto and exact absence without '
      'sibling writes',
      () async {
        store.values['unrelated'] = 13;
        for (var c = 0; c < 8; c++) {
          expect(await settings.readRecordLengthCheckpoint(channel: c), isNull);
          await settings.restoreRecordLengthCheckpoint(channel: c, bars: 0);
          expect(await settings.readRecordLengthCheckpoint(channel: c), 0);
          await settings.restoreRecordLengthCheckpoint(channel: c, bars: null);
        }
        await settings.restoreRecordLengthCheckpoint(channel: null, bars: 64);
        expect(await settings.readRecordLengthCheckpoint(channel: null), 64);
        await settings.restoreRecordLengthCheckpoint(channel: null, bars: null);
        expect(store.values, {'unrelated': 13});
      },
    );
    test('malformed type and out-of-range values remain untouched', () async {
      for (final bad in ['broken', -1, 65]) {
        store.values['tempo.length_preset.7'] = bad;
        await expectLater(
          settings.readRecordLengthCheckpoint(channel: 7),
          throwsA(anything),
        );
        expect(store.values['tempo.length_preset.7'], bad);
      }
    });
    test('discarded scalar and mode writes cannot report success', () async {
      store.discard = true;
      await expectLater(
        settings.restoreRecordLengthCheckpoint(channel: 0, bars: 8),
        throwsStateError,
      );
      await expectLater(
        settings.restoreLooperModeCheckpoint(4),
        throwsStateError,
      );
      store.discard = false;
      await settings.restoreLooperModeCheckpoint(0);
      expect(await settings.readLooperModeCheckpoint(), 0);
      await settings.restoreLooperModeCheckpoint(null);
      expect(await settings.readLooperModeCheckpoint(), isNull);
    });
    test('invalid mode and coordinate never create hidden keys', () async {
      expect(
        () => settings.restoreLooperModeCheckpoint(5),
        throwsArgumentError,
      );
      expect(
        () => settings.restoreRecordLengthCheckpoint(channel: 8, bars: 0),
        throwsArgumentError,
      );
      expect(
        () => settings.restoreRecordLengthCheckpoint(channel: 0, bars: 65),
        throwsArgumentError,
      );
      expect(store.values, isEmpty);
    });
  });
}
