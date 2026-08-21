import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';

void main() {
  group('readoutClock', () {
    test('shows m:ss below ten minutes — no phantom leading hours', () {
      expect(readoutClock(0), '0:00');
      expect(readoutClock(11), '0:11');
      expect(readoutClock(272), '4:32');
    });

    test('shows mm:ss below one hour', () {
      expect(readoutClock(754), '12:34');
      expect(readoutClock(3599), '59:59');
    });

    test('grows hours only at one hour and beyond', () {
      expect(readoutClock(3600), '1:00:00');
      expect(readoutClock(3671), '1:01:11');
      expect(readoutClock(36000), '10:00:00');
    });
  });

  group('readoutTempo', () {
    test('decides the decimal on the rendered string, not the value', () {
      // 119.98 is non-integer as a double but rounds to "120.0" at one
      // decimal — a value-level check would keep that phantom ".0".
      expect(readoutTempo(120), '120');
      expect(readoutTempo(119.98), '120');
      expect(readoutTempo(119.94), '119.9');
      expect(readoutTempo(120.5), '120.5');
    });
  });

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
      elapsedSeconds: 272,
    );

    Future<void> pump(
      WidgetTester tester,
      PerformanceReadout data, {
      Locale? locale,
      VoidCallback? onMix,
      ThemeData? theme,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.neon,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConsoleReadoutView(
            readout: data,
            waveform: const SizedBox(key: Key('waveform_region')),
            onMix: onMix,
          ),
        ),
      ),
    );

    testWidgets('shows tempo, clock, bars, mode word and the beat dots', (
      tester,
    ) async {
      await pump(tester, readout);

      expect(find.byKey(const Key('console_readout_tempo')), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_bars')), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_clock')), findsOneWidget);
      expect(find.text('4:32'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_mode')), findsOneWidget);
      expect(find.byKey(const Key('console_readout_beats')), findsOneWidget);
    });

    testWidgets('renders no track-level content — names live on the 16"', (
      tester,
    ) async {
      // Owner decision (`c/readout`): at two metres the per-track words are
      // noise; the readout must not render them even though the payload
      // still carries the tracks (the waveform colouring keys off the
      // selected one).
      await pump(tester, readout);
      expect(find.text('DRUMS'), findsNothing);
      expect(find.text('BASS'), findsNothing);
    });

    testWidgets('keeps the waveform as the loop strip', (tester) async {
      await pump(tester, readout);
      expect(find.byKey(const Key('console_readout_waveform')), findsOneWidget);
      expect(find.byKey(const Key('waveform_region')), findsOneWidget);
    });

    testWidgets('the MIX pill fires onMix; the rest of the glass is inert', (
      tester,
    ) async {
      var mixTaps = 0;
      await pump(tester, readout, onMix: () => mixTaps++);

      expect(find.text('MIX'), findsOneWidget);
      await tester.tap(find.byKey(const Key('console_readout_mix')));
      expect(mixTaps, 1);

      // The old tap-anywhere gesture is dead (#707): the strip's glass and
      // the header figures do nothing — their surfaces stay reserved for
      // future interactivity.
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('console_readout_waveform'))),
      );
      await tester.tap(
        find.byKey(const Key('console_readout_tempo')),
        warnIfMissed: false,
      );
      expect(mixTaps, 1);
    });

    testWidgets('the MIX pill hugs the strip corner at the pen geometry', (
      tester,
    ) async {
      await pump(tester, readout);
      // The default 800x600 surface is width-limited against the pen's
      // 1920x1080 — the same scale the view derives.
      const s = 800 / 1920;

      final strip = tester.getRect(
        find.byKey(const Key('console_readout_waveform')),
      );
      final target = tester.getRect(
        find.byKey(const Key('console_readout_mix')),
      );
      // The tap target (pill + its 24-inset margin) reaches exactly the
      // strip's corner — generous for a finger, nothing like the strip.
      expect(target.right, moreOrLessEquals(strip.right));
      expect(target.bottom, moreOrLessEquals(strip.bottom));

      // The drawn pill is the pen's 180x72, inset 24 from the corner.
      final pill = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('console_readout_mix')),
          matching: find.byType(Container),
        ),
      );
      expect(pill.width, moreOrLessEquals(180 * s));
      expect(pill.height, moreOrLessEquals(72 * s));
      expect(pill.right, moreOrLessEquals(strip.right - 24 * s));
      expect(pill.bottom, moreOrLessEquals(strip.bottom - 24 * s));
    });

    testWidgets('drops the decimal on an integer tempo, keeps one otherwise', (
      tester,
    ) async {
      // The two-metre face never states "120.0" — the decimal appears only
      // when the tempo actually carries one.
      await pump(tester, readout);
      expect(find.text('120'), findsOneWidget);
      expect(find.text('120.0'), findsNothing);

      await pump(tester, const PerformanceReadout(tempoBpm: 120.5));
      expect(find.text('120.5'), findsOneWidget);

      // A tapped tempo lands at 119.98: non-integer as a value, integer as
      // a rendered figure — it must read "120", not "120.0".
      await pump(tester, const PerformanceReadout(tempoBpm: 119.98));
      expect(find.text('120'), findsOneWidget);
      expect(find.text('120.0'), findsNothing);
    });

    testWidgets('draws the figures in Inter with tabular numerals, not the '
        'mono face', (tester) async {
      // The owner rejected the mono face's dotted zeros; tabular figures are
      // what keep the ticking clock from jittering in the proportional face.
      await pump(tester, readout);
      for (final figure in ['120', '4:32', '8']) {
        final style = tester.widget<Text>(find.text(figure)).style!;
        expect(style.fontFamily, isNot(SurfaceTheme.monoFont));
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: '$figure must use tabular numerals',
        );
      }
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
      expect(find.text('0:05'), findsOneWidget);
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

    testWidgets('fills the active half of the bank pair', (tester) async {
      Color? fillOf(int bank) {
        final half = tester.widget<Container>(
          find.byKey(Key('console_readout_bank_$bank')),
        );
        return (half.decoration as BoxDecoration?)?.color;
      }

      final control = AppTheme.neon.extension<SurfaceTheme>()!.control;

      await pump(tester, readout);
      expect(find.byKey(const Key('console_readout_bank')), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(fillOf(0), control);
      expect(fillOf(1), isNull);

      await pump(tester, const PerformanceReadout(activeBank: 1));
      expect(fillOf(0), isNull);
      expect(fillOf(1), control);
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

    testWidgets('paints the mode word red recording, green muting', (
      tester,
    ) async {
      final surface = AppTheme.neon.extension<SurfaceTheme>()!;
      TextStyle styleOf() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('console_readout_mode')),
              matching: find.byType(Text),
            ),
          )
          .style!;

      // Both readings come from the LED palette, not the chrome tokens the
      // desktop surfaces use — this is the two-metre panel, and these are the
      // colours the pedal's own MODE LED throws. See _ModeWord's doc for the
      // measured ratios; these assertions are what stop a well-meaning token
      // unification from quietly dimming the panel.
      await pump(tester, const PerformanceReadout());
      expect(styleOf().color, surface.ledRed);

      // #693 — the owner's call from the bench: the mute reading is green on
      // every surface, so this word may not fall back to plain white.
      await pump(tester, const PerformanceReadout(mode: 'mute'));
      expect(styleOf().color, surface.ledGreen);

      // FX has its OWN arm. It used to fall through to the neutral `_` case,
      // which made "FX" and "a token this build cannot parse" the same colour
      // on the largest mode reading in the rig.
      await pump(tester, const PerformanceReadout(mode: 'fx'));
      expect(styleOf().color, surface.ledBlue);

      // ...so neutral now means exactly one thing: an unknown token from a
      // newer main window (or the pre-rename legacy `'play'`).
      for (final token in ['custom', 'play']) {
        await pump(tester, PerformanceReadout(mode: token));
        expect(
          styleOf().color,
          surface.textPrimary,
          reason: 'unknown token $token must read neutral',
        );
      }

      // All three known modes are distinct from each other and from neutral.
      expect({
        surface.ledRed,
        surface.ledGreen,
        surface.ledBlue,
        surface.textPrimary,
      }, hasLength(4));
    });

    testWidgets('the armed record pill washes with the recSurface TOKEN', (
      tester,
    ) async {
      BoxDecoration pillOf() =>
          tester
                  .widget<Container>(
                    find.byKey(const Key('console_readout_record')),
                  )
                  .decoration!
              as BoxDecoration;

      // The outline reads `ledRed` for contrast, and deriving the wash from
      // that same red at a fixed alpha looked tidier. It is not: the wash is
      // the one part of this pill the flavors override, and an inline alpha
      // silently pinned the armed fill at 0.14 while high contrast lifts the
      // token to 0.2 — dimming the accessibility flavor on the 7" panel, the
      // exact surface this change exists to make more legible.
      for (final data in [AppTheme.neon, AppTheme.highContrast]) {
        final s = data.extension<SurfaceTheme>()!;
        // Unmount between flavors: MaterialApp animates a theme swap, so
        // re-pumping the same tree with a new theme would still read the old
        // one on the single frame this pumps.
        await tester.pumpWidget(const SizedBox.shrink());
        await pump(
          tester,
          const PerformanceReadout(recordArmed: true),
          theme: data,
        );
        expect(pillOf().color, s.recSurface);
        expect(pillOf().border!.top.color, s.ledRed);

        await pump(tester, const PerformanceReadout(), theme: data);
        expect(pillOf().color, isNull, reason: 'idle pill takes no wash');
      }

      // The dark flavor alone cannot see this: its `recSurface` alpha (0x24)
      // rounds to the same 0.14 the hardcode used, so only the boost proves
      // the token is actually being read.
      expect(
        SurfaceTheme.highContrast.recSurface.a,
        greaterThan(SurfaceTheme.dark.recSurface.a),
      );
    });

    testWidgets('renders an unknown mode token verbatim rather than guessing', (
      tester,
    ) async {
      // A newer main window paired with an older sub-window must degrade to
      // showing the raw mode, never to showing the wrong one.
      await pump(tester, const PerformanceReadout(mode: 'custom'));
      expect(find.text('CUSTOM'), findsOneWidget);
    });

    testWidgets('scales a long unknown mode token down instead of clipping', (
      tester,
    ) async {
      // The left cluster's FittedBox guard does not cover the right column:
      // a 20-character token from a newer main window must shrink to the
      // pen's right-column width, never RenderFlex-overflow the header.
      await pump(
        tester,
        const PerformanceReadout(mode: 'granular-freeze-mode'),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('GRANULAR-FREEZE-MODE'), findsOneWidget);
    });

    testWidgets('survives the worst legal header without overflowing', (
      tester,
    ) async {
      // Everything the header can carry, at once, in the wordier locale: the
      // Spanish count-in phrase, a 15-beat signature's dot run, an hour-plus
      // clock (h:mm:ss), a non-integer tempo, MUTE, bank B, and an armed
      // capture. The pen proves its drawn worst case with ~110 px of slack;
      // this one it never draws, so the figures-and-dots cluster must scale
      // down gracefully rather than clip the right column off the panel.
      await pump(
        tester,
        const PerformanceReadout(
          tempoBpm: 120.5,
          hasTempo: true,
          tsNum: 15,
          currentBeat: 14,
          countingIn: true,
          loopBars: 12,
          mode: 'mute',
          activeBank: 1,
          elapsedSeconds: 3671,
          recordArmed: true,
          recordSeconds: 3599,
        ),
        locale: const Locale('es'),
      );
      expect(tester.takeException(), isNull);
      // The whole right column is still on the panel.
      expect(find.byKey(const Key('console_readout_mode')), findsOneWidget);
      expect(find.byKey(const Key('console_readout_bank')), findsOneWidget);
      expect(
        find.byKey(const Key('console_readout_record_elapsed')),
        findsOneWidget,
      );
    });

    testWidgets('scales the type with the window height, not absolutely', (
      tester,
    ) async {
      // The pen draws at 1920x1080; the device window is 640x360 logical
      // today. The tempo figure must be the pen's 180 times height/1080 —
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
