import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

/// Confirmed recording policy and independent initialization availability.
final class RecordTimingState extends Equatable {
  const RecordTimingState({
    this.defaultTiming = RecordTiming.immediately,
    this.rememberedDivision = GridDivision.off,
    this.trackOverrides = const {},
    this.captureLocked = false,
    this.recordTimingReady = false,
  });
  final RecordTiming defaultTiming;
  final GridDivision rememberedDivision;
  final Map<int, RecordTiming> trackOverrides;
  final bool captureLocked;
  final bool recordTimingReady;

  @override
  List<Object?> get props => [
    defaultTiming,
    rememberedDivision,
    trackOverrides,
    captureLocked,
    recordTimingReady,
  ];
}

/// Serial owner of storage, native receipts, and Released timing projection.
class RecordTimingCubit extends Cubit<RecordTimingState>
    implements RecordTimingControl {
  RecordTimingCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const RecordTimingState()) {
    _subscription = repository.looperState.listen(_onLooperState);
    _receiptFailures = repository.recordTimingFailures.listen((result) {
      if (!_applying && !_closing) {
        _report(
          RecordTimingOutcome(
            repository.recordTimingRecoveryRequired
                ? RecordTimingStatus.recoveryRequired
                : RecordTimingStatus.rejected,
            engineResult: result,
          ),
        );
      }
    });
  }
  final LooperRepository _repository;
  final SettingsRepository _settings;
  late final StreamSubscription<LooperState> _subscription;
  late final StreamSubscription<EngineResult> _receiptFailures;
  Future<void>? _loadFuture;
  Future<void>? _closeFuture;
  Future<void> _tail = Future.value();
  bool _initialized = false;
  bool _closing = false;
  bool _applying = false;
  RecordTimingLifetime? _lifetime;
  final _revisions = <RecordTimingAddress, int>{};
  final _ordinary =
      StreamController<
        ({RecordTimingAddress address, RecordTiming? timing})
      >.broadcast(sync: true);
  final _failures = StreamController<RecordTimingOutcome>.broadcast(sync: true);
  RecordTimingOutcome _last = const RecordTimingOutcome(
    RecordTimingStatus.rejected,
  );
  RecordTimingCheckpoint? _storeRecovery;

  @override
  RecordTimingSnapshot? get recordTimingSnapshot => state.recordTimingReady
      ? RecordTimingSnapshot(
          defaultTiming: state.defaultTiming,
          rememberedDivision: state.rememberedDivision,
          trackOverrides: state.trackOverrides,
          captureLocked: state.captureLocked,
        )
      : null;
  @override
  RecordTimingSnapshot get durableRecordTimingSnapshot {
    final intent = _repository.recordTimingRestartIntent;
    return RecordTimingSnapshot(
      defaultTiming: intent.defaultTiming,
      rememberedDivision: intent.rememberedDivision,
      trackOverrides: intent.trackOverrides,
      captureLocked: _repository.recordTimingCaptureLocked,
    );
  }

  @override
  RecordTimingLifetime get recordTimingLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );
  @override
  int recordTimingRevision(RecordTimingAddress address) =>
      _revisions[address] ?? 0;
  @override
  Stream<({RecordTimingAddress address, RecordTiming? timing})>
  get ordinaryRecordTimingChanges => _ordinary.stream;
  Stream<RecordTimingOutcome> get recordTimingFailures => _failures.stream;

  RecordTimingOutcome _report(RecordTimingOutcome outcome) {
    if (outcome.status == RecordTimingStatus.superseded) return outcome;
    _last = outcome;
    if (outcome.status == RecordTimingStatus.recoveryRequired) {
      _publish(ready: false);
    }
    if (!outcome.isOk && !_closing && !isClosed) _failures.add(outcome);
    return outcome;
  }

  void _publish({bool? ready}) {
    if (_closing || isClosed) return;
    emit(
      RecordTimingState(
        defaultTiming: _repository.defaultRecordTiming,
        rememberedDivision: _repository.sessionTransport.quantizeDiv,
        trackOverrides: Map.unmodifiable(
          _repository.trackRecordTimingOverrides,
        ),
        captureLocked: _repository.recordTimingCaptureLocked,
        recordTimingReady: ready ?? _initialized,
      ),
    );
  }

  void _onLooperState(LooperState _) {
    if (_closing || isClosed) return;
    if (_applying) return;
    final replaced = _lifetime != recordTimingLifetime;
    if (replaced) {
      _lifetime = recordTimingLifetime;
      _revisions.clear();
    }
    if (_initialized &&
        _storeRecovery == null &&
        !_repository.recordTimingRecoveryRequired &&
        _repository.recordTimingSettingsSettled) {
      _publish();
      if (replaced && _storeRecovery == null) {
        _last = const RecordTimingOutcome(RecordTimingStatus.applied);
      }
    } else {
      _publish(ready: false);
    }
  }

  Future<T> _queue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load() => _loadFuture ??= _restore();
  Future<void> _restore() async {
    final startupSession = _repository.sessionRevision;
    try {
      final saved = await _settings.readRecordTimingCheckpoint();
      while (!_closing && !isClosed) {
        final origin = recordTimingLifetime;
        final done = await _queue(() async {
          if (_closing || isClosed) return true;
          if (origin != recordTimingLifetime) return false;
          _applying = true;
          try {
            await _repository.settleRecordTimingSettings();
            if (_closing || isClosed) return true;
            if (origin != recordTimingLifetime) return false;
            if (_repository.recordTimingRecoveryRequired) {
              _report(
                const RecordTimingOutcome(RecordTimingStatus.recoveryRequired),
              );
              return true;
            }
            if (origin.sessionRevision == startupSession) {
              final division = GridDivision.fromCode(saved.division ?? 0);
              var result = _repository.setRecordTimingSettings(
                defaultTiming: RecordTiming.of(
                  quantize: saved.quantize ?? false,
                  division: division,
                ),
                rememberedDivision: division,
                trackOverrides: {
                  for (final e in saved.trackOverrides.entries)
                    e.key: RecordTiming.values[e.value],
                },
              );
              if (result.isOk) {
                result = await _repository.settleRecordTimingSettings();
              }
              if (_closing || isClosed) return true;
              if (origin != recordTimingLifetime) return false;
              if (!result.isOk) {
                _report(
                  RecordTimingOutcome(
                    RecordTimingStatus.recoveryRequired,
                    engineResult: result,
                  ),
                );
                return true;
              }
            }
            _initialized = true;
            _lifetime = recordTimingLifetime;
            _publish();
            _report(const RecordTimingOutcome(RecordTimingStatus.applied));
            return true;
          } finally {
            _applying = false;
          }
        });
        if (done) return;
      }
    } on Object catch (error) {
      if (!_closing && !isClosed) {
        _report(
          RecordTimingOutcome(
            RecordTimingStatus.recoveryRequired,
            error: error,
          ),
        );
      }
    }
  }

  Future<RecordTimingOutcome> setTiming(RecordTiming timing) =>
      _write(const RecordTimingAddress.defaults(), timing, ordinary: true);
  Future<RecordTimingOutcome> setEnabled({required bool value}) async {
    await load();
    return setTiming(
      RecordTiming.of(quantize: value, division: state.rememberedDivision),
    );
  }

  @override
  Future<RecordTimingOutcome> setTrackTiming({
    required int channel,
    required RecordTiming? timing,
  }) => _write(RecordTimingAddress.track(channel), timing, ordinary: true);
  @override
  Future<RecordTimingOutcome> setControllerTiming(
    RecordTimingAddress address,
    RecordTiming timing, {
    required RecordTimingLifetime lifetime,
    required int revision,
    RecordTiming? releasedTiming,
  }) => _write(
    address,
    timing,
    lifetime: lifetime,
    revision: revision,
    releasedTiming: releasedTiming,
  );

  Future<RecordTimingOutcome> _write(
    RecordTimingAddress address,
    RecordTiming? timing, {
    bool ordinary = false,
    RecordTimingLifetime? lifetime,
    int? revision,
    RecordTiming? releasedTiming,
  }) async {
    if (!address.isValid || (address.channel == null && timing == null)) {
      return _report(
        const RecordTimingOutcome(
          RecordTimingStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    final origin = lifetime ?? recordTimingLifetime;
    await load();
    return _queue(() async {
      bool current() =>
          origin == recordTimingLifetime &&
          (revision == null || revision == recordTimingRevision(address));
      if (!current()) {
        return const RecordTimingOutcome(RecordTimingStatus.superseded);
      }
      if (_closing ||
          isClosed ||
          !_initialized ||
          _storeRecovery != null ||
          _repository.recordTimingRecoveryRequired ||
          _repository.recordTimingCaptureLocked) {
        return _report(
          RecordTimingOutcome(
            _storeRecovery != null || _repository.recordTimingRecoveryRequired
                ? RecordTimingStatus.recoveryRequired
                : RecordTimingStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      RecordTimingCheckpoint? checkpoint;
      var attempted = false;
      try {
        checkpoint = await _settings.readRecordTimingCheckpoint();
        if (!current() || _closing || isClosed) {
          return const RecordTimingOutcome(RecordTimingStatus.superseded);
        }
        final durable = releasedTiming ?? timing;
        final defaultAddress = address.channel == null;
        final overrides = Map.of(checkpoint.trackOverrides);
        if (!defaultAddress) {
          if (durable == null) {
            overrides.remove(address.channel);
          } else {
            overrides[address.channel!] = durable.code;
          }
        }
        final next = (
          quantize: defaultAddress ? durable!.quantize : checkpoint.quantize,
          division: defaultAddress && durable!.quantize
              ? durable.division.code
              : checkpoint.division,
          trackOverrides: Map<int, int>.unmodifiable(overrides),
        );
        attempted = true;
        await _settings.restoreRecordTimingCheckpoint(next);
        if (!current() || _closing || isClosed) {
          throw const _TimingRefusal(RecordTimingStatus.superseded);
        }
        if (_repository.recordTimingCaptureLocked) {
          throw const _TimingRefusal(RecordTimingStatus.rejected);
        }
        _applying = true;
        try {
          var result = defaultAddress
              ? _repository.setRecordTiming(
                  timing!,
                  releasedTiming: releasedTiming,
                )
              : _repository.setTrackRecordTiming(
                  channel: address.channel!,
                  timing: timing,
                  releasedTiming: releasedTiming,
                );
          if (result.isOk) {
            result = await _repository.settleRecordTimingSettings();
          }
          if (!current() || _closing || isClosed) {
            throw const _TimingRefusal(RecordTimingStatus.superseded);
          }
          if (!result.isOk) {
            throw _TimingRefusal(RecordTimingStatus.rejected, result: result);
          }
          _publish();
          if (ordinary) {
            _revisions[address] = recordTimingRevision(address) + 1;
            _ordinary.add((address: address, timing: timing));
          }
          return _report(
            RecordTimingOutcome(
              RecordTimingStatus.applied,
              deferred: !_repository.state.status.isConnected,
            ),
          );
        } finally {
          _applying = false;
        }
      } on Object catch (error) {
        if (attempted) {
          try {
            await _settings.restoreRecordTimingCheckpoint(checkpoint!);
          } on Object catch (rollbackError) {
            _storeRecovery = checkpoint;
            return _report(
              RecordTimingOutcome(
                RecordTimingStatus.recoveryRequired,
                error: rollbackError,
              ),
            );
          }
        }
        if (_repository.recordTimingRecoveryRequired) {
          return _report(
            RecordTimingOutcome(
              RecordTimingStatus.recoveryRequired,
              error: error,
            ),
          );
        }
        if (!current() || _closing || isClosed) {
          return const RecordTimingOutcome(RecordTimingStatus.superseded);
        }
        return _report(
          RecordTimingOutcome(
            _repository.recordTimingRecoveryRequired
                ? RecordTimingStatus.recoveryRequired
                : error is _TimingRefusal
                ? error.status
                : RecordTimingStatus.rejected,
            engineResult: error is _TimingRefusal ? error.result : null,
            error: error,
          ),
        );
      }
    });
  }

  Future<RecordTimingOutcome> flushRecordTiming() async {
    await load();
    await _tail;
    final wasSettled = _repository.recordTimingSettingsSettled;
    final result = await _repository.settleRecordTimingSettings();
    if (!_initialized ||
        !state.recordTimingReady ||
        _storeRecovery != null ||
        _repository.recordTimingRecoveryRequired) {
      return _report(
        RecordTimingOutcome(
          RecordTimingStatus.recoveryRequired,
          engineResult: result,
        ),
      );
    }
    if (!wasSettled && !result.isOk) {
      return _report(
        RecordTimingOutcome(
          RecordTimingStatus.rejected,
          engineResult: result,
        ),
      );
    }
    // A settled, exactly compensated edit still reports its refusal to the
    // caller. That past attempt is not an outstanding persistence obligation.
    return RecordTimingOutcome(
      RecordTimingStatus.applied,
      deferred: !_repository.state.status.isConnected,
    );
  }

  Future<RecordTimingOutcome> recoverRecordTiming() async {
    await load();
    final outcome = await _queue(() async {
      if (_closing || isClosed) {
        return const RecordTimingOutcome(RecordTimingStatus.rejected);
      }
      try {
        final recovery = _storeRecovery;
        if (recovery != null) {
          await _settings.restoreRecordTimingCheckpoint(recovery);
          if (_closing || isClosed) {
            return const RecordTimingOutcome(RecordTimingStatus.superseded);
          }
          _storeRecovery = null;
        }
        if (_repository.recordTimingRecoveryRequired) {
          final result = _repository.recoverRecordTimingSettings();
          if (!result.isOk) {
            return _report(
              RecordTimingOutcome(
                RecordTimingStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        if (!_initialized) {
          return const RecordTimingOutcome(RecordTimingStatus.applied);
        }
        if (!_repository.recordTimingSettingsSettled) {
          return _report(
            const RecordTimingOutcome(RecordTimingStatus.rejected),
          );
        }
        _publish();
        return _report(
          RecordTimingOutcome(
            RecordTimingStatus.applied,
            deferred: !_repository.state.status.isConnected,
          ),
        );
      } on Object catch (error) {
        return _report(
          RecordTimingOutcome(
            RecordTimingStatus.recoveryRequired,
            error: error,
          ),
        );
      }
    });
    if (outcome.isOk && !_initialized) {
      await _restore();
      return _last;
    }
    return outcome;
  }

  Future<T> runRecordTimingExclusive<T>(Future<T> Function() operation) async {
    await load();
    return _queue(() async {
      await _repository.settleRecordTimingSettings();
      if (!_initialized ||
          _closing ||
          isClosed ||
          _storeRecovery != null ||
          _repository.recordTimingRecoveryRequired) {
        throw StateError('Record timing is not confirmed');
      }
      return operation();
    });
  }

  @override
  Future<void> close() => _closeFuture ??= _close().then((_) => super.close());
  Future<void> _close() async {
    _closing = true;
    await _subscription.cancel();
    await _receiptFailures.cancel();
    await _loadFuture;
    await _tail;
    await _ordinary.close();
    await _failures.close();
  }
}

final class _TimingRefusal implements Exception {
  const _TimingRefusal(this.status, {this.result});
  final RecordTimingStatus status;
  final EngineResult? result;
}
