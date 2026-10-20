import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// Confirmed Hear click choice and current capture eligibility.
final class ClickModeSnapshot extends Equatable {
  /// Creates an immutable accepted mode snapshot.
  const ClickModeSnapshot({required this.mode, required this.captureLocked});

  /// The accepted audible policy, independent of output routing and volume.
  final ClickMode mode;

  /// Actual recording or overdubbing prevents changing the policy.
  final bool captureLocked;

  /// Whether the initialized owner can accept a new choice.
  bool get canEdit => !captureLocked;

  @override
  List<Object?> get props => [mode, captureLocked];
}

/// The session and device generation owning a captured mode operation.
typedef ClickModeLifetime = ({int sessionRevision, int mixGeneration});

/// The confirmed result of a Hear click transaction.
enum ClickModeStatus { applied, rejected, superseded, recoveryRequired }

/// Persistence and callback receipt, without treating enqueue as acceptance.
final class ClickModeOutcome {
  /// Creates an outcome for one attempted transaction.
  const ClickModeOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// Final admission or recovery status.
  final ClickModeStatus status;

  /// Accepted as stopped restart intent, without claiming audible publication.
  final bool deferred;

  /// Native admission or callback failure, when available.
  final EngineResult? engineResult;

  /// Persistence or recovery failure, when available.
  final Object? error;

  /// Whether the requested intent was confirmed.
  bool get isOk => status == ClickModeStatus.applied;
}

/// Narrow access to the application-owned Hear click transaction.
abstract interface class ClickModeControl {
  /// Accepted mode; null while initialization or recovery is pending.
  ClickModeSnapshot? get clickModeSnapshot;

  /// Released choice used for settings, Session Save and restart.
  ClickMode get durableClickMode;

  /// Current session/device identity, captured before source work queues.
  ClickModeLifetime get clickModeLifetime;

  /// Accepted ordinary-intent revision for this global setting.
  int get clickModeRevision;

  /// Accepted ordinary choices; rejected edits do not publish here.
  Stream<ClickMode> get ordinaryClickModeChanges;

  /// Ordinary choice, accepted only after persistence and native confirmation.
  Future<ClickModeOutcome> setClickMode(ClickMode mode);

  /// Controller choice with its optional authored durable Released value.
  Future<ClickModeOutcome> setControllerClickMode(
    ClickMode mode, {
    required ClickModeLifetime lifetime,
    required int revision,
    ClickMode? releasedMode,
  });
}
