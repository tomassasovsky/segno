# settings_repository

Repository that stores Segno's persistent settings in a key-value store
(`KeyValueStore` from `local_storage_client`, backed by `shared_preferences`).
It covers the audio device configuration, latency calibration per device
profile, monitor and input conditioning settings, tempo and recording choices,
pedal setup and bindings, MIDI configuration, display settings, and one-time
notices. The app's cubits and `midi_device_repository` read and write through
it.

## Usage

```dart
import 'package:settings_repository/settings_repository.dart';

final settings = SettingsRepository(
  store: SharedPreferencesKeyValueStore(),
  alsaPeriods: SettingsRepository.alsaPeriodsFromEnvironment(
    Platform.environment['SEGNO_ALSA_PERIODS'],
  ),
);

final config = await settings.loadAudioConfig(); // null on a first run
await settings.saveAudioConfig(
  const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
);

final offset = await settings.loadLatencyOffsetFrames(
  device: 'Scarlett 4i4',
  sampleRate: 48000,
  bufferFrames: 128,
);
```

## Notes

- Most values are a `load…`/`save…` pair. Some families are stored as opaque
  strings whose shape belongs to another layer (pedal setup, pedal bindings,
  instruments, MIDI configuration); this package does not parse them.
- `read…Checkpoint` and `restore…Checkpoint` methods return and restore the
  exact stored record, or its absence. Writes that use them are serialized and
  read back to confirm they landed; a failed pedal setup or MIDI save restores
  the previous value and throws `PedalSetupSaveException` or
  `MidiSettingsSaveException`.
- `alsaPeriods` is the ALSA period count the engine runs with, or `null` when
  `SEGNO_ALSA_PERIODS` is not set. Latency offsets are stored per period count
  and migrated from the older key once.
- `AudioBackend` and `DisplayRole` are settings-layer enums. The app maps
  `AudioBackend` to and from the engine's own enum.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
