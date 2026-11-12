import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_textures.dart';

import 'text_fit.dart';

/// The Flutter SDK's Material fonts, where the screenshot suites load Roboto
/// from.
///
/// They are in `<sdk>/bin/cache/artifacts/material_fonts` on any machine with
/// the SDK, the author's Mac and the Linux CI runner alike. The `flutter`
/// tool sets `FLUTTER_ROOT` for the tests it runs, also with a local engine.
String get materialFontDir {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    throw StateError('FLUTTER_ROOT is not set: run the tests with `flutter`');
  }
  return '$root/bin/cache/artifacts/material_fonts';
}

/// Whether the screenshot suites render.
///
/// The PNGs they write are for review against the design, not committed
/// goldens, so there is nothing to compare against: the suites run only when
/// asked to write, with `flutter test --tags screenshots --update-goldens`.
/// CI does that and uploads the result as the `screenshots` artifact.
///
/// Asked to write without the fonts, it throws rather than skipping: a
/// silent skip would leave older PNGs in place to be reviewed as new.
bool get rendersScreenshots {
  if (!autoUpdateGoldenFiles) return false;
  if (!File('$materialFontDir/Roboto-Regular.ttf').existsSync()) {
    throw StateError('No Material fonts at $materialFontDir');
  }
  return true;
}

/// Registers every font a screenshot can show, for a screenshot suite.
///
/// The test harness bundles no fonts of its own, so every face a screenshot
/// shows has to be loaded by hand or it renders as tofu boxes and the
/// screenshot is worthless. The faces come from two places: every family in
/// the font manifest the test build writes from the pubspecs, which holds the
/// app's own faces, the Material icons and the package icon fonts (Lucide
/// among them) under the names Flutter resolves them by; and the SDK's Roboto,
/// which the app does not bundle but Material falls back to for text that
/// names no family. Read from the manifest rather than listed per suite, so a
/// face the app adds reaches every suite at once.
Future<void> loadScreenshotFonts() async {
  final roboto = FontLoader('Roboto');
  for (final face in const ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(
      File('$materialFontDir/Roboto-$face.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  }
  await roboto.load();
  await loadBundledFonts();
}

/// Loads everything a code-drawn pedal needs to look as designed in a
/// screenshot: the fonts ([loadScreenshotFonts], which include every pedal's
/// typeface) and its finish tiles. A suite that draws pedals calls this in
/// place of [loadScreenshotFonts].
Future<void> loadFxStompArt() async {
  await loadScreenshotFonts();
  await FxStompTextures.instance.load();
}
