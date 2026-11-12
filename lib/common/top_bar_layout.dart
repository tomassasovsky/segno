import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:segno/theme/theme.dart';

/// A top bar's three slots: [leading] and [trailing] at their own widths at
/// either edge, and [centre] centred on the WHOLE bar, not on the room
/// between the side groups (#1308).
///
/// The side groups are laid out first and never move for the centre: a
/// message that takes the session name's place (#1562) changes nothing at
/// the edges. The centre gets the bar's full height, so a message can draw
/// its time-left line on the bar's bottom edge, and is at most twice the
/// distance from the centre to the nearer group, less the bar's gap
/// ([SpacingTheme.xl]), so it stays centred whatever the groups' widths and
/// is cut short rather than run under either of them. Only when a group
/// reaches so near the centre that less than [minCentredWidth] is left does
/// the centre fall back to the room between the groups.
///
/// The trailing group gets the room the leading one leaves, less the bar's
/// gap. When it is wider than that room (the Mixer's buttons in a desktop
/// window narrower than the appliance panel), it is scaled down to fit, the
/// way the stage scales the Mixer's strips, rather than overflowing the bar's
/// edge. It is laid out at its own width, unconstrained, so it cannot hold an
/// [Expanded], a [Flexible] or a [Spacer].
///
/// Flutter's `NavigationToolbar` was the obvious candidate and does not fit:
/// a long middle slides off centre towards the roomier side there.
class TopBarLayout extends StatelessWidget {
  /// Creates a [TopBarLayout].
  const new({
    required this.leading,
    required this.centre,
    required this.trailing,
    super.key,
  });

  /// The group at the leading edge.
  final Widget leading;

  /// The centre: the session name, a message, or nothing.
  final Widget centre;

  /// The group at the trailing edge.
  final Widget trailing;

  /// The narrowest centred room the centre is still drawn in; below it the
  /// centre falls back to the room between the groups.
  static const double minCentredWidth = 120;

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    delegate: _CentredLayout(gap: context.spacing.xl),
    children: [
      LayoutId(id: _Slot.leading, child: leading),
      LayoutId(id: _Slot.centre, child: centre),
      LayoutId(
        id: _Slot.trailing,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: trailing,
        ),
      ),
    ],
  );
}

enum _Slot { leading, centre, trailing }

class _CentredLayout extends MultiChildLayoutDelegate {
  new({required this.gap});

  final double gap;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final leading = layoutChild(_Slot.leading, loose);
    final trailing = layoutChild(
      _Slot.trailing,
      // The bar's gap stays between the groups, also when the trailing one
      // has to be scaled down to fit.
      loose.copyWith(maxWidth: math.max(0, size.width - leading.width - gap)),
    );
    positionChild(
      _Slot.leading,
      Offset(0, (size.height - leading.height) / 2),
    );
    positionChild(
      _Slot.trailing,
      Offset(size.width - trailing.width, (size.height - trailing.height) / 2),
    );
    final centre = size.width / 2;
    final centredRoom =
        2 * (math.min(centre - leading.width, centre - trailing.width) - gap);
    if (centredRoom >= TopBarLayout.minCentredWidth) {
      final title = layoutChild(
        _Slot.centre,
        _centreConstraints(centredRoom, size),
      );
      positionChild(_Slot.centre, Offset(centre - title.width / 2, 0));
      return;
    }
    // A side group reaches (nearly) to the centre — the Mixer's extra
    // buttons on the 1024-wide appliance — so no centred room is left: the
    // centre takes the room between the groups instead of vanishing.
    final start = leading.width + gap;
    final room = math.max(0, size.width - trailing.width - gap - start);
    final title = layoutChild(
      _Slot.centre,
      _centreConstraints(room.toDouble(), size),
    );
    positionChild(_Slot.centre, Offset(start + (room - title.width) / 2, 0));
  }

  /// Any width up to [room], and exactly the bar's height.
  static BoxConstraints _centreConstraints(double room, Size size) =>
      BoxConstraints(
        maxWidth: room,
        minHeight: size.height,
        maxHeight: size.height,
      );

  @override
  bool shouldRelayout(_CentredLayout oldDelegate) => oldDelegate.gap != gap;
}
