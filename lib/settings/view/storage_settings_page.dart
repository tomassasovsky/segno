import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/system/view/storage_system_tab.dart';

/// The Storage destination: what is using the internal disk, and its
/// housekeeping.
///
/// Hosts [StorageSystemTab], whose body the USB storage service (#1177)
/// replaces with the accepted Storage page.
class StorageSettingsPage extends StatelessWidget {
  /// Creates a [StorageSettingsPage].
  const StorageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => SettingsDestinationPage(
    title: context.l10n.settingsStorageTitle,
    body: const StorageSystemTab(),
  );
}
