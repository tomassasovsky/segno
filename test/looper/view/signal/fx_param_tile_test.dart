import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
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
}
