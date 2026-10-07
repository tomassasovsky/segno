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

  /// A [SessionCubit.newLoop] started an empty loop under the next automatic
  /// name, which is now current.
  newLoop,

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

  /// A folder was renamed.
  folderRenamed,

  /// An empty folder was deleted.
  folderDeleted,
}

/// A classified failure kind, so the UI can show a localized, human-readable
/// message instead of a raw `toString()`.
enum SessionError {
  /// The session's sample rate differs from the running device's.
  sampleRateMismatch,

  /// The session was written by a newer, incompatible version of the app.
  unsupportedVersion,

  /// The session was written by an older version of the app that this one
  /// cannot convert; the bundle was left untouched.
  unconvertible,

  /// A save-as / rename / duplicate targeted a name another session carries.
  nameCollision,

  /// The session bundle's overdub-layer data is corrupt or foreign.
  corruptLayers,

  /// Any other failure (I/O, engine, etc.); see [SessionState.errorMessage].
  unknown,

  /// A loaded rig is stopped until its full boot-settings image is recovered.
  bootPersistence,

  /// Refused at its commit because another operation it must not overlap is
  /// in flight; [SessionState.refusedBy] names it (the guard table, #1198).
  busy,

  /// Writing the live rig failed; the catalog and the open session are as
  /// they were (the 19/05 banner).
  saveFailed,

  /// The open session cannot be deleted (plan D6).
  currentSessionProtected,

  /// A folder that still holds sessions cannot be deleted.
  folderNotEmpty,

  /// An Open or New loop ended a take in progress, and it did not finish in
  /// time; nothing was saved, opened or cleared.
  captureInProgress,

  /// A New loop started and is current, but its empty bundle could not be
  /// written yet: the first Save writes it.
  newLoopNotSaved,
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
    this.conversion,
    this.refusedBy,
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

  /// What the player is told about a session that was just converted from
  /// an older version, or null. A per-transition result, like [outcome].
  final SessionConversionNotice? conversion;

  /// For [SessionError.busy]: the kind of operation that refused the action.
  /// Per-transition, like [error].
  final GuardKind? refusedBy;

  /// Returns a copy for the next emit.
  ///
  /// The **result** fields ([outcome] / [error] / [errorMessage] /
  /// [failedSessionId] / [conversion]) are per-transition: they default to
  /// `null` (cleared) unless passed, so a fresh status never carries a stale
  /// result. The **durable** fields ([currentSessionId] /
  /// [currentSessionName] / [sessions] / [folders]) are preserved unless
  /// overridden.
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
    SessionConversionNotice? conversion,
    GuardKind? refusedBy,
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
    conversion: conversion,
    refusedBy: refusedBy,
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
    conversion,
    refusedBy,
  ];
}

/// The notice for a session converted on open from an older version.
class SessionConversionNotice extends Equatable {
  /// Creates a [SessionConversionNotice].
  const SessionConversionNotice({
    required this.fromVersion,
    required this.written,
    this.changes = const {},
  });

  /// The schema the session was saved with.
  final int fromVersion;

  /// Whether the converted session was written back with the original kept
  /// beside it. When false the original file is unchanged on disk.
  final bool written;

  /// The audible changes the conversion made, each told to the player.
  final Set<SessionConversionChange> changes;

  @override
  List<Object?> get props => [fromVersion, written, changes];
}
