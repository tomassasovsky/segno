import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The typefaces bundled under `assets/fonts/`, each with the file beside it
/// that carries its copyright line and licence verbatim.
///
/// Flutter's licence collector only sees Dart packages' `LICENSE` files, so
/// fonts bundled as app assets are invisible to it. The SIL Open Font
/// Licence asks that every copy carry its notice and licence, and Apache 2.0
/// that recipients get a copy of the licence, so the app registers them.
const List<(String, String)> bundledFontLicenses = [
  ('Arimo', 'assets/fonts/LICENSE-Arimo.txt'),
  ('Inter', 'assets/fonts/OFL-Inter.txt'),
  ('JetBrains Mono', 'assets/fonts/OFL-JetBrainsMono.txt'),
  // The stomp pedals' display typefaces (#1501).
  ('Audiowide', 'assets/fonts/OFL-Audiowide.txt'),
  ('Bebas Neue', 'assets/fonts/OFL-BebasNeue.txt'),
  ('Bungee', 'assets/fonts/OFL-Bungee.txt'),
  ('Fascinate', 'assets/fonts/OFL-Fascinate.txt'),
  ('Lobster', 'assets/fonts/OFL-Lobster.txt'),
  ('Monoton', 'assets/fonts/OFL-Monoton.txt'),
  ('Pacifico', 'assets/fonts/OFL-Pacifico.txt'),
  ('Press Start 2P', 'assets/fonts/OFL-PressStart2P.txt'),
  ('Righteous', 'assets/fonts/OFL-Righteous.txt'),
  ('Rubik Mono One', 'assets/fonts/OFL-RubikMonoOne.txt'),
  ('Rye', 'assets/fonts/OFL-Rye.txt'),
  ('Shrikhand', 'assets/fonts/OFL-Shrikhand.txt'),
  ('Space Mono', 'assets/fonts/OFL-SpaceMono.txt'),
];

/// Adds the bundled fonts' licences to [LicenseRegistry], so System > About's
/// open-source notices list them beside the packages and the engine's
/// vendored native code.
///
/// Call once at startup, after the binding is initialised. The texts are read
/// lazily, when the registry is first walked.
void registerFontLicenses() {
  LicenseRegistry.addLicense(_fontLicenseEntries);
}

Stream<LicenseEntry> _fontLicenseEntries() async* {
  for (final (font, path) in bundledFontLicenses) {
    final text = await rootBundle.loadString(path, cache: false);
    yield LicenseEntryWithLineBreaks([font], text);
  }
}
