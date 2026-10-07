import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/settings/view/about_settings_page.dart';
import 'package:segno/settings/view/settings_fact_panel.dart';
import 'package:segno/system/controller_facts.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';

/// Controller firmware: what the console board runs, and the plain statement
/// that this console cannot update it.
///
/// The page is the Unsupported state on purpose. Updating the board from the
/// app has not been established for this hardware, so there is no Update
/// button to press and fail; the board is brought onto the firmware an image
/// ships by the boot-time flasher, which is why the way forward is Software
/// updates.
class ControllerFirmwarePage extends StatelessWidget {
  /// Creates a [ControllerFirmwarePage].
  const ControllerFirmwarePage({super.key});

  /// The panel's width: the About page's column.
  static const double width = AboutSettingsPage.columnWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pedal = context.watch<PedalCubit>().state;
    final lastFlashed = context
        .watch<ConsoleFactsCubit>()
        .state
        .facts
        .lastFlashed;
    final facts = ControllerFacts.read(pedal: pedal, lastFlashed: lastFlashed);
    return Scaffold(
      body: LoopSettingsFrame(
        crumb: l10n.controllerFirmwareCrumb,
        title: l10n.controllerFirmwareTitle,
        titleLeft: 100,
        onBack: () => Navigator.maybePop(context),
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            left: AboutSettingsPage.columns[0],
            top: AboutSettingsPage.top,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsFactPanel(
                  key: const Key('controller_installed'),
                  title: l10n.controllerInstalledPanel,
                  width: width,
                  rows: [
                    SettingsFactRow(
                      key: const Key('controller_connection'),
                      label: l10n.aboutConnectionRow,
                      value: controllerConnection(l10n, pedal.status),
                    ),
                    ...controllerFactRows(l10n, facts),
                  ],
                ),
                if (!facts.updateSupported) ...[
                  const SizedBox(height: 32),
                  SizedBox(
                    width: width,
                    child: LoopNote(
                      l10n.controllerUpdateUnsupported,
                      key: const Key('controller_update_unsupported'),
                    ),
                  ),
                  const SizedBox(height: 32),
                  LoopOutlinedButton(
                    key: const Key('controller_software_updates'),
                    width: 320,
                    label: l10n.controllerSoftwareUpdates,
                    onTap: () => unawaited(showUpdateSettings()),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
