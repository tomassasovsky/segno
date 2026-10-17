import 'package:flutter/material.dart';
import 'package:segno/audio_setup/view/console/device_audio_tab.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';

/// The Device destination: the audio interface (with the click's level and
/// the way into Audio routing) and what recording keeps in memory.
///
/// Where the device-lost and engine-stopped notices send you: the chooser
/// that restarts the engine is on it.
class DeviceSettingsPage extends StatelessWidget {
  /// Creates a [DeviceSettingsPage].
  const DeviceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => SettingsDestinationPage(
    title: context.l10n.settingsDeviceTitle,
    body: const DeviceAudioTab(),
  );
}
