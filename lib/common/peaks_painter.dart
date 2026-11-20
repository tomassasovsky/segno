import 'package:material_ui/material_ui.dart';

/// A recorded clip's waveform: one bar per peak, mirrored about the centre,
/// filled in [color] (pen `Recorded audio waveform`). The Library's preview
/// and the Sessions face's draw a saved recording with it.
class PeaksPainter extends CustomPainter {
  /// Creates the painter for [peaks] (0..1) in [color].
  const new({required this.peaks, required this.color});

  /// Absolute peaks across the clip, left to right.
  final List<double> peaks;

  /// The fill.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.isEmpty) return;
    final paint = Paint()..color = color;
    final step = size.width / peaks.length;
    final mid = size.height / 2;
    for (var i = 0; i < peaks.length; i++) {
      final half = peaks[i].clamp(0.0, 1.0) * mid;
      if (half <= 0) continue;
      canvas.drawRect(
        Rect.fromLTRB(i * step, mid - half, (i + 1) * step, mid + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PeaksPainter oldDelegate) =>
      !identical(oldDelegate.peaks, peaks) || oldDelegate.color != color;
}
