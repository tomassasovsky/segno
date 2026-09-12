import 'package:flutter/material.dart';

/// The Segno footswitch, drawn to its manufacturing outlines.
///
/// A port of `docs/design/pedal-hardware-widget.js`, which is itself the
/// vector reconstruction of the populated Fusion assembly — the same source
/// the pen's `Hardware / Segno pedal face` component was built from. Keep the
/// three in step; the outlines below are the JS file's path constants
/// transcribed, not traced.
///
/// Drawn rather than shipped as an asset because the face is parametric: the
/// thirty grips are a grid, the selected state is three different metal stops,
/// and an image would carry none of that and would have to be re-exported
/// whenever either moved.
class PedalFace extends StatelessWidget {
  /// Creates a [PedalFace].
  const PedalFace({required this.selected, this.legend, super.key});

  /// Whether this is the switch being edited. The metal brightens and its
  /// edge lights, which is how the study shows it.
  final bool selected;

  /// What the nameplate says. Drawn as type rather than as the silkscreen's
  /// ink outlines, because the map names the channel the ACTIVE BANK drives —
  /// TRACK 5 on bank B — and the plate carries outlines for TRACK1 to TRACK4
  /// only.
  final Widget? legend;

  /// The authoring box every outline below is written in.
  static const Size artSize = Size(84, 114);

  /// The nameplate, in that box: where [legend] goes.
  static const Rect namePlate = Rect.fromLTRB(14.8205, 10.53, 69.1795, 30.43);

  /// The ink the plate's lettering is printed in. Exposed so the caller can
  /// style [legend] without spelling a hardware colour of its own.
  static const Color labelInk = Color(0xFFE4E9EF);

  /// Its aspect: the face is as tall as its box and as wide as that allows.
  static double widthFor(double height) =>
      height * artSize.width / artSize.height;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = constraints.maxWidth / artSize.width;
      return CustomPaint(
        painter: PedalFacePainter(selected: selected),
        child: legend == null
            ? null
            : Stack(
                children: [
                  Positioned(
                    left: namePlate.left * scale,
                    top: namePlate.top * scale,
                    width: namePlate.width * scale,
                    height: namePlate.height * scale,
                    child: Center(child: legend),
                  ),
                ],
              ),
      );
    },
  );
}

/// Paints [PedalFace]. Public so a widget test can assert what it was given.
class PedalFacePainter extends CustomPainter {
  /// Creates a [PedalFacePainter].
  const PedalFacePainter({required this.selected});

  /// See [PedalFace.selected].
  final bool selected;

  // The metal, in two sets of stops. The selected set is the study's: a
  // colder, brighter alloy, so the switch being edited reads at a glance
  // without anything being drawn around it.
  static const _metal = [
    Color(0xFF2B3035),
    Color(0xFF737B83),
    Color(0xFF333A42),
  ];
  static const _metalSelected = [
    Color(0xFF52647B),
    Color(0xFF849AB4),
    Color(0xFF38485E),
  ];
  static const _metalStops = [0.0, 0.18, 0.85, 1.0];

  static const _hinge = Color(0xFF424A53);
  static const _hingeEdge = Color(0xFF777F88);
  static const _bodyEdge = Color(0xFF565F69);
  static const _bodyEdgeSelected = Color(0xFFCBD8E9);
  static const _rolledLeft = Color(0xFF343B43);
  static const _rolledRight = Color(0xFF242A31);
  static const _pad = Color(0xFF191D21);
  static const _padEdge = Color(0xFF13161A);
  static const _namePlate = Color(0xFF20252B);
  static const _namePlateSelected = Color(0xFF273449);
  static const _namePlateEdge = Color(0xFF3B4149);
  static const _gripBase = Color(0xFF101316);
  static const _gripTop = Color(0xFF30353A);
  static const _gripBottom = Color(0xFF202428);
  static const _gripEdge = Color(0xFF383D43);

  /// The grip grid: six rows of five, on the pitch the top pad was moulded to.
  static const _gripColumns = 5;
  static const _gripRows = 6;
  static const _gripPitchX = 11.6373;
  static const _gripPitchY = 12.0;
  static const _gripOriginX = 42.0;
  static const _gripOriginY = 39.47;
  static const _gripBaseRadius = 4.0;
  static const _gripTopRadius = 3.1;

  /// How far the lit face of a grip sits above its base.
  static const _gripLift = 0.18;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(
        size.width / PedalFace.artSize.width,
        size.height / PedalFace.artSize.height,
      );
    // Everything is authored in the 84 x 114 box, so the whole face scales
    // with one transform and no outline has to know its final size.
    _paintHinges(canvas);
    _paintBody(canvas);
    _paintPad(canvas);
    _paintNamePlate(canvas);
    _paintGrips(canvas);
    canvas.restore();
  }

  // A disabled face is dimmed by the CALLER, in one Opacity over the cap, so
  // the lettering goes with it — a face dimmed here would leave its own
  // nameplate reading at full strength.

  void _paintHinges(Canvas canvas) {
    final fill = Paint()..color = _hinge;
    final edge = Paint()
      ..color = _hingeEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.3;
    for (final hinge in [_leftHinge(), _rightHinge()]) {
      canvas
        ..drawPath(hinge, fill)
        ..drawPath(hinge, edge);
    }
  }

  void _paintBody(Canvas canvas) {
    final body = _body();
    final stops = selected ? _metalSelected : _metal;
    canvas
      ..drawPath(
        body,
        Paint()
          ..shader = LinearGradient(
            colors: [stops[0], stops[1], stops[2], stops[1]],
            stops: _metalStops,
          ).createShader(Offset.zero & PedalFace.artSize),
      )
      ..drawPath(_leftRolledEdge(), Paint()..color = _rolledLeft)
      ..drawPath(_rightRolledEdge(), Paint()..color = _rolledRight)
      ..drawPath(
        body,
        Paint()
          ..color = selected ? _bodyEdgeSelected : _bodyEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1 : 0.35,
      );
  }

  void _paintPad(Canvas canvas) {
    final pad = _padOutline();
    canvas
      ..drawPath(pad, Paint()..color = _pad)
      ..drawPath(
        pad,
        Paint()
          ..color = _padEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4,
      );
  }

  void _paintNamePlate(Canvas canvas) {
    final plate = _namePlateOutline();
    canvas
      ..drawPath(
        plate,
        Paint()..color = selected ? _namePlateSelected : _namePlate,
      )
      ..drawPath(
        plate,
        Paint()
          ..color = _namePlateEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.22,
      );
  }

  void _paintGrips(Canvas canvas) {
    final base = Paint()..color = _gripBase;
    final edge = Paint()
      ..color = _gripEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.15;
    for (var row = 0; row < _gripRows; row++) {
      for (var column = 0; column < _gripColumns; column++) {
        final centre = Offset(
          _gripOriginX + (column - (_gripColumns - 1) / 2) * _gripPitchX,
          _gripOriginY + row * _gripPitchY,
        );
        final top = centre.translate(0, -_gripLift);
        final face = Rect.fromCircle(center: top, radius: _gripTopRadius);
        canvas
          ..drawCircle(centre, _gripBaseRadius, base)
          ..drawCircle(
            top,
            _gripTopRadius,
            Paint()
              ..shader = const LinearGradient(
                colors: [_gripTop, _gripBottom],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ).createShader(face),
          )
          ..drawCircle(top, _gripTopRadius, edge);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // The outlines, transcribed from pedal-hardware-widget.js
  // ---------------------------------------------------------------------------

  /// `M3.825 2H80.175L78.535 111.88H5.465Z`
  Path _body() => Path()
    ..moveTo(3.825, 2)
    ..lineTo(80.175, 2)
    ..lineTo(78.535, 111.88)
    ..lineTo(5.465, 111.88)
    ..close();

  /// `M3.825 2H6.5L8.1 111.88H5.465Z`
  Path _leftRolledEdge() => Path()
    ..moveTo(3.825, 2)
    ..lineTo(6.5, 2)
    ..lineTo(8.1, 111.88)
    ..lineTo(5.465, 111.88)
    ..close();

  /// `M77.5 2H80.175L78.535 111.88H75.9Z`
  Path _rightRolledEdge() => Path()
    ..moveTo(77.5, 2)
    ..lineTo(80.175, 2)
    ..lineTo(78.535, 111.88)
    ..lineTo(75.9, 111.88)
    ..close();

  /// `M3.8 20.9H2.7Q.5 21.1 .5 24V27Q.5 29.1 2.7 29.3H3.8Z`
  Path _leftHinge() => Path()
    ..moveTo(3.8, 20.9)
    ..lineTo(2.7, 20.9)
    ..quadraticBezierTo(0.5, 21.1, 0.5, 24)
    ..lineTo(0.5, 27)
    ..quadraticBezierTo(0.5, 29.1, 2.7, 29.3)
    ..lineTo(3.8, 29.3)
    ..close();

  /// `M80.2 20.9H81.3Q83.5 21.1 83.5 24V27Q83.5 29.1 81.3 29.3H80.2Z`
  Path _rightHinge() => Path()
    ..moveTo(80.2, 20.9)
    ..lineTo(81.3, 20.9)
    ..quadraticBezierTo(83.5, 21.1, 83.5, 24)
    ..lineTo(83.5, 27)
    ..quadraticBezierTo(83.5, 29.1, 81.3, 29.3)
    ..lineTo(80.2, 29.3)
    ..close();

  /// `M11.73 5.45H72.27Q74.3 5.45 74.27 7.48L72.78 106.48Q72.75 108.45 70.75
  /// 108.45H13.25Q11.25 108.45 11.22 106.48L9.73 7.48Q9.7 5.45 11.73 5.45Z`
  Path _padOutline() => Path()
    ..moveTo(11.73, 5.45)
    ..lineTo(72.27, 5.45)
    ..quadraticBezierTo(74.3, 5.45, 74.27, 7.48)
    ..lineTo(72.78, 106.48)
    ..quadraticBezierTo(72.75, 108.45, 70.75, 108.45)
    ..lineTo(13.25, 108.45)
    ..quadraticBezierTo(11.25, 108.45, 11.22, 106.48)
    ..lineTo(9.73, 7.48)
    ..quadraticBezierTo(9.7, 5.45, 11.73, 5.45)
    ..close();

  /// `M14.8205 10.53H69.1795L68.8775 30.43H15.1225Z`
  Path _namePlateOutline() => Path()
    ..moveTo(PedalFace.namePlate.left, PedalFace.namePlate.top)
    ..lineTo(PedalFace.namePlate.right, PedalFace.namePlate.top)
    ..lineTo(68.8775, PedalFace.namePlate.bottom)
    ..lineTo(15.1225, PedalFace.namePlate.bottom)
    ..close();

  @override
  bool shouldRepaint(PedalFacePainter old) => old.selected != selected;
}
