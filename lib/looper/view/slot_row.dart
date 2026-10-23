import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A row of fixed slots: every slot's position and size depends on the width
/// the row is given, never on what the slots show (#1308).
///
/// A readout that changes value or length — a level going from `−∞` to
/// `-60.0`, a count from `2 bars` to `16 bars` — therefore moves nothing:
/// not itself and not its neighbours. What does not fit is ellipsized or
/// clipped inside its own slot.
///
/// The row is laid out at the available width, or at [minWidth] when the
/// available width is narrower, and then scaled down uniformly as one piece
/// (a narrow desktop window). The scale depends on the available width only,
/// so it too is the same for every value.
class SlotRow extends StatelessWidget {
  /// Creates a [SlotRow].
  const SlotRow({
    required this.slots,
    this.minWidth = 0,
    this.spacing = 0,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    super.key,
  });

  /// The slots, leading to trailing.
  final List<RowSlot> slots;

  /// The narrowest width the slots are laid out at before the row scales.
  final double minWidth;

  /// The gap between neighbouring slots.
  final double spacing;

  /// How the slots line up across the row. [CrossAxisAlignment.baseline]
  /// aligns them on the alphabetic baseline.
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : minWidth;
      final width = math.max(available, minWidth);
      final row = SizedBox(
        width: width,
        child: Row(
          spacing: spacing,
          crossAxisAlignment: crossAxisAlignment,
          textBaseline: TextBaseline.alphabetic,
          children: [
            for (final slot in slots)
              if (slot.width case final fixed?)
                SizedBox(width: fixed, child: slot)
              else
                Expanded(flex: slot.flex, child: slot),
          ],
        ),
      );
      if (width <= available) return row;
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: row,
      );
    },
  );
}

/// One slot of a [SlotRow]: [width] logical pixels wide, or a [flex] share
/// of what the fixed slots leave. Its [child] sits at [alignment] inside it
/// and is clipped to it.
class RowSlot extends StatelessWidget {
  /// Creates a [RowSlot].
  const RowSlot({
    required this.child,
    this.width,
    this.flex = 1,
    this.alignment = AlignmentDirectional.centerStart,
    super.key,
  });

  /// The slot's content. Text in it should be single-line with an
  /// ellipsis, so a long value is shortened rather than cut mid-glyph.
  final Widget child;

  /// A fixed width; null shares the remaining width by [flex].
  final double? width;

  /// The share of the remaining width when [width] is null.
  final int flex;

  /// Where [child] sits inside the slot.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Align(alignment: alignment, heightFactor: 1, child: child),
  );
}
