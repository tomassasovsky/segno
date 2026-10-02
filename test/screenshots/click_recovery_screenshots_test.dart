@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_dialog.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';

/// Author-side view of a refused persistence flush; no real halt is invoked.
void main() {
  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  final hasFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();

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

  testWidgets('failed settings flush offers Retry and Keep playing', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var goodbyeCalls = 0;
    var haltCalls = 0;
    final power = PowerOffCubit(
      flush: ({required retry}) => throw StateError('settings not confirmed'),
      pedalGoodbye: () {
        goodbyeCalls++;
      },
      powerOff: () async {
        haltCalls++;
      },
      markHold: Duration.zero,
    );
    addTearDown(power.close);
    const snapshot = PowerOffSnapshot();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          brightness: Brightness.dark,
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: BlocProvider.value(
          value: power,
          child: const Scaffold(
            body: PowerOffDialog(snapshot: _snapshot),
          ),
        ),
      ),
    );
    power.press(snapshot);
    await tester.pump();
    expect(power.state.phase, PowerOffPhase.flushFailed);
    expect(find.text('Settings could not be confirmed'), findsOneWidget);
    expect(find.byKey(const Key('power_off_retry')), findsOneWidget);
    expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
    expect(find.byKey(const Key('power_off_discard')), findsNothing);
    expect(goodbyeCalls, 0);
    expect(haltCalls, 0);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(PowerOffDialog),
      matchesGoldenFile('goldens/click_recovery_power_off.png'),
    );
  }, skip: !hasFonts);
}

PowerOffSnapshot _snapshot() => const PowerOffSnapshot();
