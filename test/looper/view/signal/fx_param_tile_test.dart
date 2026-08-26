import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal/fx_param_tile.dart';
import 'package:segno/theme/theme.dart';

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

  testWidgets('the grid survives a system text scale', (tester) async {
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
    // 1.2 is a mild OS setting and it put a red overflow bar under EVERY tile
    // in the strip — twelve parameters, twelve bars. The tile is a fixed 59
    // and the box inside it was a fixed 36, so the name and the readout had
    // nowhere to grow into. 1.5 is well past what broke it.
    for (final scale in [1.0, 1.2, 1.5]) {
      await tester.pumpWidget(
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
                    value: -80,
                    valueText: null,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'at scale $scale');
      expect(
        tester.getSize(find.byKey(const Key('tile'))).height,
        FxParamTileMetrics.height,
        reason: 'the grid stays a grid at scale $scale',
      );
    }
  });

  group('spanish param names', () {
    // Real glyph metrics, not the test framework's default font: that font
    // draws every glyph a full em wide, which flunks names that fit the tile
    // comfortably in JetBrains Mono (0.6em advance) and would make any
    // fits-or-not assertion meaningless. This is the face `signalMono`
    // actually renders with. Loaded here and not inside the testWidgets body:
    // real file I/O never completes under the test framework's fake async.
    setUpAll(() async {
      final loader = FontLoader('JetBrains Mono')
        ..addFont(
          File(
            'assets/fonts/JetBrainsMono-Regular.ttf',
          ).readAsBytes().then((b) => ByteData.view(b.buffer)),
        );
      await loader.load();
    });

    testWidgets('render whole in the tile', (tester) async {
      late List<String> names;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppTextDefaults(child: child ?? const SizedBox.shrink()),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final l10n = context.l10n;
                // The three longest Spanish parameter names (#500) — the ones
                // that ellipsized under maxLines: 1 at the 78px tile width.
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

      expect(tester.takeException(), isNull);
      for (final (i, name) in names.indexed) {
        final caption = find.text(spacedParamName(name));
        expect(caption, findsOneWidget, reason: name);
        // The whole word, no ellipsis: the paragraph itself must report that it
        // laid the name out inside its constraints.
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
    });
  });
}
