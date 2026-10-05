import 'dart:async';
import 'dart:convert';

import 'package:settings_repository/settings_repository.dart';

/// Owns confirmed next-gesture setup and exact storage repair, never audio
/// state.
///
/// A held controller value applies to the next gesture without becoming
/// durable: [live] carries it, while [confirmed] — the stored and
/// Session-captured image — keeps the controller's authored Released value.
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
  final _ordinary =
      StreamController<({int? channel, int? milliseconds})>.broadcast(
        sync: true,
      );
  final _revisions = <int?, int>{};
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  FadeDurations _confirmed = FadeDurations.defaults;
  FadeDurations _live = FadeDurations.defaults;
  // A record distinguishes an owed removal from no repair obligation.
  ({String? bytes})? _repair;
  bool _loaded = false;
  bool _closing = false;
  int _exclusive = 0;
  int _lifetime = 0;

  /// Storage errors, or null after confirmation, for existing notices.
  Stream<Object?> get results => _results.stream;

  /// Whether explicit load/repair is needed before dependent operations.
  bool get needsRecovery => !_loaded || _repair != null;

  /// The last confirmed snapshot; refuses capture during uncertain storage.
  FadeDurations get confirmed {
    if (needsRecovery) throw StateError('Fade duration settings need recovery');
    return _confirmed;
  }

  /// What the next gesture uses: [confirmed] plus any temporary held
  /// controller value. Refused, like [confirmed], during uncertain storage.
  FadeDurations get live {
    confirmed;
    return _live;
  }

  /// Identity of the installed Session's durations; a Session install
  /// replaces it, so controller work captured before it is superseded.
  int get lifetime => _lifetime;

  /// Ordinary intent revision of Default (null) or one track, independent of
  /// the other addresses.
  int revision(int? channel) => _revisions[channel] ?? 0;

  /// Accepted ordinary edits; a null track duration means Use default.
  Stream<({int? channel, int? milliseconds})> get ordinaryChanges =>
      _ordinary.stream;

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
    _confirmed = _live = record == null
        ? FadeDurations.defaults
        : FadeDurations.fromJson(jsonDecode(record));
    _loaded = true;
    _results.add(null);
  }

  /// Changes Default for subsequent gestures, retaining Custom memberships.
  Future<void> setDefault(int milliseconds) =>
      _edit(null, (_) => (milliseconds: milliseconds));

  /// Sets Custom, or removes it to inherit Default. Equality remains Custom.
  Future<void> setOverride(int channel, int? milliseconds) =>
      _edit(channel, (_) => (milliseconds: milliseconds));

  /// Moves Default, or one track's effective time ([channel] non-null), by
  /// [deltaMs] within 0.5–30 s. Applied to the [live] value when the edit
  /// runs, so rapid steps queued behind a pending write each count. Stepping
  /// an inherited track time creates its override; an edge step is a no-op.
  Future<void> step({required int deltaMs, int? channel}) =>
      _edit(channel, (live) {
        final current = channel == null
            ? live.defaultMs
            : live.effectiveMs(channel);
        final next = (current + deltaMs).clamp(500, 30000);
        return next == current ? null : (milliseconds: next);
      });

  /// Accepts one controller value for Default ([channel] null) or a track,
  /// and an optional authored durable Released value.
  ///
  /// [milliseconds] applies to the next gesture; [confirmed] stores
  /// [releasedMilliseconds] instead when given, so a temporary held value is
  /// never saved. Writing an inherited track creates its override. Completes
  /// false, without writing, once a Session install or an ordinary edit of the
  /// same address has replaced the captured [lifetime] or [revision].
  Future<bool> setControllerDuration(
    int? channel,
    int milliseconds, {
    required int lifetime,
    required int revision,
    int? releasedMilliseconds,
  }) {
    if (_closing) return Future.value(false);
    return _enqueue(() async {
      if (_closing ||
          needsRecovery ||
          lifetime != _lifetime ||
          revision != this.revision(channel)) {
        return false;
      }
      final FadeDurations durable;
      final FadeDurations next;
      try {
        durable = _with(
          _confirmed,
          channel,
          releasedMilliseconds ?? milliseconds,
        );
        next = _with(_live, channel, milliseconds);
      } on FormatException {
        return false;
      }
      try {
        await _commit(durable, next);
      } on Object catch (error) {
        _results.add(error);
        return false;
      }
      return true;
    });
  }

  /// [edit] returns the new explicit value at [channel] (null removes a
  /// track's override), or null itself for no change.
  Future<void> _edit(
    int? channel,
    ({int? milliseconds})? Function(FadeDurations live) edit,
  ) {
    if (_closing || _exclusive != 0 || _blocked()) {
      return Future<void>.error(
        StateError('Fade duration edit is unavailable'),
      );
    }
    return _enqueue(() async {
      final change = edit(live);
      if (change == null) return;
      final durable = _with(_confirmed, channel, change.milliseconds);
      final next = _with(_live, channel, change.milliseconds);
      if (durable == _confirmed && next == _live) return;
      try {
        await _commit(durable, next);
      } on Object catch (error) {
        _results.add(error);
        rethrow;
      }
      // An ordinary edit outranks older controller intent at this address.
      _revisions[channel] = revision(channel) + 1;
      _ordinary.add((channel: channel, milliseconds: change.milliseconds));
    });
  }

  /// [base] with Default ([channel] null) or one track's explicit value set;
  /// a null track value removes its override.
  static FadeDurations _with(
    FadeDurations base,
    int? channel,
    int? milliseconds,
  ) {
    if (channel == null) {
      if (milliseconds == null) {
        throw const FormatException('Fade Default needs a duration');
      }
      return FadeDurations(defaultMs: milliseconds, overrides: base.overrides);
    }
    base.effectiveMs(channel); // Validate even a removal of an absent slot.
    final overrides = {...base.overrides};
    if (milliseconds == null) {
      overrides.remove(channel);
    } else {
      overrides[channel] = milliseconds;
    }
    return FadeDurations(defaultMs: base.defaultMs, overrides: overrides);
  }

  /// Stores [durable] only when it changed, then publishes [next] as live.
  Future<void> _commit(FadeDurations durable, FadeDurations next) async {
    if (durable != _confirmed) {
      await _persist(durable, live: next);
    } else if (next != _live) {
      _live = next;
      _results.add(null);
    }
  }

  Future<void> _persist(FadeDurations next, {FadeDurations? live}) async {
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
    _live = live ?? next;
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
        if (!_loaded) {
          try {
            await _read();
          } on FormatException {
            // An unreadable record can never load; Retry repairs it to the
            // declared defaults rather than failing forever (fail safe).
            await _settings.saveFadeDurations(FadeDurations.defaults);
            await _read();
          }
        }
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
    // Controller intent captured for the outgoing Session is superseded,
    // and the incoming image replaces any temporary held value.
    _lifetime++;
    _live = _confirmed;
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
        await _ordinary.close();
        await _results.close();
      }
    }();
  }
}
