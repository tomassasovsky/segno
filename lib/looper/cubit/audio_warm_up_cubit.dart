import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/logging/app_log.dart';
import 'package:settings_repository/settings_repository.dart';

part 'audio_warm_up_state.dart';

/// Opens the player's audio config once the console has settled (#1533).
///
/// Every start the console makes on its own (the boot auto-start, the
/// boot-time recovery, a reconnect) opens the device as a warm-up: the
/// player's rate with a [kWarmUpBufferFrames]-frame buffer, silent, with the
/// transport closed ([EngineStatus.warmingUp]). This cubit decides when to
/// leave it.
///
/// It starts watching once [load]'s `ready` has completed (the first frame
/// is on screen, after the boot's settings and chains have loaded), and it
/// ticks only while a warm-up runs. On each tick it reads the callback
/// telemetry's session window and sums its late periods, gaps and xruns.
/// When that sum has not moved for the
/// quiet window, the console has settled. When the cap passes first, the
/// switch happens anyway, so it never waits forever. A device that goes
/// missing restarts the count.
///
/// The switch sets the record offset saved for the player's device, rate and
/// buffer, then [LooperRepository.finishWarmUp] reopens at the player's config
/// with the loops kept, and outputs and monitoring are heard from there. It
/// runs under the device-change guard, like an Apply; an operation that holds
/// the device defers it to the next tick.
class AudioWarmUpCubit extends Cubit<AudioWarmUpState> {
  /// Creates an [AudioWarmUpCubit].
  ///
  /// [ready] completes when the startup work is done (the app passes the
  /// first rasterized frame). [ticker] drives the checks (a periodic timer of
  /// [interval] when omitted). The console has settled after [quiet] with no
  /// new fault, and the switch happens anyway [cap] after watching began.
  AudioWarmUpCubit({
    required LooperRepository looper,
    required SettingsRepository settings,
    required GuardRegistry guards,
    Future<void> Function()? ready,
    Stream<void>? ticker,
    Duration interval = const Duration(milliseconds: 500),
    Duration quiet = const Duration(seconds: 3),
    Duration cap = const Duration(seconds: 20),
  }) : _looper = looper,
       _settings = settings,
       _guards = guards,
       _ready = ready,
       _ticker = ticker,
       _interval = interval,
       _quietTicks = _ticksIn(quiet, interval),
       _capTicks = _ticksIn(cap, interval),
       super(const AudioWarmUpState());

  final LooperRepository _looper;
  final SettingsRepository _settings;
  final GuardRegistry _guards;
  final Future<void> Function()? _ready;
  final Stream<void>? _ticker;
  final Duration _interval;
  final int _quietTicks;
  final int _capTicks;

  StreamSubscription<LooperState>? _stateSubscription;
  StreamSubscription<void>? _tickSubscription;
  var _loaded = false;
  var _switching = false;

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
    await _ready?.call();
    if (isClosed) return;
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
    if (_switching) return;
    unawaited(_tickSubscription?.cancel());
    _tickSubscription = null;
    _restart();
    _emit(AudioWarmUpStatus.idle);
  }

  void _tick() {
    if (_switching || isClosed) return;
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
    final faults = _faultsOf(_looper.readCallbackTelemetry().session);
    _ticks++;
    if (faults == _faults) {
      _quiet++;
    } else {
      _faults = faults;
      _quiet = 0;
    }
    final settled = _quiet >= _quietTicks;
    if (settled || _ticks >= _capTicks) {
      unawaited(_switch(settled: settled));
    }
  }

  /// What a dropout is made of: late periods, gaps and backend xruns.
  static int _faultsOf(CallbackWindowStats window) =>
      window.latePeriods +
      window.gapEvents +
      window.xruns.fold<int>(0, (sum, kind) => sum + kind);

  Future<void> _switch({required bool settled}) async {
    _switching = true;
    try {
      final target = _looper.lastEngineConfig;
      if (target == null) return;
      final offset = await _savedOffset(
        _looper.state.status,
        target.bufferFrames,
      );
      if (isClosed || !_looper.state.status.warmingUp) return;
      final OperationGuard guard;
      try {
        guard = _guards.enter(
          GuardKind.deviceChange,
          const GuardScope.internal(),
          purpose: 'audio warm-up',
        );
      } on GuardRefused catch (refused) {
        AppLog.info(
          'audio warm-up: switch deferred by '
          '${refused.blockers.first.kind.name}',
        );
        return;
      }
      final AudioApplyResult outcome;
      try {
        _looper.setRecordOffset(offset);
        outcome = _looper.finishWarmUp();
      } finally {
        guard.release();
      }
      AppLog.info(
        'audio warm-up: ${settled ? 'settled' : 'cap reached'} after '
        '$_ticks ticks; switch to rate=${target.sampleRate} '
        'buffer=${target.bufferFrames}: ${outcome.status.name} '
        'result=${outcome.result.name}',
      );
      // A refused admission touched nothing: the next tick tries again.
      if (outcome.result == EngineResult.notReady) return;
      _restart();
    } finally {
      _switching = false;
      // The switch's own state changes arrived while it ran.
      if (!isClosed) _follow(_looper.state);
    }
  }

  /// The record offset saved for the warm-up device at the player's rate and
  /// [bufferFrames], or 0 when that profile was never measured.
  Future<int> _savedOffset(EngineStatus status, int bufferFrames) async {
    try {
      final saved = await _settings.loadLatencyOffsetFrames(
        device: status.deviceName,
        sampleRate: status.sampleRate,
        bufferFrames: bufferFrames,
      );
      return saved != null && saved > 0 ? saved : 0;
    } on Object catch (error) {
      AppLog.error('audio warm-up: saved record offset unreadable: $error');
      return 0;
    }
  }

  void _restart() {
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
