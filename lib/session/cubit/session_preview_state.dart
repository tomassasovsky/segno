part of 'session_preview_cubit.dart';

/// Where a preview's read stands.
enum SessionPreviewStatus {
  /// No session is previewed.
  none,

  /// The manifest is being read.
  loading,

  /// The preview is in the state.
  ready,

  /// The session's manifest could not be read.
  unreadable,
}

/// One session's preview as a surface draws it.
class SessionPreviewState extends Equatable {
  /// Creates a preview state.
  const new({
    this.id,
    this.status = SessionPreviewStatus.none,
    this.preview,
    this.effects = const [],
  });

  /// The session asked for, or null for none.
  final SessionId? id;

  /// Where its read stands.
  final SessionPreviewStatus status;

  /// What the manifest says, once [status] is ready.
  final SessionPreview? preview;

  /// The session's effects, in signal order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [id, status, preview, effects];
}
