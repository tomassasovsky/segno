@Tags(['screenshots'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/settings/settings.dart';

import '../helpers/screenshot_fonts.dart';
import '../settings/view/destination_harness.dart';

/// Settings (pen `05 Loop setup / 01 Settings`) and the five interim
/// destinations, the tray's bodies in the shared Settings frame.
/// Renders only with `--update-goldens`, like the other suites here.
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFonts();
  });

  setUp(resetSegnoNavigatorForTest);

  final pages = <String, Future<void> Function()>{
    // With Power, as the console draws it (a desktop build has none).
    'home': () => segnoNavigatorKey.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => const SettingsHomePage(powerAvailable: true),
      ),
    ),
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
          await precacheImage(
            ResizeImage(
              AssetImage(destination.artAsset),
              width: SettingsTile.artSize.round(),
              height: SettingsTile.artSize.round(),
            ),
            context,
          );
        }
      });
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_$name.png'),
      );
    }, skip: !rendersScreenshots);
  }
}
