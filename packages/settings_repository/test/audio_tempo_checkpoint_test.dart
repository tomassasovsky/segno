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
  group('Follow tempo and Pitch checkpoints (#1179)', () {
    late _Store store;
    late SettingsRepository settings;
    setUp(() {
      store = _Store();
      settings = SettingsRepository(store: store);
    });

    test('each address round-trips exactly, under its own key', () async {
      store.values['sentinel'] = 17;
      expect(await settings.readFollowTempoCheckpoint(channel: null), isNull);
      await settings.restoreFollowTempoCheckpoint(channel: null, follow: false);
      await settings.restoreFollowTempoCheckpoint(channel: 3, follow: true);
      await settings.restorePitchFollowsSpeedCheckpoint(
        channel: null,
        followsSpeed: true,
      );
      await settings.restorePitchFollowsSpeedCheckpoint(
        channel: 7,
        followsSpeed: false,
      );
      expect(store.values, {
        'sentinel': 17,
        'looper.default_follow_tempo': false,
        'track_follow_tempo.3': true,
        'looper.default_pitch_follows_speed': true,
        'track_pitch_follows_speed.7': false,
      });
      expect(await settings.readFollowTempoCheckpoint(channel: 3), isTrue);
      expect(
        await settings.readPitchFollowsSpeedCheckpoint(channel: 7),
        isFalse,
      );
      await settings.restoreFollowTempoCheckpoint(channel: 3, follow: null);
      await settings.restorePitchFollowsSpeedCheckpoint(
        channel: 7,
        followsSpeed: null,
      );
      expect(await settings.readFollowTempoCheckpoint(channel: 3), isNull);
      expect(store.values.containsKey('track_pitch_follows_speed.7'), isFalse);
    });

    test('a discarded write refuses; bad coordinates write nothing', () async {
      store.discard = true;
      await expectLater(
        settings.restoreFollowTempoCheckpoint(channel: null, follow: true),
        throwsStateError,
      );
      store.discard = false;
      await expectLater(
        settings.readPitchFollowsSpeedCheckpoint(channel: 8),
        throwsArgumentError,
      );
      expect(
        () => settings.restoreFollowTempoCheckpoint(channel: -1, follow: true),
        throwsArgumentError,
      );
      expect(store.values, isEmpty);
    });
  });
}
