import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_engine.dart';

/// How a render treats effect tails at its window edge (`le_render_tails`).
enum RenderTails {
  /// Render the window twice and keep the second pass, so tails leaving the
  /// end continue at the start (the default).
  wrap,

  /// Render the window once from cold Post states; tails end at the edge.
  cut,
}

/// Where a render's result goes (`le_render_target`).
enum RenderTarget {
  /// Kept in the engine job, read with [EngineSelectedRender.copyRender].
  memory,

  /// Written as a stereo float WAV and published at the request's path.
  file,
}

/// How a render's length was chosen (`le_render_method`).
enum RenderMethod {
  /// The exact common cycle of the sources.
  commonCycle,

  /// A chosen whole number of bars.
  chosenLength;

  /// Maps a native `le_render_method`; unknown values read as common cycle.
  static RenderMethod fromCode(int code) =>
      code == 1 ? RenderMethod.chosenLength : RenderMethod.commonCycle;
}

/// A render job's progress (`le_render_state`).
enum RenderJobState {
  /// No job.
  none,

  /// Waiting for the audio callback to freeze each source's read law.
  freezing,

  /// Copying the frozen material.
  staging,

  /// Rendering on the worker.
  rendering,

  /// Finished; the result is ready.
  done,

  /// Failed; [RenderJobStatus.failure] says why.
  failed;

  /// Maps a native `le_render_state`; unknown values read as [none].
  static RenderJobState fromCode(int code) => switch (code) {
    1 => RenderJobState.freezing,
    2 => RenderJobState.staging,
    3 => RenderJobState.rendering,
    4 => RenderJobState.done,
    5 => RenderJobState.failed,
    _ => RenderJobState.none,
  };

  /// Whether the job has ended (done or failed).
  bool get isTerminal =>
      this == RenderJobState.done || this == RenderJobState.failed;
}

/// One shared-recipe render request (#1202): the selected recorded tracks,
/// the length (the common cycle, or [lengthBars] whole bars), the tail rule,
/// whether the All tracks chain is included, and the target.
@immutable
class RenderRequest {
  /// Creates a [RenderRequest].
  const RenderRequest({
    required this.sources,
    this.lengthBars,
    this.tails = RenderTails.wrap,
    this.mixFx = false,
    this.target = RenderTarget.memory,
    this.path,
    this.maxFrames,
  });

  /// Track channels to render.
  final Set<int> sources;

  /// A chosen length in whole bars, or `null` for the common cycle.
  final int? lengthBars;

  /// The tail rule.
  final RenderTails tails;

  /// Whether the All tracks chain (Mix FX) is included.
  final bool mixFx;

  /// Where the result goes.
  final RenderTarget target;

  /// The final file path for [RenderTarget.file].
  final String? path;

  /// The most frames the result may hold (Bounce: the destination's
  /// capacity), or `null` for no limit beyond the cycle cap.
  final int? maxFrames;

  /// [sources] as the native bit mask (bit `t` = track `t`).
  int get sourceMask => sources.fold(0, (mask, track) => mask | (1 << track));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderRequest &&
          _setEquals(sources, other.sources) &&
          lengthBars == other.lengthBars &&
          tails == other.tails &&
          mixFx == other.mixFx &&
          target == other.target &&
          path == other.path &&
          maxFrames == other.maxFrames;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(sources),
    lengthBars,
    tails,
    mixFx,
    target,
    path,
    maxFrames,
  );

  @override
  String toString() =>
      'RenderRequest(sources: $sources, lengthBars: $lengthBars, '
      'tails: $tails, mixFx: $mixFx, target: $target, path: $path, '
      'maxFrames: $maxFrames)';
}

/// The engine's verdict on a [RenderRequest] (`le_render_plan`).
@immutable
class RenderPlan {
  /// Creates a [RenderPlan].
  const RenderPlan({
    required this.frames,
    required this.method,
    required this.beatsMilli,
    required this.tempoSet,
    this.pluginTracks = const {},
    this.fadedTracks = const {},
    this.pendingTracks = const {},
  });

  /// The window, in frames.
  final int frames;

  /// How the length was chosen.
  final RenderMethod method;

  /// The window in beats x 1000; 0 without a tempo.
  final int beatsMilli;

  /// Whether a tempo is set; without one, lengths read in seconds.
  final bool tempoSet;

  /// Sources whose chains hold a hosted plugin, which renders dry.
  final Set<int> pluginTracks;

  /// Sources whose Fade amount is below unity.
  final Set<int> fadedTracks;

  /// Sources heard through a transform that is not ready yet.
  final Set<int> pendingTracks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderPlan &&
          frames == other.frames &&
          method == other.method &&
          beatsMilli == other.beatsMilli &&
          tempoSet == other.tempoSet &&
          _setEquals(pluginTracks, other.pluginTracks) &&
          _setEquals(fadedTracks, other.fadedTracks) &&
          _setEquals(pendingTracks, other.pendingTracks);

  @override
  int get hashCode => Object.hash(
    frames,
    method,
    beatsMilli,
    tempoSet,
    Object.hashAllUnordered(pluginTracks),
    Object.hashAllUnordered(fadedTracks),
    Object.hashAllUnordered(pendingTracks),
  );

  @override
  String toString() =>
      'RenderPlan(frames: $frames, method: $method, beatsMilli: $beatsMilli, '
      'tempoSet: $tempoSet, pluginTracks: $pluginTracks, '
      'fadedTracks: $fadedTracks, pendingTracks: $pendingTracks)';
}

/// [EngineSelectedRender.measureRender]'s answer: the verdict, and the plan
/// when it is [EngineResult.ok].
typedef RenderMeasurement = ({EngineResult result, RenderPlan? plan});

/// [EngineSelectedRender.beginRender]'s answer: the admission, and the job
/// id when it is [EngineResult.ok].
typedef RenderAdmission = ({EngineResult result, int job});

/// A render job's state (`le_engine_render_poll`).
@immutable
class RenderJobStatus {
  /// Creates a [RenderJobStatus].
  const RenderJobStatus({
    required this.state,
    required this.permille,
    this.failure = EngineResult.ok,
  });

  /// The job's state.
  final RenderJobState state;

  /// Progress, `0..1000`.
  final int permille;

  /// Why a [RenderJobState.failed] job failed: [EngineResult.tracksChanged],
  /// [EngineResult.capacity], [EngineResult.invalid] (an effect could not
  /// allocate) or [EngineResult.device] (a write failed, or the engine was
  /// reconfigured or stopped). [EngineResult.ok] otherwise.
  final EngineResult failure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderJobStatus &&
          state == other.state &&
          permille == other.permille &&
          failure == other.failure;

  @override
  int get hashCode => Object.hash(state, permille, failure);

  @override
  String toString() =>
      'RenderJobStatus(state: $state, permille: $permille, failure: $failure)';
}

/// The tracks named by a native bit mask.
Set<int> renderTracksOfMask(int mask) => {
  for (var t = 0; t < 32; t++)
    if (mask & (1 << t) != 0) t,
};

bool _setEquals(Set<int> a, Set<int> b) =>
    a.length == b.length && a.containsAll(b);
