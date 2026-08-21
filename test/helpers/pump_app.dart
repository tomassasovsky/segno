import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

extension PumpApp on WidgetTester {
  /// Pumps [widget] under the real app theme.
  ///
  /// Pass [theme] to exercise a different flavor — [AppTheme.highContrast] is
  /// the one that catches hardcoded colours and alphas, since it is the only
  /// flavor that overrides the tokens they bypass.
  ///
  /// Switching flavor mid-test **unmounts first**, because re-pumping a
  /// mounted `MaterialApp` with a new theme ANIMATES the change: one pumped
  /// frame still reads the outgoing flavor's tokens, so an assertion on the
  /// new flavor silently passes against the old one. That used to be a
  /// documented rule callers had to remember (`pumpWidget(const
  /// SizedBox.shrink())` before every re-pump) and forgetting it was a false
  /// green, never a failure — so the helper now does it (#768).
  ///
  /// Re-pumping the SAME flavor does not unmount, so tests that re-pump to
  /// push new state keep their element tree.
  Future<void> pumpApp(Widget widget, {ThemeData? theme}) async {
    final next = theme ?? AppTheme.neon;
    final mounted = _mountedTheme();
    if (mounted != null && !_sameFlavor(mounted, next)) {
      await pumpWidget(const SizedBox.shrink());
    }
    return pumpWidget(
      MaterialApp(
        // The real app theme, so widgets resolving design tokens from
        // `Theme.of(context)` (LooperTheme, SurfaceTheme) work under test.
        theme: next,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppTextDefaults(child: child ?? const SizedBox.shrink()),
        home: widget,
      ),
    );
  }

  /// The theme of the `MaterialApp` this helper already has mounted, if any.
  ThemeData? _mountedTheme() {
    if (binding.rootElement == null) return null;
    final apps = widgetList<MaterialApp>(find.byType(MaterialApp));
    return apps.isEmpty ? null : apps.first.theme;
  }

  /// Whether two [ThemeData]s are the same *flavor*.
  ///
  /// Not `==`: [AppTheme.neon] is a getter that builds a fresh [ThemeData]
  /// per call, and [ThemeData] compares its extensions by their own equality
  /// — which the token extensions do not define — so two neon themes are
  /// never equal. Their token payloads ARE `const`, though, so the canonical
  /// instances compare identical, and that is exactly the flavor identity
  /// this needs. Anything hand-built (a test's doctored copy) fails the
  /// identity check and gets the unmount, which is the safe direction.
  bool _sameFlavor(ThemeData a, ThemeData b) =>
      identical(a.extension<SurfaceTheme>(), b.extension<SurfaceTheme>()) &&
      identical(a.extension<LooperTheme>(), b.extension<LooperTheme>()) &&
      a.colorScheme == b.colorScheme;
}
