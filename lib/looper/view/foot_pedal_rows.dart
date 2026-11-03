import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/view/console_pedal_layout.dart';

/// The console's ten pedals as every foot view draws them: the rear pair at
/// the top of the view's frame and the front eight under them, each centred
/// where [ConsolePedalLayout] puts it, so the Pedals page and every foot view
/// draw a pedal in the same place (#1590 FT-4).
///
/// Fills the foot view's frame; `pedal` builds each pedal's face and caption.
class FootPedalRows extends StatelessWidget {
  /// Creates a [FootPedalRows].
  const FootPedalRows({required this.pedal, super.key});

  /// Builds the pedal drawn for a button.
  final Widget Function(PedalButton button) pedal;

  /// Each pedal's column, face and caption: the pen's 180.
  static const double pedalWidth = 180;

  /// Where the rear row starts below the frame's top.
  static const double _rearTop = 56;

  /// Where the front row starts below the frame's top.
  static const double _frontTop = 472;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final centre = constraints.maxWidth / 2;
      Widget place(PedalButton button, double top) => PositionedDirectional(
        start:
            centre + ConsolePedalLayout.centreOffset(button) - pedalWidth / 2,
        top: top,
        width: pedalWidth,
        child: pedal(button),
      );
      return Stack(
        children: [
          for (final button in ConsolePedalLayout.rearRow)
            place(button, _rearTop),
          for (final button in ConsolePedalLayout.frontRow)
            place(button, _frontTop),
        ],
      );
    },
  );
}
