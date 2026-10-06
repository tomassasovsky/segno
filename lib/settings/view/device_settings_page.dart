import 'package:flutter/material.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/view/console/device_audio_tab.dart';
import 'package:segno/audio_setup/view/console/recording_audio_tab.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';

/// The Device destination: the audio interface (with the click's level and
/// the way into Audio routing) and what recording keeps in memory, as the
/// two tabs the tray's Audio face had.
///
/// Opens on Device every time: it is where the device-lost and engine-stopped
/// notices send you, and the chooser that restarts the engine is on it.
class DeviceSettingsPage extends StatefulWidget {
  /// Creates a [DeviceSettingsPage].
  const DeviceSettingsPage({super.key});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  AudioTab _tab = AudioTab.device;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsDestinationPage(
      title: l10n.settingsDeviceTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<AudioTab>(
              key: const Key('device_settings_tabs'),
              selected: _tab,
              onChanged: (tab) => setState(() => _tab = tab),
              tabs: [
                PillTab(value: AudioTab.device, label: l10n.audioDeviceTab),
                PillTab(
                  value: AudioTab.recording,
                  label: l10n.audioRecordingTab,
                ),
              ],
            ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: switch (_tab) {
                AudioTab.device => const DeviceAudioTab(),
                AudioTab.recording => const RecordingAudioTab(),
              },
            ),
          ),
        ],
      ),
    );
  }
}
