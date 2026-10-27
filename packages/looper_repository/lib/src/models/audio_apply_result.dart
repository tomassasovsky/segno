import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/engine_reopened.dart';
import 'package:segno_engine/segno_engine.dart' show EngineResult;

/// How [AudioApplyResult] ended.
enum AudioApplyStatus {
  /// The new config is open. On a running engine it was reopened, and
  /// [AudioApplyResult.reopen] says what that did with the loops.
  applied,

  /// The new config could not be opened, and the previous one is open again.
  refused,

  /// The new config could not be opened, and neither could the previous one:
  /// the engine is stopped. Also an open whose replay rolled back.
  failed,

  /// Neither config would open, and the previous one pins an interface: it
  /// stays pinned and the reconnect supervisor reopens it when the interface
  /// answers, as after an unplug (#1270 D17).
  waiting,
}

/// The outcome of `LooperRepository.applyAudioConfig`.
class AudioApplyResult extends Equatable {
  /// Creates an [AudioApplyResult].
  const AudioApplyResult({
    required this.status,
    required this.result,
    this.reopen,
    this.refusedRate = 0,
  });

  /// How the apply ended.
  final AudioApplyStatus status;

  /// What the engine answered for the config that was asked for.
  final EngineResult result;

  /// What the reopen did with the recorded material, when the engine was
  /// running and was reopened rather than started; `null` for a cold start.
  final EngineReopened? reopen;

  /// For a config refused to keep the loops ([EngineResult.wouldClear]): the
  /// sample rate the device would have run. 0 otherwise.
  final int refusedRate;

  @override
  List<Object?> get props => [status, result, reopen, refusedRate];
}
