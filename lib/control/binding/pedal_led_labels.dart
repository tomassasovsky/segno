import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/l10n/l10n.dart';

/// What the LED editor calls [state].
String pedalLedStateLabel(AppLocalizations l10n, PedalLedState state) =>
    switch (state) {
      PedalLedState.recording => l10n.pedalLedStateRecording,
      PedalLedState.overdubbing => l10n.pedalLedStateOverdubbing,
      PedalLedState.playing => l10n.pedalLedStatePlaying,
      PedalLedState.selected => l10n.pedalLedStateSelected,
      PedalLedState.armed => l10n.pedalLedStateArmed,
      PedalLedState.engaged => l10n.pedalLedStateEngaged,
      PedalLedState.fading => l10n.pedalLedStateFading,
      PedalLedState.reversed => l10n.pedalLedStateReversed,
      PedalLedState.peelable => l10n.pedalLedStatePeelable,
      PedalLedState.tuned => l10n.pedalLedStateTuned,
      PedalLedState.muted => l10n.pedalLedStateMuted,
      PedalLedState.idle => l10n.pedalLedStateIdle,
      PedalLedState.current => l10n.pedalLedStateCurrent,
      PedalLedState.laterBank => l10n.pedalLedStateLaterBank,
      PedalLedState.lit => l10n.pedalLedStateLit,
      PedalLedState.pressed => l10n.pedalLedStatePressed,
    };

/// What the LED editor calls [group]: the track pedals as one, every other
/// group by its pedal.
String pedalLedGroupLabel(AppLocalizations l10n, PedalLedGroup group) =>
    switch (group) {
      PedalLedGroup.tracks => l10n.pedalSetupTrackGroup,
      PedalLedGroup.recPlay => pedalButtonLegend(PedalButton.recPlay),
      PedalLedGroup.stop => pedalButtonLegend(PedalButton.stop),
      PedalLedGroup.undo => pedalButtonLegend(PedalButton.undo),
      PedalLedGroup.clear => pedalButtonLegend(PedalButton.clear),
      PedalLedGroup.mode => pedalButtonLegend(PedalButton.mode),
      PedalLedGroup.bank => pedalButtonLegend(PedalButton.bank),
    };
