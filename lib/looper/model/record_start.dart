import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// Supported count-in lengths in bars; zero is Off.
const List<int> kCountInBarOptions = [0, 1, 2, 4];

/// The accepted mutually exclusive Count-in and Sound-start settings.
final class RecordStartSettings extends Equatable {
  /// Creates a validated pair without coercing unsupported choices.
  RecordStartSettings({
    required this.countInBars,
    required this.soundStart,
  }) {
    if (!kCountInBarOptions.contains(countInBars) ||
        countInBars > 0 && soundStart) {
      throw ArgumentError('Invalid recording-start pair');
    }
  }

  /// Decodes exact absence while preserving explicit Off or Sound intent.
  factory RecordStartSettings.fromCheckpoint(
    ({int? countInBars, bool? soundStart}) checkpoint,
  ) => RecordStartSettings(
    countInBars:
        checkpoint.countInBars ?? (checkpoint.soundStart == true ? 0 : 1),
    soundStart: checkpoint.soundStart ?? false,
  );

  /// Count-in length in bars, independent of a running countdown.
  final int countInBars;

  /// Whether an empty-track Record waits for a selected source's signal.
  final bool soundStart;

  @override
  List<Object?> get props => [countInBars, soundStart];
}

/// Confirmed recording-start settings and current capture eligibility.
final class RecordStartSnapshot extends Equatable {
  /// Creates an immutable accepted snapshot.
  const RecordStartSnapshot({
    required this.settings,
    required this.captureLocked,
  });

  /// The confirmed count-in and Sound pair.
  final RecordStartSettings settings;

  /// Actual recording or overdubbing prevents edits.
  final bool captureLocked;

  /// Whether this initialized owner can accept a new choice.
  bool get canEdit => !captureLocked;

  @override
  List<Object?> get props => [settings, captureLocked];
}

/// The confirmed result of one recording-start transaction.
enum RecordStartStatus { applied, rejected, superseded, recoveryRequired }

/// Persistence and native receipt outcome for the pair.
final class RecordStartOutcome {
  /// Creates an outcome without treating enqueue as confirmation.
  const RecordStartOutcome(
    this.status, {
    this.engineResult,
    this.error,
    this.deferred = false,
  });

  /// Final admission or recovery status.
  final RecordStartStatus status;

  /// Native admission or callback failure, when available.
  final EngineResult? engineResult;

  /// Persistence or recovery failure, when available.
  final Object? error;

  /// Accepted stopped intent, without claiming callback publication.
  final bool deferred;

  /// Whether the requested pair was confirmed.
  bool get isOk => status == RecordStartStatus.applied;
}

/// Narrow ordinary access to the application-owned recording-start pair.
abstract interface class RecordStartControl {
  /// Accepted pair; null during initialization or recovery.
  RecordStartSnapshot? get recordStartSnapshot;

  /// Last accepted readout, retained during recovery; null before first load.
  RecordStartSettings? get confirmedRecordStart;

  /// Sets Count-in; positive values disable Sound, zero preserves it.
  Future<RecordStartOutcome> setCountInBars(int bars);

  /// Sets Sound; enabling clears Count-in, disabling preserves it.
  Future<RecordStartOutcome> setSoundStart({required bool enabled});
}
