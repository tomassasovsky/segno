import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

// The pedal design's face pictures and module screens, ported from the
// generator of record (segno-design docs/design/own-art/pedal_faces_v3.py):
// the same shapes, colours, placement and clipping, in the face's drawing
// space. They are drawn once into a pedal's cached picture, so they build
// their paths as they go.

/// [colour] with its HSL lightness moved by [delta], as the design's
/// `shade()` moves it.
Color fxStompShade(Color colour, double delta) {
  final hsl = HSLColor.fromColor(colour);
  return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
}

/// [colour] at [opacity].
Color _a(Color colour, double opacity) =>
    colour.withValues(alpha: colour.a * opacity);

/// An SVG bounding-box radial gradient over [rect]: centred at [centre] (a
/// fraction of the box), with a radius of [radius] of its width and height.
Shader fxStompBoxRadial(
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
  return ui.Gradient.radial(
    c,
    radius * rect.width,
    colors,
    stops,
    TileMode.clamp,
    Float64List.fromList([
      1, 0, 0, 0, //
      0, sy, 0, 0, //
      0, 0, 1, 0, //
      0, c.dy * (1 - sy), 0, 1, //
    ]),
  );
}

/// An SVG bounding-box linear gradient over [rect], from [from] to [to] as
/// fractions of the box.
Shader fxStompBoxLinear(
  Rect rect,
  Offset from,
  Offset to,
  List<Color> colors,
  List<double> stops,
) => ui.Gradient.linear(
  from,
  to,
  colors,
  stops,
  TileMode.clamp,
  Float64List.fromList([
    rect.width, 0, 0, 0, //
    0, rect.height, 0, 0, //
    0, 0, 1, 0, //
    rect.left, rect.top, 0, 1, //
  ]),
);

/// A stroke of [colour] at [opacity], [width] wide.
Paint fxStompStroke(Color colour, double width, [double opacity = 1]) =>
    fxStompFill(colour, opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

/// A fill of [colour] at [opacity].
Paint fxStompFill(Color colour, [double opacity = 1]) =>
    Paint()..color = _a(colour, opacity);

/// The polished metal of screws, bezels, badges and hex nuts, over [r].
Shader fxStompMetal(Rect r) => fxStompBoxRadial(
  r,
  const Offset(.35, .3),
  .8,
  const [Color(0xFFF2F4F6), Color(0xFFA7ADB5), Color(0xFF6C727A)],
  const [0, .6, 1],
);

/// The metal dome of switches and dome knobs, over [r].
Shader fxStompDome(Rect r) => fxStompBoxRadial(
  r,
  const Offset(.36, .28),
  .85,
  const [
    Color(0xFFFFFFFF),
    Color(0xFFD4D8DD),
    Color(0xFF8E949C),
    Color(0xFF5F656D),
  ],
  const [0, .35, .8, 1],
);

Path _poly(Iterable<Offset> points, {bool close = false}) {
  final path = Path();
  var first = true;
  for (final p in points) {
    if (first) {
      path.moveTo(p.dx, p.dy);
      first = false;
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  if (close) path.close();
  return path;
}

/// The design's `wave()`: a sine sampled every [step] across `x0..x1`.
List<Offset> _wave(
  double x0,
  double x1,
  double yc,
  double amp,
  double period, {
  double phase = 0,
  int step = 4,
}) => [
  for (var x = x0.truncate(); x <= x1.truncate(); x += step)
    Offset(
      x.toDouble(),
      yc + amp * math.sin((x - x0) / period * 2 * math.pi + phase),
    ),
];

/// [path] dashed, [on] drawn and [off] skipped in turn.
Path _dashed(Path path, double on, double off) {
  final out = Path();
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      out.addPath(metric.extractPath(d, d + on), Offset.zero);
      d += on + off;
    }
  }
  return out;
}

double _rad(double degrees) => degrees * math.pi / 180;

Offset _polar(Offset c, double r, double degrees) =>
    c + Offset(math.cos(_rad(degrees)), math.sin(_rad(degrees))) * r;

/// Paints [graphic] for a pedal drawn by [spec], in the face region [r] the
/// design gives it (the body, the treadle, a window's panel or a rocker's
/// side band).
void paintFxStompGraphic(
  Canvas canvas,
  FxStompGraphic graphic,
  Rect r,
  FxStompSpec spec,
) {
  final (x, y, w, h) = (r.left, r.top, r.width, r.height);
  switch (graphic) {
    case FxStompGraphic.none:
      return;
    case FxStompGraphic.flames:
      _flames(canvas, x, y + h * .45, w, h * .55);
    case FxStompGraphic.clip:
      _clip(canvas, x + 30, y + 205, w - 60, 70, const Color(0xFFFFD400));
    case FxStompGraphic.sines:
      _sines(canvas, x, y + h * .2, w, h * .75);
    case FxStompGraphic.swirl:
      _swirl(canvas, x, y, w, h, const Color(0xFFD9C6FF));
    case FxStompGraphic.ripples:
      _ripples(canvas, x, y + 260, w, 300, const Color(0xFFBFEFFF));
    case FxStompGraphic.stars:
      _stars(canvas, x, y, w, h);
    case FxStompGraphic.octaves:
      _octaves(canvas, x, y + 320, w, 306);
    case FxStompGraphic.tweed:
      _tweed(canvas, x, y, w, h);
    case FxStompGraphic.slices:
      _slices(canvas, x, y + 450, w, 190);
    case FxStompGraphic.echo:
      _echo(canvas, spec);
    case FxStompGraphic.reels:
      _reels(
        canvas,
        x + w * .1,
        y + h * .12,
        w * .8,
        h * .75,
        const Color(0xFFFFFFFF),
      );
    case FxStompGraphic.spring:
      _spring(canvas, x, y + 104, w, 26);
    case FxStompGraphic.gate:
      _gate(canvas, x + 20, y + 170, w - 40, 110, const Color(0xFF16181C));
    case FxStompGraphic.staff:
      _staff(canvas, x + 20, y + 175, w - 40, 100, const Color(0xFF1D5C56));
    case FxStompGraphic.tuner:
      _tuner(canvas, x + 60, y + 180, w - 120, 100, const Color(0xFF16181C));
    case FxStompGraphic.arrows:
      _arrows(canvas, x, y + 40, w, h - 60, const Color(0xFFB0346E));
    case FxStompGraphic.pump:
      _pump(canvas, x, y + 120, w, h - 140, const Color(0xFF7A3D00));
    case FxStompGraphic.spike:
      _spike(canvas, x, y + 40, w, h - 40, const Color(0xFF1E4D17));
    case FxStompGraphic.doubled:
      _double(canvas, x, y, w, h, const Color(0xFF8F2A66));
    case FxStompGraphic.chevrons:
      _chevrons(canvas, x, y, w);
  }
}

/// The width a name has across a treadle.
const double kFxStompTreadleTitleRoom = 360;

/// Whether [graphic] is drawn on a treadle face's treadle rather than on
/// its body.
bool fxStompGraphicOnTreadle(FxStompGraphic graphic) =>
    graphic == FxStompGraphic.echo || graphic == FxStompGraphic.spring;

void _flames(Canvas canvas, double x, double y, double w, double h) {
  const layers = [
    (Color(0xFFFF5A1F), .9),
    (Color(0xFFFFB21F), .85),
    (Color(0xFFFFF1A8), .7),
  ];
  const n = 9;
  for (final (i, (colour, opacity)) in layers.indexed) {
    final points = [Offset(x, y + h)];
    for (var k = 0; k <= n; k++) {
      final px = x + w * k / n;
      final tip = y + h * (.15 + .25 * i) + (k % 3) * h * .08;
      points
        ..add(
          k == 0
              ? Offset(px, y + h * (.6 + .15 * i))
              : Offset(px - w / n / 2, y + h * (.55 + .15 * i)),
        )
        ..add(Offset(px, tip));
    }
    points.add(Offset(x + w, y + h));
    canvas.drawPath(
      _poly(points, close: true),
      fxStompFill(colour, opacity),
    );
  }
}

void _clip(Canvas canvas, double x, double y, double w, double h, Color c) {
  final yc = y + h / 2;
  final points = <Offset>[];
  for (var k = 0; k <= 8; k++) {
    final px = x + w * k / 8;
    final py = k.isEven ? yc - h * .32 : yc + h * .32;
    points
      ..add(Offset(px, py))
      ..add(Offset(px + w / 16, py));
  }
  canvas
    ..drawPath(
      _poly(points),
      fxStompStroke(c, 9, .9)..strokeJoin = StrokeJoin.miter,
    )
    ..drawPath(
      _dashed(_poly(_wave(x, x + w, yc, h * .45, w / 4, step: 3)), 6, 8),
      fxStompStroke(c, 3, .5),
    );
}

void _sines(Canvas canvas, double x, double y, double w, double h) {
  const strands = [
    (0.0, Color(0xFFFFFFFF)),
    (1.2, Color(0xFFC8FFE0)),
    (2.4, Color(0xFF0B5A33)),
  ];
  for (final (phase, colour) in strands) {
    canvas.drawPath(
      _poly(_wave(x, x + w, y + h / 2, h * .32, w / 2.2, phase: phase)),
      fxStompStroke(colour, 7, .75)..strokeCap = StrokeCap.round,
    );
  }
}

void _swirl(Canvas canvas, double x, double y, double w, double h, Color c) {
  final cx = x + w / 2;
  final cy = y + h / 2;
  canvas.drawPath(
    _poly([
      for (var i = 0; i < 900; i++)
        () {
          final t = i / 900 * 6 * math.pi;
          final r = 6 + t * h * .045;
          return Offset(cx + r * math.cos(t), cy + r * math.sin(t) * .8);
        }(),
    ]),
    fxStompStroke(c, 6, .45),
  );
}

void _ripples(Canvas canvas, double x, double y, double w, double h, Color c) {
  final centre = Offset(x + w / 2, y + h * .55);
  for (var r = 20; r < 420; r += 34) {
    canvas.drawOval(
      Rect.fromCenter(center: centre, width: r * 2.0, height: r * .84),
      fxStompStroke(
        c,
        math.max(1.5, 7 - r / 40),
        math.max(.08, .6 - r / 500),
      ),
    );
  }
}

void _stars(Canvas canvas, double x, double y, double w, double h) {
  final rect = Rect.fromLTWH(x, y, w, h);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = fxStompBoxRadial(
        rect,
        const Offset(.65, .4),
        .6,
        [
          const Color(0xFFB56CFF).withValues(alpha: .55),
          const Color(0xFF3A6CFF).withValues(alpha: .25),
          const Color(0x00000000),
        ],
        const [0, .5, 1],
      ),
  );
  // A fixed seed: the same starfield on every pedal and every run.
  final random = math.Random(4);
  const sizes = [.8, 1.2, 1.6, 2.4];
  for (var i = 0; i < 140; i++) {
    final centre = Offset(
      x + random.nextDouble() * w,
      y + random.nextDouble() * h,
    );
    final radius = sizes[random.nextInt(sizes.length)];
    final opacity = .4 + random.nextDouble() * .6;
    canvas.drawCircle(
      centre,
      radius,
      fxStompFill(const Color(0xFFFFFFFF), opacity),
    );
  }
  for (final (fx, fy) in const [(.78, .22), (.18, .7), (.86, .8)]) {
    final px = x + w * fx;
    final py = y + h * fy;
    canvas.drawPath(
      _poly([
        Offset(px, py - 10),
        Offset(px + 2, py - 2),
        Offset(px + 10, py),
        Offset(px + 2, py + 2),
        Offset(px, py + 10),
        Offset(px - 2, py + 2),
        Offset(px - 10, py),
        Offset(px - 2, py - 2),
      ], close: true),
      fxStompFill(const Color(0xFFFFFFFF)),
    );
  }
}

void _octaves(Canvas canvas, double x, double y, double w, double h) {
  const bands = [
    Color(0xFFFF3D2E),
    Color(0xFFFF7A1A),
    Color(0xFFFFB31A),
    Color(0xFFFFE14A),
    Color(0xFFFFF4B8),
  ];
  final centre = Offset(x + w / 2, y + h);
  for (final (i, colour) in bands.indexed) {
    canvas.drawCircle(
      centre,
      w * .75 - i * w * .13,
      fxStompFill(colour, .85),
    );
  }
}

void _tweed(Canvas canvas, double x, double y, double w, double h) {
  final dark = fxStompStroke(const Color(0xFF5A3D12), 3, .35);
  final light = fxStompStroke(const Color(0xFFFFF3CF), 2, .25);
  for (var i = 0.0; i < w + h; i += 9) {
    canvas.drawLine(Offset(x + i, y), Offset(x + i - h, y + h), dark);
  }
  for (var i = -h.truncateToDouble(); i < w; i += 9) {
    canvas.drawLine(Offset(x + i, y), Offset(x + i + h, y + h), light);
  }
}

void _slices(Canvas canvas, double x, double y, double w, double h) {
  final paint = fxStompFill(const Color(0xFF16181C), .9);
  for (var i = -300.0; i < w; i += 90) {
    canvas.drawPath(
      _poly([
        Offset(x + i, y + h),
        Offset(x + i + 40, y + h),
        Offset(x + i + 40 + h * .6, y),
        Offset(x + i + h * .6, y),
      ], close: true),
      paint,
    );
  }
}

void _echo(Canvas canvas, FxStompSpec spec) {
  // The name again, fading up and to the right behind itself.
  final y = spec.titleY ?? 392;
  for (final i in const [3, 2, 1]) {
    fxStompPaintText(
      canvas,
      spec.name,
      Offset(225.0 + i * 16, y - i * 13),
      maxWidth: kFxStompTreadleTitleRoom,
      TextStyle(
        fontFamily: spec.font,
        fontSize: spec.size,
        color: Color.fromRGBO(255, 255, 255, .42 - i * .12),
      ),
    );
  }
}

void _reels(Canvas canvas, double x, double y, double w, double h, Color c) {
  final stroke5 = fxStompStroke(c, 5, .55);
  final stroke4 = fxStompStroke(c, 4, .55);
  final fill = fxStompFill(c, .55);
  for (final cx in [x + w * .3, x + w * .7]) {
    final centre = Offset(cx, y + h / 2);
    canvas
      ..drawCircle(centre, h * .42, stroke5)
      ..drawCircle(centre, h * .12, fill);
    for (final a in const [90.0, 210.0, 330.0]) {
      canvas.drawCircle(_polar(centre, h * .26, a), h * .08, stroke4);
    }
  }
  canvas.drawLine(
    Offset(x + w * .3, y + h * .92),
    Offset(x + w * .7, y + h * .92),
    stroke4,
  );
}

void _spring(Canvas canvas, double x, double y, double w, double h) {
  canvas.drawPath(
    _poly([
      for (var i = 0; i < 1200; i++)
        Offset(
          x +
              w * .05 +
              i / 1200 * w * .9 +
              math.cos(i / 1200 * 2 * math.pi * 16) * 10,
          y + h / 2 + math.sin(i / 1200 * 2 * math.pi * 16) * h * .28,
        ),
    ]),
    fxStompStroke(const Color(0xFFE9C46A), 4, .85),
  );
}

void _gate(Canvas canvas, double x, double y, double w, double h, Color c) {
  final points = [Offset(x, y + h * .8)];
  for (final (a, b) in const [(.08, .3), (.38, .52), (.62, .9)]) {
    points.addAll([
      Offset(x + w * a, y + h * .8),
      Offset(x + w * a, y + h * .2),
      Offset(x + w * b, y + h * .2),
      Offset(x + w * b, y + h * .8),
    ]);
  }
  points.add(Offset(x + w, y + h * .8));
  canvas.drawPath(
    _poly(points),
    fxStompStroke(c, 8, .85)..strokeJoin = StrokeJoin.round,
  );
}

void _staff(Canvas canvas, double x, double y, double w, double h, Color c) {
  final line = fxStompStroke(c, 2.5, .45);
  for (var i = 0; i < 5; i++) {
    final ly = y + h * .2 + i * h * .15;
    canvas.drawLine(Offset(x, ly), Offset(x + w, ly), line);
  }
  final note = fxStompFill(c, .7);
  final stem = fxStompStroke(c, 3, .7);
  for (final (k, px) in [x + w * .22, x + w * .5, x + w * .78].indexed) {
    for (final step in const [0, 2, 4]) {
      final py = y + h * .8 - (step + k) * h * .075;
      canvas
        ..save()
        ..translate(px, py)
        ..rotate(_rad(-20))
        ..drawOval(
          Rect.fromCenter(center: Offset.zero, width: 26, height: 19),
          note,
        )
        ..restore();
    }
    final top = y + h * .8 - (4 + k) * h * .075;
    canvas.drawLine(Offset(px + 12, top), Offset(px + 12, top - h * .35), stem);
  }
}

void _tuner(Canvas canvas, double x, double y, double w, double h, Color c) {
  final centre = Offset(x + w / 2, y + h * .95);
  final r = h * .8;
  for (var a = -150.0; a <= -30; a += 10) {
    final inTune = a == -90;
    canvas.drawLine(
      _polar(centre, r * .82, a),
      _polar(centre, r, a),
      fxStompStroke(
        inTune ? const Color(0xFF18A558) : c,
        inTune ? 6 : 3,
        .8,
      ),
    );
  }
  canvas.drawLine(
    centre,
    _polar(centre, r * .9, -84),
    fxStompStroke(const Color(0xFFE8433A), 4),
  );
}

void _arrows(Canvas canvas, double x, double y, double w, double h, Color c) {
  final paint = fxStompStroke(c, 9, .55)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (final (dx, up) in const [(.25, true), (.5, false), (.75, true)]) {
    final px = x + w * dx;
    final py = y + h / 2;
    final s = up ? -1.0 : 1.0;
    canvas.drawPath(
      Path()
        ..moveTo(px - 26, py - s * 4)
        ..lineTo(px, py + s * -30)
        ..lineTo(px + 26, py - s * 4)
        ..moveTo(px, py + s * -26)
        ..lineTo(px, py + s * 34),
      paint,
    );
  }
}

void _pump(Canvas canvas, double x, double y, double w, double h, Color c) {
  final path = Path()..moveTo(x, y + h * .8);
  const n = 4;
  for (var k = 0; k < n; k++) {
    final x0 = x + w * k / n;
    path
      ..lineTo(x0 + 2, y + h * .85)
      ..cubicTo(
        x0 + w / n * .4,
        y + h * .85,
        x0 + w / n * .5,
        y + h * .15,
        x0 + w / n,
        y + h * .15,
      );
  }
  canvas.drawPath(
    path,
    fxStompStroke(c, 8, .55)..strokeJoin = StrokeJoin.round,
  );
}

void _spike(Canvas canvas, double x, double y, double w, double h, Color c) {
  canvas.drawPath(
    _poly([
      for (var i = 0; i <= 100; i++)
        () {
          final t = i / 100;
          final env = t >= .3
              ? math.exp(-math.pow((t - .3) * 9, 2))
              : math.max(0, (t - .22) / .08);
          return Offset(
            x + w * t,
            y + h / 2 - h * .45 * env * math.sin(t * 90),
          );
        }(),
    ]),
    fxStompStroke(c, 5, .6),
  );
}

void _double(Canvas canvas, double x, double y, double w, double h, Color c) {
  for (final dx in const [-30.0, 30.0]) {
    canvas.drawCircle(
      Offset(x + w * .5 + dx, y + h * .5),
      h * .38,
      fxStompStroke(c, 7, .45),
    );
  }
}

void _chevrons(Canvas canvas, double x, double y, double w) {
  for (var i = 0; i < 4; i++) {
    canvas.drawPath(
      _poly([
        Offset(x + w / 2 - 18, y + 600 - i * 60),
        Offset(x + w / 2, y + 578 - i * 60),
        Offset(x + w / 2 + 18, y + 600 - i * 60),
      ]),
      fxStompStroke(const Color(0xFFFFFFFF), 6, .5 - i * .12)
        ..strokeCap = StrokeCap.round,
    );
  }
}

/// Paints [text] centred on [baseline]'s x, its alphabetic baseline on
/// [baseline]'s y, as the design's `text-anchor="middle"` places it, shrunk
/// to [maxWidth] when it is wider.
void fxStompPaintText(
  Canvas canvas,
  String text,
  Offset baseline,
  TextStyle style, {
  double maxWidth = double.infinity,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final ascent = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  final scale = math.min(1, maxWidth / painter.width).toDouble();
  canvas
    ..save()
    ..translate(baseline.dx, baseline.dy)
    ..scale(scale)
    ..translate(-painter.width / 2, -ascent);
  painter.paint(canvas, Offset.zero);
  canvas.restore();
  painter.dispose();
}

/// Paints a module face's screen at [r]: the bezel, the grid, [display] in
/// it, clipped to the glass, and the glare.
void paintFxStompScreen(Canvas canvas, Rect r, FxStompDisplay display) {
  final (x, y, w, h) = (r.left, r.top, r.width, r.height);
  final glass = RRect.fromRectAndRadius(r, const Radius.circular(9));
  canvas
    ..drawRRect(
      RRect.fromRectAndRadius(r.inflate(4), const Radius.circular(12)),
      fxStompFill(const Color(0xFF000000), .5),
    )
    ..drawRRect(glass, fxStompFill(const Color(0xFF07090B)));
  final grid = fxStompStroke(const Color(0xFF3A4A40), 1, .25);
  for (var k = 1; k < 5; k++) {
    canvas.drawLine(
      Offset(x, y + k * h / 5),
      Offset(x + w, y + k * h / 5),
      grid,
    );
  }
  for (var k = 1; k < 8; k++) {
    canvas.drawLine(
      Offset(x + k * w / 8, y),
      Offset(x + k * w / 8, y + h),
      grid,
    );
  }
  canvas
    ..save()
    ..clipRRect(glass);
  switch (display) {
    case FxStompDisplay.none:
      break;
    case FxStompDisplay.vu:
      _vu(canvas, x, y, w, h);
    case FxStompDisplay.eq4:
      _curve(canvas, x, y, w, h, display, const Color(0xFF2AB0FF));
    case FxStompDisplay.bell:
      _curve(canvas, x, y, w, h, display, const Color(0xFFFFB02E));
    case FxStompDisplay.lpf:
      _curve(canvas, x, y, w, h, display, const Color(0xFFFF5A4A));
    case FxStompDisplay.record:
      _record(canvas, x, y, w, h);
    case FxStompDisplay.pixels:
      _pixels(canvas, x, y, w, h, const Color(0xFF7BF26C));
  }
  canvas
    ..restore()
    ..drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, h * .45),
        const Radius.circular(9),
      ),
      fxStompFill(const Color(0xFFFFFFFF), .05),
    );
}

void _vu(Canvas canvas, double x, double y, double w, double h) {
  final centre = Offset(x + w / 2, y + h * 1.05);
  final r = h * .85;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(x, y, w, h),
      const Radius.circular(9),
    ),
    fxStompFill(const Color(0xFFEFE2BD)),
  );
  for (var a = -130.0; a < -49; a += 8) {
    canvas.drawLine(
      _polar(centre, r * .85, a),
      _polar(centre, r, a),
      fxStompStroke(
        a > -60 ? const Color(0xFFFF4A3A) : const Color(0xFF2A2620),
        3,
      ),
    );
  }
  fxStompPaintText(
    canvas,
    'VU',
    Offset(centre.dx, y + h * .82),
    const TextStyle(
      fontFamily: 'Bebas Neue',
      fontSize: 22,
      color: Color(0xFF2A2620),
    ),
  );
  canvas.drawLine(
    centre,
    _polar(centre, r * .95, -72),
    fxStompStroke(const Color(0xFF16181C), 3),
  );
}

void _curve(
  Canvas canvas,
  double x,
  double y,
  double w,
  double h,
  FxStompDisplay kind,
  Color colour,
) {
  final points = <Offset>[];
  for (var i = 0; i <= 120; i++) {
    final t = i / 120;
    final v = switch (kind) {
      FxStompDisplay.eq4 =>
        .25 * math.sin(t * math.pi * 3.2 + .6) + .1 * math.sin(t * 14),
      FxStompDisplay.bell => .55 * math.exp(-math.pow((t - .55) * 7, 2)) - .08,
      FxStompDisplay.lpf => math.max(
        -.45,
        t < .6
            ? .05 + .35 * math.exp(-math.pow((t - .6) * 18, 2))
            : .4 - (t - .6) * 3.2,
      ),
      _ => 0.0,
    };
    points.add(Offset(x + 10 + (w - 20) * t, y + h / 2 - v * h));
  }
  final line = _poly(points);
  canvas
    ..drawPath(
      _poly([
        Offset(x + 10, y + h),
        ...points,
        Offset(x + w - 10, y + h),
      ], close: true),
      fxStompFill(colour, .18),
    )
    // The design's neon: a blurred copy under the line.
    ..drawPath(
      line,
      fxStompStroke(colour, 4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    )
    ..drawPath(line, fxStompStroke(colour, 4));
}

void _record(Canvas canvas, double x, double y, double w, double h) {
  final centre = Offset(x + w / 2, y + h * .82);
  canvas.drawCircle(centre, w * .48, fxStompFill(const Color(0xFF0A0A0A)));
  final groove = fxStompStroke(const Color(0xFF3A3A3A), 1.4);
  for (var r = 40; r < (w * .48).truncate(); r += 7) {
    canvas.drawCircle(centre, r.toDouble(), groove);
  }
  canvas
    ..drawCircle(centre, 34, fxStompFill(const Color(0xFFE8433A)))
    ..drawCircle(centre, 4, fxStompFill(const Color(0xFF0A0A0A)))
    ..drawPath(
      Path()
        ..moveTo(x + w * .15, y + h * .35)
        ..quadraticBezierTo(centre.dx, y + h * .05, x + w * .85, y + h * .35),
      fxStompStroke(const Color(0xFFFFFFFF), 10, .18),
    );
}

void _pixels(Canvas canvas, double x, double y, double w, double h, Color c) {
  final cw = (w - 24) / 16;
  final ch = (h - 24) / 7;
  for (var i = 0; i < 16; i++) {
    final v = .5 + .42 * math.sin(i / 15 * 2 * math.pi);
    final bars = (v * 6).round();
    for (var j = 0; j < bars; j++) {
      canvas.drawRect(
        Rect.fromLTWH(x + 12 + i * cw, y + h - 14 - j * ch, cw - 3, ch - 3),
        fxStompFill(c, .5 + j * .08),
      );
    }
  }
}
