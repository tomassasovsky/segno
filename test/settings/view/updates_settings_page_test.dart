import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show LooperState;
import 'package:mocktail/mocktail.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/settings/view/updates_settings_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:update_repository/update_repository.dart';

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

class _MockPowerCubit extends MockCubit<PowerState> implements PowerCubit {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockRecorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

/// What the console knows about itself once `UpdateCubit.load` has run.
final _running = UpdateState(
  supported: true,
  channel: 'production',
  currentVersion: Version.parse('1.0.0'),
);

final _offer = UpdateManifest(
  version: Version.parse('1.1.0'),
  bundle: 'segno-appliance-1.1.0.raucb',
  size: 412000000,
);

void main() {
  late _MockUpdateCubit update;
  late _MockPowerCubit power;
  late StreamController<UpdateState> states;

  setUpAll(() => registerFallbackValue(const PowerSnapshot()));

  setUp(() {
    update = _MockUpdateCubit();
    power = _MockPowerCubit();
    states = StreamController<UpdateState>.broadcast();
    when(update.check).thenAnswer((_) async {});
    when(update.startDownload).thenAnswer((_) async {});
    when(update.cancelDownload).thenAnswer((_) async {});
    when(update.retryInterrupted).thenAnswer((_) async {});
    when(update.discardInterrupted).thenAnswer((_) async {});
    when(update.dismissRollback).thenAnswer((_) async {});
    when(
      () => update.setAutoCheck(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(
      () => update.setExperimentalChannel(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    whenListen(
      power,
      const Stream<PowerState>.empty(),
      initialState: const PowerState(),
    );
  });

  tearDown(() => states.close());

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(UpdatesSettingsPage)));

  /// Mounts the page at the pen's 1920 x 1080 with the providers the app
  /// gives it, starting in [state]; [states] drives later changes.
  Future<void> pump(WidgetTester tester, UpdateState state) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    whenListen(update, states.stream, initialState: state);
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
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<UpdateCubit>.value(value: update),
          BlocProvider<PowerCubit>.value(value: power),
          BlocProvider<LooperBloc>.value(value: looper),
          BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
          BlocProvider<SessionCubit>.value(value: session),
        ],
        child: MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const UpdatesSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Moves the page to [state], as the cubit would.
  Future<void> emit(WidgetTester tester, UpdateState state) async {
    when(() => update.state).thenReturn(state);
    states.add(state);
    await tester.pumpAndSettle();
  }

  /// Whether the encoder focus sits inside the widget keyed [key].
  bool focused(WidgetTester tester, String key) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return false;
    final target = find.byKey(Key(key)).evaluate().single;
    var inside = false;
    focus.visitAncestorElements((element) {
      if (element == target) inside = true;
      return !inside;
    });
    return inside || focus == target;
  }

  Finder title(String text) => find.descendant(
    of: find.byKey(const Key('updates_status_title')),
    matching: find.text(text),
  );

  group('the five panel states', () {
    testWidgets('Software updates: the installed version, Check for updates, '
        'and the encoder on the check', (tester) async {
      await pump(tester, _running);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesPageInstalled('1.0.0')), findsOneWidget);
      expect(title(l10n.updatesPanelSoftware), findsOneWidget);
      expect(find.text(l10n.updatesPageIdle), findsOneWidget);
      expect(focused(tester, 'updates_check'), isTrue);

      await tester.tap(find.byKey(const Key('updates_check')));
      await tester.pumpAndSettle();
      verify(update.check).called(1);
      // Load from USB is Part 8's; nothing stands in for it yet.
      expect(find.textContaining('USB'), findsNothing);
    });

    testWidgets('Update available: the version and its size, one button to '
        'accept it, and nothing downloads until it is pressed', (tester) async {
      await pump(
        tester,
        _running.copyWith(phase: UpdatePhase.available, available: _offer),
      );
      final l10n = l10nOf(tester);

      expect(title(l10n.updatesPanelAvailable), findsOneWidget);
      expect(
        find.text(l10n.updatesPageVersionSize('1.1.0', 412)),
        findsOneWidget,
      );
      expect(focused(tester, 'updates_download'), isTrue);
      verifyNever(update.startDownload);

      await tester.tap(find.byKey(const Key('updates_download')));
      await tester.pumpAndSettle();
      verify(update.startDownload).called(1);
    });

    testWidgets('a manifest without a size shows the version alone', (
      tester,
    ) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.available,
          available: UpdateManifest(version: _offer.version, bundle: 'b'),
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesPageVersion('1.1.0')), findsOneWidget);
    });

    testWidgets('Downloading: a real bar and Cancel, with the check and the '
        'channel locked', (tester) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.downloading,
          available: _offer,
          progress: 0.42,
        ),
      );
      final l10n = l10nOf(tester);

      expect(title(l10n.updatesPanelDownloading), findsOneWidget);
      final bar = tester.widget<FractionallySizedBox>(
        find.byKey(const Key('updates_progress')),
      );
      expect(bar.widthFactor, closeTo(0.42, 0.001));
      expect(find.text(l10n.updatesPagePercent(42)), findsOneWidget);
      expect(focused(tester, 'updates_cancel'), isTrue);
      expect(
        tester
            .widget<LoopSelect<bool>>(find.byKey(const Key('updates_channel')))
            .enabled,
        isFalse,
      );

      await tester.tap(find.byKey(const Key('updates_check')));
      await tester.tap(find.byKey(const Key('updates_cancel')));
      await tester.pumpAndSettle();
      verifyNever(update.check);
      verify(update.cancelDownload).called(1);
    });

    testWidgets('Ready to install: Install and restart goes through the power '
        "flow's restart, never a reboot of its own", (tester) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.staged,
          available: UpdateManifest(version: _offer.version, bundle: ''),
        ),
      );
      final l10n = l10nOf(tester);

      expect(title(l10n.updatesPanelReady), findsOneWidget);
      expect(find.text(l10n.updatesPageVersion('1.1.0')), findsOneWidget);
      expect(find.text(l10n.updatesRestartBusySubtitle), findsOneWidget);
      expect(focused(tester, 'updates_install_restart'), isTrue);

      await tester.tap(find.byKey(const Key('updates_install_restart')));
      await tester.pumpAndSettle();
      verify(
        () => power.restart(
          const PowerSnapshot(currentSessionName: 'set'),
          save: any(named: 'save'),
        ),
      ).called(1);
    });

    testWidgets('Update paused: the interrupted sentence, Retry and Cancel, '
        'and the encoder on Retry', (tester) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.interrupted,
          interrupted: Version.parse('1.1.0'),
        ),
      );
      final l10n = l10nOf(tester);

      expect(title(l10n.updatesPanelPaused), findsOneWidget);
      expect(
        find.text('Download interrupted. The current software is unchanged.'),
        findsOneWidget,
      );
      expect(find.text(l10n.updatesPageVersion('1.1.0')), findsOneWidget);
      expect(focused(tester, 'updates_retry'), isTrue);

      await tester.tap(find.byKey(const Key('updates_retry')));
      await tester.pumpAndSettle();
      verify(update.retryInterrupted).called(1);

      await tester.tap(find.byKey(const Key('updates_discard')));
      await tester.pumpAndSettle();
      verify(update.discardInterrupted).called(1);
    });
  });

  group('failures', () {
    testWidgets('a failed download names the download and retries it — not '
        'the check', (tester) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.error,
          failure: UpdateFailure.download,
          available: _offer,
          errorMessage: 'connection reset',
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesPageDownloadFailed), findsOneWidget);
      expect(focused(tester, 'updates_retry'), isTrue);

      await tester.tap(find.byKey(const Key('updates_retry')));
      await tester.pumpAndSettle();
      verify(update.startDownload).called(1);
      verifyNever(update.check);
    });

    testWidgets('a failed check says so, and its retry is the check', (
      tester,
    ) async {
      await pump(
        tester,
        _running.copyWith(
          phase: UpdatePhase.error,
          failure: UpdateFailure.check,
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesPageCheckFailed), findsOneWidget);
      expect(find.byKey(const Key('updates_retry')), findsNothing);
      expect(focused(tester, 'updates_check'), isTrue);
    });

    testWidgets('a rolled-back update stays noticed, naming both versions, '
        'until it is dismissed', (tester) async {
      await pump(
        tester,
        _running.copyWith(
          rollback: (
            attempted: Version.parse('1.1.0'),
            restored: Version.parse('1.0.0'),
          ),
        ),
      );

      expect(
        find.text(
          'Segno 1.1.0 did not start, so the console went back to 1.0.0.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('updates_rollback_dismiss')));
      await tester.pumpAndSettle();
      verify(update.dismissRollback).called(1);
    });

    testWidgets('no notice without a rollback', (tester) async {
      await pump(tester, _running);
      expect(find.byKey(const Key('updates_rollback_notice')), findsNothing);
    });
  });

  group('the encoder', () {
    testWidgets("lands on each state's action as the state arrives", (
      tester,
    ) async {
      await pump(tester, _running);
      expect(focused(tester, 'updates_check'), isTrue);

      await emit(
        tester,
        _running.copyWith(phase: UpdatePhase.available, available: _offer),
      );
      expect(focused(tester, 'updates_download'), isTrue);

      await emit(
        tester,
        _running.copyWith(phase: UpdatePhase.downloading, available: _offer),
      );
      expect(focused(tester, 'updates_cancel'), isTrue);

      await emit(
        tester,
        _running.copyWith(phase: UpdatePhase.staged, available: _offer),
      );
      expect(focused(tester, 'updates_install_restart'), isTrue);
    });

    testWidgets('a press on the focused action runs it', (tester) async {
      await pump(
        tester,
        _running.copyWith(phase: UpdatePhase.available, available: _offer),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      verify(update.startDownload).called(1);
    });
  });

  group('settings and links', () {
    testWidgets('Check automatically is a pick of Off and On', (tester) async {
      await pump(tester, _running);

      await tester.tap(find.byKey(const Key('updates_auto_check_off')));
      await tester.pumpAndSettle();
      verify(() => update.setAutoCheck(value: false)).called(1);
    });

    testWidgets('the channel is a select', (tester) async {
      await pump(tester, _running);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesPageChannelProduction), findsOneWidget);
      await tester.tap(find.byKey(const Key('updates_channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('updates_channel_experimental')));
      await tester.pumpAndSettle();
      verify(() => update.setExperimentalChannel(value: true)).called(1);
    });

    testWidgets('About and Controller firmware are rows on the page', (
      tester,
    ) async {
      await pump(tester, _running);
      expect(find.byKey(const Key('updates_about_row')), findsOneWidget);
      expect(find.byKey(const Key('updates_controller_row')), findsOneWidget);
    });

    testWidgets('an unsupported platform offers no check and no automatic '
        'settings, and still leads to About', (tester) async {
      await pump(tester, const UpdateState());
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesUnsupportedBanner), findsOneWidget);
      expect(find.byKey(const Key('updates_check')), findsNothing);
      expect(find.byKey(const Key('updates_automatic')), findsNothing);
      expect(find.byKey(const Key('updates_about_row')), findsOneWidget);
    });
  });
}
