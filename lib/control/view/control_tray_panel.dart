import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/view/pedal_tray_body.dart';
import 'package:segno/l10n/l10n.dart';

/// The Control domain: the footswitch plate, and the ways to Pedal setup and
/// to MIDI controls.
///
/// One body and no tab strip. MIDI mappings are edited on the MIDI controls
/// page, which the body's row opens, so there is nothing here to choose
/// between.
class ControlTrayPanel extends StatelessWidget {
  /// Creates a [ControlTrayPanel].
  const ControlTrayPanel({super.key});

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const Key('control_tray_panel'),
    child: ConsoleDomainPanel<void>(
      title: context.l10n.trayControlLabel,
      tabs: const [],
      selected: null,
      onChanged: (_) {},
      body: const PedalTrayBody(),
    ),
  );
}
