import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/stage_status_bar.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockControlCubit extends MockCubit<ControlState>
    implements ControlCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockTransportClockCubit extends MockCubit<TransportClockState>
    implements TransportClockCubit {}

void main() {
  late _MockLooperBloc bloc;
  late _MockControlCubit control;
  late _MockSessionCubit session;
  late _MockPerformanceRecorderCubit recorder;
  late _MockTransportClockCubit clock;
  late AppLocalizations l10n;

  setUpAll(() async {
    registerFallbackValue(InteractionMode.record);
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    control = _MockControlCubit();
    session = _MockSessionCubit();
    recorder = _MockPerformanceRecorderCubit();
    clock = _MockTransportClockCubit();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    whenListen(
      clock,
      const Stream<TransportClockState>.empty(),
      initialState: const TransportClockState(),
    );
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: const ControlState(),
    );
    whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: const SessionState(),
    );
    whenListen(
      recorder,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: const PerformanceRecorderIdle(),
    );
  });

  Future<void> pump(WidgetTester tester, {ThemeData? theme}) {
    // The strip is drawn for the console's fixed 1920-wide panel; the default
    // 800px test surface would cramp the readouts into each other.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpApp(
      theme: theme,
      MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<ControlCubit>.value(value: control),
          BlocProvider<SessionCubit>.value(value: session),
          BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
          BlocProvider<TransportClockCubit>.value(value: clock),
        ],
        child: const Scaffold(body: Align(child: StageStatusBar())),
      ),
    );
  }

  SurfaceTheme surface(WidgetTester tester) => Theme.of(
    tester.element(find.byKey(const Key('stage_status_bar'))),
  ).extension<SurfaceTheme>()!;

  group('session block', () {
    testWidgets('shows the open session name', (tester) async {
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(currentSessionName: 'Bridge idea 3'),
      );
      await pump(tester);

      expect(find.text('Bridge idea 3'), findsOneWidget);
    });

    testWidgets('falls back to Unsaved in italic with no session open', (
      tester,
    ) async {
      await pump(tester);

      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('stage_session_name')),
          matching: find.byType(Text),
        ),
      );
      expect(text.data, l10n.sessionUnsaved);
      expect(text.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('tapping the block opens the Sessions dialog', (tester) async {
      when(() => session.refreshSessions()).thenAnswer((_) async {});
      await pump(tester);

      await tester.tap(find.byKey(const Key('stage_session_block')));
      await tester.pumpAndSettle();

      verify(() => session.refreshSessions()).called(1);
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });
  });

  group('mode pill', () {
    testWidgets('reads REC in record mode and takes no tap', (tester) async {
      await pump(tester);

      expect(find.text(l10n.interactionModeRec), findsOneWidget);

      // A readout, not a control: tapping it must dispatch nothing.
      await tester.tap(
        find.byKey(const Key('stage_mode_pill')),
        warnIfMissed: false,
      );
      await tester.pump();
      verifyNever(() => control.toggleMode());
      verifyNever(() => control.setMode(any()));
    });

    testWidgets('reads FX in fx mode', (tester) async {
      whenListen(
        control,
        const Stream<ControlState>.empty(),
        initialState: const ControlState(mode: InteractionMode.fx),
      );
      await pump(tester);
      expect(find.text(l10n.interactionModeFx), findsOneWidget);
    });

    testWidgets('reads MUTE in mute mode', (tester) async {
      whenListen(
        control,
        const Stream<ControlState>.empty(),
        initialState: const ControlState(mode: InteractionMode.mute),
      );
      await pump(tester);
      expect(find.text(l10n.interactionModeMute), findsOneWidget);
    });

    Future<(Color?, Color?)> pillOf(
      WidgetTester tester,
      InteractionMode mode, {
      ThemeData? theme,
    }) async {
      whenListen(
        control,
        const Stream<ControlState>.empty(),
        initialState: ControlState(mode: mode),
      );
      // Unmount first: re-pumping the same tree reuses the element, and the
      // pill's `context.select` would keep serving the previous mode.
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(tester, theme: theme);
      final box =
          tester
                  .widget<Container>(find.byKey(const Key('stage_mode_pill')))
                  .decoration!
              as BoxDecoration;
      return (box.border!.top.color, box.color);
    }

    testWidgets('wears rec red, mute green and FX blue', (tester) async {
      // #693 — the owner's call from the bench: mute reads GREEN on every
      // surface. Rec stays red and FX stays accent-blue.
      final s = AppTheme.neon.extension<SurfaceTheme>()!;
      expect(await pillOf(tester, InteractionMode.record), (
        s.rec,
        s.recSurface,
      ));
      expect(await pillOf(tester, InteractionMode.mute), (
        s.success,
        s.successSurface,
      ));
      expect(await pillOf(tester, InteractionMode.fx), (
        s.accent,
        s.accentSurface,
      ));
    });

    testWidgets('all three fills follow the high-contrast flavor', (
      tester,
    ) async {
      // The regression this pins: mute's fill was once an inline
      // `success.withValues(alpha: 0.14)`, which is a no-op difference in the
      // dark flavor (`successSurface` is alpha 0x24 ≈ 0.141) and therefore
      // INVISIBLE to the test above. High contrast is the only flavor that
      // overrides these washes, so it is the only one that catches a hardcode:
      // it lifts rec and accent to 0.2 while a hardcoded mute stayed at 0.14,
      // leaving mute visibly weaker than the two pills beside it on the
      // accessibility flavor.
      final hc = AppTheme.highContrast;
      final s = hc.extension<SurfaceTheme>()!;

      final rec = await pillOf(tester, InteractionMode.record, theme: hc);
      final mute = await pillOf(tester, InteractionMode.mute, theme: hc);
      final fx = await pillOf(tester, InteractionMode.fx, theme: hc);

      expect(rec, (s.rec, s.recSurface));
      expect(mute, (s.success, s.successSurface));
      expect(fx, (s.accent, s.accentSurface));

      // Stated as the reading rather than the hex: the three pills must sit at
      // one fill weight, and that weight must be the boosted one.
      expect(mute.$2!.a, rec.$2!.a);
      expect(
        mute.$2!.a,
        greaterThan(SurfaceTheme.dark.successSurface.a),
        reason: 'high contrast must boost the mute wash, not pin it',
      );
    });
  });

  group('bank pair', () {
    testWidgets('fills the active half and takes no tap', (tester) async {
      await pump(tester);

      Color? fillOf(String key) =>
          (tester.widget<Container>(find.byKey(Key(key))).decoration
                  as BoxDecoration?)
              ?.color ??
          tester.widget<Container>(find.byKey(Key(key))).color;

      expect(fillOf('stage_bank_0'), surface(tester).control);
      expect(fillOf('stage_bank_1'), isNull);

      await tester.tap(
        find.byKey(const Key('stage_bank_1')),
        warnIfMissed: false,
      );
      await tester.pump();
      verifyNever(() => control.browseBank(any()));
      verifyNever(() => control.toggleBankWithCursor());
    });

    testWidgets('follows the active bank to B', (tester) async {
      whenListen(
        control,
        const Stream<ControlState>.empty(),
        initialState: const ControlState(activeBank: 1, cursor: 4),
      );
      await pump(tester);

      final b = tester.widget<Container>(
        find.byKey(const Key('stage_bank_1')),
      );
      expect(b.color, surface(tester).control);
    });
  });

  group('record light', () {
    testWidgets('rests as a dot with no elapsed readout', (tester) async {
      await pump(tester);

      expect(find.byKey(const Key('stage_record_light')), findsOneWidget);
      expect(find.byKey(const Key('stage_record_elapsed')), findsNothing);
    });

    testWidgets('shows the stop square and elapsed time while armed', (
      tester,
    ) async {
      whenListen(
        recorder,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: const PerformanceRecorderArmed(
          elapsed: Duration(minutes: 2, seconds: 14),
          overrun: false,
        ),
      );
      await pump(tester);

      expect(find.text('02:14'), findsOneWidget);
      final light = tester.widget<Container>(
        find.byKey(const Key('stage_record_light')),
      );
      final decoration = light.decoration! as BoxDecoration;
      expect(decoration.color, surface(tester).recSurface);
    });
  });

  group('tempo clock', () {
    testWidgets('hides tempo and beat dots on the tempo-free path', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byKey(const Key('stage_tempo_bpm')), findsNothing);
      expect(find.byKey(const Key('stage_count_in')), findsNothing);
      expect(find.text('0:00:00'), findsOneWidget);
    });

    testWidgets('shows bpm, beat dots and the elapsed transport clock', (
      tester,
    ) async {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(
          status: EngineStatus(isConnected: true, sampleRate: 48000),
          transport: TransportState(
            isRunning: true,
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
          ),
        ),
      );
      whenListen(
        clock,
        const Stream<TransportClockState>.empty(),
        initialState: const TransportClockState(
          elapsed: Duration(seconds: 11),
          running: true,
        ),
      );
      await pump(tester);

      expect(find.text(l10n.stageTempoBpm('120.0')), findsOneWidget);
      expect(find.text('0:00:11'), findsOneWidget);
      expect(find.byKey(const Key('stage_count_in')), findsNothing);
    });

    testWidgets('reads the unpadded hour past the hour mark', (tester) async {
      whenListen(
        clock,
        const Stream<TransportClockState>.empty(),
        initialState: const TransportClockState(
          elapsed: Duration(hours: 1, minutes: 2, seconds: 3),
          running: true,
        ),
      );
      await pump(tester);

      expect(find.text('1:02:03'), findsOneWidget);
    });

    testWidgets('shows the count-in word while counting in', (tester) async {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(
          status: EngineStatus(isConnected: true, sampleRate: 48000),
          transport: TransportState(
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
            countingIn: true,
            countInBeatsLeft: 4,
          ),
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('stage_count_in')), findsOneWidget);
      expect(find.text(l10n.stageCountIn), findsOneWidget);
    });
  });

  // The bar is a set of live readouts, so every feed's UPDATE wiring is
  // pinned here: each test drives its cubit's stream after the first frame
  // and asserts the strip follows. Boot-state rendering alone would stay
  // green with a `buildWhen` or select slice that never fires again — the
  // frozen-at-boot console these tests exist to prevent.
  //
  // Every emit is followed by TWO pumps: the first flushes the microtask that
  // delivers the stream event to the provider's listener (which only marks
  // the element dirty), the second builds the frame that renders it.
  group('transitions', () {
    testWidgets('the session name follows a load and a rename', (
      tester,
    ) async {
      final states = StreamController<SessionState>.broadcast();
      addTearDown(states.close);
      whenListen(
        session,
        states.stream,
        initialState: const SessionState(),
      );
      await pump(tester);
      expect(find.text(l10n.sessionUnsaved), findsOneWidget);

      states.add(const SessionState(currentSessionName: 'Bridge idea 3'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Bridge idea 3'), findsOneWidget);
      expect(find.text(l10n.sessionUnsaved), findsNothing);

      states.add(const SessionState(currentSessionName: 'Chorus 9'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Chorus 9'), findsOneWidget);
      expect(find.text('Bridge idea 3'), findsNothing);
    });

    testWidgets('the mode pill follows a mode change to FX', (tester) async {
      final states = StreamController<ControlState>.broadcast();
      addTearDown(states.close);
      whenListen(
        control,
        states.stream,
        initialState: const ControlState(),
      );
      await pump(tester);
      expect(find.text(l10n.interactionModeRec), findsOneWidget);

      states.add(const ControlState(mode: InteractionMode.fx));
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.interactionModeFx), findsOneWidget);
      expect(find.text(l10n.interactionModeRec), findsNothing);
    });

    testWidgets('the bank pair follows the BANK footswitch to B', (
      tester,
    ) async {
      final states = StreamController<ControlState>.broadcast();
      addTearDown(states.close);
      whenListen(
        control,
        states.stream,
        initialState: const ControlState(),
      );
      await pump(tester);
      expect(
        tester.widget<Container>(find.byKey(const Key('stage_bank_0'))).color,
        surface(tester).control,
      );

      states.add(const ControlState(activeBank: 1, cursor: 4));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Container>(find.byKey(const Key('stage_bank_1'))).color,
        surface(tester).control,
      );
      expect(
        tester.widget<Container>(find.byKey(const Key('stage_bank_0'))).color,
        isNull,
      );
    });

    testWidgets('the record light arms mid-set and disarms again', (
      tester,
    ) async {
      final states = StreamController<PerformanceRecorderState>.broadcast();
      addTearDown(states.close);
      whenListen(
        recorder,
        states.stream,
        initialState: const PerformanceRecorderIdle(),
      );
      await pump(tester);
      expect(find.byKey(const Key('stage_record_elapsed')), findsNothing);

      states.add(
        const PerformanceRecorderArmed(
          elapsed: Duration(minutes: 2, seconds: 14),
          overrun: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('02:14'), findsOneWidget);

      states.add(const PerformanceRecorderIdle());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('stage_record_elapsed')), findsNothing);
      expect(find.text('02:14'), findsNothing);
    });

    testWidgets('the clock ticks and the count-in word arrives live', (
      tester,
    ) async {
      final looperStates = StreamController<LooperState>.broadcast();
      addTearDown(looperStates.close);
      whenListen(
        bloc,
        looperStates.stream,
        initialState: const LooperState(
          status: EngineStatus(isConnected: true, sampleRate: 48000),
          transport: TransportState(
            isRunning: true,
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
          ),
        ),
      );
      final clockStates = StreamController<TransportClockState>.broadcast();
      addTearDown(clockStates.close);
      whenListen(
        clock,
        clockStates.stream,
        initialState: const TransportClockState(
          elapsed: Duration(seconds: 11),
          running: true,
        ),
      );
      await pump(tester);
      expect(find.text('0:00:11'), findsOneWidget);

      // The next second of elapsed transport time — the cubit's ticker
      // emitting, nothing changing on the engine stream at all.
      clockStates.add(
        const TransportClockState(
          elapsed: Duration(seconds: 12),
          running: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('0:00:12'), findsOneWidget);
      expect(find.text('0:00:11'), findsNothing);

      looperStates.add(
        const LooperState(
          status: EngineStatus(isConnected: true, sampleRate: 48000),
          transport: TransportState(
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
            countingIn: true,
            countInBeatsLeft: 4,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('stage_count_in')), findsOneWidget);
    });
  });
}
