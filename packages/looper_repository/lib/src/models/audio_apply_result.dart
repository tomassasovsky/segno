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
  /// the engine is stopped.
  failed,
}

/// The outcome of `LooperRepository.applyAudioConfig`.
class AudioApplyResult extends Equatable {
  /// Creates an [AudioApplyResult].
  const AudioApplyResult({
    required this.status,
    required this.result,
    this.reopen,
  });

  /// How the apply ended.
  final AudioApplyStatus status;

  /// What the engine answered for the config that was asked for.
  final EngineResult result;

  /// What the reopen did with the recorded material, when the engine was
  /// running and was reopened rather than started; `null` for a cold start.
  final EngineReopened? reopen;

  @override
  List<Object?> get props => [status, result, reopen];
}
