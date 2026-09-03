import 'dart:async';

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
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late _MockLooperRepository looper;

  setUp(() {
    final settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    looper = _MockLooperRepository();
    when(
      () => looper.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    // The control cubit projects the pedal frame from looper.state (its
    // synchronous snapshot); seed() keeps it in step with the bloc state.
    when(() => looper.state).thenReturn(const LooperState());
    // The row reads the mode / cursor / bank from the shared control cubit.
    final pedalRepo = PedalRepository(SimulatorPedalLink());
    addTearDown(pedalRepo.dispose);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    when(() => looper.state).thenReturn(state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<ControlCubit>.value(value: control),
        ],
        child: const Scaffold(body: TrackMeterRow()),
      ),
    ),
  );

  Color borderColor(WidgetTester tester, int channel) {
    final container = tester.widget<Container>(
      find.byKey(Key('pedalScreen_bar_$channel')),
    );
    return ((container.decoration! as BoxDecoration).border! as Border)
        .top
        .color;
  }

  testWidgets('renders a bar only for the active bank tracks', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]));
    await pump(tester);

    // Bank A: channels 0..3 render; 4..7 do not.
    for (var c = 0; c < 4; c++) {
      expect(find.byKey(Key('pedalScreen_bar_$c')), findsOneWidget);
    }
    expect(find.byKey(const Key('pedalScreen_bar_4')), findsNothing);
  });

  testWidgets('the selected track bar has a white border', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 4; i++) Track(channel: i)]));
    control.selectTrack(1);
    await pump(tester);

    expect(borderColor(tester, 1), Colors.white);
    expect(borderColor(tester, 0), Colors.transparent);
  });

  group('rebuild scope', () {
    // The whole point of #654 (the same split #646 gave TracksView): a level
    // tick on one track must not rebuild the other tiles. Each tile's keyed
    // Container is created fresh every `_TrackMeter.build` run (it carries
    // per-build values, so it is never const-canonicalised), which makes
    // widget identity an honest rebuild detector: the same instance across a
    // pump means neither the row nor that tile's slot re-ran.
    late StreamController<LooperState> states;

    setUp(() => states = StreamController<LooperState>.broadcast());
    tearDown(() => states.close());

    void seedStream(LooperState initial) {
      when(() => bloc.state).thenReturn(initial);
      when(() => looper.state).thenReturn(initial);
      whenListen(bloc, states.stream, initialState: initial);
    }

    Container bar(WidgetTester tester, int channel) =>
        tester.widget<Container>(find.byKey(Key('pedalScreen_bar_$channel')));

    testWidgets(
      'a level-only change on one track does not rebuild the other tiles',
      (tester) async {
        const quiet = LooperState(tracks: [Track(), Track(channel: 1)]);
        seedStream(quiet);
        await pump(tester);

        final tile0 = bar(tester, 0);
        final tile1 = bar(tester, 1);

        // Exactly what a moving meter emits: same structure, new levels and a
        // new playhead — on track 0 only.
        const loud = LooperState(
          tracks: [
            Track(rms: 0.8, peak: 0.9, playheadFrames: 4410),
            Track(channel: 1),
          ],
        );
        when(() => bloc.state).thenReturn(loud);
        states.add(loud);
        await tester.pump();

        expect(
          identical(tile0, bar(tester, 0)),
          isFalse,
          reason: 'track 0 level moved -- its own tile must rebuild',
        );
        expect(
          identical(tile1, bar(tester, 1)),
          isTrue,
          reason:
              "track 0's meter tick rebuilt track 1's tile -- the row or "
              'slot selector is leaking live audio fields (see #654)',
        );
      },
    );

    testWidgets('a structural change still rebuilds the row', (tester) async {
      const both = LooperState(tracks: [Track(), Track(channel: 1)]);
      seedStream(both);
      await pump(tester);

      expect(find.byKey(const Key('pedalScreen_bar_1')), findsOneWidget);

      // Losing a track is exactly the kind of change the row's structure
      // selector exists to show: it must get through.
      const dropped = LooperState(tracks: [Track()]);
      when(() => bloc.state).thenReturn(dropped);
      states.add(dropped);
      await tester.pump();

      expect(
        find.byKey(const Key('pedalScreen_bar_1')),
        findsNothing,
        reason: 'the structure selector swallowed a track removal',
      );
    });
  });
}
