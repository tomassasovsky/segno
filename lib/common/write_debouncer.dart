import 'dart:async';

/// Trailing-debounces persistence writes, one pending write per target.
///
/// An FX chain persists as ONE encoded envelope per target, so a knob drag —
/// which emits a parameter change per pointer move — used to re-encode and
/// rewrite that whole envelope at pointer rate. The store behind it is
/// `SharedPreferencesAsync`, the uncached API: every write is a platform
/// channel round trip and, on Linux, a full preferences-file rewrite. On the
/// appliance that lands on the same isolate whose blocking IO already cost
/// audible dropouts once (#804/#806).
///
/// **Only the persistence is coalesced.** Every caller writes to the engine
/// first and unconditionally, so nothing audible waits on a timer; what the
/// user is dragging still moves the audio on the move that dragged it.
///
/// [schedule] keeps the LATEST closure per key and re-arms that key's timer.
/// The closure is invoked at flush time and reads its value from the
/// authority then, so a coalesced burst persists the final value rather than
/// replaying a stale snapshot. A zero [debounce] writes straight through and
/// arms no timer at all — what tests pass so a pumped frame does not have to
/// outlive a pending write. Mirrors `ControlCubit._scheduleMappingsWrite`,
/// which coalesces the controller-mapping blob the same way.
class WriteDebouncer {
  /// Creates a [WriteDebouncer] coalescing over [debounce].
  WriteDebouncer({this.debounce = const Duration(milliseconds: 300)});

  /// How long a target stays quiet before its pending write goes out.
  final Duration debounce;

  final Map<Object, Timer> _timers = {};
  final Map<Object, void Function()> _pending = {};

  /// Whether any write is waiting to go out.
  bool get hasPending => _pending.isNotEmpty;

  /// Queues [write] for [key], replacing anything already queued for it.
  void schedule(Object key, void Function() write) {
    if (debounce <= Duration.zero) {
      write();
      return;
    }
    _pending[key] = write;
    _timers.remove(key)?.cancel();
    _timers[key] = Timer(debounce, () => _flushKey(key));
  }

  /// Runs every pending write now. Called from the owner's `close()` so a drag
  /// followed by a shutdown is not lost.
  void flush() => _pending.keys.toList().forEach(_flushKey);

  /// Drops every pending write without running it — for when something has
  /// superseded them all (a session load replacing every chain), where
  /// flushing would write values the new truth has already replaced.
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
  }

  void _flushKey(Object key) {
    _timers.remove(key)?.cancel();
    _pending.remove(key)?.call();
  }
}
