import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// The recording timing default or one fixed track.
final class RecordTimingAddress extends Equatable {
  /// The timing inherited by tracks without an explicit override.
  const RecordTimingAddress.defaults() : channel = null;

  /// A zero-based track independent of selection, content, or label.
  const RecordTimingAddress.track(int this.channel);

  /// Null denotes the default; supported track coordinates are zero to seven.
  final int? channel;

  /// Whether this address names one of the nine supported scopes.
  bool get isValid => channel == null || (channel! >= 0 && channel! < 8);

  @override
  List<Object?> get props => [channel];
}

/// The timing default, its remembered division and every track override:
/// the value the Record timing owner holds.
final class RecordTimingVector extends Equatable {
  /// Copies overrides so a caller cannot change an accepted vector.
  RecordTimingVector({
    required this.defaultTiming,
    required this.rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  /// The timing inherited by tracks without an override.
  final RecordTiming defaultTiming;

  /// The default's last musical division, kept while Immediately is chosen.
  final GridDivision rememberedDivision;

  /// Explicit choices, including Immediately; absent tracks inherit.
  final Map<int, RecordTiming> trackOverrides;

  /// The value [address] holds; null for a track that inherits.
  RecordTiming? at(RecordTimingAddress address) => switch (address.channel) {
    null => defaultTiming,
    final channel => trackOverrides[channel],
  };

  /// This vector with [address] set to [timing]; null removes a track's
  /// override. A default without a gate keeps the remembered division.
  RecordTimingVector withValue(
    RecordTimingAddress address,
    RecordTiming? timing,
  ) {
    final channel = address.channel;
    if (!address.isValid || (channel == null && timing == null)) {
      throw ArgumentError('Invalid record timing at $address');
    }
    if (channel == null) {
      return RecordTimingVector(
        defaultTiming: timing!,
        rememberedDivision: timing.quantize
            ? timing.division
            : rememberedDivision,
        trackOverrides: trackOverrides,
      );
    }
    return RecordTimingVector(
      defaultTiming: defaultTiming,
      rememberedDivision: rememberedDivision,
      trackOverrides: {
        for (final entry in trackOverrides.entries)
          if (entry.key != channel) entry.key: entry.value,
        channel: ?timing,
      },
    );
  }

  @override
  List<Object?> get props => [
    defaultTiming,
    rememberedDivision,
    trackOverrides,
  ];
}

/// Confirmed timing, explicit inheritance membership, and edit eligibility.
final class RecordTimingSnapshot extends Equatable {
  /// Copies overrides so a caller cannot change accepted owner state.
  RecordTimingSnapshot({
    required this.defaultTiming,
    required this.rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required this.captureLocked,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  /// The timing inherited by tracks without an override.
  final RecordTiming defaultTiming;

  /// The default's last musical division, retained while Immediately is chosen.
  final GridDivision rememberedDivision;

  /// Explicit choices, including Immediately; absent tracks inherit.
  final Map<int, RecordTiming> trackOverrides;

  /// Whether recording or overdubbing currently prevents timing edits.
  final bool captureLocked;

  /// The effective musical choice at this supported address.
  RecordTiming effectiveTiming(RecordTimingAddress address) =>
      trackOverrides[address.channel] ?? defaultTiming;

  /// All modes retain track timing; capture alone temporarily locks editing.
  bool canEdit(RecordTimingAddress address) =>
      address.isValid && !captureLocked;

  @override
  List<Object?> get props => [
    defaultTiming,
    rememberedDivision,
    trackOverrides,
    captureLocked,
  ];
}

/// The session and device generation owning a captured timing operation.
typedef RecordTimingLifetime = ({int sessionRevision, int mixGeneration});

/// The confirmed result of a timing transaction.
enum RecordTimingStatus { applied, rejected, superseded, recoveryRequired }

/// Persistence and native receipt result, without treating enqueue as success.
final class RecordTimingOutcome {
  /// Creates an outcome for one attempted timing transaction.
  const RecordTimingOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// Final admission or recovery status.
  final RecordTimingStatus status;

  /// Accepted while stopped as restart intent, without an audible claim.
  final bool deferred;

  /// The native admission or receipt failure when available.
  final EngineResult? engineResult;

  /// A persistence or recovery failure when available.
  final Object? error;

  /// Whether the requested intent was confirmed.
  bool get isOk => status == RecordTimingStatus.applied;
}

/// Narrow access to the one application-owned recording timing transaction.
abstract interface class RecordTimingControl {
  /// Confirmed live values; null while initialization or recovery is pending.
  RecordTimingSnapshot? get recordTimingSnapshot;

  /// Released values and remembered division used for Save and restart.
  RecordTimingSnapshot get durableRecordTimingSnapshot;

  /// Current session/device identity, captured before controller work queues.
  RecordTimingLifetime get recordTimingLifetime;

  /// Accepted ordinary-intent revision for this address only.
  int recordTimingRevision(RecordTimingAddress address);

  /// Accepted ordinary change; null on a track means Use default.
  Stream<({RecordTimingAddress address, RecordTiming? timing})>
  get ordinaryRecordTimingChanges;

  /// Writes a controller choice and its optional authored durable release.
  Future<RecordTimingOutcome> setControllerTiming(
    RecordTimingAddress address,
    RecordTiming timing, {
    required RecordTimingLifetime lifetime,
    required int revision,
    RecordTiming? releasedTiming,
  });

  /// Ordinary fixed-track choice; null removes only the timing override.
  Future<RecordTimingOutcome> setTrackTiming({
    required int channel,
    required RecordTiming? timing,
  });
}

/// Confirmed recording policy and independent initialization availability.
final class RecordTimingState extends Equatable {
  const RecordTimingState({
    this.defaultTiming = RecordTiming.immediately,
    this.rememberedDivision = GridDivision.off,
    this.trackOverrides = const {},
    this.captureLocked = false,
    this.recordTimingReady = false,
  });
  final RecordTiming defaultTiming;
  final GridDivision rememberedDivision;
  final Map<int, RecordTiming> trackOverrides;
  final bool captureLocked;
  final bool recordTimingReady;

  /// Confirmed choices, or null while initialization or recovery is pending.
  RecordTimingSnapshot? get recordTimingSnapshot => recordTimingReady
      ? RecordTimingSnapshot(
          defaultTiming: defaultTiming,
          rememberedDivision: rememberedDivision,
          trackOverrides: trackOverrides,
          captureLocked: captureLocked,
        )
      : null;

  @override
  List<Object?> get props => [
    defaultTiming,
    rememberedDivision,
    trackOverrides,
    captureLocked,
    recordTimingReady,
  ];
}
