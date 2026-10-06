import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_tray_body.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The Network destination: the Wi-Fi radio, its networks and joining.
///
/// Owns its [WifiCubit] for as long as it is open. The body loads the radio's
/// state and scans when it mounts, so nothing is read while the page is shut.
class NetworkSettingsPage extends StatelessWidget {
  /// Creates a [NetworkSettingsPage].
  ///
  /// [repository] overrides the provided [WifiRepository], for tests.
  const NetworkSettingsPage({this.repository, super.key});

  /// Optional repository override.
  final WifiRepository? repository;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) =>
        WifiCubit(repository: repository ?? context.read<WifiRepository>()),
    child: SettingsDestinationPage(
      title: context.l10n.settingsNetworkTitle,
      body: const WifiTrayBody(),
    ),
  );
}
