import 'package:looper_repository/looper_repository.dart';

/// The owned setting families, in the registry's fixed order.
enum OwnedSetting {
  clickVolume,
  hearClick,
  recordStart,
  decay,
  oneShot,
  recordLength,
  recordTiming,
  fade,
  followTempo,
  pitchMode,
}

/// The session and device generation that own a captured setting write.
typedef SettingLifetime = ({int sessionRevision, int mixGeneration});

/// Whether an owned setting write was confirmed, refused, replaced, or needs
/// recovery.
enum SettingStatus { applied, rejected, superseded, recoveryRequired }

/// The confirmed result of one owned setting transaction, distinct from
/// command enqueue.
final class SettingOutcome {
  /// Creates an outcome for one attempted transaction.
  const SettingOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// Final admission or recovery status.
  final SettingStatus status;

  /// Accepted while stopped, without claiming audible callback publication.
  final bool deferred;

  /// Native admission or callback failure, when available.
  final EngineResult? engineResult;

  /// Persistence or recovery failure, when available.
  final Object? error;

  /// Whether the requested value was confirmed.
  bool get isOk => status == SettingStatus.applied;
}
