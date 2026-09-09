import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late PerformanceRepository performance;
  late ControlCubit control;
  late PedalRepository pedalRepo;

  setUpAll(() {
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setLooperMode(any())).thenReturn(EngineResult.ok);
    when(
      () => repository.looperModeGate(any()),
    ).thenReturn(LooperModeGate.open);

    settings = SettingsRepository(store: FakeKeyValueStore());
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    pedalRepo = PedalRepository(const NoopPedalTransport());
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
  });

  /// Seeds the mock bloc's [LooperState] both as the static `.state` and as
  /// the (empty, by default) stream's initial value.
  void seed(LooperState state, {Stream<LooperState>? stream}) {
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      stream ?? const Stream<LooperState>.empty(),
      initialState: state,
    );
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<ControlCubit>.value(value: control),
          ],
          child: const Scaffold(
            body: SingleChildScrollView(child: LooperModeSection()),
          ),
        ),
      ),
    ),
  );

  testWidgets('renders all five modes with Multi selected by default', (
    tester,
  ) async {
    seed(const LooperState());
    await pump(tester);

    for (final mode in LooperMode.values) {
      expect(
        find.byKey(Key('looperMode_option_${mode.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('lays modes out as a vertical list', (tester) async {
    seed(const LooperState());
    await pump(tester);

    expect(find.byKey(const Key('looperMode_list')), findsOneWidget);
    final multi = tester.getTopLeft(
      find.byKey(const Key('looperMode_option_multi')),
    );
    final sync = tester.getTopLeft(
      find.byKey(const Key('looperMode_option_sync')),
    );
    expect(sync.dy, greaterThan(multi.dy));
    expect(sync.dx, multi.dx);
  });

  testWidgets('an open gate dispatches the change at once, with no dialog', (
    tester,
  ) async {
    seed(const LooperState());
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_sync')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
    verify(() => bloc.add(const LooperModeChanged(LooperMode.sync))).called(1);
  });

  testWidgets('re-selecting the already-active mode is a no-op', (
    tester,
  ) async {
    seed(const LooperState());
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_multi')));
    await tester.pumpAndSettle();

    verifyNever(() => bloc.add(any()));
    verifyNever(() => repository.looperModeGate(any()));
  });

  testWidgets(
    'playing loops ask to stop and switch; confirming dispatches the change '
    'and clears nothing',
    (tester) async {
      when(
        () => repository.looperModeGate(LooperMode.sync),
      ).thenReturn(LooperModeGate.playing);
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);
      expect(find.text('Stop loops and switch'), findsOneWidget);
      verifyNever(() => bloc.add(any()));

      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.sync)),
      ).called(1);
      // The engine stops the loops itself; no take is cleared for a switch.
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
  );

  testWidgets('cancelling the stop-and-switch dialog changes nothing', (
    tester,
  ) async {
    when(
      () => repository.looperModeGate(LooperMode.sync),
    ).thenReturn(LooperModeGate.playing);
    seed(
      const LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
      ),
    );
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_sync')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('console_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
    verifyNever(() => bloc.add(any()));
    verifyNever(() => repository.clear(channel: any(named: 'channel')));
  });

  testWidgets('a refused change names its reason and dispatches nothing', (
    tester,
  ) async {
    when(
      () => repository.looperModeGate(LooperMode.multi),
    ).thenReturn(LooperModeGate.spans);
    seed(
      const LooperState(
        transport: TransportState(looperMode: LooperMode.sync),
        tracks: [
          Track(state: TrackState.stopped, lengthFrames: 4000),
          Track(channel: 1, state: TrackState.stopped, lengthFrames: 8000),
        ],
      ),
    );
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_multi')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
    expect(
      find.byKey(const Key('looperMode_refused_snackbar')),
      findsOneWidget,
    );
    expect(
      find.text('The recorded loop lengths do not fit this mode.'),
      findsOneWidget,
    );
    verifyNever(() => bloc.add(any()));
  });
}
