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
  const _PedalFacePainter({required this.selected});

  final bool selected;

  // These colors are intrinsic to the accepted hardware artwork, not UI tokens.
  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 84, size.height / 114);
    final body = Path()
      ..moveTo(3.825, 2)
      ..lineTo(80.175, 2)
      ..lineTo(78.535, 111.88)
      ..lineTo(5.465, 111.88)
      ..close();
    final metal = selected
        ? const [Color(0xff52647b), Color(0xff849ab4), Color(0xff38485e)]
        : const [Color(0xff2b3035), Color(0xff737b83), Color(0xff333a42)];
    final fill = Paint()
      ..shader = LinearGradient(
        colors: [...metal, metal[1]],
        stops: const [0, .18, .85, 1],
      ).createShader(const Rect.fromLTWH(0, 0, 84, 114));
    for (final x in [0.5, 79.5]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 20.9, 4, 8.4),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xff424a53),
      );
    }
    canvas
      ..drawPath(body, fill)
      ..drawPath(
        body,
        Paint()
          ..color = selected ? const Color(0xffcbd8e9) : const Color(0xff565f69)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1 : .35,
      );
    final pad = Path()
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
    canvas.drawPath(pad, Paint()..color = const Color(0xff191d21));
    final nameplate = Path()
      ..moveTo(14.8205, 10.53)
      ..lineTo(69.1795, 10.53)
      ..lineTo(68.8775, 30.43)
      ..lineTo(15.1225, 30.43)
      ..close();
    canvas
      ..drawPath(
        nameplate,
        Paint()
          ..color = selected
              ? const Color(0xff273449)
              : const Color(0xff20252b),
      )
      ..drawPath(
        nameplate,
        Paint()
          ..color = const Color(0xff3b4149)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .22,
      );
    for (var row = 0; row < 6; row++) {
      for (var column = 0; column < 5; column++) {
        final center = Offset(42 + (column - 2) * 11.6373, 39.47 + row * 12);
        canvas
          ..drawCircle(center, 4, Paint()..color = const Color(0xff101316))
          ..drawCircle(
            center.translate(0, -.18),
            3.1,
            Paint()
              ..shader = const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xff30353a), Color(0xff202428)],
              ).createShader(Rect.fromCircle(center: center, radius: 3.1)),
          );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PedalFacePainter oldDelegate) =>
      oldDelegate.selected != selected;
}
