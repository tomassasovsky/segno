@Tags(['screenshots'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_dialog.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../helpers/helpers.dart';

/// Pen 32's five Power screens on the main screen (Power options, Saving,
/// Save failed, Safe to switch off and Restarting) and the Track display's
/// faces. No real halt is invoked.
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFonts();
  });

  Future<void> pumpFace(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1920, 1080),
    double pixelRatio = 1,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = pixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.neon,
        builder: (context, child) =>
            AppTextDefaults(child: child ?? const SizedBox.shrink()),
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
    updateInstalling: () async => false,
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
  }, skip: !rendersScreenshots);

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
  }, skip: !rendersScreenshots);

  final savedAt = DateTime(2026, 11, 2, 21, 47);
  for (final (name, state) in [
    (
      'power_saving',
      const PowerState(
        phase: PowerPhase.saving,
        action: PowerAction.shutDown,
        step: PowerStep.writeSession,
        session: 'friday-set',
        slow: true,
      ),
    ),
    (
      'power_safe_to_switch_off',
      PowerState(
        phase: PowerPhase.goodbye,
        action: PowerAction.shutDown,
        session: 'friday-set',
        savedAt: savedAt,
      ),
    ),
    (
      'power_restarting',
      PowerState(
        phase: PowerPhase.goodbye,
        action: PowerAction.restart,
        session: 'friday-set',
        savedAt: savedAt,
      ),
    ),
  ]) {
    testWidgets(name, (tester) async {
      await pumpFace(
        tester,
        PowerGoodbye(state: state, stagedUpdate: '1.1.0'),
      );
      await expectLater(
        find.byType(PowerGoodbye),
        matchesGoldenFile('goldens/$name.png'),
      );
    }, skip: !rendersScreenshots);
  }

  for (final (name, readout) in [
    (
      'power_readout_saving',
      const PerformanceReadout(
        goodbye: ReadoutGoodbye.saving,
        savingStep: PowerStep.writeSession,
        savingProgress: 0.5,
      ),
    ),
    (
      'power_readout_safe_to_switch_off',
      const PerformanceReadout(goodbye: ReadoutGoodbye.safeToSwitchOff),
    ),
    (
      'power_readout_restarting',
      const PerformanceReadout(goodbye: ReadoutGoodbye.restarting),
    ),
  ]) {
    testWidgets(name, (tester) async {
      // The 7" panel: 1024x600 at the console's pixel ratio.
      await pumpFace(
        tester,
        ReadoutGoodbyeFace(readout: readout),
        size: const Size(1024, 600),
        pixelRatio: 1.6,
      );
      await expectLater(
        find.byType(ReadoutGoodbyeFace),
        matchesGoldenFile('goldens/$name.png'),
      );
    }, skip: !rendersScreenshots);
  }
}

PowerSnapshot _snapshot() =>
    const PowerSnapshot(currentSessionName: 'friday-set');
