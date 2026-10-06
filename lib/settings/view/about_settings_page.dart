import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/system/view/about_system_tab.dart';

/// What this console is: its name, versions, controller and licences.
/// Opened from the Updates page.
class AboutSettingsPage extends StatelessWidget {
  /// Creates an [AboutSettingsPage].
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => SettingsDestinationPage(
    title: context.l10n.settingsAboutTitle,
    body: const AboutSystemTab(),
  );
}
