import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'transport_clock_state.dart';

/// The stage's wall-clock transport timer — the honest source behind the
/// pen's `0:00:11` readout on every STAGE screen (#678).
///
/// **What it counts.** Elapsed wall time while the transport runs: any track
/// recording, overdubbing, or playing, or a count-in in progress (the click
/// is already sounding, so the performance has started). The clock **holds**
/// when the transport stops — a paused set has not un-happened — and
/// **resets to zero** only when the rig empties (clear-all, or the
/// clear-then-import of a session load), because a rig with nothing on it
/// has no performance to have timed. The pen never states the clock's
/// epoch (no `c/` note names it, and every stage state draws the same
/// figure), so these are the literal semantics of "elapsed time": engine
/// time was not needed, and no engine surface was added.
///
/// **Why a cubit of its own.** The engine has no wall clock and
/// `LooperBloc`'s state is the repository's [LooperState] verbatim, so the
/// timer lives beside the transport facts rather than inside them — the same
/// shape as `TunerCubit`, following the repository stream directly. The strip
/// subscribes to its own slice (the bar's per-element rebuild discipline),
/// and nothing else pays for the tick.
///
/// **Tick discipline.** While running, a periodic timer re-derives elapsed
/// from the wall clock — never by accumulating tick counts, which would
/// drift — and
/// emits it truncated to whole seconds. Equal states are dropped by the
/// cubit, so subscribers rebuild once per displayed second regardless of the
/// tick rate.
class TransportClockCubit extends Cubit<TransportClockState> {
  /// Creates a [TransportClockCubit] following [repository].
  ///
  /// [now] supplies the wall clock; injectable for deterministic tests
  /// (the `PerformanceRecorderCubit` pattern). [tickInterval] paces the
  /// running re-derivation; shorter than a second so a displayed second
  /// never lags a full second behind the wall.
  TransportClockCubit({
    required LooperRepository repository,
    DateTime Function() now = DateTime.now,
    Duration tickInterval = const Duration(milliseconds: 250),
  }) : _now = now,
       _tickInterval = tickInterval,
       super(const TransportClockState()) {
    // Seed from the live snapshot rather than waiting for the first
    // projection: created while the transport is already running (a lazy
    // read mid-set), the clock must start counting now, not on the next
    // engine poll.
    _onLooperState(repository.state);
    _subscription = repository.looperState.listen(_onLooperState);
  }

  final DateTime Function() _now;
  final Duration _tickInterval;
  late final StreamSubscription<LooperState> _subscription;

  /// Wall time already banked by previous runs (the hold).
  Duration _banked = Duration.zero;

  /// When the current run began, or `null` while the transport is stopped.
  DateTime? _runStartedAt;

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
    if (running && _runStartedAt == null) {
      _runStartedAt = _now();
      _ticker = Timer.periodic(_tickInterval, (_) => _emitElapsed());
    } else if (!running && _runStartedAt != null) {
      _banked += _now().difference(_runStartedAt!);
      _runStartedAt = null;
      _ticker?.cancel();
      _ticker = null;
    }
    // The reset, guarded on stopped: while the FIRST recording is still
    // capturing, no track has content yet, and zeroing a clock that is
    // counting that very take would be wrong.
    if (!running && !looper.hasContent) _banked = Duration.zero;
    _emitElapsed(running: running);
  }

  void _emitElapsed({bool? running}) {
    final startedAt = _runStartedAt;
    final live = startedAt == null
        ? Duration.zero
        : _now().difference(startedAt);
    final total = _banked + live;
    emit(
      TransportClockState(
        // Truncated to the displayed granularity so equal seconds dedupe.
        elapsed: Duration(seconds: total.inSeconds),
        running: running ?? state.running,
      ),
    );
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    unawaited(_subscription.cancel());
    return super.close();
  }
}
