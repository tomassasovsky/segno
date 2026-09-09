import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// Paints a mirrored, centered loop waveform from peak [samples] (index 0 =
/// loop start, each in `0..1`) with a white playhead bar at [progress]
/// (`0..1`), and — when [bars] is set — the bar ruler of the accepted stage:
/// a faint line at every bar with its number in the bottom-left corner of
/// the bar. The stroke colour comes from the active [LooperTheme]'s waveform
/// table, keyed by [state]. Repaints on a new list or progress is supplied.
class WaveformView extends StatelessWidget {
  /// Creates a [WaveformView].
  const WaveformView({
    required this.samples,
    required this.state,
    this.progress = 0,
    this.bars = 0,
    this.semanticLabel,
    super.key,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`; the white bar is hidden when `<= 0`.
  final double progress;

  /// Whole bars across the loop, for the ruler; `0` draws no ruler (no tempo
  /// grid counts them, or nothing is recorded).
  final int bars;

  /// The transport state the stroke colour speaks for. Required: the
  /// waveform is part of the transport legend, so there is no such thing as
  /// "the waveform colour" without a state to resolve it against.
  final LooperMeterState state;

  /// Accessible name for the otherwise-opaque waveform (WCAG 1.1.1). When set,
  /// the view is exposed to screen readers with this label and a playhead-
  /// position value; null leaves it decorative (the caller supplies the locale-
  /// resolved string, since this widget can run in a window without l10n).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>();
    // Paint the themed backdrop here rather than leaving it to each caller: the
    // state colours carry alpha, so what sits behind them decides what they
    // actually render as — and the contrast floors in `test/theme/` are
    // measured against this token.
    final background = looper?.waveformBackground ?? Colors.black;
    // Null-guarded like the LooperTheme above: this view also runs in the
    // second window, which is a separate engine.
    final surface = theme.extension<SurfaceTheme>();
    final paint = CustomPaint(
      key: const Key('waveform_view_paint'),
      painter: WaveformPainter(
        samples: samples,
        progress: progress,
        bars: bars,
        color: looper?.waveformColor(state) ?? Colors.tealAccent,
        background: background,
      ),
      size: Size.infinite,
    );
    // The ruler is its own layer under the wave: the playhead repaints the
    // wave every poll, and the ruler's bar labels are laid-out text that
    // must not be re-shaped at frame rate for a fact (the bar count) that
    // changes once per take.
    final ruler = bars > 0
        ? RepaintBoundary(
            child: CustomPaint(
              key: const Key('waveform_view_ruler'),
              painter: BarRulerPainter(
                bars: bars,
                color: surface?.textMuted ?? Colors.grey,
              ),
              size: Size.infinite,
            ),
          )
        : null;
    return Semantics(
      label: semanticLabel,
      value: '${(progress.clamp(0.0, 1.0) * 100).round()}%',
      child: ColoredBox(
        color: background,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ?ruler,
            RepaintBoundary(child: paint),
          ],
        ),
      ),
    );
  }
}

/// The [CustomPainter] backing [WaveformView]; public so it can be unit-tested.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({
    required this.samples,
    required this.color,
    required this.background,
    this.progress = 0,
    this.bars = 0,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`.
  final double progress;

  /// Whole bars across the loop; `> 0` leaves [rulerHeight] free at the
  /// bottom for the [BarRulerPainter] layer under this one.
  final int bars;

  /// Waveform color.
  final Color color;

  /// The surface the waveform is drawn on. Used to cut the playhead free of
  /// the bars — see [paint].
  final Color background;

  /// The ruler's reserved strip under the waveform, for the bar numbers.
  static const double rulerHeight = 28;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final ruler = bars > 0;
    final waveHeight = ruler ? size.height - rulerHeight : size.height;
    if (waveHeight <= 0) return;
    final midY = waveHeight / 2;

    // A faint baseline so the surface reads as "ready" even with no audio.
    canvas.drawRect(
      Rect.fromLTWH(0, midY - 0.5, size.width, 1),
      Paint()..color = color.withValues(alpha: 0.18),
    );

    if (samples.isNotEmpty) {
      final dx = size.width / samples.length;
      final barWidth = dx < 1.5 ? dx : dx * 0.7;
      final fill = Paint()..color = color;
      for (var i = 0; i < samples.length; i++) {
        final amp = samples[i].clamp(0.0, 1.0);
        if (amp <= 0) continue;
        final half = amp * midY;
        final x = i * dx;
        canvas.drawRect(
          Rect.fromLTRB(x, midY - half, x + barWidth, midY + half),
          fill,
        );
      }
    }

    if (progress > 0) {
      final x = (progress.clamp(0.0, 1.0)) * size.width;
      // A background-coloured gutter either side of the playhead. It vanishes
      // against the empty surface, but where bars cover the playhead it cuts
      // them away from it — without this the white playhead is invisible
      // wherever the waveform is itself white, which the not-sounding states
      // are (opaque white in high contrast). Drawn before the bar so the bar
      // stays a crisp 2px.
      canvas
        ..drawRect(
          Rect.fromLTWH(x - 2, 0, 4, waveHeight),
          Paint()..color = background,
        )
        ..drawRect(
          Rect.fromLTWH(x - 1, 0, 2, waveHeight),
          Paint()..color = Colors.white,
        );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.progress != progress ||
      oldDelegate.bars != bars ||
      oldDelegate.color != color ||
      oldDelegate.background != background;
}

/// The bar ruler under the wave: one faint line per bar across the full
/// height and the bar number in the strip the wave leaves free at the bottom
/// ([WaveformPainter.rulerHeight]). Painted in its own layer, so the wave's
/// per-poll playhead repaint never re-shapes these labels.
class BarRulerPainter extends CustomPainter {
  /// Creates a [BarRulerPainter] for [bars] whole bars.
  BarRulerPainter({required this.bars, required this.color});

  /// Whole bars across the loop; `0` paints nothing.
  final int bars;

  /// The label colour.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars <= 0 || size.width <= 0 || size.height <= 0) return;
    final line = Paint()..color = Colors.white.withValues(alpha: 0.09);
    final style = TextStyle(
      fontFamily: SurfaceTheme.monoFont,
      fontSize: 18,
      height: 1,
      color: color,
    );
    for (var bar = 0; bar < bars; bar++) {
      final x = bar / bars * size.width;
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), line);
      final label = TextPainter(
        text: TextSpan(text: '${bar + 1}', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 5, size.height - label.height));
    }
  }

  @override
  bool shouldRepaint(BarRulerPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}
