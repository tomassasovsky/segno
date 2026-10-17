import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:settings_repository/settings_repository.dart';

/// The hardware namespace whose player-authored names are being managed.
enum PortAliasKind {
  /// Individual input sockets.
  input,

  /// Stereo output destinations.
  output,
}

/// Names confirmed for one uninterrupted device opening.
typedef PortAliasSnapshot = ({
  String device,
  Map<int, String> names,
  int lifetime,
});

/// Owns input or output alias storage, per-key ordering and device lifetimes.
/// The publication callback only adapts confirmed state into presentation.
class PortAliases {
  /// Follows the currently opened device and loads its persisted names.
  PortAliases({
    required SettingsRepository settings,
    required LooperRepository repository,
    required PortAliasKind kind,
    required int probeCeiling,
    required void Function(PortAliasSnapshot) onChanged,
  }) : _settings = settings,
       _repository = repository,
       _kind = kind,
       _probeCeiling = probeCeiling,
       _onChanged = onChanged {
    _subscription = _repository.looperState.listen(
      (looper) => unawaited(_followDevice(looper)),
    );
    unawaited(_followDevice(_repository.state));
  }

  final SettingsRepository _settings;
  final LooperRepository _repository;
  final PortAliasKind _kind;
  final int _probeCeiling;
  final void Function(PortAliasSnapshot) _onChanged;
  Map<int, String> _names = const {};
  bool _closed = false;
  late final StreamSubscription<LooperState> _subscription;

  final Map<int, String?> _confirmedDuringLoad = {};
  final Map<(String, int), Future<void>> _renameTails = {};
  final Set<(String, int)> _recoveryKeys = {};
  String _device = '';
  int _lifetime = 0;
  int _generation = -1;
  bool _loading = false;
  bool _loaded = false;

  bool _owns(int lifetime, int generation) =>
      !_closed &&
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
    _loaded = false;
    _confirmedDuringLoad.clear();
    _publish(const {});
    if (device.isEmpty) return;
    final names = <int, String>{};
    try {
      for (var port = 0; port < _probeCeiling; port++) {
        await _renameTails[(device, port)];
        if (!_owns(lifetime, generation)) return;
        final saved = await _read(device, port);
        if (!_owns(lifetime, generation)) return;
        if (saved != null && saved.isNotEmpty) names[port] = saved;
        _recoveryKeys.remove((device, port));
      }
    } on Object {
      if (_owns(lifetime, generation)) _loading = false;
      return;
    }
    if (!_owns(lifetime, generation)) return;
    _loading = false;
    _loaded = true;
    for (final entry in _confirmedDuringLoad.entries) {
      if (entry.value case final name?) {
        names[entry.key] = name;
      } else {
        names.remove(entry.key);
      }
    }
    _confirmedDuringLoad.clear();
    _publish(names);
  }

  /// Renames one port while preserving its device lifetime and exact old key.
  Future<AliasRenameResult> rename(
    int port,
    String name, {
    int? expectedLifetime,
  }) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    if (device.isEmpty ||
        port < 0 ||
        port >= _probeCeiling ||
        !_owns(lifetime, generation) ||
        (expectedLifetime != null && expectedLifetime != lifetime)) {
      return AliasRenameResult.refused;
    }
    final key = (device, port);
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
      if (_loaded && trimmed == (_names[port] ?? '')) {
        return AliasRenameResult.applied;
      }
      String? checkpoint;
      try {
        checkpoint = await _read(device, port);
      } on Object {
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      try {
        await _write(device, port, trimmed.isEmpty ? null : trimmed);
      } on Object {
        try {
          await _write(device, port, checkpoint);
        } on Object {
          _recoveryKeys.add(key);
          return AliasRenameResult.recoveryRequired;
        }
        if (_owns(lifetime, generation)) {
          if (_loading) _confirmedDuringLoad[port] = checkpoint;
          final names = {..._names};
          if (checkpoint == null || checkpoint.isEmpty) {
            names.remove(port);
          } else {
            names[port] = checkpoint;
          }
          _publish(names);
        }
        return AliasRenameResult.storageFailed;
      }
      if (!_owns(lifetime, generation)) return AliasRenameResult.refused;
      if (_loading) {
        _confirmedDuringLoad[port] = trimmed.isEmpty ? null : trimmed;
      }
      final names = {..._names};
      if (trimmed.isEmpty) {
        names.remove(port);
      } else {
        names[port] = trimmed;
      }
      _publish(names);
      return AliasRenameResult.applied;
    } finally {
      completed.complete();
      if (identical(_renameTails[key], completed.future)) {
        unawaited(_renameTails.remove(key));
      }
    }
  }

  /// Re-reads one uncertain key before another edit may use it.
  Future<void> retryAliasRecovery(int port) async {
    final device = _device;
    final lifetime = _lifetime;
    final generation = _generation;
    final key = (device, port);
    if (device.isEmpty || !_recoveryKeys.contains(key)) return;
    try {
      final value = await _read(device, port);
      if (!_owns(lifetime, generation)) return;
      _recoveryKeys.remove(key);
      final names = {..._names};
      if (value == null || value.isEmpty) {
        names.remove(port);
      } else {
        names[port] = value;
      }
      _publish(names);
    } on Object {
      return;
    }
  }

  void _publish(Map<int, String> names) {
    _names = Map.unmodifiable(names);
    _onChanged((device: _device, names: _names, lifetime: _lifetime));
  }

  Future<String?> _read(String device, int port) => switch (_kind) {
    PortAliasKind.input => _settings.loadInputName(device: device, input: port),
    PortAliasKind.output => _settings.loadOutputName(device: device, bus: port),
  };

  Future<void> _write(String device, int port, String? name) =>
      switch ((_kind, name)) {
        (PortAliasKind.input, null) => _settings.clearInputName(
          device: device,
          input: port,
        ),
        (PortAliasKind.input, final value?) => _settings.saveInputName(
          device: device,
          input: port,
          name: value,
        ),
        (PortAliasKind.output, null) => _settings.clearOutputName(
          device: device,
          bus: port,
        ),
        (PortAliasKind.output, final value?) => _settings.saveOutputName(
          device: device,
          bus: port,
          name: value,
        ),
      };

  /// Stops publication; admitted storage work still finishes its compensation.
  Future<void> close() {
    _closed = true;
    return _subscription.cancel();
  }
}
