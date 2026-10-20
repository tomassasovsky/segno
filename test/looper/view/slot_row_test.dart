import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/slot_row.dart';

import '../../helpers/helpers.dart';

void main() {
  Widget row(String value, {double width = 400, double minWidth = 0}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SlotRow(
              key: const Key('row'),
              minWidth: minWidth,
              spacing: 10,
              slots: [
                const RowSlot(width: 40, child: Text('1')),
                RowSlot(
                  child: Text(
                    value,
                    key: const Key('value'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const RowSlot(
                  flex: 2,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text('end'),
                ),
              ],
            ),
          ),
        ),
      );

  group(SlotRow, () {
    testWidgets('slots keep their rects whatever the value', (tester) async {
      await tester.pumpWidget(row('-∞'));
      final short = slotRects(find.byKey(const Key('row')));
      expect(short, hasLength(3));
      expect(short[0].width, 40);
      // The flex slots share what the fixed slot and the gaps leave, 1:2.
      expect(short[1].width, closeTo((400 - 40 - 20) / 3, 0.01));
      expect(short[2].width, closeTo(2 * (400 - 40 - 20) / 3, 0.01));

      await tester.pumpWidget(row('-60.0 dB and a great deal more text'));
      expect(slotRects(find.byKey(const Key('row'))), short);
      expect(tester.takeException(), isNull);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('value')),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isTrue);
    });

    testWidgets('a row narrower than its minimum scales down as one piece', (
      tester,
    ) async {
      await tester.pumpWidget(row('2', width: 200, minWidth: 400));
      final rects = slotRects(find.byKey(const Key('row')));
      expect(rects.first.width, closeTo(20, 0.01));
      expect(rects.last.right, closeTo(200, 0.01));

      await tester.pumpWidget(row('128 bars', width: 200, minWidth: 400));
      expect(slotRects(find.byKey(const Key('row'))), rects);
    });

    testWidgets('an unbounded row is laid out at its minimum', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: UnconstrainedBox(
            alignment: Alignment.topLeft,
            child: SlotRow(
              key: Key('row'),
              minWidth: 300,
              slots: [RowSlot(child: Text('a'))],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('row'))).width, 300);
    });
  });
}
