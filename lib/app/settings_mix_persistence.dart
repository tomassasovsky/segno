import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:settings_repository/settings_repository.dart';

/// Persists a coordinator candidate as one appliance-wide settings value.
class SettingsMixPersistence implements MixSettingsPersistence {
  /// Uses the existing settings store; no second persistence owner is needed.
  const SettingsMixPersistence(this.settings);

  /// The settings repository carrying the canonical mix value.
  final SettingsRepository settings;

  @override
  Future<String?> read(String device) => settings.readMixSettingsCheckpoint();

  @override
  Future<void> write(String device, MixSettingsSnapshot candidate) =>
      settings.replaceMixSettings(
        device: device,
        mix: (
          trackPans: candidate.trackPans,
          laneLevels: candidate.laneLevels,
          monitorLevels: candidate.monitorLevels,
          inputSetup: device.isEmpty
              ? (trimDb: const {}, pan: const {}, pairs: const {})
              : (
                  trimDb: candidate.inputSetup.trimDb,
                  pan: candidate.inputSetup.pan,
                  pairs: candidate.inputSetup.pairs,
                ),
          outputSetup: device.isEmpty
              ? (
                  level: const {},
                  muted: const {},
                  mono: const {},
                  balance: const {},
                )
              : candidate.outputSetup.toMaps(),
        ),
      );

  @override
  Future<void> restore(String device, String? checkpoint) =>
      settings.restoreMixSettingsCheckpoint(checkpoint);
}
