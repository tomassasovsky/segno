import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/display_brightness_edit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/system/view/display_system_tab.dart';

/// The Displays destination: brightness first, then what the screens do.
///
/// One brightness for both panels, as the console has today; per-display
/// brightness and touch calibration arrive with the accepted Displays page.
class DisplaysSettingsPage extends StatelessWidget {
  /// Creates a [DisplaysSettingsPage].
  const DisplaysSettingsPage({super.key});

  /// What the brightness bar is inset by inside its card.
  static const EdgeInsets _barInset = EdgeInsets.all(18);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final brightness = context.watch<DisplayBrightnessCubit>().state;
    return SettingsDestinationPage(
      title: l10n.settingsDisplaysTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsoleCard(
            children: [
              Padding(
                padding: _barInset,
                // The bar's whole travel is 0..1; below the floor the cubit
                // clamps, so the left end reads the dimmest the console
                // allows rather than a black screen nobody could read to undo.
                child: ConsoleValueBar(
                  key: const Key('displays_brightness'),
                  label: l10n.trayBrightnessLabel,
                  value: brightness,
                  resetValue: kDefaultDisplayBrightness,
                  readout: l10n.trayBrightnessPercent(
                    (brightness * 100).round(),
                  ),
                  onChanged: (value) => editDisplayBrightness(context, value),
                ),
              ),
            ],
          ),
          const Expanded(child: DisplaySystemTab()),
        ],
      ),
    );
  }
}
