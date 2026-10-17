import 'package:flutter/material.dart';
import 'package:segno/control/view/fx_pedal_assignments_body.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';

/// The FX page's pedal assignments: what each footswitch acts on in FX mode,
/// per bank (pen `04 / 02 Pedal banks`, crumb `EFFECTS / PEDAL ASSIGNMENTS`).
///
/// The tray's binding editor in the shared settings frame until the pen's
/// Pedal banks redesign replaces the body.
class FxPedalAssignmentsPage extends StatelessWidget {
  /// Creates a [FxPedalAssignmentsPage].
  const FxPedalAssignmentsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsDestinationPage(
      title: l10n.fxPedalAssignmentsTitle,
      crumb: l10n.fxPedalAssignmentsCrumb,
      body: const FxPedalAssignmentsBody(),
    );
  }
}
