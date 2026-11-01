import 'package:flutter/material.dart';
import 'package:segno/theme/surface_theme.dart';
import 'package:segno/theme/text_metrics.dart';

/// Applies the Segno overlay legend face to the main looper screen.
class LooperScreenTheme extends StatelessWidget {
  /// Creates a [LooperScreenTheme].
  const LooperScreenTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const family = SurfaceTheme.legendFont;
    return Theme(
      data: theme.copyWith(
        textTheme: withAppTextMetrics(
          theme.textTheme.apply(fontFamily: family),
        ),
        primaryTextTheme: withAppTextMetrics(
          theme.primaryTextTheme.apply(fontFamily: family),
        ),
      ),
      child: child,
    );
  }
}
