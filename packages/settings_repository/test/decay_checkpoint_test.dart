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
  group('Decay scalar checkpoint', () {
    late _Store store;
    late SettingsRepository settings;
    setUp(() {
      store = _Store();
      settings = SettingsRepository(store: store);
    });
    test(
      'absence and explicit zero restore exactly without touching siblings',
      () async {
        store.values['sentinel'] = 17;
        expect(await settings.readDecayCheckpoint(channel: null), isNull);
        await settings.saveOverdubDecay(0);
        expect(await settings.readDecayCheckpoint(channel: null), 0);
        await settings.saveTrackOverdubDecay(7, 0);
        expect(await settings.loadTrackOverdubDecay(7), 0);
        await settings.restoreDecayCheckpoint(channel: null, percent: null);
        await settings.saveTrackOverdubDecay(7, null);
        expect(store.values, {'sentinel': 17});
      },
    );
    test(
      'silent discarded write is refused and does not poison later writer',
      () async {
        store.discard = true;
        await expectLater(settings.saveOverdubDecay(40), throwsStateError);
        store.discard = false;
        await settings.saveOverdubDecay(60);
        expect(await settings.loadOverdubDecay(), 60);
      },
    );
    test(
      'malformed stored percent remains unchanged and readable as failure',
      () async {
        store.values['track_overdub_decay.7'] = 101;
        await expectLater(
          settings.loadTrackOverdubDecay(7),
          throwsFormatException,
        );
        expect(store.values['track_overdub_decay.7'], 101);
      },
    );
    test('invalid coordinates cannot create a hidden override key', () {
      expect(() => settings.saveTrackOverdubDecay(8, 40), throwsArgumentError);
      expect(store.values, isEmpty);
    });
    test('loads wait for prior writes and zero remains explicit', () async {
      final saved = settings.saveTrackOverdubDecay(0, 0);
      final read = settings.loadTrackOverdubDecay(0);
      await saved;
      expect(await read, 0);
      expect(store.values.containsKey('track_overdub_decay.0'), isTrue);
    });
  });
}
