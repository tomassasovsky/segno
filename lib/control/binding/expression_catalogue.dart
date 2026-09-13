import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';

/// What an expression pedal can be pointed at, organized the way the accepted
/// screen asks for it: pick a destination, then a control on it.
///
/// The targets themselves are part 4b's [ControlValueTarget]s, unchanged and
/// read straight from the live rig — this adds only the grouping and the names,
/// which the flat MIDI-learn list did not need and this screen does.
///
/// The kinds are [FxDestinationKind], not a fourth spelling of the same three
/// words: the Effects page, the routing page and this one all say Live inputs /
/// Recorded tracks / Outputs, and they have to mean the same thing.

/// One control a destination offers.
class ExpressionControl extends Equatable {
  /// Creates an [ExpressionControl].
  const ExpressionControl({required this.target, required this.label});

  /// What it writes.
  final ControlValueTarget target;

  /// Its name within its group — the parameter, not the chain around it.
  final String label;

  @override
  List<Object?> get props => [target, label];
}

/// A heading and the controls under it: one effect's parameters, or the
/// destination's own.
class ExpressionControlGroup extends Equatable {
  /// Creates an [ExpressionControlGroup].
  const ExpressionControlGroup({required this.label, required this.controls});

  /// The heading.
  final String label;

  /// The controls, in the order the rig reports them.
  final List<ExpressionControl> controls;

  @override
  List<Object?> get props => [label, controls];
}

/// One effect a destination offers to turn on and off.
class ExpressionActivation extends Equatable {
  /// Creates an [ExpressionActivation].
  const ExpressionActivation({required this.target, required this.label});

  /// The chain or the effect.
  final FxBindingTarget target;

  /// Its name within the destination.
  final String label;

  @override
  List<Object?> get props => [target, label];
}

/// One place a pedal can reach, and everything it offers there.
class ExpressionDestination extends Equatable {
  /// Creates an [ExpressionDestination].
  const ExpressionDestination({
    required this.id,
    required this.kind,
    required this.label,
    required this.groups,
    this.activations = const [],
  });

  /// A stable key for the screen to remember which destination is open. Not
  /// persisted: a mapping stores its target, which is identity enough.
  final String id;

  /// Which tab of the picker this sits under.
  final FxDestinationKind kind;

  /// What the destination row says.
  final String label;

  /// Its controls, grouped under their headings.
  final List<ExpressionControlGroup> groups;

  /// The effects here a button can turn on and off: the whole chain first,
  /// then each effect in it. Empty unless the catalogue was asked for them —
  /// an expression pedal sweeps values and has nothing to switch.
  final List<ExpressionActivation> activations;

  /// Every control here, flattened.
  Iterable<ExpressionControl> get controls =>
      groups.expand((group) => group.controls);

  @override
  List<Object?> get props => [id, kind, label, groups, activations];
}

/// Names [target] in the three pieces the screen needs: the destination it
/// lives on, the group within that destination, and the control itself.
///
/// Three rather than one string because the screen shows different pairs of
/// them in different places — a picker already inside one effect's section
/// needs only the parameter, a mapping row needs the destination over the rest.
/// [expressionRowName] composes the row's half.
///
/// Derived from the target alone wherever it can be, so a mapping whose effect
/// has been removed still says where it pointed. Only the group and the control
/// need the live rig, and both fall back to what the mapping itself holds — the
/// slot id and the parameter's index. A row that went blank would be worse than
/// one naming a number.
({String destination, String group, String control}) expressionTargetName(
  AppLocalizations l10n,
  List<String> trackNames,
  LooperRepository looper,
  ControlValueTarget target,
) => switch (target) {
  TrackVolumeTarget(:final channel) => (
    destination: l10n.trackName(trackNames, channel),
    group: l10n.trackName(trackNames, channel),
    control: l10n.expressionControlVolume,
  ),
  MasterGainTarget() => (
    destination: l10n.fxEditorMasterTitle,
    group: l10n.fxEditorMasterTitle,
    control: l10n.expressionControlGain,
  ),
  FxParamTarget(:final address, :final slotId, :final param) => (
    destination: fxStageLabel(l10n, trackNames, address),
    group:
        fxSlotName(looper, FxSlotTarget(address: address, slotId: slotId)) ??
        slotId,
    control: fxParamName(looper, target) ?? '#$param',
  ),
};

/// What a mapping row says under its destination: the control, with the group
/// in front of it when the group is something other than the destination
/// itself.
String expressionRowName(
  AppLocalizations l10n,
  List<String> trackNames,
  LooperRepository looper,
  ControlValueTarget target,
) {
  final name = expressionTargetName(l10n, trackNames, looper, target);
  return name.group == name.destination
      ? name.control
      : '${name.group} · ${name.control}';
}

/// Every destination the live rig offers, in reading order within each kind.
///
/// A track's own fader and the effects on its whole-track chain are ONE
/// destination, because they are one thing to the performer — the rig reports
/// them from different places, which is not a reason to ask for the track
/// twice.
///
/// [withActivations] adds each destination's effects as things to turn on and
/// off, which is what an external BUTTON can do and an expression pedal cannot.
/// A destination whose chain offers only activations — a hosted plugin has no
/// continuous parameters here — exists only when they are asked for.
List<ExpressionDestination> expressionDestinations(
  AppLocalizations l10n,
  List<String> trackNames,
  LooperRepository looper, {
  bool withActivations = false,
}) {
  final drafts = <String, _Draft>{};
  _Draft draftFor(
    ({String id, FxDestinationKind kind, int order}) place,
    String label,
  ) => drafts.putIfAbsent(
    place.id,
    () => _Draft(
      id: place.id,
      kind: place.kind,
      order: place.order,
      label: label,
    ),
  );

  for (final target in looper.availableValueTargets()) {
    final place = _placeOf(target);
    if (place == null) continue;
    final names = expressionTargetName(l10n, trackNames, looper, target);
    draftFor(place, names.destination).groups
        .putIfAbsent(names.group, () => [])
        .add(ExpressionControl(target: target, label: names.control));
  }
  if (withActivations) {
    for (final target in looper.availableBindingTargets()) {
      final place = _placeOfAddress(target.address);
      if (place == null) continue;
      draftFor(
        place,
        _addressLabel(l10n, trackNames, target.address),
      ).activations.add(
        ExpressionActivation(
          target: target,
          label: expressionActivationName(l10n, looper, target),
        ),
      );
    }
  }
  final ordered = drafts.values.toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  return [
    for (final draft in ordered)
      ExpressionDestination(
        id: draft.id,
        kind: draft.kind,
        label: draft.label,
        groups: [
          for (final entry in draft.groups.entries)
            ExpressionControlGroup(label: entry.key, controls: entry.value),
        ],
        activations: draft.activations,
      ),
  ];
}

/// Names an activation within its destination: the effect's own name, or the
/// whole chain.
String expressionActivationName(
  AppLocalizations l10n,
  LooperRepository looper,
  FxBindingTarget target,
) => switch (target) {
  FxChainTarget() => l10n.externalActivationChain,
  final FxSlotTarget slot => fxSlotName(looper, slot) ?? slot.slotId,
};

/// The destination's label for [address], the way [expressionTargetName] names
/// it for a parameter on the same chain — so a track reached through its chain
/// and through its fader reads as one place.
String _addressLabel(
  AppLocalizations l10n,
  List<String> trackNames,
  FxAddress address,
) => fxStageLabel(l10n, trackNames, address);

/// Where [target] belongs, or `null` for a target no destination covers.
({String id, FxDestinationKind kind, int order})? _placeOf(
  ControlValueTarget target,
) => switch (target) {
  TrackVolumeTarget(:final channel) => _trackPlace(channel),
  MasterGainTarget() => (
    id: 'master',
    kind: FxDestinationKind.output,
    order: _masterOrder,
  ),
  FxParamTarget(:final address) => _placeOfAddress(address),
};

// The bands keep the kinds apart and leave room inside each one, so a track
// sorts next to its own lanes however the rig happened to report them.
const int _inputOrder = 100000;
const int _recordedOrder = 200000;
const int _allTracksOrder = 290000;
const int _outputOrder = 300000;
const int _masterOrder = 390000;

({String id, FxDestinationKind kind, int order}) _trackPlace(int channel) => (
  id: 'track:$channel',
  kind: FxDestinationKind.recordedTrack,
  order: _recordedOrder + channel * 100,
);

/// Where a chain at [address] belongs, or `null` when it names no chain.
({String id, FxDestinationKind kind, int order})? _placeOfAddress(
  FxAddress address,
) => switch (address) {
  FxAddress(stage: FxStage.input, :final index) => (
    id: 'input:$index',
    kind: FxDestinationKind.liveInput,
    order: _inputOrder + index,
  ),
  FxAddress(stage: FxStage.track, :final index) => _trackPlace(index),
  FxAddress(stage: FxStage.loop, :final index, lane: final lane?) => (
    id: 'loop:$index:$lane',
    kind: FxDestinationKind.recordedTrack,
    // Straight after the track it is a part of, in lane order.
    order: _recordedOrder + index * 100 + lane + 1,
  ),
  FxAddress(stage: FxStage.allTracks) => (
    id: 'allTracks',
    kind: FxDestinationKind.recordedTrack,
    order: _allTracksOrder,
  ),
  FxAddress(stage: FxStage.output, :final index) => (
    id: 'output:$index',
    kind: FxDestinationKind.output,
    order: _outputOrder + index,
  ),
  // A Loop address with no lane names no chain, so it offers nothing — the
  // same nothing the resolvers write to it.
  FxAddress(stage: FxStage.loop) => null,
};

/// One destination under construction: a map keyed by heading, so groups keep
/// the order their first control arrived in.
class _Draft {
  _Draft({
    required this.id,
    required this.kind,
    required this.order,
    required this.label,
  });

  final String id;
  final FxDestinationKind kind;
  final int order;
  final String label;
  final Map<String, List<ExpressionControl>> groups = {};
  final List<ExpressionActivation> activations = [];
}

/// What the picker's tab says for [kind] — the Effects page's own words.
String expressionKindLabel(AppLocalizations l10n, FxDestinationKind kind) =>
    switch (kind) {
      FxDestinationKind.liveInput => l10n.fxKindLiveInputs,
      FxDestinationKind.recordedTrack => l10n.fxKindRecordedTracks,
      FxDestinationKind.output => l10n.fxKindOutputs,
    };
