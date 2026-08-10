/// The rail glyphs the pen draws itself, rather than names from an icon set.
///
/// Five of the nine rail icons are stock lucide and come from the font
/// (`repeat`, `volume-2`, `wifi-high`, `cpu`, `sun`). These four are not: the
/// pen draws them as vector shapes, and no lucide glyph matches. They are
/// transcribed here from the pen's own numbers rather than approximated with
/// the nearest stock icon, which is what put nine Material lookalikes on this
/// rail in the first place.
///
/// **The `NavRail` component's icon names are not the source.** `ctaGc` carries
/// lucide names on its `NavItem` instances — `activity`, `gamepad-2`,
/// `align-justify`, `target` — and every screen in the pen draws something
/// else in their place. The screens are what a person looks at, so the screens
/// win; the component's names are stale defaults.
///
/// Everything here is in the pen's own 22-unit box with its 1.65 stroke, and
/// scales from there, so the numbers in this file can be diffed against the
/// pen node they came from.
library;

import 'package:flutter/widgets.dart';

/// One of the four rail glyphs the pen draws.
enum PenIcon {
  /// Signal: a smooth three-hump wave (`X8X8h`). Not lucide `activity`, which
  /// is a jagged pulse — this domain is the signal path, drawn as a signal.
  signal,

  /// Control: a landscape body with two round switches (`RVE0R`). Reads as the
  /// floor pedal the domain is about.
  control,

  /// Tracks: three upright bars (`V15Rb6`) — a track is a lane of the rig.
  tracks,

  /// Tuner: four bars of differing height (`XRflJ`).
  tuner,
}

/// Draws [icon] in [color], scaled to whatever box it is given.
class PenIconPainter extends CustomPainter {
  /// Creates a [PenIconPainter].
  const PenIconPainter({required this.icon, required this.color});

  /// Which glyph to draw.
  final PenIcon icon;

  /// The stroke colour.
  final Color color;

  /// The pen's own icon box. Every number below is in this space.
  static const double box = 22;

  /// The pen's stroke on all four, at [box].
  static const double _stroke = 1.65;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / box;
    canvas
      ..save()
      ..scale(scale);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (icon) {
      case PenIcon.signal:
        _signal(canvas, paint);
      case PenIcon.control:
        _control(canvas, paint);
      case PenIcon.tracks:
        _tracks(canvas, paint);
      case PenIcon.tuner:
        _tuner(canvas, paint);
    }
    canvas.restore();
  }

  /// `M0 8c3 0 3-8 6-8 3 0 3 8 6 8 3 0 3-8 6-8` over an 18x8 span, laid into
  /// the pen's 16.5x7.33 box at (2.75, 7.33) — the same 11/12 the pen scales
  /// its 24-unit source by to reach a 22 box.
  void _signal(Canvas canvas, Paint paint) {
    const k = 16.5 / 18;
    final path = Path()..moveTo(2.75, 7.33 + 8 * k);
    for (var i = 0; i < 3; i++) {
      final dy = i.isEven ? -8 * k : 8 * k;
      path.relativeCubicTo(3 * k, 0, 3 * k, dy, 6 * k, dy);
    }
    canvas.drawPath(path, paint);
  }

  /// A 16.5x11 body at (2.75, 5.5), radius 2.75, with two 2.75 switches on its
  /// centre line at x 6.42 and 12.83.
  void _control(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(2.75, 5.5, 16.5, 11),
        const Radius.circular(2.75),
      ),
      paint,
    );
    for (final x in const [6.4167, 12.8333]) {
      canvas.drawOval(Rect.fromLTWH(x, 9.625, 2.75, 2.75), paint);
    }
  }

  /// Three 3.67x14.67 bars at y 3.67, radius 1.375.
  void _tracks(Canvas canvas, Paint paint) {
    for (final x in const [2.75, 9.1667, 15.5833]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 3.6667, 3.6667, 14.6667),
          const Radius.circular(1.375),
        ),
        paint,
      );
    }
  }

  /// `M0 4.5l0 4m4.5-8.5l0 13m4.5-10.5l0 8m4.5-5.5l0 3` over a 13.5x13 span,
  /// laid into 12.375x11.92 at (3.67, 5) — so the two axes scale differently,
  /// exactly as the pen's own viewBox stretch does.
  void _tuner(Canvas canvas, Paint paint) {
    const kx = 12.375 / 13.5;
    const ky = 11.9167 / 13;
    // (top, bottom) of each bar in the source span, left to right.
    const bars = <(double, double)>[
      (4.5, 8.5),
      (0, 13),
      (2.5, 10.5),
      (5, 8),
    ];
    for (var i = 0; i < bars.length; i++) {
      final x = 3.6667 + i * 4.5 * kx;
      canvas.drawLine(
        Offset(x, 5 + bars[i].$1 * ky),
        Offset(x, 5 + bars[i].$2 * ky),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PenIconPainter oldDelegate) =>
      oldDelegate.icon != icon || oldDelegate.color != color;
}

/// A [PenIcon] as a widget, sized and coloured like an [Icon].
class PenIconView extends StatelessWidget {
  /// Creates a [PenIconView].
  const PenIconView({
    required this.icon,
    required this.size,
    required this.color,
    super.key,
  });

  /// Which glyph to draw.
  final PenIcon icon;

  /// Side of the square box, as [Icon.size] would be.
  final double size;

  /// The stroke colour.
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: PenIconPainter(icon: icon, color: color),
    ),
  );
}
