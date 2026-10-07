/// Persists Segno settings (per-device latency calibration, audio config, UI).
library;

export 'package:local_storage_client/local_storage_client.dart'
    show KeyValueStore, SharedPreferencesKeyValueStore;

// AudioBackend is a settings-layer domain enum (no longer the engine's), part
// of StoredAudioConfig's public API.
export 'src/display_role.dart';
export 'src/fade_durations.dart';
export 'src/settings_repository.dart'
    show
        AudioBackend,
        MidiSettingsSaveException,
        PedalSetupSaveException,
        RecordTimingCheckpoint,
        SettingsRepository,
        StoredAudioConfig,
        StoredInputSetup,
        StoredMixSettings,
        StoredOutputSetup;
