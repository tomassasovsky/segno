import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:settings_repository/settings_repository.dart';

part 'inputs_state.dart';

/// What the player calls each hardware input, per interface.
///
/// Modelled on `TracksCubit` because it is the same problem one level down the
/// signal path: the interface says input 2 and the player says "mic". Two
/// things are NOT copies of it:
///
/// **Names belong to the DEVICE**, not to the socket number. Input 1 on a
/// Scarlett and input 1 on the built-in pair are different jacks with different
/// things plugged into them, and one name for both describes whichever rig was
/// patched last. Keyed off the engine's reported device name, the same shape
/// `latency_offset.$device.$rate.$buffer` already uses.
///
/// **There is no ceiling.** An earlier version stopped at the engine constant
/// now called `LE_MAX_MONITORED_INPUTS`, on the reading that a socket past it
/// was unusable. It caps which inputs the monitor path covers — a
/// higher-numbered channel is still recordable, so it is still worth naming
/// (#558). The list follows whatever the device reports.
///
/// One persisted map and nothing else. Provided at app level and loaded once,
/// because an input is called what the player calls it on every surface that
/// shows one — the Audio face's input chips, the Tracks routing summary and the
/// per-track lane list all read the same names through `l10n.inputName`.
class InputsCubit extends Cubit<InputsState> {
  /// Creates an [InputsCubit] that follows [repository]'s open device.
  InputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : _settings = settings,
       _repository = repository,
       super(const InputsState()) {
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
    emit(InputsState(device: device, lifetime: lifetime));
    if (device.isEmpty) return;
    final names = <int, String>{};
    try {
      for (var input = 0; input < InputsState.probeCeiling; input++) {
        await _renameTails[(device, input)];
        if (!_owns(lifetime, generation)) return;
        final saved = await _settings.loadInputName(
          device: device,
          input: input,
        );
        if (!_owns(lifetime, generation)) return;
        if (saved != null && saved.isNotEmpty) names[input] = saved;
        _recoveryKeys.remove((device, input));
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
    emit(InputsState(device: device, names: names, lifetime: lifetime));
  }

  /// Durably renames [input] for one device lifetime, restoring its exact key
  /// if a write throws after touching storage.
  Future<void> rename(
    int input,
    String name, {
    int? expectedLifetime,
    void Function(AliasRenameResult)? onResult,
  }) async {
    final result = await _rename(
      input,
      name,
      expectedLifetime: expectedLifetime,
    );
    onResult?.call(result);
  }

  Future<AliasRenameResult> _rename(
    int input,
    String name, {
    int? expectedLifetime,
  }) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    if (device.isEmpty ||
        input < 0 ||
        input >= InputsState.probeCeiling ||
        !_owns(lifetime, generation) ||
        (expectedLifetime != null && expectedLifetime != lifetime)) {
      return AliasRenameResult.refused;
    }
    final key = (device, input);
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
      if (!_loading && trimmed == (state.names[input] ?? '')) {
        return AliasRenameResult.applied;
      }
      String? checkpoint;
      try {
        checkpoint = await _settings.loadInputName(
          device: device,
          input: input,
        );
      } on Object {
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      try {
        if (trimmed.isEmpty) {
          await _settings.clearInputName(device: device, input: input);
        } else {
          await _settings.saveInputName(
            device: device,
            input: input,
            name: trimmed,
          );
        }
      } on Object {
        try {
          if (checkpoint == null) {
            await _settings.clearInputName(device: device, input: input);
          } else {
            await _settings.saveInputName(
              device: device,
              input: input,
              name: checkpoint,
            );
          }
        } on Object {
          _recoveryKeys.add(key);
          return AliasRenameResult.recoveryRequired;
        }
        if (_owns(lifetime, generation)) {
          if (_loading) _confirmedDuringLoad[input] = checkpoint;
          final names = {...state.names};
          if (checkpoint == null || checkpoint.isEmpty) {
            names.remove(input);
          } else {
            names[input] = checkpoint;
          }
          emit(state.copyWith(names: names));
        }
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      if (_loading) {
        _confirmedDuringLoad[input] = trimmed.isEmpty ? null : trimmed;
      }
      final names = {...state.names};
      if (trimmed.isEmpty) {
        names.remove(input);
      } else {
        names[input] = trimmed;
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
  Future<void> retryAliasRecovery(int input) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    final key = (device, input);
    if (device.isEmpty || !_recoveryKeys.contains(key)) return;
    try {
      final value = await _settings.loadInputName(device: device, input: input);
      if (!_owns(lifetime, generation)) return;
      _recoveryKeys.remove(key);
      final names = {...state.names};
      if (value == null || value.isEmpty) {
        names.remove(input);
      } else {
        names[input] = value;
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
