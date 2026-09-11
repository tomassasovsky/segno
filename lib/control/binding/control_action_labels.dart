import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// How the shared catalogue is NAMED, in one place.
///
/// Pure functions of the action and the localizations, so the picker row, the
/// assigned-value field and the Semantics announcement all say the same words.
/// Three spellings of one action would read as three different assignments.
///
/// [trackNames] is the rig's own naming, threaded in so a fixed-track action
/// reads `drums · Clear` rather than `Track 1 · Clear` (#526).
String controlActionLabel(
  AppLocalizations l10n,
  List<String> trackNames,
  ControlAction action,
) => switch (action) {
  ModeAction(:final mode) => _modeLabel(l10n, mode),
  CommandAction(:final command) => _commandLabel(l10n, command),
  TrackPedalAction(:final channel) => l10n.actionTrackPedal(
    l10n.trackName(trackNames, channel),
  ),
  SelectTrackAction(:final channel) => l10n.actionSelectTrack(
    l10n.trackName(trackNames, channel),
  ),
  TrackOperationAction(:final operation, :final scope) => l10n.actionScoped(
    _scopeLabel(l10n, trackNames, scope),
    _operationLabel(l10n, operation),
  ),
};

/// What an unassigned gesture reads as.
String controlActionNone(AppLocalizations l10n) => l10n.actionNone;

/// The heading [group] is listed under.
String controlActionGroupLabel(
  AppLocalizations l10n,
  ControlActionGroup group,
) => switch (group) {
  ControlActionGroup.functions => l10n.actionGroupFunctions,
  ControlActionGroup.transport => l10n.actionGroupTransport,
  ControlActionGroup.loopModes => l10n.actionGroupLoopModes,
  ControlActionGroup.selected => l10n.actionGroupSelected,
  ControlActionGroup.fixed => l10n.actionGroupFixed,
  ControlActionGroup.allTracks => l10n.actionGroupAllTracks,
  ControlActionGroup.tracks => l10n.actionGroupTracks,
  ControlActionGroup.fx => l10n.actionGroupFx,
  ControlActionGroup.backing => l10n.actionGroupBacking,
  ControlActionGroup.sessions => l10n.actionGroupSessions,
};

/// What a Record / Play hold reads as.
String recordHoldLabel(AppLocalizations l10n, RecordHold hold) =>
    switch (hold) {
      RecordHold.none => l10n.actionNone,
      RecordHold.undoRecording => l10n.actionUndoRecording,
    };

/// What a track-switch hold reads as.
String trackHoldLabel(AppLocalizations l10n, TrackHold hold) => switch (hold) {
  TrackHold.none => l10n.actionNone,
  TrackHold.armOverdub => l10n.actionArmOverdub,
  TrackHold.clearTrack => l10n.actionClearTrack,
};

String _modeLabel(AppLocalizations l10n, InteractionMode mode) =>
    switch (mode) {
      // Not "Tracks": on a switch, the mode every other mode returns to is
      // the way OUT of wherever the foot is, and the accepted catalogue names
      // it for what the stomp does rather than for where it lands.
      InteractionMode.record => l10n.actionModeExit,
      InteractionMode.mute => l10n.actionModeMute,
      InteractionMode.fx => l10n.actionModeFx,
    };

String _commandLabel(AppLocalizations l10n, ControlCommand command) =>
    switch (command) {
      ControlCommand.recordPlay => l10n.actionRecordPlay,
      ControlCommand.stop => l10n.actionStop,
      ControlCommand.undo => l10n.actionUndo,
      ControlCommand.redo => l10n.actionRedo,
      ControlCommand.clearAll => l10n.actionClearAll,
      ControlCommand.cutSound => l10n.actionCutSound,
      ControlCommand.recordPerformance => l10n.actionRecordPerformance,
      ControlCommand.nextBank => l10n.actionNextBank,
    };

String _operationLabel(AppLocalizations l10n, TrackOperation operation) =>
    switch (operation) {
      TrackOperation.mute => l10n.actionOperationMute,
      TrackOperation.solo => l10n.actionOperationSolo,
      TrackOperation.clear => l10n.actionOperationClear,
      TrackOperation.undo => l10n.actionOperationUndo,
      TrackOperation.redo => l10n.actionOperationRedo,
    };

String _scopeLabel(
  AppLocalizations l10n,
  List<String> trackNames,
  ActionScope scope,
) => switch (scope) {
  SelectedTrackScope() => l10n.actionScopeSelected,
  AllTracksScope() => l10n.actionScopeAllTracks,
  FixedTrackScope(:final channel) => l10n.trackName(trackNames, channel),
};
