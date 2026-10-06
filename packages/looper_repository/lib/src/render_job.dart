import 'dart:async';
import 'dart:typed_data';

import 'package:looper_repository/src/models/selected_render.dart';
import 'package:segno_engine/segno_engine.dart';

/// One running shared-recipe render (#1202).
///
/// Polls the engine on a timer — each poll is also the job's staging
/// heartbeat — publishes [progress], and completes [outcome] once the job
/// finishes, fails or is cancelled. A file job is released from the engine
/// when it finishes (its file is published); a memory job stays held, so a
/// Bounce can consume it in place, until [release] or the next render.
class RenderJob {
  /// Starts polling engine job [id].
  RenderJob({
    required EngineSelectedRender engine,
    required this.id,
    required this.target,
    required Duration pollInterval,
    this.path,
  }) : _engine = engine {
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  final EngineSelectedRender _engine;

  /// The engine's job id.
  final int id;

  /// Where the result goes.
  final RenderTarget target;

  /// The final file, for a file job.
  final String? path;

  Timer? _timer;
  RenderProgress? _last;
  final StreamController<RenderProgress> _progress =
      StreamController<RenderProgress>.broadcast();
  final Completer<RenderOutcome> _outcome = Completer<RenderOutcome>();

  /// Progress, emitted when it changes.
  Stream<RenderProgress> get progress => _progress.stream;

  /// How the job ended.
  Future<RenderOutcome> get outcome => _outcome.future;

  /// Whether the job has ended.
  bool get isFinished => _outcome.isCompleted;

  /// A finished memory job's interleaved stereo result, at most [maxFrames]
  /// frames, or `null` when there is none.
  Float32List? copySamples({required int maxFrames}) =>
      _engine.copyRender(id, maxFrames: maxFrames);

  /// Cancels the job. A file job leaves no partial file.
  void cancel() {
    if (isFinished) return;
    _engine.cancelRender(id);
    _finish(const RenderOutcome(result: EngineResult.ok, cancelled: true));
  }

  /// Releases a finished memory job's result from the engine.
  void release() {
    if (!isFinished) {
      cancel();
      return;
    }
    if (target == RenderTarget.memory) _engine.cancelRender(id);
  }

  void _poll() {
    final status = _engine.pollRender(id);
    if (status == null) {
      // The engine no longer holds this job: a newer job replaced it.
      _finish(const RenderOutcome(result: EngineResult.invalid));
      return;
    }
    final progress = RenderProgress(
      state: status.state,
      permille: status.permille,
    );
    if (progress != _last) {
      _last = progress;
      _progress.add(progress);
    }
    switch (status.state) {
      case RenderJobState.done:
        if (target == RenderTarget.file) _engine.cancelRender(id);
        _finish(RenderOutcome(result: EngineResult.ok, path: path));
      case RenderJobState.failed:
        _finish(RenderOutcome(result: status.failure));
      case RenderJobState.none:
      case RenderJobState.freezing:
      case RenderJobState.staging:
      case RenderJobState.rendering:
        break;
    }
  }

  void _finish(RenderOutcome outcome) {
    _timer?.cancel();
    _timer = null;
    if (!_outcome.isCompleted) _outcome.complete(outcome);
    unawaited(_progress.close());
  }
}
