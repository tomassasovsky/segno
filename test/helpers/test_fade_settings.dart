import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import 'fake_audio_engine.dart';
import 'fake_key_value_store.dart';

/// A Fade duration owner over its own fake store. Unloaded by default, so
/// Fade gestures refuse until a test calls `load()`. Without a [repository],
/// it follows a stopped repository of its own.
FadeSettings testFadeSettings({
  SettingsRepository? settings,
  LooperRepository? repository,
}) => FadeSettings(
  repository:
      repository ??
      LooperRepository(engine: FakeAudioEngine(), ticker: const Stream.empty()),
  settings: settings ?? SettingsRepository(store: FakeKeyValueStore()),
  blocked: () => false,
  sessionBlocked: () => false,
);
