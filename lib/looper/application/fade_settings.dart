import 'dart:async';
import 'dart:convert';

import 'package:settings_repository/settings_repository.dart';

/// Owns confirmed next-gesture setup and exact storage repair, never audio
/// state.
class FadeSettings {
  /// Borrows the existing store and Session/shutdown admission predicate.
  FadeSettings({
    required SettingsRepository settings,
    required bool Function() blocked,
    required bool Function() sessionBlocked,
  }) : _settings = settings,
       _blocked = blocked,
       _sessionBlocked = sessionBlocked;

  final SettingsRepository _settings;
  final bool Function() _blocked;
  final bool Function() _sessionBlocked;
  final _results = StreamController<Object?>.broadcast();
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  FadeDurations _confirmed = FadeDurations.defaults;
  // A record distinguishes an owed removal from no repair obligation.
  ({String? bytes})? _repair;
  bool _loaded = false;
  bool _closing = false;
  int _exclusive = 0;

  /// Storage errors, or null after confirmation, for existing notices.
  Stream<Object?> get results => _results.stream;

  /// Whether explicit load/repair is needed before dependent operations.
  bool get needsRecovery => !_loaded || _repair != null;

  /// The last confirmed snapshot; refuses capture during uncertain storage.
  FadeDurations get confirmed {
    if (needsRecovery) throw StateError('Fade duration settings need recovery');
    return _confirmed;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Restores one strict record; a missing record alone uses defaults.
  Future<void> load() {
    if (_closing) return Future<void>.value();
    return _enqueue(() async {
      if (_loaded) return;
      try {
        await _read();
      } on Object catch (error) {
        _results.add(error);
        rethrow;
      }
    });
  }

  Future<void> _read() async {
    final record = await _settings.readFadeDurationsCheckpoint();
    _confirmed = record == null
        ? FadeDurations.defaults
        : FadeDurations.fromJson(jsonDecode(record));
    _loaded = true;
    _results.add(null);
  }

  /// Changes Default for subsequent gestures, retaining Custom memberships.
  Future<void> setDefault(int milliseconds) => _edit(
    (value) =>
        FadeDurations(defaultMs: milliseconds, overrides: value.overrides),
  );

  /// Sets Custom, or removes it to inherit Default. Equality remains Custom.
  Future<void> setOverride(int channel, int? milliseconds) => _edit((value) {
    value.effectiveMs(channel); // Validate even a removal of an absent slot.
    final overrides = {...value.overrides};
    if (milliseconds == null) {
      overrides.remove(channel);
    } else {
      overrides[channel] = milliseconds;
    }
    return FadeDurations(defaultMs: value.defaultMs, overrides: overrides);
  });

  /// Moves Default, or one track's effective time ([channel] non-null), by
  /// [deltaMs] within 0.5–30 s. Applied to the value confirmed when the edit
  /// runs, so rapid steps queued behind a pending write each count. Stepping
  /// an inherited track time creates its override; an edge step is a no-op.
  Future<void> step({required int deltaMs, int? channel}) => _edit((value) {
    final current = channel == null
        ? value.defaultMs
        : value.effectiveMs(channel);
    final next = (current + deltaMs).clamp(500, 30000);
    if (next == current) return value;
    if (channel == null) {
      return FadeDurations(defaultMs: next, overrides: value.overrides);
    }
    return FadeDurations(
      defaultMs: value.defaultMs,
      overrides: {...value.overrides, channel: next},
    );
  });

  Future<void> _edit(FadeDurations Function(FadeDurations) change) {
    if (_closing || _exclusive != 0 || _blocked()) {
      return Future<void>.error(
        StateError('Fade duration edit is unavailable'),
      );
    }
    return _enqueue(() async {
      final next = change(confirmed);
      if (next == _confirmed) return;
      try {
        await _persist(next);
      } on Object catch (error) {
        _results.add(error);
        rethrow;
      }
    });
  }

  Future<void> _persist(FadeDurations next) async {
    final checkpoint = await _settings.readFadeDurationsCheckpoint();
    try {
      await _settings.saveFadeDurations(next);
    } on Object {
      _repair = (bytes: checkpoint);
      try {
        await _repairStorage();
      } on Object {
        // Keep the exact checkpoint until explicit recovery confirms it.
      }
      rethrow;
    }
    _confirmed = next;
    _loaded = true;
    _results.add(null);
  }

  Future<void> _repairStorage() async {
    final repair = _repair;
    if (repair == null) return;
    await _settings.restoreFadeDurationsCheckpoint(repair.bytes);
    _repair = null;
  }

  /// Explicit ordinary Retry; accepted Session recovery uses its retained
  /// image.
  Future<bool> recover() {
    if (_closing || _exclusive != 0 || _sessionBlocked()) {
      return Future.value(false);
    }
    return _enqueue(() async {
      try {
        await _repairStorage();
        if (!_loaded) await _read();
        _results.add(null);
        return true;
      } on Object catch (error) {
        _results.add(error);
        return false;
      }
    });
  }

  /// Reserves synchronously while the caller reserves its existing owners.
  /// Await the supplied drain before Session I/O; never await this scope itself.
  Future<T> runExclusive<T>(
    Future<T> Function(Future<void> admittedEdits) action,
  ) {
    if (_closing) return Future.error(StateError('Fade settings are closing'));
    _exclusive++;
    final prior = _tail;
    final result = Future<T>.sync(
      () => action(prior),
    ).whenComplete(() => prior);
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result.whenComplete(() => _exclusive--);
  }

  /// Installs the accepted Session vector inside its existing exclusive scope.
  /// It deliberately does not enqueue behind the operation that holds the
  /// scope.
  Future<void> installSession(FadeDurations incoming) async {
    if (_exclusive == 0) throw StateError('Session exclusion is required');
    await _repairStorage();
    await _persist(incoming);
  }

  /// Confirms admitted writes before shutdown; never call inside the held
  /// scope.
  Future<void> flush() async {
    await _tail;
    confirmed;
  }

  /// Refuses new work immediately and drains already admitted storage
  /// operations.
  Future<void> close() {
    _closing = true;
    return _closeFuture ??= () async {
      try {
        await _tail;
      } finally {
        await _results.close();
      }
    }();
  }
}
