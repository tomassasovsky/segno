import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/waveform_window.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

void main() {
  group('waveform frame diff', () {
    test('the first frame carries samples — nothing has been sent yet', () {
      final payload = waveformFramePayload(
        samples: Float32List.fromList([0.1, 0.2, 0.3]),
        progress: 0,
        selectedTrack: 'Drums',
        lastSent: null,
      );

      expect(payload.containsKey('samples'), isTrue);
    });

    test('an unchanged buffer is not re-sent, but progress still is', () {
      final peaks = Float32List.fromList([0.1, 0.2, 0.3]);
      final payload = waveformFramePayload(
        // A NEW list with the same contents: `readVisual` copies out of the
        // native buffer every call, so identity would never match and only
        // value equality can suppress anything.
        samples: Float32List.fromList([0.1, 0.2, 0.3]),
        progress: 0.5,
        selectedTrack: 'Drums',
        lastSent: peaks,
      );

      expect(
        payload.containsKey('samples'),
        isFalse,
        reason: 'steady playback re-shipped 512 unchanged floats',
      );
      expect(payload['progress'], 0.5);
      expect(payload['selectedTrack'], 'Drums');
    });

    test('a changed peak re-sends the buffer', () {
      final payload = waveformFramePayload(
        samples: Float32List.fromList([0.1, 0.9, 0.3]),
        progress: 0.5,
        selectedTrack: 'Drums',
        lastSent: Float32List.fromList([0.1, 0.2, 0.3]),
      );

      expect(payload.containsKey('samples'), isTrue);
    });

    test('a resized buffer re-sends — a new loop length is a new picture', () {
      final payload = waveformFramePayload(
        samples: Float32List.fromList([0.1, 0.2]),
        progress: 0,
        selectedTrack: '',
        lastSent: Float32List.fromList([0.1, 0.2, 0.3]),
      );

      expect(payload.containsKey('samples'), isTrue);
    });
  });

  group('waveformFrameFrom', () {
    WaveformFrame frameOf(List<double> samples) => (
      samples: Float32List.fromList(samples),
      progress: 0,
      selectedTrack: 'Drums',
    );

    test('a progress-only frame HOLDS the samples already on screen', () {
      final previous = frameOf([0.1, 0.2, 0.3]);

      final next = waveformFrameFrom(
        {'progress': 0.75, 'selectedTrack': 'Drums'},
        previous,
      );

      expect(
        next.samples,
        previous.samples,
        reason: 'an absent samples key blanked the waveform mid-playback',
      );
      expect(next.progress, 0.75);
    });

    test('a frame that carries samples replaces them', () {
      final next = waveformFrameFrom(
        {
          'samples': Float32List.fromList([0.4, 0.5]),
          'progress': 0.1,
          'selectedTrack': 'Bass',
        },
        frameOf([0.1, 0.2, 0.3]),
      );

      expect(next.samples, Float32List.fromList([0.4, 0.5]));
      expect(next.selectedTrack, 'Bass');
    });

    test('a malformed samples value HOLDS the waveform on screen', () {
      // The absent key is the easy case (a progress-only push). A present but
      // garbled value is what a damaged frame actually looks like, and
      // decoding it to an empty buffer would blank the second screen mid-set
      // — the one outcome the hold exists to prevent.
      final previous = frameOf([0.1, 0.2, 0.3]);

      final next = waveformFrameFrom(
        {'samples': 'nope', 'progress': 0.4, 'selectedTrack': 'Drums'},
        previous,
      );

      expect(next.samples, previous.samples);
      expect(next.progress, 0.4);
    });

    test('a malformed progress holds the playhead instead of resetting it', () {
      final next = waveformFrameFrom(
        {'progress': 'nope', 'selectedTrack': 'Bass'},
        (
          samples: Float32List.fromList([0.1]),
          progress: 0.62,
          selectedTrack: 'Drums',
        ),
      );

      expect(
        next.progress,
        0.62,
        reason: 'a garbled frame snapped the playhead back to the loop start',
      );
      expect(next.selectedTrack, 'Bass');
    });

    test('a malformed selectedTrack degrades instead of throwing', () {
      // The comment two lines above the field promises the second screen does
      // not go down mid-set on a garbled frame. `as String?` would have
      // thrown here — a present-but-wrong value is the shape a garbled frame
      // actually takes; an absent key is the easy case.
      final next = waveformFrameFrom(
        {'progress': 0.2, 'selectedTrack': 7},
        frameOf([0.1, 0.2]),
      );

      expect(next.selectedTrack, 'Drums');
      expect(next.progress, 0.2);
    });
  });

  group('WaveformWindowApp', () {
    Future<void> pump(WidgetTester tester) async {
      final frame = ValueNotifier<WaveformFrame>(
        (samples: Float32List(0), progress: 0, selectedTrack: ''),
      );
      final readout = ValueNotifier<PerformanceReadout>(
        const PerformanceReadout(tempoBpm: 120),
      );
      addTearDown(frame.dispose);
      addTearDown(readout.dispose);
      await tester.pumpWidget(
        WaveformWindowApp(
          frame: frame,
          readout: readout,
        ),
      );
    }

    testWidgets('fills the panel with the pen readout', (tester) async {
      await pump(tester);
      expect(find.byType(ConsoleReadoutView), findsOneWidget);
      // Full-bleed: the console view spans the panel, no windowed inset.
      final panel = tester.getSize(find.byType(Scaffold));
      final view = tester.getSize(find.byType(ConsoleReadoutView));
      expect(view.width, panel.width);
    });

    testWidgets('PerformanceReadout.goodbye covers the panel with the mark', (
      tester,
    ) async {
      final frame = ValueNotifier<WaveformFrame>(
        (samples: Float32List(0), progress: 0, selectedTrack: ''),
      );
      final readout = ValueNotifier<PerformanceReadout>(
        const PerformanceReadout(goodbye: ReadoutGoodbye.mark),
      );
      addTearDown(frame.dispose);
      addTearDown(readout.dispose);
      await tester.pumpWidget(
        WaveformWindowApp(
          frame: frame,
          readout: readout,
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      expect(find.byKey(const Key('power_mark')), findsOneWidget);
    });

    testWidgets('PerformanceReadout.brightness dims the panel in software', (
      tester,
    ) async {
      final frame = ValueNotifier<WaveformFrame>(
        (samples: Float32List(0), progress: 0, selectedTrack: ''),
      );
      final readout = ValueNotifier<PerformanceReadout>(
        const PerformanceReadout(),
      );
      addTearDown(frame.dispose);
      addTearDown(readout.dispose);
      await tester.pumpWidget(
        WaveformWindowApp(
          frame: frame,
          readout: readout,
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      expect(find.byType(ColorFiltered), findsNothing);

      readout.value = const PerformanceReadout(brightness: 0.3);
      await tester.pump();
      expect(
        find.ancestor(
          of: find.byType(ConsoleReadoutView),
          matching: find.byType(ColorFiltered),
        ),
        findsOneWidget,
      );
    });

    testWidgets('gives the readout a Material ancestor on both faces', (
      tester,
    ) async {
      // Without a Material ancestor the readout renders in the unthemed
      // fallback style (yellow double-underlined text), as once seen live on
      // the 7".
      await pump(tester);
      expect(
        find.ancestor(
          of: find.byType(ConsoleReadoutView),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
