import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/playback_options.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns verified decay intent and the existing global Once preference.
class PlaybackSettings implements DecayControl, OneShotControl {
  /// Creates the application owner backed by the existing repositories.
  PlaybackSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings {
    _lifetime = decayLifetime;
    _subscription = repository.looperState.listen(_onLooperState);
  }

  final _states = StreamController<PlaybackOptions>.broadcast(sync: true);
  PlaybackOptions _state = const PlaybackOptions();

  /// Current accepted settings and independent field readiness.
  PlaybackOptions get state => _state;

  /// Accepted settings and readiness changes for borrowed views.
  Stream<PlaybackOptions> get stream => _states.stream;

  void _emit(PlaybackOptions next) {
    if (_states.isClosed || next == _state) return;
    _state = next;
    _states.add(next);
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
  Future<void>? _oneShotLoadFuture;
  bool _oneShotInitialized = false;
  final _oneShotRevisions = <OneShotAddress, int>{};
  final _ordinaryOneShot =
      StreamController<({OneShotAddress address, bool? oneShot})>.broadcast(
        sync: true,
      );
  final _oneShotFailures = StreamController<OneShotOutcome>.broadcast(
    sync: true,
  );
  OneShotOutcome _lastOneShot = const OneShotOutcome(OneShotStatus.rejected);
  _OneShotRecovery? _oneShotRecovery;
  OneShotLifetime? _oneShotLifetime;

  bool _closing = false;
  bool _applying = false;
  _DecayRecovery? _recovery;
  DecayOutcome _last = const DecayOutcome(DecayStatus.rejected);

  @override
  DecaySnapshot? get decaySnapshot => state.decaySnapshot;

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
    if (!outcome.isOk && !_closing && !_states.isClosed) {
      _failures.add(outcome);
    }
    return outcome;
  }

  void _publish({bool ready = true}) {
    if (_closing || _states.isClosed) return;
    _emit(
      state.copyWith(
        overdubDecay: _repository.defaultOverdubDecay,
        trackOverdubDecayOverrides: _repository.trackOverdubDecayOverrides,
        decayReady: ready,
      ),
    );
  }

  void _onLooperState(LooperState _) {
    if (_closing || _states.isClosed || _applying) return;
    _syncOneShot();
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
    _oneShotLoadFuture ??= _restoreOnce(),
  ]).then((_) {});

  Future<void> _ready() async {
    _decayLoadFuture ??= _restoreDecay();
    await _decayLoadFuture;
  }

  Future<void> _restoreDecay({bool insideQueue = false}) async {
    final lifetime = decayLifetime;
    try {
      // Read and validate every fixed slot before applying any value.
      final saved = await Future.wait([
        _settings.readDecayCheckpoint(channel: null),
        for (var channel = 0; channel < 8; channel++)
          _settings.readDecayCheckpoint(channel: channel),
      ]);
      Future<void> apply() async {
        if (_closing || _states.isClosed) return;
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
      }

      if (insideQueue) {
        await apply();
      } else {
        await _queue(apply);
      }
    } on Object catch (error) {
      if (lifetime != decayLifetime || _closing || _states.isClosed) return;
      _report(DecayOutcome(DecayStatus.rejected, error: error));
    }
  }

  Future<void> _restoreOnce() async {
    final startupSession = oneShotLifetime.sessionRevision;
    try {
      final saved = await Future.wait([
        _settings.readOneShotCheckpoint(channel: null),
        for (var c = 0; c < 8; c++) _settings.readOneShotCheckpoint(channel: c),
      ]);
      // Device replacement can occur while reading or awaiting a receipt.
      // Retry admission for that device; a newer session owns its own vector.
      while (!_closing && !_states.isClosed) {
        final origin = oneShotLifetime;
        final finished = await _queue(() async {
          if (_closing || _states.isClosed) return true;
          if (origin != oneShotLifetime) return false;
          _applying = true;
          try {
            final prior = await _repository.settleOneShot();
            if (_closing || _states.isClosed) return true;
            if (origin != oneShotLifetime) return false;
            if (!prior.isOk || _repository.oneShotRecoveryRequired) {
              _reportOneShot(
                const OneShotOutcome(OneShotStatus.recoveryRequired),
              );
              return true;
            }
            if (origin.sessionRevision == startupSession) {
              var result = _repository.setOneShotSnapshot(
                defaultOneShot: saved.first ?? false,
                trackOverrides: {
                  for (var c = 0; c < 8; c++)
                    if (saved[c + 1] != null) c: saved[c + 1]!,
                },
              );
              if (result.isOk) result = await _repository.settleOneShot();
              if (_closing || _states.isClosed) return true;
              if (origin != oneShotLifetime) return false;
              if (!result.isOk) {
                _reportOneShot(
                  OneShotOutcome(
                    _repository.oneShotRecoveryRequired
                        ? OneShotStatus.recoveryRequired
                        : OneShotStatus.rejected,
                    engineResult: result,
                  ),
                );
                return true;
              }
            }
            _oneShotLifetime = oneShotLifetime;
            _oneShotInitialized = true;
            _publishOneShot();
            _reportOneShot(const OneShotOutcome(OneShotStatus.applied));
            return true;
          } finally {
            _applying = false;
          }
        });
        if (finished) return;
      }
    } on Object catch (error) {
      if (!_closing && !_states.isClosed) {
        _reportOneShot(OneShotOutcome(OneShotStatus.rejected, error: error));
      }
    }
  }

  Future<void> _readyOneShot() async {
    _oneShotLoadFuture ??= _restoreOnce();
    await _oneShotLoadFuture;
  }

  @override
  OneShotSnapshot? get oneShotSnapshot => state.oneShotSnapshot;

  @override
  OneShotSnapshot get durableOneShotSnapshot {
    final intent = _repository.oneShotRestartIntent;
    return OneShotSnapshot(
      defaultOneShot: intent.defaultOneShot,
      trackOverrides: intent.trackOverrides,
    );
  }

  @override
  OneShotLifetime get oneShotLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  @override
  int oneShotRevision(OneShotAddress address) =>
      _oneShotRevisions[address] ?? 0;

  @override
  Stream<({OneShotAddress address, bool? oneShot})>
  get ordinaryOneShotChanges => _ordinaryOneShot.stream;

  /// Playback refusals for the application's visible recovery flow.
  Stream<OneShotOutcome> get oneShotFailures => _oneShotFailures.stream;

  OneShotOutcome _reportOneShot(OneShotOutcome outcome) {
    if (outcome.status == OneShotStatus.superseded) return outcome;
    _lastOneShot = outcome;
    if (!outcome.isOk && !_closing && !_states.isClosed) {
      _oneShotFailures.add(outcome);
    }
    return outcome;
  }

  void _publishOneShot() {
    if (_closing || _states.isClosed) return;
    _emit(
      state.copyWith(
        defaultOneShot: _repository.defaultOneShot,
        trackOneShotOverrides: Map.unmodifiable(
          _repository.trackOneShotOverrides,
        ),
        oneShotReady: true,
        overdubDecay: state.decayReady ? _repository.defaultOverdubDecay : null,
        trackOverdubDecayOverrides: state.decayReady
            ? _repository.trackOverdubDecayOverrides
            : null,
      ),
    );
  }

  void _syncOneShot() {
    final replaced = _oneShotLifetime != oneShotLifetime;
    if (replaced) {
      _oneShotLifetime = oneShotLifetime;
      _oneShotRevisions.clear();
    }
    if (_repository.oneShotRecoveryRequired) {
      if (_lastOneShot.status != OneShotStatus.recoveryRequired) {
        _reportOneShot(const OneShotOutcome(OneShotStatus.recoveryRequired));
      }
    } else if (_oneShotInitialized) {
      if (_repository.oneShotSettingsSettled) {
        _publishOneShot();
        if (replaced && _oneShotRecovery == null) {
          _lastOneShot = const OneShotOutcome(OneShotStatus.applied);
        }
      } else if (replaced) {
        _emit(state.copyWith(oneShotReady: false));
      }
    }
  }

  /// Sets and verifies ordinary default Playback through the shared queue.
  Future<OneShotOutcome> setDefaultOneShot({required bool value}) =>
      _writeOneShot(const OneShotAddress.defaults(), value, ordinary: true);

  @override
  Future<OneShotOutcome> setTrackOneShot({
    required int channel,
    required bool? oneShot,
  }) => _writeOneShot(OneShotAddress.track(channel), oneShot, ordinary: true);

  @override
  Future<OneShotOutcome> setControllerOneShot(
    OneShotAddress address, {
    required bool oneShot,
    required OneShotLifetime lifetime,
    required int revision,
    bool? releasedOneShot,
  }) => _writeOneShot(
    address,
    oneShot,
    lifetime: lifetime,
    revision: revision,
    releasedOneShot: releasedOneShot,
  );

  Future<OneShotOutcome> _writeOneShot(
    OneShotAddress address,
    bool? oneShot, {
    bool ordinary = false,
    OneShotLifetime? lifetime,
    int? revision,
    bool? releasedOneShot,
  }) async {
    if (!address.isValid || (address.channel == null && oneShot == null)) {
      return _reportOneShot(
        const OneShotOutcome(
          OneShotStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    final origin = lifetime ?? oneShotLifetime;
    await _readyOneShot();
    return _queue(() async {
      bool current() =>
          origin == oneShotLifetime &&
          (revision == null || revision == oneShotRevision(address));
      if (!current()) return const OneShotOutcome(OneShotStatus.superseded);
      if (_closing ||
          _states.isClosed ||
          !state.oneShotReady ||
          _oneShotRecovery != null ||
          _repository.oneShotRecoveryRequired) {
        return _reportOneShot(
          OneShotOutcome(
            _oneShotRecovery != null || _repository.oneShotRecoveryRequired
                ? OneShotStatus.recoveryRequired
                : OneShotStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      bool? checkpoint;
      var storeAttempted = false;
      try {
        checkpoint = await _settings.readOneShotCheckpoint(
          channel: address.channel,
        );
        if (!current() || _closing || _states.isClosed) {
          return const OneShotOutcome(OneShotStatus.superseded);
        }
        final durable = releasedOneShot ?? oneShot;
        if (checkpoint != durable) {
          storeAttempted = true;
          await _settings.restoreOneShotCheckpoint(
            channel: address.channel,
            oneShot: durable,
          );
        }
        if (!current() || _closing || _states.isClosed) {
          throw const _OneShotRefusal(OneShotStatus.superseded);
        }
        _applying = true;
        try {
          var result = address.channel == null
              ? _repository.setDefaultOneShot(
                  oneShot: oneShot!,
                  releasedOneShot: releasedOneShot,
                )
              : _repository.setOneShot(
                  channel: address.channel!,
                  oneShot: oneShot,
                  releasedOneShot: releasedOneShot,
                );
          if (result.isOk) result = await _repository.settleOneShot();
          if (!result.isOk) {
            throw _OneShotRefusal(OneShotStatus.rejected, result: result);
          }
          if (!current() || _closing || _states.isClosed) {
            throw const _OneShotRefusal(OneShotStatus.superseded);
          }
          _publishOneShot();
          if (ordinary) {
            _oneShotRevisions[address] = oneShotRevision(address) + 1;
            _ordinaryOneShot.add((address: address, oneShot: oneShot));
          }
          return _reportOneShot(
            OneShotOutcome(
              OneShotStatus.applied,
              deferred: !_repository.state.status.isConnected,
            ),
          );
        } finally {
          _applying = false;
        }
      } on Object catch (error) {
        if (storeAttempted) {
          try {
            await _settings.restoreOneShotCheckpoint(
              channel: address.channel,
              oneShot: checkpoint,
            );
          } on Object catch (rollbackError) {
            _oneShotRecovery = _OneShotRecovery(
              address,
              origin,
              checkpoint: checkpoint,
            );
            return _reportOneShot(
              OneShotOutcome(
                OneShotStatus.recoveryRequired,
                error: rollbackError,
              ),
            );
          }
        }
        if (_repository.oneShotRecoveryRequired) {
          return _reportOneShot(
            OneShotOutcome(OneShotStatus.recoveryRequired, error: error),
          );
        }
        if (!current() || _closing || _states.isClosed) {
          return const OneShotOutcome(OneShotStatus.superseded);
        }
        return _reportOneShot(
          OneShotOutcome(
            error is _OneShotRefusal ? error.status : OneShotStatus.rejected,
            engineResult: error is _OneShotRefusal ? error.result : null,
            error: error,
          ),
        );
      }
    });
  }

  /// Drains admitted writes and observes autonomous replay without new input.
  Future<OneShotOutcome> flushOneShot() async {
    await _readyOneShot();
    await _tail;
    final result = await _repository.settleOneShot();
    if (!result.isOk ||
        _repository.oneShotRecoveryRequired ||
        _oneShotRecovery != null) {
      return _reportOneShot(
        OneShotOutcome(OneShotStatus.recoveryRequired, engineResult: result),
      );
    }
    return state.oneShotReady
        ? _lastOneShot
        : _reportOneShot(const OneShotOutcome(OneShotStatus.rejected));
  }

  /// Repairs exact storage and current repository recovery, never an old rig.
  Future<OneShotOutcome> recoverOneShot() async {
    await _readyOneShot();
    if (!_oneShotInitialized &&
        !_repository.oneShotRecoveryRequired &&
        _oneShotRecovery == null) {
      await _restoreOnce();
      return _lastOneShot;
    }
    final outcome = await _queue(() async {
      if (_closing || _states.isClosed) {
        return const OneShotOutcome(OneShotStatus.rejected);
      }
      final recovery = _oneShotRecovery;
      try {
        if (recovery != null) {
          await _settings.restoreOneShotCheckpoint(
            channel: recovery.address.channel,
            oneShot: recovery.checkpoint,
          );
          if (_closing || _states.isClosed) {
            return const OneShotOutcome(OneShotStatus.superseded);
          }
          _oneShotRecovery = null;
        }
        if (_repository.oneShotRecoveryRequired) {
          final result = _repository.recoverOneShotSettings();
          if (!result.isOk) {
            return _reportOneShot(
              OneShotOutcome(
                OneShotStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        if (!_oneShotInitialized) {
          // Recovery repairs the engine, not unvalidated startup settings.
          // Their staged reads must run outside this serial queue.
          return const OneShotOutcome(OneShotStatus.applied);
        }
        _publishOneShot();
        return _reportOneShot(
          OneShotOutcome(
            OneShotStatus.applied,
            deferred: !_repository.state.status.isConnected,
          ),
        );
      } on Object catch (error) {
        return _reportOneShot(
          OneShotOutcome(OneShotStatus.recoveryRequired, error: error),
        );
      }
    });
    if (outcome.isOk && !_oneShotInitialized) {
      await _restoreOnce();
      return _lastOneShot;
    }
    return outcome;
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
      if (_closing ||
          _states.isClosed ||
          !state.decayReady ||
          _recovery != null) {
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
        if (!current() || _closing || _states.isClosed) {
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
        if (!current() || _closing || _states.isClosed) {
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
        if (!current() || _closing || _states.isClosed) {
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
      if (_closing || _states.isClosed) {
        return const DecayOutcome(DecayStatus.rejected);
      }
      final recovery = _recovery;
      if (recovery != null) {
        try {
          await _settings.restoreDecayCheckpoint(
            channel: recovery.address.channel,
            percent: recovery.checkpoint,
          );
          if (_closing || _states.isClosed) {
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
        await _restoreDecay(insideQueue: true);
        return _last;
      }
      return _report(const DecayOutcome(DecayStatus.applied));
    });
  }

  /// Mixer, Click, then one Playback queue; initialization precedes its lock.
  Future<T> runPlaybackExclusive<T>(Future<T> Function() operation) async {
    await Future.wait([_ready(), _readyOneShot()]);
    return _queue(() async {
      if (_closing ||
          _states.isClosed ||
          !state.decayReady ||
          !state.oneShotReady ||
          _recovery != null ||
          _oneShotRecovery != null ||
          _repository.oneShotRecoveryRequired) {
        throw StateError('Playback is unavailable for session capture');
      }
      final settled = await _repository.settleOneShot();
      if (!settled.isOk) throw StateError('Playback receipt is unavailable');
      return operation();
    });
  }

  /// Drains admitted transactions and disposes this application owner.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _subscription.cancel();
    await _loadFuture;
    await _decayLoadFuture;
    await _oneShotLoadFuture;
    await _tail;
    await _ordinary.close();
    await _failures.close();
    await _ordinaryOneShot.close();
    await _oneShotFailures.close();
    await _states.close();
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

final class _OneShotRecovery {
  const _OneShotRecovery(
    this.address,
    this.lifetime, {
    required this.checkpoint,
  });
  final OneShotAddress address;
  final bool? checkpoint;
  final OneShotLifetime lifetime;
}

final class _OneShotRefusal implements Exception {
  const _OneShotRefusal(this.status, {this.result});
  final OneShotStatus status;
  final EngineResult? result;
}
