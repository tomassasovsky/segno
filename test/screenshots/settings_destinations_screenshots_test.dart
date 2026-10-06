@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/settings/settings.dart';

import '../helpers/screenshot_fonts.dart';
import '../settings/view/destination_harness.dart';

/// Settings (pen `05 Loop setup / 01 Settings`) and the five interim
/// destinations, the tray's bodies in the shared Settings frame.
/// Author-machine goldens, like the other suites here.
void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  final hasFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  setUp(resetSegnoNavigatorForTest);

  final pages = <String, Future<void> Function()>{
    'home': openSegnoSettings,
    'device': openDeviceSettings,
    'network': openNetworkSettings,
    'displays': openDisplaySettings,
    'storage': openStorageSettings,
    'updates': openUpdateSettings,
  };

  for (final MapEntry(key: name, value: open) in pages.entries) {
    testWidgets(name, (tester) async {
      await DestinationHarness().pump(tester);
      unawaited(open());
      await tester.pumpAndSettle();
      // The tile art decodes off the test's fake clock; let the real decode
      // finish so the golden is not an empty picture.
      final context = tester.element(find.byType(Scaffold).last);
      await tester.runAsync(() async {
        for (final destination in SettingsDestination.values) {
          await precacheImage(AssetImage(destination.artAsset), context);
        }
      });
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_$name.png'),
      );
    }, skip: !hasFonts);
  }
}
