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
/// Bounce can consume it in place, until [release]. While a finished memory
/// job is held, the repository refuses a new render rather than replace it.
class RenderJob {
  /// Starts polling engine job [id]. A job still waiting for the audio
  /// callback to freeze its sources after [freezeTimeout] (the device is
  /// present but not calling back) is cancelled and ends with
  /// [EngineResult.device].
  RenderJob({
    required EngineSelectedRender engine,
    required this.id,
    required RenderTarget target,
    required Duration pollInterval,
    required Duration freezeTimeout,
    this.path,
  }) : _engine = engine,
       _target = target,
       _freezeTimeout = freezeTimeout {
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  final EngineSelectedRender _engine;
  final RenderTarget _target;
  final Duration _freezeTimeout;

  /// The engine's job id.
  final int id;

  /// The final file, for a file job; `null` for a memory job.
  final String? path;

  Timer? _timer;
  RenderProgress? _last;
  Stopwatch? _freezing;
  bool _released = false;
  final StreamController<RenderProgress> _progress =
      StreamController<RenderProgress>.broadcast();
  final Completer<RenderOutcome> _outcome = Completer<RenderOutcome>();

  /// Progress, emitted when it changes.
  Stream<RenderProgress> get progress => _progress.stream;

  /// How the job ended.
  Future<RenderOutcome> get outcome => _outcome.future;

  /// Whether the job has ended.
  bool get isFinished => _outcome.isCompleted;

  /// Whether this is a finished memory job whose result the engine still
  /// holds for its caller (until [release]).
  bool get holdsResult =>
      _target == RenderTarget.memory && isFinished && !_released;

  /// A finished memory job's interleaved stereo result, at most [maxFrames]
  /// frames, or `null` when there is none.
  Float32List? copySamples({required int maxFrames}) =>
      _engine.copyRender(id, maxFrames: maxFrames);

  /// Cancels the job. A file job leaves no partial file.
  void cancel() {
    if (isFinished) return;
    _engine.cancelRender(id);
    _released = true;
    _finish(const RenderOutcome(result: EngineResult.ok, cancelled: true));
  }

  /// Releases a finished memory job's result from the engine.
  void release() {
    if (!isFinished) {
      cancel();
      return;
    }
    if (holdsResult) _engine.cancelRender(id);
    _released = true;
  }

  void _poll() {
    final status = _engine.pollRender(id);
    if (status == null) {
      // The engine no longer holds this job (a reconfigure retired it).
      _released = true;
      _finish(const RenderOutcome(result: EngineResult.invalid));
      return;
    }
    final phase = _phaseOf(status.state);
    if (phase != null) {
      final progress = RenderProgress(phase: phase, permille: status.permille);
      if (progress != _last) {
        _last = progress;
        _progress.add(progress);
      }
    }
    switch (status.state) {
      case RenderJobState.done:
        if (_target == RenderTarget.file) {
          _engine.cancelRender(id);
          _released = true;
        }
        _finish(RenderOutcome(result: EngineResult.ok, path: path));
      case RenderJobState.failed:
        _engine.cancelRender(id);
        _released = true;
        _finish(RenderOutcome(result: status.failure));
      case RenderJobState.freezing:
        final waited = _freezing ??= Stopwatch()..start();
        if (waited.elapsed > _freezeTimeout) {
          _engine.cancelRender(id);
          _released = true;
          _finish(const RenderOutcome(result: EngineResult.device));
        }
      case RenderJobState.none:
      case RenderJobState.staging:
      case RenderJobState.rendering:
        break;
    }
  }

  static RenderPhase? _phaseOf(RenderJobState state) => switch (state) {
    RenderJobState.none => null,
    RenderJobState.freezing => RenderPhase.freezing,
    RenderJobState.staging => RenderPhase.staging,
    RenderJobState.rendering => RenderPhase.rendering,
    RenderJobState.done => RenderPhase.done,
    RenderJobState.failed => RenderPhase.failed,
  };

  void _finish(RenderOutcome outcome) {
    _timer?.cancel();
    _timer = null;
    if (!_outcome.isCompleted) _outcome.complete(outcome);
    unawaited(_progress.close());
  }
}
