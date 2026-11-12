import 'package:material_ui/material_ui.dart';
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

    group('fitLabel (#1672)', () {
      const long = 'A label longer than its button';
      double drawnScale(WidgetTester tester) =>
          tester.getRect(find.text(long)).width /
          tester.getSize(find.text(long)).width;

      Future<void> pump(WidgetTester tester, {required bool fitLabel}) =>
          tester.pumpApp(
            Center(
              child: LoopOutlinedButton(
                width: 100,
                fitLabel: fitLabel,
                label: long,
                onTap: () {},
              ),
            ),
          );

      testWidgets('widens the button to its label', (tester) async {
        await pump(tester, fitLabel: true);
        expect(
          tester.getSize(find.byType(LoopOutlinedButton)).width,
          greaterThan(100),
        );
        // Drawn at its own size, not scaled into the box.
        expect(drawnScale(tester), 1);
      });

      testWidgets('keeps the width when the label fits', (tester) async {
        await tester.pumpApp(
          Center(
            child: LoopOutlinedButton(
              width: 400,
              fitLabel: true,
              label: 'Short',
              onTap: () {},
            ),
          ),
        );
        expect(tester.getSize(find.byType(LoopOutlinedButton)).width, 400);
      });

      testWidgets('without it the label scales down in the fixed box', (
        tester,
      ) async {
        await pump(tester, fitLabel: false);
        expect(tester.getSize(find.byType(LoopOutlinedButton)).width, 100);
        expect(drawnScale(tester), lessThan(1));
      });
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
