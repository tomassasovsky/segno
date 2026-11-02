// Regenerates ../segno_engine/src/test/bench/fx_factory_settings.inc, the
// factory presets' effect settings the effects matrix runs (#1547).
//
//   cd packages/looper_repository &&
//     flutter test tool/generate_fx_factory_settings.dart
//
// A test rather than a script because the package depends on Flutter, which
// `dart run` cannot load. Rerun it after the catalogue or the module builds
// change; test/fx_factory_settings_test.dart fails until then.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test/helpers/fx_factory_settings.dart';

void main() {
  test('regenerate the factory effect settings', () {
    final file = File(kFxFactorySettingsPath)
      ..writeAsStringSync(fxFactorySettingsInc());
    stdout.writeln('wrote ${file.path} (${file.lengthSync()} bytes)');
  });
}
