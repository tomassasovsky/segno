import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/console_leds/view/console_leds_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';
import '../../settings/view/destination_harness.dart';

void main() {
  late DestinationHarness harness;
  late FakePedalLink link;

  setUp(() {
    resetSegnoNavigatorForTest();
    resetAppToastsForTest();
    resetToastificationForTest();
    harness = DestinationHarness();
    link = FakePedalLink();
  });

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold).first));

  /// Opens Settings > Displays > Console LEDs with a talking board, after
  /// [light] (none: the board says nothing about a sensor).
  Future<void> open(WidgetTester tester, {PedalAmbientLight? light}) async {
    await harness.pump(tester, pedalLink: link);
    link.hello();
    if (light != null) link.emit(AmbientLightMessage(light));
    await tester.pump();
    unawaited(openDisplaySettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('displays_console_leds')));
    await tester.pumpAndSettle();
    expect(find.byType(ConsoleLedsPage), findsOneWidget);
  }

  /// The board falls silent before the test ends, so the link's hello
  /// watchdog is not left running.
  Future<void> silence(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  String text(WidgetTester tester, Key key) => tester
      .widget<AppText>(
        find.descendant(of: find.byKey(key), matching: find.byType(AppText)),
      )
      .data!;

  String rowValue(WidgetTester tester, String key) {
    final texts = tester
        .widgetList<AppText>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(AppText),
          ),
        )
        .map((t) => t.data)
        .toList();
    return texts.last!;
  }

  testWidgets('a board that says nothing of a sensor: Automatic is off and '
      'says why', (tester) async {
    await open(tester);
    final strings = l10n(tester);
    expect(
      text(tester, const Key('console_leds_note')),
      strings.consoleLedsNoteNotReported,
    );
    expect(
      rowValue(tester, 'console_leds_sensor_state'),
      strings.aboutNotReported,
    );
    expect(find.byKey(const Key('console_leds_reading')), findsNothing);
    await tester.tap(find.byKey(const Key('console_leds_automatic')));
    await tester.pumpAndSettle();
    expect(harness.leds.state.settings.automatic, isFalse);
    // Manual brightness, full, as the console has always been.
    expect(
      tester
          .widget<AppText>(find.byKey(const Key('console_leds_readout')))
          .data,
      '100%',
    );
    expect(find.byKey(const Key('console_leds_brightness')), findsOneWidget);
    await silence(tester);
  });

  testWidgets('no sensor on J22: Automatic is unavailable and says so', (
    tester,
  ) async {
    await open(tester, light: PedalAmbientLight.none);
    final strings = l10n(tester);
    expect(
      text(tester, const Key('console_leds_note')),
      strings.consoleLedsNoteNoSensor,
    );
    expect(
      rowValue(tester, 'console_leds_sensor_state'),
      strings.consoleLedsSensorNone,
    );
    await tester.tap(find.byKey(const Key('console_leds_automatic')));
    await tester.pumpAndSettle();
    expect(harness.leds.state.settings.automatic, isFalse);
    expect(link.sent.whereType<LedLevelMessage>(), isEmpty);
    await silence(tester);
  });

  testWidgets('a sensor: the live reading, Automatic with its offset, and '
      'calibration', (tester) async {
    await open(
      tester,
      light: const PedalAmbientLight(
        sensor: PedalLightSensor.reading,
        level: 160,
      ),
    );
    final strings = l10n(tester);
    expect(
      rowValue(tester, 'console_leds_reading'),
      strings.consoleLedsReadingValue(1024),
    );
    expect(
      text(tester, const Key('console_leds_note')),
      strings.consoleLedsNoteManual,
    );
    await tester.tap(find.byKey(const Key('console_leds_automatic')));
    await tester.pumpAndSettle();
    expect(harness.leds.state.settings.automatic, isTrue);
    expect(find.byKey(const Key('console_leds_offset')), findsOneWidget);
    expect(
      tester
          .widget<AppText>(find.byKey(const Key('console_leds_readout')))
          .data,
      '0%',
    );
    expect(
      text(tester, const Key('console_leds_note')),
      strings.consoleLedsNoteAutomatic,
    );
    // The live reading moves the page.
    link.emit(
      const AmbientLightMessage(
        PedalAmbientLight(sensor: PedalLightSensor.reading, level: 20),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      rowValue(tester, 'console_leds_reading'),
      strings.consoleLedsReadingValue(2),
    );
    await tester.tap(find.byKey(const Key('console_leds_set_dark')));
    await tester.pumpAndSettle();
    expect(harness.leds.state.settings.darkReading, 20);
    expect(
      (await harness.settings.loadConsoleLeds()).darkReading,
      20,
    );
    await silence(tester);
  });

  testWidgets('a sensor at the top of its range asks for a smaller resistor', (
    tester,
  ) async {
    await open(
      tester,
      light: const PedalAmbientLight(
        sensor: PedalLightSensor.aboveRange,
        level: 190,
      ),
    );
    final strings = l10n(tester);
    expect(
      text(tester, const Key('console_leds_note')),
      strings.consoleLedsNoteAboveRange,
    );
    expect(
      tester.widget<LoopNote>(find.byKey(const Key('console_leds_note'))).tone,
      LoopNoteTone.error,
    );
    expect(
      rowValue(tester, 'console_leds_sensor_state'),
      strings.consoleLedsSensorAboveRange,
    );
    expect(ConsoleLedSettings.defaultBrightReading, lessThan(190));
    await silence(tester);
  });
}
