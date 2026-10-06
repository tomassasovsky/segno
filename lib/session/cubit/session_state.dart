part of 'session_cubit.dart';

/// Lifecycle of a session persistence action.
enum SessionStatus {
  /// No action in progress.
  idle,

  /// An action is running.
  working,

  /// The last action succeeded.
  success,

  /// The last action failed.
  failure,
}

/// Which session action succeeded, for localized UI messaging.
enum SessionOutcome {
  /// [SessionCubit.save] wrote the live rig back to the open session.
  saved,

  /// The live rig was saved under a new identity, which is now current: a
  /// [SessionCubit.saveAs], or a [SessionCubit.save] with no open session,
  /// which takes the next automatic name.
  savedAs,

  /// A [SessionCubit.open] succeeded.
  loaded,

  /// A session was renamed.
  renamed,

  /// A session was deleted.
  deleted,

  /// A saved session was copied under a new name.
  duplicated,

  /// A session was moved to another folder.
  moved,

  /// A folder was created.
  folderCreated,
}

/// A classified failure kind, so the UI can show a localized, human-readable
/// message instead of a raw `toString()`.
enum SessionError {
  /// The session's sample rate differs from the running device's.
  sampleRateMismatch,

  /// The session was written by a newer, incompatible version of the app.
  unsupportedVersion,

  /// A save-as / rename / duplicate targeted a name another session carries.
  nameCollision,

  /// The session bundle's overdub-layer data is corrupt or foreign.
  corruptLayers,

  /// Any other failure (I/O, engine, etc.); see [SessionState.errorMessage].
  unknown,

  /// A loaded rig is stopped until its full boot-settings image is recovered.
  bootPersistence,

  /// Writing the live rig failed; the catalog and the open session are as
  /// they were (the 19/05 banner).
  saveFailed,

  /// The open session cannot be deleted (plan D6).
  currentSessionProtected,
}

/// State of the [SessionCubit].
///
/// Two logical parts: the **per-action result** ([status] plus [outcome] /
/// [error] / [errorMessage] for the last action) and the **durable catalog**
/// ([currentSessionId] and [currentSessionName] — the document model's open
/// session — and [sessions] — the picker list). The catalog fields survive
/// across action transitions; the result fields describe only the most recent
/// action. Neither is persisted to disk (the current session is a runtime
/// pointer).
class SessionState extends Equatable {
  /// Creates a [SessionState].
  const SessionState({
    this.status = SessionStatus.idle,
    this.outcome,
    this.error,
    this.errorMessage,
    this.failedSessionId,
    this.currentSessionId,
    this.currentSessionName,
    this.sessions = const [],
    this.folders = const [],
    this.bootRecoveryRequired = false,
  });

  /// The current action status.
  final SessionStatus status;

  /// Which action succeeded, for localized success messaging.
  final SessionOutcome? outcome;

  /// The classified failure kind, for localized error messaging.
  final SessionError? error;

  /// The raw failure message, for diagnostics / the unknown-error fallback.
  final String? errorMessage;

  /// The session a failed action addressed (an Open's target), or null when
  /// the failure concerns no one session. A per-action result, like [error].
  final SessionId? failedSessionId;

  /// The bundle id of the session currently open (the document model), or
  /// `null` when none is loaded. A runtime pointer — never persisted. The id
  /// is the identity every catalog action addresses; a rename never changes
  /// it.
  final SessionId? currentSessionId;

  /// The display name of the open session, for the stage header, or `null`
  /// when none is loaded. Follows a rename of the open session.
  final String? currentSessionName;

  /// The saved-session catalog, for the picker.
  final List<SessionSummary> sessions;

  /// The catalog's one-level folders, sorted, for the Library's chips and
  /// Move to folder.
  final List<String> folders;

  /// The new rig was accepted but boot settings or bindings still need Retry.
  final bool bootRecoveryRequired;

  /// Returns a copy for the next emit.
  ///
  /// The **result** fields ([outcome] / [error] / [errorMessage] /
  /// [failedSessionId]) are per-transition: they default to `null` (cleared)
  /// unless passed, so a fresh status never carries a stale result. The
  /// **durable** fields ([currentSessionId] / [currentSessionName] /
  /// [sessions] / [folders]) are preserved unless overridden.
  SessionState copyWith({
    SessionStatus? status,
    SessionOutcome? outcome,
    SessionError? error,
    String? errorMessage,
    SessionId? failedSessionId,
    SessionId? currentSessionId,
    String? currentSessionName,
    List<SessionSummary>? sessions,
    List<String>? folders,
    bool? bootRecoveryRequired,
  }) => SessionState(
    status: status ?? this.status,
    outcome: outcome,
    error: error,
    errorMessage: errorMessage,
    failedSessionId: failedSessionId,
    currentSessionId: currentSessionId ?? this.currentSessionId,
    currentSessionName: currentSessionName ?? this.currentSessionName,
    sessions: sessions ?? this.sessions,
    folders: folders ?? this.folders,
    bootRecoveryRequired: bootRecoveryRequired ?? this.bootRecoveryRequired,
  );

  @override
  List<Object?> get props => [
    status,
    outcome,
    error,
    errorMessage,
    failedSessionId,
    currentSessionId,
    currentSessionName,
    sessions,
    folders,
    bootRecoveryRequired,
  ];
}
