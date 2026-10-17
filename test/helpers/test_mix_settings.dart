import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:settings_repository/settings_repository.dart';

import 'fake_key_value_store.dart';

/// Gives a test owner the same coordinator path as the running app.
MixSettingsCoordinator testMixSettings(
  LooperRepository repository, {
  SettingsRepository? settings,
}) => MixSettingsCoordinator(
  repository: repository,
  persistence: SettingsMixPersistence(
    settings ?? SettingsRepository(store: FakeKeyValueStore()),
  ),
  device: () => repository.state.status.deviceName,
);

/// Seeds the canonical value at test seams without the removed per-field
/// settings writers.
extension MixSettingsTestSeeds on SettingsRepository {
  Future<void> seedLaneVolume(int channel, int lane, double volume) async {
    final saved = await loadMixSettings('test');
    await replaceMixSettings(
      device: 'test',
      mix: (
        trackLevels: saved.trackLevels,
        trackPans: saved.trackPans,
        laneLevels: {...saved.laneLevels, (channel, lane): volume},
        monitorLevels: saved.monitorLevels,
        laneInputs: saved.laneInputs,
        laneOutputs: saved.laneOutputs,
        laneCounts: saved.laneCounts,
        inputSetup: saved.inputSetup,
        outputSetup: saved.outputSetup,
      ),
    );
  }

  Future<void> seedTrackPan(int channel, double pan) async {
    final saved = await loadMixSettings('test');
    await replaceMixSettings(
      device: 'test',
      mix: (
        trackLevels: saved.trackLevels,
        trackPans: {...saved.trackPans, channel: pan},
        laneLevels: saved.laneLevels,
        monitorLevels: saved.monitorLevels,
        laneInputs: saved.laneInputs,
        laneOutputs: saved.laneOutputs,
        laneCounts: saved.laneCounts,
        inputSetup: saved.inputSetup,
        outputSetup: saved.outputSetup,
      ),
    );
  }

  Future<void> seedInputSetup(String device, StoredInputSetup setup) async {
    final saved = await loadMixSettings(device);
    await replaceMixSettings(
      device: device,
      mix: (
        trackLevels: saved.trackLevels,
        trackPans: saved.trackPans,
        laneLevels: saved.laneLevels,
        monitorLevels: saved.monitorLevels,
        laneInputs: saved.laneInputs,
        laneOutputs: saved.laneOutputs,
        laneCounts: saved.laneCounts,
        inputSetup: setup,
        outputSetup: saved.outputSetup,
      ),
    );
  }

  Future<void> seedInputPair(String device, int input, double balance) async {
    final saved = await loadMixSettings(device);
    await seedInputSetup(device, (
      trimDb: saved.inputSetup.trimDb,
      pan: saved.inputSetup.pan,
      pairs: {...saved.inputSetup.pairs, input: balance},
    ));
  }
}
