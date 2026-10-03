import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/record_length.dart';
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
  ClickVolumeTarget() => l10n.loopClickVolumeReadout(
    (target.toDomain(normalized) * 100).round(),
  ),
  DecayValueTarget() => _decayReadout(l10n, target.toDomain(normalized)),
  OneShotValueTarget() =>
    target.toDomain(normalized) ? l10n.loopPlaybackOnce : l10n.loopPlaybackLoop,
  RecordLengthValueTarget() => _lengthReadout(
    l10n,
    target.toDomain(normalized),
  ),
  MasterGainTarget() => signalGainReadout(normalized),
};

String _decayReadout(AppLocalizations l10n, int percent) => percent == 0
    ? '${l10n.loopDecayOff} · ${l10n.loopDecayKeep}'
    : l10n.loopDecayPercent(percent);

String _lengthReadout(AppLocalizations l10n, int bars) =>
    bars == 0 ? l10n.loopLengthAuto : l10n.lengthPresetBars(bars);

/// Why an initialized Record length target cannot accept a new edit now.
String? recordLengthDisabledReason(
  AppLocalizations l10n,
  ControlValueTarget target,
  RecordLengthSnapshot? snapshot,
) {
  if (target is! RecordLengthValueTarget || snapshot == null) return null;
  if (snapshot.canEdit(target.address)) return null;
  return snapshot.captureLocked
      ? l10n.recordLengthCaptureLocked
      : l10n.recordLengthSharedInMulti;
}
