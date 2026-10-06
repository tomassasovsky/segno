import 'dart:async';

import 'package:segno_engine/segno_engine.dart' show EngineResult;

/// How the engine answered one admitted settings command.
enum ReceiptVerdict {
  /// The callback applied exactly the requested value.
  accepted,

  /// The callback refused and left the prior value intact.
  refused,

  /// The published state proves neither outcome.
  uncertain,
}

/// Classifies one admitted command from the engine's published state; null
/// while the receipt has not been published yet.
typedef ReceiptCheck =
    ({ReceiptVerdict verdict, EngineResult result})? Function();

/// Enqueues one native command for a value. A refused admission returns its
/// result and no check.
typedef ReceiptSend<T> =
    ({EngineResult result, ReceiptCheck? check}) Function(T value);

/// One settings family's native transaction: admission, callback receipt,
/// uncertainty and recovery. The family supplies only its native command and
/// how to read the receipt; everything else is the same for every family.
///
/// Uncertainty never stops audio. An expired or unreadable receipt leaves the
/// family needing recovery with the requested durable value owed. Retry
/// re-requests that value as a new receipt (the command ring is FIFO, so it
/// lands after any late one), and a fresh engine lifetime replays it.
final class SettingsReceipt<T extends Object> {
  /// Creates a receipt whose accepted and restart values start at [initial].
  SettingsReceipt(
    T initial, {
    required ReceiptSend<T> send,
    required bool Function() running,
    required void Function() publish,
  }) : _live = initial,
       _restart = initial,
       _send = send,
       _running = running,
       _publish = publish;

  final ReceiptSend<T> _send;
  final bool Function() _running;
  final void Function() _publish;
  T _live;
  T _restart;
  T? _owed;
  _Pending<T>? _pending;
  EngineResult _lastResult = EngineResult.ok;
  // Synchronous, so an owner hears a failure while its own write still awaits
  // the receipt and reports it once.
  final _failures = StreamController<EngineResult>.broadcast(sync: true);

  /// The last accepted value, including a temporary controller value.
  T get live => _live;

  /// The accepted durable value a device restart replays.
  T get restart => _owed ?? _restart;

  /// No command is awaiting its callback receipt.
  bool get settled => _pending == null;

  /// An uncertain receipt owes its durable value until Retry or a restart.
  bool get recoveryRequired => _owed != null;

  /// The most recent classified result; a cancelled waiter does not change it.
  EngineResult get lastResult => _lastResult;

  /// Refusals and uncertainty, including autonomous restart replays.
  Stream<EngineResult> get failures => _failures.stream;

  /// The pending receipt's observer, polled with the other settings receipts.
  ReceiptObservation? get observation => _pending?.observation;

  /// Stages [value] while stopped or requests it from the running engine.
  /// [restart] is the durable value when [value] is temporary.
  EngineResult request(T value, {T? restart}) {
    if (_pending != null || _owed != null) return EngineResult.notReady;
    return _admit(value, restart ?? value, startup: false);
  }

  /// Replays the owed or accepted durable value into a fresh engine lifetime.
  EngineResult replay() {
    final value = restart;
    return _admit(value, value, startup: true);
  }

  /// Retry: running, re-requests the owed value; stopped, stages it. Never
  /// stops audio.
  EngineResult recover() {
    final owed = _owed;
    if (owed == null) return EngineResult.ok;
    if (_pending != null) return EngineResult.notReady;
    return _admit(owed, owed, startup: false);
  }

  /// Awaits the pending receipt, bounded by the caller's budget and the
  /// admission deadline; returns the last result when nothing is pending.
  Future<EngineResult> settle({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) {
    final pending = _pending;
    if (pending == null) return Future.value(_lastResult);
    return pending.observation.wait(
      pollInterval: pollInterval,
      attempts: attempts,
    );
  }

  /// Retires the waiter of a lifetime that will never publish its receipt.
  void cancel() {
    final pending = _pending;
    _pending = null;
    pending?.observation.complete(EngineResult.notReady);
  }

  /// Adopts a value applied outside the receipt, as a Session reset does.
  void adopt(T value) {
    _live = value;
    _restart = value;
  }

  /// A device stop retires a temporary live value to its restart value.
  void retireLive() => _live = _restart;

  /// A recalled session replaces any value the old lifetime still owed.
  void reset() {
    _owed = null;
    _lastResult = EngineResult.ok;
  }

  /// Closes the failure stream.
  Future<void> dispose() => _failures.close();

  // The owed value is kept until a receipt is accepted or a stopped engine
  // stages it: a cancel, a refusal or a failed start leaves it owed.
  EngineResult _admit(T value, T restart, {required bool startup}) {
    if (!_running()) {
      _live = value;
      _restart = restart;
      _owed = null;
      _lastResult = EngineResult.ok;
      return EngineResult.ok;
    }
    final admission = _send(value);
    final check = admission.check;
    if (!admission.result.isOk || check == null) return admission.result;
    final pending = _Pending(value, restart, check, startup: startup);
    _pending = pending;
    pending.observation.start(
      settle: () => _settle(pending),
      expire: () => _uncertain(pending, EngineResult.notReady),
      publish: _publish,
    );
    return EngineResult.ok;
  }

  bool _settle(_Pending<T> pending) {
    if (!identical(_pending, pending)) return false;
    final receipt = pending.check();
    if (receipt == null) return false;
    switch (receipt.verdict) {
      case ReceiptVerdict.accepted:
        _pending = null;
        _live = pending.value;
        _restart = pending.restart;
        _owed = null;
        _lastResult = EngineResult.ok;
        pending.observation.complete(EngineResult.ok);
      case ReceiptVerdict.refused when !pending.startup:
        _pending = null;
        _lastResult = receipt.result;
        pending.observation.complete(receipt.result);
        _report(receipt.result);
      case ReceiptVerdict.refused || ReceiptVerdict.uncertain:
        // A refused restart replay leaves the new lifetime's value unknown.
        _uncertain(pending, EngineResult.invalid);
    }
    return true;
  }

  void _uncertain(_Pending<T> pending, EngineResult result) {
    if (!identical(_pending, pending)) return;
    _pending = null;
    _owed = pending.restart;
    _lastResult = result;
    pending.observation.complete(result);
    _report(result);
  }

  void _report(EngineResult result) {
    if (!_failures.isClosed) _failures.add(result);
  }
}

final class _Pending<T> {
  _Pending(this.value, this.restart, this.check, {required this.startup});
  final T value;
  final T restart;
  final ReceiptCheck check;
  final bool startup;
  final observation = ReceiptObservation();
}

/// One admission deadline and observer per settings receipt. Family classifiers
/// decide acceptance and recovery; consumers only await this work.
final class ReceiptObservation {
  static const _interval = Duration(milliseconds: 10);
  static const _timeout = Duration(milliseconds: 500);
  final _completed = Completer<EngineResult>();
  Timer? _deadline;
  Timer? _observer;
  final _shortenedDeadlines = <Timer>[];
  bool Function()? _settle;
  void Function()? _expire;
  void Function()? _publish;

  /// Arms the deadline and the periodic observer.
  void start({
    required bool Function() settle,
    required void Function() expire,
    required void Function() publish,
  }) {
    _settle = settle;
    _expire = expire;
    _publish = publish;
    // Relative timers are independent of the wall clock. Later awaiters never
    // restart this admitted request's native uncertainty cutoff.
    _deadline = Timer(_timeout, () => _observe(expired: true));
    _observer = Timer.periodic(_interval, (_) => _observe());
  }

  /// Classifies the receipt once; true when it settled now.
  bool check() {
    if (_completed.isCompleted) return false;
    return _settle?.call() ?? false;
  }

  /// Completes every waiter and cancels the timers.
  void complete(EngineResult result) {
    _deadline?.cancel();
    _observer?.cancel();
    for (final timer in _shortenedDeadlines) {
      timer.cancel();
    }
    _shortenedDeadlines.clear();
    _completed.complete(result);
  }

  /// Awaits completion within the caller's budget.
  Future<EngineResult> wait({
    required Duration pollInterval,
    required int attempts,
  }) {
    if (_completed.isCompleted) return _completed.future;
    final micros = pollInterval.inMicroseconds;
    final budget = micros <= 0 || attempts <= 0 ? 0 : micros * attempts;
    _observe();
    // Each shorter budget starts when requested, independently of any delayed
    // observation ticks. All waiters still share the one receipt completion;
    // none can move or replace its original admission deadline.
    if (!_completed.isCompleted && budget < _timeout.inMicroseconds) {
      _shortenedDeadlines.add(
        Timer(Duration(microseconds: budget), () => _observe(expired: true)),
      );
    }
    return _completed.future;
  }

  void _observe({bool expired = false}) {
    if (_completed.isCompleted) return;
    if (check()) {
      _publish?.call();
    } else if (expired) {
      _expire?.call();
      _publish?.call();
    }
  }
}
