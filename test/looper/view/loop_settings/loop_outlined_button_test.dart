import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

import '../../../helpers/helpers.dart';

void main() {
  group(LoopOutlinedButton, () {
    Future<FontWeight?> weightOf(
      WidgetTester tester,
      LoopButtonTone tone,
    ) async {
      await tester.pumpApp(
        Center(
          child: LoopOutlinedButton(
            width: 200,
            tone: tone,
            label: 'Label',
            onTap: () {},
          ),
        ),
      );
      return tester.widget<Text>(find.text('Label')).style?.fontWeight;
    }

    testWidgets('an accent label is bold, as the pen draws every accent '
        'action', (tester) async {
      expect(await weightOf(tester, LoopButtonTone.accent), FontWeight.w700);
    });

    testWidgets('the other fills keep the regular weight', (tester) async {
      for (final tone in [
        LoopButtonTone.outlined,
        LoopButtonTone.raised,
        LoopButtonTone.card,
      ]) {
        expect(await weightOf(tester, tone), isNull, reason: tone.name);
      }
    });
  });
}
