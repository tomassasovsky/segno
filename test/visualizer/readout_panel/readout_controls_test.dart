import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show RecordTiming, TempoFollowState;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_command.dart';
import 'package:segno/visualizer/readout_panel/readout_button.dart';
import 'package:segno/visualizer/readout_panel/readout_controls.dart';
import 'package:segno/visualizer/readout_panel/readout_loop_panel.dart';
import 'package:segno/visualizer/waveform_window.dart';

import '../../helpers/text_fit.dart';

/// The readout's footer strip and Loop panel (#1654) on the 7" at its
/// native 1024x600, pixel ratio 1.6: 640x375 logical.
void main() {
  setUpAll(loadBundledFonts);

  const ready = ReadoutLoopSettings(
    lengthBars: 4,
    timing: RecordTiming.bar,
    ready: true,
  );

  PerformanceReadout readoutOf({
    TempoFollowState follow = TempoFollowState.free,
    ReadoutLoopSettings loop = ready,
    bool clock = false,
    bool dimmed = false,
    int tsNum = 4,
    int tsDen = 4,
    String state = 'playing',
  }) => PerformanceReadout(
    selected: ReadoutTrack(
      channel: 1,
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
    clockOwnsTempo: clock,
    loop: loop,
    dimmed: dimmed,
  );

  late List<ReadoutCommand> sent;
  late int touches;
  late ValueNotifier<PerformanceReadout> pushed;

  Future<void> pump(
    WidgetTester tester,
    PerformanceReadout readout, {
    Locale locale = const Locale('en'),
  }) async {
    tester.view
      ..physicalSize = const Size(1024, 600)
      ..devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    sent = [];
    touches = 0;
    final frame = ValueNotifier<WaveformFrame>((
      samples: Float32List.fromList([0.2, 0.8, 0.4, 0.6]),
      progress: 0.4,
      selectedTrack: 'GUITAR',
    ));
    pushed = ValueNotifier(readout);
    addTearDown(frame.dispose);
    addTearDown(pushed.dispose);
    tester.platformDispatcher
      ..localeTestValue = locale
      ..localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      WaveformWindowApp(
        frame: frame,
        readout: pushed,
        onActivity: () => touches++,
        onCommand: sent.add,
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pump();
  }

  final panel = find.byKey(const Key('readout_panel'));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('console_readout_strip')));
    await tester.pump();
    expect(panel, findsOneWidget);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String key) {
    final face = find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(ReadoutButtonFace),
    );
    return tester.widget<ReadoutButtonFace>(face).enabled;
  }

  void semanticTap(WidgetTester tester, String key) {
    final node = tester.getSemantics(find.byKey(Key(key)));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
  }

  group('the strip and the panel', () {
    testWidgets('the readout is unchanged until the strip is touched', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      expect(panel, findsNothing);
      expect(find.byKey(const Key('console_readout_start')), findsOneWidget);
      expect(find.text('Start 1 bar'), findsOneWidget);
      expect(find.text('4 bars'), findsWidgets);

      // A touch anywhere else is activity and nothing more.
      await tester.tapAt(const Offset(320, 150));
      await tester.pump();
      expect(panel, findsNothing);
      expect(touches, 1);
      expect(sent, isEmpty);

      await open(tester);
      expect(sent, isEmpty);
    });

    testWidgets("the strip names the selected track's next take, and "
        'nothing before the owners load', (tester) async {
      await pump(
        tester,
        readoutOf(
          loop: const ReadoutLoopSettings(
            lengthBars: 4,
            trackLengthBars: 8,
            timing: RecordTiming.bar,
            trackTiming: RecordTiming.eighth,
            ready: true,
          ),
        ),
      );
      expect(find.text('8 bars'), findsOneWidget);
      expect(find.text('Start 1/8'), findsOneWidget);

      pushed.value = readoutOf(loop: const ReadoutLoopSettings());
      await tester.pump();
      expect(find.byKey(const Key('console_readout_length')), findsNothing);
      expect(find.byKey(const Key('console_readout_start')), findsNothing);
    });

    testWidgets('Done closes the panel', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      await tapKey(tester, 'readout_panel_done');
      expect(panel, findsNothing);
    });

    testWidgets('ten seconds without a touch close it; a touch restarts '
        'the count', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      await tester.pump(const Duration(seconds: 9));
      await tester.tapAt(const Offset(320, 20));
      await tester.pump(const Duration(seconds: 9));
      expect(panel, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(panel, findsNothing);
    });

    testWidgets('a held step keeps the panel open', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('readout_panel_nudge_+1'))),
      );
      await tester.pump(const Duration(seconds: 12));
      expect(panel, findsOneWidget);
      await gesture.up();
      await tester.pump(ReadoutControls.idleClose);
      expect(panel, findsNothing);
    });

    testWidgets('the waking touch on a dimmed console presses nothing', (
      tester,
    ) async {
      await pump(tester, readoutOf(dimmed: true));
      await tester.tap(
        find.byKey(const Key('console_readout_strip')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(panel, findsNothing);
      expect(touches, 1);

      pushed.value = readoutOf();
      await tester.pump();
      await open(tester);
    });
  });

  group('commands', () {
    testWidgets('the steps send their deltas; a hold repeats', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      for (final step in ['-1', '-0.1', '+0.1', '+1']) {
        await tapKey(tester, 'readout_panel_nudge_$step');
      }
      expect(sent, const [
        TempoNudge(-1),
        TempoNudge(-0.1),
        TempoNudge(0.1),
        TempoNudge(1),
      ]);

      sent.clear();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('readout_panel_nudge_+0.1'))),
      );
      await tester.pump();
      expect(sent, const [TempoNudge(0.1)]);
      await tester.pump(ReadoutPressButton.repeatDelay);
      await tester.pump(ReadoutPressButton.repeatEvery * 3);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(sent, List.filled(4, const TempoNudge(0.1)));
    });

    testWidgets('a lock that lands mid-hold stops the repeat', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('readout_panel_nudge_+1'))),
      );
      await tester.pump(ReadoutPressButton.repeatDelay);
      await tester.pump(ReadoutPressButton.repeatEvery);
      final before = sent.length;
      pushed.value = readoutOf(follow: TempoFollowState.busy);
      await tester.pump();
      await tester.pump(ReadoutPressButton.repeatEvery * 5);
      expect(sent, hasLength(before));
      await gesture.up();
      await tester.pump();
    });

    testWidgets('a finger sliding off a held step stops it', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      final step = find.byKey(const Key('readout_panel_nudge_+1'));
      final gesture = await tester.startGesture(tester.getCenter(step));
      await tester.pump(ReadoutPressButton.repeatDelay);
      await tester.pump(ReadoutPressButton.repeatEvery);
      await gesture.moveTo(tester.getCenter(step) + const Offset(0, 120));
      await tester.pump();
      final before = sent.length;
      await tester.pump(ReadoutPressButton.repeatEvery * 5);
      expect(sent, hasLength(before));
      await gesture.up();
      await tester.pump();
    });

    testWidgets('every button can be pressed through accessibility', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, readoutOf());
      await open(tester);
      semanticTap(tester, 'readout_panel_timing_half');
      await tester.pump();
      expect(sent, const [TimingSet(RecordTiming.half)]);
      semanticTap(tester, 'readout_panel_done');
      await tester.pump();
      expect(panel, findsNothing);
      semantics.dispose();
    });

    testWidgets('Tap sends on touch, before the finger lifts', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('readout_panel_tap'))),
      );
      await tester.pump();
      expect(sent, const [TempoTap()]);
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pump();
      expect(sent, const [TempoTap()]);
    });

    testWidgets('a signature from the row, and from the full list', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      await open(tester);
      await tapKey(tester, 'readout_panel_signature_6_8');
      expect(sent, const [SignatureSet(6, 8)]);

      await tapKey(tester, 'readout_panel_signature_more');
      expect(find.byKey(const Key('readout_panel_signatures')), findsOne);
      await tapKey(tester, 'readout_panel_all_signature_11_8');
      expect(sent.last, const SignatureSet(11, 8));
      expect(find.byKey(const Key('readout_panel_signatures')), findsNothing);

      await tapKey(tester, 'readout_panel_signature_more');
      await tapKey(tester, 'readout_panel_signature_back');
      expect(find.byKey(const Key('readout_panel_signatures')), findsNothing);
      expect(sent, hasLength(2));
    });

    testWidgets('a signature off the short list shows in More', (
      tester,
    ) async {
      await pump(tester, readoutOf(tsNum: 7, tsDen: 8));
      await open(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('readout_panel_signature_more')),
          matching: find.text('7/8'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('length steps from what the panel last sent, until the '
        'push has it', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      await tapKey(tester, 'readout_panel_length_more');
      await tapKey(tester, 'readout_panel_length_more');
      expect(sent, const [LengthSet(5), LengthSet(6)]);
      expect(find.text('6 bars'), findsOneWidget);

      // The rig took 6; the push says so.
      pushed.value = readoutOf(
        loop: const ReadoutLoopSettings(
          lengthBars: 6,
          timing: RecordTiming.bar,
          ready: true,
        ),
      );
      await tester.pump();
      await tapKey(tester, 'readout_panel_length_less');
      await tapKey(tester, 'readout_panel_length_auto');
      expect(sent.skip(2), const [LengthSet(5), LengthSet(0)]);
    });

    testWidgets('a refused length goes back to the pushed one', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      await open(tester);
      await tapKey(tester, 'readout_panel_length_more');
      expect(find.text('5 bars'), findsOneWidget);
      await tester.pump(ReadoutLoopPanel.lengthDraftFor);
      expect(find.text('5 bars'), findsNothing);
      expect(find.text('4 bars'), findsWidgets);
    });

    testWidgets('Auto has no shorter step', (tester) async {
      await pump(
        tester,
        readoutOf(loop: const ReadoutLoopSettings(ready: true)),
      );
      await open(tester);
      expect(enabled(tester, 'readout_panel_length_less'), isFalse);
      await tapKey(tester, 'readout_panel_length_more');
      expect(sent, const [LengthSet(1)]);
    });

    testWidgets('every record timing', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      for (final timing in RecordTiming.values) {
        await tapKey(tester, 'readout_panel_timing_${timing.name}');
      }
      expect(sent, [
        for (final timing in RecordTiming.values) TimingSet(timing),
      ]);
    });
  });

  group('the panel layout', () {
    testWidgets('the Start grid is one gap apart across and down (#1672)', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      await open(tester);
      Rect cell(RecordTiming timing) => tester.getRect(
        find.byKey(Key('readout_panel_timing_${timing.name}')),
      );
      final across =
          cell(RecordTiming.loopStart).left -
          cell(RecordTiming.immediately).right;
      final down =
          cell(RecordTiming.quarter).top -
          cell(RecordTiming.immediately).bottom;
      expect(across, down);
    });

    testWidgets('fits while a take records, in Spanish (#1672)', (
      tester,
    ) async {
      await pump(
        tester,
        readoutOf(
          state: 'recording',
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
      await open(tester);
      expect(tester.takeException(), isNull);
      Rect cell(RecordTiming timing) => tester.getRect(
        find.byKey(Key('readout_panel_timing_${timing.name}')),
      );
      expect(
        cell(RecordTiming.loopStart).left -
            cell(RecordTiming.immediately).right,
        cell(RecordTiming.quarter).top - cell(RecordTiming.immediately).bottom,
      );
    });
  });

  group('exact tempo', () {
    final keypad = find.byKey(const Key('readout_keypad'));

    Future<void> openKeypad(WidgetTester tester) async {
      await open(tester);
      await tapKey(tester, 'readout_panel_bpm_button');
      expect(keypad, findsOneWidget);
    }

    Future<void> type(WidgetTester tester, String keys) async {
      for (final key in keys.split('')) {
        await tester.tap(
          find.descendant(of: keypad, matching: find.text(key)).last,
        );
        await tester.pump();
      }
    }

    Future<void> set(WidgetTester tester) async {
      await tester.tap(
        find.descendant(of: keypad, matching: find.textContaining('Set')),
      );
      await tester.pump();
    }

    testWidgets('typing 128.47 and Set sends exactly that', (tester) async {
      await pump(tester, readoutOf());
      await openKeypad(tester);
      await type(tester, '128.47');
      expect(find.text('Set 128.47'), findsOneWidget);
      await set(tester);
      expect(sent, const [TempoSet(128.47)]);
      expect(keypad, findsNothing);
      expect(panel, findsOneWidget);
    });

    testWidgets('a third decimal and a fourth digit are not typed', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      await openKeypad(tester);
      await type(tester, '92.505');
      expect(
        find.descendant(of: keypad, matching: find.text('92.50')),
        findsOne,
      );
      await tapKey(tester, 'readout_keypad_cancel');
      await tapKey(tester, 'readout_panel_bpm_button');
      await type(tester, '1200');
      expect(find.descendant(of: keypad, matching: find.text('120')), findsOne);
    });

    for (final bad in ['350', '3']) {
      testWidgets('$bad is refused with the range, and the keypad stays', (
        tester,
      ) async {
        await pump(tester, readoutOf());
        await openKeypad(tester);
        await type(tester, bad);
        await set(tester);
        expect(sent, isEmpty);
        expect(keypad, findsOneWidget);
        expect(
          find.text('Enter a tempo from 30.00 to 300.00 BPM'),
          findsOneWidget,
        );
        // Typing again takes the refusal away.
        await tester.tap(find.byIcon(Icons.backspace_outlined));
        await tester.pump();
        expect(find.byKey(const Key('readout_keypad_error')), findsNothing);
      });
    }

    testWidgets('the panel behind presses nothing; a touch on it backs out', (
      tester,
    ) async {
      await pump(tester, readoutOf());
      await openKeypad(tester);
      // Tap, under the scrim at the panel's lower left.
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('readout_panel_tap'))) -
            const Offset(100, 0),
      );
      await tester.pump();
      expect(sent, isEmpty);
      expect(keypad, findsNothing);
      expect(panel, findsOneWidget);
    });

    testWidgets('typing keeps the panel open', (tester) async {
      await pump(tester, readoutOf());
      await openKeypad(tester);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 6));
        await type(tester, '1');
      }
      expect(keypad, findsOneWidget);
      await tester.pump(ReadoutControls.idleClose);
      expect(panel, findsNothing);
    });

    testWidgets('the dotted rule is as wide as the figure', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      final rule = tester.getSize(
        find.byKey(const Key('readout_panel_bpm_rule')),
      );
      final figure = tester.getRect(find.byKey(const Key('readout_panel_bpm')));
      expect(rule.width, greaterThanOrEqualTo(figure.width));
      expect(rule.width, lessThan(figure.width + 60));
    });

    testWidgets('Cancel and an empty Set send nothing', (tester) async {
      await pump(tester, readoutOf());
      await openKeypad(tester);
      await type(tester, '99');
      await tapKey(tester, 'readout_keypad_cancel');
      expect(keypad, findsNothing);
      await tapKey(tester, 'readout_panel_bpm_button');
      await set(tester);
      expect(keypad, findsNothing);
      expect(sent, isEmpty);
    });

    testWidgets('a locked tempo opens no keypad, and a lock closes it', (
      tester,
    ) async {
      await pump(tester, readoutOf(follow: TempoFollowState.noFollower));
      await open(tester);
      await tapKey(tester, 'readout_panel_bpm_button');
      expect(keypad, findsNothing);

      pushed.value = readoutOf();
      await tester.pump();
      await tapKey(tester, 'readout_panel_bpm_button');
      expect(keypad, findsOneWidget);
      pushed.value = readoutOf(follow: TempoFollowState.busy);
      await tester.pump();
      expect(keypad, findsNothing);
    });

    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('the keypad fits (${locale.languageCode})', (tester) async {
        await pump(tester, readoutOf(), locale: locale);
        await openKeypad(tester);
        await type(tester, '350');
        await tester.tap(
          find.descendant(
            of: keypad,
            matching: find.text(
              lookupAppLocalizations(locale).loopTempoEntrySet,
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('readout_keypad_error')), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(clippedTexts(tester, within: keypad), isEmpty);
        expect(await unbundledTexts(tester, within: keypad), isEmpty);
      });
    }
  });

  group('locks', () {
    const tempoKeys = [
      'readout_panel_nudge_-1',
      'readout_panel_nudge_+1',
      'readout_panel_tap',
    ];
    const loopKeys = [
      'readout_panel_length_more',
      'readout_panel_length_auto',
      'readout_panel_timing_half',
    ];
    final note = find.byKey(const Key('readout_panel_tempo_note'));
    final band = find.byKey(const Key('readout_panel_recording'));

    testWidgets('no loops: everything is free', (tester) async {
      await pump(tester, readoutOf());
      await open(tester);
      for (final key in [
        ...tempoKeys,
        ...loopKeys,
        'readout_panel_signature_3_4',
      ]) {
        expect(enabled(tester, key), isTrue, reason: key);
      }
      expect(find.text('Tap the figure to type it.'), findsOneWidget);
      expect(band, findsNothing);
    });

    testWidgets('loops that follow: the tempo says it retimes them, the '
        'signature waits for a clear', (tester) async {
      await pump(tester, readoutOf(follow: TempoFollowState.retimes));
      await open(tester);
      for (final key in [...tempoKeys, ...loopKeys]) {
        expect(enabled(tester, key), isTrue, reason: key);
      }
      expect(enabled(tester, 'readout_panel_signature_3_4'), isFalse);
      expect(enabled(tester, 'readout_panel_signature_more'), isFalse);
      expect(
        find.text('Changing the tempo retimes the recorded loops.'),
        findsOneWidget,
      );
      expect(find.text('Clear all tracks to change it'), findsOneWidget);
    });

    for (final (follow, reason) in const [
      (TempoFollowState.noGrid, 'Locked: the loops have no bar grid.'),
      (TempoFollowState.noFollower, 'Locked: no track follows the tempo.'),
      (TempoFollowState.busy, 'Locked while a take is armed or recording.'),
    ]) {
      testWidgets('${follow.name}: the tempo is locked and says why', (
        tester,
      ) async {
        await pump(tester, readoutOf(follow: follow));
        await open(tester);
        for (final key in tempoKeys) {
          expect(enabled(tester, key), isFalse, reason: key);
        }
        expect(enabled(tester, 'readout_panel_signature_4_4'), isFalse);
        for (final key in loopKeys) {
          expect(enabled(tester, key), isTrue, reason: key);
        }
        expect(find.text(reason), findsOneWidget);

        // A locked step sends nothing.
        await tester.tap(find.byKey(const Key('readout_panel_nudge_+1')));
        await tester.pump();
        expect(sent, isEmpty);
      });
    }

    testWidgets('a take recording: the band, and everything locked', (
      tester,
    ) async {
      await pump(
        tester,
        readoutOf(
          follow: TempoFollowState.busy,
          state: 'recording',
          loop: const ReadoutLoopSettings(
            lengthBars: 4,
            timing: RecordTiming.bar,
            captureLocked: true,
            ready: true,
          ),
        ),
      );
      await open(tester);
      expect(band, findsOneWidget);
      for (final key in [...tempoKeys, ...loopKeys]) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
      // The band says it once.
      expect(note, findsNothing);
      await tester.tap(find.byKey(const Key('readout_panel_timing_half')));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('a take the owners report before the engine does locks '
        'the tempo too', (tester) async {
      await pump(
        tester,
        readoutOf(
          follow: TempoFollowState.retimes,
          loop: const ReadoutLoopSettings(
            lengthBars: 4,
            timing: RecordTiming.bar,
            captureLocked: true,
            ready: true,
          ),
        ),
      );
      await open(tester);
      expect(band, findsOneWidget);
      for (final key in [...tempoKeys, 'readout_panel_signature_4_4']) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
      expect(note, findsNothing);
    });

    testWidgets('a MIDI clock owns the tempo', (tester) async {
      await pump(tester, readoutOf(clock: true));
      await open(tester);
      for (final key in tempoKeys) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
      expect(enabled(tester, 'readout_panel_signature_4_4'), isTrue);
      expect(find.text('MIDI clock sets the tempo.'), findsOneWidget);
    });

    testWidgets('not loaded yet: the length and start wait', (tester) async {
      await pump(
        tester,
        readoutOf(loop: const ReadoutLoopSettings(lengthBars: 4)),
      );
      await open(tester);
      for (final key in loopKeys) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
      expect(band, findsNothing);
    });

    testWidgets("the selected track's own length and start are named", (
      tester,
    ) async {
      await pump(
        tester,
        readoutOf(
          loop: const ReadoutLoopSettings(
            lengthBars: 4,
            trackLengthBars: 8,
            timing: RecordTiming.bar,
            trackTiming: RecordTiming.eighth,
            ready: true,
          ),
        ),
      );
      await open(tester);
      expect(find.text('Track 2 uses 8 bars'), findsOneWidget);
      expect(find.text('Track 2 uses 1/8'), findsOneWidget);
      // The panel still edits the default.
      await tapKey(tester, 'readout_panel_length_more');
      expect(sent, const [LengthSet(5)]);
    });
  });

  group('fit', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final language = locale.languageCode;
      for (final (name, readout) in [
        ('free', readoutOf()),
        (
          'own values',
          readoutOf(
            follow: TempoFollowState.retimes,
            loop: const ReadoutLoopSettings(
              lengthBars: 64,
              trackLengthBars: 64,
              timing: RecordTiming.loopStart,
              trackTiming: RecordTiming.loopStart,
              ready: true,
            ),
            tsNum: 12,
            tsDen: 8,
          ),
        ),
        (
          'recording',
          readoutOf(
            follow: TempoFollowState.busy,
            state: 'overdubbing',
            loop: const ReadoutLoopSettings(
              lengthBars: 64,
              timing: RecordTiming.loopStart,
              captureLocked: true,
              ready: true,
            ),
          ),
        ),
        ('locked', readoutOf(follow: TempoFollowState.noFollower)),
        (
          'locked at 15/8',
          readoutOf(follow: TempoFollowState.noGrid, tsNum: 15, tsDen: 8),
        ),
      ]) {
        testWidgets('$name: every text in full and every target 48 px '
            '($language)', (tester) async {
          await pump(tester, readout, locale: locale);
          expect(clippedTexts(tester), isEmpty);
          await open(tester);
          expect(tester.takeException(), isNull);
          expect(clippedTexts(tester), isEmpty);
          expect(await unbundledTexts(tester), isEmpty);
          expect(
            find.text(lookupAppLocalizations(locale).done),
            findsOneWidget,
          );
          for (final face in tester.renderObjectList<RenderBox>(
            find.byType(ReadoutButtonFace),
          )) {
            expect(face.size.width, greaterThanOrEqualTo(kReadoutMinTarget));
            expect(face.size.height, greaterThanOrEqualTo(kReadoutMinTarget));
          }

          await tapKey(tester, 'readout_panel_signature_more');
          expect(tester.takeException(), isNull);
          expect(clippedTexts(tester), isEmpty);
          for (final face in tester.renderObjectList<RenderBox>(
            find.byType(ReadoutButtonFace),
          )) {
            expect(face.size.height, greaterThanOrEqualTo(kReadoutMinTarget));
          }
        });
      }
    }

    testWidgets('the strip is a 48 px target with a name', (tester) async {
      await pump(tester, readoutOf());
      final strip = tester.getSize(
        find.byKey(const Key('console_readout_strip')),
      );
      expect(strip.height, greaterThanOrEqualTo(kReadoutMinTarget));
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byKey(const Key('console_readout_strip'))),
        matchesSemantics(
          label: 'Tempo, length and start',
          isButton: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });
  });
}
