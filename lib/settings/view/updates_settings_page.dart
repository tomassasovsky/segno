import 'dart:async';

import 'package:flutter/material.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/system/view/updates_system_tab.dart';

/// The Updates destination: the running build, the check, download and
/// restart flow, and the way to About.
///
/// About is a row here because the accepted behaviour keeps the version and
/// identity facts with Updates, and the ten Settings destinations have no
/// tile of their own for it.
class UpdatesSettingsPage extends StatelessWidget {
  /// Creates an [UpdatesSettingsPage].
  const UpdatesSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsDestinationPage(
      title: l10n.settingsUpdatesTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: UpdatesSystemTab()),
          ConsoleCard(
            children: [
              ConsoleRow(
                key: const Key('settings_about_row'),
                title: l10n.settingsAboutTitle,
                subtitle: l10n.settingsAboutSubtitle,
                showDivider: false,
                onTap: () => unawaited(openAboutSettings()),
              ),
            ],
          ),
          const SizedBox(height: kConsoleGroupGap),
        ],
      ),
    );
  }
}
