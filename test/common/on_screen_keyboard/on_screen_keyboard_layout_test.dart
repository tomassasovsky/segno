import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';

import '../../helpers/helpers.dart';

void main() {
  group('$OnScreenKeyboard layout (#1672)', () {
    for (final layout in OnScreenKeyboardLayout.values) {
      testWidgets('${layout.name}: the outer keys sit on its edges, '
          '${OnScreenKeyboard.keyGap} apart', (tester) async {
        await tester.pumpApp(
          Center(
            child: SizedBox(
              width: 600,
              child: OnScreenKeyboard(
                layout: layout,
                onKey: (_) {},
                onBackspace: () {},
                onDone: () {},
                doneLabel: 'Set',
              ),
            ),
          ),
        );
        final board = tester.getRect(find.byType(OnScreenKeyboard));
        final done = tester.getRect(
          find
              .ancestor(of: find.text('Set'), matching: find.byType(SizedBox))
              .first,
        );
        expect(done.right, board.right);
        expect(done.bottom, board.bottom);
        final one = tester.getRect(
          find
              .ancestor(
                of: find.text(
                  layout == OnScreenKeyboardLayout.numeric ? '1' : 'q',
                ),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        expect(one.left, board.left);
        expect(one.top, board.top);
        final first = layout == OnScreenKeyboardLayout.numeric ? '1' : 'q';
        final next = layout == OnScreenKeyboardLayout.numeric ? '2' : 'w';
        final below = layout == OnScreenKeyboardLayout.numeric ? '4' : 'a';
        Rect keyOf(String text) => tester.getRect(
          find
              .ancestor(of: find.text(text), matching: find.byType(SizedBox))
              .first,
        );
        expect(keyOf(next).left - keyOf(first).right, OnScreenKeyboard.keyGap);
        expect(keyOf(below).top - keyOf(first).bottom, OnScreenKeyboard.keyGap);
      });
    }
  });
}
