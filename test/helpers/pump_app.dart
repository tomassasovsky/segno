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
  Future<void> pumpApp(Widget widget, {ThemeData? theme}) {
    return pumpWidget(
      MaterialApp(
        // The real app theme, so widgets resolving design tokens from
        // `Theme.of(context)` (LooperTheme, SurfaceTheme) work under test.
        theme: theme ?? AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppTextDefaults(child: child ?? const SizedBox.shrink()),
        home: widget,
      ),
    );
  }
}
