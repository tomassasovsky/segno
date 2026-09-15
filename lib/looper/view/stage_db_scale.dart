import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/theme/theme.dart';

/// The shared dBFS scale drawn on either side of the track run (the accepted
/// stage): one set of marks for all four meters, in place of a per-track
/// numeric level. Its 0 lines up with the top of every column's meter and its
/// -60 with the bottom, so the marks read against the fills directly — the
/// meters are dB-linear over the same span (`peakMeterFill`).
///
/// Decorative for assistive technology: each track's level reaches a screen
/// reader through its own tile.
class StageDbScale extends StatelessWidget {
  /// Creates a [StageDbScale]. [trailing] puts the marks on the run's right
  /// side, left-aligned against the last column.
  const StageDbScale({required this.trailing, super.key});

  /// Whether this scale sits after the run (marks left-aligned) rather than
  /// before it (right-aligned).
  final bool trailing;

  /// The scale's width — the pen's 38.
  static const double width = 38;

  /// The marks, top to bottom, in dBFS.
  static const List<int> marks = [0, -6, -12, -18, -24, -36, -48, -60];

  /// Each mark's line box, so the label centres on its level.
  static const double _labelHeight = 18;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final markStyle = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textMuted,
      fontSize: 18,
      height: 1,
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.only(
            top: TrackColumn.meterTopInset,
            bottom: TrackColumn.meterBottomInset,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final span = constraints.maxHeight;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: -28,
                    left: trailing ? 0 : null,
                    right: trailing ? null : 0,
                    child: AppText(
                      l10n.stageDbUnit,
                      style: markStyle.copyWith(fontSize: 13),
                    ),
                  ),
                  for (final mark in marks)
                    Positioned(
                      top: span * (-mark / 60) - _labelHeight / 2,
                      left: trailing ? 0 : null,
                      right: trailing ? null : 0,
                      child: AppText('$mark', style: markStyle),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
