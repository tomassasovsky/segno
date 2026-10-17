import 'package:meta/meta.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineResult, RenderMethod, RenderPlan;

/// How a render treats effect tails at its window edge.
enum RenderTailRule {
  /// The window is rendered twice and the second pass kept, so tails leaving
  /// the end continue at the start (the default).
  wrap,

  /// The window is rendered once; tails end at the edge.
  cut,
}

/// Where a running render is.
enum RenderPhase {
  /// Waiting for the audio callback to freeze each source's read law.
  freezing,

  /// Copying the frozen material ("Preparing").
  staging,

  /// Rendering.
  rendering,

  /// Finished.
  done,

  /// Failed; the job's outcome says why.
  failed,
}

/// What to render with the shared recipe (#1202): the selected recorded
/// tracks, the length ([lengthBars] whole bars, or `null` for their common
/// cycle), the tail rule, and whether the All tracks chain (Mix FX) is
/// included. Save selected audio and Bounce both describe their render this
/// way; Bounce never sets [mixFx].
@immutable
class SelectedRender {
  /// Creates a [SelectedRender].
  const SelectedRender({
    required this.sources,
    this.lengthBars,
    this.tails = RenderTailRule.wrap,
    this.mixFx = false,
  });

  /// Track channels to render.
  final Set<int> sources;

  /// A chosen length in whole bars, or `null` for the common cycle.
  final int? lengthBars;

  /// The tail rule (Wrap by default).
  final RenderTailRule tails;

  /// Whether the All tracks chain is included (Off by default).
  final bool mixFx;

  /// A copy with the given fields replaced. [clearLength] returns to the
  /// common cycle.
  SelectedRender copyWith({
    Set<int>? sources,
    int? lengthBars,
    bool clearLength = false,
    RenderTailRule? tails,
    bool? mixFx,
  }) => SelectedRender(
    sources: sources ?? this.sources,
    lengthBars: clearLength ? null : lengthBars ?? this.lengthBars,
    tails: tails ?? this.tails,
    mixFx: mixFx ?? this.mixFx,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectedRender &&
          sources.length == other.sources.length &&
          sources.containsAll(other.sources) &&
          lengthBars == other.lengthBars &&
          tails == other.tails &&
          mixFx == other.mixFx;

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(sources), lengthBars, tails, mixFx);

  @override
  String toString() =>
      'SelectedRender(sources: $sources, lengthBars: $lengthBars, '
      'tails: $tails, mixFx: $mixFx)';
}

/// The engine's plan for a [SelectedRender], as the surfaces read it.
@immutable
class SelectedRenderPlan {
  /// Creates a [SelectedRenderPlan].
  const SelectedRenderPlan({
    required this.frames,
    required this.seconds,
    required this.commonCycle,
    this.beats,
    this.bars,
    this.pluginTracks = const {},
    this.fadedTracks = const {},
    this.pendingTracks = const {},
    this.onceCutTracks = const {},
  });

  /// Builds the readout from the engine's [plan] at [sampleRate] with
  /// [beatsPerBar] beats to the bar. Without a time signature
  /// ([beatsPerBar] below 1) a bar is four beats, the engine's own default
  /// for a chosen length, so the readout and the rendered length agree.
  factory SelectedRenderPlan.fromEngine(
    RenderPlan plan, {
    required int sampleRate,
    required int beatsPerBar,
  }) {
    final beats = plan.tempoSet ? plan.beatsMilli / 1000 : null;
    final perBar = beatsPerBar > 0 ? beatsPerBar : 4;
    return SelectedRenderPlan(
      frames: plan.frames,
      seconds: sampleRate > 0 ? plan.frames / sampleRate : 0,
      commonCycle: plan.method == RenderMethod.commonCycle,
      beats: beats,
      bars: beats != null ? beats / perBar : null,
      pluginTracks: plan.pluginTracks,
      fadedTracks: plan.fadedTracks,
      pendingTracks: plan.pendingTracks,
      onceCutTracks: plan.onceCutTracks,
    );
  }

  /// The window, in frames.
  final int frames;

  /// The window, in seconds.
  final double seconds;

  /// Whether the length is the sources' common cycle (else a chosen length).
  final bool commonCycle;

  /// The window in beats, or `null` without a tempo.
  final double? beats;

  /// The window in bars, or `null` without a tempo. Fractional when the
  /// common cycle is not a whole number of bars.
  final double? bars;

  /// Tracks whose hosted plugins render dry; the surfaces name them.
  final Set<int> pluginTracks;

  /// Tracks that are faded and will render quiet or silent.
  final Set<int> fadedTracks;

  /// Tracks heard through a transform that is not ready yet.
  final Set<int> pendingTracks;

  /// Once tracks longer than the chosen length: only the part of their single
  /// pass inside the window is rendered, and none of it when the pass starts
  /// after the window ends. The surfaces warn before the render.
  final Set<int> onceCutTracks;

  /// Whether a tempo is set (lengths read in bars, else in seconds).
  bool get tempoSet => beats != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectedRenderPlan &&
          frames == other.frames &&
          seconds == other.seconds &&
          commonCycle == other.commonCycle &&
          beats == other.beats &&
          bars == other.bars &&
          _sameSet(pluginTracks, other.pluginTracks) &&
          _sameSet(fadedTracks, other.fadedTracks) &&
          _sameSet(pendingTracks, other.pendingTracks) &&
          _sameSet(onceCutTracks, other.onceCutTracks);

  @override
  int get hashCode => Object.hash(
    frames,
    seconds,
    commonCycle,
    beats,
    bars,
    Object.hashAllUnordered(pluginTracks),
    Object.hashAllUnordered(fadedTracks),
    Object.hashAllUnordered(pendingTracks),
    Object.hashAllUnordered(onceCutTracks),
  );

  @override
  String toString() =>
      'SelectedRenderPlan(frames: $frames, seconds: $seconds, '
      'commonCycle: $commonCycle, beats: $beats, bars: $bars, '
      'pluginTracks: $pluginTracks, fadedTracks: $fadedTracks, '
      'pendingTracks: $pendingTracks, onceCutTracks: $onceCutTracks)';
}

/// The engine's verdict on a [SelectedRender]: [EngineResult.ok] with a
/// [SelectedRenderPlan], or the refusal with none.
typedef SelectedRenderMeasurement = ({
  EngineResult result,
  SelectedRenderPlan? plan,
});

/// A running render's progress.
@immutable
class RenderProgress {
  /// Creates a [RenderProgress].
  const RenderProgress({required this.phase, required this.permille});

  /// Where the job is.
  final RenderPhase phase;

  /// Progress, `0..1000`, on one scale across staging and rendering.
  final int permille;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderProgress &&
          phase == other.phase &&
          permille == other.permille;

  @override
  int get hashCode => Object.hash(phase, permille);

  @override
  String toString() => 'RenderProgress(phase: $phase, permille: $permille)';
}

/// How a render job ended.
@immutable
class RenderOutcome {
  /// Creates a [RenderOutcome].
  const RenderOutcome({
    required this.result,
    this.path,
    this.cancelled = false,
  });

  /// [EngineResult.ok] when the render finished; otherwise why it failed
  /// ([EngineResult.tracksChanged], [EngineResult.capacity],
  /// [EngineResult.device] — also when the audio callback never froze the
  /// sources in time — or [EngineResult.invalid]).
  final EngineResult result;

  /// The published file, for a file render that finished.
  final String? path;

  /// Whether the job was cancelled before it finished.
  final bool cancelled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderOutcome &&
          result == other.result &&
          path == other.path &&
          cancelled == other.cancelled;

  @override
  int get hashCode => Object.hash(result, path, cancelled);

  @override
  String toString() =>
      'RenderOutcome(result: $result, path: $path, cancelled: $cancelled)';
}

bool _sameSet(Set<int> a, Set<int> b) =>
    a.length == b.length && a.containsAll(b);
