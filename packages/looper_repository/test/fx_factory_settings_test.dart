import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/fx_factory_settings.dart';

void main() {
  test('the effects matrix runs the factory presets as they build', () {
    expect(
      File(kFxFactorySettingsPath).readAsStringSync(),
      fxFactorySettingsInc(),
      reason: 'regenerate with tool/generate_fx_factory_settings.dart',
    );
  });
}
