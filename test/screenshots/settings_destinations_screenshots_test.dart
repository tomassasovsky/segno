@Tags(['screenshots'])
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/console_leds/view/console_leds_page.dart';
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
    // Displays > Console LEDs (#1564), on a board that reports no sensor.
    'console_leds': () =>
        segnoNavigatorKey.currentState!.push(ConsoleLedsPage.route()),
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

  // Console LEDs with a sensor reading 1024 of 4095, in Automatic.
  testWidgets('console_leds_sensor', (tester) async {
    final link = FakePedalLink();
    final harness = DestinationHarness();
    await harness.pump(tester, pedalLink: link);
    link
      ..hello(firmwareMajor: 2, firmwareMinor: 7)
      ..emit(
        const AmbientLightMessage(
          PedalAmbientLight(sensor: PedalLightSensor.reading, level: 160),
        ),
      );
    await tester.pump();
    await harness.leds.setAutomatic(automatic: true);
    segnoNavigatorKey.currentState!.push(ConsoleLedsPage.route());
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_console_leds_sensor.png'),
    );
    // The board falls silent so its hello watchdog does not outlive the test.
    await tester.pump(const Duration(seconds: 4));
  }, skip: !rendersScreenshots);
}
