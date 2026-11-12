@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show RecordTiming, TempoFollowState;
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_command.dart';
import 'package:segno/visualizer/waveform_window.dart';

import '../helpers/helpers.dart';

/// The 7" readout's Loop panel (#1654) at the panel's native 1024x600, pixel
/// ratio 1.6 (640x375 logical), as homescreen.toml runs it. Rendered with
///
///   flutter test --tags screenshots --update-goldens \
///     test/screenshots/readout_controls_screenshots_test.dart
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFonts();
  });

  /// A plucked pattern, four hits a bar over four bars.
  final samples = Float32List.fromList([
    for (var i = 0; i < 512; i++)
      0.25 + 0.6 * math.exp(-((i % 32) / 9)) * (0.8 + 0.2 * math.sin(i * 0.7)),
  ]);

  PerformanceReadout readout({
    String state = 'playing',
    TempoFollowState follow = TempoFollowState.free,
    ReadoutLoopSettings loop = const ReadoutLoopSettings(
      lengthBars: 4,
      timing: RecordTiming.bar,
      ready: true,
    ),
    int tsNum = 4,
    int tsDen = 4,
  }) => PerformanceReadout(
    selected: ReadoutTrack(
      channel: 0,
      name: 'GUITAR',
      state: state,
      primary: true,
      bars: 4,
    ),
    tempoBpm: 84,
    hasTempo: true,
    tsNum: tsNum,
    tsDen: tsDen,
    tempoFollow: follow,
    loop: loop,
  );

  Future<void> pump(
    WidgetTester tester,
    PerformanceReadout value, {
    Locale locale = const Locale('en'),
    Stream<ReadoutRefusal> refusals = const Stream.empty(),
  }) async {
    tester.view
      ..physicalSize = const Size(1024, 600)
      ..devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    tester.platformDispatcher
      ..localeTestValue = locale
      ..localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final frame = ValueNotifier<WaveformFrame>((
      samples: samples,
      progress: 0.4,
      selectedTrack: 'GUITAR',
    ));
    final pushed = ValueNotifier(value);
    addTearDown(frame.dispose);
    addTearDown(pushed.dispose);
    await tester.pumpWidget(
      WaveformWindowApp(frame: frame, readout: pushed, refusals: refusals),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pump();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('console_readout_strip')));
    await tester.pump();
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(WaveformWindowApp),
      matchesGoldenFile('goldens/readout_controls_$name.png'),
    );
  }

  testWidgets('the readout with its footer strip', (tester) async {
    await pump(tester, readout());
    await shoot(tester, 'readout');
  }, skip: !rendersScreenshots);

  testWidgets('the Loop panel', (tester) async {
    await pump(tester, readout());
    await openPanel(tester);
    await shoot(tester, 'panel');
  }, skip: !rendersScreenshots);

  testWidgets('the Loop panel while a tempo change retimes the loops, the '
      'track with its own length', (tester) async {
    await pump(
      tester,
      readout(
        follow: TempoFollowState.retimes,
        loop: const ReadoutLoopSettings(
          lengthBars: 4,
          trackLengthBars: 8,
          timing: RecordTiming.bar,
          ready: true,
        ),
      ),
    );
    await openPanel(tester);
    await shoot(tester, 'panel_retimes');
  }, skip: !rendersScreenshots);

  testWidgets('the Loop panel while a take records', (tester) async {
    await pump(
      tester,
      readout(
        state: 'recording',
        follow: TempoFollowState.busy,
        loop: const ReadoutLoopSettings(
          lengthBars: 4,
          timing: RecordTiming.bar,
          captureLocked: true,
          ready: true,
        ),
      ),
    );
    await openPanel(tester);
    await shoot(tester, 'panel_recording');
  }, skip: !rendersScreenshots);

  testWidgets('the readout and the panel in Spanish, while a take records '
      'and the track has its own values', (tester) async {
    await pump(
      tester,
      readout(
        state: 'recording',
        follow: TempoFollowState.busy,
        loop: const ReadoutLoopSettings(
          lengthBars: 4,
          trackLengthBars: 8,
          timing: RecordTiming.loopStart,
          trackTiming: RecordTiming.eighth,
          captureLocked: true,
          ready: true,
        ),
      ),
      locale: const Locale('es'),
    );
    await shoot(tester, 'readout_es');
    await openPanel(tester);
    await shoot(tester, 'panel_recording_es');
  }, skip: !rendersScreenshots);

  testWidgets('the exact-tempo keypad', (tester) async {
    await pump(tester, readout());
    await openPanel(tester);
    await tester.tap(find.byKey(const Key('readout_panel_bpm_button')));
    await tester.pump();
    for (final key in ['9', '2', '.', '5']) {
      await tester.tap(find.text(key).last);
      await tester.pump();
    }
    await shoot(tester, 'keypad');

    // Out of range: the keypad stays up and gives the range.
    await tester.tap(find.byKey(const Key('readout_keypad_cancel')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('readout_panel_bpm_button')));
    await tester.pump();
    for (final key in ['3', '5', '0']) {
      await tester.tap(find.text(key).last);
      await tester.pump();
    }
    await tester.tap(find.textContaining('Set').last);
    await shoot(tester, 'keypad_range');
  }, skip: !rendersScreenshots);

  testWidgets('every time signature', (tester) async {
    await pump(tester, readout(tsNum: 7, tsDen: 8));
    await openPanel(tester);
    await tester.tap(find.byKey(const Key('readout_panel_signature_more')));
    await shoot(tester, 'signatures');
  }, skip: !rendersScreenshots);

  testWidgets('a refused Clear tempo, in English and Spanish', (tester) async {
    for (final (locale, name) in const [
      (Locale('en'), 'panel_clear_refused'),
      (Locale('es'), 'panel_clear_refused_es'),
    ]) {
      final refusals = StreamController<ReadoutRefusal>.broadcast(sync: true);
      addTearDown(refusals.close);
      await pump(
        tester,
        readout(follow: TempoFollowState.retimes),
        locale: locale,
        refusals: refusals.stream,
      );
      await openPanel(tester);
      refusals.add(ReadoutRefusal.tempoClearLocked);
      await shoot(tester, name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, skip: !rendersScreenshots);
}
