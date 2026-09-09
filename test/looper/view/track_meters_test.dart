import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/theme/theme.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late LooperBloc bloc;

  setUp(() {
    bloc = _MockLooperBloc();
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pumpLeaf(WidgetTester tester, Widget leaf) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      home: BlocProvider<LooperBloc>.value(
        value: bloc,
        child: Scaffold(body: SizedBox(width: 100, height: 300, child: leaf)),
      ),
    ),
  );

  group('TrackPeakMeter', () {
    // The level is read from the ambient bloc by channel — that is what lets
    // a meter tick skip the ~250-line tile above it, and what makes every
    // surface built from these tiles a LIVE view rather than a function of
    // the Track it was handed.
    Widget meter(int channel) => TrackPeakMeter(
      channel: channel,
      color: Colors.green,
      hasContent: true,
      frozen: false,
    );

    testWidgets('draws the rig level for its channel', (tester) async {
      seed(
        const LooperState(tracks: [Track(peak: 0.75), Track(channel: 1)]),
      );
      await pumpLeaf(tester, meter(0));

      expect(tester.widget<PeakMeterBar>(find.byType(PeakMeterBar)).peak, 0.75);
    });

    testWidgets('a channel the rig has dropped meters as silence', (
      tester,
    ) async {
      // Never drawn in the app — the slot above unmounts the tile in the same
      // frame. Asserted anyway because the selector runs at EMIT time, before
      // that unmount, so this path is reached on every channel removal and
      // must not throw.
      seed(const LooperState(tracks: [Track(peak: 0.75)]));
      await pumpLeaf(tester, meter(6));

      expect(tester.widget<PeakMeterBar>(find.byType(PeakMeterBar)).peak, 0);
    });
  });

  group('PeakMeterBar clip cap', () {
    Widget bar({required double peak, bool frozen = false}) => PeakMeterBar(
      peak: peak,
      color: Colors.green,
      hasContent: true,
      frozen: frozen,
      clipColor: Colors.red,
    );

    testWidgets('appears on a full-scale peak and holds across quieter '
        'ticks', (tester) async {
      seed(const LooperState());
      await pumpLeaf(tester, bar(peak: 0.5));
      expect(find.byKey(const Key('meter_clip_cap')), findsNothing);

      await pumpLeaf(tester, bar(peak: 1));
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);

      // The next, quieter tick still shows the cap: a single hot block must
      // survive long enough to be seen.
      await pumpLeaf(tester, bar(peak: 0.3));
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);
    });

    testWidgets('never shows on a stopped track', (tester) async {
      seed(const LooperState());
      await pumpLeaf(tester, bar(peak: 1));
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);
      await pumpLeaf(tester, bar(peak: 0, frozen: true));
      expect(find.byKey(const Key('meter_clip_cap')), findsNothing);
    });

    testWidgets('retires after the hold with no further ticks', (
      tester,
    ) async {
      // One hot block, then silence: nothing rebuilds the bar again, so the
      // cap must retire on its own clock rather than on the next rebuild.
      seed(const LooperState());
      await pumpLeaf(tester, bar(peak: 1));
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);

      await tester.pump(PeakMeterBar.clipHold ~/ 2);
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);

      await tester.pump(PeakMeterBar.clipHold);
      expect(find.byKey(const Key('meter_clip_cap')), findsNothing);
    });

    testWidgets('a fresh clip restarts the hold', (tester) async {
      seed(const LooperState());
      await pumpLeaf(tester, bar(peak: 1));
      await tester.pump(PeakMeterBar.clipHold ~/ 2);
      await pumpLeaf(tester, bar(peak: 1));
      await tester.pump(PeakMeterBar.clipHold ~/ 2);
      // Half a hold after the FIRST clip's retirement would have fallen.
      expect(find.byKey(const Key('meter_clip_cap')), findsOneWidget);
      await tester.pump(PeakMeterBar.clipHold);
      expect(find.byKey(const Key('meter_clip_cap')), findsNothing);
    });

    testWidgets('is absent without a clip colour', (tester) async {
      seed(const LooperState());
      await pumpLeaf(
        tester,
        const PeakMeterBar(
          peak: 1,
          color: Colors.green,
          hasContent: true,
          frozen: false,
        ),
      );
      expect(find.byKey(const Key('meter_clip_cap')), findsNothing);
    });
  });

  group('TrackProgressBar', () {
    testWidgets("fills to the track's own progress", (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 1000,
              positionFrames: 250,
            ),
          ],
        ),
      );
      await pumpLeaf(
        tester,
        const TrackProgressBar(channel: 0, color: Colors.green),
      );
      final fill = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(fill.widthFactor, 0.25);
    });

    testWidgets('an empty or dropped channel reads 0', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pumpLeaf(
        tester,
        const TrackProgressBar(channel: 3, color: Colors.green),
      );
      final fill = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(fill.widthFactor, 0);
    });
  });
}
