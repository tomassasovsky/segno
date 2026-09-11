import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// One thing the accepted FX surfaces draw: a rack with its modules, or a
/// standalone single effect.
///
/// The engine's chain is a flat run of entries; the accepted design's chain is
/// a run of RACKS. [fxChainGroups] is the one place that turns the first into
/// the second, so every surface that draws, reorders or removes a chain agrees
/// on where one rack ends and the next begins.
class FxChainGroup extends Equatable {
  /// Creates an [FxChainGroup] spanning `[start, end)` of [chain].
  const FxChainGroup({
    required this.chain,
    required this.start,
    required this.end,
  });

  /// The whole chain this group is part of.
  ///
  /// Carried so a group is enough to compute the transform a surface wants:
  /// moving a rack to the other stage rewrites the chain around it, and an
  /// editor holding only the group would have to be handed the chain again.
  final List<TrackEffect> chain;

  /// The index in [chain] of this group's first entry.
  final int start;

  /// One past the index of this group's last entry.
  final int end;

  /// The group's entries, in processing order. Never empty.
  List<TrackEffect> get entries => chain.sublist(start, end);

  /// The rack these entries make up, or `null` when this group is a single
  /// standalone effect.
  FxRack? get rack => chain[start].rack;

  /// Whether this group is a rack rather than a single effect.
  bool get isRack => rack != null;

  /// The stage every entry in the group sits in.
  ///
  /// A rack never straddles the loop player: the accepted Pre/Post switch
  /// moves a whole instance, so every entry of one rack shares a placement.
  FxPlacement get placement => chain[start].placement;

  /// Whether any entry in the group is audible. A rack whose every module is
  /// bypassed is drawn bypassed.
  bool get anyEnabled {
    for (var i = start; i < end; i++) {
      if (chain[i].enabled) return true;
    }
    return false;
  }

  /// How many entries the group holds.
  int get length => end - start;

  /// The channel handling the accepted design puts around the whole group.
  ///
  /// The engine applies channel handling per entry: the input choice before an
  /// entry's effect, the output choice, level and placement after it. For a
  /// rack that is exactly what the accepted "Rack input / Rack output / Rack
  /// level / Balance" means when it is read around the group — the input of
  /// the FIRST module and the output side of the LAST one. The modules in
  /// between stay at defaults, which is bit-identical to no channel handling
  /// at all, so the rack is transparent between its own pedals.
  FxChannels get channels => FxChannels(
    input: chain[start].channels.input,
    output: chain[end - 1].channels.output,
    placement: chain[end - 1].channels.placement,
    level: chain[end - 1].channels.level,
  );

  @override
  List<Object?> get props => [entries, start];
}

/// Groups [chain] into what the accepted surfaces draw: a run of entries
/// sharing one [FxRack.id] becomes one rack, and an entry with no rack becomes
/// a group of its own.
///
/// Consecutive on purpose. A rack's modules are contiguous by construction —
/// adding one appends them together, reorder moves whole groups, and reorder
/// inside a rack stays inside it — so contiguity is the invariant every chain
/// write preserves rather than something this has to repair.
List<FxChainGroup> fxChainGroups(List<TrackEffect> chain) {
  final groups = <FxChainGroup>[];
  var i = 0;
  while (i < chain.length) {
    final rack = chain[i].rack;
    var j = i + 1;
    if (rack != null) {
      while (j < chain.length && chain[j].rack?.id == rack.id) {
        j++;
      }
    }
    groups.add(FxChainGroup(chain: chain, start: i, end: j));
    i = j;
  }
  return groups;
}

/// A group's stable identity: its rack's id, or its single effect's slot id.
///
/// One function because four surfaces key cards by it — the chain strip, the
/// editor that re-finds its group after every write, and both reorder
/// surfaces — and two of them keying it differently would open the wrong
/// editor after a reorder.
String fxGroupId(FxChainGroup group) =>
    group.rack?.id ?? group.chain[group.start].slotId ?? '${group.start}';

/// Returns [chain] with its groups in the order [ids] names, by [fxGroupId].
///
/// Refuses, returning [chain] unchanged, when [ids] does not name exactly the
/// groups the chain has, or when the order would carry a group across the
/// Pre/Post boundary. A reorder draft is made on a chain the player can still
/// change from a pedal, so committing one that no longer matches would drop or
/// duplicate whatever moved in the meantime.
List<TrackEffect> fxOrderGroups(List<TrackEffect> chain, List<String> ids) {
  final groups = fxChainGroups(chain);
  final byId = {for (final g in groups) fxGroupId(g): g};
  if (byId.length != groups.length) return chain;
  if (ids.length != groups.length || ids.toSet().length != ids.length) {
    return chain;
  }
  if (!ids.every(byId.containsKey)) return chain;
  final ordered = [for (final id in ids) byId[id]!];
  for (var i = 0; i < ordered.length; i++) {
    if (ordered[i].placement != groups[i].placement) return chain;
  }
  return [for (final g in ordered) ...g.entries];
}

/// Returns [chain] with the rack [rackId]'s modules in the order [slotIds]
/// names.
///
/// Refuses, returning [chain] unchanged, when [slotIds] does not name exactly
/// that rack's modules — see [fxOrderGroups] for why.
List<TrackEffect> fxOrderRackModules(
  List<TrackEffect> chain,
  String rackId,
  List<String> slotIds,
) {
  final group = fxChainGroups(
    chain,
  ).where((g) => g.rack?.id == rackId).firstOrNull;
  if (group == null) return chain;
  final modules = group.entries;
  final byId = {for (final fx in modules) fx.slotId ?? '': fx};
  if (byId.length != modules.length || byId.containsKey('')) return chain;
  if (slotIds.length != modules.length ||
      slotIds.toSet().length != slotIds.length ||
      !slotIds.every(byId.containsKey)) {
    return chain;
  }
  return [
    ...chain.sublist(0, group.start),
    for (final id in slotIds) byId[id]!,
    ...chain.sublist(group.end),
  ];
}

/// Returns [chain] with every module of the rack [rackId] renamed to [name].
///
/// The name lives on each entry, so a rename rewrites the run. The rack's
/// [FxRack.id] does not change, which is what keeps a binding that names this
/// rack pointing at it across the rename.
List<TrackEffect> fxRenameRack(
  List<TrackEffect> chain,
  String rackId,
  String name,
) => [
  for (final fx in chain)
    if (fx.rack?.id == rackId)
      _withRack(fx, fx.rack!.copyWith(name: name))
    else
      fx,
];

/// Returns [chain] without the group starting at [start] and ending at [end].
///
/// Removing a rack takes all of its modules; removing one module of a rack
/// leaves the others and the rack itself. Both are the same list splice, which
/// is why there is one function rather than two.
List<TrackEffect> fxRemoveRange(List<TrackEffect> chain, int start, int end) {
  if (start < 0 || end > chain.length || start >= end) return chain;
  return [...chain.sublist(0, start), ...chain.sublist(end)];
}

/// Returns [chain] with the group at [from] moved to position [to], counting
/// in GROUPS rather than entries.
///
/// A move is refused, returning [chain] unchanged, when it would carry a group
/// across the Pre/Post boundary: the accepted design states that reorder moves
/// an effect within its stage, and that the explicit placement switch is what
/// moves it between them.
List<TrackEffect> fxMoveGroup(List<TrackEffect> chain, int from, int to) {
  final groups = fxChainGroups(chain);
  if (from < 0 || from >= groups.length) return chain;
  if (to < 0 || to >= groups.length) return chain;
  if (from == to) return chain;
  if (groups[from].placement != groups[to].placement) return chain;
  final reordered = [...groups];
  reordered.insert(to, reordered.removeAt(from));
  return [for (final g in reordered) ...g.entries];
}

/// Returns [chain] with the module at index [from] of the rack [rackId] moved
/// to index [to] inside that same rack.
///
/// The rack's own position in the chain does not change, and neither does any
/// other group: a module can only move among its own rack's pedals.
List<TrackEffect> fxMoveWithinRack(
  List<TrackEffect> chain,
  String rackId,
  int from,
  int to,
) {
  final group = fxChainGroups(
    chain,
  ).where((g) => g.rack?.id == rackId).firstOrNull;
  if (group == null) return chain;
  final modules = [...group.entries];
  if (from < 0 || from >= modules.length) return chain;
  if (to < 0 || to >= modules.length) return chain;
  if (from == to) return chain;
  modules.insert(to, modules.removeAt(from));
  return [
    ...chain.sublist(0, group.start),
    ...modules,
    ...chain.sublist(group.end),
  ];
}

/// Returns [chain] with the group spanning `[start, end)` carrying [channels]
/// as the accepted design reads them around a whole rack.
///
/// The mirror of [FxChainGroup.channels]: the input choice lands on the first
/// module, the output choice, balance and level on the last, and every module
/// in between is reset to defaults so the rack stays transparent between its
/// own pedals. A one-entry group takes all four, which is exactly what the
/// single-effect editor writes.
List<TrackEffect> fxSetGroupChannels(
  List<TrackEffect> chain,
  int start,
  int end,
  FxChannels channels,
) {
  if (start < 0 || end > chain.length || start >= end) return chain;
  return [
    for (var i = 0; i < chain.length; i++)
      if (i < start || i >= end)
        chain[i]
      else
        _withChannels(
          chain[i],
          FxChannels(
            input: i == start ? channels.input : FxChannelInput.stereo,
            output: i == end - 1 ? channels.output : FxChannelOutput.stereo,
            placement: i == end - 1 ? channels.placement : 0,
            level: i == end - 1 ? channels.level : 1,
          ),
        ),
  ];
}

/// The per-entry channel writes that carry [channels] onto [group], keyed by
/// their index in the whole chain.
///
/// The editing counterpart of [fxSetGroupChannels]: a player moving the rack's
/// Balance touches ONE entry, so the surface issues the one per-entry write the
/// repository already has rather than pushing the whole chain on every frame of
/// a drag. At most two writes — the first module's input side and the last
/// module's output side — and none at all when nothing changed.
///
/// It does not reset the modules in between, because nothing puts anything
/// there: a rack's middle modules are created at defaults and only
/// [fxSetGroupChannels] ever writes them. A test pins the two agreeing.
Map<int, FxChannels> fxGroupChannelWrites(
  FxChainGroup group,
  FxChannels channels,
) {
  final writes = <int, FxChannels>{};
  final first = group.chain[group.start].channels;
  if (first.input != channels.input) {
    writes[group.start] = first.copyWith(input: channels.input);
  }
  final last = group.chain[group.end - 1].channels;
  if (last.output != channels.output ||
      last.placement != channels.placement ||
      last.level != channels.level) {
    writes[group.end - 1] = last.copyWith(
      output: channels.output,
      placement: channels.placement,
      level: channels.level,
    );
  }
  return writes;
}

/// Returns [chain] with every entry of the group spanning `[start, end)` moved
/// to [placement], landing at the END of that stage.
///
/// A rack moves as one thing: the accepted switch is a property of the
/// instance, not of a module inside it, so leaving half a rack behind would
/// split it across the loop player.
///
/// To the stage's END, in the accepted design's own words, rather than staying
/// where it stood: reorder is what arranges a stage, and a switch that dropped
/// an instance into the middle of the other stage would be reordering it too.
/// Identity, channels and parameters ride along untouched.
List<TrackEffect> fxSetGroupPlacement(
  List<TrackEffect> chain,
  int start,
  int end,
  FxPlacement placement,
) {
  if (start < 0 || end > chain.length || start >= end) return chain;
  final moved = [
    for (var i = start; i < end; i++) _withPlacement(chain[i], placement),
  ];
  final rest = [...chain.sublist(0, start), ...chain.sublist(end)];
  final same = [
    for (final fx in rest)
      if (fx.placement == placement) fx,
  ];
  final other = [
    for (final fx in rest)
      if (fx.placement != placement) fx,
  ];
  return placement == FxPlacement.pre
      ? [...same, ...moved, ...other]
      : [...other, ...same, ...moved];
}

TrackEffect _withRack(TrackEffect fx, FxRack rack) => switch (fx) {
  BuiltInEffect() => fx.copyWith(rack: rack),
  PluginEffect() => fx.copyWith(rack: rack),
};

TrackEffect _withChannels(TrackEffect fx, FxChannels channels) => switch (fx) {
  BuiltInEffect() => fx.copyWith(channels: channels),
  PluginEffect() => fx.copyWith(channels: channels),
};

TrackEffect _withPlacement(TrackEffect fx, FxPlacement placement) =>
    switch (fx) {
      BuiltInEffect() => fx.copyWith(placement: placement),
      PluginEffect() => fx.copyWith(placement: placement),
    };
