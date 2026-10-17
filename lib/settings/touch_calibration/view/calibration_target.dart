import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// Touch calibration's target (pen 30): a 72 px ring with a crosshair through
/// it, its lines running 19 px past the ring. Centred on [Offset.zero], so
/// place it with its centre on the point a tap is aimed at.
class CalibrationTarget extends StatelessWidget {
  /// Creates a [CalibrationTarget].
  const CalibrationTarget({super.key});

  /// The crosshair's span, which is the widget's size.
  static const double span = 110;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox.square(
      dimension: span,
      child: CustomPaint(
        painter: _TargetPainter(
          ring: surface.touchTarget,
          line: surface.touchTargetLine,
        ),
      ),
    );
  }
}

class _TargetPainter extends CustomPainter {
  const _TargetPainter({required this.ring, required this.line});

  final Color ring;
  final Color line;

  static const double _ringDiameter = 72;
  static const double _stroke = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final lines = Paint()
      ..color = line
      ..strokeWidth = _stroke;
    canvas
      ..drawLine(Offset(centre.dx, 0), Offset(centre.dx, size.height), lines)
      ..drawLine(Offset(0, centre.dy), Offset(size.width, centre.dy), lines)
      ..drawCircle(
        centre,
        _ringDiameter / 2,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke,
      );
  }

  @override
  bool shouldRepaint(_TargetPainter oldDelegate) =>
      oldDelegate.ring != ring || oldDelegate.line != line;
}

/// [CalibrationTarget] centred on [target], a point in [area]'s normalized
/// coordinates, inside a box of that [area]'s size.
class PositionedCalibrationTarget extends StatelessWidget {
  /// Creates a [PositionedCalibrationTarget].
  const PositionedCalibrationTarget({
    required this.target,
    required this.area,
    super.key,
  });

  /// Where the target sits, `(0, 0)` top-left to `(1, 1)` bottom-right.
  final ({double x, double y}) target;

  /// The size of the box the target is placed in.
  final Size area;

  @override
  Widget build(BuildContext context) {
    const half = CalibrationTarget.span / 2;
    return Positioned(
      left: target.x * area.width - half,
      top: target.y * area.height - half,
      child: const CalibrationTarget(key: Key('touch_calibration_target')),
    );
  }
}
