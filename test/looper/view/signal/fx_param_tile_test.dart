import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/signal/fx_param_tile.dart';

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
}
