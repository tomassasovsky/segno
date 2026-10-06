import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/model/owned_setting.dart';

/// What one owned setting contributes to the shared transaction: its storage
/// checkpoints, its native command and its receipt. Everything else is
/// [SettingsOwner]'s, identical for every family.
///
/// A family's value [V] may span several addresses (the default and each
/// track); each address has its own stored checkpoint [C]. A unit family has
/// the one address null.
abstract interface class SettingsFamily<V extends Object, C> {
  /// Keys the family's notice and names it in logs.
  OwnedSetting get key;

  /// Every address, in load order.
  List<Object?> get addresses;

  /// Whether [value] is a value this family can hold.
  bool validate(V value);

  /// Reads [address]'s exact stored checkpoint, including absence. Throws
  /// when the stored data cannot be decoded.
  Future<C> readCheckpoint(Object? address);

  /// Writes and verifies [address]'s [checkpoint], including absence.
  Future<void> writeCheckpoint(Object? address, C checkpoint);

  /// [address]'s checkpoint for the [durable] value.
  C checkpointOf(V durable, Object? address);

  /// The durable value after a write to [address]: [durable] with [address]
  /// taken from [written]. A unit family returns [written].
  V durableAfter(V durable, V written, Object? address);

  /// The value a startup replays for every address's checkpoint, absence
  /// included.
  V restoreValue(Map<Object?, C> checkpoints);

  /// What Retry writes over [address]'s stored data while it stays unreadable.
  C repair(Object? address);

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

  /// Stages or enqueues [live], with [durable] for restart. [edit] is the
  /// family's own edit tag from the write; null for a restore.
  EngineResult request(V live, V durable, Object? edit);

  /// Awaits the pending receipt.
  Future<EngineResult> settle();

  /// Re-requests the owed durable value.
  EngineResult recover();
}

/// Stages [family]'s stored value into the stopped engine before audio
/// opens. Throws when the stored value is unreadable or refused; the owner's
/// load and Retry then own the recovery.
Future<void> stageStored<V extends Object, C>(
  SettingsFamily<V, C> family,
) async {
  final value = family.restoreValue(await _readAll(family));
  final request = family.request(value, value, null);
  final result = request.isOk ? await family.settle() : request;
  if (!result.isOk) {
    throw StateError('${family.key.name} replay refused: ${result.name}');
  }
}

Future<Map<Object?, C>> _readAll<V extends Object, C>(
  SettingsFamily<V, C> family,
) async => {
  for (final address in family.addresses)
    address: await family.readCheckpoint(address),
};

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
  final _ordinary = StreamController<({Object? address, V value})>.broadcast(
    sync: true,
  );
  final _failures = StreamController<SettingOutcome>.broadcast(sync: true);
  final _changes = StreamController<void>.broadcast(sync: true);
  final _recovered = StreamController<void>.broadcast(sync: true);
  bool _recoveryReported = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _loadFuture;
  Future<void>? _closeFuture;
  _Slot<V>? _waiting;
  late SettingLifetime _lifetime;
  final _revisions = <Object?, int>{};
  bool _initialized = false;
  bool _reading = false;
  bool _busy = false;
  bool _closing = false;
  Object? _unreadable;
  int? _loadSession;
  ({Object? address, C checkpoint})? _owedRollback;
  SettingOutcome _last = const SettingOutcome(SettingStatus.rejected);

  /// The family this owner carries.
  OwnedSetting get key => _family.key;

  /// Current session and device identity; capture it before queuing work.
  SettingLifetime get lifetime => (
    sessionRevision: _repository.sessionRevision,
    mixGeneration: _repository.mixGeneration,
  );

  /// Accepted ordinary-intent revision of a unit family within this lifetime.
  int get revision => revisionOf(null);

  /// Accepted ordinary-intent revision of [address] within this lifetime.
  int revisionOf(Object? address) => _revisions[address] ?? 0;

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

  /// Accepted ordinary values, with the address each one wrote.
  Stream<({Object? address, V value})> get ordinaryChanges => _ordinary.stream;

  /// Every refusal and recovery obligation, reported once.
  Stream<SettingOutcome> get failures => _failures.stream;

  /// Fires whenever readiness or the reported outcome changes.
  Stream<void> get changes => _changes.stream;

  /// Fires when a reported recovery resolves, including outside Retry: a
  /// restart or reconnect replay that lands the owed value.
  Stream<void> get recovered => _recovered.stream;

  /// Restores the stored value once. Unreadable storage makes only this
  /// family unavailable.
  Future<void> load() => _loadFuture ??= _restore();

  /// Ordinary intent; a newer write to the same [address] with the same
  /// [edit] replaces one still waiting.
  Future<SettingOutcome> set(V value, {Object? address, Object? edit}) =>
      update((_) => value, address: address, edit: edit);

  /// Ordinary intent computed from the live value when the write runs, so a
  /// queued edit composes with the one admitted before it.
  Future<SettingOutcome> update(
    V Function(V live) change, {
    Object? address,
    Object? edit,
  }) => _admit(
    _Write(
      change,
      address: address,
      lifetime: lifetime,
      edit: edit,
      ordinary: true,
    ),
  );

  /// Controller intent fenced by its origin; [released] is the durable value
  /// while [value] is held.
  Future<SettingOutcome> setController(
    V value, {
    required SettingLifetime lifetime,
    int? revision,
    V? released,
    Object? address,
  }) => updateController(
    (_) => value,
    address: address,
    lifetime: lifetime,
    revision: revision,
    released: released == null ? null : (_) => released,
  );

  /// Controller intent computed from the live value, fenced by [address]'s
  /// revision; [released] derives the value whose [address] entry becomes
  /// durable from the held one.
  Future<SettingOutcome> updateController(
    V Function(V live) change, {
    required SettingLifetime lifetime,
    int? revision,
    V Function(V held)? released,
    Object? edit,
    Object? address,
  }) => _admit(
    _Write(
      change,
      address: address,
      lifetime: lifetime,
      revision: revision,
      released: released,
      edit: edit,
    ),
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
          await _family.writeCheckpoint(owed.address, owed.checkpoint);
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
      _recovered.close(),
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
    final waiting = _waiting;
    final sameAddress = waiting?.write.address == write.address;
    if (waiting != null &&
        sameAddress &&
        waiting.write.ordinary &&
        write.revision != null) {
      // A newer ordinary choice already supersedes this origin's revision.
      write.done.complete(const SettingOutcome(SettingStatus.superseded));
      return write.done.future;
    }
    if (waiting != null && sameAddress && waiting.write.edit == write.edit) {
      // Latest wins per address and edit: one storage write per receipt.
      waiting.write.done.complete(
        const SettingOutcome(SettingStatus.superseded),
      );
      waiting.write = write;
      return write.done.future;
    }
    // Another address or edit queues behind the waiting one, in order.
    final slot = _waiting = _Slot(write);
    unawaited(
      load().then(
        (_) => _queue(() async {
          if (identical(_waiting, slot)) _waiting = null;
          final next = slot.write;
          next.done.complete(await _write(next));
        }),
      ),
    );
    return write.done.future;
  }

  Future<SettingOutcome> _write(_Write<V> write) async {
    bool current() =>
        !_closing &&
        write.lifetime == lifetime &&
        (write.revision == null || write.revision == revisionOf(write.address));
    if (!current()) return const SettingOutcome(SettingStatus.superseded);
    // An owed receipt may be replaying right now; the settle below waits for
    // it and the check after it refuses only a value still owed.
    if (!_initialized || _unreadable != null || _owedRollback != null) {
      return _report(
        SettingOutcome(
          _recoveryPending
              ? SettingStatus.recoveryRequired
              : SettingStatus.rejected,
          engineResult: EngineResult.notReady,
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
      // The value is computed from what the engine accepted last.
      final V value;
      final V durable;
      try {
        value = write.change(_family.live);
        durable = _family.durableAfter(
          _family.durable,
          write.released?.call(value) ?? value,
          write.address,
        );
      } on Object {
        // A change that cannot build a valid value is refused, not thrown.
        return _report(
          const SettingOutcome(
            SettingStatus.rejected,
            engineResult: EngineResult.invalid,
          ),
        );
      }
      if (!_family.validate(value) || !_family.validate(durable)) {
        return _report(
          const SettingOutcome(
            SettingStatus.rejected,
            engineResult: EngineResult.invalid,
          ),
        );
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
        checkpoint = await _family.readCheckpoint(write.address);
      } on Object catch (error) {
        return _report(
          SettingOutcome(SettingStatus.rejected, error: error),
        );
      }
      if (!current()) return const SettingOutcome(SettingStatus.superseded);
      try {
        await _family.writeCheckpoint(
          write.address,
          _family.checkpointOf(durable, write.address),
        );
      } on Object catch (error) {
        // A write may land and then throw: restore the exact checkpoint.
        return await _rollback(
          write.address,
          checkpoint,
          SettingStatus.rejected,
          error: error,
        );
      }
      if (!current()) {
        return await _rollback(
          write.address,
          checkpoint,
          SettingStatus.superseded,
        );
      }
      if (_family.captureLocked) {
        return await _rollback(
          write.address,
          checkpoint,
          SettingStatus.rejected,
          engineResult: EngineResult.notReady,
        );
      }
      final deferred = !_running;
      final admission = _family.request(value, durable, write.edit);
      final result = admission.isOk ? await _family.settle() : admission;
      if (result.isOk) {
        // Committed: the engine holds this value now, so storage keeps it
        // even when the lifetime moved on before this resumed.
        if (write.ordinary) {
          _revisions[write.address] = revisionOf(write.address) + 1;
          if (!_ordinary.isClosed) {
            _ordinary.add((address: write.address, value: value));
          }
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
        write.address,
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
    Object? address,
    C checkpoint,
    SettingStatus status, {
    EngineResult? engineResult,
    Object? error,
  }) async {
    try {
      await _family.writeCheckpoint(address, checkpoint);
    } on Object catch (rollbackError) {
      _owedRollback = (address: address, checkpoint: checkpoint);
      return _report(
        SettingOutcome(SettingStatus.recoveryRequired, error: rollbackError),
      );
    }
    return _report(
      SettingOutcome(status, engineResult: engineResult, error: error),
    );
  }

  Future<void> _repairStorage() async {
    for (final address in _family.addresses) {
      try {
        // A transient read failure reads cleanly now and needs no repair.
        await _family.readCheckpoint(address);
      } on Object catch (error) {
        await _family.writeCheckpoint(address, _family.repair(address));
        AppLog.warn(
          '${_family.key.name}: replaced unreadable stored value: '
          '$error',
        );
      }
    }
    _unreadable = null;
  }

  Future<void> _restore() async {
    // The stored preference belongs to the session the first load ran in.
    // A re-run after a recalled Session must not replace the Session's value.
    final session = _loadSession ??= _repository.sessionRevision;
    Map<Object?, C>? checkpoints;
    _reading = true;
    try {
      checkpoints = await _readAll(_family);
    } on Object catch (error) {
      // A recalled session is newer authority than a failed startup read.
      if (session == _repository.sessionRevision) {
        _unreadable = error;
        _report(SettingOutcome(SettingStatus.recoveryRequired, error: error));
        return;
      }
    } finally {
      _reading = false;
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
          if (checkpoints != null && origin.sessionRevision == session) {
            final value = _family.restoreValue(checkpoints);
            final admission = _family.request(value, value, null);
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
    if (_closing || _busy) return;
    // A Session recalled during the startup read is the value: the family is
    // available now, and the read that returns later restores nothing.
    if (_reading &&
        !_initialized &&
        _repository.sessionRevision != _loadSession) {
      _initialized = true;
      _changed();
    }
    if (_lifetime != lifetime) {
      _lifetime = lifetime;
      _revisions.clear();
      _changed();
    }
    if (_recoveryReported && ready) {
      _recoveryReported = false;
      if (!_recovered.isClosed) _recovered.add(null);
      _changed();
    }
  }

  SettingOutcome _report(SettingOutcome outcome) {
    if (outcome.status == SettingStatus.superseded) return outcome;
    _last = outcome;
    if (outcome.status == SettingStatus.recoveryRequired) {
      _recoveryReported = true;
    }
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
    this.change, {
    required this.lifetime,
    this.address,
    this.revision,
    this.released,
    this.edit,
    this.ordinary = false,
  });
  final V Function(V live) change;
  final Object? address;
  final SettingLifetime lifetime;
  final int? revision;
  final V Function(V held)? released;
  final Object? edit;
  final bool ordinary;
  final done = Completer<SettingOutcome>();
}

/// A queued write not yet started; a write to the same address with the same
/// edit replaces its content.
final class _Slot<V> {
  _Slot(this.write);
  _Write<V> write;
}
