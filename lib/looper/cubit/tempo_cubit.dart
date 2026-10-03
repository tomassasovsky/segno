import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:settings_repository/settings_repository.dart';

/// The tempo range the engine accepts, inclusive.
///
/// `LooperRepository.setTempo` clamps to this and reports nothing, so a
/// surface that submits outside it closes on a value the rig never took.
/// Stated here so every tempo control can clamp before it writes.
const (double, double) kTempoRange = (30, 300);

/// The count-in lengths offered, in measures; `0` is off.
///
/// Beside the cubit that writes the value rather than in a picker, for the
/// same reason [kMaxClickGain] is: two surfaces offer this setting — the
/// Settings section and the console's Loop face — and a set known to only one
/// of them is two pickers that can drift into offering different lengths.
const List<int> kCountInBarOptions = [0, 1, 2, 4];

/// What each [ClickMode] is called. One table, both surfaces.
Map<ClickMode, String> clickModeLabels(AppLocalizations l10n) => {
  ClickMode.off: l10n.clickModeOffLabel,
  ClickMode.rec: l10n.clickModeRecLabel,
  ClickMode.recFirst: l10n.clickModeRecFirstLabel,
  ClickMode.playRec: l10n.clickModePlayRecLabel,
};

/// What each count-in length is called, keyed by [kCountInBarOptions].
Map<int, String> countInLabels(AppLocalizations l10n) => {
  0: l10n.countInOffLabel,
  1: l10n.countInBarsLabel1,
  2: l10n.countInBarsLabel2,
  4: l10n.countInBarsLabel4,
};

/// The 17 Sheeran-verified time signatures (index plan D1): denominator `4`
/// with numerator `2..7`, denominator `8` with numerator `5..15`. Shared by
/// [TempoCubit] callers and the settings picker so both agree on the valid
/// set without duplicating it.
const List<(int num, int den)> kValidTimeSignatures = [
  (2, 4),
  (3, 4),
  (4, 4),
  (5, 4),
  (6, 4),
  (7, 4),
  (5, 8),
  (6, 8),
  (7, 8),
  (8, 8),
  (9, 8),
  (10, 8),
  (11, 8),
  (12, 8),
  (13, 8),
  (14, 8),
  (15, 8),
];

/// The tempo, click and count-in settings, following repository changes such
/// as session recall. Explicit edits are also persisted as startup defaults.
class TempoSettings extends Equatable {
  /// Creates a [TempoSettings].
  const TempoSettings({
    this.bpm = 0,
    this.tsNum = 4,
    this.tsDen = 4,
    this.clickMode = ClickMode.off,
    this.clickModeReady = false,
    this.clickModeCaptureLocked = false,
    this.clickOutputMask = 0,
    this.clickVolume = 1,
    this.clickReady = false,
    this.countInBars = 0,
  });

  /// The tempo in BPM; `0` means no tempo has been established.
  final double bpm;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator (`4` or `8`).
  final int tsDen;

  /// Click audibility mode.
  final ClickMode clickMode;

  /// Hear click has independently initialized and has no unresolved receipt.
  final bool clickModeReady;

  /// Actual capture prevents mode editing, without locking waiting arms.
  final bool clickModeCaptureLocked;

  /// Click output routing bitmask.
  final int clickOutputMask;

  /// Click volume (`0..LE_MAX_GAIN`).
  final double clickVolume;

  /// Whether Click initialization has established an accepted value.
  final bool clickReady;

  /// Count-in length in measures (`0` = off).
  final int countInBars;

  /// Returns a copy with the given overrides.
  TempoSettings copyWith({
    double? bpm,
    int? tsNum,
    int? tsDen,
    ClickMode? clickMode,
    bool? clickModeReady,
    bool? clickModeCaptureLocked,
    int? clickOutputMask,
    double? clickVolume,
    bool? clickReady,
    int? countInBars,
  }) => TempoSettings(
    bpm: bpm ?? this.bpm,
    tsNum: tsNum ?? this.tsNum,
    tsDen: tsDen ?? this.tsDen,
    clickMode: clickMode ?? this.clickMode,
    clickModeReady: clickModeReady ?? this.clickModeReady,
    clickModeCaptureLocked:
        clickModeCaptureLocked ?? this.clickModeCaptureLocked,
    clickOutputMask: clickOutputMask ?? this.clickOutputMask,
    clickVolume: clickVolume ?? this.clickVolume,
    clickReady: clickReady ?? this.clickReady,
    countInBars: countInBars ?? this.countInBars,
  );

  @override
  List<Object?> get props => [
    bpm,
    tsNum,
    tsDen,
    clickMode,
    clickModeReady,
    clickModeCaptureLocked,
    clickOutputMask,
    clickVolume,
    clickReady,
    countInBars,
  ];
}

/// Owns the tempo grid, click, and count-in settings (plan A5): loads the
/// persisted intent on [load], applies each setter to the [LooperRepository]
/// (the live engine) AND persists it via [SettingsRepository] — mirroring
/// the record timing cubit's single-writer shape, extended to
/// the full A1/A2 field set (pattern for the multi-field shape:
/// `RecordOptionsCubit`).
///
/// [tapTempo] is the one exception: a momentary action forwarded straight to
/// the repository, never persisted (see [LooperRepository.tapTempo]'s doc —
/// there is nothing meaningful to remember; the resulting tempo, if any, is
/// the engine's own runtime state).
class TempoCubit extends Cubit<TempoSettings>
    implements ClickVolumeControl, ClickModeControl {
  /// Creates a [TempoCubit] driving [repository], persisted through
  /// [settings]. Starts at the tempo-free defaults until [load] restores the
  /// saved values.
  TempoCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    Duration clickPollInterval = const Duration(milliseconds: 10),
    int clickPollAttempts = 50,
  }) : _repository = repository,
       _settings = settings,
       _clickPollInterval = clickPollInterval,
       _clickPollAttempts = clickPollAttempts,
       super(const TempoSettings()) {
    _acceptedClickLifetime = clickVolumeLifetime;
    _subscription = _repository.looperState.listen(_onLooperState);
    _modeFailureSubscription = _repository.clickModeFailures.listen((result) {
      if (!_modeApplying && !_closing) {
        _reportMode(
          ClickModeOutcome(
            _repository.clickModeRecoveryRequired
                ? ClickModeStatus.recoveryRequired
                : ClickModeStatus.rejected,
            engineResult: result,
          ),
        );
      }
    });
  }

  late final StreamSubscription<EngineResult> _modeFailureSubscription;
  Future<void>? _modeLoadFuture;
  bool _modeInitialized = false;
  bool _modeApplying = false;
  int _modeRevision = 0;
  ClickModeLifetime? _modeLifetime;
  ({int? checkpoint, ClickModeLifetime lifetime})? _modeStoreRecovery;
  final _ordinaryMode = StreamController<ClickMode>.broadcast(sync: true);
  final _modeFailures = StreamController<ClickModeOutcome>.broadcast(
    sync: true,
  );
  ClickModeOutcome _lastModeOutcome = const ClickModeOutcome(
    ClickModeStatus.rejected,
  );

  /// Last accepted choice for readout, retained while recovery blocks editing.
  /// Null until initialization has confirmed a mode at least once.
  ClickMode? get confirmedClickMode =>
      _modeInitialized ? state.clickMode : null;

  @override
  ClickModeSnapshot? get clickModeSnapshot =>
      state.clickModeReady && !_closing && !isClosed
      ? ClickModeSnapshot(
          mode: state.clickMode,
          captureLocked: state.clickModeCaptureLocked,
        )
      : null;
  @override
  ClickMode get durableClickMode => _repository.clickModeRestartIntent;
  @override
  ClickModeLifetime get clickModeLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );
  @override
  int get clickModeRevision => _modeRevision;
  @override
  Stream<ClickMode> get ordinaryClickModeChanges => _ordinaryMode.stream;

  /// Failed Hear click attempts and persistent recovery obligations.
  Stream<ClickModeOutcome> get clickModeFailures => _modeFailures.stream;

  bool get _modeRecoveryPending =>
      _modeStoreRecovery != null || _repository.clickModeRecoveryRequired;
  bool get _modeReady =>
      _modeInitialized &&
      !_modeApplying &&
      !_modeRecoveryPending &&
      _repository.clickModeSettled;

  ClickModeOutcome _reportMode(ClickModeOutcome outcome) {
    if (outcome.status == ClickModeStatus.superseded) return outcome;
    _lastModeOutcome = outcome;
    if (!_closing && !isClosed) {
      if (outcome.status == ClickModeStatus.recoveryRequired) {
        emit(state.copyWith(clickModeReady: false));
      }
      if (!outcome.isOk) _modeFailures.add(outcome);
    }
    return outcome;
  }

  /// Initializes Hear click independently from volume and miscellaneous tempo.
  Future<void> loadClickMode() => _modeLoadFuture ??= _restoreClickMode();

  Future<void> _restoreClickMode() async {
    final session = _repository.sessionRevision;
    try {
      int? saved;
      try {
        saved = await _settings.readClickModeCheckpoint();
      } on Object {
        // A recalled session is newer authority than a failed startup read.
        // Device-only changes still require validating the saved preference.
        if (session == _repository.sessionRevision) rethrow;
      }
      while (!_closing && !isClosed) {
        final origin = clickModeLifetime;
        final done = await _queueClick(() async {
          if (_closing || isClosed) return true;
          if (origin != clickModeLifetime) return false;
          _modeApplying = true;
          try {
            await _repository.settleClickMode();
            if (_closing || isClosed) return true;
            if (origin != clickModeLifetime) return false;
            if (_repository.clickModeRecoveryRequired) {
              _reportMode(
                const ClickModeOutcome(ClickModeStatus.recoveryRequired),
              );
              return true;
            }
            if (origin.sessionRevision == session) {
              var result = _repository.setClickMode(
                ClickMode.fromCode(saved ?? 2),
              );
              if (result.isOk) result = await _repository.settleClickMode();
              if (_closing || isClosed) return true;
              if (origin != clickModeLifetime) return false;
              if (!result.isOk) {
                _reportMode(
                  ClickModeOutcome(
                    ClickModeStatus.recoveryRequired,
                    engineResult: result,
                  ),
                );
                return true;
              }
            }
            _modeInitialized = true;
            _modeLifetime = clickModeLifetime;
            _reportMode(const ClickModeOutcome(ClickModeStatus.applied));
            return true;
          } finally {
            _modeApplying = false;
            _syncFromRepository();
          }
        });
        if (done) return;
      }
    } on Object catch (error) {
      if (!_closing && !isClosed) {
        _reportMode(
          ClickModeOutcome(ClickModeStatus.recoveryRequired, error: error),
        );
      }
    }
  }

  @override
  Future<ClickModeOutcome> setClickMode(ClickMode mode) =>
      _writeMode(mode, ordinary: true);

  @override
  Future<ClickModeOutcome> setControllerClickMode(
    ClickMode mode, {
    required ClickModeLifetime lifetime,
    required int revision,
    ClickMode? releasedMode,
  }) => _writeMode(
    mode,
    lifetime: lifetime,
    revision: revision,
    releasedMode: releasedMode,
  );

  Future<ClickModeOutcome> _writeMode(
    ClickMode mode, {
    bool ordinary = false,
    ClickModeLifetime? lifetime,
    int? revision,
    ClickMode? releasedMode,
  }) async {
    final origin = lifetime ?? clickModeLifetime;
    await loadClickMode();
    return _queueClick(() async {
      bool current() =>
          origin == clickModeLifetime &&
          (revision == null || revision == _modeRevision);
      if (!current()) return const ClickModeOutcome(ClickModeStatus.superseded);
      if (_closing ||
          isClosed ||
          !_modeInitialized ||
          _modeRecoveryPending ||
          !_repository.clickModeSettled ||
          _repository.clickModeCaptureLocked) {
        return _reportMode(
          ClickModeOutcome(
            _modeRecoveryPending
                ? ClickModeStatus.recoveryRequired
                : ClickModeStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      int? checkpoint;
      var attempted = false;
      _modeApplying = true;
      try {
        checkpoint = await _settings.readClickModeCheckpoint();
        if (!current() || _closing || isClosed) {
          return const ClickModeOutcome(ClickModeStatus.superseded);
        }
        attempted = true;
        await _settings.restoreClickModeCheckpoint((releasedMode ?? mode).code);
        if (!current() || _closing || isClosed) {
          throw const _ClickModeRefusal(ClickModeStatus.superseded);
        }
        if (_repository.clickModeCaptureLocked) {
          throw const _ClickModeRefusal(ClickModeStatus.rejected);
        }
        var result = _repository.setClickMode(mode, releasedMode: releasedMode);
        if (result.isOk) result = await _repository.settleClickMode();
        if (!current() || _closing || isClosed) {
          throw const _ClickModeRefusal(ClickModeStatus.superseded);
        }
        if (!result.isOk) {
          throw _ClickModeRefusal(ClickModeStatus.rejected, result: result);
        }
        if (ordinary) {
          ++_modeRevision;
          _ordinaryMode.add(mode);
        }
        return _reportMode(
          ClickModeOutcome(
            ClickModeStatus.applied,
            deferred: !_repository.sessionTransport.isRunning,
          ),
        );
      } on Object catch (error) {
        if (attempted) {
          try {
            await _settings.restoreClickModeCheckpoint(checkpoint);
          } on Object catch (rollbackError) {
            _modeStoreRecovery = (checkpoint: checkpoint, lifetime: origin);
            return _reportMode(
              ClickModeOutcome(
                ClickModeStatus.recoveryRequired,
                error: rollbackError,
              ),
            );
          }
        }
        if (!current() || _closing || isClosed) {
          return const ClickModeOutcome(ClickModeStatus.superseded);
        }
        return _reportMode(
          ClickModeOutcome(
            _repository.clickModeRecoveryRequired
                ? ClickModeStatus.recoveryRequired
                : error is _ClickModeRefusal
                ? error.status
                : ClickModeStatus.rejected,
            engineResult: error is _ClickModeRefusal ? error.result : null,
            error: error,
          ),
        );
      } finally {
        _modeApplying = false;
        _syncFromRepository();
      }
    });
  }

  /// Healthy compensated refusals do not poison the orderly shutdown barrier.
  Future<ClickModeOutcome> flushClickMode() async {
    await loadClickMode();
    await _clickTail;
    final wasSettled = _repository.clickModeSettled;
    final result = await _repository.settleClickMode();
    if (!_modeInitialized || _modeRecoveryPending) {
      return _reportMode(
        ClickModeOutcome(
          ClickModeStatus.recoveryRequired,
          engineResult: result,
        ),
      );
    }
    if (!wasSettled && !result.isOk) {
      return _reportMode(
        ClickModeOutcome(ClickModeStatus.rejected, engineResult: result),
      );
    }
    _syncFromRepository();
    return ClickModeOutcome(
      ClickModeStatus.applied,
      deferred: !_repository.sessionTransport.isRunning,
    );
  }

  /// Explicit recovery repairs storage and the current native obligation.
  Future<ClickModeOutcome> recoverClickMode() async {
    await loadClickMode();
    final outcome = await _queueClick(() async {
      if (_closing || isClosed) {
        return const ClickModeOutcome(ClickModeStatus.rejected);
      }
      try {
        final storage = _modeStoreRecovery;
        if (storage != null) {
          await _settings.restoreClickModeCheckpoint(storage.checkpoint);
          if (_closing || isClosed) {
            return const ClickModeOutcome(ClickModeStatus.superseded);
          }
          _modeStoreRecovery = null;
        }
        if (_repository.clickModeRecoveryRequired) {
          final result = _repository.recoverClickMode();
          if (!result.isOk) {
            return _reportMode(
              ClickModeOutcome(
                ClickModeStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        if (!_modeInitialized) {
          return const ClickModeOutcome(ClickModeStatus.applied);
        }
        final result = await _repository.settleClickMode();
        if (!_repository.clickModeSettled || _modeRecoveryPending) {
          return _reportMode(
            ClickModeOutcome(
              ClickModeStatus.recoveryRequired,
              engineResult: result,
            ),
          );
        }
        _syncFromRepository();
        return _reportMode(
          ClickModeOutcome(
            ClickModeStatus.applied,
            deferred: !_repository.sessionTransport.isRunning,
          ),
        );
      } on Object catch (error) {
        return _reportMode(
          ClickModeOutcome(ClickModeStatus.recoveryRequired, error: error),
        );
      }
    });
    if (outcome.isOk && !_modeInitialized) {
      await _restoreClickMode();
      return _lastModeOutcome;
    }
    return outcome;
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  int _userEditRevision = 0;
  final Duration _clickPollInterval;
  final int _clickPollAttempts;
  Future<void> _clickTail = Future<void>.value();
  final _ordinaryClick = StreamController<double>.broadcast(sync: true);
  final _clickFailures = StreamController<ClickVolumeOutcome>.broadcast();
  bool _closing = false;
  bool _clickBusy = false;
  bool _clickObservationQueued = false;
  double? _releasedClick;
  ClickVolumeLifetime? _acceptedClickLifetime;
  ({double? checkpoint, double volume, ClickVolumeLifetime lifetime})?
  _clickRecovery;

  bool get _clickRecoveryPending =>
      _clickRecovery != null || _repository.clickVolumeRecoveryRequired;

  @override
  double? get clickVolume =>
      state.clickReady && !_closing && !isClosed ? state.clickVolume : null;

  @override
  double get durableClickVolume => _releasedClick ?? state.clickVolume;

  @override
  ClickVolumeLifetime get clickVolumeLifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  @override
  Stream<double> get ordinaryClickVolumeChanges => _ordinaryClick.stream;

  /// Refusals and recovery obligations shared by both touch and controllers.
  Stream<ClickVolumeOutcome> get clickVolumeFailures => _clickFailures.stream;

  Future<T> _queueClick<T>(Future<T> Function() operation) {
    final result = _clickTail.then((_) => operation());
    _clickTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Waits for every Click write, including ordinary touch edits.
  Future<ClickVolumeOutcome> flushClickVolume() async {
    try {
      await _loadFuture;
      await _clickTail;
      await _queueClick(_observeClickReplay);
    } on Object catch (error) {
      return _reportClick(
        ClickVolumeOutcome(ClickVolumeStatus.rejected, error: error),
      );
    }
    if (!state.clickReady ||
        _clickRecoveryPending ||
        !_repository.clickVolumeSettled) {
      return _reportClick(
        ClickVolumeOutcome(
          _clickRecoveryPending
              ? ClickVolumeStatus.recoveryRequired
              : ClickVolumeStatus.rejected,
          engineResult: EngineResult.notReady,
        ),
      );
    }
    return ClickVolumeOutcome(
      ClickVolumeStatus.applied,
      deferred: !_repository.sessionTransport.isRunning,
    );
  }

  /// Session callers acquire Mixer before this gate, never the reverse.
  Future<T> runClickExclusive<T>(Future<T> Function() operation) async {
    await load();
    return _queueClick(() async {
      await _repository.settleClickMode();
      if (!_modeInitialized ||
          _modeRecoveryPending ||
          !_repository.clickModeSettled) {
        throw StateError('Hear click is unavailable for session capture');
      }
      if (!state.clickReady || _clickRecoveryPending || _closing || isClosed) {
        throw StateError('Click volume is unavailable for session capture');
      }
      final checkpoint = await _settings.readClickVolumeCheckpoint();
      final priorDurable = durableClickVolume;
      final lifetime = clickVolumeLifetime;
      try {
        return await operation();
      } finally {
        if (_repository.clickVolumeRecoveryRequired && _clickRecovery == null) {
          await _recoverFailedClick(
            checkpoint,
            priorDurable,
            false,
            lifetime: lifetime,
          );
        }
        _syncFromRepository();
      }
    });
  }

  ClickVolumeOutcome _reportClick(ClickVolumeOutcome outcome) {
    if (!outcome.isOk &&
        outcome.status != ClickVolumeStatus.superseded &&
        !_clickFailures.isClosed) {
      _clickFailures.add(outcome);
    }
    return outcome;
  }

  /// Reestablishes the exact preference and deferred runtime intent, stopped.
  Future<ClickVolumeOutcome> recoverClickVolume() => _queueClick(() async {
    if (_clickRecovery == null && _repository.clickVolumeRecoveryRequired) {
      await _adoptClickRecovery();
    }
    var recovery = _clickRecovery;
    if (recovery == null) {
      if (_closing ||
          isClosed ||
          !state.clickReady ||
          !_repository.clickVolumeSettled) {
        return _reportClick(
          const ClickVolumeOutcome(
            ClickVolumeStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      try {
        await _settings.readClickVolumeCheckpoint();
        return _reportClick(
          ClickVolumeOutcome(
            ClickVolumeStatus.applied,
            deferred: !_repository.sessionTransport.isRunning,
          ),
        );
      } on Object catch (error) {
        return _reportClick(
          ClickVolumeOutcome(ClickVolumeStatus.rejected, error: error),
        );
      }
    }
    try {
      await _settings.restoreClickVolumeCheckpoint(recovery.checkpoint);
      if (_closing || isClosed) {
        return const ClickVolumeOutcome(ClickVolumeStatus.superseded);
      }
      if (clickVolumeLifetime != recovery.lifetime) {
        // Only the old scalar obligation belongs to this transaction. A
        // replacement rig's replay failure owns its own confirmed gain.
        _clickRecovery = null;
        if (!_repository.clickVolumeRecoveryRequired) {
          _syncFromRepository();
          return _reportClick(
            const ClickVolumeOutcome(ClickVolumeStatus.applied),
          );
        }
        await _adoptClickRecovery();
        final adopted = _clickRecovery;
        if (adopted == null) {
          return _reportClick(
            const ClickVolumeOutcome(ClickVolumeStatus.recoveryRequired),
          );
        }
        recovery = adopted;
      }
      if (_closing || isClosed || clickVolumeLifetime != recovery.lifetime) {
        return const ClickVolumeOutcome(ClickVolumeStatus.superseded);
      }
      final result = _repository.setClickVolume(recovery.volume);
      if (!result.isOk) {
        return _reportClick(
          ClickVolumeOutcome(
            ClickVolumeStatus.recoveryRequired,
            engineResult: result,
          ),
        );
      }
      _repository.clearClickRecoveryStartBlock();
      _clickRecovery = null;
      _releasedClick = null;
      _acceptedClickLifetime = clickVolumeLifetime;
      emit(state.copyWith(clickVolume: recovery.volume, clickReady: true));
      return _reportClick(
        const ClickVolumeOutcome(ClickVolumeStatus.applied, deferred: true),
      );
    } on Object catch (error) {
      return _reportClick(
        ClickVolumeOutcome(ClickVolumeStatus.recoveryRequired, error: error),
      );
    }
  });

  void _onLooperState(LooperState _) => _syncFromRepository();

  void _syncFromRepository() {
    if (_closing || isClosed) return;
    final lifetime = clickVolumeLifetime;
    final changed =
        _acceptedClickLifetime != null && _acceptedClickLifetime != lifetime;
    if (changed && !_clickBusy) {
      _releasedClick = null;
      _acceptedClickLifetime = lifetime;
    }
    final clickSettled = !_clickBusy && _repository.clickVolumeSettled;
    if (!_clickBusy &&
        (changed || _repository.clickVolumeRecoveryRequired) &&
        !_clickObservationQueued) {
      _clickObservationQueued = true;
      unawaited(
        _queueClick(_observeClickReplay).whenComplete(() {
          _clickObservationQueued = false;
        }),
      );
    }
    if (!_modeApplying && _modeLifetime != clickModeLifetime) {
      _modeLifetime = clickModeLifetime;
      _modeRevision = 0;
    }
    final transport = _repository.sessionTransport;
    emit(
      TempoSettings(
        bpm: transport.tempoBpm,
        tsNum: transport.tsNum,
        tsDen: transport.tsDen,
        clickMode: !_modeApplying && _modeInitialized
            ? transport.clickMode
            : state.clickMode,
        clickModeReady: _modeReady,
        clickModeCaptureLocked: _repository.clickModeCaptureLocked,
        clickOutputMask: transport.clickMask,
        clickVolume: clickSettled && (state.clickReady || changed)
            ? transport.clickVolume
            : state.clickVolume,
        clickReady: state.clickReady || changed && clickSettled,
        countInBars: transport.countInBars,
      ),
    );
  }

  Future<void> _observeClickReplay() async {
    if (_closing || isClosed) return;
    if (_repository.sessionTransport.isRunning &&
        !_repository.clickVolumeSettled) {
      await _repository.settleClickVolume(
        pollInterval: _clickPollInterval,
        attempts: _clickPollAttempts,
      );
    }
    if (_repository.clickVolumeRecoveryRequired && _clickRecovery == null) {
      await _adoptClickRecovery();
    }
    _syncFromRepository();
  }

  Future<void> _adoptClickRecovery() async {
    final lifetime = clickVolumeLifetime;
    final volume = _repository.sessionTransport.clickVolume;
    try {
      final checkpoint = await _settings.readClickVolumeCheckpoint();
      if (_closing ||
          isClosed ||
          lifetime != clickVolumeLifetime ||
          !_repository.clickVolumeRecoveryRequired) {
        return;
      }
      await _recoverFailedClick(checkpoint, volume, false, lifetime: lifetime);
    } on Object catch (error) {
      // The checkpoint remains unknown; explicit Retry reads it again before
      // attempting any restoration. Never invent an absent scalar.
      _reportClick(
        ClickVolumeOutcome(ClickVolumeStatus.recoveryRequired, error: error),
      );
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _clickTail;
    await _subscription.cancel();
    await _modeFailureSubscription.cancel();
    await _modeLoadFuture;
    await _ordinaryMode.close();
    await _modeFailures.close();
    await _ordinaryClick.close();
    await _clickFailures.close();
    await super.close();
  }

  /// Restores the persisted tempo/click/count-in settings and applies them to
  /// the repository.
  Future<void> load() => _loadFuture ??= Future.wait<void>([
    _restore(),
    loadClickMode(),
  ]).then((_) {});

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final recordStartRevision = _repository.recordStartRevision;
    final bpm = await _settings.loadTempoBpm();
    final (tsNum, tsDen) = await _settings.loadTimeSignature();
    final clickOutputMask = await _settings.loadClickOutputMask();
    final clickVolume = await _settings.loadClickVolume();
    final countInBars = await _settings.loadCountInBars();
    final autoRecord = await _settings.loadAutoRecord();
    if (isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    var restored = state;
    // An unset tempo must not become a manual 30 BPM grid.
    if (bpm > 0 && _repository.setTempo(bpm).isOk) {
      restored = restored.copyWith(bpm: bpm);
    }
    if (_repository.setTimeSignature(tsNum, tsDen).isOk) {
      restored = restored.copyWith(tsNum: tsNum, tsDen: tsDen);
    }
    if (_repository.setClickOutput(clickOutputMask).isOk) {
      restored = restored.copyWith(clickOutputMask: clickOutputMask);
    }
    ClickVolumeOutcome? restoredClick;
    await _queueClick(() async {
      if (sessionRevision != _repository.sessionRevision ||
          userEditRevision != _userEditRevision ||
          _closing ||
          isClosed) {
        return;
      }
      restoredClick = await _writeClickVolume(
        clickVolume,
        lifetime: clickVolumeLifetime,
        persist: false,
        publish: false,
      );
    });
    if (_closing || isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    restored = restored.copyWith(
      clickVolume: restoredClick?.isOk ?? false
          ? clickVolume
          : state.clickVolume,
      clickReady: (restoredClick?.isOk ?? false) || state.clickReady,
    );
    // One startup owner restores the mutually exclusive start methods. A
    // later Sound start edit in RecordOptionsCubit also takes precedence.
    if (recordStartRevision == _repository.recordStartRevision) {
      if (countInBars > 0) {
        if (_repository.setCountIn(countInBars).isOk) {
          restored = restored.copyWith(countInBars: countInBars);
        }
      } else if (_repository.setAutoRecord(enabled: autoRecord).isOk &&
          _repository.setCountIn(0).isOk) {
        restored = restored.copyWith(countInBars: 0);
      }
    } else {
      restored = restored.copyWith(
        countInBars: _repository.sessionTransport.countInBars,
      );
    }
    emit(
      restored.copyWith(
        clickMode: state.clickMode,
        clickModeReady: state.clickModeReady,
        clickModeCaptureLocked: state.clickModeCaptureLocked,
      ),
    );
  }

  /// Sets and persists the tempo in BPM, applying it now.
  ///
  /// Unconditionally calls the repository — this is a "set to this value"
  /// command triggered by an explicit user action, not a delta against the
  /// cubit's own cache. The cache can go stale relative to the live engine
  /// (for example, a recalled session replaces the accepted tempo), so
  /// gating the
  /// repository call on `newValue != state.field` risks silently no-op'ing a
  /// user's tap whose target value happens to match the stale cache while
  /// the live engine holds something else. `emit` stays cheap to call
  /// unconditionally too: [Cubit] already no-ops a no-change emit
  /// internally.
  Future<void> setTempo(double bpm) async {
    _userEditRevision++;
    if (!_repository.setTempo(bpm).isOk) return;
    emit(state.copyWith(bpm: bpm));

    await _settings.saveTempoBpm(bpm);
  }

  /// Sets and persists the time signature, applying it now. [num]/[den] must
  /// be one of [kValidTimeSignatures] — the picker only offers valid choices,
  /// and the engine itself rejects anything else without applying it.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setTimeSignature(int num, int den) async {
    _userEditRevision++;
    if (!_repository.setTimeSignature(num, den).isOk) return;
    emit(state.copyWith(tsNum: num, tsDen: den));

    await _settings.saveTimeSignature(num, den);
  }

  /// Sets and persists the click output routing bitmask, applying it now.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setClickOutput(int mask) async {
    _userEditRevision++;
    if (!_repository.setClickOutput(mask).isOk) return;
    emit(state.copyWith(clickOutputMask: mask));

    await _settings.saveClickOutputMask(mask);
  }

  /// Applies ordinary touch intent through the same durable Click owner.
  Future<ClickVolumeOutcome> setClickVolume(double volume) {
    _userEditRevision++;
    final lifetime = clickVolumeLifetime;
    return _queueClick(
      () => _writeClickVolume(volume, lifetime: lifetime, ordinary: true),
    );
  }

  @override
  Future<ClickVolumeOutcome> setControllerClickVolume(
    double volume, {
    required ClickVolumeLifetime lifetime,
    double? releasedVolume,
  }) => _queueClick(
    () => _writeClickVolume(
      volume,
      releasedVolume: releasedVolume,
      lifetime: lifetime,
    ),
  );

  Future<ClickVolumeOutcome> _writeClickVolume(
    double volume, {
    required ClickVolumeLifetime lifetime,
    double? releasedVolume,
    bool ordinary = false,
    bool persist = true,
    bool publish = true,
  }) async {
    bool current() => !isClosed && lifetime == clickVolumeLifetime;
    if (_closing || !current()) {
      return const ClickVolumeOutcome(ClickVolumeStatus.superseded);
    }
    if (_clickRecoveryPending) {
      return _reportClick(
        const ClickVolumeOutcome(ClickVolumeStatus.recoveryRequired),
      );
    }
    if (!volume.isFinite ||
        volume < 0 ||
        volume > kMaxClickGain ||
        releasedVolume != null &&
            (!releasedVolume.isFinite ||
                releasedVolume < 0 ||
                releasedVolume > kMaxClickGain)) {
      return _reportClick(
        const ClickVolumeOutcome(
          ClickVolumeStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    final priorDurable = durableClickVolume;
    double? checkpoint;
    var saved = false;
    _clickBusy = true;
    try {
      checkpoint = await _settings.readClickVolumeCheckpoint();
      if (!current()) {
        return const ClickVolumeOutcome(ClickVolumeStatus.superseded);
      }
      // Engine startup replays the accepted gain through the same native
      // queue. Drain that receipt before admitting the owner's next intent.
      if (_repository.sessionTransport.isRunning &&
          !_repository.clickVolumeSettled) {
        final prior = await _repository.settleClickVolume(
          pollInterval: _clickPollInterval,
          attempts: _clickPollAttempts,
        );
        if (_repository.clickVolumeRecoveryRequired) {
          return await _recoverFailedClick(
            checkpoint,
            priorDurable,
            false,
            lifetime: lifetime,
            result: prior,
          );
        }
        if (!current() || !prior.isOk) {
          return _reportClick(
            ClickVolumeOutcome(
              current()
                  ? ClickVolumeStatus.rejected
                  : ClickVolumeStatus.superseded,
              engineResult: prior,
            ),
          );
        }
      }
      if (persist) {
        // A write may mutate storage and then throw: checkpoint restoration is
        // required even when its returned Future did not succeed.
        saved = true;
        await _settings.saveClickVolume(releasedVolume ?? volume);
      }
      if (!current()) {
        if (saved) await _settings.restoreClickVolumeCheckpoint(checkpoint);
        return const ClickVolumeOutcome(ClickVolumeStatus.superseded);
      }
      final deferred = !_repository.sessionTransport.isRunning;
      var result = _repository.setClickVolume(
        volume,
        releasedVolume: releasedVolume,
      );
      if (result.isOk) {
        result = await _repository.settleClickVolume(
          pollInterval: _clickPollInterval,
          attempts: _clickPollAttempts,
        );
      }
      if (_repository.clickVolumeRecoveryRequired) {
        return await _recoverFailedClick(
          checkpoint,
          priorDurable,
          saved,
          lifetime: lifetime,
          result: result,
        );
      }
      if (!current() || !result.isOk) {
        if (saved) await _settings.restoreClickVolumeCheckpoint(checkpoint);
        return _reportClick(
          ClickVolumeOutcome(
            current()
                ? ClickVolumeStatus.rejected
                : ClickVolumeStatus.superseded,
            engineResult: result,
          ),
        );
      }
      _releasedClick = releasedVolume;
      _acceptedClickLifetime = lifetime;
      if (publish) emit(state.copyWith(clickVolume: volume, clickReady: true));
      if (ordinary) _ordinaryClick.add(volume);
      return _reportClick(
        ClickVolumeOutcome(ClickVolumeStatus.applied, deferred: deferred),
      );
    } on Object catch (error) {
      if (saved) {
        try {
          await _settings.restoreClickVolumeCheckpoint(checkpoint);
        } on Object catch (restoreError) {
          final recovery = await _recoverFailedClick(
            checkpoint,
            priorDurable,
            false,
            lifetime: lifetime,
            error: restoreError,
          );
          return recovery;
        }
      }
      return _reportClick(
        ClickVolumeOutcome(ClickVolumeStatus.rejected, error: error),
      );
    } finally {
      _clickBusy = false;
      if (_acceptedClickLifetime != clickVolumeLifetime) _syncFromRepository();
    }
  }

  Future<ClickVolumeOutcome> _recoverFailedClick(
    double? checkpoint,
    double priorDurable,
    bool restore, {
    required ClickVolumeLifetime lifetime,
    EngineResult? result,
    Object? error,
  }) async {
    final sameLifetime = lifetime == clickVolumeLifetime;
    if (sameLifetime && !_repository.clickVolumeRecoveryRequired) {
      _repository
        ..blockStartForClickRecovery()
        ..stopEngine();
    }
    _releasedClick = null;
    _clickRecovery = (
      checkpoint: checkpoint,
      volume: priorDurable,
      lifetime: sameLifetime ? clickVolumeLifetime : lifetime,
    );
    var failureError = error;
    if (restore) {
      try {
        await _settings.restoreClickVolumeCheckpoint(checkpoint);
      } on Object catch (failure) {
        failureError = failure;
      }
    }
    return _reportClick(
      ClickVolumeOutcome(
        ClickVolumeStatus.recoveryRequired,
        engineResult: result,
        error: failureError,
      ),
    );
  }

  /// Sets and persists the count-in length in measures (`0` = off), applying
  /// it now. Unconditional repository call — see [setTempo]'s doc. A
  /// count-in clears Sound start (the engine's rule, D9), persisted here too
  /// so a restart does not bring Sound start back over it.
  Future<void> setCountInBars(int bars) async {
    final clamped = bars < 0 ? 0 : bars;
    _userEditRevision++;
    if (!_repository.setCountIn(clamped).isOk) return;
    emit(state.copyWith(countInBars: clamped));

    await Future.wait([
      _settings.saveCountInBars(clamped),
      if (clamped > 0) _settings.saveAutoRecord(value: false),
    ]);
  }

  /// Registers a tempo tap; two taps within the engine's window set the
  /// tempo from their interval. A momentary action forwarded straight to the
  /// repository — never persisted (see the class doc).
  EngineResult tapTempo() {
    _userEditRevision++;
    return _repository.tapTempo();
  }
}

final class _ClickModeRefusal implements Exception {
  const _ClickModeRefusal(this.status, {this.result});
  final ClickModeStatus status;
  final EngineResult? result;
}
