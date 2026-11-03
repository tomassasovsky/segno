import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../helpers/text_fit.dart';

void main() {
  group('readoutTempo', () {
    test('drops the decimal on a whole tempo, keeps one otherwise', () {
      expect(readoutTempo(84), '84');
      expect(readoutTempo(84.02), '84');
      expect(readoutTempo(84.5), '84.5');
      expect(readoutTempo(120.25), '120.3');
    });
  });

  group('readoutMeterStateOf', () {
    test("resolves the selected track's state, muted overlaying it", () {
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(channel: 0, name: 'T', state: 'playing'),
        ),
        LooperMeterState.playing,
      );
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(
            channel: 0,
            name: 'T',
            state: 'playing',
            muted: true,
          ),
        ),
        LooperMeterState.muted,
      );
    });

    test('reads none, or an unknown token, as empty rather than throwing', () {
      expect(readoutMeterStateOf(null), LooperMeterState.empty);
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(channel: 0, name: 'T', state: 'transmogrifying'),
        ),
        LooperMeterState.empty,
      );
    });
  });

  group('ConsoleReadoutView', () {
    const selected = ReadoutTrack(
      channel: 0,
      name: 'Acoustic rhythm guitar',
      state: 'playing',
      primary: true,
      bars: 2,
    );
    const readout = PerformanceReadout(
      selected: selected,
      tempoBpm: 84,
      hasTempo: true,
    );

    Future<void> pump(
      WidgetTester tester, {
      PerformanceReadout readout = readout,
      Size size = const Size(1280, 720),
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppTextDefaults(child: child ?? const SizedBox.shrink()),
          home: Scaffold(
            body: ConsoleReadoutView(
              readout: readout,
              waveform: const ColoredBox(
                key: Key('test_waveform'),
                color: Colors.transparent,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('names the selected track: number, crown, name', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('1'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_crown')), findsOneWidget);
      expect(find.text('Acoustic rhythm guitar'), findsOneWidget);
    });

    testWidgets('shows the crown only when the selected track is primary', (
      tester,
    ) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(channel: 1, name: 'Lead', state: 'playing'),
        ),
      );
      expect(find.byKey(const Key('console_readout_crown')), findsNothing);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('reads the state word in the state colour and the bars', (
      tester,
    ) async {
      await pump(tester);
      final state = tester.widget<AppText>(
        find.byKey(const Key('console_readout_state')),
      );
      expect(state.data, 'Playing');
      expect(
        state.style!.color,
        AppTheme.neon.extension<LooperTheme>()!.waveformColor(
          LooperMeterState.playing,
        ),
      );
      expect(find.text('2 bars'), findsOneWidget);
    });

    testWidgets('an empty track says so and counts no bars', (tester) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(channel: 3, name: 'Lead', state: 'empty'),
        ),
      );
      expect(find.text('Empty'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_bars')), findsNothing);
    });

    testWidgets('localizes a default track name', (tester) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(
            channel: 2,
            name: 'TRACK 3',
            state: 'stopped',
            defaultName: true,
          ),
        ),
      );
      expect(find.text('TRACK 3'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('keeps the waveform as the strip between header and footer', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('test_waveform')), findsOneWidget);
      final wave = tester.getRect(find.byKey(const Key('test_waveform')));
      final state = tester.getRect(
        find.byKey(const Key('console_readout_state')),
      );
      final footer = tester.getRect(
        find.byKey(const Key('console_readout_tempo')),
      );
      expect(wave.top, greaterThan(state.bottom));
      expect(wave.bottom, lessThan(footer.top));
    });

    testWidgets('the footer carries the tempo, signature and function · bank', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('84'), findsOneWidget);
      expect(find.text('4/4'), findsOneWidget);
      expect(find.text('Tracks · Bank A'), findsOneWidget);
    });

    testWidgets('the footer names Mute and FX as the current function', (
      tester,
    ) async {
      await pump(tester, readout: readout.copyWithMode('mute', bank: 1));
      expect(find.text('Mute · Bank B'), findsOneWidget);
      await pump(tester, readout: readout.copyWithMode('fx', bank: 1));
      expect(find.text('FX · Bank B'), findsOneWidget);
    });

    testWidgets('shows — for the tempo on the tempo-free path', (
      tester,
    ) async {
      await pump(
        tester,
        readout: const PerformanceReadout(selected: selected),
      );
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('with no track selected the header says so', (tester) async {
      await pump(tester, readout: const PerformanceReadout());
      expect(find.byKey(const Key('console_readout_noTrack')), findsOneWidget);
      expect(find.byKey(const Key('console_readout_name')), findsNothing);
    });

    testWidgets('nothing on the face takes a tap', (tester) async {
      await pump(tester);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
    });

    group('notice band (#1562)', () {
      // The console's faces: a band's height is the drawn type's.
      setUpAll(loadBundledFonts);

      const lost = ReadoutNotice(
        title: 'Scarlett 4i4 USB disconnected. Nothing is heard.',
        tone: NoticeTone.critical,
      );

      testWidgets('nothing over the top margin while the main screen says '
          'nothing', (tester) async {
        await pump(tester);
        expect(find.byKey(const Key('console_readout_notice')), findsNothing);
      });

      testWidgets('fills the top margin and moves nothing on the readout', (
        tester,
      ) async {
        await pump(tester);
        final header = tester.getRect(
          find.byKey(const Key('console_readout_number')),
        );
        final footer = tester.getRect(
          find.byKey(const Key('console_readout_function')),
        );
        await pump(
          tester,
          readout: const PerformanceReadout(selected: selected, notice: lost),
        );
        final band = tester.getRect(
          find.byKey(const Key('console_readout_notice')),
        );
        expect(band.top, 0);
        expect(band.width, 1280);
        expect(band.height, NoticeTheme.standard.readoutBandHeight);
        expect(band.bottom, lessThanOrEqualTo(header.top));
        expect(
          tester.getRect(find.byKey(const Key('console_readout_number'))),
          header,
        );
        expect(
          tester.getRect(find.byKey(const Key('console_readout_function'))),
          footer,
        );
        expect(
          find.text(lost.title, findRichText: true),
          findsOneWidget,
        );
      });

      testWidgets('a sentence too long for one line is said whole, the band '
          'growing over the readout', (tester) async {
        const detail =
            'The original was kept beside it. Its Master effects, and pedals '
            'bound to them, now run on All tracks. A live input above 100% '
            'was lowered to 100%. It saved no tempo, so its tempo was set '
            'from the loop length.';
        await pump(
          tester,
          readout: const PerformanceReadout(
            selected: selected,
            notice: ReadoutNotice(
              title: 'Session converted from an older Segno',
              body: detail,
              tone: NoticeTone.success,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final wrapped = find.byKey(const Key('notice_sentence_wrapped'));
        expect(wrapped, findsOneWidget);
        expect(
          find.textContaining('set from the loop length', findRichText: true),
          findsOneWidget,
        );
        final band = tester.getRect(
          find.byKey(const Key('console_readout_notice')),
        );
        expect(
          band.height,
          greaterThan(NoticeTheme.standard.readoutBandHeight),
        );
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(of: wrapped, matching: find.byType(RichText)),
        );
        expect(text.didExceedMaxLines, isFalse);
        expect(text.textSize.height, lessThanOrEqualTo(text.size.height));
      });

      testWidgets('the longest message, on the 7" panel, stays well inside '
          'the readout', (tester) async {
        // Every change a conversion can report, and eight held chains: the
        // most any message says.
        const detail =
            'The original was kept beside it. Its Master effects, and pedals '
            'bound to them, now run on All tracks. A live input above 100% '
            'was lowered to 100%. It saved no tempo, so its tempo was set '
            'from the loop length. GUITAR, BOOM, RC-20, VOX, TRACK 5, '
            'TRACK 6, TRACK 7 and the Guitar input chain are off.';
        await pump(
          tester,
          size: const Size(1024, 600),
          readout: const PerformanceReadout(
            selected: selected,
            notice: ReadoutNotice(
              title: 'Session converted from an older Segno',
              body: detail,
              tone: NoticeTone.success,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final band = tester.getRect(
          find.byKey(const Key('console_readout_notice')),
        );
        expect(band.height, lessThan(600 / 3));
        expect(
          find.textContaining('input chain are off', findRichText: true),
          findsOneWidget,
        );
      });

      testWidgets("carries the main bar's marks: the dot only for a critical "
          'message', (tester) async {
        await pump(
          tester,
          readout: const PerformanceReadout(selected: selected, notice: lost),
        );
        expect(
          find.byKey(const Key('console_readout_notice_dot')),
          findsOneWidget,
        );
        await pump(
          tester,
          readout: const PerformanceReadout(
            selected: selected,
            notice: ReadoutNotice(
              title: 'Cleared all tracks',
              tone: NoticeTone.neutral,
            ),
          ),
        );
        expect(
          find.byKey(const Key('console_readout_notice_dot')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('console_readout_notice')),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
      });

      testWidgets("a track's message says the track first, on one line", (
        tester,
      ) async {
        await pump(
          tester,
          size: const Size(1024, 600),
          readout: const PerformanceReadout(
            selected: selected,
            notice: ReadoutNotice(
              title: 'Recording did not start',
              body: 'Press Record again',
              tone: NoticeTone.warning,
              track: 'GUITAR',
            ),
          ),
        );
        expect(
          find.textContaining('GUITAR', findRichText: true),
          findsOneWidget,
        );
        // The title whole, and the body too: it fits the 7".
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const Key('notice_sentence_title')),
            matching: find.byType(RichText),
          ),
        );
        expect(text.didExceedMaxLines, isFalse);
        expect(find.text('Press Record again'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('survives the 7" panel\'s narrower aspect without overflow', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1024, 600),
        readout: const PerformanceReadout(
          selected: ReadoutTrack(
            channel: 7,
            name: 'A deliberately very long track name that keeps going',
            state: 'overdubbing',
            primary: true,
            bars: 64,
          ),
          tempoBpm: 300,
          hasTempo: true,
          tsNum: 15,
          tsDen: 16,
          mode: 'mute',
          activeBank: 1,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

extension on PerformanceReadout {
  PerformanceReadout copyWithMode(String mode, {required int bank}) =>
      PerformanceReadout(
        selected: selected,
        tempoBpm: tempoBpm,
        hasTempo: hasTempo,
        tsNum: tsNum,
        tsDen: tsDen,
        mode: mode,
        activeBank: bank,
        goodbye: goodbye,
      );
}
