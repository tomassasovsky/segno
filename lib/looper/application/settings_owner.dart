import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/model/owned_setting.dart';

/// What one owned setting contributes to the shared transaction: its storage
/// checkpoint, its native command and its receipt. Everything else is
/// [SettingsOwner]'s, identical for every family.
abstract interface class SettingsFamily<V extends Object, C> {
  /// Names the family in logs.
  String get name;

  /// Whether [value] is a value this family can hold.
  bool validate(V value);

  /// Reads the exact stored checkpoint, including absence. Throws when the
  /// stored data cannot be decoded.
  Future<C> readCheckpoint();

  /// Writes and verifies [checkpoint], including absence.
  Future<void> writeCheckpoint(C checkpoint);

  /// [checkpoint] with [durable] stored in it.
  C withDurable(C checkpoint, V durable);

  /// The value a startup replays for [checkpoint], absence included.
  V restoreValue(C checkpoint);

  /// What Retry writes over stored data that stays unreadable.
  C repair();

  /// The accepted live value, including a temporary controller value.
  V get live;

  /// The accepted durable value that restart and Session capture use.
  V get durable;

  /// Whether an active take refuses this family's edits.
  bool get captureLocked;

  /// Whether an uncertain receipt owes its durable value.
  bool get recoveryRequired;

  /// Refusals and uncertainty reported by the receipt.
  Stream<EngineResult> get failures;

  /// Stages or enqueues [live], with [durable] for restart.
  EngineResult request(V live, V durable);

  /// Awaits the pending receipt.
  Future<EngineResult> settle();

  /// Re-requests the owed durable value.
  EngineResult recover();
}

/// The one settings transaction: load, ordinary and controller writes,
/// flush, recovery and Session exclusion for one [SettingsFamily].
///
/// A write commits on acceptance: it reads the checkpoint, stores the durable
/// value, requests it and settles the receipt. Accepted is final, even if the
/// session or device moved on meanwhile. A refusal rolls storage back. An
/// uncertain receipt keeps the durable value in storage, because that is what
/// Retry re-requests and a restart replays. Nothing here stops audio.
class SettingsOwner<V extends Object, C> {
  /// Owns [family] over [repository]'s session and device lifetime.
  SettingsOwner({
    required LooperRepository repository,
    required SettingsFamily<V, C> family,
  }) : _repository = repository,
       _family = family {
    _lifetime = lifetime;
    _stateSubscription = repository.looperState.listen((_) => _sync());
    _failureSubscription = family.failures.listen(_onReceiptFailure);
  }

  final LooperRepository _repository;
  final SettingsFamily<V, C> _family;
  late final StreamSubscription<LooperState> _stateSubscription;
  late final StreamSubscription<EngineResult> _failureSubscription;
  final _ordinary = StreamController<V>.broadcast(sync: true);
  final _failures = StreamController<SettingOutcome>.broadcast(sync: true);
  final _changes = StreamController<void>.broadcast(sync: true);
  Future<void> _tail = Future<void>.value();
  Future<void>? _loadFuture;
  Future<void>? _closeFuture;
  _Write<V>? _waiting;
  late SettingLifetime _lifetime;
  int _revision = 0;
  bool _initialized = false;
  bool _busy = false;
  bool _closing = false;
  Object? _unreadable;
  ({C checkpoint})? _owedRollback;
  SettingOutcome _last = const SettingOutcome(SettingStatus.rejected);

  /// Current session and device identity; capture it before queuing work.
  SettingLifetime get lifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  /// Accepted ordinary-intent revision within this lifetime.
  int get revision => _revision;

  /// Whether a load has ever confirmed a value.
  bool get initialized => _initialized;

  /// Unreadable storage, an owed rollback or an uncertain receipt.
  bool get _recoveryPending =>
      _unreadable != null || _owedRollback != null || _family.recoveryRequired;

  /// Whether a new value can be admitted; an in-flight write does not count.
  bool get ready => _initialized && !_recoveryPending && !_closing;

  /// The live value for readouts; null while unavailable.
  V? get value => ready ? _family.live : null;

  /// The accepted live value, whether or not the family is available.
  V get live => _family.live;

  /// The durable value for storage and Session capture.
  V get durable => _family.durable;

  /// Whether an active take refuses edits.
  bool get captureLocked => _family.captureLocked;

  /// Accepted ordinary values.
  Stream<V> get ordinaryChanges => _ordinary.stream;

  /// Every refusal and recovery obligation, reported once.
  Stream<SettingOutcome> get failures => _failures.stream;

  /// Fires whenever readiness or the reported outcome changes.
  Stream<void> get changes => _changes.stream;

  /// Restores the stored value once. Unreadable storage makes only this
  /// family unavailable.
  Future<void> load() => _loadFuture ??= _restore();

  /// Ordinary intent; a newer write replaces one still waiting.
  Future<SettingOutcome> set(V value) =>
      _admit(_Write(value, lifetime: lifetime, ordinary: true));

  /// Controller intent fenced by its origin; [released] is the durable value
  /// while [value] is held.
  Future<SettingOutcome> setController(
    V value, {
    required SettingLifetime lifetime,
    int? revision,
    V? released,
  }) => _admit(
    _Write(value, lifetime: lifetime, revision: revision, released: released),
  );

  /// Drains admitted writes and settles the receipt. The outcome reflects the
  /// current flags only, never an earlier write's result.
  Future<SettingOutcome> flush() async {
    await load();
    await _queue(_family.settle);
    if (!_initialized || _recoveryPending) {
      return _report(
        const SettingOutcome(
          SettingStatus.recoveryRequired,
          engineResult: EngineResult.notReady,
        ),
      );
    }
    return SettingOutcome(SettingStatus.applied, deferred: !_running);
  }

  /// Retry: repairs unreadable storage, restores an owed rollback, re-requests
  /// an owed native value and finishes a failed load. Never stops audio.
  Future<SettingOutcome> recover() async {
    await load();
    final outcome = await _queue(() async {
      if (_closing) return const SettingOutcome(SettingStatus.rejected);
      _busy = true;
      try {
        if (_unreadable != null) await _repairStorage();
        if (_owedRollback case final owed?) {
          await _family.writeCheckpoint(owed.checkpoint);
          _owedRollback = null;
        }
        if (_family.recoveryRequired) {
          final result = _family.recover();
          if (!result.isOk) {
            return _report(
              SettingOutcome(
                SettingStatus.recoveryRequired,
                engineResult: result,
              ),
            );
          }
        }
        final result = await _family.settle();
        if (_recoveryPending) {
          return _report(
            SettingOutcome(
              SettingStatus.recoveryRequired,
              engineResult: result,
            ),
          );
        }
        return _report(
          SettingOutcome(SettingStatus.applied, deferred: !_running),
        );
      } on Object catch (error) {
        return _report(
          SettingOutcome(SettingStatus.recoveryRequired, error: error),
        );
      } finally {
        _busy = false;
        _sync();
      }
    });
    if (outcome.isOk && !_initialized && !_closing) {
      await (_loadFuture = _restore());
      return _last;
    }
    return outcome;
  }

  /// Excludes writes while Session capture or replacement runs. An
  /// unavailable family does not refuse: capture uses the durable value.
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    await load();
    return _queue(() async {
      await _family.settle();
      return operation();
    });
  }

  /// Lets admitted work finish, then closes the streams.
  Future<void> close() => _closeFuture ??= _close();

  bool get _running => _repository.sessionTransport.isRunning;

  Future<void> _close() async {
    _closing = true;
    await _loadFuture;
    await _tail;
    await _stateSubscription.cancel();
    await _failureSubscription.cancel();
    await Future.wait([
      _ordinary.close(),
      _failures.close(),
      _changes.close(),
    ]);
  }

  Future<T> _queue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SettingOutcome> _admit(_Write<V> write) {
    final replaced = _waiting;
    _waiting = write;
    if (replaced != null) {
      // Latest wins: one storage write per in-flight receipt.
      replaced.done.complete(const SettingOutcome(SettingStatus.superseded));
    } else {
      unawaited(
        load().then(
          (_) => _queue(() async {
            final next = _waiting!;
            _waiting = null;
            next.done.complete(await _write(next));
          }),
        ),
      );
    }
    return write.done.future;
  }

  Future<SettingOutcome> _write(_Write<V> write) async {
    bool current() =>
        !_closing &&
        write.lifetime == lifetime &&
        (write.revision == null || write.revision == _revision);
    if (!current()) return const SettingOutcome(SettingStatus.superseded);
    if (!_initialized || _recoveryPending) {
      return _report(
        SettingOutcome(
          _recoveryPending
              ? SettingStatus.recoveryRequired
              : SettingStatus.rejected,
          engineResult: EngineResult.notReady,
        ),
      );
    }
    final durable = write.released ?? write.value;
    if (!_family.validate(write.value) || !_family.validate(durable)) {
      return _report(
        const SettingOutcome(
          SettingStatus.rejected,
          engineResult: EngineResult.invalid,
        ),
      );
    }
    _busy = true;
    try {
      // A restart replay or Session receipt lands before this admission.
      await _family.settle();
      if (!current()) return const SettingOutcome(SettingStatus.superseded);
      if (_family.recoveryRequired) {
        return _report(const SettingOutcome(SettingStatus.recoveryRequired));
      }
      if (_family.captureLocked) {
        return _report(
          const SettingOutcome(
            SettingStatus.rejected,
            engineResult: EngineResult.notReady,
          ),
        );
      }
      final C checkpoint;
      try {
        checkpoint = await _family.readCheckpoint();
      } on Object catch (error) {
        return _report(
          SettingOutcome(SettingStatus.rejected, error: error),
        );
      }
      if (!current()) return const SettingOutcome(SettingStatus.superseded);
      try {
        await _family.writeCheckpoint(_family.withDurable(checkpoint, durable));
      } on Object catch (error) {
        // A write may land and then throw: restore the exact checkpoint.
        return await _rollback(
          checkpoint,
          SettingStatus.rejected,
          error: error,
        );
      }
      if (!current()) {
        return await _rollback(checkpoint, SettingStatus.superseded);
      }
      if (_family.captureLocked) {
        return await _rollback(
          checkpoint,
          SettingStatus.rejected,
          engineResult: EngineResult.notReady,
        );
      }
      final deferred = !_running;
      final admission = _family.request(write.value, durable);
      final result = admission.isOk ? await _family.settle() : admission;
      if (result.isOk) {
        // Committed: the engine holds this value now, so storage keeps it
        // even when the lifetime moved on before this resumed.
        if (write.ordinary) {
          _revision++;
          if (!_ordinary.isClosed) _ordinary.add(write.value);
        }
        return _report(
          SettingOutcome(SettingStatus.applied, deferred: deferred),
        );
      }
      if (_family.recoveryRequired && _family.durable == durable) {
        // Uncertain: storage already holds the value Retry re-requests.
        return _report(
          SettingOutcome(SettingStatus.recoveryRequired, engineResult: result),
        );
      }
      return await _rollback(
        checkpoint,
        _family.recoveryRequired
            ? SettingStatus.recoveryRequired
            : current()
            ? SettingStatus.rejected
            : SettingStatus.superseded,
        engineResult: result,
      );
    } finally {
      _busy = false;
      _sync();
    }
  }

  Future<SettingOutcome> _rollback(
    C checkpoint,
    SettingStatus status, {
    EngineResult? engineResult,
    Object? error,
  }) async {
    try {
      await _family.writeCheckpoint(checkpoint);
    } on Object catch (rollbackError) {
      _owedRollback = (checkpoint: checkpoint);
      return _report(
        SettingOutcome(SettingStatus.recoveryRequired, error: rollbackError),
      );
    }
    return _report(
      SettingOutcome(status, engineResult: engineResult, error: error),
    );
  }

  Future<void> _repairStorage() async {
    try {
      // A transient read failure reads cleanly now and needs no repair.
      await _family.readCheckpoint();
    } on Object catch (error) {
      await _family.writeCheckpoint(_family.repair());
      AppLog.warn('${_family.name}: replaced unreadable stored value: $error');
    }
    _unreadable = null;
  }

  Future<void> _restore() async {
    final session = _repository.sessionRevision;
    C? checkpoint;
    var read = false;
    try {
      checkpoint = await _family.readCheckpoint();
      read = true;
    } on Object catch (error) {
      // A recalled session is newer authority than a failed startup read.
      if (session == _repository.sessionRevision) {
        _unreadable = error;
        _report(SettingOutcome(SettingStatus.recoveryRequired, error: error));
        return;
      }
    }
    while (!_closing) {
      final origin = lifetime;
      final done = await _queue(() async {
        if (_closing) return true;
        if (origin != lifetime) return false;
        _busy = true;
        try {
          await _family.settle();
          if (_closing) return true;
          if (origin != lifetime) return false;
          if (_family.recoveryRequired) {
            _report(const SettingOutcome(SettingStatus.recoveryRequired));
            return true;
          }
          if (read && origin.sessionRevision == session) {
            final value = _family.restoreValue(checkpoint as C);
            final admission = _family.request(value, value);
            final result = admission.isOk ? await _family.settle() : admission;
            if (_closing) return true;
            if (!result.isOk) {
              // A retired lifetime never published; restore into the new one.
              if (origin != lifetime && !_family.recoveryRequired) {
                return false;
              }
              _report(
                SettingOutcome(
                  SettingStatus.recoveryRequired,
                  engineResult: result,
                ),
              );
              return true;
            }
          }
          _initialized = true;
          _report(const SettingOutcome(SettingStatus.applied));
          return true;
        } finally {
          _busy = false;
          _sync();
        }
      });
      if (done) return;
    }
  }

  void _onReceiptFailure(EngineResult result) {
    // The owner's own operation reports its receipt; this is autonomous work.
    if (_busy || _closing) return;
    _report(
      SettingOutcome(
        _family.recoveryRequired
            ? SettingStatus.recoveryRequired
            : SettingStatus.rejected,
        engineResult: result,
      ),
    );
  }

  void _sync() {
    if (_closing || _busy || _lifetime == lifetime) return;
    _lifetime = lifetime;
    _revision = 0;
    _changed();
  }

  SettingOutcome _report(SettingOutcome outcome) {
    if (outcome.status == SettingStatus.superseded) return outcome;
    _last = outcome;
    if (!_closing && !outcome.isOk && !_failures.isClosed) {
      _failures.add(outcome);
    }
    _changed();
    return outcome;
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

final class _Write<V> {
  _Write(
    this.value, {
    required this.lifetime,
    this.revision,
    this.released,
    this.ordinary = false,
  });
  final V value;
  final SettingLifetime lifetime;
  final int? revision;
  final V? released;
  final bool ordinary;
  final done = Completer<SettingOutcome>();
}
