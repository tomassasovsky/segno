import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/fx_options_sheet.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('showFxOptionsSheet', () {
    Future<void> open(WidgetTester tester, List<FxOption> options) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showFxOptionsSheet(
              context,
              title: 'Move to folder',
              options: options,
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a list longer than the canvas scrolls inside the panel and '
        'every row stays reachable', (tester) async {
      await open(tester, [
        for (var i = 0; i < 12; i++) FxOption(id: 'f$i', label: 'Folder $i'),
      ]);

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('fx_options_sheet'))).height,
        lessThanOrEqualTo(1080),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('fx_option_f11')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('fx_options_sheet')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('fx_option_f11')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fx_options_sheet')), findsNothing);
    });
  });
}
