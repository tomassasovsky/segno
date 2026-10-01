import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';

/// Opens the shared MIDI setup page from the Control tray.
///
/// Device selection, Learn and mapping edits all belong to that page. The
/// tray provides an entry, rather than another editor for the same settings.
class ControllersTrayBody extends StatelessWidget {
  /// Creates a [ControllersTrayBody].
  const ControllersTrayBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return KeyedSubtree(
      key: const Key('controllers_tray_body'),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(top: 14),
        child: ConsoleCard(
          children: [
            ConsoleRow(
              key: const Key('midi_open_controls'),
              title: l10n.midiControlsTitle,
              subtitle: l10n.midiControlsEntryDetail,
              showDivider: false,
              onTap: () => unawaited(
                openMidiControls(
                  onStage: context.read<SettingsTrayCubit>().closeTray,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
