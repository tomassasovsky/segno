import 'package:meta/meta.dart';
import 'package:session_repository/src/models/session_summary.dart';

/// What the Library's preview panel shows for one saved session: the facts a
/// decoded manifest supplies, with no audio decoded.
///
/// Only populated tracks appear in [tracks]; an empty session has none.
@immutable
class SessionPreview {
  /// Creates a [SessionPreview].
  const SessionPreview({
    required this.summary,
    required this.tracks,
    required this.fxCount,
    this.backingCount = 0,
  });

  /// The catalog row this preview belongs to.
  final SessionSummary summary;

  /// The populated tracks, in channel order.
  final List<SessionPreviewTrack> tracks;

  /// Effect entries across every chain stage.
  final int fxCount;

  /// Prepared backing files; always 0 until the backing player exists.
  final int backingCount;
}

/// One populated track in a [SessionPreview].
@immutable
class SessionPreviewTrack {
  /// Creates a [SessionPreviewTrack].
  const SessionPreviewTrack({
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
