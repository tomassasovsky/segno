import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/display_brightness_edit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/view/settings_destination_page.dart';
import 'package:segno/system/view/display_system_tab.dart';
import 'package:segno/theme/theme.dart';

/// The Displays destination: brightness first, then what the screens do.
///
/// One brightness for both panels, as the console has today; per-display
/// brightness and touch calibration arrive with the accepted Displays page.
class DisplaysSettingsPage extends StatelessWidget {
  /// Creates a [DisplaysSettingsPage].
  const DisplaysSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => SettingsDestinationPage(
    title: context.l10n.settingsDisplaysTitle,
    body: const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsoleCard(children: [DisplayBrightnessRow()]),
        Expanded(child: DisplaySystemTab()),
      ],
    ),
  );
}

/// The brightness slider: the Loop settings slider, so touch, the encoder's
/// draft grammar (Enter, turn, Enter; Back cancels) and a screen reader's
/// increase and decrease all adjust it.
///
/// The whole travel covers the brightness the console allows,
/// [kMinDisplayBrightness] to full: the left end is the dimmest readable
/// level rather than a stretch of dead travel below it. A double tap returns
/// to [kDefaultDisplayBrightness].
class DisplayBrightnessRow extends StatelessWidget {
  /// Creates a [DisplayBrightnessRow].
  const DisplayBrightnessRow({super.key});

  /// One encoder detent or arrow press: 5% of the travel.
  static const double step = 0.05;

  static const double _range = 1 - kMinDisplayBrightness;

  /// The slider position for [brightness].
  static double travelOf(double brightness) =>
      ((brightness - kMinDisplayBrightness) / _range).clamp(0.0, 1.0);

  /// The brightness at slider position [travel].
  static double brightnessAt(double travel) =>
      kMinDisplayBrightness + travel.clamp(0.0, 1.0) * _range;

  static const double _labelWidth = 160;
  static const double _readoutWidth = 94;
  static const double _gap = 18;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final brightness = context.watch<DisplayBrightnessCubit>().state;
    String percent(double travel) =>
        l10n.trayBrightnessPercent((brightnessAt(travel) * 100).round());
    void apply(double travel) =>
        editDisplayBrightness(context, brightnessAt(travel));
    return Padding(
      padding: const EdgeInsets.all(_gap),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: AppText(
              l10n.trayBrightnessLabel,
              style: TextStyle(color: surface.textPrimary, fontSize: 16),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => LoopSlider(
                key: const Key('displays_brightness'),
                width: constraints.maxWidth,
                value: travelOf(brightness),
                keyboardStep: step,
                semanticLabel: l10n.trayBrightnessLabel,
                semanticValueBuilder: percent,
                onChanged: apply,
                onEditCancel: apply,
                onDoubleTap: () => editDisplayBrightness(
                  context,
                  kDefaultDisplayBrightness,
                ),
              ),
            ),
          ),
          const SizedBox(width: _gap),
          SizedBox(
            width: _readoutWidth,
            child: AppText(
              percent(travelOf(brightness)),
              key: const Key('displays_brightness_readout'),
              textAlign: TextAlign.right,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 14,
                fontFamily: SurfaceTheme.monoFont,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
