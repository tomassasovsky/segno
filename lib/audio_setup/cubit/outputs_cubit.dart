import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

part 'outputs_state.dart';

/// What the player calls each destination of the open interface.
///
/// The output-side twin of [InputsCubit], and keyed the same way: names belong
/// to the DEVICE, because outputs 3 and 4 on a Scarlett and on the built-in
/// pair drive different things.
///
/// The one difference is the unit. An input is a jack; a destination is a
/// PAIR of jacks (bus `k` = outputs `2k` and `2k+1`), which is what the player
/// patches, names and sends a track to. Naming the jacks separately would ask
/// for two names for one cable pair and leave every routing surface to guess
/// which of them to show.
class OutputsCubit extends Cubit<OutputsState> {
  /// Creates an [OutputsCubit] that follows [repository]'s open device.
  OutputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : _settings = settings,
       _repository = repository,
       super(const OutputsState()) {
    _subscription = _repository.looperState.listen(
      (looper) => unawaited(_followDevice(looper)),
    );
    unawaited(_followDevice(_repository.state));
  }

  final SettingsRepository _settings;
  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

  final Map<int, String?> _confirmedDuringLoad = {};
  final Map<(String, int), Future<void>> _renameTails = {};
  final Set<(String, int)> _recoveryKeys = {};
  String _device = '';
  int _lifetime = 0;
  int _generation = -1;
  bool _loading = false;

  bool _owns(int lifetime, int generation) =>
      !isClosed &&
      lifetime == _lifetime &&
      generation == _repository.mixGeneration;

  Future<void> _followDevice(LooperState looper) async {
    final status = looper.status;
    final device = status.isConnected && status.devicePresent
        ? status.deviceName
        : '';
    final generation = looper.mixGeneration;
    if (generation != _repository.mixGeneration) return;
    if (device == _device && generation == _generation) return;
    _device = device;
    _generation = generation;
    final lifetime = ++_lifetime;
    _loading = device.isNotEmpty;
    _confirmedDuringLoad.clear();
    emit(OutputsState(device: device, lifetime: lifetime));
    if (device.isEmpty) return;
    final names = <int, String>{};
    try {
      for (var bus = 0; bus < OutputsState.probeCeiling; bus++) {
        await _renameTails[(device, bus)];
        if (!_owns(lifetime, generation)) return;
        final saved = await _settings.loadOutputName(device: device, bus: bus);
        if (!_owns(lifetime, generation)) return;
        if (saved != null && saved.isNotEmpty) names[bus] = saved;
        _recoveryKeys.remove((device, bus));
      }
    } on Object {
      if (_owns(lifetime, generation)) _loading = false;
      return;
    }
    if (!_owns(lifetime, generation)) return;
    _loading = false;
    for (final entry in _confirmedDuringLoad.entries) {
      if (entry.value case final name?) {
        names[entry.key] = name;
      } else {
        names.remove(entry.key);
      }
    }
    _confirmedDuringLoad.clear();
    emit(OutputsState(device: device, names: names, lifetime: lifetime));
  }

  /// Durably renames [bus] for one device lifetime, restoring its exact key
  /// if a write throws after touching storage.
  Future<void> rename(
    int bus,
    String name, {
    int? expectedLifetime,
    void Function(AliasRenameResult)? onResult,
  }) async {
    final result = await _rename(
      bus,
      name,
      expectedLifetime: expectedLifetime,
    );
    onResult?.call(result);
  }

  Future<AliasRenameResult> _rename(
    int bus,
    String name, {
    int? expectedLifetime,
  }) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    if (device.isEmpty ||
        bus < 0 ||
        bus >= OutputsState.probeCeiling ||
        !_owns(lifetime, generation) ||
        (expectedLifetime != null && expectedLifetime != lifetime)) {
      return AliasRenameResult.refused;
    }
    final key = (device, bus);
    final previous = _renameTails[key] ?? Future<void>.value();
    final completed = Completer<void>();
    _renameTails[key] = completed.future;
    try {
      await previous;
      if (!_owns(lifetime, generation)) {
        return AliasRenameResult.refused;
      }
      if (_recoveryKeys.contains(key)) {
        return AliasRenameResult.recoveryRequired;
      }
      final trimmed = name.trim();
      if (!_loading && trimmed == (state.names[bus] ?? '')) {
        return AliasRenameResult.applied;
      }
      String? checkpoint;
      try {
        checkpoint = await _settings.loadOutputName(device: device, bus: bus);
      } on Object {
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      try {
        if (trimmed.isEmpty) {
          await _settings.clearOutputName(device: device, bus: bus);
        } else {
          await _settings.saveOutputName(
            device: device,
            bus: bus,
            name: trimmed,
          );
        }
      } on Object {
        try {
          if (checkpoint == null) {
            await _settings.clearOutputName(device: device, bus: bus);
          } else {
            await _settings.saveOutputName(
              device: device,
              bus: bus,
              name: checkpoint,
            );
          }
        } on Object {
          _recoveryKeys.add(key);
          return AliasRenameResult.recoveryRequired;
        }
        if (_owns(lifetime, generation)) {
          if (_loading) _confirmedDuringLoad[bus] = checkpoint;
          final names = {...state.names};
          if (checkpoint == null || checkpoint.isEmpty) {
            names.remove(bus);
          } else {
            names[bus] = checkpoint;
          }
          emit(state.copyWith(names: names));
        }
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      if (_loading) {
        _confirmedDuringLoad[bus] = trimmed.isEmpty ? null : trimmed;
      }
      final names = {...state.names};
      if (trimmed.isEmpty) {
        names.remove(bus);
      } else {
        names[bus] = trimmed;
      }
      emit(state.copyWith(names: names));
      return AliasRenameResult.applied;
    } finally {
      completed.complete();
      if (identical(_renameTails[key], completed.future)) {
        unawaited(_renameTails.remove(key));
      }
    }
  }

  /// Re-reads one uncertain key before another edit may use it.
  Future<void> retryAliasRecovery(int bus) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    final key = (device, bus);
    if (device.isEmpty || !_recoveryKeys.contains(key)) return;
    try {
      final value = await _settings.loadOutputName(device: device, bus: bus);
      if (!_owns(lifetime, generation)) return;
      _recoveryKeys.remove(key);
      final names = {...state.names};
      if (value == null || value.isEmpty) {
        names.remove(bus);
      } else {
        names[bus] = value;
      }
      emit(state.copyWith(names: names));
    } on Object {
      return;
    }
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
