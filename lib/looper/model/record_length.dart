import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// A future-recording preset for the default or one fixed track.
final class RecordLengthAddress extends Equatable {
  const RecordLengthAddress.defaults() : channel = null;
  const RecordLengthAddress.track(int this.channel);

  final int? channel;
  bool get isValid => channel == null || (channel! >= 0 && channel! < 8);

  @override
  List<Object?> get props => [channel];
}

/// Confirmed presets and their current edit eligibility.
final class RecordLengthSnapshot extends Equatable {
  RecordLengthSnapshot({
    required this.defaultBars,
    required Map<int, int> trackOverrides,
    required this.mode,
    required this.captureLocked,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  final int defaultBars;
  final Map<int, int> trackOverrides;
  final LooperMode mode;
  final bool captureLocked;

  int effectiveBars(RecordLengthAddress address) => mode == LooperMode.multi
      ? defaultBars
      : trackOverrides[address.channel] ?? defaultBars;

  bool canEdit(RecordLengthAddress address) =>
      address.isValid &&
      !captureLocked &&
      (address.channel == null || mode != LooperMode.multi);

  @override
  List<Object?> get props => [defaultBars, trackOverrides, mode, captureLocked];
}

typedef RecordLengthLifetime = ({int sessionRevision, int mixGeneration});

enum RecordLengthStatus { applied, rejected, superseded, recoveryRequired }

final class RecordLengthOutcome {
  const RecordLengthOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  final RecordLengthStatus status;
  final bool deferred;
  final EngineResult? engineResult;
  final Object? error;
  bool get isOk => status == RecordLengthStatus.applied;
}

/// The application-owned length transaction, shared with ordinary mode edits.
abstract interface class RecordLengthControl {
  RecordLengthSnapshot? get recordLengthSnapshot;
  RecordLengthSnapshot get durableRecordLengthSnapshot;
  RecordLengthLifetime get recordLengthLifetime;
  int recordLengthRevision(RecordLengthAddress address);
  Stream<({RecordLengthAddress address, int? bars})>
  get ordinaryRecordLengthChanges;

  Future<RecordLengthOutcome> setControllerRecordLength(
    RecordLengthAddress address,
    int bars, {
    required RecordLengthLifetime lifetime,
    required int revision,
    int? releasedBars,
  });

  Future<RecordLengthOutcome> setTrackRecordLength({
    required int channel,
    required int? bars,
  });

  /// Uses the same queue and coupled native vector as length edits.
  Future<RecordLengthOutcome> setLooperMode(LooperMode mode);
}
