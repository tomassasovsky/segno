import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:settings_repository/settings_repository.dart';

/// Global record-behavior options applied to the [LooperRepository] and
/// persisted via [SettingsRepository].
class RecordOptions extends Equatable {
  /// Creates a [RecordOptions].
  const RecordOptions({
    this.recDub = false,
    this.autoRecord = false,
    this.defaultMultiple = 0,
    this.defaultLengthBars = 0,
    this.recordLengthReady = false,
    this.trackLengthPresetOverrides = const {},
    this.recordLengthMode = LooperMode.multi,
    this.recordLengthCaptureLocked = false,
  });

  /// When `true`, a record press finalizing a recording continues into overdub
  /// instead of playback (the second-press "rec/dub" mode).
  final bool recDub;

  /// When `true`, recording is sound-activated: a record press on an empty
  /// track waits and starts when the input crosses the threshold.
  final bool autoRecord;

  /// The global default loop length used by inheriting tracks (`0` = auto).
  final int defaultMultiple;

  /// The default length preset for a defining recording (`0` = Auto, else
  /// `1..64` bars; accepted design, Length & quantize). Tracks follow it
  /// unless they carry their own override.
  final int defaultLengthBars;
  final bool recordLengthReady;
  final Map<int, int> trackLengthPresetOverrides;
  final LooperMode recordLengthMode;
  final bool recordLengthCaptureLocked;

  /// Returns a copy with the given overrides.
  RecordOptions copyWith({
    bool? recDub,
    bool? autoRecord,
    int? defaultMultiple,
    int? defaultLengthBars,
    bool? recordLengthReady,
    Map<int, int>? trackLengthPresetOverrides,
    LooperMode? recordLengthMode,
    bool? recordLengthCaptureLocked,
  }) => RecordOptions(
    recDub: recDub ?? this.recDub,
    autoRecord: autoRecord ?? this.autoRecord,
    defaultMultiple: defaultMultiple ?? this.defaultMultiple,
    defaultLengthBars: defaultLengthBars ?? this.defaultLengthBars,
    recordLengthReady: recordLengthReady ?? this.recordLengthReady,
    trackLengthPresetOverrides:
        trackLengthPresetOverrides ?? this.trackLengthPresetOverrides,
    recordLengthMode: recordLengthMode ?? this.recordLengthMode,
    recordLengthCaptureLocked:
        recordLengthCaptureLocked ?? this.recordLengthCaptureLocked,
  );

  @override
  List<Object?> get props => [
    recDub,
    autoRecord,
    defaultMultiple,
    defaultLengthBars,
    recordLengthReady,
    trackLengthPresetOverrides,
    recordLengthMode,
    recordLengthCaptureLocked,
  ];
}

/// Owns the global record-behavior options: applies them to the repository and
/// persists them. Defaults to both off (the classic rec → play behavior).
class RecordOptionsCubit extends Cubit<RecordOptions>
    implements RecordLengthControl {
  RecordOptionsCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const RecordOptions()) {
    _subscription = repository.looperState.listen(_onLooperState);
    _receiptFailures = repository.lengthSettingsFailures.listen((result) {
      if (!_applying && !_closing) {
        _report(
          RecordLengthOutcome(
            repository.lengthRecoveryRequired
                ? RecordLengthStatus.recoveryRequired
                : RecordLengthStatus.rejected,
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
  Future<void>? _lengthLoad;
  Future<void>? _otherLoad;
  Future<void>? _closeFuture;
  Future<void> _tail = Future.value();
  int _userEditRevision = 0;
  bool _initialized = false;
  bool _closing = false;
  bool _applying = false;
  RecordLengthLifetime? _lifetime;
  final _revisions = <RecordLengthAddress, int>{};
  final _ordinary =
      StreamController<({RecordLengthAddress address, int? bars})>.broadcast(
        sync: true,
      );
  final _failures = StreamController<RecordLengthOutcome>.broadcast(sync: true);
  RecordLengthOutcome _last = const RecordLengthOutcome(
    RecordLengthStatus.rejected,
  );
  _LengthStoreRecovery? _recovery;

  @override
  RecordLengthSnapshot? get recordLengthSnapshot => state.recordLengthReady
      ? RecordLengthSnapshot(
          defaultBars: state.defaultLengthBars,
          trackOverrides: state.trackLengthPresetOverrides,
          mode: state.recordLengthMode,
          captureLocked: state.recordLengthCaptureLocked,
        )
      : null;
  @override
  RecordLengthSnapshot get durableRecordLengthSnapshot {
    final intent = _repository.lengthRestartIntent;
    return RecordLengthSnapshot(
      defaultBars: intent.defaultBars,
      trackOverrides: intent.trackOverrides,
      mode: intent.mode,
      captureLocked: _repository.recordLengthCaptureLocked,
    );
  }

  @override
  RecordLengthLifetime get recordLengthLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );
  @override
  int recordLengthRevision(RecordLengthAddress address) =>
      _revisions[address] ?? 0;
  @override
  Stream<({RecordLengthAddress address, int? bars})>
  get ordinaryRecordLengthChanges => _ordinary.stream;
  Stream<RecordLengthOutcome> get recordLengthFailures => _failures.stream;

  RecordLengthOutcome _report(RecordLengthOutcome outcome) {
    if (outcome.status == RecordLengthStatus.superseded) return outcome;
    _last = outcome;
    if (!outcome.isOk && !_closing && !isClosed) _failures.add(outcome);
    return outcome;
  }

  void _publish({bool? ready}) {
    if (_closing || isClosed) return;
    emit(
      state.copyWith(
        defaultLengthBars: _repository.sessionTransport.defaultLengthPresetBars,
        trackLengthPresetOverrides: Map.unmodifiable(
          _repository.trackLengthPresetOverrides,
        ),
        recordLengthMode: _repository.sessionTransport.looperMode,
        recordLengthCaptureLocked: _repository.recordLengthCaptureLocked,
        recordLengthReady: ready ?? _initialized,
      ),
    );
  }

  void _onLooperState(LooperState looper) {
    if (_closing || isClosed) return;
    emit(
      state.copyWith(
        recDub: looper.transport.recDub,
        autoRecord: looper.transport.autoRecord,
        defaultMultiple: looper.transport.defaultMultiple,
        recordLengthCaptureLocked: _repository.recordLengthCaptureLocked,
      ),
    );
    if (_applying) return;
    final replaced = _lifetime != recordLengthLifetime;
    if (replaced) {
      _lifetime = recordLengthLifetime;
      _revisions.clear();
    }
    if (_initialized && !_repository.lengthRecoveryRequired) {
      if (_repository.lengthSettingsSettled) {
        _publish();
        if (replaced && _recovery == null) {
          _last = const RecordLengthOutcome(RecordLengthStatus.applied);
        }
      } else if (replaced) {
        _publish(ready: false);
      }
    }
  }

  Future<T> _queue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load() => _loadFuture ??= Future.wait([
    _otherLoad ??= _restoreOther(),
    _lengthLoad ??= _restoreLength(),
  ]).then((_) {});
  Future<void> _ready() async {
    _lengthLoad ??= _restoreLength();
    await _lengthLoad;
  }

  Future<void> _restoreOther() async {
    final session = _repository.sessionRevision;
    final revision = _userEditRevision;
    final recDub = await _settings.loadRecDub();
    final multiple = await _settings.loadDefaultMultiple();
    if (_closing || isClosed) return;
    if (session != _repository.sessionRevision ||
        revision != _userEditRevision) {
      return;
    }
    if (_repository.setRecDub(enabled: recDub).isOk) {
      emit(state.copyWith(recDub: recDub));
    }
    if (_repository.setDefaultMultiple(multiple: multiple).isOk) {
      emit(state.copyWith(defaultMultiple: multiple));
    }
  }

  Future<void> _restoreLength() async {
    final startupSession = recordLengthLifetime.sessionRevision;
    try {
      final saved = await Future.wait([
        _settings.readLooperModeCheckpoint(),
        _settings.readRecordLengthCheckpoint(channel: null),
        for (var c = 0; c < 8; c++)
          _settings.readRecordLengthCheckpoint(channel: c),
      ]);
      while (!_closing && !isClosed) {
        final origin = recordLengthLifetime;
        final done = await _queue(() async {
          if (_closing || isClosed) return true;
          if (origin != recordLengthLifetime) return false;
          _applying = true;
          try {
            await _repository.settleLengthSettings();
            if (_closing || isClosed) return true;
            if (origin != recordLengthLifetime) return false;
            if (_repository.lengthRecoveryRequired) {
              _report(
                const RecordLengthOutcome(RecordLengthStatus.recoveryRequired),
              );
              return true;
            }
            if (origin.sessionRevision == startupSession) {
              var result = _repository.setLengthSettings(
                mode: LooperMode.fromCode(saved[0] ?? 0),
                defaultBars: saved[1] ?? 0,
                overrides: {
                  for (var c = 0; c < 8; c++)
                    if (saved[c + 2] != null) c: saved[c + 2]!,
                },
              );
              if (result.isOk) {
                result = await _repository.settleLengthSettings();
              }
              if (_closing || isClosed) return true;
              if (origin != recordLengthLifetime) return false;
              if (!result.isOk) {
                _report(
                  RecordLengthOutcome(
                    RecordLengthStatus.recoveryRequired,
                    engineResult: result,
                  ),
                );
                return true;
              }
            }
            _initialized = true;
            _lifetime = recordLengthLifetime;
            _publish();
            _report(const RecordLengthOutcome(RecordLengthStatus.applied));
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
          RecordLengthOutcome(
            RecordLengthStatus.recoveryRequired,
            error: error,
          ),
        );
      }
    }
  }

  Future<RecordLengthOutcome> setDefaultLengthBars(int bars) => _write(
    const RecordLengthAddress.defaults(),
    bars.clamp(0, 64),
    ordinary: true,
  );
  @override
  Future<RecordLengthOutcome> setTrackRecordLength({
    required int channel,
    required int? bars,
  }) => _write(RecordLengthAddress.track(channel), bars, ordinary: true);
  @override
  Future<RecordLengthOutcome> setControllerRecordLength(
    RecordLengthAddress address,
    int bars, {
    required RecordLengthLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) => _write(
    address,
    bars,
    lifetime: lifetime,
    revision: revision,
    releasedBars: releasedBars,
  );
  @override
  Future<RecordLengthOutcome> setLooperMode(LooperMode mode) =>
      _write(null, null, mode: mode);

  Future<int?> _checkpoint(RecordLengthAddress? address) => address == null
      ? _settings.readLooperModeCheckpoint()
      : _settings.readRecordLengthCheckpoint(channel: address.channel);
  Future<void> _restoreScalar(RecordLengthAddress? address, int? value) =>
      address == null
      ? _settings.restoreLooperModeCheckpoint(value)
      : _settings.restoreRecordLengthCheckpoint(
          channel: address.channel,
          bars: value,
        );
  bool _editable(RecordLengthAddress? address) =>
      !_repository.recordLengthCaptureLocked &&
      (address?.channel == null ||
          _repository.sessionTransport.looperMode != LooperMode.multi);

  Future<RecordLengthOutcome> _write(
    RecordLengthAddress? address,
    int? bars, {
    bool ordinary = false,
    RecordLengthLifetime? lifetime,
    int? revision,
    int? releasedBars,
    LooperMode? mode,
  }) async {
    if (address != null &&
        (!address.isValid ||
            (address.channel == null && bars == null) ||
            (bars != null && (bars < 0 || bars > 64)) ||
            (releasedBars != null &&
                (releasedBars < 0 || releasedBars > 64)))) {
      return _report(
        const RecordLengthOutcome(
          RecordLengthStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    final origin = lifetime ?? recordLengthLifetime;
    await _ready();
    return _queue(() async {
      bool current() =>
          origin == recordLengthLifetime &&
          (address == null ||
              revision == null ||
              revision == recordLengthRevision(address));
      if (!current()) {
        return const RecordLengthOutcome(RecordLengthStatus.superseded);
      }
      if (_closing ||
          isClosed ||
          !_initialized ||
          _recovery != null ||
          _repository.lengthRecoveryRequired ||
          !_editable(address)) {
        return _report(
          RecordLengthOutcome(
            _recovery != null || _repository.lengthRecoveryRequired
                ? RecordLengthStatus.recoveryRequired
                : RecordLengthStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      int? checkpoint;
      var attempted = false;
      try {
        checkpoint = await _checkpoint(address);
        if (!current() || _closing || isClosed) {
          return const RecordLengthOutcome(RecordLengthStatus.superseded);
        }
        final durable = mode?.code ?? releasedBars ?? bars;
        if (checkpoint != durable) {
          attempted = true;
          await _restoreScalar(address, durable);
        }
        if (!current() || _closing || isClosed) {
          throw const _LengthRefusal(RecordLengthStatus.superseded);
        }
        if (!_editable(address)) {
          throw const _LengthRefusal(RecordLengthStatus.rejected);
        }
        final enteringMulti =
            mode == LooperMode.multi &&
            _repository.sessionTransport.looperMode != LooperMode.multi;
        final retired = enteringMulti
            ? Map.of(durableRecordLengthSnapshot.trackOverrides)
            : null;
        _applying = true;
        try {
          var result = mode != null
              ? _repository.setLooperMode(mode, trackOverrides: retired)
              : address!.channel == null
              ? _repository.setDefaultLengthPreset(
                  bars!,
                  releasedBars: releasedBars,
                )
              : _repository.setTrackLengthPreset(
                  channel: address.channel!,
                  bars: bars,
                  releasedBars: releasedBars,
                );
          if (result.isOk) result = await _repository.settleLengthSettings();
          if (!current() || _closing || isClosed) {
            throw const _LengthRefusal(RecordLengthStatus.superseded);
          }
          if (!result.isOk) {
            throw _LengthRefusal(RecordLengthStatus.rejected, result: result);
          }
          _publish();
          if (enteringMulti) {
            for (var c = 0; c < 8; c++) {
              final target = RecordLengthAddress.track(c);
              _revisions[target] = recordLengthRevision(target) + 1;
              _ordinary.add((address: target, bars: retired![c]));
            }
          } else if (ordinary) {
            _revisions[address!] = recordLengthRevision(address) + 1;
            _ordinary.add((address: address, bars: bars));
          }
          return _report(
            RecordLengthOutcome(
              RecordLengthStatus.applied,
              deferred: !_repository.state.status.isConnected,
            ),
          );
        } finally {
          _applying = false;
        }
      } on Object catch (error) {
        if (attempted) {
          try {
            await _restoreScalar(address, checkpoint);
          } on Object catch (rollbackError) {
            _recovery = _LengthStoreRecovery(address, checkpoint);
            return _report(
              RecordLengthOutcome(
                RecordLengthStatus.recoveryRequired,
                error: rollbackError,
              ),
            );
          }
        }
        if (_repository.lengthRecoveryRequired) {
          return _report(
            RecordLengthOutcome(
              RecordLengthStatus.recoveryRequired,
              error: error,
            ),
          );
        }
        if (!current() || _closing || isClosed) {
          return const RecordLengthOutcome(RecordLengthStatus.superseded);
        }
        return _report(
          RecordLengthOutcome(
            _repository.lengthRecoveryRequired
                ? RecordLengthStatus.recoveryRequired
                : error is _LengthRefusal
                ? error.status
                : RecordLengthStatus.rejected,
            engineResult: error is _LengthRefusal ? error.result : null,
            error: error,
          ),
        );
      }
    });
  }

  Future<RecordLengthOutcome> flushRecordLength() async {
    await _ready();
    await _tail;
    final result = await _repository.settleLengthSettings();
    if (_recovery != null || _repository.lengthRecoveryRequired) {
      return _report(
        RecordLengthOutcome(
          RecordLengthStatus.recoveryRequired,
          engineResult: result,
        ),
      );
    }
    return _last;
  }

  Future<RecordLengthOutcome> recoverRecordLength() async {
    await _ready();
    final result = await _queue(() async {
      if (_closing || isClosed) {
        return const RecordLengthOutcome(RecordLengthStatus.rejected);
      }
      try {
        final recovery = _recovery;
        if (recovery != null) {
          await _restoreScalar(recovery.address, recovery.checkpoint);
          if (_closing || isClosed) {
            return const RecordLengthOutcome(RecordLengthStatus.superseded);
          }
          _recovery = null;
        }
        if (_repository.lengthRecoveryRequired) {
          final result = _repository.recoverLengthSettings();
          if (!result.isOk) {
            return _report(
              RecordLengthOutcome(
                RecordLengthStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        if (!_initialized) {
          return const RecordLengthOutcome(RecordLengthStatus.applied);
        }
        if (!_repository.lengthSettingsSettled) {
          return _report(
            const RecordLengthOutcome(RecordLengthStatus.rejected),
          );
        }
        _publish();
        return _report(
          RecordLengthOutcome(
            RecordLengthStatus.applied,
            deferred: !_repository.state.status.isConnected,
          ),
        );
      } on Object catch (error) {
        return _report(
          RecordLengthOutcome(
            RecordLengthStatus.recoveryRequired,
            error: error,
          ),
        );
      }
    });
    if (result.isOk && !_initialized) {
      await _restoreLength();
      return _last;
    }
    return result;
  }

  Future<T> runRecordExclusive<T>(Future<T> Function() operation) async {
    await _ready();
    return _queue(() async {
      await _repository.settleLengthSettings();
      if (!_initialized ||
          _closing ||
          isClosed ||
          _recovery != null ||
          _repository.lengthRecoveryRequired) {
        throw StateError('Record length is not confirmed');
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
    await _otherLoad;
    await _lengthLoad;
    await _tail;
    await _ordinary.close();
    await _failures.close();
  }

  /// Sets and persists the rec/dub second-press mode, applying it now.
  Future<void> setRecDub({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setRecDub(enabled: value).isOk) return;
    emit(state.copyWith(recDub: value));

    await _settings.saveRecDub(value: value);
  }

  /// Sets and persists sound-activated recording, applying it now. Turning
  /// it on clears the count-in (the engine's rule, D9), persisted here too
  /// so a restart does not bring the count-in back over it.
  Future<void> setAutoRecord({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setAutoRecord(enabled: value).isOk) return;
    emit(state.copyWith(autoRecord: value));

    await Future.wait([
      _settings.saveAutoRecord(value: value),
      if (value) _settings.saveCountInBars(0),
    ]);
  }

  /// Sets and persists the global default loop length, applying it now.
  Future<void> setDefaultMultiple(int multiple) async {
    final clamped = multiple < 0 ? 0 : multiple;
    _userEditRevision++;
    if (!_repository.setDefaultMultiple(multiple: clamped).isOk) return;
    emit(state.copyWith(defaultMultiple: clamped));

    await _settings.saveDefaultMultiple(clamped);
  }
}

final class _LengthStoreRecovery {
  const _LengthStoreRecovery(this.address, this.checkpoint);
  final RecordLengthAddress? address;
  final int? checkpoint;
}

final class _LengthRefusal implements Exception {
  const _LengthRefusal(this.status, {this.result});
  final RecordLengthStatus status;
  final EngineResult? result;
}
