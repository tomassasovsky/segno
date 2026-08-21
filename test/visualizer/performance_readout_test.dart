import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/performance_readout_view.dart';
import 'package:segno_engine/segno_engine.dart' show TrackState;

void main() {
  const readout = PerformanceReadout(
    tracks: [
      ReadoutTrack(name: 'Drums', state: 'playing'),
      ReadoutTrack(name: 'Bass', state: 'recording', selected: true),
      ReadoutTrack(name: 'Keys', state: 'playing', muted: true),
      ReadoutTrack(name: 'Gtr', state: 'empty', pending: true),
    ],
    tempoBpm: 128,
    hasTempo: true,
    currentBeat: 2,
    countingIn: true,
    loopBars: 8,
    isRunning: true,
    mode: 'fx',
    activeBank: 1,
    elapsedSeconds: 71,
    recordArmed: true,
    recordSeconds: 12,
  );

  group('PerformanceReadout wire format', () {
    test('survives a round trip through the channel payload', () {
      // The payload crosses a method channel between two Flutter engines, so
      // the map is the contract — not the Dart type.
      expect(PerformanceReadout.fromMap(readout.toMap()), readout);
    });

    test('a decoded empty payload is the default readout', () {
      expect(PerformanceReadout.fromMap(const {}), const PerformanceReadout());
    });

    test('ignores unknown fields, so a newer sender is readable', () {
      // A newer main window may grow the payload; an older sub-window must
      // read the fields it knows and drop the rest, never throw.
      final map = readout.toMap()..['someFutureFact'] = 42;
      expect(PerformanceReadout.fromMap(map), readout);
    });

    test('defaults the console facts on a pre-console payload', () {
      // A v1 (pre-console-readout) sender never wrote these keys: the decode
      // must fall back to quiet defaults, and hasTempo must fall back to the
      // old "tempo > 0" reading rather than hiding the dots.
      final decoded = PerformanceReadout.fromMap(const {
        'tempoBpm': 120.0,
        'mode': 'mute',
      });
      expect(decoded.hasTempo, isTrue);
      expect(decoded.currentBeat, 0);
      expect(decoded.countingIn, isFalse);
      // A #696-era sender dropped activeBank as unrendered; the decode
      // defaults it to bank A rather than throwing — the "without ceremony"
      // re-add that removal promised.
      expect(decoded.activeBank, 0);
      expect(decoded.elapsedSeconds, 0);
      expect(decoded.recordArmed, isFalse);
      expect(decoded.recordSeconds, 0);
      expect(
        PerformanceReadout.fromMap(const {'tempoBpm': 0.0}).hasTempo,
        isFalse,
      );
    });

    test('carries the volume-overlay facts through a round trip', () {
      // The #698 additions: per-track volume / chain / default-name flag /
      // source names, plus the configured-inputs group.
      const mixed = PerformanceReadout(
        tracks: [
          ReadoutTrack(
            name: 'GUITAR',
            state: 'playing',
            volume: 1.26,
            chainEnabled: false,
            inputNames: ['GUITAR'],
          ),
          ReadoutTrack(name: 'TRACK 5', state: 'empty', defaultName: true),
        ],
        inputs: [
          ReadoutInput(
            index: 1,
            name: 'MIC',
            volume: 0.5,
            listeningTracks: ['VOX'],
          ),
        ],
      );
      expect(PerformanceReadout.fromMap(mixed.toMap()), mixed);
    });

    test('defaults the volume-overlay facts on a pre-overlay payload', () {
      // A pre-#698 sender wrote none of these keys: volumes fall back to
      // unity (an unmoved fader, not silence), chains to engaged, and the
      // inputs group to empty.
      final decoded = PerformanceReadout.fromMap(const {
        'tracks': [
          {'name': 'Drums', 'state': 'playing'},
        ],
      });
      final track = decoded.tracks.single;
      expect(track.volume, 1);
      expect(track.chainEnabled, isTrue);
      expect(track.defaultName, isFalse);
      expect(track.inputNames, isEmpty);
      expect(decoded.inputs, isEmpty);
    });

    test('drops non-string entries from re-serialized name lists', () {
      // The plugin re-serializes typed lists as List<Object?> across the
      // engine boundary; junk entries must be dropped, not thrown on.
      final decoded = ReadoutInput.fromMap(const {
        'index': 2,
        'name': 'MIC',
        'listeningTracks': ['VOX', 3, null],
      });
      expect(decoded.listeningTracks, ['VOX']);
    });

    test('equality is by value, which is what makes the push diff work', () {
      expect(
        const PerformanceReadout(tempoBpm: 120),
        const PerformanceReadout(tempoBpm: 120),
      );
      expect(
        const PerformanceReadout(tempoBpm: 120),
        isNot(const PerformanceReadout(tempoBpm: 121)),
      );
    });
  });

  group('PerformanceReadoutView', () {
    Future<void> pump(WidgetTester tester, PerformanceReadout data) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: PerformanceReadoutView(
                readout: data,
                waveform: const SizedBox(key: Key('waveform_region')),
              ),
            ),
          ),
        );

    testWidgets('shows tempo, bars, mode and every track', (tester) async {
      await pump(tester, readout);

      expect(find.byKey(const Key('readout_tempo')), findsOneWidget);
      expect(find.byKey(const Key('readout_bars')), findsOneWidget);
      expect(find.byKey(const Key('readout_mode')), findsOneWidget);
      expect(find.text('128  4/4'), findsOneWidget);

      for (final name in ['Drums', 'Bass', 'Keys', 'Gtr']) {
        expect(find.text(name), findsOneWidget, reason: '$name is missing');
      }
    });

    testWidgets('keeps the waveform as one region, not the whole surface', (
      tester,
    ) async {
      await pump(tester, readout);
      expect(find.byKey(const Key('waveform_region')), findsOneWidget);
    });

    testWidgets('an armed track reads ARMED, outranking its own state', (
      tester,
    ) async {
      await pump(tester, readout);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // Gtr is empty AND pending; pending is the thing worth seeing.
      expect(find.text(l10n.readoutStatePending), findsOneWidget);
      // Keys is playing AND muted; muted wins for the same reason.
      expect(find.text(l10n.readoutStateMuted), findsOneWidget);
    });

    testWidgets('hides the bar count when nothing defines a loop yet', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout(tempoBpm: 120));
      expect(find.byKey(const Key('readout_bars')), findsNothing);
      expect(find.byKey(const Key('readout_tempo')), findsOneWidget);
    });

    testWidgets('the mode chip reads rec red, mute green and FX blue', (
      tester,
    ) async {
      // #693. This chip used to paint EVERY mode one accent blue, so its
      // colour said nothing: rec and FX were the same reading. All three
      // modes now carry the mapping the rest of the console uses.
      //
      // From the LED palette, NOT the chrome tokens: `_TrackRow._tint` paints
      // the state rows directly below this chip from `ledRed`/`ledAmber`/
      // `ledGreen`, so a chrome-token chip put `rec` #E5484D above a row of
      // `ledRed` #EF4444 — two reds a shade apart in one column, the very
      // defect unifying the mode surfaces was meant to remove.
      final surface = AppTheme.neon.extension<SurfaceTheme>()!;
      Color chipColor() =>
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(const Key('readout_mode')),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      Color labelColor() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('readout_mode')),
              matching: find.byType(Text),
            ),
          )
          .style!
          .color!;

      await pump(tester, const PerformanceReadout());
      expect(chipColor(), surface.ledRed.withValues(alpha: 0.18));
      expect(labelColor(), surface.ledRed);

      await pump(tester, const PerformanceReadout(mode: 'mute'));
      expect(chipColor(), surface.ledGreen.withValues(alpha: 0.18));
      expect(labelColor(), surface.ledGreen);

      await pump(tester, const PerformanceReadout(mode: 'fx'));
      expect(chipColor(), surface.ledBlue.withValues(alpha: 0.18));
      expect(labelColor(), surface.ledBlue);

      // ...and the three readings are actually distinct.
      expect({surface.ledRed, surface.ledGreen, surface.ledBlue}, hasLength(3));
    });

    testWidgets('the chip and the rows beneath it share one red and one '
        'green', (tester) async {
      // The near-miss guard. Both readings live in this one window, so the
      // chip may not drift onto a different token family from the rows: a
      // recording track under a RECORD chip must be one red, not two.
      final surface = AppTheme.neon.extension<SurfaceTheme>()!;
      Color labelColor() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('readout_mode')),
              matching: find.byType(Text),
            ),
          )
          .style!
          .color!;
      // 'REC' is both a track's state word and the record chip's own label,
      // so scope the row lookup to everything outside the chip.
      Color stateWordColor(String word) {
        final inChip = find
            .descendant(
              of: find.byKey(const Key('readout_mode')),
              matching: find.text(word),
            )
            .evaluate()
            .toSet();
        final rows = find.text(word).evaluate().toSet()..removeAll(inChip);
        return (rows.single.widget as Text).style!.color!;
      }

      const tracks = [
        ReadoutTrack(name: 'DRUMS', state: 'recording'),
        ReadoutTrack(name: 'BASS', state: 'playing'),
      ];

      await pump(tester, const PerformanceReadout(tracks: tracks));
      expect(labelColor(), stateWordColor('REC'));

      await pump(
        tester,
        const PerformanceReadout(mode: 'mute', tracks: tracks),
      );
      expect(labelColor(), stateWordColor('PLAY'));

      // Named so the failure says what broke: these are the two pairs that
      // used to be a shade apart.
      expect(surface.ledRed, isNot(surface.rec));
      expect(surface.ledGreen, isNot(surface.success));
    });

    testWidgets('an unknown mode token keeps the chip neutral', (tester) async {
      // A newer main window paired with an older sub-window must not have its
      // token folded into a real mode's colour — including the pre-rename
      // legacy `'play'`, which is mute's old token and must NOT silently
      // borrow mute's green from a build that no longer maps it.
      final surface = AppTheme.neon.extension<SurfaceTheme>()!;
      Color chipColor() =>
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(const Key('readout_mode')),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;

      for (final token in ['custom', 'play']) {
        await pump(tester, PerformanceReadout(mode: token));
        expect(
          chipColor(),
          surface.textPrimary.withValues(alpha: 0.18),
          reason: 'unknown token $token must read neutral',
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

    testWidgets('gives every engine TrackState its own label — only empty '
        'may read EMPTY', (tester) async {
      // Driven by TrackState.values, NOT by a hand-listed set: the states I
      // remembered were four of five, and `stopped` (which retains its loop
      // buffer) silently rendered as EMPTY. Anything added to the engine enum
      // fails here until the readout has a word for it.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      for (final state in TrackState.values) {
        await pump(
          tester,
          PerformanceReadout(
            tracks: [ReadoutTrack(name: 'Drums', state: state.name)],
          ),
        );

        final readsEmpty = find
            .text(l10n.readoutStateEmpty)
            .evaluate()
            .isNotEmpty;
        expect(
          readsEmpty,
          state == TrackState.empty,
          reason: state == TrackState.empty
              ? 'empty must read EMPTY'
              : '${state.name} renders as EMPTY — a track holding audio is '
                    'being reported as having none',
        );
      }
    });

    testWidgets('shows a dash for tempo before the engine reports one', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout());
      expect(find.text('--  4/4'), findsOneWidget);
    });

    testWidgets('decides the tempo decimal on the rendered string', (
      tester,
    ) async {
      // Same rule as the console readout: 119.98 is non-integer as a value
      // but rounds to "120.0" at one decimal — it must read "120".
      await pump(tester, const PerformanceReadout(tempoBpm: 119.98));
      expect(find.text('120  4/4'), findsOneWidget);

      await pump(tester, const PerformanceReadout(tempoBpm: 120.5));
      expect(find.text('120.5  4/4'), findsOneWidget);
    });
  });
}
