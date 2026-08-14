import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'transport_clock_state.dart';

/// The stage's wall-clock transport timer — the honest source behind the
/// pen's `0:00:11` readout on every STAGE screen (#678).
///
/// **What it counts.** Elapsed time while the transport runs: any track
/// recording, overdubbing, or playing, or a count-in in progress (the click
/// is already sounding, so the performance has started). The clock **holds**
/// when the transport stops — a paused set has not un-happened — and
/// **resets to zero** when the rig it was timing goes away: a session load
/// replacing the rig ([LooperRepository.rigReplaced]), or the rig emptying
/// under it (clear-all). The pen never states the clock's epoch (no `c/`
/// note names it, and every stage state draws the same figure), so these are
/// the literal semantics of "elapsed time": engine time was not needed, and
/// no engine surface was added.
///
/// **Why a cubit of its own.** The engine has no wall clock and
/// `LooperBloc`'s state is the repository's [LooperState] verbatim, so the
/// timer lives beside the transport facts rather than inside them — the same
/// shape as `TunerCubit`, following the repository stream directly. The strip
/// subscribes to its own slice (the bar's per-element rebuild discipline),
/// and nothing else pays for the tick.
///
/// **Monotonic, not wall-clock.** The run is measured by a [Stopwatch] —
/// monotonic ticks — never by `DateTime.now()` differences. The appliance Pi
/// has no RTC, so its system clock STEPS at the first NTP sync after boot: a
/// forward step would permanently inflate a wall-clock-derived elapsed, and a
/// backward step larger than the run would drive it negative (which the
/// display's euclidean `%` would render as garbage). A stopwatch is immune
/// to both, and its start/stop accumulation across runs is exactly the
/// hold-across-a-stop this clock wants.
///
/// **Tick discipline.** While running, a periodic timer re-reads the
/// stopwatch — never accumulating tick counts, which would drift — and emits
/// it truncated to whole seconds. Equal states are dropped by the cubit, so
/// subscribers rebuild once per displayed second regardless of the tick
/// rate.
class TransportClockCubit extends Cubit<TransportClockState> {
  /// Creates a [TransportClockCubit] following [repository].
  ///
  /// [stopwatch] supplies the monotonic run timer; injectable for
  /// deterministic tests (`fake_async` fakes `Timer`, not [Stopwatch]).
  /// [tickInterval] paces the running re-read; shorter than a second so a
  /// displayed second never lags a full second behind the wall.
  TransportClockCubit({
    required LooperRepository repository,
    Stopwatch? stopwatch,
    Duration tickInterval = const Duration(milliseconds: 250),
  }) : _watch = stopwatch ?? Stopwatch(),
       _tickInterval = tickInterval,
       super(const TransportClockState()) {
    // Seed from the live snapshot rather than waiting for the first
    // projection: created while the transport is already running (a lazy
    // read mid-set), the clock must start counting now, not on the next
    // engine poll.
    _onLooperState(repository.state);
    _subscription = repository.looperState.listen(_onLooperState);
    // The load-bearing reset: a session load replaces the rig in a cleared
    // window of a few milliseconds of mostly synchronous FFI import, which
    // the poll-driven projection frequently never emits — sampled from the
    // stream alone, the old session's elapsed would silently carry into the
    // freshly loaded one. The repository announces the replacement
    // explicitly instead.
    _rigReplacedSubscription = repository.rigReplaced.listen(
      (_) => _resetElapsed(),
    );
  }

  final Stopwatch _watch;
  final Duration _tickInterval;
  late final StreamSubscription<LooperState> _subscription;
  late final StreamSubscription<void> _rigReplacedSubscription;

  Timer? _ticker;

  /// Whether [looper]'s transport is audibly running: any track capturing or
  /// sounding, or the count-in click already going.
  static bool _transportRunning(LooperState looper) =>
      looper.transport.countingIn ||
      looper.tracks.any(
        (track) => switch (track.state) {
          TrackState.recording ||
          TrackState.overdubbing ||
          TrackState.playing => true,
          TrackState.empty || TrackState.stopped => false,
        },
      );

  void _onLooperState(LooperState looper) {
    final running = _transportRunning(looper);
    if (running && !_watch.isRunning) {
      _watch.start();
      _ticker = Timer.periodic(_tickInterval, (_) => _emitElapsed());
    } else if (!running && _watch.isRunning) {
      _watch.stop();
      _ticker?.cancel();
      _ticker = null;
    }
    // The projection-based reset, covering what [LooperRepository.rigReplaced]
    // does not: a rig emptied IN PLACE (the user's clear-all, a failed load's
    // destructive clear), where the empty state is stable and the stream does
    // reliably carry it. Guarded on stopped: while the FIRST recording is
    // still capturing, no track has content yet, and zeroing a clock that is
    // counting that very take would be wrong.
    if (!running && !looper.hasContent) _watch.reset();
    _emitElapsed(running: running);
  }

  /// Zeroes the clock. [Stopwatch.reset] keeps a running watch running, so a
  /// reset that lands mid-run restarts the count from zero rather than
  /// stopping it.
  void _resetElapsed() {
    _watch.reset();
    _emitElapsed();
  }

  void _emitElapsed({bool? running}) {
    emit(
      TransportClockState(
        // Truncated to the displayed granularity so equal seconds dedupe.
        elapsed: Duration(seconds: _watch.elapsed.inSeconds),
        running: running ?? state.running,
      ),
    );
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_rigReplacedSubscription.cancel());
    return super.close();
  }
}
