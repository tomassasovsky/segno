import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:settings_repository/settings_repository.dart';

/// Accepted global playback options and explicit track decay membership.
class PlaybackOptions extends Equatable {
  /// Creates the playback state; Decay remains unavailable until restored.
  const PlaybackOptions({
    this.overdubDecay = 0,
    this.defaultOneShot = false,
    this.trackOverdubDecayOverrides = const {},
    this.decayReady = false,
  });

  /// The default overdub decay in percent, from zero to 100.
  final int overdubDecay;

  /// Whether inheriting tracks play once instead of looping.
  final bool defaultOneShot;

  /// Explicit track values, including zero; absence means inheritance.
  final Map<int, int> trackOverdubDecayOverrides;

  /// Whether Decay has initialized independently of the Once preference.
  final bool decayReady;

  /// Returns a copy with the supplied accepted fields.
  PlaybackOptions copyWith({
    int? overdubDecay,
    bool? defaultOneShot,
    Map<int, int>? trackOverdubDecayOverrides,
    bool? decayReady,
  }) => PlaybackOptions(
    overdubDecay: overdubDecay ?? this.overdubDecay,
    defaultOneShot: defaultOneShot ?? this.defaultOneShot,
    trackOverdubDecayOverrides:
        trackOverdubDecayOverrides ?? this.trackOverdubDecayOverrides,
    decayReady: decayReady ?? this.decayReady,
  );

  @override
  List<Object?> get props => [
    overdubDecay,
    defaultOneShot,
    trackOverdubDecayOverrides,
    decayReady,
  ];
}

/// Owns verified decay intent and the existing global Once preference.
class PlaybackOptionsCubit extends Cubit<PlaybackOptions>
    implements DecayControl {
  /// Creates the application owner backed by the existing repositories.
  PlaybackOptionsCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const PlaybackOptions()) {
    _lifetime = decayLifetime;
    _subscription = repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  late final StreamSubscription<LooperState> _subscription;
  final _ordinary =
      StreamController<({DecayAddress address, int? percent})>.broadcast(
        sync: true,
      );
  final _failures = StreamController<DecayOutcome>.broadcast(sync: true);
  final _revisions = <DecayAddress, int>{};
  Future<void>? _loadFuture;
  Future<void>? _decayLoadFuture;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  late DecayLifetime _lifetime;
  int _onceEditRevision = 0;
  bool _closing = false;
  bool _applying = false;
  _DecayRecovery? _recovery;
  DecayOutcome _last = const DecayOutcome(DecayStatus.rejected);

  @override
  DecaySnapshot? get decaySnapshot => state.decayReady
      ? DecaySnapshot(
          defaultPercent: state.overdubDecay,
          trackOverrides: state.trackOverdubDecayOverrides,
        )
      : null;

  @override
  DecaySnapshot get durableDecaySnapshot {
    final intent = _repository.decayRestartIntent;
    return DecaySnapshot(
      defaultPercent: intent.defaultPercent,
      trackOverrides: intent.trackOverrides,
    );
  }

  @override
  DecayLifetime get decayLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  @override
  int decayRevision(DecayAddress address) => _revisions[address] ?? 0;

  @override
  Stream<({DecayAddress address, int? percent})> get ordinaryDecayChanges =>
      _ordinary.stream;

  /// Refusals for the application's visible recovery flow.
  Stream<DecayOutcome> get decayFailures => _failures.stream;

  DecayOutcome _report(DecayOutcome outcome) {
    if (outcome.status == DecayStatus.superseded) return outcome;
    _last = outcome;
    if (!outcome.isOk && !_closing && !isClosed) {
      _failures.add(outcome);
    }
    return outcome;
  }

  void _publish({bool ready = true}) {
    if (_closing || isClosed) return;
    emit(
      state.copyWith(
        overdubDecay: _repository.defaultOverdubDecay,
        trackOverdubDecayOverrides: _repository.trackOverdubDecayOverrides,
        defaultOneShot: _repository.defaultOneShot,
        decayReady: ready,
      ),
    );
  }

  void _onLooperState(LooperState _) {
    if (_closing || isClosed || _applying) return;
    if (_lifetime != decayLifetime) {
      _lifetime = decayLifetime;
      _revisions.clear();
      if (!_repository.decayReplayResult.isOk) {
        _report(
          DecayOutcome(
            DecayStatus.rejected,
            engineResult: _repository.decayReplayResult,
          ),
        );
      } else if (_recovery == null) {
        _last = const DecayOutcome(DecayStatus.applied);
      }
      // Session replacement adopts the repository's actual new intent.
      _publish(ready: _repository.decayReplayResult.isOk);
    } else if (state.decayReady) {
      _publish();
    } else {
      emit(state.copyWith(defaultOneShot: _repository.defaultOneShot));
    }
  }

  Future<T> _queue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Starts independent Decay and Once restoration exactly once.
  Future<void> load() => _loadFuture ??= Future.wait([
    _decayLoadFuture ??= _restoreDecay(),
    _restoreOnce(),
  ]).then((_) {});

  Future<void> _ready() async {
    _decayLoadFuture ??= _restoreDecay();
    await _decayLoadFuture;
  }

  Future<void> _restoreDecay() async {
    final lifetime = decayLifetime;
    try {
      // Read and validate every fixed slot before applying any value.
      final saved = await Future.wait([
        _settings.readDecayCheckpoint(channel: null),
        for (var channel = 0; channel < 8; channel++)
          _settings.readDecayCheckpoint(channel: channel),
      ]);
      if (_closing || isClosed) return;
      if (lifetime != decayLifetime) {
        _lifetime = decayLifetime;
        _publish(ready: _repository.decayReplayResult.isOk);
        return;
      }
      if (!_repository.decayReplayResult.isOk) {
        _report(
          DecayOutcome(
            DecayStatus.rejected,
            engineResult: _repository.decayReplayResult,
          ),
        );
        _publish(ready: false);
        return;
      }
      final prior = durableDecaySnapshot;
      _applying = true;
      try {
        var result = _repository.setOverdubDecay(saved.first ?? 0);
        for (var channel = 0; channel < 8 && result.isOk; channel++) {
          result = _repository.setTrackOverdubDecay(
            channel: channel,
            percent: saved[channel + 1],
          );
        }
        if (!result.isOk) {
          // A failed multi-scope initialization cannot remain partly audible.
          _repository
            ..stopEngine()
            ..setOverdubDecay(prior.defaultPercent);
          for (var channel = 0; channel < 8; channel++) {
            _repository.setTrackOverdubDecay(
              channel: channel,
              percent: prior.trackOverrides[channel],
            );
          }
          _lifetime = decayLifetime;
          _report(DecayOutcome(DecayStatus.rejected, engineResult: result));
          _publish(ready: false);
          return;
        }
        _lifetime = decayLifetime;
        _last = const DecayOutcome(DecayStatus.applied);
        _publish();
      } finally {
        _applying = false;
      }
    } on Object catch (error) {
      if (lifetime != decayLifetime || _closing || isClosed) return;
      _report(DecayOutcome(DecayStatus.rejected, error: error));
    }
  }

  Future<void> _restoreOnce() async {
    final session = _repository.sessionRevision;
    final revision = _onceEditRevision;
    final value = await _settings.loadDefaultOneShot();
    if (_closing || isClosed) return;
    if (session == _repository.sessionRevision &&
        revision == _onceEditRevision) {
      _repository.setDefaultOneShot(oneShot: value);
    }
    if (state.defaultOneShot != _repository.defaultOneShot) {
      emit(state.copyWith(defaultOneShot: _repository.defaultOneShot));
    }
  }

  /// Sets and persists ordinary default decay.
  Future<DecayOutcome> setOverdubDecay(int percent) =>
      _write(const DecayAddress.defaults(), percent, ordinary: true);

  @override
  Future<DecayOutcome> setTrackOverdubDecay({
    required int channel,
    required int? percent,
  }) => _write(DecayAddress.track(channel), percent, ordinary: true);

  @override
  Future<DecayOutcome> setControllerDecay(
    DecayAddress address,
    int percent, {
    required DecayLifetime lifetime,
    required int revision,
    int? releasedPercent,
  }) => _write(
    address,
    percent,
    lifetime: lifetime,
    revision: revision,
    releasedPercent: releasedPercent,
  );

  Future<DecayOutcome> _write(
    DecayAddress address,
    int? percent, {
    bool ordinary = false,
    DecayLifetime? lifetime,
    int? revision,
    int? releasedPercent,
  }) async {
    if (!address.isValid ||
        (address.channel == null && percent == null) ||
        (percent != null && (percent < 0 || percent > 100)) ||
        (releasedPercent != null &&
            (releasedPercent < 0 || releasedPercent > 100))) {
      return _report(
        const DecayOutcome(
          DecayStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    final origin = lifetime ?? decayLifetime;
    await _ready();
    return _queue(() async {
      bool current() =>
          origin == decayLifetime &&
          (revision == null || revision == decayRevision(address));
      if (!current()) return const DecayOutcome(DecayStatus.superseded);
      if (_closing || isClosed || !state.decayReady || _recovery != null) {
        return _report(
          DecayOutcome(
            _recovery == null
                ? DecayStatus.rejected
                : DecayStatus.recoveryRequired,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      int? checkpoint;
      var checkpointRead = false;
      var storeAttempted = false;
      try {
        checkpoint = await _settings.readDecayCheckpoint(
          channel: address.channel,
        );
        checkpointRead = true;
        if (!current() || _closing || isClosed) {
          return const DecayOutcome(DecayStatus.superseded);
        }
        final durable = releasedPercent ?? percent;
        if (checkpoint != durable) {
          storeAttempted = true;
          await _settings.restoreDecayCheckpoint(
            channel: address.channel,
            percent: durable,
          );
        }
        if (!current() || _closing || isClosed) {
          throw const _DecayRefusal(DecayStatus.superseded);
        }
        final prior = durableDecaySnapshot;
        final live = decaySnapshot!;
        final existing = address.channel == null
            ? live.defaultPercent
            : live.trackOverrides[address.channel];
        _applying = true;
        try {
          final result = existing == percent && !ordinary
              ? EngineResult.ok
              : address.channel == null
              ? _repository.setOverdubDecay(percent!)
              : _repository.setTrackOverdubDecay(
                  channel: address.channel!,
                  percent: percent,
                );
          if (!result.isOk) {
            throw _DecayRefusal(DecayStatus.rejected, result: result);
          }
          final overrides = Map<int, int>.of(prior.trackOverrides);
          if (address.channel case final channel?) {
            if (durable == null) {
              overrides.remove(channel);
            } else {
              overrides[channel] = durable;
            }
          }
          _repository.setDecayRestartIntent(
            defaultPercent: address.channel == null
                ? durable!
                : prior.defaultPercent,
            trackOverrides: overrides,
          );
          _publish();
          if (ordinary) {
            _revisions[address] = decayRevision(address) + 1;
            _ordinary.add((address: address, percent: percent));
          }
          return _report(
            DecayOutcome(
              DecayStatus.applied,
              deferred: !_repository.state.status.isConnected,
            ),
          );
        } finally {
          _applying = false;
        }
      } on Object catch (error) {
        if (checkpointRead && storeAttempted) {
          try {
            await _settings.restoreDecayCheckpoint(
              channel: address.channel,
              percent: checkpoint,
            );
          } on Object catch (rollbackError) {
            _recovery = _DecayRecovery(address, checkpoint, origin);
            return _report(
              DecayOutcome(DecayStatus.recoveryRequired, error: rollbackError),
            );
          }
        }
        // A delayed storage exception belongs to its original session too.
        // Once its scalar is restored, do not poison a replacement's outcome.
        if (!current() || _closing || isClosed) {
          return const DecayOutcome(DecayStatus.superseded);
        }
        return _report(
          DecayOutcome(
            error is _DecayRefusal ? error.status : DecayStatus.rejected,
            engineResult: error is _DecayRefusal ? error.result : null,
            error: error,
          ),
        );
      }
    });
  }

  /// Waits admitted decay writes and reports unresolved refusal or recovery.
  Future<DecayOutcome> flushDecay() async {
    await _ready();
    await _tail;
    return state.decayReady
        ? _last
        : _report(const DecayOutcome(DecayStatus.rejected));
  }

  /// Explicitly repairs an exact scalar checkpoint, without replaying old
  /// audio.
  Future<DecayOutcome> recoverDecay() async {
    await _ready();
    return _queue(() async {
      if (_closing || isClosed) return const DecayOutcome(DecayStatus.rejected);
      final recovery = _recovery;
      if (recovery != null) {
        try {
          await _settings.restoreDecayCheckpoint(
            channel: recovery.address.channel,
            percent: recovery.checkpoint,
          );
          if (_closing || isClosed) {
            return const DecayOutcome(DecayStatus.superseded);
          }
          _recovery = null;
          if (recovery.lifetime != decayLifetime) _revisions.clear();
          // Storage repair never applies the old record to a replacement rig.
          _lifetime = decayLifetime;
          _publish(ready: _repository.decayReplayResult.isOk);
        } on Object catch (error) {
          return _report(
            DecayOutcome(DecayStatus.recoveryRequired, error: error),
          );
        }
      }
      if (!_repository.decayReplayResult.isOk) {
        return _report(
          DecayOutcome(
            DecayStatus.rejected,
            engineResult: _repository.decayReplayResult,
          ),
        );
      }
      if (!state.decayReady) {
        await _restoreDecay();
        return _last;
      }
      return _report(const DecayOutcome(DecayStatus.applied));
    });
  }

  /// Session lock order is Mixer, Click, then Decay; startup precedes the
  /// queue.
  Future<T> runDecayExclusive<T>(Future<T> Function() operation) async {
    await _ready();
    return _queue(() async {
      if (_closing || isClosed || !state.decayReady || _recovery != null) {
        throw StateError('Decay is unavailable for session capture');
      }
      return operation();
    });
  }

  /// Preserves the existing, independently initialized Once preference.
  Future<void> setDefaultOneShot({required bool value}) async {
    _onceEditRevision++;
    if (!_repository.setDefaultOneShot(oneShot: value).isOk) return;
    if (!_closing && !isClosed) emit(state.copyWith(defaultOneShot: value));
    await _settings.saveDefaultOneShot(oneShot: value);
  }

  @override
  Future<void> close() => _closeFuture ??= _close().then((_) => super.close());

  Future<void> _close() async {
    _closing = true;
    await _subscription.cancel();
    await _loadFuture;
    await _decayLoadFuture;
    await _tail;
    await _ordinary.close();
    await _failures.close();
  }
}

final class _DecayRecovery {
  const _DecayRecovery(this.address, this.checkpoint, this.lifetime);
  final DecayAddress address;
  final int? checkpoint;
  final DecayLifetime lifetime;
}

final class _DecayRefusal implements Exception {
  const _DecayRefusal(this.status, {this.result});
  final DecayStatus status;
  final EngineResult? result;
}
