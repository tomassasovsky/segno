import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart'
    show routingPlacementLabel;
import 'package:segno/looper/view/signal_graph/signal_style.dart';

/// The unit a saved normalized endpoint represents on its actual control.
/// The same text is used by MIDI and External rows and endpoint editors.
String controlValueReadout(
  AppLocalizations l10n,
  ControlValueTarget target,
  double normalized,
) => switch (target) {
  TrackVolumeTarget() || LaneVolumeTarget() || MonitorVolumeTarget() =>
    signalGainReadout((target as MixValueTarget).toDomain(normalized)),
  TrackPanTarget() ||
  InputPanTarget() ||
  PairBalanceTarget() ||
  OutputBalanceTarget() => routingPlacementLabel(
    l10n,
    (target as MixValueTarget).toDomain(normalized),
  ),
  OutputLevelTarget() || FxParamTarget() => '${(normalized * 100).round()}%',
  MasterGainTarget() => signalGainReadout(normalized),
};
