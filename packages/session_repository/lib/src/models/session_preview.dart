import 'package:meta/meta.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/src/models/session_summary.dart';

/// What a preview shows for one saved session: the facts a decoded manifest
/// supplies, with no audio decoded.
///
/// Only populated tracks appear in [tracks]. A session with none is not
/// empty: it can be a prepared setup, which is what the looper mode, the
/// loop length and the chains describe (#1921).
@immutable
class SessionPreview {
  /// Creates a [SessionPreview].
  const new({
    required this.summary,
    required this.tracks,
    required this.fxCount,
    required this.sampleRate,
    this.backingCount = 0,
    this.hasMixdown = false,
    this.looperMode = LooperMode.multi,
    this.loopBars = 0,
    this.inputChains = const [],
    this.trackChains = const [],
    this.allTracksChain = '',
    this.outputChains = const [],
  });

  /// The catalog row this preview belongs to.
  final SessionSummary summary;

  /// The rate the session was recorded at, so a track without a tempo can
  /// show its length in seconds.
  final int sampleRate;

  /// The populated tracks, in channel order.
  final List<SessionPreviewTrack> tracks;

  /// Effect entries across every chain stage.
  final int fxCount;

  /// Prepared backing files; always 0 until the backing player exists.
  final int backingCount;

  /// Whether the bundle holds a `mixdown.wav` for Listen. A session whose
  /// mix is empty (no tracks, or every lane muted) has none.
  final bool hasMixdown;

  /// The looper mode the session was saved in.
  final LooperMode looperMode;

  /// The loop length in bars the session's grid is set to; 0 when it has
  /// none.
  final int loopBars;

  /// The stored chain of each input that has one, in input order. Like every
  /// chain here it is the manifest's own string: this package does not look
  /// inside it, and the caller decodes it to name its effects.
  final List<String> inputChains;

  /// The stored chains on the tracks: each lane's, then each track's, in
  /// channel order.
  final List<String> trackChains;

  /// The stored chain of the All tracks stage; empty when it has none.
  final String allTracksChain;

  /// The stored chain of each output that has one, in bus order.
  final List<String> outputChains;
}

/// One populated track in a [SessionPreview].
@immutable
class SessionPreviewTrack {
  /// Creates a [SessionPreviewTrack].
  const new({
    required this.channel,
    required this.lengthFrames,
    required this.baseLengthFrames,
    required this.bars,
    required this.layers,
    required this.muted,
    required this.fxCount,
    required this.liveLayerFile,
  });

  /// The track's channel (0-based).
  final int channel;

  /// The track's loop length in frames.
  final int lengthFrames;

  /// The session's master loop length in frames (the clip-width reference).
  final int baseLengthFrames;

  /// The loop length in bars, or 0 when the session carries no tempo (the
  /// panel then shows seconds).
  final int bars;

  /// Recorded layers the track plays: the live layer plus its undo history
  /// (lane 0's `undoCount + 1`; depths are track-wide).
  final int layers;

  /// Whether every lane of the track is muted.
  final bool muted;

  /// Effect entries on this track's lane chains and track chain.
  final int fxCount;

  /// Lane 0's live-layer WAV, relative to the bundle, for a waveform read.
  final String liveLayerFile;
}
