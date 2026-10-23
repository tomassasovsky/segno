import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/fx/fx_rack_editor.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('FxPedalColumn', () {
    Future<void> pump(WidgetTester tester, BuiltInEffect effect) =>
        tester.pumpApp(
          Center(
            child: FxPedalColumn(
              effect: effect,
              onTogglePower: () {},
              onParam: (_, _) {},
            ),
          ),
        );

    testWidgets("a rack's EQ shows the controls its rack shows, under its "
        'names', (tester) async {
      final module = kFxModules.firstWhere((m) => m.name == 'Four-band EQ');
      final drum = fxModuleEntry(
        module,
        const FxPreset(
          family: 'Drum Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {
            'EQ': 1,
            'EQ Low': 0.5,
            'EQ Mid': 0.5,
            'EQ Mid Freq': 0.5,
            'EQ High': 0.5,
          },
        ),
      );
      await pump(tester, drum);

      for (final i in [1, 4, 5, 10]) {
        expect(find.byKey(Key('fx_pedal_param_$i')), findsOneWidget);
      }
      expect(find.byKey(const Key('fx_pedal_param_0')), findsNothing);
      expect(find.byKey(const Key('fx_pedal_param_14')), findsNothing);
      expect(find.text('Mid'), findsOneWidget);
      expect(find.text('Mid freq'), findsOneWidget);
      expect(find.text('Lo mid'), findsNothing);
      // The kind's own units, with no "Scale unverified" on a measured range.
      expect(find.text('0.0 dB'), findsNWidgets(3));
    });

    testWidgets('an EQ that is not a rack module shows every parameter', (
      tester,
    ) async {
      await pump(tester, BuiltInEffect(type: TrackEffectType.eq));

      expect(find.byKey(const Key('fx_pedal_param_0')), findsOneWidget);
      expect(find.text('Low cut'), findsOneWidget);
    });
  });
}
