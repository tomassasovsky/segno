import 'package:flutter/material.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The two ends of a travel being taught, and what they add up to.
///
/// A draft of a draft: the captures here are staged until Use calibration puts
/// them in the page's draft, which Save then commits. Backing out of this view
/// leaves the saved travel alone — a half-taught pedal must never replace a
/// working one.
class ExpressionCalibrationPanel extends StatelessWidget {
  /// Creates an [ExpressionCalibrationPanel].
  const ExpressionCalibrationPanel({
    required this.heel,
    required this.toe,
    required this.connected,
    required this.onCapture,
    required this.onCancel,
    required this.onUse,
    super.key,
  });

  /// The raw reading captured with the heel down, or `null` until it has been.
  final double? heel;

  /// The same for the toe.
  final double? toe;

  /// Whether the jack has reported a position at all. Nothing can be captured
  /// when it has not: the capture IS the reading.
  final bool connected;

  /// Captures the current reading as an end. `true` is the heel.
  final void Function({required bool isHeel}) onCapture;

  /// Leaves without changing the travel.
  final VoidCallback onCancel;

  /// Stages the captured travel into the page's draft.
  final ValueChanged<ExpressionCalibration> onUse;

  /// The pen's column width and card geometry.
  static const double penWidth = 1290;
  static const double _cardWidth = 631;
  static const double _cardHeight = 273;

  /// The travel the two captures describe, or `null` while one is missing.
  ExpressionCalibration? get captured {
    final start = heel;
    final end = toe;
    if (start == null || end == null) return null;
    return ExpressionCalibration(heel: start, toe: end);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final travel = captured;
    // Both captured but too close together is its own message: the foot did
    // move, it just did not move far enough, and "move to each end" would read
    // as though nothing had been done.
    final hint = travel != null && !travel.isUsable
        ? l10n.expressionCalibrateSpanHint
        : l10n.expressionCalibrateHint;
    return SizedBox(
      width: penWidth,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            l10n.expressionTeachTravel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 32,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 38),
          Row(
            children: [
              _end(context, isHeel: true),
              const SizedBox(width: 28),
              _end(context, isHeel: false),
            ],
          ),
          const SizedBox(height: 38),
          SizedBox(
            height: 33,
            child: AppText(
              hint,
              key: const Key('expression_calibrate_hint'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 23,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(height: 37),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              LoopOutlinedButton(
                key: const Key('expression_calibrate_cancel'),
                width: 125,
                label: l10n.pedalSetupCancel,
                onTap: onCancel,
              ),
              const SizedBox(width: 18),
              LoopOutlinedButton(
                key: const Key('expression_calibrate_use'),
                width: 223,
                tone: LoopButtonTone.accent,
                label: l10n.expressionUseCalibration,
                // A travel too short to divide by is refused here rather than
                // stored and ignored later: the one place a performer can see
                // why is the panel they are standing at.
                onTap: travel != null && travel.isUsable
                    ? () => onUse(travel)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _end(BuildContext context, {required bool isHeel}) {
    final l10n = context.l10n;
    final surface = context.surface;
    final value = isHeel ? heel : toe;
    final done = value != null;
    final end = isHeel ? l10n.expressionHeel : l10n.expressionToe;
    return SizedBox(
      width: _cardWidth,
      height: _cardHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: done ? surface.accentSurface : surface.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: done ? surface.accent : surface.borderSubtle,
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 31),
            AppText(
              isHeel ? '1' : '2',
              style: TextStyle(
                color: surface.textTertiary,
                fontSize: 56,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 24),
            AppText(
              isHeel ? l10n.expressionHeelDown : l10n.expressionToeDown,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 30,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 24),
            LoopOutlinedButton(
              key: Key('expression_capture_${isHeel ? 'heel' : 'toe'}'),
              width: 139,
              label: done
                  ? l10n.expressionSetAgain
                  : l10n.expressionSetEnd(end.toLowerCase()),
              onTap: connected ? () => onCapture(isHeel: isHeel) : null,
            ),
          ],
        ),
      ),
    );
  }
}
