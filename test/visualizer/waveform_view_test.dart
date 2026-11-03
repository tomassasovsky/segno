import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/visualizer.dart';

void main() {
  /// The stroke colour [WaveformView] actually handed to its painter.
  Color paintedColor(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.byKey(const Key('waveform_view_paint')),
    );
    return (paint.painter! as WaveformPainter).color;
  }

  Future<void> pumpWaveform(
    WidgetTester tester,
    LooperMeterState state, {
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.neon,
      home: Scaffold(
        body: WaveformView(
          samples: Float32List.fromList([0, 0.5, 1, 0.5, 0]),
          state: state,
        ),
      ),
    ),
  );

  testWidgets('WaveformView paints with the active theme', (tester) async {
    await pumpWaveform(tester, LooperMeterState.playing);
    expect(find.byKey(const Key('waveform_view_paint')), findsOneWidget);
  });

  testWidgets('the stroke resolves from the theme table, per state', (
    tester,
  ) async {
    // #499 stage 3b: the waveform is state-coloured, so the same widget in two
    // transport states must paint two different colours — both of them the
    // theme's, never a constant baked into the widget.
    final looper = AppTheme.neon.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      await pumpWaveform(tester, state);
      expect(
        paintedColor(tester),
        looper.waveformColor(state),
        reason: '$state must paint its own table entry',
      );
    }
    // And the states genuinely differ on screen, rather than all resolving to
    // one colour that happens to satisfy the lookup.
    await pumpWaveform(tester, LooperMeterState.recording);
    final recording = paintedColor(tester);
    await pumpWaveform(tester, LooperMeterState.playing);
    expect(paintedColor(tester), isNot(recording));
  });

  testWidgets('the stroke follows the high-contrast palette too', (
    tester,
  ) async {
    final hc = AppTheme.highContrast.extension<LooperTheme>()!;
    await pumpWaveform(
      tester,
      LooperMeterState.playing,
      theme: AppTheme.highContrast,
    );
    expect(paintedColor(tester), hc.waveformColor(LooperMeterState.playing));
    expect(
      paintedColor(tester),
      isNot(
        AppTheme.neon.extension<LooperTheme>()!.waveformColor(
          LooperMeterState.playing,
        ),
      ),
    );
  });

  testWidgets('exposes a semantic label + playhead value when named (1.1.1)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List.fromList([0, 0.5, 1]),
            progress: 0.42,
            state: LooperMeterState.playing,
            semanticLabel: 'Output loop waveform',
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(WaveformView)),
      isSemantics(label: 'Output loop waveform', value: '42%'),
    );
    handle.dispose();
  });

  testWidgets('WaveformWindowApp renders the pushed frame', (tester) async {
    final frame = ValueNotifier<WaveformFrame>(
      (
        samples: Float32List.fromList([0, 1, 0]),
        progress: 0.2,
        selectedTrack: '',
      ),
    );
    addTearDown(frame.dispose);

    final readout = ValueNotifier(const PerformanceReadout());
    addTearDown(readout.dispose);

    await tester.pumpWidget(
      WaveformWindowApp(frame: frame, readout: readout),
    );
    await tester.pump();

    expect(find.byType(WaveformView), findsOneWidget);

    frame.value = (
      samples: Float32List.fromList([1, 0, 1, 0]),
      progress: 0.6,
      selectedTrack: '',
    );
    await tester.pump();
    expect(find.byType(WaveformView), findsOneWidget);
  });

  testWidgets('the playhead keeps a gutter cut through the waveform', (
    tester,
  ) async {
    // Regression: the playhead is hard-coded white, and the not-sounding
    // states are white too (opaque white in high contrast) — without a gutter
    // in the background colour the playhead is invisible wherever a bar
    // covers it, which is most of the height on a loud loop.
    //
    // The wave paints its baseline; the playhead's layer over it paints the
    // gutter, then the playhead itself.
    final hc = AppTheme.highContrast.extension<LooperTheme>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.highContrast,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List(0),
            progress: 0.5,
            state: LooperMeterState.stopped,
          ),
        ),
      ),
    );

    expect(
      tester.renderObject(find.byKey(const Key('waveform_view_paint'))),
      paints..rect(
        color: hc
            .waveformColor(LooperMeterState.stopped)
            .withValues(
              alpha: 0.18,
            ),
      ),
    );
    expect(
      tester.renderObject(find.byKey(const Key('waveform_view_playhead'))),
      paints
        ..rect(color: hc.waveformBackground)
        ..rect(color: const Color(0xFFFFFFFF)),
      reason: 'the gutter must sit between the bars and the playhead',
    );
    // The state that made this necessary: waveform and playhead are the same
    // white, so only the gutter separates them.
    expect(
      hc.waveformColor(LooperMeterState.stopped),
      const Color(0xFFFFFFFF),
    );
  });

  testWidgets('the view paints the themed waveform background itself', (
    tester,
  ) async {
    // Both consumers rely on this rather than supplying their own backdrop —
    // the alpha-carrying state colours composite against it, and it is what
    // the contrast floors in test/theme are measured against.
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      await pumpWaveform(tester, LooperMeterState.muted, theme: data);
      // MaterialApp animates between themes, so the second pass is mid-lerp
      // until it settles — assert on the arrived-at theme, not a frame of the
      // transition.
      await tester.pumpAndSettle();
      final looper = data.extension<LooperTheme>()!;
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .map((box) => box.color),
        contains(looper.waveformBackground),
      );
      final playhead = tester.widget<CustomPaint>(
        find.byKey(const Key('waveform_view_playhead')),
      );
      expect(
        (playhead.painter! as PlayheadPainter).background,
        looper.waveformBackground,
      );
    }
  });

  testWidgets('the window colours its waveform from the pushed readout', (
    tester,
  ) async {
    final frame = ValueNotifier<WaveformFrame>(
      (
        samples: Float32List.fromList([0, 1, 0]),
        progress: 0,
        selectedTrack: '',
      ),
    );
    addTearDown(frame.dispose);
    final readout = ValueNotifier(
      const PerformanceReadout(
        selected: ReadoutTrack(channel: 0, name: 'T', state: 'recording'),
      ),
    );
    addTearDown(readout.dispose);

    await tester.pumpWidget(
      WaveformWindowApp(frame: frame, readout: readout),
    );
    await tester.pump();

    final looper = AppTheme.neon.extension<LooperTheme>()!;
    expect(
      paintedColor(tester),
      looper.waveformColor(LooperMeterState.recording),
    );

    // The colour is live, not a one-shot at first build: a state change pushed
    // over the channel has to reach the stroke.
    readout.value = const PerformanceReadout(
      selected: ReadoutTrack(channel: 0, name: 'T', state: 'playing'),
    );
    await tester.pump();
    expect(
      paintedColor(tester),
      looper.waveformColor(LooperMeterState.playing),
    );
  });

  group('WaveformPainter.shouldRepaint', () {
    final samples = Float32List.fromList([0, 1]);
    const cyan = Color(0xFF00E5FF);

    WaveformPainter painterOf({Float32List? samples_, Color color = cyan}) =>
        WaveformPainter(samples: samples_ ?? samples, color: color);

    test('does not repaint for the same list and color', () {
      expect(painterOf().shouldRepaint(painterOf()), isFalse);
    });

    test('repaints on a new sample list', () {
      expect(
        painterOf().shouldRepaint(
          painterOf(samples_: Float32List.fromList([0, 1])),
        ),
        isTrue,
      );
    });

    test('repaints on a color change', () {
      expect(
        painterOf().shouldRepaint(painterOf(color: const Color(0xFFFF2D95))),
        isTrue,
      );
    });
  });

  group('PlayheadPainter.shouldRepaint', () {
    const black = Color(0xFF000000);

    PlayheadPainter painterOf({
      double progress = 0,
      Color background = black,
    }) => PlayheadPainter(progress: progress, background: background);

    test('repaints on a playhead change', () {
      expect(
        painterOf(progress: 0.2).shouldRepaint(painterOf(progress: 0.5)),
        isTrue,
      );
    });

    test('repaints on a background change', () {
      // The background is not decoration: it is painted into the playhead
      // gutter, so a stale one leaves the gutter the wrong colour.
      expect(
        painterOf().shouldRepaint(
          painterOf(background: const Color(0xFF101014)),
        ),
        isTrue,
      );
    });
  });

  testWidgets('a moving playhead does not repaint the wave', (tester) async {
    final samples = Float32List.fromList([0, 0.5, 1]);
    Future<void> pumpAt(double progress) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: WaveformView(
            samples: samples,
            state: LooperMeterState.playing,
            progress: progress,
          ),
        ),
      ),
    );
    const waveKey = Key('waveform_view_paint');
    const playheadKey = Key('waveform_view_playhead');
    CustomPainter painterOf(Key key) =>
        tester.widget<CustomPaint>(find.byKey(key)).painter!;

    await pumpAt(0.2);
    final wave = painterOf(waveKey);
    final playhead = painterOf(playheadKey);
    await pumpAt(0.4);

    expect(painterOf(waveKey).shouldRepaint(wave), isFalse);
    expect(painterOf(playheadKey).shouldRepaint(playhead), isTrue);
    // Each paints in a layer of its own, so a playhead repaint reaches
    // neither the wave nor the readout around the view.
    final waveBoundary = find
        .ancestor(
          of: find.byKey(waveKey),
          matching: find.byType(RepaintBoundary),
        )
        .first;
    final playheadBoundary = find
        .ancestor(
          of: find.byKey(playheadKey),
          matching: find.byType(RepaintBoundary),
        )
        .first;
    expect(
      find.descendant(of: waveBoundary, matching: find.byKey(playheadKey)),
      findsNothing,
    );
    expect(
      find.descendant(of: playheadBoundary, matching: find.byKey(waveKey)),
      findsNothing,
    );
  });

  group('bar ruler', () {
    Future<void> pumpBars(WidgetTester tester, int bars) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List.fromList([0, 0.5, 1]),
            state: LooperMeterState.playing,
            progress: 0.3,
            bars: bars,
          ),
        ),
      ),
    );

    testWidgets('is its own repaint layer over the wave, and absent '
        'without bars', (tester) async {
      await pumpBars(tester, 4);
      final ruler = find.byKey(const Key('waveform_view_ruler'));
      expect(ruler, findsOneWidget);
      // The playhead repaints the wave every poll; the ruler's laid-out
      // labels must not be re-shaped with it.
      expect(
        find.ancestor(of: ruler, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(
        (tester.widget<CustomPaint>(ruler).painter! as BarRulerPainter).bars,
        4,
      );
      // Over the wave and the playhead, so its lines stay visible across
      // loud bars: the last child of the stack, after the wave's own layer.
      final stack = tester.widget<Stack>(
        find.ancestor(of: ruler, matching: find.byType(Stack)).first,
      );
      expect(stack.children.length, 3);
      expect(
        find.descendant(
          of: find.byWidget(stack.children.last),
          matching: ruler,
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byWidget(stack.children.first),
          matching: find.byKey(const Key('waveform_view_paint')),
        ),
        findsOneWidget,
      );

      await pumpBars(tester, 0);
      expect(find.byKey(const Key('waveform_view_ruler')), findsNothing);
    });

    // Long loops on a wave row (#1524): bars narrower than a number used to
    // run every number into the next, and the last past the ruler's end.
    for (final bars in [4, 16, 128, 999]) {
      test('$bars bars: numbers never touch and stay on the ruler', () {
        const size = Size(1340, 24);
        final canvas = _LabelCanvas();
        BarRulerPainter(
          bars: bars,
          color: const Color(0xFF888888),
        ).paint(canvas, size);
        expect(canvas.labels, isNotEmpty);
        expect(canvas.labels.first.left, BarRulerPainter.labelInset);
        if (bars == 4) expect(canvas.labels, hasLength(4));
        for (var i = 1; i < canvas.labels.length; i++) {
          expect(
            canvas.labels[i].left,
            greaterThanOrEqualTo(
              canvas.labels[i - 1].right + BarRulerPainter.labelGap,
            ),
          );
        }
        expect(canvas.labels.last.right, lessThanOrEqualTo(size.width));
      });
    }

    test('repaints only when the bars or the colour change', () {
      const grey = Color(0xFF888888);
      final four = BarRulerPainter(bars: 4, color: grey);
      expect(
        four.shouldRepaint(BarRulerPainter(bars: 4, color: grey)),
        isFalse,
      );
      expect(four.shouldRepaint(BarRulerPainter(bars: 8, color: grey)), isTrue);
      expect(
        four.shouldRepaint(
          BarRulerPainter(bars: 4, color: const Color(0xFFFFFFFF)),
        ),
        isTrue,
      );
    });
  });
}

/// Records where each bar number is drawn.
class _LabelCanvas implements Canvas {
  final labels = <Rect>[];

  @override
  void drawParagraph(Paragraph paragraph, Offset offset) =>
      labels.add(offset & Size(paragraph.maxIntrinsicWidth, paragraph.height));

  @override
  void noSuchMethod(Invocation invocation) {}
}
