import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/stage_status_bar.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';

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

/// The cross-surface invariant behind `SurfaceTheme.modePair` (#768).
///
/// The desktop `ModeIndicator` and the stage status bar's mode pill each used
/// to hold their own three-arm switch over the same token pairs, each
/// commented "these can never disagree", with a test per widget that only
/// checked its own arm — so nothing in the build would have noticed if one
/// arm had been edited. This file is the enforcement: it asserts that what
/// each surface actually PAINTS equals what the resolver returns, for every
/// mode, in both flavors. Change one widget's arm back to a literal pair and
/// this fails; the two per-widget tests would not.
void main() {
  late _MockLooperBloc bloc;
  late _MockControlCubit control;
  late _MockSessionCubit session;
  late _MockPerformanceRecorderCubit recorder;
  late _MockTransportClockCubit clock;

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

  /// The (outline, fill) the desktop chrome's `ModeIndicator` renders.
  Future<(Color?, Color?)> indicatorPair(
    WidgetTester tester,
    InteractionMode mode,
    ThemeData theme,
  ) async {
    // A fresh element per mode: the widget takes the mode as an argument, but
    // unmounting keeps this symmetric with [pillPair] below.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpApp(
      theme: theme,
      Scaffold(
        body: ModeIndicator(mode: mode, onToggle: () {}),
      ),
    );
    final box =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(const Key('tracks_mode_indicator')),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    return (box.border!.top.color, box.color);
  }

  /// The (outline, fill) the stage status bar's mode pill renders.
  Future<(Color?, Color?)> pillPair(
    WidgetTester tester,
    InteractionMode mode,
    ThemeData theme,
  ) async {
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: ControlState(mode: mode),
    );
    // The pill reads the mode through `context.select`, so a re-pump of the
    // same tree would keep serving the previous one — unmount for a fresh
    // element. (The flavor swap is `pumpApp`'s own job.)
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
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
    final box =
        tester
                .widget<Container>(find.byKey(const Key('stage_mode_pill')))
                .decoration!
            as BoxDecoration;
    return (box.border!.top.color, box.color);
  }

  for (final (flavorName, theme) in [
    ('neon', AppTheme.neon),
    ('high contrast', AppTheme.highContrast),
  ]) {
    group('in the $flavorName flavor', () {
      for (final mode in InteractionMode.values) {
        testWidgets(
          'both mode surfaces paint SurfaceTheme.modePair for ${mode.name}',
          (tester) async {
            final expected = theme.extension<SurfaceTheme>()!.modePair(mode);

            final indicator = await indicatorPair(tester, mode, theme);
            final pill = await pillPair(tester, mode, theme);

            // Each surface against the resolver — a widget that stopped
            // calling it (or called it and then overrode an arm) fails here…
            expect(indicator, (
              expected.outline,
              expected.fill,
            ), reason: 'ModeIndicator must render the resolved pair');
            expect(pill, (
              expected.outline,
              expected.fill,
            ), reason: 'the stage mode pill must render the resolved pair');
            // …and against each other, which is the invariant both widgets'
            // comments used to only claim.
            expect(indicator, pill);
          },
        );
      }
    });
  }

  test('every mode has a distinct pair', () {
    // The mapping's whole job is telling the three modes apart at a glance
    // (rec red, mute green, FX blue — owner's call, 2026-08-20). Two modes
    // resolving to one colour would satisfy every "reads the resolver" check
    // above while making the chip say nothing.
    for (final surface in [SurfaceTheme.dark, SurfaceTheme.highContrast]) {
      final outlines = InteractionMode.values
          .map((m) => surface.modePair(m).outline)
          .toSet();
      final fills = InteractionMode.values
          .map((m) => surface.modePair(m).fill)
          .toSet();
      expect(outlines, hasLength(InteractionMode.values.length));
      expect(fills, hasLength(InteractionMode.values.length));
    }
  });
}
