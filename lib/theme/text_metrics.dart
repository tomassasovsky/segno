import 'package:flutter/material.dart';

/// Collapses font ascent/descent padding so line boxes sit closer to ink.
///
/// Inter (and most UI fonts) center **metrics**, not paint. Without this,
/// caps, chips, and icon+label rows read high and attract one-off
/// `Transform.translate` nudges. Applied app-wide via the theme's text
/// roles and [AppTextDefaults].
const TextHeightBehavior kAppTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: false,
  applyHeightToLastDescent: false,
);

/// Optical nudge for high-ink strings (caps, digits, `?`).
const Offset kAppTextOpticalOffset = Offset(0, 1);

/// Latin letters only, for case checks (digits/symbols handled separately).
final RegExp _letters = RegExp(r'\p{L}', unicode: true);

/// Content-based optical offset for AppText.
///
/// Inter paints caps, digits, and lone `?`/`!` high of geometric center. Mixed
/// case and lowercase are left alone — strut + height behavior are enough, and
/// a blanket 1px nudge overshoots them.
Offset appTextOpticalOffsetFor(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return Offset.zero;
  if (trimmed == '?' || trimmed == '!') return kAppTextOpticalOffset;

  final letters = _letters.allMatches(trimmed).map((m) => m.group(0)!).join();
  if (letters.isEmpty) {
    // Digits / punctuation chips read like caps.
    return kAppTextOpticalOffset;
  }
  if (letters == letters.toUpperCase()) return kAppTextOpticalOffset;
  return Offset.zero;
}

/// Even leading distribution on every role of a [TextTheme].
TextTheme withAppTextMetrics(TextTheme theme) {
  TextStyle? tighten(TextStyle? style) => style?.copyWith(
    leadingDistribution: TextLeadingDistribution.even,
  );
  return TextTheme(
    displayLarge: tighten(theme.displayLarge),
    displayMedium: tighten(theme.displayMedium),
    displaySmall: tighten(theme.displaySmall),
    headlineLarge: tighten(theme.headlineLarge),
    headlineMedium: tighten(theme.headlineMedium),
    headlineSmall: tighten(theme.headlineSmall),
    titleLarge: tighten(theme.titleLarge),
    titleMedium: tighten(theme.titleMedium),
    titleSmall: tighten(theme.titleSmall),
    bodyLarge: tighten(theme.bodyLarge),
    bodyMedium: tighten(theme.bodyMedium),
    bodySmall: tighten(theme.bodySmall),
    labelLarge: tighten(theme.labelLarge),
    labelMedium: tighten(theme.labelMedium),
    labelSmall: tighten(theme.labelSmall),
  );
}

/// Optional override for AppText's content-based optical offset.
///
/// Wrap a subtree to force an offset (including [Offset.zero] to disable).
/// Without this, AppText picks the nudge from the string itself.
class AppTextOptics extends InheritedWidget {
  /// Creates [AppTextOptics].
  const AppTextOptics({
    required this.opticalOffset,
    required super.child,
    super.key,
  });

  /// Forced optical offset for descendant AppText widgets.
  final Offset opticalOffset;

  /// The override when present; otherwise `null` (use content-based).
  static Offset? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppTextOptics>()
      ?.opticalOffset;

  @override
  bool updateShouldNotify(AppTextOptics oldWidget) =>
      opticalOffset != oldWidget.opticalOffset;
}

/// Ambient text metrics under a [MaterialApp].
///
/// Sets [kAppTextHeightBehavior] and even leading distribution. Optical nudge
/// is chosen per string by [appTextOpticalOffsetFor], not forced here.
class AppTextDefaults extends StatelessWidget {
  /// Creates an [AppTextDefaults].
  const AppTextDefaults({required this.child, super.key});

  /// The app subtree.
  final Widget child;

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
    style: const TextStyle(
      leadingDistribution: TextLeadingDistribution.even,
    ),
    textHeightBehavior: kAppTextHeightBehavior,
    child: child,
  );
}
