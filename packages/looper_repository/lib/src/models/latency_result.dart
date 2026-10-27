import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart' show EngineResult;

/// How a cable measurement (`LooperRepository.measureLatency`) ended.
enum LatencyOutcome {
  /// The pulse came back: [LatencyResult.offsetFrames] is the new record
  /// offset, already set in the engine.
  done,

  /// The measurement window closed with no pulse on the chosen input.
  noReturn,

  /// The measurement was cancelled: by the caller, a stop, a take that was
  /// running when it was asked, or the device leaving.
  cancelled,

  /// No state came back in time, so the measurement was cancelled.
  timedOut,

  /// The engine refused the request ([LatencyResult.engineResult] says why).
  refused,
}

/// The result of one cable measurement. Every outcome but [LatencyOutcome.done]
/// leaves the record offset as it was.
class LatencyResult extends Equatable {
  /// A measurement that ended with [outcome].
  const LatencyResult(this.outcome)
    : offsetFrames = 0,
      latencyMs = 0,
      engineResult = EngineResult.ok;

  /// A measurement that returned [offsetFrames], [latencyMs] round trip.
  const LatencyResult.done({
    required this.offsetFrames,
    required this.latencyMs,
  }) : outcome = LatencyOutcome.done,
       engineResult = EngineResult.ok;

  /// A request the engine refused with [engineResult].
  const LatencyResult.refused(this.engineResult)
    : outcome = LatencyOutcome.refused,
      offsetFrames = 0,
      latencyMs = 0;

  /// How it ended.
  final LatencyOutcome outcome;

  /// The measured record offset in frames, for [LatencyOutcome.done].
  final int offsetFrames;

  /// The measured round trip in milliseconds, for [LatencyOutcome.done].
  final double latencyMs;

  /// What the engine answered the request with.
  final EngineResult engineResult;

  @override
  List<Object?> get props => [outcome, offsetFrames, latencyMs, engineResult];
}
