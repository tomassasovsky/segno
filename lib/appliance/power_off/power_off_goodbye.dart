import 'package:flutter/material.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// Plymouth field behind the goodbye lockup / Saving face.
const Color kPowerOffGoodbyeFill = Color(0xFF08080A);

/// Bundled lockup — the same PNG Plymouth uses at boot.
const String kPowerOffLockupAsset = 'assets/brand/segno-lockup.png';

/// [PerformanceReadout.goodbye] for a power-off phase.
ReadoutGoodbye readoutGoodbyeOf(PowerOffPhase phase) => switch (phase) {
  PowerOffPhase.saving => ReadoutGoodbye.saving,
  PowerOffPhase.goodbye => ReadoutGoodbye.mark,
  PowerOffPhase.idle ||
  PowerOffPhase.refuse ||
  PowerOffPhase.confirm ||
  PowerOffPhase.saveAs ||
  PowerOffPhase.saveFailed => ReadoutGoodbye.none,
};

/// Full-screen Saving… / mark overlay. Non-interactive.
class PowerOffGoodbye extends StatelessWidget {
  /// Creates a [PowerOffGoodbye] for [face].
  const PowerOffGoodbye({required this.face, super.key});

  /// Which committed face to draw. [ReadoutGoodbye.none] draws nothing.
  final ReadoutGoodbye face;

  @override
  Widget build(BuildContext context) {
    if (face == ReadoutGoodbye.none) return const SizedBox.shrink();
    final l10n = context.l10n;
    return AbsorbPointer(
      child: ColoredBox(
        key: const Key('power_off_goodbye'),
        color: kPowerOffGoodbyeFill,
        child: Center(
          child: face == ReadoutGoodbye.saving
              ? AppText(
                  key: const Key('power_off_saving'),
                  l10n.powerOffSaving,
                  style: TextStyle(
                    color: context.surface.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                )
              : Image.asset(
                  kPowerOffLockupAsset,
                  key: const Key('power_off_mark'),
                  semanticLabel: l10n.a11yPowerOffMark,
                  filterQuality: FilterQuality.high,
                ),
        ),
      ),
    );
  }
}
