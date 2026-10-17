@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_dialog.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../helpers/helpers.dart';

/// Pen 32's five Power screens: Power options, Saving, Save failed, Safe to
/// switch off and Restarting. No real halt is invoked.
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

  Future<void> pumpFace(WidgetTester tester, Widget child) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        home: Scaffold(body: child),
      ),
    );
  }

  PowerCubit cubit() => PowerCubit(
    stopTransport: () {},
    flush: ({required retry}) {},
    storageSettled: () async {},
    guards: GuardRegistry(),
    pedalGoodbye: () {},
    powerOff: () async {},
    reboot: () async {},
    markHold: Duration.zero,
  );

  testWidgets('Power options, with a staged update', (tester) async {
    final power = cubit()..press(_snapshot());
    addTearDown(power.close);
    await pumpFace(
      tester,
      BlocProvider.value(
        value: power,
        child: PowerDialog(
          snapshot: _snapshot,
          save: () async {},
          stagedUpdate: '1.1.0',
        ),
      ),
    );
    await expectLater(
      find.byType(PowerDialog),
      matchesGoldenFile('goldens/power_options.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Save failed: Segno is staying on', (tester) async {
    final power = cubit()
      ..shutDown(_snapshot(), save: () async => throw StateError('disk full'));
    addTearDown(power.close);
    await pumpFace(
      tester,
      BlocProvider.value(
        value: power,
        child: PowerDialog(snapshot: _snapshot, save: () async {}),
      ),
    );
    await tester.pump();
    expect(power.state.phase, PowerPhase.saveFailed);
    await expectLater(
      find.byType(PowerDialog),
      matchesGoldenFile('goldens/power_save_failed.png'),
    );
  }, skip: !hasFonts);

  for (final (name, face, action) in [
    ('power_saving', ReadoutGoodbye.saving, PowerAction.shutDown),
    ('power_safe_to_switch_off', ReadoutGoodbye.mark, PowerAction.shutDown),
    ('power_restarting', ReadoutGoodbye.mark, PowerAction.restart),
  ]) {
    testWidgets(name, (tester) async {
      await pumpFace(tester, PowerGoodbye(face: face, action: action));
      await expectLater(
        find.byType(PowerGoodbye),
        matchesGoldenFile('goldens/$name.png'),
      );
    }, skip: !hasFonts);
  }
}

PowerSnapshot _snapshot() =>
    const PowerSnapshot(currentSessionName: 'friday-set');
