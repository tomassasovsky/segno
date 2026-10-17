import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/settings/view/settings_fact_panel.dart';
import 'package:segno/system/controller_facts.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/system/view/console_licences_sheet.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// About Segno: what this console is, its controller, and the open-source
/// notices — three panels of facts the console actually read.
///
/// **A fact this build did not read is left out, not drawn as a dash.** A
/// desktop is not a console, and a serial number that is not there is not a
/// serial number that is blank. The controller is the exception that proves
/// it: its rows always show, because a board that says nothing is the case
/// someone opens this page to see, and "Not reported" is then the fact.
///
/// Opened from the Updates page; leads to the Controller firmware page.
class AboutSettingsPage extends StatefulWidget {
  /// Creates an [AboutSettingsPage].
  const AboutSettingsPage({super.key});

  /// The two columns' left edges in the frame's main area: the pen's 100 px
  /// page margin, then a 24 px gutter.
  static const List<double> columns = [100, 972];

  /// Each column's width.
  static const double columnWidth = 848;

  /// The columns' top in the frame's main area, under the title row.
  static const double top = 120;

  @override
  State<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends State<AboutSettingsPage> {
  /// The one walk of the licence registry this page makes, counted for the
  /// notices row and handed to the notices panel when it opens:
  /// `LicenseRegistry.licenses` re-parses the whole NOTICES asset on every
  /// access.
  late final Future<List<ConsoleLicencePackage>> _licences;

  /// How many packages the registry carries, or null until the walk ends.
  int? _packages;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<ConsoleFactsCubit>().load());
    _licences = readConsoleLicencePackages();
    unawaited(_countPackages());
  }

  Future<void> _countPackages() async {
    final packages = await _licences;
    if (mounted) setState(() => _packages = packages.length);
  }

  Future<void> _rename(String current) async {
    final l10n = context.l10n;
    final cubit = context.read<ConsoleFactsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.aboutRenameTitle,
      subtitle: l10n.aboutNameRow,
      current: current,
      fieldLabel: l10n.aboutNameRow,
      // An empty name hands the console back the name it shipped with.
      allowEmpty: true,
    );
    if (name == null) return;
    await cubit.rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = context.watch<ConsoleFactsCubit>().state;
    final version = context.watch<UpdateCubit>().state.currentVersion;
    final pedal = context.watch<PedalCubit>().state;
    final engine = context.watch<AudioSetupCubit>().state.engineStatus;
    final controller = ControllerFacts.read(
      pedal: pedal,
      lastFlashed: facts.facts.lastFlashed,
    );
    final packages = _packages;

    final thisConsole = SettingsFactPanel(
      key: const Key('about_this_console'),
      title: l10n.aboutThisConsolePanel,
      width: AboutSettingsPage.columnWidth,
      rows: [
        // A name hangs off the serial, so a build that read none has nothing
        // to rename and no name of its own to show.
        if (facts.facts.serial.isNotEmpty)
          SettingsFactRow(
            key: const Key('about_name'),
            label: l10n.aboutNameRow,
            value: facts.consoleName.isEmpty
                ? l10n.aboutDefaultName
                : facts.consoleName,
            trailing: LoopOutlinedButton(
              key: const Key('about_rename'),
              width: 160,
              height: 56,
              label: l10n.aboutRename,
              onTap: () => unawaited(_rename(facts.consoleName)),
            ),
          ),
        if (version != null)
          SettingsFactRow(
            key: const Key('about_version'),
            label: l10n.aboutSegnoVersionRow,
            value: '$version',
          ),
        if (facts.facts.systemImage.isNotEmpty)
          SettingsFactRow(
            key: const Key('about_image'),
            label: l10n.aboutSystemImageRow,
            value: facts.facts.systemImage,
          ),
        if (facts.facts.serial.isNotEmpty)
          SettingsFactRow(
            key: const Key('about_serial'),
            label: l10n.aboutSerialRow,
            value: facts.facts.serial,
          ),
        // Off the engine's own report: what the interface is running at, not
        // what was asked for.
        if (engine.isConnected && engine.deviceName.isNotEmpty)
          SettingsFactRow(
            key: const Key('about_interface'),
            label: l10n.aboutAudioInterfaceRow,
            value: engine.deviceName,
            caption: engine.sampleRate > 0
                ? l10n.aboutAudioInterfaceSubtitle(
                    engine.sampleRate / 1000,
                    engine.bufferFrames,
                  )
                : null,
          ),
        if (facts.facts.panels.isNotEmpty)
          SettingsFactRow(
            key: const Key('about_displays'),
            label: l10n.aboutDisplaysRow,
            value: facts.facts.panels.join('\n'),
          ),
      ],
    );

    return Scaffold(
      body: LoopSettingsFrame(
        crumb: l10n.settingsCrumb(l10n.settingsAboutTitle),
        title: l10n.settingsAboutTitle,
        titleLeft: 100,
        onBack: () => Navigator.maybePop(context),
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            left: AboutSettingsPage.columns[0],
            top: AboutSettingsPage.top,
            child: thisConsole,
          ),
          Positioned(
            left: AboutSettingsPage.columns[1],
            top: AboutSettingsPage.top,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsFactPanel(
                  key: const Key('about_controller'),
                  title: l10n.aboutControllerPanel,
                  width: AboutSettingsPage.columnWidth,
                  rows: [
                    SettingsFactRow(
                      key: const Key('about_controller_connection'),
                      label: l10n.aboutConnectionRow,
                      value: controllerConnection(l10n, pedal.status),
                    ),
                    ...controllerFactRows(l10n, controller),
                    SettingsFactRow(
                      key: const Key('about_controller_firmware_row'),
                      label: l10n.aboutControllerFirmwareRow,
                      onTap: () => unawaited(openControllerFirmware()),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SettingsFactPanel(
                  key: const Key('about_licenses'),
                  title: l10n.aboutLicensesPanel,
                  width: AboutSettingsPage.columnWidth,
                  rows: [
                    SettingsFactRow(
                      key: const Key('about_notices'),
                      label: l10n.aboutNoticesRow,
                      // Null until the walk finishes, and null if it found
                      // nothing: "0 components" is a figure no one measured.
                      value: (packages ?? 0) == 0
                          ? null
                          : l10n.aboutNoticesCount(packages!),
                      onTap: () => unawaited(
                        showConsoleLicences(context, packages: _licences),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Connection row's value for the console board's link [status].
String controllerConnection(AppLocalizations l10n, PedalLinkStatus status) =>
    switch (status) {
      PedalLinkStatus.connected => l10n.aboutConnectionConnected,
      PedalLinkStatus.disconnected => l10n.aboutConnectionDisconnected,
      PedalLinkStatus.incompatible => l10n.aboutConnectionIncompatible,
    };

/// The Firmware and Wire protocol rows for [facts], shared by About and the
/// Controller firmware page: the values, and under the firmware where they
/// came from when that was not the board itself.
List<Widget> controllerFactRows(
  AppLocalizations l10n,
  ControllerFacts facts,
) => [
  SettingsFactRow(
    key: const Key('controller_firmware'),
    label: l10n.aboutFirmwareRow,
    value: facts.firmware ?? l10n.aboutNotReported,
    caption: switch (facts.source) {
      ControllerFactsSource.reported => null,
      ControllerFactsSource.lastFlashed => l10n.aboutLastFlashedCaption,
      ControllerFactsSource.notReported => l10n.aboutNotReportedCaption,
    },
  ),
  SettingsFactRow(
    key: const Key('controller_protocol'),
    label: l10n.aboutWireProtocolRow,
    value: facts.protocol?.toString() ?? l10n.aboutNotReported,
  ),
];
