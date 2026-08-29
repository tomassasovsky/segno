import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/cache_telemetry_scope.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('CacheTelemetryScope', () {
    late FakeAudioEngine engine;
    late StreamController<void> ticker;
    late LooperRepository repository;
    late SettingsRepository settings;
    late TracksCubit tracksCubit;
    late SettingsTrayCubit trayCubit;

    setUp(() async {
      engine = FakeAudioEngine();
      ticker = StreamController<void>.broadcast();
      repository = LooperRepository(engine: engine, ticker: ticker.stream);
      settings = SettingsRepository(store: FakeKeyValueStore());
      tracksCubit = TracksCubit(settings: settings);
      // The strip is off by default on the console, and the scope only polls
      // while it is on -- so turn it on to exercise the gate at all.
      await tracksCubit.setShowIndicators(value: true);
      trayCubit = SettingsTrayCubit(settings: settings);
    });

    tearDown(() async {
      await tracksCubit.close();
      await trayCubit.close();
      await repository.dispose();
      await ticker.close();
    });

    Future<void> pumpScope(WidgetTester tester) => tester.pumpApp(
      RepositoryProvider.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: tracksCubit),
            BlocProvider.value(value: trayCubit),
          ],
          child: const CacheTelemetryScope(child: SizedBox()),
        ),
      ),
    );

    testWidgets(
      'stays off while the Signal face is not showing, even with the '
      'preference on',
      (tester) async {
        await pumpScope(tester);

        // With the preference ON — the exact state that used to cost a
        // per-poll engine sweep on every screen (#418) — but the tray closed,
        // nothing renders the glyph, so the repository must not be polling.
        expect(tracksCubit.state.showIndicators, isTrue);
        expect(repository.cacheTelemetryEnabled, isFalse);
        expect(engine.laneCacheSweeps, 0);
      },
    );

    testWidgets(
      'turns on when the tray opens at Signal and the preference is on',
      (tester) async {
        await pumpScope(tester);

        trayCubit.open(); // the tray's landing destination IS Signal
        await tester.pump();

        expect(repository.cacheTelemetryEnabled, isTrue);
      },
    );

    testWidgets('stays off with Signal showing but the preference off', (
      tester,
    ) async {
      await pumpScope(tester);

      await tracksCubit.setShowIndicators(value: false);
      trayCubit.open();
      await tester.pump();

      expect(repository.cacheTelemetryEnabled, isFalse);
      expect(engine.laneCacheSweeps, 0);
    });

    testWidgets('turns off when the rail leaves the Signal face', (
      tester,
    ) async {
      await pumpScope(tester);
      trayCubit.open();
      await tester.pump();
      expect(repository.cacheTelemetryEnabled, isTrue);

      trayCubit.showDestination(SettingsTrayDestination.control);
      await tester.pump();

      expect(repository.cacheTelemetryEnabled, isFalse);
    });

    testWidgets('turns off when the tray closes', (tester) async {
      await pumpScope(tester);
      trayCubit.open();
      await tester.pump();
      expect(repository.cacheTelemetryEnabled, isTrue);

      trayCubit.closeTray();
      await tester.pump();

      // closeTray parks the destination back at Signal, so the destination
      // check alone would leave telemetry running behind a closed tray —
      // open-ness has to be part of the gate.
      expect(repository.cacheTelemetryEnabled, isFalse);
    });

    testWidgets('turns off when the scope itself unmounts', (tester) async {
      await pumpScope(tester);
      trayCubit.open();
      await tester.pump();
      expect(repository.cacheTelemetryEnabled, isTrue);

      // Navigating off the tracks screen unmounts the scope; nobody can be
      // looking at the glyph any more, whatever the cubits last said.
      await tester.pumpWidget(const SizedBox.shrink());

      expect(repository.cacheTelemetryEnabled, isFalse);
    });

    testWidgets(
      'a restored preference equal to the compile-time default still lands',
      (tester) async {
        // The gate is driven only by cubit emissions, so the case where
        // load() restores a value IDENTICAL to the initial state is the one
        // that could silently never arrive — a fresh desktop install, i.e.
        // the default. bloc delivers the first emit even when the state
        // compares equal; this pins that, rather than leaving the default
        // path resting on it untested.
        await settings.saveShowTrackIndicators(value: true);
        await pumpScope(tester);
        trayCubit.open();
        await tester.pump();

        await tracksCubit.load();
        await tester.pump();

        expect(repository.cacheTelemetryEnabled, isTrue);
      },
    );
  });
}
