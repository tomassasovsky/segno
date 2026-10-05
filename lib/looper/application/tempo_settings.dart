import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the tempo grid and count-in settings (plan A5), and presents the
/// Click volume and Hear click owners in one [TempoState]: loads the persisted
/// intent on [load], applies each setter to the [LooperRepository] (the live
/// engine) AND persists it via [SettingsRepository].
///
/// [tapTempo] is the one exception: a momentary action forwarded straight to
/// the repository, never persisted (see [LooperRepository.tapTempo]'s doc —
/// there is nothing meaningful to remember; the resulting tempo, if any, is
/// the engine's own runtime state).
class TempoSettings implements RecordStartControl {
  /// Creates a [TempoSettings] driving [repository], persisted through
  /// [settings]. Starts at the tempo-free defaults until [load] restores the
  /// saved values.
  TempoSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       clickVolumeOwner = SettingsOwner(
         repository: repository,
         family: ClickVolumeFamily(repository: repository, settings: settings),
       ),
       clickModeOwner = SettingsOwner(
         repository: repository,
         family: HearClickFamily(repository: repository, settings: settings),
       ) {
    _startFailureSubscription = _repository.recordStartSettingsFailures.listen((
      result,
    ) {
      if (!_closing &&
          (!_startApplying || _repository.recordStartRecoveryRequired)) {
        _reportStart(
          RecordStartOutcome(
            _repository.recordStartRecoveryRequired
                ? RecordStartStatus.recoveryRequired
                : RecordStartStatus.rejected,
            engineResult: result,
          ),
        );
      }
    });
    _subscription = _repository.looperState.listen(_onLooperState);
    _ownerSubscriptions = [
      clickVolumeOwner.changes.listen((_) => _syncFromRepository()),
      clickModeOwner.changes.listen((_) => _syncFromRepository()),
    ];
  }

  /// The Click volume transaction.
  final SettingsOwner<double, double?> clickVolumeOwner;

  /// The Hear click transaction.
  final SettingsOwner<ClickMode, int?> clickModeOwner;

  /// ControlCubit's Click volume port over [clickVolumeOwner].
  late final clickVolumeControl = ClickVolumeOwnerControl(clickVolumeOwner);

  /// ControlCubit's Hear click port over [clickModeOwner].
  late final clickModeControl = ClickModeOwnerControl(clickModeOwner);

  TempoState _state = const TempoState();
  final _states = StreamController<TempoState>.broadcast(sync: true);

  /// Current immutable presentation of accepted values and readiness.
  TempoState get state => _state;

  /// Publications consumed by the borrowed UI adapter.
  Stream<TempoState> get stream => _states.stream;

  void _emit(TempoState next) {
    if (_states.isClosed) return;
    final published = next.copyWith(
      clickModeInitialized: clickModeOwner.initialized,
      recordStartInitialized: _startInitialized,
    );
    if (_state == published) return;
    _state = published;
    _states.add(published);
  }

  late final StreamSubscription<EngineResult> _startFailureSubscription;
  Future<void>? _startLoadFuture;
  bool _startInitialized = false;
  bool _startApplying = false;
  int _startRevision = 0;
  final _ordinaryStart = StreamController<RecordStartSettings>.broadcast(
    sync: true,
  );
  ({int? countInBars, bool? soundStart})? _startStoreRecovery;
  final _startFailures = StreamController<RecordStartOutcome>.broadcast(
    sync: true,
  );
  RecordStartOutcome _lastStartOutcome = const RecordStartOutcome(
    RecordStartStatus.rejected,
  );

  @override
  RecordStartSettings? get confirmedRecordStart => _startInitialized
      ? RecordStartSettings(
          countInBars: state.countInBars,
          soundStart: state.soundStart,
        )
      : null;

  @override
  RecordStartSnapshot? get recordStartSnapshot =>
      state.recordStartReady && !_closing && !_states.isClosed
      ? RecordStartSnapshot(
          settings: confirmedRecordStart!,
          captureLocked: state.recordStartCaptureLocked,
        )
      : null;

  @override
  RecordStartSettings get durableRecordStartSettings {
    final pair = _repository.recordStartRestartIntent;
    return RecordStartSettings(
      countInBars: pair.countInBars,
      soundStart: pair.soundStart,
    );
  }

  /// Failed writes and persistent recovery obligations for the pair.
  Stream<RecordStartOutcome> get recordStartFailures => _startFailures.stream;

  bool get _startRecoveryPending =>
      _startStoreRecovery != null || _repository.recordStartRecoveryRequired;
  bool get _startReady =>
      _startInitialized &&
      !_startApplying &&
      !_startRecoveryPending &&
      _repository.recordStartSettingsSettled;
  @override
  RecordStartLifetime get recordStartLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  @override
  int get recordStartRevision => _startRevision;

  @override
  Stream<RecordStartSettings> get ordinaryRecordStartChanges =>
      _ordinaryStart.stream;

  RecordStartOutcome _reportStart(RecordStartOutcome outcome) {
    if (outcome.status == RecordStartStatus.superseded) return outcome;
    _lastStartOutcome = outcome;
    if (!_closing && !_states.isClosed) {
      if (outcome.status == RecordStartStatus.recoveryRequired) {
        _emit(state.copyWith(recordStartReady: false));
      }
      if (!outcome.isOk) _startFailures.add(outcome);
    }
    return outcome;
  }

  /// Validates both saved scalars independently of miscellaneous Tempo load.
  Future<void> loadRecordStart() => _startLoadFuture ??= _restoreRecordStart();

  Future<void> _restoreRecordStart() async {
    final session = _repository.sessionRevision;
    try {
      RecordStartSettings? saved;
      try {
        saved = RecordStartSettings.fromCheckpoint(
          await _settings.readRecordStartCheckpoint(),
        );
      } on Object {
        if (session == _repository.sessionRevision) rethrow;
      }
      while (!_closing && !_states.isClosed) {
        final origin = recordStartLifetime;
        final done = await _queueTempo(() async {
          if (_closing || _states.isClosed) return true;
          if (origin != recordStartLifetime) return false;
          _startApplying = true;
          try {
            await _repository.settleRecordStartSettings();
            if (_closing || _states.isClosed) return true;
            if (origin != recordStartLifetime) return false;
            if (_repository.recordStartRecoveryRequired) {
              _reportStart(
                const RecordStartOutcome(RecordStartStatus.recoveryRequired),
              );
              return true;
            }
            if (origin.sessionRevision == session) {
              final settings = saved!;
              var result = _repository.setRecordStartSettings(
                countInBars: settings.countInBars,
                soundStart: settings.soundStart,
                editKind: RecordStartEditKind.restore,
              );
              if (result.isOk) {
                result = await _repository.settleRecordStartSettings();
              }
              if (_closing || _states.isClosed) return true;
              if (origin != recordStartLifetime) return false;
              if (!result.isOk) {
                _reportStart(
                  RecordStartOutcome(
                    RecordStartStatus.recoveryRequired,
                    engineResult: result,
                  ),
                );
                return true;
              }
            }
            _startInitialized = true;
            _reportStart(const RecordStartOutcome(RecordStartStatus.applied));
            return true;
          } finally {
            _startApplying = false;
            _syncFromRepository();
          }
        });
        if (done) return;
      }
    } on Object catch (error) {
      if (!_closing && !_states.isClosed) {
        _reportStart(
          RecordStartOutcome(RecordStartStatus.recoveryRequired, error: error),
        );
      }
    }
  }

  @override
  Future<RecordStartOutcome> setCountInBars(int bars) =>
      _writeRecordStart(countInBars: bars, ordinary: true);

  @override
  Future<RecordStartOutcome> setSoundStart({required bool enabled}) =>
      _writeRecordStart(soundStart: enabled, ordinary: true);

  @override
  Future<RecordStartOutcome> setControllerCountIn(
    int bars, {
    required RecordStartLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) => _writeRecordStart(
    countInBars: bars,
    lifetime: lifetime,
    revision: revision,
    releasedBars: releasedBars,
  );

  Future<RecordStartOutcome> _writeRecordStart({
    int? countInBars,
    bool? soundStart,
    bool ordinary = false,
    RecordStartLifetime? lifetime,
    int? revision,
    int? releasedBars,
  }) async {
    final origin = lifetime ?? recordStartLifetime;
    await loadRecordStart();
    return _queueTempo(() async {
      bool current() =>
          origin == recordStartLifetime &&
          (revision == null || revision == _startRevision) &&
          !_closing &&
          !_states.isClosed;
      if (!current()) {
        return const RecordStartOutcome(RecordStartStatus.superseded);
      }
      if (!_startInitialized ||
          _startRecoveryPending ||
          !_repository.recordStartSettingsSettled ||
          _repository.recordStartCaptureLocked ||
          countInBars != null && !kCountInBarOptions.contains(countInBars) ||
          releasedBars != null && !kCountInBarOptions.contains(releasedBars)) {
        return _reportStart(
          RecordStartOutcome(
            _startRecoveryPending
                ? RecordStartStatus.recoveryRequired
                : RecordStartStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      final prior = _repository.recordStartSettings;
      final accepted = RecordStartSettings(
        countInBars: prior.countInBars,
        soundStart: prior.soundStart,
      );
      final next = countInBars != null
          ? accepted.withCountIn(countInBars)
          : RecordStartSettings(
              countInBars: soundStart == true ? 0 : prior.countInBars,
              soundStart: soundStart ?? prior.soundStart,
            );
      final durable = releasedBars == null
          ? next
          : next.withCountIn(releasedBars);
      ({int? countInBars, bool? soundStart})? checkpoint;
      var attempted = false;
      _startApplying = true;
      try {
        checkpoint = await _settings.readRecordStartCheckpoint();
        if (!current()) {
          return const RecordStartOutcome(RecordStartStatus.superseded);
        }
        attempted = true;
        await _settings.saveRecordStartSettings(
          countInBars: durable.countInBars,
          soundStart: durable.soundStart,
        );
        if (!current()) {
          throw const _RecordStartRefusal(RecordStartStatus.superseded);
        }
        if (_repository.recordStartCaptureLocked) {
          throw const _RecordStartRefusal(RecordStartStatus.rejected);
        }
        var result = _repository.setRecordStartSettings(
          countInBars: next.countInBars,
          soundStart: next.soundStart,
          releasedSettings: (
            countInBars: durable.countInBars,
            soundStart: durable.soundStart,
          ),
          editKind: countInBars != null
              ? RecordStartEditKind.countIn
              : RecordStartEditKind.sound,
        );
        if (result.isOk) result = await _repository.settleRecordStartSettings();
        if (!current()) {
          throw const _RecordStartRefusal(RecordStartStatus.superseded);
        }
        if (!result.isOk) {
          throw _RecordStartRefusal(RecordStartStatus.rejected, result: result);
        }
        if (ordinary) {
          ++_startRevision;
          _ordinaryStart.add(next);
        }
        return _reportStart(
          RecordStartOutcome(
            RecordStartStatus.applied,
            deferred: !_repository.sessionTransport.isRunning,
          ),
        );
      } on Object catch (error) {
        if (attempted) {
          try {
            await _settings.restoreRecordStartCheckpoint(checkpoint!);
          } on Object catch (rollbackError) {
            _startStoreRecovery = checkpoint;
            return _reportStart(
              RecordStartOutcome(
                RecordStartStatus.recoveryRequired,
                error: rollbackError,
              ),
            );
          }
        }
        if (!current()) {
          return const RecordStartOutcome(RecordStartStatus.superseded);
        }
        return _reportStart(
          RecordStartOutcome(
            _repository.recordStartRecoveryRequired
                ? RecordStartStatus.recoveryRequired
                : error is _RecordStartRefusal
                ? error.status
                : RecordStartStatus.rejected,
            engineResult: error is _RecordStartRefusal ? error.result : null,
            error: error,
          ),
        );
      } finally {
        _startApplying = false;
        _syncFromRepository();
      }
    });
  }

  /// A confirmed rollback remains a healthy barrier; uncertainty does not.
  Future<RecordStartOutcome> flushRecordStart() async {
    await loadRecordStart();
    await _tempoTail;
    final wasSettled = _repository.recordStartSettingsSettled;
    final result = await _repository.settleRecordStartSettings();
    if (!_startInitialized || _startRecoveryPending) {
      return _reportStart(
        RecordStartOutcome(
          RecordStartStatus.recoveryRequired,
          engineResult: result,
        ),
      );
    }
    if (!wasSettled && !result.isOk) {
      return _reportStart(
        RecordStartOutcome(RecordStartStatus.rejected, engineResult: result),
      );
    }
    _syncFromRepository();
    return RecordStartOutcome(
      RecordStartStatus.applied,
      deferred: !_repository.sessionTransport.isRunning,
    );
  }

  /// Explicit retry repairs exact scalar membership and this native lifetime.
  Future<RecordStartOutcome> recoverRecordStart() async {
    await loadRecordStart();
    final outcome = await _queueTempo(() async {
      if (_closing || _states.isClosed) {
        return const RecordStartOutcome(RecordStartStatus.rejected);
      }
      try {
        final checkpoint = _startStoreRecovery;
        if (checkpoint != null) {
          await _settings.restoreRecordStartCheckpoint(checkpoint);
          if (_closing || _states.isClosed) {
            return const RecordStartOutcome(RecordStartStatus.superseded);
          }
          _startStoreRecovery = null;
        }
        if (_repository.recordStartRecoveryRequired) {
          final result = _repository.recoverRecordStartSettings();
          if (!result.isOk) {
            return _reportStart(
              RecordStartOutcome(
                RecordStartStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        if (!_startInitialized) {
          return const RecordStartOutcome(RecordStartStatus.applied);
        }
        final result = await _repository.settleRecordStartSettings();
        if (!_repository.recordStartSettingsSettled || _startRecoveryPending) {
          return _reportStart(
            RecordStartOutcome(
              RecordStartStatus.recoveryRequired,
              engineResult: result,
            ),
          );
        }
        _syncFromRepository();
        return _reportStart(
          RecordStartOutcome(
            RecordStartStatus.applied,
            deferred: !_repository.sessionTransport.isRunning,
          ),
        );
      } on Object catch (error) {
        return _reportStart(
          RecordStartOutcome(RecordStartStatus.recoveryRequired, error: error),
        );
      }
    });
    if (outcome.isOk && !_startInitialized) {
      await _restoreRecordStart();
      return _lastStartOutcome;
    }
    return outcome;
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  late final List<StreamSubscription<void>> _ownerSubscriptions;
  int _userEditRevision = 0;
  Future<void> _tempoTail = Future<void>.value();
  bool _closing = false;

  Future<T> _queueTempo<T>(Future<T> Function() operation) {
    final result = _tempoTail.then((_) => operation());
    _tempoTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Session callers acquire Mixer before this gate, never the reverse.
  /// Click volume and Hear click capture their durable values even while
  /// unavailable; Count-in still refuses.
  Future<T> runTempoExclusive<T>(Future<T> Function() operation) async {
    await load();
    return clickVolumeOwner.runExclusive(
      () => clickModeOwner.runExclusive(
        () => _queueTempo(() async {
          await _repository.settleRecordStartSettings();
          if (!_startInitialized ||
              _startRecoveryPending ||
              !_repository.recordStartSettingsSettled) {
            throw StateError(
              'Recording start is unavailable for session capture',
            );
          }
          if (_closing || _states.isClosed) {
            throw StateError('Tempo settings are closing');
          }
          try {
            return await operation();
          } finally {
            _syncFromRepository();
          }
        }),
      ),
    );
  }

  void _onLooperState(LooperState _) => _syncFromRepository();

  void _syncFromRepository() {
    if (_closing || _states.isClosed) return;
    final transport = _repository.sessionTransport;
    _emit(
      TempoState(
        bpm: transport.tempoBpm,
        tsNum: transport.tsNum,
        tsDen: transport.tsDen,
        clickMode: clickModeOwner.live,
        clickModeReady: clickModeOwner.ready,
        clickModeCaptureLocked: clickModeOwner.captureLocked,
        clickOutputMask: transport.clickMask,
        clickVolume: clickVolumeOwner.live,
        clickReady: clickVolumeOwner.ready,
        countInBars: !_startApplying && _startInitialized
            ? transport.countInBars
            : state.countInBars,
        soundStart: !_startApplying && _startInitialized
            ? transport.autoRecord
            : state.soundStart,
        recordStartReady: _startReady,
        recordStartCaptureLocked: _repository.recordStartCaptureLocked,
      ),
    );
  }

  Future<void>? _closeFuture;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    // Initialization failures belong to the load caller. They must not bypass
    // disposal or prevent the remaining application owners from closing.
    await Future.wait<void>([
      ?_loadFuture,
      ?_startLoadFuture,
    ]).then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _tempoTail;
    try {
      await Future.wait<void>([
        _subscription.cancel(),
        _startFailureSubscription.cancel(),
        for (final subscription in _ownerSubscriptions) subscription.cancel(),
      ]);
    } finally {
      await Future.wait<void>([
        clickVolumeOwner.close(),
        clickModeOwner.close(),
        _startFailures.close(),
        _ordinaryStart.close(),
        _states.close(),
      ]);
    }
  }

  /// Restores the persisted tempo/click/count-in settings and applies them to
  /// the repository.
  Future<void> load() => _loadFuture ??= Future.wait<void>([
    _restore(),
    clickVolumeOwner.load(),
    clickModeOwner.load(),
    loadRecordStart(),
  ]).then((_) {});

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final bpm = await _settings.loadTempoBpm();
    final (tsNum, tsDen) = await _settings.loadTimeSignature();
    final clickOutputMask = await _settings.loadClickOutputMask();
    if (_states.isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    // An unset tempo must not become a manual 30 BPM grid.
    final tempoApplied = bpm > 0 && _repository.setTempo(bpm).isOk;
    final signatureApplied = _repository.setTimeSignature(tsNum, tsDen).isOk;
    final outputApplied = _repository.setClickOutput(clickOutputMask).isOk;
    _emit(
      state.copyWith(
        bpm: tempoApplied ? bpm : null,
        tsNum: signatureApplied ? tsNum : null,
        tsDen: signatureApplied ? tsDen : null,
        clickOutputMask: outputApplied ? clickOutputMask : null,
      ),
    );
  }

  /// Sets and persists the tempo in BPM, applying it now.
  ///
  /// Unconditionally calls the repository — this is a "set to this value"
  /// command triggered by an explicit user action, not a delta against the
  /// owner's accepted state. The cache can go stale relative to the live engine
  /// (for example, a recalled session replaces the accepted tempo), so
  /// gating the
  /// repository call on `newValue != state.field` risks silently no-op'ing a
  /// user's tap whose target value happens to match the stale cache while
  /// the live engine holds something else. `emit` stays cheap to call
  /// unconditionally too: equal immutable state does not republish.
  Future<void> setTempo(double bpm) async {
    _userEditRevision++;
    if (!_repository.setTempo(bpm).isOk) return;
    _emit(state.copyWith(bpm: bpm));

    await _settings.saveTempoBpm(bpm);
  }

  /// Sets and persists the time signature, applying it now. [num]/[den] must
  /// be one of [kValidTimeSignatures] — the picker only offers valid choices,
  /// and the engine itself rejects anything else without applying it.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setTimeSignature(int num, int den) async {
    _userEditRevision++;
    if (!_repository.setTimeSignature(num, den).isOk) return;
    _emit(state.copyWith(tsNum: num, tsDen: den));

    await _settings.saveTimeSignature(num, den);
  }

  /// Sets and persists the click output routing bitmask, applying it now.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setClickOutput(int mask) async {
    _userEditRevision++;
    if (!_repository.setClickOutput(mask).isOk) return;
    _emit(state.copyWith(clickOutputMask: mask));

    await _settings.saveClickOutputMask(mask);
  }

  /// Registers a tempo tap; two taps within the engine's window set the
  /// tempo from their interval. A momentary action forwarded straight to the
  /// repository — never persisted (see the class doc).
  EngineResult tapTempo() {
    _userEditRevision++;
    return _repository.tapTempo();
  }
}

final class _RecordStartRefusal implements Exception {
  const _RecordStartRefusal(this.status, {this.result});
  final RecordStartStatus status;
  final EngineResult? result;
}
