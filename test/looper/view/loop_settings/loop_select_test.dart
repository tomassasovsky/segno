import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('LoopSelect', () {
    late List<String> chosen;

    setUp(() => chosen = []);

    Future<void> pump(
      WidgetTester tester, {
      String value = 'b',
      bool enabled = true,
    }) => tester.pumpApp(
      Center(
        child: LoopSelect<String>(
          key: const Key('select'),
          value: value,
          enabled: enabled,
          onSelected: chosen.add,
          items: [
            for (final v in ['a', 'b', 'c'])
              LoopSelectItem(key: Key('row_$v'), value: v, label: 'Item $v'),
          ],
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the current label and opens on tap to list every '
        'choice', (tester) async {
      await pump(tester);
      expect(find.text('Item b'), findsOneWidget);
      expect(find.byKey(const Key('row_a')), findsNothing);

      await open(tester);

      for (final v in ['a', 'b', 'c']) {
        expect(find.byKey(Key('row_$v')), findsOneWidget);
      }
      expect(find.byIcon(LucideIcons.chevronUp), findsOneWidget);
    });

    testWidgets('choosing a row reports it and closes the menu', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('row_c')));
      await tester.pumpAndSettle();

      expect(chosen, ['c']);
      expect(find.byKey(const Key('row_c')), findsNothing);
      expect(find.byIcon(LucideIcons.chevronDown), findsOneWidget);
    });

    testWidgets('the current choice carries the check', (tester) async {
      await pump(tester);
      await open(tester);

      expect(find.byIcon(LucideIcons.check), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('row_b')),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('opening focuses the current row; arrow down and Enter '
        'choose the next', (tester) async {
      await pump(tester);
      await open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(chosen, ['c']);
      expect(find.byKey(const Key('row_c')), findsNothing);
    });

    testWidgets('Escape closes without choosing', (tester) async {
      await pump(tester);
      await open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(chosen, isEmpty);
      expect(find.byKey(const Key('row_a')), findsNothing);
    });

    testWidgets('a disabled select does not open', (tester) async {
      await pump(tester, enabled: false);
      await open(tester);

      expect(find.byKey(const Key('row_a')), findsNothing);
    });
  });
}
