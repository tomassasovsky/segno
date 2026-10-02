import 'package:looper_repository/looper_repository.dart';

/// The Click stage's linear gain ceiling; unity is half of its travel.
const double kMaxClickGain = 2;

/// The session and device that own a captured Click intent.
typedef ClickVolumeLifetime = ({int sessionRevision, int mixGeneration});

/// Whether a Click edit was confirmed, refused, replaced, or needs recovery.
enum ClickVolumeStatus { applied, rejected, superseded, recoveryRequired }

/// A durable Click transaction's result, distinct from command enqueue.
final class ClickVolumeOutcome {
  /// Creates a transaction outcome.
  const ClickVolumeOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// The final admission status.
  final ClickVolumeStatus status;

  /// Accepted while stopped, without claiming audible callback publication.
  final bool deferred;

  /// The native refusal, when available.
  final EngineResult? engineResult;

  /// The persistence or recovery failure, when available.
  final Object? error;

  /// Whether the requested intent was confirmed.
  bool get isOk => status == ClickVolumeStatus.applied;
}

/// Narrow access to the one application-owned Click volume transaction.
abstract interface class ClickVolumeControl {
  /// Accepted physical gain, or null while the owner is unavailable/loading.
  double? get clickVolume;

  /// Gain to capture durably while a temporary controller value is audible.
  double get durableClickVolume;

  /// Current session/device identity; capture before queuing source work.
  ClickVolumeLifetime get clickVolumeLifetime;

  /// Accepted ordinary edits, in physical gain units.
  Stream<double> get ordinaryClickVolumeChanges;

  /// Writes controller intent, with an authored durable Released override.
  Future<ClickVolumeOutcome> setControllerClickVolume(
    double volume, {
    required ClickVolumeLifetime lifetime,
    double? releasedVolume,
  });
}
