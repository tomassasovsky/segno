import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/slot_row.dart';

/// The global rect of every [RowSlot] under [row], leading to trailing: what
/// a fixed-slot test compares before and after a readout changes (#1308).
List<Rect> slotRects(Finder row) => [
  for (final element
      in find.descendant(of: row, matching: find.byType(RowSlot)).evaluate())
    _rectOf(element.renderObject! as RenderBox),
];

/// The box's rect on screen, scale included (a [SlotRow] narrower than its
/// minimum is drawn scaled down).
Rect _rectOf(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
