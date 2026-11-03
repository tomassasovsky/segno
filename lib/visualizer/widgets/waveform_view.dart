import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// Paints a mirrored, centered loop waveform from peak [samples] (index 0 =
/// loop start, each in `0..1`) with a white playhead bar at [progress]
/// (`0..1`), and — when [bars] is set — the bar ruler of the accepted stage:
/// a faint line at every bar with its number in the bottom-left corner of
/// the bar. The stroke colour comes from the active [LooperTheme]'s waveform
/// table, keyed by [state]. The wave repaints on a new list; the playhead
/// paints in a layer of its own over it, so a moving playhead does not
/// repaint the wave.
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
        bars: bars,
        color: looper?.waveformColor(state) ?? Colors.tealAccent,
      ),
      size: Size.infinite,
    );
    // The playhead moves on every engine poll; the wave under it changes
    // once per lap at most. Painted apart, a playhead tick repaints two
    // rectangles and the wave keeps its layer (#1563).
    final playhead = CustomPaint(
      key: const Key('waveform_view_playhead'),
      painter: PlayheadPainter(
        progress: progress,
        bars: bars,
        background: background,
      ),
      size: Size.infinite,
    );
    // The ruler is its own layer over the wave and the playhead (its faint
    // lines stay visible across the bars): its bar labels are laid-out text
    // that must not be re-shaped at frame rate for a fact (the bar count)
    // that changes once per take.
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
            RepaintBoundary(child: paint),
            playhead,
            ?ruler,
          ],
        ),
      ),
    );
  }
}

/// The wave of [WaveformView]; public so it can be unit-tested.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({
    required this.samples,
    required this.color,
    this.bars = 0,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Whole bars across the loop; `> 0` leaves [rulerHeight] free at the
  /// bottom for the [BarRulerPainter] layer over this one.
  final int bars;

  /// Waveform color.
  final Color color;

  /// The ruler's reserved strip under the waveform, for the bar numbers.
  static const double rulerHeight = 28;

  /// The height the wave and the playhead take in [size], above the ruler.
  static double waveHeightIn(Size size, {required int bars}) =>
      bars > 0 ? size.height - rulerHeight : size.height;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final waveHeight = waveHeightIn(size, bars: bars);
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
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.bars != bars ||
      oldDelegate.color != color;
}

/// The white playhead bar over [WaveformPainter]'s wave, at [progress]
/// (`0..1`); hidden when `<= 0`.
class PlayheadPainter extends CustomPainter {
  /// Creates a [PlayheadPainter].
  PlayheadPainter({
    required this.progress,
    required this.background,
    this.bars = 0,
  });

  /// Playhead position in `0..1`.
  final double progress;

  /// The surface the waveform is drawn on, painted into the gutter that cuts
  /// the playhead free of the bars — see [paint].
  final Color background;

  /// Whole bars across the loop; the playhead stops above the ruler.
  final int bars;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || size.width <= 0) return;
    final waveHeight = WaveformPainter.waveHeightIn(size, bars: bars);
    if (waveHeight <= 0) return;
    final x = progress.clamp(0.0, 1.0) * size.width;
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

  @override
  bool shouldRepaint(PlayheadPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bars != bars ||
      oldDelegate.background != background;
}

/// The bar ruler over the wave: one faint line per bar across the full
/// height and the bar numbers in the strip the wave leaves free at the bottom
/// ([WaveformPainter.rulerHeight]). Painted in its own layer, so the
/// per-poll playhead repaint never re-shapes these labels.
///
/// Every bar is numbered while the numbers fit. When bars are narrower than
/// a number, only every 2nd, 4th, 8th... bar is, so the numbers never run
/// into each other or past the end (#1524).
class BarRulerPainter extends CustomPainter {
  /// Creates a [BarRulerPainter] for [bars] whole bars.
  BarRulerPainter({required this.bars, required this.color});

  /// Whole bars across the loop; `0` paints nothing.
  final int bars;

  /// The label colour.
  final Color color;

  /// A number's inset from its bar line.
  static const double labelInset = 5;

  /// The least space after a number before the next one.
  static const double labelGap = 8;

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
    final barWidth = size.width / bars;
    // The widest number is the last one's.
    final measure = TextPainter(
      text: TextSpan(text: '$bars', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final widest = measure.width;
    measure.dispose();
    // Every number sits the same inset from its own line, so the room
    // between two numbers is the stride less one number.
    var stride = 1;
    while (stride < bars && stride * barWidth < widest + labelGap) {
      stride *= 2;
    }
    for (var bar = 0; bar < bars; bar++) {
      final x = bar * barWidth;
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), line);
      // The last numbered bar must also leave room for its number before
      // the end of the ruler.
      if (bar % stride != 0 || (bars - bar) * barWidth < labelInset + widest) {
        continue;
      }
      final label = TextPainter(
        text: TextSpan(text: '${bar + 1}', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      label
        ..paint(canvas, Offset(x + labelInset, size.height - label.height))
        ..dispose();
    }
  }

  @override
  bool shouldRepaint(BarRulerPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}
