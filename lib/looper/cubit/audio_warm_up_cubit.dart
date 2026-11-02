import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/logging/app_log.dart';

part 'audio_warm_up_state.dart';

/// Opens the player's audio config once the console has settled (#1533).
///
/// Every start the console makes on its own (the boot auto-start, the
/// boot-time recovery, a reconnect) opens the device as a warm-up: the
/// player's rate with a [kWarmUpBufferFrames]-frame buffer, silent, with the
/// transport closed ([EngineStatus.warmingUp]). This cubit decides when to
/// leave it.
///
/// It ticks only while a warm-up runs, and no tick counts as quiet before
/// [load]'s `ready` has completed (the first frame is on screen, after the
/// boot's settings and chains have loaded); the cap counts from [load].
/// On each tick it reads the callback telemetry's session window and sums
/// its late periods, gaps and xruns. When that sum has not moved for the
/// quiet window, the console has settled. When the cap passes first, the
/// switch happens anyway, so it never waits forever. A device that goes
/// missing restarts the count.
///
/// The switch is [LooperRepository.finishWarmUp]: it reopens at the player's
/// config with the loops kept, and what runs then owes its record offset,
/// which the audio setup settles (#1541) before anything is heard. It runs
/// under the device-change guard, like an Apply; an operation that holds the
/// device defers it to the next tick.
class AudioWarmUpCubit extends Cubit<AudioWarmUpState> {
  /// Creates an [AudioWarmUpCubit].
  ///
  /// [ready] completes when the startup work is done (the app passes the
  /// first rasterized frame). [ticker] drives the checks (a periodic timer of
  /// [interval] when omitted). The console has settled after [quiet] with no
  /// new fault, and the switch happens anyway [cap] after watching began.
  AudioWarmUpCubit({
    required LooperRepository looper,
    required GuardRegistry guards,
    Future<void> Function()? ready,
    Stream<void>? ticker,
    Duration interval = const Duration(milliseconds: 500),
    Duration quiet = const Duration(seconds: 3),
    Duration cap = const Duration(seconds: 20),
  }) : _looper = looper,
       _guards = guards,
       _ready = ready,
       _ticker = ticker,
       _interval = interval,
       _quietTicks = _ticksIn(quiet, interval),
       _capTicks = _ticksIn(cap, interval),
       super(const AudioWarmUpState());

  final LooperRepository _looper;
  final GuardRegistry _guards;
  final Future<void> Function()? _ready;
  final Stream<void>? _ticker;
  final Duration _interval;
  final int _quietTicks;
  final int _capTicks;

  StreamSubscription<LooperState>? _stateSubscription;
  StreamSubscription<void>? _tickSubscription;
  var _loaded = false;

  /// Whether the startup work is done ([load]'s `ready`).
  var _isReady = false;

  /// Whether this warm-up's switch was already deferred, so a long deferral
  /// logs once.
  var _deferred = false;

  /// Ticks watched in this warm-up.
  var _ticks = 0;

  /// Consecutive ticks with no new fault.
  var _quiet = 0;

  /// The fault sum at the last tick, or `null` before the first one.
  int? _faults;

  static int _ticksIn(Duration span, Duration interval) =>
      (span.inMicroseconds / interval.inMicroseconds).ceil();

  /// Waits for the startup work, then watches. Idempotent.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    // Until the startup work is done no tick counts as quiet, but the cap
    // runs from here: a console whose screen never draws (no panel
    // attached) must still be heard.
    final ready = _ready;
    if (ready == null) {
      _isReady = true;
    } else {
      unawaited(ready().then((_) => _isReady = true));
    }
    _stateSubscription = _looper.looperState.listen(_follow);
    _follow(_looper.state);
  }

  /// Ticks while a warm-up runs, and only then.
  void _follow(LooperState looper) {
    if (looper.status.warmingUp) {
      _emit(AudioWarmUpStatus.settling);
      _tickSubscription ??= (_ticker ?? Stream<void>.periodic(_interval))
          .listen(
            (_) => _tick(),
          );
      return;
    }
    unawaited(_tickSubscription?.cancel());
    _tickSubscription = null;
    _restart();
    _emit(AudioWarmUpStatus.idle);
  }

  void _tick() {
    if (isClosed) return;
    final status = _looper.state.status;
    if (!status.warmingUp) {
      _follow(_looper.state);
      return;
    }
    if (!status.isConnected || !status.devicePresent) {
      // The reconnect warms up again, and the count starts over with it.
      _restart();
      return;
    }
    _ticks++;
    final faults = _isReady
        ? _faultsOf(_looper.readCallbackTelemetry().session)
        : null;
    if (faults != null && faults == _faults) {
      _quiet++;
    } else {
      _faults = faults;
      _quiet = 0;
    }
    final settled = _quiet >= _quietTicks;
    if (settled || _ticks >= _capTicks) _switch(settled: settled);
  }

  /// What a dropout is made of: late periods, gaps and backend xruns.
  static int _faultsOf(CallbackWindowStats window) =>
      window.latePeriods + window.gapEvents + window.xrunTotal;

  void _switch({required bool settled}) {
    final target = _looper.lastEngineConfig;
    if (target == null) return;
    final OperationGuard guard;
    try {
      guard = _guards.enter(
        GuardKind.deviceChange,
        const GuardScope.internal(),
        purpose: 'audio warm-up',
      );
    } on GuardRefused catch (refused) {
      _logDeferred(refused.blockers.first.kind.name);
      return;
    }
    final AudioApplyResult outcome;
    try {
      outcome = _looper.finishWarmUp();
    } finally {
      guard.release();
    }
    if (outcome.result == EngineResult.notReady) {
      _logDeferred('a start fence');
      return;
    }
    AppLog.info(
      'audio warm-up: ${settled ? 'settled' : 'cap reached'} after '
      '$_ticks ticks; switch to rate=${target.sampleRate} '
      'buffer=${target.bufferFrames}: ${outcome.status.name} '
      'result=${outcome.result.name}',
    );
    _restart();
  }

  /// A deferred switch is tried again on the next tick; it is logged once.
  void _logDeferred(String by) {
    if (_deferred) return;
    _deferred = true;
    AppLog.info('audio warm-up: switch deferred by $by');
  }

  void _restart() {
    _deferred = false;
    _ticks = 0;
    _quiet = 0;
    _faults = null;
  }

  void _emit(AudioWarmUpStatus status) {
    if (isClosed || state.status == status) return;
    emit(AudioWarmUpState(status: status));
  }

  @override
  Future<void> close() {
    unawaited(_stateSubscription?.cancel());
    unawaited(_tickSubscription?.cancel());
    return super.close();
  }
}
