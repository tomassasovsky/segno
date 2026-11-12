import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

/// The app's spacing scale: every gap and inset a component sets comes from
/// one of these steps instead of a literal, so neighbouring components keep
/// one rhythm (#1562).
///
/// Four-pixel steps at the small end and the top bar's own gap (24) and the
/// stage's 32 at the large end; the stage top bar's 24 between its buttons
/// is [xl].
///
/// Read it with the [SpacingThemeX.spacing] extension:
/// `context.spacing.lg`.
@immutable
class SpacingTheme extends ThemeExtension<SpacingTheme> {
  /// Creates a [SpacingTheme].
  const SpacingTheme({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
  });

  /// 4.
  final double xs;

  /// 8.
  final double sm;

  /// 12.
  final double md;

  /// 16.
  final double lg;

  /// 24: the stage top bar's gap between its controls.
  final double xl;

  /// 32.
  final double xxl;

  /// The scale every flavour shares.
  static const SpacingTheme standard = SpacingTheme(
    xs: 4,
    sm: 8,
    md: 12,
    lg: 16,
    xl: 24,
    xxl: 32,
  );

  @override
  SpacingTheme copyWith({
    double? xs,
    double? sm,
    double? md,
    double? lg,
    double? xl,
    double? xxl,
  }) => SpacingTheme(
    xs: xs ?? this.xs,
    sm: sm ?? this.sm,
    md: md ?? this.md,
    lg: lg ?? this.lg,
    xl: xl ?? this.xl,
    xxl: xxl ?? this.xxl,
  );

  @override
  SpacingTheme lerp(ThemeExtension<SpacingTheme>? other, double t) {
    if (other is! SpacingTheme) return this;
    double l(double a, double b) => lerpDouble(a, b, t) ?? a;
    return SpacingTheme(
      xs: l(xs, other.xs),
      sm: l(sm, other.sm),
      md: l(md, other.md),
      lg: l(lg, other.lg),
      xl: l(xl, other.xl),
      xxl: l(xxl, other.xxl),
    );
  }
}

/// Ergonomic access to the [SpacingTheme] from a [BuildContext].
extension SpacingThemeX on BuildContext {
  /// The [SpacingTheme] for this context.
  SpacingTheme get spacing => Theme.of(this).extension<SpacingTheme>()!;
}
