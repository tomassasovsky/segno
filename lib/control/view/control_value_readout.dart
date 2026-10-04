import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart'
    show routingPlacementLabel;
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/looper/view/tempo_labels.dart';

/// The unit a saved normalized endpoint represents on its actual control.
/// The same text is used by MIDI and External rows and endpoint editors.
String controlValueReadout(
  AppLocalizations l10n,
  ControlValueTarget target,
  double normalized,
) => switch (target) {
  TrackVolumeTarget() || LaneVolumeTarget() => signalGainReadout(
    (target as MixValueTarget).toDomain(normalized),
  ),
  TrackPanTarget() ||
  InputPanTarget() ||
  PairBalanceTarget() ||
  OutputBalanceTarget() => routingPlacementLabel(
    l10n,
    (target as MixValueTarget).toDomain(normalized),
  ),
  MonitorVolumeTarget() => '${(target.toDomain(normalized) * 100).round()}%',
  OutputLevelTarget() || FxParamTarget() => '${(normalized * 100).round()}%',
  ClickVolumeTarget() => l10n.loopClickVolumeReadout(
    (target.toDomain(normalized) * 100).round(),
  ),
  ClickModeValueTarget() => clickModeReadout(
    l10n,
    target.toDomain(normalized),
  ),
  CountInValueTarget() => countInLabels(l10n)[target.toDomain(normalized)]!,
  DecayValueTarget() => _decayReadout(l10n, target.toDomain(normalized)),
  OneShotValueTarget() =>
    target.toDomain(normalized) ? l10n.loopPlaybackOnce : l10n.loopPlaybackLoop,
  RecordLengthValueTarget() => _lengthReadout(
    l10n,
    target.toDomain(normalized),
  ),
  RecordTimingValueTarget() => recordTimingReadout(
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

/// The four Hear click choices in the same words as the Loop settings row.
String clickModeReadout(AppLocalizations l10n, ClickMode mode) =>
    switch (mode) {
      ClickMode.off => l10n.loopClickOff,
      ClickMode.recFirst => l10n.loopClickFirst,
      ClickMode.rec => l10n.loopClickRecording,
      ClickMode.playRec => l10n.loopClickAlways,
    };

/// The same seven musical choices offered by Loop settings.
String recordTimingReadout(AppLocalizations l10n, RecordTiming timing) =>
    switch (timing) {
      RecordTiming.immediately => l10n.loopTimingImmediately,
      RecordTiming.loopStart => l10n.loopTimingLoopStart,
      RecordTiming.bar => l10n.loopTimingBar,
      RecordTiming.half => l10n.loopTimingHalf,
      RecordTiming.quarter => l10n.loopTimingQuarter,
      RecordTiming.eighth => l10n.loopTimingEighth,
      RecordTiming.sixteenth => l10n.loopTimingSixteenth,
    };
