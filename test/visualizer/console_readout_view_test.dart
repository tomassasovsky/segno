import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';

void main() {
  group('ConsoleReadoutView', () {
    const readout = PerformanceReadout(
      tracks: [
        ReadoutTrack(name: 'DRUMS', state: 'playing'),
        ReadoutTrack(name: 'BASS', state: 'recording', selected: true),
      ],
      tempoBpm: 120,
      hasTempo: true,
      currentBeat: 1,
      loopBars: 8,
      isRunning: true,
      elapsedSeconds: 11,
    );

    Future<void> pump(WidgetTester tester, PerformanceReadout data) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ConsoleReadoutView(
                readout: data,
                waveform: const SizedBox(key: Key('waveform_region')),
              ),
            ),
          ),
        );

    testWidgets('shows tempo, bars, clock, mode word and the beat dots', (
      tester,
    ) async {
      await pump(tester, readout);

      expect(find.byKey(const Key('console_readout_tempo')), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_bars')), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_clock')), findsOneWidget);
      expect(find.text('0:00:11'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_mode')), findsOneWidget);
      expect(find.byKey(const Key('console_readout_beats')), findsOneWidget);
    });

    testWidgets('renders no track-level content — names live on the 16"', (
      tester,
    ) async {
      // Owner-directed revision of the pen's drawn screen (#695): at two
      // metres the per-track words are noise; the readout must not render
      // them even though the payload still carries the tracks (the waveform
      // colouring keys off the selected one).
      await pump(tester, readout);
      expect(find.text('DRUMS'), findsNothing);
      expect(find.text('BASS'), findsNothing);
    });

    testWidgets('keeps the waveform as the loop strip', (tester) async {
      await pump(tester, readout);
      expect(find.byKey(const Key('console_readout_waveform')), findsOneWidget);
      expect(find.byKey(const Key('waveform_region')), findsOneWidget);
    });

    testWidgets('lights one beat dot per tsNum, the current one', (
      tester,
    ) async {
      await pump(tester, readout.copyWithBeat(tsNum: 3, currentBeat: 2));
      final dots = find.descendant(
        of: find.byKey(const Key('console_readout_beats')),
        matching: find.byType(DecoratedBox),
      );
      expect(dots, findsNWidgets(3));
      final lit = tester
          .widgetList<DecoratedBox>(dots)
          .map((d) => (d.decoration as BoxDecoration).color)
          .where(
            (c) => c == AppTheme.neon.extension<SurfaceTheme>()!.textPrimary,
          )
          .length;
      expect(lit, 1);
    });

    testWidgets('hides the dots and shows -- on the tempo-free path', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout(elapsedSeconds: 5));
      expect(find.byKey(const Key('console_readout_beats')), findsNothing);
      expect(find.text('--'), findsOneWidget);
      // The clock still runs: the transport can play tempo-free.
      expect(find.text('0:00:05'), findsOneWidget);
    });

    testWidgets('hides the bar count when nothing defines a loop yet', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout(tempoBpm: 120));
      expect(find.byKey(const Key('console_readout_bars')), findsNothing);
    });

    testWidgets('announces the count-in beside the dots', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pump(tester, readout);
      expect(find.byKey(const Key('console_readout_count_in')), findsNothing);

      await pump(tester, readout.copyWithBeat(countingIn: true));
      expect(find.byKey(const Key('console_readout_count_in')), findsOneWidget);
      expect(find.text(l10n.readoutCountIn), findsOneWidget);
    });

    testWidgets('the record light idles dim and lights with the elapsed when '
        'a capture runs', (tester) async {
      await pump(tester, readout);
      expect(find.byKey(const Key('console_readout_record')), findsOneWidget);
      expect(
        find.byKey(const Key('console_readout_record_elapsed')),
        findsNothing,
      );

      await pump(
        tester,
        const PerformanceReadout(recordArmed: true, recordSeconds: 754),
      );
      expect(
        find.byKey(const Key('console_readout_record_elapsed')),
        findsOneWidget,
      );
      expect(find.text('12:34'), findsOneWidget);
    });

    testWidgets('maps each mode token to its word', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      for (final (token, word) in [
        ('record', l10n.readoutModeRecord),
        ('mute', l10n.readoutModeMute),
        ('fx', l10n.readoutModeFx),
      ]) {
        await pump(tester, PerformanceReadout(mode: token));
        expect(
          find.descendant(
            of: find.byKey(const Key('console_readout_mode')),
            matching: find.text(word),
          ),
          findsOneWidget,
          reason: 'mode $token must read $word',
        );
      }
    });

    testWidgets('renders an unknown mode token verbatim rather than guessing', (
      tester,
    ) async {
      // A newer main window paired with an older sub-window must degrade to
      // showing the raw mode, never to showing the wrong one.
      await pump(tester, const PerformanceReadout(mode: 'custom'));
      expect(find.text('CUSTOM'), findsOneWidget);
    });

    testWidgets('scales the type with the window height, not absolutely', (
      tester,
    ) async {
      // The pen draws at 1920x1080; the device window is 640x360 logical
      // today. The tempo figure must be the pen's 77 times height/1080 —
      // proportions are the contract, not pixels.
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, readout);
      final full = tester.widget<Text>(find.text('120')).style!.fontSize!;

      tester.view.physicalSize = const Size(640, 360);
      await pump(tester, readout);
      final third = tester.widget<Text>(find.text('120')).style!.fontSize!;
      expect(third, moreOrLessEquals(full / 3));
    });
  });
}

/// Test-side convenience: tweak the beat facts without restating the rest.
extension on PerformanceReadout {
  PerformanceReadout copyWithBeat({
    int? tsNum,
    int? currentBeat,
    bool? countingIn,
  }) => PerformanceReadout(
    tracks: tracks,
    tempoBpm: tempoBpm,
    hasTempo: hasTempo,
    tsNum: tsNum ?? this.tsNum,
    tsDen: tsDen,
    currentBeat: currentBeat ?? this.currentBeat,
    countingIn: countingIn ?? this.countingIn,
    loopBars: loopBars,
    isRunning: isRunning,
    mode: mode,
    activeBank: activeBank,
    elapsedSeconds: elapsedSeconds,
    recordArmed: recordArmed,
    recordSeconds: recordSeconds,
  );
}
