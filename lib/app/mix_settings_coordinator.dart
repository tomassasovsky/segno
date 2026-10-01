import 'dart:async';

import 'package:looper_repository/looper_repository.dart';

/// One atomic durable mix value, with exact rollback of the previous value.
abstract interface class MixSettingsPersistence {
  /// Reads the opaque previous durable value, including absence.
  Future<String?> read(String device);

  /// Atomically writes this candidate, preserving other devices' setups.
  Future<void> write(String device, MixSettingsSnapshot candidate);

  /// Atomically restores the exact value returned by [read].
  Future<void> restore(String device, String? checkpoint);
}

/// The complete outcome of one coalesced set of edits.
enum MixSettingsStatus {
  /// Storage and callback both accepted the controls.
  applied,

  /// Validation, admission or callback refused; durable rollback succeeded.
  rejected,

  /// Storage refused before audio changed.
  storageFailed,

  /// Session or device lifetime changed before completion.
  superseded,

  /// Durable rollback failed. Audio is stopped and recovery is required.
  recoveryRequired,
}

/// Carries failures to callers and the shared UI error stream.
class MixSettingsOutcome {
  /// Creates an outcome.
  const MixSettingsOutcome(this.status, {this.engineResult, this.error});

  /// Transaction outcome, including persistence failures.
  final MixSettingsStatus status;

  /// Native refusal reason when available.
  final EngineResult? engineResult;

  /// Storage or recovery failure when available.
  final Object? error;

  /// Whether both owners accepted the candidate.
  bool get isOk => status == MixSettingsStatus.applied;
}

/// Session work cannot proceed until the failed durable rollback is retried.
class MixSettingsRecoveryException implements Exception {
  /// Creates the typed error consumed by session/app error handling.
  const MixSettingsRecoveryException(this.outcome);

  /// The original failure that requires [MixSettingsCoordinator.recover].
  final MixSettingsOutcome outcome;

  @override
  String toString() => 'Mix settings recovery required: ${outcome.error}';
}

enum _Control {
  trackLevel,
  laneLevel,
  pan,
  trim,
  inputPan,
  pair,
  recordingInput,
  trackOutput,
  balance,
  monitor,
  outputLevel,
  outputMute,
  outputMono,
  outputBalance,
  reset,
  soloOn,
  soloOff,
  soloToggle,
  clearSolo,
}

typedef _Target = (_Control, int, int);
typedef _Edit = MixSettingsSnapshot? Function(MixSettingsSnapshot);

bool _sameMap<K, V>(Map<K, V> a, Map<K, V> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// Serializes live edits with durable storage and callback confirmation.
///
/// One active candidate and one latest edit per bounded control are retained.
/// All callers in a drain share its future, so a drag cannot accumulate event
/// waiters here. The final value remains queued until it is applied or refused
/// with an explicit outcome. Session replacement and boot-key synchronization
/// use [runExclusive] to share this same publication boundary.
class MixSettingsCoordinator {
  /// Connects the shared repository, atomic storage and device identity.
  MixSettingsCoordinator({
    required LooperRepository repository,
    required MixSettingsPersistence persistence,
    required String Function() device,
  }) : _repository = repository,
       _persistence = persistence,
       _device = device;

  final LooperRepository _repository;
  final MixSettingsPersistence _persistence;
  final String Function() _device;
  final _failures = StreamController<MixSettingsOutcome>.broadcast();
  final _pending = <_Target, _Edit>{};
  Future<MixSettingsOutcome>? _draining;
  Future<void> _exclusiveTail = Future<void>.value();
  int _exclusiveCount = 0;
  int? _queuedGeneration;
  String? _queuedDevice;
  bool _closed = false;
  MixSettingsOutcome? _recovery;
  (String, String?)? _recoveryCheckpoint;

  static const _applied = MixSettingsOutcome(MixSettingsStatus.applied);

  /// Shared user-visible failures, including failed durable rollback.
  Stream<MixSettingsOutcome> get failures => _failures.stream;

  MixSettingsOutcome _report(MixSettingsOutcome result) {
    if (!result.isOk && !_failures.isClosed) _failures.add(result);
    return result;
  }

  Future<MixSettingsOutcome> _reject() => Future.value(
    _report(
      const MixSettingsOutcome(
        MixSettingsStatus.rejected,
        engineResult: EngineResult.invalid,
      ),
    ),
  );

  Future<MixSettingsOutcome> _submit(_Target target, _Edit edit) {
    if (_recovery case final recovery?) return Future.value(recovery);
    if (_closed || _exclusiveCount != 0) {
      return Future.value(
        _report(
          const MixSettingsOutcome(
            MixSettingsStatus.superseded,
          ),
        ),
      );
    }
    final generation = _repository.mixGeneration;
    final device = _device();
    if (_queuedGeneration != generation || _queuedDevice != device) {
      _pending.clear();
      _queuedGeneration = generation;
      _queuedDevice = device;
    }
    var queuedTarget = target;
    var queuedEdit = edit;
    if (target.$1 == _Control.clearSolo) {
      _pending.removeWhere((key, _) => _soloControl(key.$1));
    } else if (_soloControl(target.$1)) {
      final previous = _pending.keys
          .where((key) => key.$2 == target.$2 && _soloControl(key.$1))
          .firstOrNull;
      if (previous != null) _pending.remove(previous);
      if (target.$1 == _Control.soloToggle) {
        if (previous?.$1 == _Control.soloToggle) {
          // Two unsubmitted presses cancel, without retaining a closure chain.
          return _draining ?? Future.value(_applied);
        }
        final control = switch (previous?.$1) {
          _Control.soloOn => _Control.soloOff,
          _Control.soloOff => _Control.soloOn,
          _ => _Control.soloToggle,
        };
        queuedTarget = (control, target.$2, 0);
        queuedEdit = _soloEdit(control, target.$2);
      }
    }
    // Reinsertion preserves the ordering of overlapping controls (Reset then
    // fader, or a track fader then its lane fader) without retaining old moves.
    _pending
      ..remove(queuedTarget)
      ..[queuedTarget] = queuedEdit;
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  bool _current(int generation, String device) =>
      generation == _repository.mixGeneration && device == _device();

  Future<MixSettingsOutcome> _drain() async {
    var outcome = _applied;
    while (_pending.isNotEmpty) {
      // Temporary audibility never joins a durable write that can fail.
      // Keep each contiguous group ordered within this same publication owner.
      final temporary = _temporaryControl(_pending.keys.first.$1);
      final targets = _pending.keys
          .takeWhile((key) => _temporaryControl(key.$1) == temporary)
          .toList();
      final edits = [for (final target in targets) _pending.remove(target)!];
      final generation = _queuedGeneration!;
      final device = _queuedDevice!;
      final settled = _repository.mixSettingsSettled
          ? EngineResult.ok
          : await _repository.settleMixSettings();
      MixSettingsOutcome result;
      if (!_current(generation, device)) {
        result = const MixSettingsOutcome(MixSettingsStatus.superseded);
      } else if (!settled.isOk) {
        result = MixSettingsOutcome(
          MixSettingsStatus.rejected,
          engineResult: settled,
        );
      } else {
        MixSettingsSnapshot? candidate = _repository.mixSettingsSnapshot;
        for (final edit in edits) {
          candidate = edit(candidate!);
          if (candidate == null) break;
        }
        result = candidate == null
            ? const MixSettingsOutcome(
                MixSettingsStatus.rejected,
                engineResult: EngineResult.invalid,
              )
            : await _commit(candidate, generation, device);
      }
      _report(result);
      if (!result.isOk) outcome = result;
      if (_recovery != null) _pending.clear();
    }
    return outcome;
  }

  Future<MixSettingsOutcome> _commit(
    MixSettingsSnapshot candidate,
    int generation,
    String device,
  ) async {
    final current = _repository.mixSettingsSnapshot;
    if (device.isEmpty &&
        (candidate.inputSetup != current.inputSetup ||
            candidate.outputSetup != current.outputSetup ||
            !_sameMap(candidate.laneInputs, current.laneInputs) ||
            !_sameMap(candidate.laneOutputs, current.laneOutputs) ||
            !_sameMap(candidate.laneCounts, current.laneCounts))) {
      return const MixSettingsOutcome(
        MixSettingsStatus.rejected,
        engineResult: EngineResult.notReady,
      );
    }
    final valid = _repository.validateMixSettings(candidate);
    if (!valid.isOk) {
      return MixSettingsOutcome(
        MixSettingsStatus.rejected,
        engineResult: valid,
      );
    }
    final persistent =
        candidate.copyWith(trackSolos: const {}) !=
        current.copyWith(trackSolos: const {});
    String? checkpoint;
    if (persistent) {
      try {
        checkpoint = await _persistence.read(device);
      } on Object catch (error) {
        return MixSettingsOutcome(
          MixSettingsStatus.storageFailed,
          error: error,
        );
      }
      if (!_current(generation, device)) {
        return const MixSettingsOutcome(MixSettingsStatus.superseded);
      }
      // No audio or confirmed state changes before this atomic durable write.
      try {
        await _persistence.write(device, candidate);
      } on Object catch (error) {
        return _rollback(
          device,
          checkpoint,
          MixSettingsOutcome(MixSettingsStatus.storageFailed, error: error),
        );
      }
    }
    if (!_current(generation, device)) {
      return _rollback(
        device,
        checkpoint,
        const MixSettingsOutcome(MixSettingsStatus.superseded),
      );
    }
    final admitted = _repository.applyMixSettings(candidate);
    final settled = admitted.isOk
        ? await _repository.settleMixSettings()
        : admitted;
    // A successful settlement means the repository published this candidate.
    // A stop or restart after that publication cannot undo it; rolling back
    // only storage would make the next startup replay a different mix.
    if (!settled.isOk) {
      final failure = MixSettingsOutcome(
        _current(generation, device)
            ? MixSettingsStatus.rejected
            : MixSettingsStatus.superseded,
        engineResult: settled,
      );
      return persistent ? _rollback(device, checkpoint, failure) : failure;
    }
    return _applied;
  }

  Future<MixSettingsOutcome> _rollback(
    String device,
    String? checkpoint,
    MixSettingsOutcome failure,
  ) async {
    try {
      await _persistence.restore(device, checkpoint);
      return failure;
    } on Object catch (error) {
      _repository
        ..blockStartForMixRecovery()
        ..stopEngine();
      _recoveryCheckpoint = (device, checkpoint);
      return _recovery = MixSettingsOutcome(
        MixSettingsStatus.recoveryRequired,
        engineResult: failure.engineResult,
        error: error,
      );
    }
  }

  /// Restores a session replacement's durable checkpoint while its caller
  /// holds [runExclusive]. Failed rollback shares the live controls' stopped
  /// recovery state, failure stream and [recover] retry action.
  Future<MixSettingsOutcome> rollbackExclusive({
    required String device,
    required String? checkpoint,
  }) async {
    if (_exclusiveCount == 0) {
      throw StateError('Mix rollback requires the exclusive boundary');
    }
    return _report(
      await _rollback(
        device,
        checkpoint,
        const MixSettingsOutcome(MixSettingsStatus.rejected),
      ),
    );
  }

  /// Waits for every currently queued final control value.
  Future<MixSettingsOutcome> flush() =>
      _draining ?? Future.value(_recovery ?? _applied);

  /// Orders session replacement, boot restore and key synchronization after
  /// pending edits. Controls are refused explicitly until the boundary exits.
  Future<T> runExclusive<T>(Future<T> Function() action) {
    return _exclusive(action);
  }

  Future<T> _exclusive<T>(
    Future<T> Function() action, {
    bool recovery = false,
  }) {
    _exclusiveCount++;
    final result = _exclusiveTail.then((_) async {
      await flush();
      if (!recovery && _recovery != null) {
        throw MixSettingsRecoveryException(_recovery!);
      }
      return action();
    });
    _exclusiveTail = result.then<void>(
      (_) => _exclusiveCount--,
      onError: (Object _, StackTrace _) {
        _exclusiveCount--;
      },
    );
    return result;
  }

  /// Retries the exact failed durable rollback. Audio stays stopped; app
  /// device controls may reopen it only after this reports success.
  Future<MixSettingsOutcome> recover() => _exclusive(() async {
    final checkpoint = _recoveryCheckpoint;
    if (checkpoint == null) return _applied;
    try {
      await _persistence.restore(checkpoint.$1, checkpoint.$2);
      _repository.clearMixRecoveryStartBlock();
      _recovery = null;
      _recoveryCheckpoint = null;
      return _applied;
    } on Object catch (error) {
      return _report(
        _recovery = MixSettingsOutcome(
          MixSettingsStatus.recoveryRequired,
          error: error,
        ),
      );
    }
  }, recovery: true);

  /// Flushes the accepted edits before releasing the failure stream.
  Future<void> close() async {
    _closed = true;
    await flush();
    await _exclusiveTail;
    await _failures.close();
  }

  /// Sets every active lane's independent playback level.
  Future<MixSettingsOutcome> setTrackVolume(double volume, {int channel = 0}) {
    if (!_track(channel) || !volume.isFinite) return _reject();
    return _submit(
      (_Control.trackLevel, channel, 0),
      (value) => value.copyWith(
        laneLevels: {
          ...value.laneLevels,
          for (var lane = 0; lane < (value.laneCounts[channel] ?? 1); lane++)
            (channel, lane): volume.clamp(0.0, 2.0),
        },
      ),
    );
  }

  /// Sets one lane's playback level.
  Future<MixSettingsOutcome> setLaneVolume(
    double volume, {
    required int channel,
    required int lane,
  }) {
    if (!_track(channel) || lane < 0 || lane >= kMaxLanes || !volume.isFinite) {
      return _reject();
    }
    return _submit(
      (_Control.laneLevel, channel, lane),
      (value) => value.copyWith(
        laneLevels: {
          ...value.laneLevels,
          (channel, lane): volume.clamp(0.0, 2.0),
        },
      ),
    );
  }

  /// Sets a track's offset without changing recorded source images.
  Future<MixSettingsOutcome> setTrackPan(double pan, {int channel = 0}) {
    if (!_track(channel) || !pan.isFinite) return _reject();
    return _submit(
      (_Control.pan, channel, 0),
      (value) => value.copyWith(
        trackPans: {...value.trackPans, channel: pan.clamp(-1.0, 1.0)},
      ),
    );
  }

  /// Sets capture gain independently of live level.
  Future<MixSettingsOutcome> setInputTrimDb({
    required int input,
    required double db,
  }) {
    if (!_input(input) || !db.isFinite) return _reject();
    return _submit(
      (_Control.trim, input, 0),
      (value) => value.copyWith(
        inputSetup: value.inputSetup.withTrim(
          input,
          db.clamp(kMinInputTrimDb, kMaxInputTrimDb),
        ),
      ),
    );
  }

  /// Positions live monitoring and future recorded input images.
  Future<MixSettingsOutcome> setInputPan({
    required int input,
    required double pan,
  }) {
    if (!_input(input) || !pan.isFinite) return _reject();
    return _submit(
      (_Control.inputPan, input, 0),
      (value) => value.copyWith(
        inputSetup: value.inputSetup.withPan(input, pan.clamp(-1.0, 1.0)),
      ),
    );
  }

  /// Links or unlinks an even adjacent input pair.
  Future<MixSettingsOutcome> setInputPair({
    required int input,
    required bool paired,
  }) {
    if (!_input(input) || input.isOdd || input + 1 >= kMaxChannels) {
      return _reject();
    }
    return _submit(
      (_Control.pair, input, 0),
      (value) => _repository.prepareInputPair(
        value,
        input: input,
        paired: paired,
      ),
    );
  }

  /// Selects or removes one recording source (both members when linked).
  Future<MixSettingsOutcome> setRecordingInput({
    required int channel,
    required int input,
    required bool selected,
  }) {
    if (!_track(channel) || !_input(input)) return _reject();
    return _submit(
      (_Control.recordingInput, channel, input),
      (value) => _repository.prepareRecordingInputs(
        value,
        channel: channel,
        input: input,
        selected: selected,
      ),
    );
  }

  /// Sets a whole track's destination in one durable/native revision.
  Future<MixSettingsOutcome> setTrackOutput({
    required int channel,
    required int mask,
  }) {
    if (!_track(channel) || mask < 0 || mask > 0xffffffff) return _reject();
    return _submit(
      (_Control.trackOutput, channel, 0),
      (value) => _repository.prepareTrackOutput(
        value,
        channel: channel,
        mask: mask,
      ),
    );
  }

  /// Balances both members of an existing pair together.
  Future<MixSettingsOutcome> setPairBalance({
    required int input,
    required double balance,
  }) {
    if (!_input(input) || input.isOdd || !balance.isFinite) return _reject();
    return _submit((_Control.balance, input, 0), (value) {
      if (!value.inputSetup.pairs.containsKey(input)) {
        return null;
      }
      return value.copyWith(
        inputSetup: value.inputSetup.withBalance(
          input,
          balance.clamp(-1.0, 1.0),
        ),
      );
    });
  }

  /// Sets live level independently of capture trim.
  Future<MixSettingsOutcome> setMonitorVolume({
    required int input,
    required double volume,
  }) {
    if (!_input(input) || !volume.isFinite) return _reject();
    return _submit(
      (_Control.monitor, input, 0),
      (value) => value.copyWith(
        monitorLevels: {...value.monitorLevels, input: volume.clamp(0.0, 2.0)},
      ),
    );
  }

  /// Changes one destination fact while retaining its other controls.
  Future<MixSettingsOutcome> setOutputLevel({
    required int bus,
    required double level,
  }) {
    if (!_output(bus) || !level.isFinite) return _reject();
    return _submit((_Control.outputLevel, bus, 0), (value) {
      final current = value.outputSetup.of(bus);
      return value.copyWith(
        outputSetup: value.outputSetup.withBus(
          bus,
          current.copyWith(level: level.clamp(0.0, 1.0)),
        ),
      );
    });
  }

  /// Mutes one destination, preserving its level.
  Future<MixSettingsOutcome> setOutputMute({
    required int bus,
    required bool muted,
  }) {
    if (!_output(bus)) return _reject();
    return _submit((_Control.outputMute, bus, 0), (value) {
      final current = value.outputSetup.of(bus);
      return value.copyWith(
        outputSetup: value.outputSetup.withBus(
          bus,
          current.copyWith(muted: muted),
        ),
      );
    });
  }

  /// Switches Stereo/Mono without discarding the stored balance.
  Future<MixSettingsOutcome> setOutputMono({
    required int bus,
    required bool mono,
  }) {
    if (!_output(bus)) return _reject();
    return _submit((_Control.outputMono, bus, 0), (value) {
      final current = value.outputSetup.of(bus);
      return value.copyWith(
        outputSetup: value.outputSetup.withBus(
          bus,
          current.copyWith(mono: mono),
        ),
      );
    });
  }

  /// Stores balance even when the destination is currently Mono.
  Future<MixSettingsOutcome> setOutputBalance({
    required int bus,
    required double balance,
  }) {
    if (!_output(bus) || !balance.isFinite) return _reject();
    return _submit((_Control.outputBalance, bus, 0), (value) {
      final current = value.outputSetup.of(bus);
      return value.copyWith(
        outputSetup: value.outputSetup.withBus(
          bus,
          current.copyWith(balance: balance.clamp(-1.0, 1.0)),
        ),
      );
    });
  }

  /// Resets level and pan, retaining mute, Solo and recorded source images.
  Future<MixSettingsOutcome> resetMixer() => _submit((
    _Control.reset,
    0,
    0,
  ), (value) => value.copyWith(trackPans: const {}, laneLevels: const {}));

  /// Sets a temporary Solo flag; durable storage deliberately omits it.
  Future<MixSettingsOutcome> setTrackSolo({
    required int channel,
    required bool solo,
  }) {
    if (!_track(channel)) return _reject();
    return _submit(
      (solo ? _Control.soloOn : _Control.soloOff, channel, 0),
      _soloEdit(solo ? _Control.soloOn : _Control.soloOff, channel),
    );
  }

  /// Toggles against ordered shared intent, including unsubmitted presses.
  Future<MixSettingsOutcome> toggleTrackSolo({required int channel}) {
    if (!_track(channel)) return _reject();
    return _submit(
      (_Control.soloToggle, channel, 0),
      _soloEdit(_Control.soloToggle, channel),
    );
  }

  static bool _soloControl(_Control control) =>
      control == _Control.soloOn ||
      control == _Control.soloOff ||
      control == _Control.soloToggle;

  static bool _temporaryControl(_Control control) =>
      _soloControl(control) || control == _Control.clearSolo;

  static _Edit _soloEdit(_Control control, int channel) =>
      (value) => value.copyWith(
        trackSolos: {
          ...value.trackSolos,
          channel: switch (control) {
            _Control.soloOn => true,
            _Control.soloOff => false,
            _ => !(value.trackSolos[channel] ?? false),
          },
        },
      );

  /// Clears the temporary Solo set in the same ordered control stream.
  Future<MixSettingsOutcome> clearSolo() => _submit((
    _Control.clearSolo,
    0,
    0,
  ), (value) => value.copyWith(trackSolos: const {}));

  static bool _track(int channel) => channel >= 0 && channel < 8;
  static bool _input(int input) => input >= 0 && input < kMaxChannels;
  static bool _output(int bus) => bus >= 0 && bus < kMaxOutputBuses;
}
