import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_host.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockRecorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockUpdateRepository extends Mock implements UpdateRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

final _offer = UpdateManifest(
  version: Version.parse('1.1.0'),
  bundle: 'segno-appliance-1.1.0.raucb',
);

void main() {
  group('an update install gates the power flow', () {
    late UpdateRepository updates;
    late StreamController<double> download;
    late UpdateCubit update;
    late PowerCubit power;
    late List<String> log;

    setUp(() async {
      log = <String>[];
      download = StreamController<double>();
      updates = _MockUpdateRepository();
      when(() => updates.isSupported).thenReturn(true);
      when(() => updates.channel).thenReturn('production');
      when(
        () => updates.currentVersion(),
      ).thenAnswer((_) async => Version.parse('1.0.0'));
      when(() => updates.stagedVersion()).thenAnswer((_) async => Version.none);
      when(() => updates.checkForUpdate()).thenAnswer((_) async => _offer);
      when(
        () => updates.downloadAndStage(_offer),
      ).thenAnswer((_) => download.stream);
      update = UpdateCubit(
        updates: updates,
        settings: _MockSettingsRepository(),
      );
      await update.check();
      power = PowerCubit(
        stopTransport: () {},
        flush: ({required retry}) {},
        storageSettled: () async {},
        guards: GuardRegistry(),
        pedalGoodbye: () {},
        powerOff: () async => log.add('powerOff'),
        reboot: () async => log.add('reboot'),
        markHold: Duration.zero,
      );
    });

    tearDown(() async {
      await power.close();
      await update.close();
      // Never awaited: the done future of a controller nobody listens to
      // does not complete.
      unawaited(download.close());
    });

    /// Two buttons standing in for the rear power button (and Settings'
    /// Power row) and for Updates' Install and restart: both build their
    /// snapshot with [currentPowerSnapshot].
    Future<void> pump(WidgetTester tester) {
      final looper = _MockLooperBloc();
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(),
      );
      final recorder = _MockRecorder();
      whenListen(
        recorder,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: const PerformanceRecorderIdle(),
      );
      final session = _MockSessionCubit();
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(currentSessionName: 'set'),
      );
      when(session.save).thenAnswer((_) async {});
      return tester.pumpApp(
        MultiBlocProvider(
          providers: [
            BlocProvider<PowerCubit>.value(value: power),
            BlocProvider<UpdateCubit>.value(value: update),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
            BlocProvider<SessionCubit>.value(value: session),
          ],
          child: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  key: const Key('power'),
                  onPressed: () => requestPower(context),
                  child: const Text('Power'),
                ),
                TextButton(
                  key: const Key('install_restart'),
                  onPressed: () => requestRestart(context),
                  child: const Text('Install and restart'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('the power button is refused while an online update '
        'downloads, and opens Power options once the download fails', (
      tester,
    ) async {
      await pump(tester);
      unawaited(update.startDownload());
      expect(update.state.phase, UpdatePhase.downloading);

      await tester.tap(find.byKey(const Key('power')));
      await tester.pump();
      expect(
        power.state,
        const PowerState(
          phase: PowerPhase.refuse,
          refusal: PowerRefusal.update,
        ),
      );

      power.dismiss();
      download.addError(Exception('sha mismatch'));
      await tester.pump();
      expect(update.state.phase, UpdatePhase.error);

      await tester.tap(find.byKey(const Key('power')));
      await tester.pump();
      expect(power.state, const PowerState(phase: PowerPhase.options));
      expect(log, isEmpty);
    });

    testWidgets('the power button opens Power options once the download '
        'has staged', (tester) async {
      await pump(tester);
      unawaited(update.startDownload());
      download.add(0.7);
      await tester.pump();

      await tester.tap(find.byKey(const Key('power')));
      await tester.pump();
      expect(power.state.refusal, PowerRefusal.update);

      power.dismiss();
      unawaited(download.close());
      await tester.pump();
      expect(update.state.phase, UpdatePhase.staged);

      await tester.tap(find.byKey(const Key('power')));
      await tester.pump();
      expect(power.state, const PowerState(phase: PowerPhase.options));
    });

    testWidgets('Install and restart waits for a USB install, and reboots '
        'once it has ended', (tester) async {
      await pump(tester);
      update.setUsbInstalling(working: true);

      await tester.tap(find.byKey(const Key('install_restart')));
      await tester.pump();
      expect(
        power.state,
        const PowerState(
          phase: PowerPhase.refuse,
          refusal: PowerRefusal.update,
        ),
      );
      expect(log, isEmpty);

      power.dismiss();
      update.setUsbInstalling(working: false);
      await tester.tap(find.byKey(const Key('install_restart')));
      await tester.pump();
      await tester.pump();

      expect(power.state.phase, PowerPhase.goodbye);
      expect(log, ['reboot']);
    });
  });
}
