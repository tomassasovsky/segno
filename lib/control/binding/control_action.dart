/// The SHARED action catalogue: everything a control surface can be asked to
/// do, named once.
///
/// One vocabulary, three pickers. The built-in footswitch setup, the external
/// pedal setup and MIDI Learn all list the same entries, so a performer who
/// learns "Selected track · Mute" on the plate finds the same words — and the
/// same behaviour — on a jack and on a controller. The alternative, a picker
/// per surface, is how three surfaces end up meaning three different things by
/// one label.
///
/// ## What is in it, and what is not yet
///
/// The catalogue lists what the rig can actually DO. An entry whose operation
/// has no implementation would be a control that reads as assigned and stomps
/// as nothing, which is worse than an absent one — so the eight performance
/// operations with no engine behind them (Reverse, Speed, Fade, Transpose,
/// Multiply, Divide, Bounce and the foot Mixer) are absent here, and the part
/// that builds each one adds its entries with it. [ControlActionGroup] carries
/// the accepted headings, including the ones no entry sits under yet, so a
/// later part adds actions rather than re-deciding the shape of the picker.
///
/// ## Identity
///
/// [ControlAction.key] is the stable, byte-exact string a binding stores —
/// never a label. Renaming what a picker row SAYS can never re-point an
/// assignment, and a key that no longer parses reads as a broken assignment
/// (which the surface offers to change or remove) rather than silently
/// binding to whatever now carries that name.
library;

import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// The heading a catalogue entry is listed under.
///
/// The accepted grouping, in the accepted order. Groups with no entries yet
/// are listed anyway — their parts fill them — and a picker simply skips an
/// empty one.
enum ControlActionGroup {
  /// Modes and whole-rig functions.
  functions,

  /// Loop transport commands.
  transport,

  /// Whole loop modes (Multi, Sync, Song, Band, Free). Empty until the part
  /// that makes loop-mode changes safe from a footswitch.
  loopModes,

  /// Operations on whatever track is selected when the control fires.
  selected,

  /// Operations on one named track, whatever is selected.
  fixed,

  /// Operations on all eight tracks at once.
  allTracks,

  /// The track pedals themselves, and the bank.
  tracks,

  /// The eight FX pedal assignments. Empty until the FX-slot model lands;
  /// FX activation is assigned on its own surface today.
  fx,

  /// Backing-track playback. Empty until the audio library part.
  backing,

  /// Session recall and save. Empty until the session part.
  sessions,
}

/// Which track a catalogue action acts on.
///
/// Resolved ONCE, at dispatch. A [SelectedTrackScope] action fires on whatever
/// the cursor holds at the moment the foot commits, and a [FixedTrackScope]
/// one never follows the bank — "Track 3 · Clear" means track 3 from either
/// bank, which is the whole point of naming it.
sealed class ActionScope extends Equatable {
  const ActionScope();

  /// Parses a scope [token] back, or `null` when it names nothing.
  static ActionScope? tryParse(String token) {
    if (token == 'selected') return const SelectedTrackScope();
    if (token == 'all') return const AllTracksScope();
    final channel = int.tryParse(token);
    if (channel == null) return null;
    if (channel < 0 || channel >= PedalStateFrame.trackCount) return null;
    return FixedTrackScope(channel);
  }

  /// The key fragment this scope contributes.
  String get token;

  /// The group an operation with this scope is listed under.
  ControlActionGroup get group;
}

/// Whatever track is selected when the action fires.
final class SelectedTrackScope extends ActionScope {
  /// Creates a [SelectedTrackScope].
  const SelectedTrackScope();

  @override
  String get token => 'selected';

  @override
  ControlActionGroup get group => ControlActionGroup.selected;

  @override
  List<Object?> get props => const [];
}

/// All eight tracks, in one edit.
final class AllTracksScope extends ActionScope {
  /// Creates an [AllTracksScope].
  const AllTracksScope();

  @override
  String get token => 'all';

  @override
  ControlActionGroup get group => ControlActionGroup.allTracks;

  @override
  List<Object?> get props => const [];
}

/// One named track, independent of the bank and of the selection.
final class FixedTrackScope extends ActionScope {
  /// Creates a [FixedTrackScope] on [channel] (zero-based).
  const FixedTrackScope(this.channel);

  /// The track this scope names.
  final int channel;

  @override
  String get token => '$channel';

  @override
  ControlActionGroup get group => ControlActionGroup.fixed;

  @override
  List<Object?> get props => [channel];
}

/// The per-track operations a control can drive directly, without entering a
/// mode first.
enum TrackOperation {
  /// Mute or unmute the track.
  mute('mute'),

  /// Solo or unsolo the track.
  solo('solo'),

  /// Erase the track's audio (recoverable through the clear restore point).
  clear('clear'),

  /// Undo the track's latest audio edit.
  undo('undo'),

  /// Redo the track's latest undone audio edit.
  redo('redo');

  const TrackOperation(this.token);

  /// The key fragment this operation contributes.
  final String token;

  /// Parses a [token] back to an operation, or `null`.
  static TrackOperation? fromToken(String token) {
    for (final value in values) {
      if (value.token == token) return value;
    }
    return null;
  }

  /// Whether this operation may be applied to every track at once.
  ///
  /// Clear may not: erasing the whole rig is [ControlCommand.clearAll], ONE
  /// grouped edit with one undo, and eight separate clears would leave eight
  /// undo steps behind a single stomp.
  bool get allowsAllTracks => this != TrackOperation.clear;
}

/// The whole-rig commands a control can drive.
enum ControlCommand {
  /// The Record / Play transport action for the current mode.
  recordPlay('command:record-play'),

  /// The Stop action for the current mode.
  stop('command:stop'),

  /// Undo the latest audio edit on the selected track.
  undo('command:undo'),

  /// Redo the latest undone audio edit on the selected track.
  redo('command:redo'),

  /// Clear every track, as one grouped edit with one undo.
  clearAll('command:clear-all'),

  /// Stop tracks and backing and end existing effect tails.
  cutSound('command:cut-sound'),

  /// Arm or finish a performance recording.
  recordPerformance('command:record-performance'),

  /// Switch the track bank A / B.
  nextBank('bank:next');

  const ControlCommand(this.key);

  /// The whole key for this command. Spelled out per member rather than
  /// derived from the member name, because the accepted catalogue does not
  /// prefix the bank with `command:` and a vocabulary shared across three
  /// surfaces has to match it exactly.
  final String key;

  /// Parses a [key] back to a command, or `null`.
  static ControlCommand? fromKey(String key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return null;
  }
}

/// One entry in the catalogue: something a control can be assigned to do.
sealed class ControlAction extends Equatable {
  /// Creates a [ControlAction].
  const ControlAction();

  /// Parses a stored [key] back to an action, or `null` when it names
  /// nothing this build can do.
  ///
  /// Never throws. Assignments cross app restarts, session bundles and USB
  /// backups as bare strings, so a key from a newer build — or a hand-edited
  /// one — degrades to an assignment the surface shows as broken, never to a
  /// crash and never to a different action that happens to sort nearby.
  static ControlAction? tryParse(String key) {
    final command = ControlCommand.fromKey(key);
    if (command != null) return CommandAction(command);
    final parts = key.split(':');
    if (parts.length < 2) return null;
    switch (parts.first) {
      case 'mode':
        if (parts.length != 2) return null;
        final mode = _modeFromToken(parts[1]);
        return mode == null ? null : ModeAction(mode);
      case 'track':
        if (parts.length != 2) return null;
        final channel = _channel(parts[1]);
        return channel == null ? null : TrackPedalAction(channel);
      case 'select-track':
        if (parts.length != 2) return null;
        final channel = _channel(parts[1]);
        return channel == null ? null : SelectTrackAction(channel);
      case 'direct':
        if (parts.length != 3) return null;
        final operation = TrackOperation.fromToken(parts[1]);
        if (operation == null) return null;
        final scope = ActionScope.tryParse(parts[2]);
        if (scope == null) return null;
        // The same rule the catalogue is built under, enforced on the way in
        // too: a stored `direct:clear:all` is not a clear-all by another
        // name, it is a key no build ever wrote.
        if (scope is AllTracksScope && !operation.allowsAllTracks) return null;
        return TrackOperationAction(operation: operation, scope: scope);
      default:
        return null;
    }
  }

  /// The stable key this action stores as (see the library doc).
  String get key;

  /// The heading this action is listed under.
  ControlActionGroup get group;

  static int? _channel(String token) {
    final channel = int.tryParse(token);
    if (channel == null) return null;
    if (channel < 0 || channel >= PedalStateFrame.trackCount) return null;
    return channel;
  }

  static InteractionMode? _modeFromToken(String token) {
    for (final mode in InteractionMode.values) {
      if (ModeAction(mode).token == token) return mode;
    }
    return null;
  }
}

/// Enters an interaction mode, or returns to Tracks when the rig is already
/// in it.
///
/// One action rather than an enter/leave pair, because a foot has one switch:
/// the accepted design's `Exit` IS `mode:tracks`, and every other mode action
/// doubles as its own way out. Nothing here can strand the performer in a
/// mode whose door they cannot find, which is the failure this shape exists
/// to prevent.
final class ModeAction extends ControlAction {
  /// Creates a [ModeAction] entering [mode].
  const ModeAction(this.mode);

  /// The mode this action enters.
  final InteractionMode mode;

  /// The key fragment [mode] contributes.
  ///
  /// Deliberately NOT [InteractionMode.token]: the persisted mode token is
  /// `record` for the mode the accepted catalogue calls `tracks`, and the two
  /// strings answer different questions — one is what a settings file stores,
  /// the other is what three assignment surfaces share.
  String get token => switch (mode) {
    InteractionMode.record => 'tracks',
    InteractionMode.mute => 'mute',
    InteractionMode.fx => 'fx',
    InteractionMode.custom => 'custom',
  };

  @override
  String get key => 'mode:$token';

  @override
  ControlActionGroup get group => ControlActionGroup.functions;

  @override
  List<Object?> get props => [mode];
}

/// Runs a whole-rig command.
final class CommandAction extends ControlAction {
  /// Creates a [CommandAction] running [command].
  const CommandAction(this.command);

  /// The command this action runs.
  final ControlCommand command;

  @override
  String get key => command.key;

  @override
  ControlActionGroup get group => switch (command) {
    ControlCommand.nextBank => ControlActionGroup.tracks,
    _ => ControlActionGroup.transport,
  };

  @override
  List<Object?> get props => [command];
}

/// Selects a track and advances its Record / Play — what a track footswitch
/// does, available to any control.
final class TrackPedalAction extends ControlAction {
  /// Creates a [TrackPedalAction] on [channel].
  const TrackPedalAction(this.channel);

  /// The track this action drives.
  final int channel;

  @override
  String get key => 'track:$channel';

  @override
  ControlActionGroup get group => ControlActionGroup.tracks;

  @override
  List<Object?> get props => [channel];
}

/// Selects a track and does nothing else.
///
/// A separate named action from [TrackPedalAction] by the accepted design,
/// and not a variant of it: a control that only moves the cursor is what a
/// performer reaches for when the next stomp must land somewhere specific,
/// and one that also starts recording is the opposite of that.
final class SelectTrackAction extends ControlAction {
  /// Creates a [SelectTrackAction] on [channel].
  const SelectTrackAction(this.channel);

  /// The track this action selects.
  final int channel;

  @override
  String get key => 'select-track:$channel';

  @override
  ControlActionGroup get group => ControlActionGroup.tracks;

  @override
  List<Object?> get props => [channel];
}

/// Runs one per-track operation on one scope.
final class TrackOperationAction extends ControlAction {
  /// Creates a [TrackOperationAction].
  const TrackOperationAction({required this.operation, required this.scope});

  /// What to do.
  final TrackOperation operation;

  /// Which track (or tracks) to do it to.
  final ActionScope scope;

  @override
  String get key => 'direct:${operation.token}:${scope.token}';

  @override
  ControlActionGroup get group => scope.group;

  @override
  List<Object?> get props => [operation, scope];
}

/// The whole catalogue, in picker order.
///
/// Built rather than hand-listed, so a track count or an operation added in
/// one place reaches every surface. The order within a group is the accepted
/// one: modes first, then the commands, then the per-track operations by
/// scope, then the track pedals themselves.
List<ControlAction> controlActionCatalogue() => [
  for (final mode in InteractionMode.values) ModeAction(mode),
  for (final command in ControlCommand.values) CommandAction(command),
  for (final scope in _scopes())
    for (final operation in TrackOperation.values)
      if (scope is! AllTracksScope || operation.allowsAllTracks)
        TrackOperationAction(operation: operation, scope: scope),
  for (var channel = 0; channel < PedalStateFrame.trackCount; channel++) ...[
    TrackPedalAction(channel),
    SelectTrackAction(channel),
  ],
];

/// Every action in [group], in catalogue order.
List<ControlAction> controlActionsIn(ControlActionGroup group) =>
    controlActionCatalogue().where((a) => a.group == group).toList();

/// The groups that actually have entries, in catalogue order — what a picker
/// draws its headings from.
List<ControlActionGroup> controlActionGroups() {
  final present = {for (final action in controlActionCatalogue()) action.group};
  return [
    for (final group in ControlActionGroup.values)
      if (present.contains(group)) group,
  ];
}

List<ActionScope> _scopes() => [
  const SelectedTrackScope(),
  const AllTracksScope(),
  for (var channel = 0; channel < PedalStateFrame.trackCount; channel++)
    FixedTrackScope(channel),
];
