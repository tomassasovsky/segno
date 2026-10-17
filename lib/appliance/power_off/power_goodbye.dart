import 'package:flutter/material.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// Plymouth field behind the Saving face and the terminal faces.
const Color kPowerGoodbyeFill = Color(0xFF08080A);

/// Bundled lockup — the same PNG Plymouth uses at boot.
const String kPowerLockupAsset = 'assets/brand/segno-lockup.png';

/// [PerformanceReadout.goodbye] for a power phase: what the Track display
/// mirrors.
ReadoutGoodbye readoutGoodbyeOf(PowerPhase phase) => switch (phase) {
  PowerPhase.saving => ReadoutGoodbye.saving,
  PowerPhase.goodbye => ReadoutGoodbye.mark,
  PowerPhase.idle ||
  PowerPhase.refuse ||
  PowerPhase.options ||
  PowerPhase.saveAs ||
  PowerPhase.saveFailed => ReadoutGoodbye.none,
};

/// Full-screen Saving… / terminal overlay. Non-interactive.
///
/// With an [action] (the main display) the terminal face is pen 32's
/// centered icon and text: "Safe to switch off" or "Restarting". Without one
/// (the Track display, which only mirrors [ReadoutGoodbye]) it is the lockup.
class PowerGoodbye extends StatelessWidget {
  /// Creates a [PowerGoodbye] for [face].
  const PowerGoodbye({required this.face, this.action, super.key});

  /// Which committed face to draw. [ReadoutGoodbye.none] draws nothing.
  final ReadoutGoodbye face;

  /// The committed action, which names the terminal face.
  final PowerAction? action;

  @override
  Widget build(BuildContext context) {
    if (face == ReadoutGoodbye.none) return const SizedBox.shrink();
    final l10n = context.l10n;
    final surface = context.surface;
    final style = TextStyle(
      color: surface.textPrimary,
      fontSize: 28,
      fontWeight: FontWeight.w600,
      height: 1.2,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final Widget content;
    if (face == ReadoutGoodbye.saving) {
      content = AppText(
        key: const Key('power_saving'),
        l10n.powerSaving,
        style: style,
      );
    } else if (action case final action?) {
      final restart = action == PowerAction.restart;
      content = Column(
        key: Key(restart ? 'power_restarting' : 'power_safe_to_switch_off'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            restart ? Icons.restart_alt : Icons.power_settings_new,
            size: 48,
            color: surface.textSecondary,
          ),
          const SizedBox(height: 19),
          AppText(
            restart ? l10n.powerRestarting : l10n.powerSafeToSwitchOff,
            style: style,
          ),
        ],
      );
    } else {
      content = Image.asset(
        kPowerLockupAsset,
        key: const Key('power_mark'),
        semanticLabel: l10n.a11yPowerMark,
        filterQuality: FilterQuality.high,
      );
    }
    return AbsorbPointer(
      child: ColoredBox(
        key: const Key('power_goodbye'),
        color: kPowerGoodbyeFill,
        child: Center(child: content),
      ),
    );
  }
}
