import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// Editable pedal artwork using the accepted Fusion-derived 84 by 114 geometry.
/// Interaction and focus belong to the enclosing pedal, not its painted parts.
class PedalHardwareFace extends StatelessWidget {
  /// Creates the hardware face with its physical label.
  const PedalHardwareFace({
    required this.label,
    required this.selected,
    super.key,
  });

  /// The label printed on the nameplate.
  final String label;

  /// Whether the enclosing pedal is being edited.
  final bool selected;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 84 / 114,
    child: CustomPaint(
      painter: _PedalFacePainter(selected: selected),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = constraints.maxWidth / 84;
          return Stack(
            children: [
              Positioned(
                left: 16 * scale,
                right: 16 * scale,
                top: 12 * scale,
                height: 17 * scale,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AppText(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: context.surface.textPrimary,
                        fontFamily: SurfaceTheme.monoFont,
                        fontSize: 11 * scale,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _PedalFacePainter extends CustomPainter {
  /// Creates a [_PedalFacePainter].
  const _PedalFacePainter({required this.selected});

  static const Size _artSize = Size(84, 114);
  static const Rect _namePlateRect = Rect.fromLTRB(
    14.8205,
    10.53,
    69.1795,
    30.43,
  );

  /// See [PedalHardwareFace.selected].
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

  static final Shader _metalShader = _metalGradient(_metal);
  static final Shader _selectedMetalShader = _metalGradient(_metalSelected);
  static final Shader _gripShader = const LinearGradient(
    colors: [_gripTop, _gripBottom],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  ).createShader(Rect.fromCircle(center: Offset.zero, radius: _gripTopRadius));

  static Shader _metalGradient(List<Color> stops) => LinearGradient(
    colors: [stops[0], stops[1], stops[2], stops[1]],
    stops: _metalStops,
  ).createShader(Offset.zero & _artSize);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(
        size.width / _artSize.width,
        size.height / _artSize.height,
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
    for (final hinge in [_leftHinge, _rightHinge]) {
      canvas
        ..drawPath(hinge, fill)
        ..drawPath(hinge, edge);
    }
  }

  /// The body and the two edges rolled over its sides.
  ///
  /// The body is filled AND stroked before the rolled edges go on, which is
  /// the study's order: they lie over the metal's outline where they meet it,
  /// and stroking last would draw that outline back on top of them.
  void _paintBody(Canvas canvas) {
    canvas
      ..drawPath(
        _body,
        Paint()..shader = selected ? _selectedMetalShader : _metalShader,
      )
      ..drawPath(
        _body,
        Paint()
          ..color = selected ? _bodyEdgeSelected : _bodyEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1 : 0.35,
      )
      ..drawPath(_leftRolledEdge, Paint()..color = _rolledLeft)
      ..drawPath(_rightRolledEdge, Paint()..color = _rolledRight);
  }

  void _paintPad(Canvas canvas) {
    final pad = _padOutline;
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
    final plate = _namePlateOutline;
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
    // Every grip shares the cached shader while the canvas moves under it.
    final lit = Paint()..shader = _gripShader;
    for (var row = 0; row < _gripRows; row++) {
      for (var column = 0; column < _gripColumns; column++) {
        final centre = Offset(
          _gripOriginX + (column - (_gripColumns - 1) / 2) * _gripPitchX,
          _gripOriginY + row * _gripPitchY,
        );
        canvas
          ..drawCircle(centre, _gripBaseRadius, base)
          ..save()
          ..translate(centre.dx, centre.dy - _gripLift)
          ..drawCircle(Offset.zero, _gripTopRadius, lit)
          ..drawCircle(Offset.zero, _gripTopRadius, edge)
          ..restore();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // The seven measured outlines from docs/design/pedal-hardware-widget.js.
  // Built once and used without mutation by every rendered face.
  // ---------------------------------------------------------------------------

  static final Path _body = Path()
    ..moveTo(3.825, 2)
    ..lineTo(80.175, 2)
    ..lineTo(78.535, 111.88)
    ..lineTo(5.465, 111.88)
    ..close();

  static final Path _leftRolledEdge = Path()
    ..moveTo(3.825, 2)
    ..lineTo(6.5, 2)
    ..lineTo(8.1, 111.88)
    ..lineTo(5.465, 111.88)
    ..close();

  static final Path _rightRolledEdge = Path()
    ..moveTo(77.5, 2)
    ..lineTo(80.175, 2)
    ..lineTo(78.535, 111.88)
    ..lineTo(75.9, 111.88)
    ..close();

  static final Path _leftHinge = Path()
    ..moveTo(3.8, 20.9)
    ..lineTo(2.7, 20.9)
    ..quadraticBezierTo(0.5, 21.1, 0.5, 24)
    ..lineTo(0.5, 27)
    ..quadraticBezierTo(0.5, 29.1, 2.7, 29.3)
    ..lineTo(3.8, 29.3)
    ..close();

  static final Path _rightHinge = Path()
    ..moveTo(80.2, 20.9)
    ..lineTo(81.3, 20.9)
    ..quadraticBezierTo(83.5, 21.1, 83.5, 24)
    ..lineTo(83.5, 27)
    ..quadraticBezierTo(83.5, 29.1, 81.3, 29.3)
    ..lineTo(80.2, 29.3)
    ..close();

  static final Path _padOutline = Path()
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

  static final Path _namePlateOutline = Path()
    ..moveTo(_namePlateRect.left, _namePlateRect.top)
    ..lineTo(_namePlateRect.right, _namePlateRect.top)
    ..lineTo(68.8775, _namePlateRect.bottom)
    ..lineTo(15.1225, _namePlateRect.bottom)
    ..close();

  @override
  bool shouldRepaint(_PedalFacePainter old) => old.selected != selected;
}
