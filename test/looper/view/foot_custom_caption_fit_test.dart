import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/foot_custom_view.dart';
import 'package:segno/looper/view/foot_pedal_rows.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/text_fit.dart';

/// A mode or command assigned to a Custom switch reads on one line under its
/// pedal, in English and Spanish, measured in the faces the console draws
/// (#1590 FT-3). A track operation names a track, whose name can be any
/// length, and keeps its two lines.
void main() {
  setUpAll(loadBundledFonts);

  // The caption's style as drawn: the page's Material body text (which
  // carries its letter spacing), with the foot view's face and the pedal's
  // size over it.
  double width(String text, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: AppTheme.neon.textTheme.bodyMedium!.merge(
          TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            fontWeight: FontWeight.w400,
            fontSize: fontSize,
          ),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final measured = painter.width;
    painter.dispose();
    return measured;
  }

  for (final locale in const [Locale('en'), Locale('es')]) {
    test('every mode and command caption fits one line ($locale)', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      final captions = [
        for (final action in controlActionCatalogue())
          if (action is ModeAction || action is CommandAction)
            footCustomActionLabel(l10n, const [], action),
        l10n.footCustomStopCapture,
        l10n.footCustomUnavailableAction,
      ];
      final wide = [
        for (final caption in captions)
          if (width(caption, 24) > FootPedalRows.pedalWidth) caption,
      ];
      expect(wide, isEmpty);
    });
  }

  test('every mode and command Hold line fits one line (en)', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final wide = [
      for (final action in controlActionCatalogue())
        if (action is ModeAction || action is CommandAction)
          if (l10n.footCustomHold(footCustomActionLabel(l10n, const [], action))
              case final hint when width(hint, 18) > FootPedalRows.pedalWidth)
            hint,
    ];
    expect(wide, isEmpty);
  });
}
