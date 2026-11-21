import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/capture_count.dart';
import 'package:segno/looper/view/track_capture_count.dart';
import 'package:segno/looper/view/track_column.dart' show SlotFigure;
import 'package:segno/theme/theme.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc;

class _MockLooperRepository extends Mock implements LooperRepository;

void main() {
  group('captureCountOf (#1936)', () {
    test('counts the bar being recorded toward the target', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 2500, targetFrames: 8000),
          framesPerBar: 2000,
          sampleRate: 1000,
        ),
        (bar: 2, ofBars: 4, seconds: 0, approxBars: 0),
      );
    });

    test('starts at bar 1', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 1, targetFrames: 8000),
          framesPerBar: 2000,
          sampleRate: 1000,
        ).bar,
        1,
      );
    });

    test('holds the last bar through the seam past the target', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 8010, targetFrames: 8000),
          framesPerBar: 2000,
          sampleRate: 1000,
        ),
        (bar: 4, ofBars: 4, seconds: 0, approxBars: 0),
      );
    });

    test('counts bars without a total when only a press ends the take', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 4500),
          framesPerBar: 2000,
          sampleRate: 1000,
        ),
        (bar: 3, ofBars: 0, seconds: 0, approxBars: 0),
      );
    });

    test('counts whole seconds with no bar grid', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 7999),
          framesPerBar: null,
          sampleRate: 1000,
        ),
        (bar: 0, ofBars: 0, seconds: 7, approxBars: 0),
      );
    });
  });

  group("the beat analysis's estimate (#1936)", () {
    test('adds whole bars to a take with no grid', () {
      // 120 BPM in 4/4 at 1 kHz: a 2000-frame bar.
      expect(
        captureCountOf(
          const TakeCapture(frames: 7000),
          framesPerBar: null,
          sampleRate: 1000,
          estimateFramesPerBar: estimateFramesPerBar(120, 4, 1000),
        ),
        (bar: 0, ofBars: 0, seconds: 7, approxBars: 3),
      );
    });

    test('is not used where the grid counts bars', () {
      expect(
        captureCountOf(
          const TakeCapture(frames: 7000),
          framesPerBar: 2000,
          sampleRate: 1000,
          estimateFramesPerBar: 1000,
        ).approxBars,
        0,
      );
    });

    test('is nothing without an estimate', () {
      expect(estimateFramesPerBar(0, 4, 48000), isNull);
    });
  });

  test('elapsedFigure reads minutes and two-digit seconds', () {
    expect(elapsedFigure(7), '0:07');
    expect(elapsedFigure(92), '1:32');
  });

  group('TrackCaptureCount', () {
    late LooperBloc bloc;
    late LooperRepository repository;
    late StreamController<Playhead> playheads;

    setUp(() {
      bloc = _MockLooperBloc();
      repository = _MockLooperRepository();
      playheads = StreamController<Playhead>.broadcast();
      when(() => repository.playheads).thenAnswer((_) => playheads.stream);
      when(() => repository.playhead).thenReturn(const Playhead());
    });

    tearDown(() => unawaited(playheads.close()));

    void seed(TransportState transport) {
      final state = LooperState(
        status: const EngineStatus(sampleRate: 1000),
        transport: transport,
      );
      when(() => bloc.state).thenReturn(state);
      whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    }

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: BlocProvider<LooperBloc>.value(
            value: bloc,
            child: const Scaffold(
              body: TrackCaptureCount(
                channel: 0,
                figureStyle: TextStyle(fontSize: 24),
                unitStyle: TextStyle(fontSize: 17),
              ),
            ),
          ),
        ),
      ),
    );

    SlotFigure figure(WidgetTester tester) =>
        tester.widget<SlotFigure>(find.byType(SlotFigure));

    testWidgets('reads bar of bars on a take toward a target', (tester) async {
      // 120 BPM at 1 kHz: a 2000-frame bar.
      seed(
        const TransportState(tempoBpm: 120, tempoSource: TempoSource.manual),
      );
      when(() => repository.playhead).thenReturn(
        const Playhead(
          captures: [TakeCapture(frames: 2500, targetFrames: 8000)],
        ),
      );
      await pump(tester);

      expect(figure(tester).figure, '2 / 4');
      expect(figure(tester).unit, 'bars');
    });

    testWidgets('follows the take as it records', (tester) async {
      seed(const TransportState());
      await pump(tester);
      expect(figure(tester).figure, '0:00');

      playheads.add(const Playhead(captures: [TakeCapture(frames: 7000)]));
      await tester.pump();
      await tester.pump();

      expect(figure(tester).figure, '0:07');
      expect(figure(tester).unit, '');
    });

    testWidgets('shows the estimate beside the time once there is one', (
      tester,
    ) async {
      seed(const TransportState());
      when(() => repository.playhead).thenReturn(
        const Playhead(
          captures: [TakeCapture(frames: 9000)],
          tempoEstimateBpm: 120,
          tempoEstimateTrack: 0,
        ),
      );
      await pump(tester);

      expect(figure(tester).figure, '≈ 4');
      expect(figure(tester).unit, 'bars');
    });

    testWidgets('shows no estimate on a take the analysis does not hear', (
      tester,
    ) async {
      seed(const TransportState());
      when(() => repository.playhead).thenReturn(
        const Playhead(
          captures: [TakeCapture(frames: 9000)],
          tempoEstimateBpm: 120,
          tempoEstimateTrack: 3,
        ),
      );
      await pump(tester);

      expect(figure(tester).figure, '0:09');
      expect(figure(tester).unit, '');
    });
  });
}
