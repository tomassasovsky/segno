import 'package:segno/looper/application/fade_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import 'fake_key_value_store.dart';

/// A Fade duration owner over its own fake store. Unloaded by default, so
/// Fade gestures refuse until a test calls `load()`.
FadeSettings testFadeSettings({SettingsRepository? settings}) => FadeSettings(
  settings: settings ?? SettingsRepository(store: FakeKeyValueStore()),
  blocked: () => false,
  sessionBlocked: () => false,
);
