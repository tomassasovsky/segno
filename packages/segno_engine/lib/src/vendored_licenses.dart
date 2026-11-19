import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The third-party native code compiled into the engine library, each with
/// the file that carries its license verbatim (declared as assets in this
/// package's pubspec, read from where the code is vendored).
///
/// Flutter's license collector only sees Dart packages' `LICENSE` files, so
/// code vendored inside a plugin's native build is invisible to it. MIT
/// requires its notice in binary copies, so the engine, which is what ships
/// that code, registers these itself.
///
/// The VST3 SDK's three subtrees (`base/`, `pluginterfaces/`,
/// `public.sdk/`) carry byte-identical `LICENSE.txt` files; one is shown.
const List<(String, String)> _vendoredLicenses = [
  ('clap', 'third_party/clap/LICENSE'),
  ('miniaudio', 'src/miniaudio/LICENSE'),
  ('signalsmith-dsp', 'third_party/signalsmith-stretch/dsp/LICENSE.txt'),
  ('signalsmith-stretch', 'third_party/signalsmith-stretch/LICENSE.txt'),
  ('vst3sdk', 'third_party/vst3sdk/base/LICENSE.txt'),
];

/// Adds the vendored native libraries' licenses to [LicenseRegistry], so the
/// app's open source notices list them beside the Dart packages'.
///
/// Call once at startup, after the binding is initialised. The texts are read
/// lazily, when the registry is first walked. A file that fails to load is
/// reported through [FlutterError.reportError] and left out, so the other
/// entries, and every other package's, still list.
void registerVendoredLicenses() {
  LicenseRegistry.addLicense(_vendoredLicenseEntries);
}

Stream<LicenseEntry> _vendoredLicenseEntries() async* {
  for (final (package, path) in _vendoredLicenses) {
    final String text;
    try {
      text = await rootBundle.loadString(
        'packages/segno_engine/$path',
        cache: false,
      );
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'segno_engine',
          context: ErrorDescription("loading $package's license"),
        ),
      );
      continue;
    }
    yield LicenseEntryWithLineBreaks([package], text);
  }
}
