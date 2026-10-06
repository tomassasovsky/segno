import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/model/fx_library_choice.dart';
import 'package:settings_repository/settings_repository.dart';

part 'fx_state.dart';

/// Result of a route-owned FX edit after native admission and persistence.
enum FxEditStatus {
  /// The edit was accepted and saved.
  applied,

  /// The requested order or value was already current.
  unchanged,

  /// The target or native admission refused the edit.
  refused,

  /// The route, selection or engine life changed before completion.
  stale,

  /// Audio accepted the edit, but durable storage still needs a retry.
  unsaved,
}

/// A chain edit's outcome, including the stable identity of an added group.
final class FxEditResult {
  /// Creates an [FxEditResult].
  const FxEditResult(this.status, {this.groupId});

  /// The outcome of the edit.
  final FxEditStatus status;

  /// New group identity when this was an addition.
  final String? groupId;
}

/// Where the Effects page is pointed, and what each strip remembers.
///
/// Keeps the route's selection and owns its FX edits against the current rig.
/// The repository remains authoritative; this cubit keeps no chain copy.
///
/// Per-kind memory rather than one selection, because the pen's Sound type row
/// switches between three strips that each keep their place: coming back to
/// Live inputs after a look at Outputs lands on the input that was open, not
/// on the first one (accepted design, "Back and context switches preserve each
/// strip's position").
class FxCubit extends Cubit<FxState> {
  /// Creates an [FxCubit] pointed at [initial].
  FxCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    required FxChainPersistence persistence,
    FxDestination? initial,
  }) : _repository = repository,
       _settings = settings,
       _persistence = persistence,
       super(
         initial == null ? const FxState() : FxState.at(initial),
       );

  final LooperRepository _repository;
  final SettingsRepository _settings;
  final FxChainPersistence _persistence;

  /// Reads an editable destination, including its empty default chain. The
  /// binding lookup deliberately omits default chains, so it cannot answer
  /// whether a valid empty track, part, or input can receive a new effect.
  List<TrackEffect>? _currentChain(FxAddress address) {
    final rig = _repository.state;
    final index = address.index;
    final trackExists = rig.tracks.any((track) => track.channel == index);
    return switch (address.stage) {
      FxStage.input =>
        !_persistence.inputRestoreFailed &&
                index >= 0 &&
                index < rig.status.inputChannels &&
                (rig.status.excludedInputMask & (1 << index)) == 0
            ? _repository.monitorEffects(index)
            : null,
      FxStage.loop =>
        trackExists &&
                address.lane != null &&
                address.lane! >= 0 &&
                address.lane! < _repository.laneCount(index)
            ? _repository.laneEffects(index, address.lane!)
            : null,
      FxStage.track => trackExists ? _repository.trackEffects(index) : null,
      FxStage.allTracks => index == 0 ? _repository.allTracksEffects : null,
      FxStage.output =>
        index >= 0 && index < rig.outputBusCount
            ? _repository.outputEffects(index)
            : null,
    };
  }

  bool _sameRig(int generation, int session) =>
      _repository.mixGeneration == generation &&
      _repository.sessionRevision == session;

  bool _validLife(int generation, int session) =>
      !isClosed && _sameRig(generation, session);

  EngineResult _replaceChain(FxAddress address, List<TrackEffect> chain) =>
      switch (address.stage) {
        FxStage.input => _repository.setMonitorEffects(
          input: address.index,
          effects: chain,
        ),
        FxStage.loop => _repository.setLaneEffects(
          channel: address.index,
          lane: address.lane!,
          effects: chain,
        ),
        FxStage.track => _repository.setTrackEffects(
          channel: address.index,
          effects: chain,
        ),
        FxStage.allTracks => _repository.setAllTracksEffects(effects: chain),
        FxStage.output => _repository.setOutputEffects(
          bus: address.index,
          effects: chain,
        ),
      };

  Future<FxEditResult> _editChain(
    FxAddress address,
    ({List<TrackEffect> entries, String? groupId})? Function(
      List<TrackEffect> current,
    )
    change, {
    FxDestination? expectedDestination,
  }) async {
    final generation = _repository.mixGeneration;
    final session = _repository.sessionRevision;
    bool stale() =>
        !_validLife(generation, session) ||
        (expectedDestination != null &&
            state.destination != expectedDestination);
    if (stale()) return const FxEditResult(FxEditStatus.stale);
    final current = _currentChain(address);
    if (current == null) return const FxEditResult(FxEditStatus.refused);
    final proposed = change(current);
    if (proposed == null || proposed.entries.length > kTrackEffectMax) {
      return const FxEditResult(FxEditStatus.refused);
    }
    if (identical(proposed.entries, current)) {
      return const FxEditResult(FxEditStatus.unchanged);
    }
    if (stale()) return const FxEditResult(FxEditStatus.stale);
    final ticket = _persistence.beginPending();
    var confirmed = false;
    try {
      final admitted = _replaceChain(address, proposed.entries);
      if (!admitted.isOk) return const FxEditResult(FxEditStatus.refused);
      final applied = await _repository.settleFxRecipes(
        waitForCallback: true,
        cancelled: () => !_sameRig(generation, session),
      );
      confirmed = applied.isOk && _sameRig(generation, session);
      if (confirmed) _persistence.retainConfirmed(address, _settings);
    } on Object {
      return const FxEditResult(FxEditStatus.refused);
    } finally {
      _persistence.finishPending(ticket);
    }
    if (!_sameRig(generation, session)) {
      return const FxEditResult(FxEditStatus.stale);
    }
    if (!confirmed) return const FxEditResult(FxEditStatus.refused);
    try {
      await _persistence.saveConfirmed(address, _settings);
    } on Object {
      return FxEditResult(FxEditStatus.unsaved, groupId: proposed.groupId);
    }
    if (stale()) return const FxEditResult(FxEditStatus.stale);
    return FxEditResult(FxEditStatus.applied, groupId: proposed.groupId);
  }

  /// Appends one library choice to the selected destination as a new group.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> appendChoice(
    FxDestination destination,
    FxLibraryChoice choice,
  ) {
    final address = destination.address;
    if (address == null) {
      return Future.value(const FxEditResult(FxEditStatus.refused));
    }
    final added = withFreshSlotIds(
      _entriesFor(choice, placement: destination.defaultPlacement),
    );
    if (added.isEmpty) {
      return Future.value(const FxEditResult(FxEditStatus.refused));
    }
    final groupId = added.first.rack?.id ?? added.first.slotId;
    return _editChain(
      address,
      (current) => (
        entries: [...current, ...added],
        groupId: groupId,
      ),
      expectedDestination: destination,
    );
  }

  /// Appends a library choice into the rack named by [rackId].
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> appendToRack(
    FxAddress address,
    String rackId,
    FxLibraryChoice choice,
  ) => _editChain(address, (current) {
    final group = fxChainGroups(
      current,
    ).where((entry) => entry.rack?.id == rackId).firstOrNull;
    if (group == null) return null;
    final added = withFreshSlotIds(
      _entriesFor(
        choice,
        placement: group.placement,
        into: group.rack,
      ),
    );
    if (added.isEmpty || current.length + added.length > kTrackEffectMax) {
      return null;
    }
    return (
      entries: fxSetGroupChannels(
        [
          ...current.sublist(0, group.end),
          ...added,
          ...current.sublist(group.end),
        ],
        group.start,
        group.end + added.length,
        group.channels,
      ),
      groupId: rackId,
    );
  });

  /// Renames the current rack without changing its stable identity.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> renameRack(
    FxAddress address,
    String rackId,
    String name,
  ) => _editChain(address, (current) {
    if (!fxChainGroups(current).any((group) => group.rack?.id == rackId)) {
      return null;
    }
    return (entries: fxRenameRack(current, rackId, name), groupId: rackId);
  });

  /// Reorders the modules of one rack by their stable slot identities.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> reorderRack(
    FxAddress address,
    String rackId,
    List<String> slotIds,
  ) => _editChain(
    address,
    (current) => (
      entries: fxOrderRackModules(current, rackId, slotIds),
      groupId: rackId,
    ),
  );

  /// Reorders complete groups, refusing stale IDs or crossing Pre/Post.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> reorderGroups(
    FxAddress address,
    List<String> groupIds,
  ) => _editChain(
    address,
    (current) => (
      entries: fxOrderGroups(current, groupIds),
      groupId: null,
    ),
  );

  /// Removes one module from a rack, retaining its other modules.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> removeRackModule(
    FxAddress address,
    String rackId,
    String slotId,
  ) => _editChain(address, (current) {
    final group = fxChainGroups(
      current,
    ).where((entry) => entry.rack?.id == rackId).firstOrNull;
    if (group == null || group.length < 2) return null;
    final index = current.indexWhere((entry) => entry.slotId == slotId);
    if (index < group.start || index >= group.end) return null;
    return (entries: fxRemoveRange(current, index, index + 1), groupId: null);
  });

  /// Removes an entire rack with the identity the user confirmed.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> removeRack(FxAddress address, String rackId) =>
      _editChain(address, (current) {
        final group = fxChainGroups(
          current,
        ).where((entry) => entry.rack?.id == rackId).firstOrNull;
        if (group == null) return null;
        return (
          entries: fxRemoveRange(current, group.start, group.end),
          groupId: null,
        );
      });

  /// Removes the one effect the user chose, even if the chain was reordered.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> removeEffect(
    FxAddress address,
    String slotId,
  ) => _editChain(address, (current) {
    final index = current.indexWhere((entry) => entry.slotId == slotId);
    if (index < 0 || current[index].rack != null) return null;
    return (entries: fxRemoveRange(current, index, index + 1), groupId: null);
  });

  /// Moves one current group to the requested stage.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> setGroupPlacement(
    FxAddress address,
    String groupId,
    FxPlacement placement,
  ) => _editChain(address, (current) {
    final group = fxChainGroups(
      current,
    ).where((entry) => fxGroupId(entry) == groupId).firstOrNull;
    if (group == null ||
        address.stage == FxStage.output ||
        address.stage == FxStage.allTracks) {
      return null;
    }
    return (
      entries: fxSetGroupPlacement(
        current,
        group.start,
        group.end,
        placement,
      ),
      groupId: groupId,
    );
  });

  /// Changes one effect's power by stable identity, even after a reorder.
  // ignore: prefer_void_public_cubit_methods
  FxEditResult setEffectEnabled(
    FxAddress address,
    String slotId, {
    required bool enabled,
  }) {
    final chain = _currentChain(address);
    final index = chain?.indexWhere((entry) => entry.slotId == slotId) ?? -1;
    if (index < 0 || isClosed) {
      return const FxEditResult(FxEditStatus.refused);
    }
    if (chain![index].enabled == enabled) {
      return const FxEditResult(FxEditStatus.unchanged);
    }
    final result = switch (address.stage) {
      FxStage.input => _repository.setMonitorEffectEnabled(
        input: address.index,
        index: index,
        enabled: enabled,
      ),
      FxStage.loop => _repository.setLaneEffectEnabled(
        channel: address.index,
        lane: address.lane!,
        index: index,
        enabled: enabled,
      ),
      FxStage.track => _repository.setTrackEffectEnabled(
        channel: address.index,
        index: index,
        enabled: enabled,
      ),
      FxStage.allTracks => _repository.setAllTracksEffectEnabled(
        index: index,
        enabled: enabled,
      ),
      FxStage.output => _repository.setOutputEffectEnabled(
        bus: address.index,
        index: index,
        enabled: enabled,
      ),
    };
    if (!result.isOk) return const FxEditResult(FxEditStatus.refused);
    _persistence.ordinarySlotAt(address, index, enabled: enabled);
    _persistence.scheduleSave(address, _settings);
    return const FxEditResult(FxEditStatus.applied);
  }

  /// Changes every current module of a rack using its stable rack identity.
  // ignore: prefer_void_public_cubit_methods
  FxEditResult setGroupEnabled(
    FxAddress address,
    String groupId, {
    required bool enabled,
  }) {
    final chain = _currentChain(address);
    if (chain == null) return const FxEditResult(FxEditStatus.refused);
    final group = fxChainGroups(
      chain,
    ).where((entry) => fxGroupId(entry) == groupId).firstOrNull;
    if (group == null) return const FxEditResult(FxEditStatus.refused);
    var changed = false;
    for (final entry in group.entries) {
      final id = entry.slotId;
      if (id == null) return const FxEditResult(FxEditStatus.refused);
      final outcome = setEffectEnabled(address, id, enabled: enabled);
      if (outcome.status == FxEditStatus.refused) return outcome;
      changed |= outcome.status == FxEditStatus.applied;
    }
    return FxEditResult(
      changed ? FxEditStatus.applied : FxEditStatus.unchanged,
    );
  }

  /// Moves one built-in parameter without replacing the DSP chain.
  // ignore: prefer_void_public_cubit_methods
  FxEditResult setParameter(
    FxAddress address,
    String slotId,
    int parameter,
    double value,
  ) {
    final chain = _currentChain(address);
    final index = chain?.indexWhere((entry) => entry.slotId == slotId) ?? -1;
    if (index < 0 || isClosed || !value.isFinite || value < 0 || value > 1) {
      return const FxEditResult(FxEditStatus.refused);
    }
    final effect = chain![index];
    if (effect is! BuiltInEffect ||
        parameter < 0 ||
        parameter >= effect.params.length) {
      return const FxEditResult(FxEditStatus.refused);
    }
    if (effect.params[parameter] == value) {
      return const FxEditResult(FxEditStatus.unchanged);
    }
    final result = switch (address.stage) {
      FxStage.input => _repository.setMonitorEffectParam(
        input: address.index,
        index: index,
        param: parameter,
        value: value,
      ),
      FxStage.loop => _repository.setLaneEffectParam(
        channel: address.index,
        lane: address.lane!,
        index: index,
        param: parameter,
        value: value,
      ),
      FxStage.track => _repository.setTrackEffectParam(
        channel: address.index,
        index: index,
        param: parameter,
        value: value,
      ),
      FxStage.allTracks => _repository.setAllTracksEffectParam(
        index: index,
        param: parameter,
        value: value,
      ),
      FxStage.output => _repository.setOutputEffectParam(
        bus: address.index,
        index: index,
        param: parameter,
        value: value,
      ),
    };
    if (!result.isOk) return const FxEditResult(FxEditStatus.refused);
    _persistence.ordinaryParameterAt(address, index, parameter, value);
    _persistence.scheduleSave(address, _settings);
    return const FxEditResult(FxEditStatus.applied);
  }

  /// Applies one group's channel handling to its current members.
  // ignore: prefer_void_public_cubit_methods
  Future<FxEditResult> setGroupChannels(
    FxAddress address,
    String groupId,
    FxChannels channels,
  ) => _editChain(address, (current) {
    final group = fxChainGroups(
      current,
    ).where((entry) => fxGroupId(entry) == groupId).firstOrNull;
    if (group == null) return null;
    final writes = fxGroupChannelWrites(group, channels);
    if (writes.isEmpty) return (entries: current, groupId: groupId);
    final next = List<TrackEffect>.of(current);
    for (final write in writes.entries) {
      final effect = current[write.key];
      next[write.key] = switch (effect) {
        BuiltInEffect() => effect.copyWith(channels: write.value),
        PluginEffect() => effect.copyWith(channels: write.value),
      };
    }
    return (entries: next, groupId: groupId);
  });

  static List<TrackEffect> _entriesFor(
    FxLibraryChoice choice, {
    required FxPlacement placement,
    FxRack? into,
  }) {
    switch (choice) {
      case FxSingleChoice(:final type):
        return [
          BuiltInEffect(
            type: type,
            enabled: false,
            placement: placement,
            rack: into,
          ),
        ];
      case FxSavedChoice(:final preset):
        final rack =
            into ??
            (preset.isRack
                ? FxRack(
                    id: SlotIds.mint(),
                    name: preset.name,
                    art: preset.art,
                  )
                : null);
        return [
          for (final effect in preset.entries)
            switch (effect) {
              BuiltInEffect() => effect.copyWith(
                enabled: false,
                placement: placement,
                rack: rack,
              ),
              PluginEffect() => effect.copyWith(
                enabled: false,
                placement: placement,
                rack: rack,
              ),
            },
        ];
      case FxRackChoice(:final preset):
        final rack =
            into ??
            FxRack(
              id: SlotIds.mint(),
              name: preset.name,
              art: kFxFamilySlugs[preset.family],
            );
        return [
          for (final module in fxPresetModules(preset))
            fxModuleEntry(module, preset).copyWith(
              enabled: false,
              placement: placement,
              rack: rack,
            ),
        ];
    }
  }

  /// Moves to [kind], landing on the source that kind was left on.
  void showKind(FxDestinationKind kind) {
    if (state.kind == kind) return;
    emit(state.copyWith(kind: kind));
  }

  /// Selects [index] within the current kind.
  ///
  /// Switching tracks resets the part to Whole track: a part index means a
  /// lane of the track it was chosen on, and carrying it to another track
  /// would open a stranger's second part — or nothing at all.
  void selectSource(int index) {
    if (state.index == index) return;
    emit(
      state.kind == FxDestinationKind.recordedTrack
          ? state.copyWith(index: index, part: FxTrackPart.whole)
          : state.copyWith(index: index),
    );
  }

  /// Selects which part of the current recorded track is being edited.
  void selectPart(FxTrackPart part) {
    if (state.kind != FxDestinationKind.recordedTrack) return;
    emit(state.copyWith(part: part));
  }

  /// Points the page at [destination] outright — for an entry from somewhere
  /// that already knows the target (an FX marker, a pedal assignment).
  void show(FxDestination destination) => emit(
    state.copyWith(
      kind: destination.kind,
      index: destination.index,
      part: destination.part,
    ),
  );
}
