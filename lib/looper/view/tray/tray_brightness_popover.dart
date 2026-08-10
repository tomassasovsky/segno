import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/brightness_capsule.dart';
import 'package:segno/looper/view/tray/tray_navigation_rail.dart';
import 'package:segno/theme/theme.dart';

/// The brightness popover, from `SYSTEM / brightness`.
///
/// A popover and not a rail destination: brightness is not a domain to
/// configure, it is one control you reach for and let go of. Giving it a face
/// of its own would mean leaving whatever you were looking at to change the
/// backlight and then navigating back, which is the trade every other rail
/// entry is worth making and this one is not.
///
/// `c/brightness` calls it a "Control-Center capsule: the fill is the
/// control" — there is no separate handle, the lit part of the pill IS the
/// value, dragged directly.
class TrayBrightnessPopover extends StatelessWidget {
  /// Creates a [TrayBrightnessPopover].
  const TrayBrightnessPopover({required this.onDismiss, super.key});

  /// Closes the popover.
  final VoidCallback onDismiss;

  /// Popover size, from the pen's `R2Ml5m`.
  static const Size size = Size(119, 303);

  /// Capsule size inside it, from `FQgZF`.
  static const Size capsuleSize = Size(79, 235);

  static const double _radius = 22;
  static const double _pad = 20;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();

    return Stack(
      children: [
        // A real barrier, not a bare `GestureDetector`: that stopped POINTERS
        // and nothing else, so a screen reader could still activate a rail
        // item behind the popover and Tab walked straight out of it — states
        // no sighted pointer user can reach.
        // `BlockSemantics` as well as the barrier: the barrier stops
        // POINTERS, and on its own left a screen reader able to activate a
        // rail item behind the popover — a state no sighted user can reach.
        Positioned.fill(
          child: BlockSemantics(
            child: ModalBarrier(
              key: const Key('trayBrightness_scrim'),
              semanticsLabel: l10n.dismiss,
              onDismiss: onDismiss,
            ),
          ),
        ),
        Positioned(
          // Beside the rail and level with the entry that opened it, as the
          // pen places it — not centred on the screen, which would read as a
          // dialog about brightness rather than as the button's own drawer.
          left: TrayNavigationRail.width + 10,
          bottom: 44,
          child: FocusScope(
            child: Material(
              key: const Key('trayBrightness_popover'),
              color: surface.surface,
              elevation: 12,
              borderRadius: BorderRadius.circular(_radius),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Padding(
                  padding: const EdgeInsets.all(_pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Centred over the capsule, in the console's mono, at
                      // the pen's own size — `JFpjr` is `textAlign: center`
                      // across the full content width, SF Mono 14/1.14. It
                      // shipped left-aligned in the UI face at 13, which put
                      // a number that changes width as it counts (7% / 72% /
                      // 100%) hard against the capsule's left edge, shifting
                      // under the thumb that was dragging it.
                      Text(
                        l10n.trayBrightnessPercent(
                          (state.brightness * 100).round(),
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: SurfaceTheme.monoFont,
                          color: surface.textSecondary,
                          fontSize: 14,
                          height: 1.14,
                          leadingDistribution: TextLeadingDistribution.even,
                        ),
                      ),
                      const SizedBox(height: 12),
                      BrightnessCapsule(
                        key: const Key('settingsTray_brightness'),
                        value: state.brightness,
                        semanticLabel: l10n.trayBrightnessLabel,
                        onChanged: (value) =>
                            unawaited(cubit.setBrightness(value)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
