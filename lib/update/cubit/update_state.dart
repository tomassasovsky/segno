part of 'update_cubit.dart';

/// Where the update flow currently is.
enum UpdatePhase {
  /// Nothing in progress; no check has run (or the platform is unsupported).
  idle,

  /// A read-only availability check is running.
  checking,

  /// The last check found the device on the newest published build.
  upToDate,

  /// A newer build is available and not yet staged.
  available,

  /// The available bundle is downloading/staging to the inactive slot.
  downloading,

  /// A newer build is fully staged and awaiting a restart to apply.
  staged,

  /// An install was cut off (a crash, a power loss or a stopped service)
  /// before it staged anything; see [UpdateState.interrupted]. The running
  /// software is unchanged, and the player retries or drops it.
  interrupted,

  /// The last operation failed; see [UpdateState.errorMessage].
  error,
}

/// Which operation put the flow into [UpdatePhase.error].
///
/// The two read differently and retry differently: a check that could not
/// reach the server is retried by checking, and a download that broke off is
/// retried by downloading. One error phase with one wording told half the
/// users the wrong thing and offered all of them the wrong button.
enum UpdateFailure {
  /// The read-only availability check.
  check,

  /// The download and stage of an offered bundle.
  download,
}

/// Immutable state of the update feature.
class UpdateState extends Equatable {
  /// Creates an [UpdateState].
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.supported = false,
    this.channel = '',
    this.currentVersion,
    this.available,
    this.progress = 0,
    this.autoCheck = true,
    this.dismissed = const {},
    this.errorMessage,
    this.failure,
    this.interrupted,
    this.rollback,
  });

  /// The current phase of the flow.
  final UpdatePhase phase;

  /// Whether in-app updates are offered on this platform.
  final bool supported;

  /// The channel this device follows, for display.
  final String channel;

  /// The running semantic version, or `null` before the first load / when
  /// unknown. Nullable (rather than [Version.none]) so this state can stay
  /// `const` — `pub_semver`'s [Version] is not const-constructible.
  final Version? currentVersion;

  /// The newer manifest found by the last check, or `null` if none.
  final UpdateManifest? available;

  /// Download/stage progress in `[0, 1]`, meaningful in [UpdatePhase.downloading].
  final double progress;

  /// Whether the passive, read-only check runs automatically.
  final bool autoCheck;

  /// Versions the user dismissed the notification for; a newer version
  /// re-notifies because it is not in this set.
  final Set<Version> dismissed;

  /// A human-readable message when [phase] is [UpdatePhase.error].
  final String? errorMessage;

  /// What failed, when [phase] is [UpdatePhase.error].
  final UpdateFailure? failure;

  /// The version whose install was cut off, in [UpdatePhase.interrupted].
  final Version? interrupted;

  /// A staged build that did not start, so the console went back to
  /// `restored`; shown until dismissed, whatever the phase.
  final ({Version attempted, Version restored})? rollback;

  /// Whether a newer build is currently on offer (available or staged).
  bool get hasUpdate => available != null;

  /// Whether the startup banner should be shown: an update is available and its
  /// version has not been dismissed.
  bool get shouldNotify =>
      available != null && !dismissed.contains(available!.version);

  /// Copies this state, overriding the given fields. Set [clearAvailable] to
  /// drop the available manifest (there is no other way to null it), and
  /// [clearError] to clear a previous error message; [clearInterrupted] and
  /// [clearRollback] drop those the same way.
  UpdateState copyWith({
    UpdatePhase? phase,
    bool? supported,
    String? channel,
    Version? currentVersion,
    UpdateManifest? available,
    bool clearAvailable = false,
    double? progress,
    bool? autoCheck,
    Set<Version>? dismissed,
    String? errorMessage,
    UpdateFailure? failure,
    bool clearError = false,
    Version? interrupted,
    bool clearInterrupted = false,
    ({Version attempted, Version restored})? rollback,
    bool clearRollback = false,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      supported: supported ?? this.supported,
      channel: channel ?? this.channel,
      currentVersion: currentVersion ?? this.currentVersion,
      available: clearAvailable ? null : (available ?? this.available),
      progress: progress ?? this.progress,
      autoCheck: autoCheck ?? this.autoCheck,
      dismissed: dismissed ?? this.dismissed,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      failure: clearError ? null : (failure ?? this.failure),
      interrupted: clearInterrupted ? null : (interrupted ?? this.interrupted),
      rollback: clearRollback ? null : (rollback ?? this.rollback),
    );
  }

  @override
  List<Object?> get props => [
    phase,
    supported,
    channel,
    currentVersion,
    available,
    progress,
    autoCheck,
    dismissed,
    errorMessage,
    failure,
    interrupted,
    rollback,
  ];
}
