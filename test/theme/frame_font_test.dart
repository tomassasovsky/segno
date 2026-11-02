import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/theme/surface_theme.dart';

import '../helpers/text_fit.dart';

double _width(FontWeight weight) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'Keyboard shortcuts',
      style: TextStyle(
        fontFamily: SurfaceTheme.frameFont,
        fontSize: 100,
        fontWeight: weight,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  addTearDown(painter.dispose);
  return painter.width;
}

void main() {
  setUpAll(loadBundledFonts);

  // Arimo is the track view's face and the settings frame's. A weight the app
  // does not bundle is synthesized by thickening the Regular's outlines,
  // which keeps the Regular's advance widths; the bundled Bold is wider.
  test('Arimo draws bold and semi-bold from its own Bold face', () {
    final regular = _width(FontWeight.w400);
    expect(_width(FontWeight.w700), greaterThan(regular + 50));
    expect(_width(FontWeight.w600), _width(FontWeight.w700));
  });
}
