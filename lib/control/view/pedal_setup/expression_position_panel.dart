import 'package:flutter/material.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Where the pedal is, beside a picture of one.
///
/// The picture is the same generated, unbranded artwork the switch screens use:
/// it depicts a category of pedal, not a product and not the Segno faceplate.
///
/// Two different things are drawn here, which is the point of the pair. The
/// METER shows the raw reading whether or not the pedal has been calibrated, so
/// a performer can see the jack is alive. The NUMBER shows the position in the
/// taught travel, and shows nothing at all until there is a travel to measure
/// against — a percentage of an unknown range would be a number that means
/// nothing.
class ExpressionPositionPanel extends StatelessWidget {
  /// Creates an [ExpressionPositionPanel].
  const ExpressionPositionPanel({
    required this.raw,
    required this.calibration,
    required this.height,
    this.onCalibrate,
    super.key,
  });

  /// The jack's last raw reading, or `null` if it has reported none.
  final double? raw;

  /// The travel this pedal was taught, or `null` until it has been.
  final ExpressionCalibration? calibration;

  /// The column's height — the workspace is taller in the calibrate view.
  final double height;

  /// Opens the calibrate view. `null` draws no button, which is what the
  /// calibrate view itself wants.
  final VoidCallback? onCalibrate;

  /// The pen's column width, and the box the artwork is fitted into.
  static const double penWidth = 340;
  static const Size _visual = Size(308, 320);
  static const double _inset = 16;

  /// The pen's bundled picture of an expression pedal.
  static const String asset = 'assets/hardware/external_expression.webp';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final travel = calibration;
    final reading = raw;
    final position = reading == null ? null : travel?.positionOf(reading);
    final status = reading == null
        ? l10n.expressionNotConnected
        : travel == null || !travel.isUsable
        ? l10n.expressionCalibrationNeeded
        : null;
    return SizedBox(
      width: penWidth,
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.fromSize(
            size: _visual,
            child: Opacity(
              opacity: reading == null ? surface.disabledOpacity : 1,
              child: Image.asset(asset, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: _inset),
          _readout(context, position),
          const SizedBox(height: _inset),
          _meter(context, position ?? reading),
          const SizedBox(height: _inset),
          _ends(context),
          if (status != null) ...[
            const SizedBox(height: 26),
            SizedBox(
              width: _visual.width,
              height: 33,
              child: AppText(
                status,
                key: const Key('expression_status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 23,
                  height: 1.3,
                ),
              ),
            ),
          ],
          if (onCalibrate != null) ...[
            SizedBox(height: status == null ? 36 : 35),
            LoopOutlinedButton(
              key: const Key('expression_calibrate'),
              width: 168,
              label: l10n.expressionCalibrate,
              // Nothing to capture until a jack has reported a position: the
              // ends are readings, and there are none.
              onTap: reading == null ? null : onCalibrate,
            ),
          ],
        ],
      ),
    );
  }

  Widget _readout(BuildContext context, double? position) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      width: _visual.width,
      height: 42,
      child: Row(
        children: [
          // The label yields rather than the number: a position that had to
          // be read at a glance is the whole point of this row.
          Expanded(
            child: AppText(
              l10n.expressionPosition,
              maxLines: 1,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 24,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 12),
          AppText(
            position == null
                ? l10n.expressionNoReading
                : '${(position * 100).round()}%',
            key: const Key('expression_position'),
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 36,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _meter(BuildContext context, double? fraction) {
    final surface = context.surface;
    return SizedBox(
      width: _visual.width,
      height: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(
          color: surface.meterTrack,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (fraction ?? 0).clamp(0.0, 1.0),
              // Both factors: with only a width the fill is handed loose
              // height constraints, and a ColoredBox with no child takes none
              // of them — the meter would draw its track and nothing else.
              heightFactor: 1,
              child: ColoredBox(color: surface.textSecondary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ends(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final style = TextStyle(
      color: surface.textTertiary,
      fontSize: 21,
      height: 1,
    );
    return SizedBox(
      width: _visual.width,
      height: 24,
      child: Row(
        children: [
          Expanded(
            child: AppText(l10n.expressionHeel, maxLines: 1, style: style),
          ),
          const SizedBox(width: 12),
          AppText(l10n.expressionToe, maxLines: 1, style: style),
        ],
      ),
    );
  }
}
