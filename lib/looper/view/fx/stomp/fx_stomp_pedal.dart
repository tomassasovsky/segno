import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/theme/theme.dart';

/// A catalogue pedal, drawn in code from its [face] (the approved V2 design,
/// #1501).
///
/// The pedal keeps its own proportions and scales to fit the space its
/// parent gives it. Every part is laid out in one fixed drawing space and the
/// whole is scaled, so each painter's geometry and gradients are built once
/// and reused by every pedal.
class FxStompPedal extends StatelessWidget {
  /// Creates an [FxStompPedal].
  const FxStompPedal({required this.face, super.key});

  /// What the pedal shows.
  final FxStompFace face;

  @override
  Widget build(BuildContext context) {
    final ink = _inkOn(face.colour);
    final knobs = face.knobs.take(kFxStompMaxKnobs).toList();
    return RepaintBoundary(
      // A picture: the name and the controls it shows are on the surface
      // around it, which is what a screen reader reads.
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: _kPedal.aspectRatio,
          child: FittedBox(
            child: SizedBox.fromSize(
              size: _kPedal,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EnclosurePainter(face.colour, lit: face.lit),
                    ),
                  ),
                  _CheckLabel(ink: ink),
                  for (var i = 0; i < knobs.length; i++)
                    _StompKnob(
                      knob: knobs[i],
                      slot: _KnobSlot.of(index: i, count: knobs.length),
                      ink: ink,
                    ),
                  Positioned.fill(
                    child: CustomPaint(painter: _TreadlePainter(face.colour)),
                  ),
                  _TreadleLabel(
                    name: face.name,
                    subtitle: face.subtitle,
                    ink: ink,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The drawing space every part is laid out in.
const Size _kPedal = Size(450, 662);

/// The enclosure, under the knobs.
const Rect _kBody = Rect.fromLTWH(24, 14, 402, 626);

/// The hinged treadle.
const Rect _kTreadle = Rect.fromLTWH(32, 298, 386, 334);

/// The ribbed rubber pad on the treadle.
const Rect _kPad = Rect.fromLTWH(62, 432, 326, 178);

/// The chrome badge's centre and radius.
const Offset _kBadge = Offset(225, 521);
const double _kBadgeRadius = 41;

/// The LED's centre.
const Offset _kLed = Offset(225, 52);

/// The row the knobs sit on.
const double _kKnobRow = 136;

/// Light print on a dark enclosure, dark print on a light one.
Color _inkOn(Color body) =>
    body.computeLuminance() > 0.4 ? _kDarkInk : _kLightInk;

const Color _kLightInk = Color(0xFFF6F8FA);
const Color _kDarkInk = Color(0xFF1B1D22);

/// [colour] with its lightness moved by [delta], as the design's shades are.
Color _shade(Color colour, double delta) {
  final hsl = HSLColor.fromColor(colour);
  return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
}

/// An SVG bounding-box radial gradient over [rect]: centred at [centre] (a
/// fraction of the box) with a radius of [radius] of its width and height,
/// so an ellipse on a box that is not square.
Shader _boxRadial(
  Rect rect,
  Offset centre,
  double radius,
  List<Color> colors,
  List<double> stops,
) {
  final c = Offset(
    rect.left + rect.width * centre.dx,
    rect.top + rect.height * centre.dy,
  );
  final sy = rect.height / rect.width;
  final matrix = Float64List.fromList([
    1, 0, 0, 0, //
    0, sy, 0, 0, //
    0, 0, 1, 0, //
    0, c.dy * (1 - sy), 0, 1, //
  ]);
  return ui.Gradient.radial(
    c,
    radius * rect.width,
    colors,
    stops,
    TileMode.clamp,
    matrix,
  );
}

Paint _fill(Color colour) => Paint()..color = colour;

Paint _blurred(Color colour, double sigma) => Paint()
  ..color = colour
  ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

Paint _stroke(Color colour, double width) => Paint()
  ..color = colour
  ..style = PaintingStyle.stroke
  ..strokeWidth = width;

/// The polished metal of the screws, the LED bezel and the badge.
Shader _metal(Offset centre, double radius) => _boxRadial(
  Rect.fromCircle(center: centre, radius: radius),
  const Offset(.35, .3),
  .8,
  const [Color(0xFFF2F4F6), Color(0xFFA7ADB5), Color(0xFF6C727A)],
  const [0, .6, 1],
);

/// The parts of the enclosure every pedal shares, built once.
final class _EnclosureParts {
  _EnclosureParts() {
    final body = RRect.fromRectAndRadius(_kBody, const Radius.circular(30));
    bodyShape = body;
    bevel = RRect.fromRectAndRadius(
      const Rect.fromLTWH(25.5, 15.5, 399, 623),
      const Radius.circular(29),
    );
    side = Paint()
      ..shader = ui.Gradient.linear(
        _kBody.centerLeft,
        _kBody.centerRight,
        [
          Colors.black.withValues(alpha: .28),
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: .32),
        ],
        const [0, .08, .92, 1],
      );
    sheen = Paint()..shader = _sheenOver(_kBody, 1);
    for (final x in const [52.0, 398.0]) {
      screws.add((
        shadow: Offset(x, 44),
        head: Offset(x, 43.5),
        metal: Paint()..shader = _metal(Offset(x, 43.5), 6.5),
        slotFrom: Offset(x - 4, 46),
        slotTo: Offset(x + 4, 41),
      ));
    }
    bezel = Paint()..shader = _metal(_kLed, 10);
    lens = Paint()
      ..shader = _boxRadial(
        Rect.fromCircle(center: _kLed, radius: 7),
        const Offset(.4, .35),
        .7,
        const [Color(0xFFFFD2C8), Color(0xFFFF4A3A), Color(0xFF8A130B)],
        const [0, .45, 1],
      );
    jackNut = _fill(const Color(0xFF2A2D32));
  }

  late final RRect bodyShape;
  late final RRect bevel;
  late final Paint side;
  late final Paint sheen;
  final List<
    ({
      Offset shadow,
      Offset head,
      Paint metal,
      Offset slotFrom,
      Offset slotTo,
    })
  >
  screws = [];
  late final Paint bezel;
  late final Paint lens;
  final Paint lensOff = _fill(const Color(0xFF4A1410));
  late final Paint jackNut;

  final Rect ground = Rect.fromCenter(
    center: const Offset(225, 648),
    width: 400,
    height: 28,
  );
  final RRect leftJack = RRect.fromLTRBR(
    16,
    104,
    26,
    132,
    const Radius.circular(2),
  );
  final RRect rightJack = RRect.fromLTRBR(
    424,
    104,
    434,
    132,
    const Radius.circular(2),
  );
  final Paint groundShadow = _blurred(Colors.black.withValues(alpha: .35), 4);
  final Paint bevelLine = _stroke(Colors.white.withValues(alpha: .28), 2);
  final Paint screwShadow = _fill(Colors.black.withValues(alpha: .25));
  final Paint screwSlot = _stroke(const Color(0xFF55595F), 1.8)
    ..strokeCap = StrokeCap.round;
  final Paint ledGlow = _blurred(
    const Color(0xFFFF3B2B).withValues(alpha: .55),
    5,
  );
  final Paint ledGlint = _fill(Colors.white.withValues(alpha: .8));
}

/// The top-left sheen, at [opacity], over [rect].
Shader _sheenOver(Rect rect, double opacity) => _boxRadial(
  rect,
  const Offset(.28, .08),
  .75,
  [
    Colors.white.withValues(alpha: .38 * opacity),
    Colors.white.withValues(alpha: .06 * opacity),
    Colors.white.withValues(alpha: 0),
  ],
  const [0, .5, 1],
);

final _EnclosureParts _enclosure = _EnclosureParts();

/// The enclosure: its shadow, side jacks, coloured body with its shading,
/// sheen and bevel, the two screws and the LED.
class _EnclosurePainter extends CustomPainter {
  _EnclosurePainter(this.colour, {required this.lit});

  final Color colour;

  /// Whether the LED is on: the effect is engaged.
  final bool lit;

  /// The body gradient per colour, shared by every pedal of that colour.
  static final Map<Color, Paint> _bodies = {};

  Paint get _body => _bodies.putIfAbsent(
    colour,
    () => Paint()
      ..shader = ui.Gradient.linear(
        _kBody.topCenter,
        _kBody.bottomCenter,
        [_shade(colour, .10), colour, _shade(colour, -.10)],
        const [0, .55, 1],
      ),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final parts = _enclosure;
    canvas
      ..drawOval(parts.ground, parts.groundShadow)
      // The jacks: only their nuts show past the enclosure's sides.
      ..drawRRect(parts.leftJack, parts.jackNut)
      ..drawRRect(parts.rightJack, parts.jackNut)
      ..drawRRect(parts.bodyShape, _body)
      ..save()
      ..clipRRect(parts.bodyShape)
      ..drawRect(_kBody, parts.side)
      ..drawRect(_kBody, parts.sheen)
      ..restore()
      ..drawRRect(parts.bevel, parts.bevelLine);
    for (final screw in parts.screws) {
      canvas
        ..drawCircle(screw.shadow, 7.5, parts.screwShadow)
        ..drawCircle(screw.head, 6.5, screw.metal)
        ..drawLine(screw.slotFrom, screw.slotTo, parts.screwSlot);
    }
    if (lit) canvas.drawCircle(_kLed, 16, parts.ledGlow);
    canvas
      ..drawCircle(_kLed, 10, parts.bezel)
      ..drawCircle(_kLed, 7, lit ? parts.lens : parts.lensOff)
      ..drawCircle(_kLed - const Offset(2.5, 2.5), 2, parts.ledGlint);
  }

  @override
  bool shouldRepaint(_EnclosurePainter oldDelegate) =>
      oldDelegate.colour != colour || oldDelegate.lit != lit;
}

/// The parts of the treadle every pedal shares, built once.
final class _TreadleParts {
  _TreadleParts() {
    rubber = Paint()
      ..shader = ui.Gradient.linear(
        _kPad.topCenter,
        _kPad.bottomCenter,
        const [Color(0xFF16181C), Color(0xFF23262C), Color(0xFF1B1D22)],
        const [0, .12, 1],
      );
    for (var row = 0, y = 452.0; y < 600; row++, y += 15) {
      for (var x = 80.0 + (row.isOdd ? 15 : 0); x < 362; x += 30) {
        // The badge sits in a clear patch in the middle of the ribs.
        if ((Offset(x + 13, y + 3.5) - _kBadge).distance <= 54) continue;
        ribs.addRRect(
          RRect.fromLTRBR(x, y, x + 26, y + 7, const Radius.circular(3.5)),
        );
      }
    }
    badgeMetal = Paint()..shader = _metal(_kBadge, _kBadgeRadius);
    final mark = Path()
      ..moveTo(10, -18)
      ..cubicTo(0, -26, -16, -20, -12, -8)
      ..cubicTo(-8, 2, 12, 0, 12, 12)
      ..cubicTo(12, 24, -6, 26, -12, 18)
      ..moveTo(-20, 20)
      ..lineTo(20, -20);
    final dots = Path()
      ..addOval(Rect.fromCircle(center: const Offset(-16, -4), radius: 2.6))
      ..addOval(Rect.fromCircle(center: const Offset(16, 4), radius: 2.6));
    // The segno mark, at the badge, 1.25 times its drawn size.
    final place = Matrix4.identity()
      ..setEntry(0, 0, 1.25)
      ..setEntry(1, 1, 1.25)
      ..setEntry(0, 3, _kBadge.dx)
      ..setEntry(1, 3, _kBadge.dy);
    segno = mark.transform(place.storage);
    segnoDots = dots.transform(place.storage);
  }

  late final Paint rubber;
  final Path ribs = Path();
  late final Paint badgeMetal;
  late final Path segno;
  late final Path segnoDots;

  final RRect gap = RRect.fromLTRBR(
    30,
    292,
    420,
    300,
    const Radius.circular(4),
  );
  final RRect treadle = RRect.fromRectAndRadius(
    _kTreadle,
    const Radius.circular(22),
  );
  final RRect treadleBevel = RRect.fromLTRBR(
    33,
    299,
    417,
    631,
    const Radius.circular(21),
  );
  final RRect padWell = RRect.fromLTRBR(
    58,
    428,
    392,
    614,
    const Radius.circular(16),
  );
  final RRect pad = RRect.fromRectAndRadius(_kPad, const Radius.circular(13));
  final RRect foot = RRect.fromLTRBR(
    24,
    626,
    426,
    640,
    const Radius.circular(6),
  );

  final Paint gapFill = _fill(Colors.black.withValues(alpha: .45));
  final Paint sheen = Paint()..shader = _sheenOver(_kTreadle, .5);
  final Paint treadleLine = _stroke(Colors.white.withValues(alpha: .22), 2);
  final Paint well = _fill(const Color(0xFF0D0E10));
  final Paint ribFill = _fill(const Color(0xFF2C3037));
  final Paint padLine = _stroke(Colors.black.withValues(alpha: .6), 3);
  final Paint badgeShadow = _blurred(Colors.black.withValues(alpha: .5), 4);
  final Paint badgeRim = _stroke(Colors.white.withValues(alpha: .5), 1.5);
  final Paint segnoGlint = _stroke(Colors.white.withValues(alpha: .55), 6.25)
    ..strokeCap = StrokeCap.round;
  final Paint segnoLine = _stroke(const Color(0xFF2A2E34), 6.25)
    ..strokeCap = StrokeCap.round;
  final Paint segnoDot = _fill(const Color(0xFF2A2E34));
  final Paint footShade = _fill(Colors.black.withValues(alpha: .3));
}

final _TreadleParts _treadle = _TreadleParts();

/// The hinged treadle: the gap above it, its coloured plate, the ribbed
/// rubber pad and the chrome badge with the segno mark.
class _TreadlePainter extends CustomPainter {
  _TreadlePainter(this.colour);

  final Color colour;

  /// The plate gradient per colour, shared by every pedal of that colour.
  static final Map<Color, Paint> _plates = {};

  Paint get _plate => _plates.putIfAbsent(
    colour,
    () => Paint()
      ..shader = ui.Gradient.linear(
        _kTreadle.topCenter,
        _kTreadle.bottomCenter,
        [colour, _shade(colour, -.20)],
      ),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final parts = _treadle;
    canvas
      ..drawRRect(parts.gap, parts.gapFill)
      ..drawRRect(parts.treadle, _plate)
      ..drawRRect(parts.treadle, parts.sheen)
      ..drawRRect(parts.treadleBevel, parts.treadleLine)
      ..drawRRect(parts.padWell, parts.well)
      ..drawRRect(parts.pad, parts.rubber)
      ..drawPath(parts.ribs, parts.ribFill)
      ..drawRRect(parts.pad, parts.padLine)
      ..drawCircle(_kBadge + const Offset(0, 2), 47, parts.badgeShadow)
      ..drawCircle(_kBadge, 45, parts.well)
      ..drawCircle(_kBadge, _kBadgeRadius, parts.badgeMetal)
      ..drawCircle(_kBadge, _kBadgeRadius, parts.badgeRim)
      ..save()
      ..translate(0, 1.5)
      ..drawPath(parts.segno, parts.segnoGlint)
      ..restore()
      ..drawPath(parts.segno, parts.segnoLine)
      ..drawPath(parts.segnoDots, parts.segnoDot)
      ..drawRRect(parts.foot, parts.footShade);
  }

  @override
  bool shouldRepaint(_TreadlePainter oldDelegate) =>
      oldDelegate.colour != colour;
}

/// Where a knob sits: its centre, its radius and the width its label has.
class _KnobSlot {
  const _KnobSlot(this.x, this.radius, this.labelWidth);

  /// The slot for knob [index] of [count], as the design spaces them.
  factory _KnobSlot.of({required int index, required int count}) {
    const xs = {
      1: [225.0],
      2: [138.0, 312.0],
      3: [104.0, 225.0, 346.0],
      4: [88.0, 179.0, 271.0, 362.0],
    };
    const radii = {1: 44.0, 2: 42.0, 3: 36.0, 4: 31.0};
    final row = xs[count]!;
    final width = count == 1 ? 200.0 : row[1] - row[0] - 6;
    return _KnobSlot(row[index], radii[count]!, width);
  }

  final double x;
  final double radius;
  final double labelWidth;
}

/// One knob and the label under it.
class _StompKnob extends StatelessWidget {
  const _StompKnob({required this.knob, required this.slot, required this.ink});

  final FxStompKnob knob;
  final _KnobSlot slot;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final r = slot.radius;
    return Positioned(
      left: slot.x - slot.labelWidth / 2,
      top: _kKnobRow - r,
      width: slot.labelWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: r * 2,
            // Its own layer: a knob that turns repaints alone, not the
            // enclosure and treadle under it.
            child: RepaintBoundary(
              child: CustomPaint(painter: _KnobPainter(knob.setting)),
            ),
          ),
          SizedBox(height: 18, width: slot.labelWidth),
          _PedalPrint(
            knob.label,
            size: 15,
            weight: FontWeight.w700,
            spacing: 1.5,
            colour: ink.withValues(alpha: .88),
          ),
        ],
      ),
    );
  }
}

/// The parts of a knob of one radius, built once per radius.
final class _KnobParts {
  /// The parts for a knob of radius [r].
  factory _KnobParts.of(double r) =>
      _byRadius.putIfAbsent(r, () => _KnobParts._(r));

  _KnobParts._(this.r) {
    final c = Offset(r, r);
    skirt = Paint()
      ..shader = _boxRadial(
        Rect.fromCircle(center: c, radius: r),
        const Offset(.4, .35),
        .75,
        const [Color(0xFF3B4048), Color(0xFF121418)],
        const [0, 1],
      );
    cap = Paint()
      ..shader = _boxRadial(
        Rect.fromCircle(center: c, radius: r * .74),
        const Offset(.38, .3),
        .8,
        const [Color(0xFF4D535D), Color(0xFF262A30), Color(0xFF16181C)],
        const [0, .6, 1],
      );
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30;
      final d = Offset(math.cos(a), math.sin(a));
      ridges
        ..moveTo(c.dx + d.dx * (r - 6), c.dy + d.dy * (r - 6))
        ..lineTo(c.dx + d.dx * (r - .5), c.dy + d.dy * (r - .5));
    }
    shadow = Rect.fromCenter(
      center: c + Offset(0, r * .32),
      width: r * 2.04,
      height: r * 1.96,
    );
    glint = Rect.fromCenter(
      center: c + Offset(-r * .22, -r * .3),
      width: r * .72,
      height: r * .4,
    );
    pointer = _stroke(const Color(0xFFF4F6F8), math.max(3, r * .11))
      ..strokeCap = StrokeCap.round;
  }

  static final Map<double, _KnobParts> _byRadius = {};

  final double r;
  late final Paint skirt;
  late final Paint cap;
  final Path ridges = Path();
  late final Rect shadow;
  late final Rect glint;
  late final Paint pointer;

  final Paint shadowFill = _blurred(Colors.black.withValues(alpha: .38), 4);
  final Paint base = _fill(const Color(0xFF0B0C0E));
  final Paint ridgeLine = _stroke(Colors.black.withValues(alpha: .55), 1.6);
  final Paint capLine = _stroke(Colors.black.withValues(alpha: .5), 1.2);
  final Paint glintFill = _fill(Colors.white.withValues(alpha: .10));
}

/// A knurled knob with its cap and pointer, filling its square box.
class _KnobPainter extends CustomPainter {
  _KnobPainter(this.setting);

  /// Where it points, from 0 (fully left) to 1 (fully right).
  final double setting;

  /// The sweep a knob turns through, centred on straight up.
  static const double _sweep = 270 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final parts = _KnobParts.of(r);
    final c = Offset(r, r);
    final angle = (setting.clamp(0.0, 1.0) - .5) * _sweep - math.pi / 2;
    final d = Offset(math.cos(angle), math.sin(angle));
    canvas
      ..drawOval(parts.shadow, parts.shadowFill)
      ..drawCircle(c + const Offset(0, 3), r, parts.base)
      ..drawCircle(c, r, parts.skirt)
      ..drawPath(parts.ridges, parts.ridgeLine)
      ..drawCircle(c, r * .74, parts.cap)
      ..drawCircle(c, r * .74, parts.capLine)
      ..drawOval(parts.glint, parts.glintFill)
      ..drawLine(c + d * (r * .18), c + d * (r * .66), parts.pointer);
  }

  @override
  bool shouldRepaint(_KnobPainter oldDelegate) =>
      oldDelegate.setting != setting;
}

/// "CHECK" under the LED.
class _CheckLabel extends StatelessWidget {
  const _CheckLabel({required this.ink});

  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      top: 75,
      child: _PedalPrint(
        'CHECK',
        size: 11,
        weight: FontWeight.w700,
        spacing: 1.5,
        colour: ink.withValues(alpha: .88),
      ),
    );
  }
}

/// The effect's name on the treadle, and the subtitle under it.
class _TreadleLabel extends StatelessWidget {
  const _TreadleLabel({
    required this.name,
    required this.subtitle,
    required this.ink,
  });

  final String name;
  final String? subtitle;
  final Color ink;

  /// The name's size: as large as the treadle allows for a short name, a
  /// step smaller per letter after five, and shrunk further to fit a long
  /// one.
  double get _nameSize => switch (name.length) {
    <= 5 => 74,
    6 => 64,
    7 => 56,
    _ => 48,
  };

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final shadow = Shadow(
      offset: const Offset(0, 1.5),
      blurRadius: 1.2,
      color: (ink == _kLightInk ? Colors.black : Colors.white).withValues(
        alpha: .35,
      ),
    );
    return Positioned(
      left: 48,
      right: 48,
      top: 298,
      height: 128,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PedalPrint(
            name,
            size: _nameSize,
            weight: FontWeight.w700,
            spacing: 2,
            colour: ink,
            shadow: shadow,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            _PedalPrint(
              subtitle,
              size: 17,
              weight: FontWeight.w600,
              spacing: 3,
              colour: ink.withValues(alpha: .8),
              shadow: shadow,
            ),
          ],
        ],
      ),
    );
  }
}

/// One line printed on the pedal, shrunk to fit its width rather than
/// wrapped or cut.
class _PedalPrint extends StatelessWidget {
  const _PedalPrint(
    this.text, {
    required this.size,
    required this.weight,
    required this.spacing,
    required this.colour,
    this.shadow,
  });

  final String text;
  final double size;
  final FontWeight weight;
  final double spacing;
  final Color colour;
  final Shadow? shadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            fontSize: size,
            fontWeight: weight,
            letterSpacing: spacing,
            height: 1,
            color: colour,
            shadows: shadow == null ? null : [shadow!],
            // Print on a pedal, wherever the pedal is: never the ambient
            // style's decoration.
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
