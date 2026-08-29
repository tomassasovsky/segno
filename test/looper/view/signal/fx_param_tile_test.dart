import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal/fx_param_tile.dart';
import 'package:segno/theme/theme.dart';

/// Registers the app's real mono face for the rest of this test run.
///
/// What "the default font" means is not portable: macOS `flutter_tester`
/// resolves unknown families to the 1em-per-glyph test font, while the Linux
/// one (CI) resolves them to real system fonts with real ascenders — the same
/// tile can fit on one machine and overflow on the other. Loading the shipped
/// face makes the metrics the app's own, everywhere. Called from `setUpAll`,
/// never from inside `testWidgets` — real file I/O never completes under the
/// test framework's fake async.
Future<void> loadAppMonoFont() async {
  final loader = FontLoader('JetBrains Mono')
    ..addFont(
      File(
        'assets/fonts/JetBrainsMono-Regular.ttf',
      ).readAsBytes().then((b) => ByteData.view(b.buffer)),
    );
  await loader.load();
}

/// Pumps one [FxParamTile] under [scale] and returns nothing but trouble.
Future<void> pumpTile(
  WidgetTester tester, {
  required double scale,
  required PluginParamInfo spec,
  String? valueText,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.neon,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: AppTextDefaults(
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: FxParamTile(
              key: const Key('tile'),
              spec: spec,
              value: spec.def,
              valueText: valueText,
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  ),
);

/// The grid must hold its 59px row at any text scale, on whatever font is
/// resolving — no overflow bars, no grown tiles. The name row has no vertical
/// pinning to guarantee that; the value box is the shock absorber, scaling
/// its readout down once the slack is gone.
Future<void> expectGridSurvivesScales(WidgetTester tester) async {
  const spec = PluginParamInfo(
    id: 0,
    name: 'THRESHOLD',
    unit: 'dB',
    min: -100,
    max: 0,
    def: -80,
    stepCount: 0,
    flags: 0x01,
  );
  // 1.2 is a mild OS setting and it once put a red overflow bar under EVERY
  // tile in the strip. 1.5 is what overflowed the value box on fonts whose
  // natural line towers over the test font's 1em (CI resolves the app's
  // families to real system fonts). 3.0 is the ceiling of Android's display
  // sizes — nothing sane, everything survivable.
  for (final scale in [1.0, 1.2, 1.5, 3.0]) {
    await pumpTile(tester, scale: scale, spec: spec);
    final e = tester.takeException();
    if (e != null) {
      // The one-line summary ("overflowed by N pixels") cannot say WHICH
      // flex, and this has already failed on fonts the author machine does
      // not resolve. Dump what this run saw so its log is enough.
      debugPrint('=== tile render tree at scale $scale ===');
      debugPrint(
        tester
            .renderObject(find.byKey(const Key('tile')))
            .toStringDeep(minLevel: DiagnosticLevel.fine),
      );
    }
    expect(e, isNull, reason: 'at scale $scale');
    expect(
      tester.getSize(find.byKey(const Key('tile'))).height,
      FxParamTileMetrics.height,
      reason: 'the grid stays a grid at scale $scale',
    );
  }
}

/// A caption that fits must paint exactly as it laid out — scale 1, no
/// residual fit. An earlier cut pinned the name row to a computed
/// `fontSize x height` (9.9) while the engine measured the line at 10.0, and
/// the 0.99 height ratio silently rescaled every caption in the grid. Painted
/// extent vs layout extent is the assertion that catches that class of bug.
Future<void> expectFittingNamePaintsAsLaidOut(WidgetTester tester) async {
  const spec = PluginParamInfo(
    id: 0,
    name: 'DRIVE', // Fits the 78px tile even at 1em-per-glyph test metrics.
    unit: '',
    min: 0,
    max: 1,
    def: 0.5,
    stepCount: 0,
    flags: 0x01,
  );
  await pumpTile(tester, scale: 1, spec: spec, valueText: '50%');
  final caption = find.text('DRIVE');
  final laidOut = tester.renderObject<RenderParagraph>(caption).size;
  // getRect runs the paragraph's corners through its paint transform, so a
  // FittedBox scale — however slight — lands in the difference.
  final painted = tester.getRect(caption);
  expect(painted.height, moreOrLessEquals(laidOut.height));
  expect(painted.width, moreOrLessEquals(laidOut.width));
}

void main() {
  group('spacedParamName', () {
    test('runs camel case back apart', () {
      // What a plugin actually reports. Upper-cased as-is this reads
      // "OUTPUTMODE" — one long word at mono 9pt in a 78px tile.
      expect(spacedParamName('OutputMode'), 'OUTPUT MODE');
      expect(spacedParamName('dryWet'), 'DRY WET');
      expect(spacedParamName('lowCut3'), 'LOW CUT3');
    });

    test('leaves a name that punctuates itself alone', () {
      // Including acronyms, which the camel-case rule would otherwise
      // shatter into single letters.
      expect(spacedParamName('Output Mode'), 'OUTPUT MODE');
      expect(spacedParamName('EQ'), 'EQ');
      expect(spacedParamName('LFO Rate'), 'LFO RATE');
      expect(spacedParamName('Freq'), 'FREQ');
    });
  });

  // Both font regimes, deliberately: the framework's fallback stands in for
  // whatever exotic metrics a host resolves (CI's Linux tester hands back
  // real system fonts), the app face is what actually ships. The groups must
  // run in this order — a loaded font cannot be unloaded.
  group('under the framework test font', () {
    testWidgets('the grid survives a system text scale', (tester) async {
      await expectGridSurvivesScales(tester);
    });

    testWidgets('a fitting name paints at exactly its laid-out size', (
      tester,
    ) async {
      await expectFittingNamePaintsAsLaidOut(tester);
    });
  });

  group('under the app mono font', () {
    setUpAll(loadAppMonoFont);

    testWidgets('the grid survives a system text scale', (tester) async {
      await expectGridSurvivesScales(tester);
    });

    testWidgets('a fitting name paints at exactly its laid-out size', (
      tester,
    ) async {
      await expectFittingNamePaintsAsLaidOut(tester);
    });

    testWidgets('spanish param names render whole in the tile', (
      tester,
    ) async {
      late List<String> names;
      Future<void> pump(double scale) => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: AppTextDefaults(child: child ?? const SizedBox.shrink()),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final l10n = context.l10n;
                // The three longest Spanish parameter names (#500) — the
                // ones that ellipsized under maxLines: 1 at the 78px width.
                names = [
                  l10n.paramFeedback,
                  l10n.paramShift,
                  l10n.paramDamping,
                ];
                return Align(
                  alignment: Alignment.topLeft,
                  child: Wrap(
                    spacing: FxParamTileMetrics.gutter,
                    children: [
                      for (final (i, name) in names.indexed)
                        FxParamTile(
                          key: Key('tile_$i'),
                          spec: PluginParamInfo(
                            id: i,
                            name: name,
                            unit: '',
                            min: 0,
                            max: 1,
                            def: 0.5,
                            stepCount: 0,
                            flags: 0x01,
                          ),
                          value: 0.5,
                          valueText: '50%',
                          onTap: () {},
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      await pump(1);
      expect(tester.takeException(), isNull);
      for (final (i, name) in names.indexed) {
        final caption = find.text(spacedParamName(name));
        expect(caption, findsOneWidget, reason: name);
        // The whole word, no ellipsis: the paragraph itself must report
        // that it laid the name out inside its constraints.
        final paragraph = tester.renderObject<RenderParagraph>(caption);
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '"$name" must not truncate at the tile width',
        );
        expect(
          tester.getSize(find.byKey(Key('tile_$i'))).height,
          FxParamTileMetrics.height,
          reason: 'the grid stays a grid under "$name"',
        );
      }

      // At a raised text scale the fits-whole set narrows by design — the
      // ellipsis cap is a floor on painted glyph size, so wider glyphs seat
      // fewer characters. What must still hold: nothing overflows, and the
      // grid keeps its geometry.
      await pump(1.5);
      expect(tester.takeException(), isNull, reason: 'at scale 1.5');
      for (final (i, name) in names.indexed) {
        expect(
          tester.getSize(find.byKey(Key('tile_$i'))).height,
          FxParamTileMetrics.height,
          reason: 'the grid stays a grid under "$name" at scale 1.5',
        );
      }
    });
  });
}
