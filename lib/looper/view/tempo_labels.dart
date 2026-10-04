import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/record_start.dart';

/// What each [ClickMode] is called. One table, both surfaces.
Map<ClickMode, String> clickModeLabels(AppLocalizations l10n) => {
  ClickMode.off: l10n.clickModeOffLabel,
  ClickMode.rec: l10n.clickModeRecLabel,
  ClickMode.recFirst: l10n.clickModeRecFirstLabel,
  ClickMode.playRec: l10n.clickModePlayRecLabel,
};

/// What each count-in length is called, keyed by [kCountInBarOptions].
Map<int, String> countInLabels(AppLocalizations l10n) => {
  0: l10n.countInOffLabel,
  1: l10n.countInBarsLabel1,
  2: l10n.countInBarsLabel2,
  4: l10n.countInBarsLabel4,
};
