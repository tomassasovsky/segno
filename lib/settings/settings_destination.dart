import 'package:segno/app/segno_navigator.dart';
import 'package:segno/l10n/l10n.dart';

/// The ten places Settings leads, in the order the Settings page draws them
/// (pen `05 Loop setup / 01 Settings`): the musical setup on the first row,
/// the appliance on the second.
enum SettingsDestination {
  /// Effects.
  effects('effects'),

  /// Loop settings.
  loop('loop'),

  /// Pedals setup.
  pedals('pedals'),

  /// MIDI controls.
  midi('midi'),

  /// Audio routing.
  routing('routing'),

  /// The audio interface.
  device('device'),

  /// Wi-Fi.
  network('network'),

  /// The two screens.
  displays('displays'),

  /// Internal storage.
  storage('storage'),

  /// Software updates.
  updates('updates');

  const SettingsDestination(this.key);

  /// The name of this destination's artwork, and its tile's key suffix.
  final String key;

  /// The tile's artwork: the owner's Segno menu picture for this place.
  String get artAsset => 'assets/settings/$key.png';

  /// The tile's name.
  String label(AppLocalizations l10n) => switch (this) {
    SettingsDestination.effects => l10n.fxTitle,
    SettingsDestination.loop => l10n.loopSettingsTitle,
    SettingsDestination.pedals => l10n.pedalSetupTitle,
    SettingsDestination.midi => l10n.settingsMidiTitle,
    SettingsDestination.routing => l10n.routingTitle,
    SettingsDestination.device => l10n.settingsDeviceTitle,
    SettingsDestination.network => l10n.settingsNetworkTitle,
    SettingsDestination.displays => l10n.settingsDisplaysTitle,
    SettingsDestination.storage => l10n.settingsStorageTitle,
    SettingsDestination.updates => l10n.settingsUpdatesTitle,
  };

  /// Opens this destination's page over Settings.
  Future<void> open() => switch (this) {
    SettingsDestination.effects => openFx(),
    SettingsDestination.loop => openLoopSettings(),
    SettingsDestination.pedals => openPedalSetup(),
    SettingsDestination.midi => openMidiControls(),
    SettingsDestination.routing => openAudioRouting(),
    SettingsDestination.device => openDeviceSettings(),
    SettingsDestination.network => openNetworkSettings(),
    SettingsDestination.displays => openDisplaySettings(),
    SettingsDestination.storage => openStorageSettings(),
    SettingsDestination.updates => openUpdateSettings(),
  };
}
