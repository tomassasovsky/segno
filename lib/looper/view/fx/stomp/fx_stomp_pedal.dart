import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_graphics.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_textures.dart';
import 'package:segno/theme/theme.dart';

/// A catalogue pedal, drawn in code from its [face] (the approved pedal
/// design, #1501).
///
/// The pedal keeps its face's proportions and scales to fit the space its
/// parent gives it. Every part is laid out in the face's fixed drawing space
/// and the whole is scaled. The enclosure is recorded once per look and
/// replayed; each knob paints on its own layer, so turning one repaints only
/// that knob.
class FxStompPedal extends StatelessWidget {
  /// Creates an [FxStompPedal].
  const FxStompPedal({required this.face, super.key});

  /// What the pedal shows.
  final FxStompFace face;

  @override
  Widget build(BuildContext context) {
    final spec = face.spec;
    final kind = spec.face;
    final knobs = face.knobs.take(kind.maxKnobs).toList();
    final spots = _KnobSpot.layout(kind, knobs.length);
    final textures = FxStompTextures.instance;
    unawaited(textures.load());
    return RepaintBoundary(
      // A picture: the name and the controls it shows are on the surface
      // around it, which is what a screen reader reads.
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: kind.size.aspectRatio,
          child: FittedBox(
            child: SizedBox.fromSize(
              size: kind.size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EnclosurePainter(
                        spec: spec,
                        lit: face.lit,
                        knobs: knobs.length,
                        textures: textures.images,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _LabelsPainter(
                        labels: [for (final knob in knobs) knob.label],
                        spots: spots,
                        colour: kind == FxStompFaceKind.window
                            ? spec.panelInk
                            : spec.bodyInk,
                      ),
                    ),
                  ),
                  for (final (i, knob) in knobs.indexed)
                    _StompKnob(
                      spec: spec,
                      spot: spots[i],
                      setting: knob.setting,
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

/// Where a knob sits on a face, and where its label prints.
class _KnobSpot {
  const _KnobSpot(this.centre, this.radius, this.labelBaseline, this.labelSize);

  final Offset centre;
  final double radius;
  final double labelBaseline;
  final double labelSize;

  /// The design's `place_knobs()`: [count] knobs in rows of [cols], each row
  /// centred on [cx], [dx] apart, rows [dy] apart from [top].
  static List<Offset> _place(
    int count,
    double cx,
    double top,
    int cols,
    double dx,
    double dy,
  ) => [
    for (var i = 0; i < count; i++)
      Offset(
        cx -
            dx * (math.min(cols, count - i ~/ cols * cols) - 1) / 2 +
            dx * (i % cols),
        top + dy * (i ~/ cols),
      ),
  ];

  /// Every knob spot of a [kind] face holding [count] knobs.
  static List<_KnobSpot> layout(FxStompFaceKind kind, int count) {
    if (count == 0) return const [];
    _KnobSpot under(Offset c, double r) => _KnobSpot(c, r, c.dy + r + 26, 14);
    switch (kind) {
      case FxStompFaceKind.treadle:
        final r = const {1: 44.0, 2: 42.0, 3: 36.0, 4: 31.0}[count]!;
        final dx = const {1: 0.0, 2: 174.0, 3: 121.0, 4: 91.0}[count]!;
        return [for (final c in _place(count, 225, 136, 4, dx, 0)) under(c, r)];
      case FxStompFaceKind.box:
        if (count <= 3) {
          final r = const {1: 42.0, 2: 40.0, 3: 34.0}[count]!;
          return [
            for (final c in _place(count, 225, 150, 3, 125, 0)) under(c, r),
          ];
        }
        return [
          for (final c in _place(
            count,
            225,
            128,
            count > 4 ? 3 : 2,
            count > 4 ? 125 : 170,
            112,
          ))
            under(c, 30),
        ];
      case FxStompFaceKind.window:
        final r = count <= 3 ? 36.0 : 32.0;
        const spots = {
          1: [Offset(225, 200)],
          2: [Offset(160, 200), Offset(290, 200)],
          3: [Offset(150, 160), Offset(300, 160), Offset(225, 270)],
          4: [
            Offset(150, 160),
            Offset(300, 160),
            Offset(150, 285),
            Offset(300, 285),
          ],
        };
        return [for (final c in spots[count]!) under(c, r)];
      case FxStompFaceKind.module:
        return [
          for (final c in _place(count, 225, 400, 2, 180, 150))
            _KnobSpot(c, 38, c.dy + 82, 16),
        ];
      case FxStompFaceKind.rocker:
        return const [];
    }
  }
}

/// The labels under the knobs.
class _LabelsPainter extends CustomPainter {
  _LabelsPainter({
    required this.labels,
    required this.spots,
    required this.colour,
  });

  final List<String> labels;
  final List<_KnobSpot> spots;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, label) in labels.indexed) {
      final spot = spots[i];
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            fontWeight: FontWeight.w700,
            fontSize: spot.labelSize,
            letterSpacing: 1.5,
            color: colour.withValues(alpha: .9),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      // Shrunk to the space beside it rather than run into the next label.
      final scale = math.min(1, _room(spot) / painter.width).toDouble();
      final ascent = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      canvas
        ..save()
        ..translate(spot.centre.dx, spot.labelBaseline)
        ..scale(scale)
        ..translate(-painter.width / 2, -ascent);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
      painter.dispose();
    }
  }

  /// The width a label at [spot] has: the gap to its nearest neighbour on
  /// the same row.
  double _room(_KnobSpot spot) {
    var room = 200.0;
    for (final other in spots) {
      if (identical(other, spot) || other.centre.dy != spot.centre.dy) continue;
      room = math.min(room, (other.centre.dx - spot.centre.dx).abs() - 8);
    }
    return room;
  }

  @override
  bool shouldRepaint(_LabelsPainter oldDelegate) {
    if (oldDelegate.colour != colour) return true;
    if (oldDelegate.labels.length != labels.length) return true;
    for (var i = 0; i < labels.length; i++) {
      if (oldDelegate.labels[i] != labels[i]) return true;
    }
    return false;
  }
}

/// One knob, on its own layer.
class _StompKnob extends StatelessWidget {
  const _StompKnob({
    required this.spec,
    required this.spot,
    required this.setting,
  });

  final FxStompSpec spec;
  final _KnobSpot spot;
  final double setting;

  @override
  Widget build(BuildContext context) {
    final r = spot.radius;
    return Positioned(
      left: spot.centre.dx - r,
      top: spot.centre.dy - r,
      width: r * 2,
      height: r * 2,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _KnobPainter(
            style: spec.knob,
            cap: spec.knobCap,
            accent: spec.accent,
            setting: setting,
          ),
        ),
      ),
    );
  }
}

/// The paints of one knob look at one radius, built once.
final class _KnobParts {
  /// The parts for a knob with a [cap] colour at radius [r].
  factory _KnobParts.of(double r, Color? cap) =>
      _cache.putIfAbsent((r, cap), () => _KnobParts._(r, cap));

  _KnobParts._(this.r, Color? cap) {
    final c = Offset(r, r);
    Shader radial(
      double radius,
      Offset at,
      double reach,
      List<Color> colors,
      List<double> stops,
    ) => fxStompBoxRadial(
      Rect.fromCircle(center: c, radius: radius),
      at,
      reach,
      colors,
      stops,
    );
    skirt = Paint()
      ..shader = radial(
        r,
        const Offset(.4, .35),
        .75,
        const [
          Color(0xFF3B4048),
          Color(0xFF121418),
        ],
        const [0, 1],
      );
    capPaint = Paint()
      ..shader = radial(
        r * .74,
        const Offset(.38, .3),
        .8,
        const [
          Color(0xFF4D535D),
          Color(0xFF262A30),
          Color(0xFF16181C),
        ],
        const [0, .6, 1],
      );
    dome = Paint()
      ..shader = radial(
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
    cream = Paint()
      ..shader = radial(
        r * .8,
        const Offset(.36, .3),
        .85,
        _cream,
        _creamStops,
      );
    chickenCream = Paint()
      ..shader = fxStompBoxRadial(
        Rect.fromLTRB(-r * .55, -r * 1.05, r * .55, r * .8),
        const Offset(.36, .3),
        .85,
        _cream,
        _creamStops,
      );
    colourCap = Paint()..color = cap ?? const Color(0xFF808080);
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30;
      final d = Offset(math.cos(a), math.sin(a));
      ridges
        ..moveTo(c.dx + d.dx * (r - 6), c.dy + d.dy * (r - 6))
        ..lineTo(c.dx + d.dx * (r - .5), c.dy + d.dy * (r - .5));
    }
    chicken = Path()
      ..moveTo(0, -r * 1.05)
      ..cubicTo(r * .32, -r * .6, r * .55, r * .1, r * .45, r * .5)
      ..cubicTo(r * .3, r * .8, -r * .3, r * .8, -r * .45, r * .5)
      ..cubicTo(-r * .55, r * .1, -r * .32, -r * .6, 0, -r * 1.05)
      ..close();
    shadow = Rect.fromCenter(
      center: c + Offset(0, r * .35),
      width: r * 2.1,
      height: r * 2,
    );
  }

  static final Map<(double, Color?), _KnobParts> _cache = {};

  static const List<Color> _cream = [
    Color(0xFFFFFAF0),
    Color(0xFFEADFC6),
    Color(0xFFA99A7C),
  ];
  static const List<double> _creamStops = [0, .55, 1];

  final double r;
  late final Paint skirt;
  late final Paint capPaint;
  late final Paint dome;
  late final Paint cream;
  late final Paint chickenCream;
  late final Paint colourCap;
  final Path ridges = Path();
  late final Path chicken;
  late final Rect shadow;

  final Paint shadowFill = Paint()
    ..color = const Color(0x66000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  final Paint base = Paint()..color = const Color(0xFF0B0C0E);
  final Paint domeRim = Paint()..color = const Color(0xFF101114);
  final Paint creamSkirt = Paint()..color = const Color(0xFF1D1F23);
  final Paint ridgeLine = Paint()
    ..color = const Color(0x8C000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6;
  final Paint chickenLine = Paint()
    ..color = const Color(0x66000000)
    ..style = PaintingStyle.stroke;
  final Paint chickenMark = Paint()
    ..color = const Color(0xFF1A1C20)
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round;
  final Paint glint = Paint()..color = const Color(0x40FFFFFF);
}

/// A knob in one of the design's styles, filling its square box.
class _KnobPainter extends CustomPainter {
  _KnobPainter({
    required this.style,
    required this.cap,
    required this.accent,
    required this.setting,
  });

  final FxStompKnobStyle style;
  final Color? cap;
  final Color accent;

  /// Where it points, from 0 (fully left) to 1 (fully right).
  final double setting;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final parts = _KnobParts.of(r, cap);
    final c = Offset(r, r);
    final degrees = (setting.clamp(0.0, 1.0) - .5) * 270;
    final a = (degrees - 90) * math.pi / 180;
    final d = Offset(math.cos(a), math.sin(a));
    void pointer(Color colour, double width) => canvas.drawLine(
      c + d * (r * .18),
      c + d * (r * .8),
      Paint()
        ..color = colour
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawOval(parts.shadow, parts.shadowFill);
    switch (style) {
      case FxStompKnobStyle.black:
        canvas
          ..drawCircle(c + const Offset(0, 3), r, parts.base)
          ..drawCircle(c, r, parts.skirt)
          ..drawPath(parts.ridges, parts.ridgeLine)
          ..drawCircle(c, r * .74, parts.capPaint);
        pointer(accent, math.max(3, r * .11));
      case FxStompKnobStyle.dome:
        canvas
          ..drawCircle(c, r + 3, parts.domeRim)
          ..drawCircle(c, r, parts.dome);
        pointer(const Color(0xFF1A1C20), math.max(3, r * .12));
      case FxStompKnobStyle.cream:
        canvas
          ..drawCircle(c + const Offset(0, 3), r + 4, parts.base)
          ..drawCircle(c, r + 4, parts.creamSkirt)
          ..drawCircle(c, r * .8, parts.cream);
        pointer(const Color(0xFF1A1C20), math.max(3, r * .1));
      case FxStompKnobStyle.chicken:
        canvas
          ..drawCircle(c + const Offset(0, 3), r * .62, parts.base)
          ..save()
          ..translate(c.dx, c.dy)
          ..rotate(degrees * math.pi / 180)
          ..drawPath(parts.chicken, parts.chickenCream)
          ..drawPath(parts.chicken, parts.chickenLine)
          ..drawLine(
            Offset(0, -r * .95),
            Offset(0, -r * .35),
            parts.chickenMark,
          )
          ..restore();
      case FxStompKnobStyle.cap:
        canvas
          ..drawCircle(c + const Offset(0, 3), r, parts.base)
          ..drawCircle(c, r, parts.skirt)
          ..drawCircle(c, r * .62, parts.colourCap)
          ..drawCircle(c + Offset(-r * .15, -r * .2), r * .3, parts.glint);
        pointer(const Color(0xFFF4F6F8), math.max(3, r * .1));
    }
  }

  @override
  bool shouldRepaint(_KnobPainter oldDelegate) =>
      oldDelegate.setting != setting ||
      oldDelegate.style != style ||
      oldDelegate.cap != cap ||
      oldDelegate.accent != accent;
}

/// What an enclosure picture is recorded for.
typedef _EnclosureKey = ({
  FxStompSpec spec,
  bool lit,
  int knobs,
  bool textured,
});

/// The enclosure: everything but the knobs and their labels, recorded once
/// per look ([_EnclosureKey]) and replayed.
class _EnclosurePainter extends CustomPainter {
  _EnclosurePainter({
    required this.spec,
    required this.lit,
    required this.knobs,
    required this.textures,
  }) : super(repaint: textures);

  final FxStompSpec spec;
  final bool lit;
  final int knobs;
  final ValueNotifier<Map<FxStompFinish, ui.Image>> textures;

  static final Map<_EnclosureKey, ui.Picture> _pictures = {};

  @override
  void paint(Canvas canvas, Size size) {
    final texture = textures.value[spec.finish];
    final key = (spec: spec, lit: lit, knobs: knobs, textured: texture != null);
    canvas.drawPicture(
      _pictures.putIfAbsent(key, () {
        final recorder = ui.PictureRecorder();
        _Enclosure(
          Canvas(recorder),
          spec,
          lit: lit,
          knobs: knobs,
          texture: texture,
        ).paint();
        return recorder.endRecording();
      }),
    );
  }

  @override
  bool shouldRepaint(_EnclosurePainter oldDelegate) =>
      !identical(oldDelegate.spec, spec) ||
      oldDelegate.lit != lit ||
      oldDelegate.knobs != knobs;
}

/// Draws one enclosure, as the design's face functions do.
class _Enclosure {
  _Enclosure(
    this.canvas,
    this.spec, {
    required this.lit,
    required this.knobs,
    required this.texture,
  });

  final Canvas canvas;
  final FxStompSpec spec;
  final bool lit;
  final int knobs;
  final ui.Image? texture;

  Color get ink => spec.bodyInk;

  void paint() {
    switch (spec.face) {
      case FxStompFaceKind.treadle:
        _treadle();
      case FxStompFaceKind.box:
        _box();
      case FxStompFaceKind.window:
        _window();
      case FxStompFaceKind.module:
        _module();
      case FxStompFaceKind.rocker:
        _rocker();
    }
  }

  static Paint _fill(Color colour, [double opacity = 1]) =>
      Paint()..color = colour.withValues(alpha: colour.a * opacity);

  static Paint _blur(Color colour, double opacity, double sigma) =>
      _fill(colour, opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

  static Paint _line(Color colour, double width, [double opacity = 1]) =>
      _fill(colour, opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width;

  static Shader _metal(Rect r) => fxStompBoxRadial(
    r,
    const Offset(.35, .3),
    .8,
    const [Color(0xFFF2F4F6), Color(0xFFA7ADB5), Color(0xFF6C727A)],
    const [0, .6, 1],
  );

  static Shader _dome(Rect r) => fxStompBoxRadial(
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

  static Shader _metalV(Rect r) => fxStompBoxLinear(
    r,
    Offset.zero,
    const Offset(0, 1),
    const [Color(0xFFD9DDE2), Color(0xFF8C9299), Color(0xFF5D636A)],
    const [0, .5, 1],
  );

  static Shader _rubber(Rect r) => fxStompBoxLinear(
    r,
    Offset.zero,
    const Offset(0, 1),
    const [Color(0xFF16181C), Color(0xFF23262C), Color(0xFF1B1D22)],
    const [0, .12, 1],
  );

  static Shader _sheen(Rect r, [double opacity = 1]) => fxStompBoxRadial(
    r,
    const Offset(.28, .08),
    .75,
    [
      Colors.white.withValues(alpha: .38 * opacity),
      Colors.white.withValues(alpha: .06 * opacity),
      Colors.white.withValues(alpha: 0),
    ],
    const [0, .5, 1],
  );

  /// The design's `body()`: the shadow, the finished body with its picture,
  /// the side shading and sheen, and the bevel.
  void _body(Rect r, double rx, {Rect? art}) {
    final shape = RRect.fromRectAndRadius(r, Radius.circular(rx));
    final base = spec.base;
    final base2 = spec.base2;
    final (colors, stops, to) = switch (spec.finish) {
      FxStompFinish.split when base2 != null => (
        [fxStompShade(base, .08), base, base2, fxStompShade(base2, -.1)],
        const <double>[0, .5, .5, 1],
        const Offset(1, 1),
      ),
      FxStompFinish.fade when base2 != null => (
        [base2, base],
        const <double>[0, 1],
        const Offset(0, 1),
      ),
      _ => (
        [fxStompShade(base, .10), base, fxStompShade(base, -.12)],
        const <double>[0, .55, 1],
        const Offset(0, 1),
      ),
    };
    canvas
      ..drawOval(
        Rect.fromCenter(
          center: Offset(r.center.dx, r.bottom + 8),
          width: r.width - 40,
          height: 28,
        ),
        _blur(Colors.black, .35, 4),
      )
      ..drawRRect(
        shape,
        Paint()..shader = fxStompBoxLinear(r, Offset.zero, to, colors, stops),
      )
      ..save()
      ..clipRRect(shape);
    _texture(r);
    if (art != null && !fxStompGraphicOnTreadle(spec.graphic)) {
      paintFxStompGraphic(canvas, spec.graphic, art, spec);
    }
    canvas
      ..drawRect(
        r,
        Paint()
          ..shader = fxStompBoxLinear(
            r,
            Offset.zero,
            const Offset(1, 0),
            [
              Colors.black.withValues(alpha: .28),
              Colors.black.withValues(alpha: 0),
              Colors.black.withValues(alpha: 0),
              Colors.black.withValues(alpha: .32),
            ],
            const [0, .08, .92, 1],
          ),
      )
      ..drawRect(r, Paint()..shader = _sheen(r))
      ..restore()
      ..drawRRect(
        RRect.fromRectAndRadius(r.deflate(1.5), Radius.circular(rx - 1)),
        _line(Colors.white, 2, .28),
      );
  }

  /// The finish's texture tile, repeated over [r], at the design's opacity.
  void _texture(Rect r) {
    final image = texture;
    if (image == null) return;
    final opacity = switch (spec.finish) {
      FxStompFinish.flake => .55,
      FxStompFinish.hammer => .5,
      FxStompFinish.marble => .9,
      _ => 1.0,
    };
    final scale = FxStompTextures.scales[spec.finish] ?? 1;
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          (Matrix4.identity()..scaleByDouble(scale, scale, 1, 1)).storage,
          filterQuality: FilterQuality.medium,
        ),
    );
  }

  void _screw(Offset at) {
    final head = at - const Offset(0, .5);
    canvas
      ..drawCircle(at, 7.5, _fill(Colors.black, .25))
      ..drawCircle(
        head,
        6.5,
        Paint()..shader = _metal(Rect.fromCircle(center: head, radius: 6.5)),
      )
      ..drawLine(
        at + const Offset(-4, 2),
        at + const Offset(4, -3),
        _line(const Color(0xFF55595F), 1.8)..strokeCap = StrokeCap.round,
      );
  }

  void _led(Offset at) {
    final colour = spec.led;
    if (lit) canvas.drawCircle(at, 15, _blur(colour, .55, 5));
    final Paint lens;
    if (lit) {
      lens = Paint()
        ..shader = fxStompBoxRadial(
          Rect.fromCircle(center: at, radius: 6),
          const Offset(.4, .35),
          .7,
          [Colors.white, colour, fxStompShade(colour, -.25)],
          const [0, .45, 1],
        );
    } else {
      lens = _fill(fxStompShade(colour, -.38));
    }
    canvas
      ..drawCircle(
        at,
        9,
        Paint()..shader = _metal(Rect.fromCircle(center: at, radius: 9)),
      )
      ..drawCircle(at, 6, lens)
      ..drawCircle(at - const Offset(2, 2), 1.8, _fill(Colors.white, .8));
  }

  /// The segno mark, at [at], [scale] times its drawn size.
  void _logo(Offset at, double scale, Color colour, [double opacity = 1]) {
    final stroke = _line(colour, 5, opacity)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = _fill(colour, opacity);
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..scale(scale)
      ..drawPath(
        Path()
          ..moveTo(10, -18)
          ..cubicTo(0, -26, -16, -20, -12, -8)
          ..cubicTo(-8, 2, 12, 0, 12, 12)
          ..cubicTo(12, 24, -6, 26, -12, 18)
          ..moveTo(-20, 20)
          ..lineTo(20, -20),
        stroke,
      )
      ..drawCircle(const Offset(-16, -4), 2.6, dot)
      ..drawCircle(const Offset(16, 4), 2.6, dot)
      ..restore();
  }

  void _stompSwitch(Offset c, [double r = 34]) {
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = (30 + 60 * i) * math.pi / 180;
      final p = c + Offset(math.cos(a), math.sin(a)) * (r + 14);
      if (i == 0) {
        hex.moveTo(p.dx, p.dy);
      } else {
        hex.lineTo(p.dx, p.dy);
      }
    }
    hex.close();
    canvas
      ..drawCircle(c + const Offset(0, 6), r + 16, _blur(Colors.black, .35, 4))
      ..drawPath(
        hex,
        Paint()..shader = _metal(Rect.fromCircle(center: c, radius: r + 14)),
      )
      ..drawPath(hex, _line(Colors.black, 1, .35))
      ..drawCircle(c + const Offset(0, 4), r, _fill(const Color(0xFF3A3E44)))
      ..drawCircle(
        c,
        r,
        Paint()..shader = _dome(Rect.fromCircle(center: c, radius: r)),
      )
      ..drawCircle(c, r * .62, _line(Colors.black, 2, .15));
  }

  /// A round footswitch: a dark well and a dome lifted [lift] in it.
  void _domeSwitch(Offset c, double outer, double inner, double lift) {
    final top = c - Offset(0, lift);
    canvas
      ..drawCircle(c, outer, _fill(const Color(0xFF0D0E10)))
      ..drawCircle(
        top,
        inner,
        Paint()..shader = _dome(Rect.fromCircle(center: top, radius: inner)),
      );
  }

  /// The design's `title()`: the name centred on [x], its baseline on [y],
  /// turned by [tilt] degrees (the spec's own when not given).
  void _title(double x, double y, {double? tilt}) {
    final turn = tilt ?? spec.tilt;
    final style = TextStyle(
      fontFamily: spec.font,
      fontSize: spec.size,
      fontWeight: spec.bold ? FontWeight.w700 : FontWeight.w400,
    );
    canvas
      ..save()
      ..translate(x, y)
      ..rotate(turn * math.pi / 180)
      ..translate(-x, -y);
    final outline = spec.outline;
    if (outline != null) {
      fxStompPaintText(
        canvas,
        spec.name,
        Offset(x, y),
        style.copyWith(
          foreground: Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..strokeJoin = StrokeJoin.round,
        ),
      );
    }
    fxStompPaintText(
      canvas,
      spec.name,
      Offset(x, y),
      style.copyWith(
        color: ink,
        shadows: [
          Shadow(
            offset: const Offset(0, 1.5),
            blurRadius: 1.2,
            color: Colors.black.withValues(alpha: .35),
          ),
        ],
      ),
    );
    canvas.restore();
  }

  RRect _rounded(double x, double y, double w, double h, double r) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));

  void _treadle() {
    const tread = Rect.fromLTWH(32, 298, 386, 334);
    final treadShape = RRect.fromRectAndRadius(
      tread,
      const Radius.circular(22),
    );
    for (final jack in const [
      Rect.fromLTWH(6, 96, 18, 44),
      Rect.fromLTWH(426, 96, 18, 44),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(jack, const Radius.circular(3)),
        Paint()..shader = _metalV(jack),
      );
    }
    _body(
      const Rect.fromLTWH(24, 14, 402, 626),
      30,
      art: const Rect.fromLTWH(24, 14, 402, 284),
    );
    _screw(const Offset(52, 44));
    _screw(const Offset(398, 44));
    _led(const Offset(225, 52));
    canvas
      ..drawRRect(_rounded(30, 292, 390, 8, 4), _fill(Colors.black, .45))
      ..drawRRect(
        treadShape,
        Paint()
          ..shader = fxStompBoxLinear(
            tread,
            Offset.zero,
            const Offset(0, 1),
            [spec.base, fxStompShade(spec.base, -.2)],
            const [0, 1],
          ),
      );
    if (fxStompGraphicOnTreadle(spec.graphic)) {
      canvas
        ..save()
        ..clipRRect(treadShape);
      paintFxStompGraphic(
        canvas,
        spec.graphic,
        const Rect.fromLTWH(32, 298, 386, 130),
        spec,
      );
      canvas.restore();
    }
    canvas
      ..drawRRect(treadShape, Paint()..shader = _sheen(tread, .5))
      ..drawRRect(_rounded(33, 299, 384, 332, 21), _line(Colors.white, 2, .22));
    _title(225, spec.titleY ?? 392);
    const pad = Rect.fromLTWH(62, 432, 326, 178);
    canvas
      ..drawRRect(
        _rounded(58, 428, 334, 186, 16),
        _fill(const Color(0xFF0D0E10)),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(pad, const Radius.circular(13)),
        Paint()..shader = _rubber(pad),
      );
    const badge = Offset(225, 521);
    final ribs = Path();
    for (var row = 0, y = 452.0; y < 600; row++, y += 15) {
      for (var x = 80.0 + (row.isOdd ? 15 : 0); x < 362; x += 30) {
        if ((Offset(x + 13, y + 3.5) - badge).distance <= 54) continue;
        ribs.addRRect(
          RRect.fromLTRBR(x, y, x + 26, y + 7, const Radius.circular(3.5)),
        );
      }
    }
    canvas
      ..drawPath(ribs, _fill(const Color(0xFF2C3037)))
      ..drawCircle(badge, 45, _fill(const Color(0xFF0D0E10)))
      ..drawCircle(
        badge,
        41,
        Paint()..shader = _metal(Rect.fromCircle(center: badge, radius: 41)),
      );
    _logo(badge, 1.25, const Color(0xFF2A2E34));
    canvas.drawRRect(_rounded(24, 626, 402, 14, 6), _fill(Colors.black, .3));
  }

  void _box() {
    const body = Rect.fromLTWH(30, 14, 390, 626);
    _body(body, 46, art: body);
    _logo(const Offset(225, 58), .7, ink, .9);
    _led(const Offset(345, 58));
    _title(225, spec.titleY ?? (knobs > 3 ? 420 : 395));
    _stompSwitch(const Offset(225, 548));
  }

  void _window() {
    const panel = Rect.fromLTWH(66, 50, 318, 300);
    final panelShape = RRect.fromRectAndRadius(
      panel,
      const Radius.circular(44),
    );
    final colour = spec.panel ?? spec.base;
    _body(const Rect.fromLTWH(30, 14, 390, 724), 70);
    canvas
      ..drawRRect(_rounded(70, 56, 310, 300, 44), _blur(Colors.black, .35, 4))
      ..drawRRect(
        panelShape,
        Paint()
          ..shader = fxStompBoxLinear(
            panel,
            Offset.zero,
            const Offset(1, 1),
            [fxStompShade(colour, .08), fxStompShade(colour, -.08)],
            const [0, 1],
          ),
      )
      ..save()
      ..clipRRect(panelShape);
    paintFxStompGraphic(canvas, spec.graphic, panel, spec);
    canvas
      ..restore()
      ..drawRRect(_rounded(67, 51, 316, 298, 43), _line(Colors.white, 2, .35))
      ..drawRRect(panelShape, Paint()..shader = _sheen(panel, .7));
    _logo(const Offset(225, 80), .55, spec.panelInk, .7);
    _title(225, spec.titleY ?? 470);
    _led(const Offset(225, 525));
    _stompSwitch(const Offset(225, 632));
  }

  void _module() {
    _body(const Rect.fromLTWH(40, 14, 370, 970), 14);
    const [
      Offset(72, 46),
      Offset(378, 46),
      Offset(72, 952),
      Offset(378, 952),
    ].forEach(_screw);
    _title(225, 122, tilt: 0);
    paintFxStompScreen(
      canvas,
      const Rect.fromLTWH(80, 160, 290, 150),
      spec.display,
    );
    // The scale around each knob.
    final tick = _line(ink, 2.2, .75)..strokeCap = StrokeCap.round;
    for (final spot in _KnobSpot.layout(FxStompFaceKind.module, knobs)) {
      for (var i = 0; i < 11; i++) {
        final a = (-225 + i * 27) * math.pi / 180;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(
          spot.centre + d * 47,
          spot.centre + d * (i % 5 == 0 ? 56 : 52),
          tick,
        );
      }
    }
    _led(const Offset(225, 860));
    _domeSwitch(const Offset(225, 912), 24, 19, 2);
    _logo(const Offset(345, 905), .55, ink, .6);
  }

  void _rocker() {
    _body(
      const Rect.fromLTWH(30, 14, 390, 744),
      26,
      art: const Rect.fromLTWH(322, 14, 98, 744),
    );
    const rubber = Rect.fromLTWH(60, 38, 254, 552);
    canvas
      ..drawRRect(_rounded(58, 40, 262, 560, 20), _blur(Colors.black, .55, 4))
      ..drawRRect(
        _rounded(56, 34, 262, 560, 20),
        _fill(const Color(0xFF0D0E10)),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(rubber, const Radius.circular(17)),
        Paint()..shader = _rubber(rubber),
      );
    final ribs = Path();
    for (var row = 0, y = 70.0; y < 560; row++, y += 16) {
      for (var x = 78.0 + (row.isOdd ? 13 : 0); x < 300; x += 26) {
        ribs.addRRect(
          RRect.fromLTRBR(x, y, x + 22, y + 7, const Radius.circular(3.5)),
        );
      }
    }
    const bar = Rect.fromLTWH(56, 560, 262, 34);
    canvas
      ..drawPath(ribs, _fill(const Color(0xFF2C3037)))
      ..saveLayer(bar.inflate(1), _fill(Colors.white, .85))
      ..drawRRect(
        RRect.fromRectAndRadius(bar, const Radius.circular(12)),
        Paint()..shader = _metalV(bar),
      )
      ..restore();
    _title(392, 330, tilt: -90);
    _logo(const Offset(372, 640), .9, ink, .85);
    _led(const Offset(372, 700));
    _domeSwitch(const Offset(188, 686), 34, 29, 2);
  }
}
