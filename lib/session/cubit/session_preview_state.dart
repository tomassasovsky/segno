part of 'session_preview_cubit.dart';

/// Where a preview's read stands.
enum SessionPreviewStatus {
  /// No session is previewed.
  none,

  /// The manifest is being read.
  loading,

  /// The preview is in the state. Its waveforms may still be arriving.
  ready,

  /// The session's manifest could not be read.
  unreadable,
}

/// The effects a saved session holds, by where they sit in the signal path,
/// in chain order.
class SessionPreviewEffects extends Equatable {
  /// Creates the effects of one session.
  const new({
    this.inputs = const [],
    this.tracks = const [],
    this.allTracks = const [],
    this.outputs = const [],
  });

  /// On the inputs.
  final List<TrackEffect> inputs;

  /// On the tracks and their lanes.
  final List<TrackEffect> tracks;

  /// On the All tracks stage.
  final List<TrackEffect> allTracks;

  /// On the outputs.
  final List<TrackEffect> outputs;

  @override
  List<Object?> get props => [inputs, tracks, allTracks, outputs];
}

/// One session's preview as a surface draws it.
class SessionPreviewState extends Equatable {
  /// Creates a preview state.
  const new({
    this.id,
    this.status = SessionPreviewStatus.none,
    this.preview,
    this.effects = const SessionPreviewEffects(),
    this.peaks = const {},
  });

  /// The session asked for, or null for none.
  final SessionId? id;

  /// Where its read stands.
  final SessionPreviewStatus status;

  /// What the manifest says, once [status] is ready.
  final SessionPreview? preview;

  /// The session's effects by place.
  final SessionPreviewEffects effects;

  /// Each recorded track's waveform by channel, for the tracks whose audio
  /// has been read.
  final Map<int, List<double>> peaks;

  /// Returns a copy with [peaks].
  SessionPreviewState copyWith({Map<int, List<double>>? peaks}) =>
      SessionPreviewState(
        id: id,
        status: status,
        preview: preview,
        effects: effects,
        peaks: peaks ?? this.peaks,
      );

  @override
  List<Object?> get props => [id, status, preview, effects, peaks];
}
