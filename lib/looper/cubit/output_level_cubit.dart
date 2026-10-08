import 'dart:async';
import 'dart:math' show ln10, log;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'output_level_state.dart';

/// A peak at or above this reads as clipping — the engine's level is the
/// absolute sample peak, so full scale is 1.0.
const double kClipPeak = 0.999;

/// The stage footer's `OUT` readout: the master-bus peak, refreshed the way a
/// DAW's numeric peak display is (#1301).
///
/// **Why it does not follow every poll.** The engine is polled every 16 ms,
/// and with an input monitored the master bus carries that input's noise
/// floor even when nobody plays. Its peak then changes in the first decimal on
/// almost every poll, and a readout that follows it rebuilds, re-runs
/// semantics and costs the console a full frame about 60 times a second while
/// it sits idle. A figure that changes that fast cannot be read anyway.
///
/// **What it shows instead.** The highest peak seen since the last refresh,
/// published every `refreshInterval` (four times a second by default, the
/// cadence of the elapsed clock beside it). Holding the maximum means a
/// transient between refreshes still shows. Equal readings are dropped, so a
/// steady level rebuilds nothing at all.
///
/// **Clipping does not wait.** A clipping peak publishes immediately: the
/// player should not have to wait a quarter of a second to learn about it.
class OutputLevelCubit extends Cubit<OutputLevelState> {
  /// Creates an [OutputLevelCubit] following [repository].
  OutputLevelCubit({
    required LooperRepository repository,
    Duration refreshInterval = const Duration(milliseconds: 250),
  }) : super(OutputLevelState.of(repository.state.transport.outputPeak)) {
    _latest = repository.state.transport.outputPeak;
    _held = _latest;
    _subscription = repository.looperState.listen(_onLooperState);
    _ticker = Timer.periodic(refreshInterval, (_) => _publish());
  }

  late final StreamSubscription<LooperState> _subscription;
  late final Timer _ticker;

  /// The most recent peak. The repository drops repeated identical states, so
  /// a steady level sends no events; each refresh window starts from this
  /// rather than from silence.
  late double _latest;

  /// The highest peak since the last publish.
  late double _held;

  void _onLooperState(LooperState looper) {
    _latest = looper.transport.outputPeak;
    if (_latest > _held) _held = _latest;
    if (_latest >= kClipPeak && !state.clip) _publish();
  }

  void _publish() {
    emit(OutputLevelState.of(_held));
    _held = _latest;
  }

  @override
  Future<void> close() {
    _ticker.cancel();
    unawaited(_subscription.cancel());
    return super.close();
  }
}
