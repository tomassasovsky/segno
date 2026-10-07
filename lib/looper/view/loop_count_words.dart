import 'package:segno/l10n/l10n.dart';

/// How a track's length reads on the stage: the figure, its small unit and
/// the spoken form. Whole bars when the grid counts them; else whole beats,
/// which a Divide of a sole 1- or 3-bar loop leaves (2 or 6 beats, #1168);
/// else no counted length.
({String figure, String unit, String spoken}) loopCountWords(
  AppLocalizations l10n, {
  required int? bars,
  required int? beats,
}) {
  if (bars != null) {
    return (
      figure: '$bars',
      unit: l10n.stageBarsUnit(bars),
      spoken: l10n.stageBarsFigure(bars),
    );
  }
  if (beats != null) {
    return (
      figure: '$beats',
      unit: l10n.stageBeatsUnit(beats),
      spoken: l10n.stageBeatsFigure(beats),
    );
  }
  return (
    figure: l10n.stageNoBars,
    unit: l10n.stageBarsUnit(0),
    spoken: l10n.stageNoBarsFigure,
  );
}
