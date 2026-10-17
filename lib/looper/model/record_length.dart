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

/// The looper mode, stored beside the length presets it couples with.
final class LooperModeAddress extends Equatable {
  const LooperModeAddress();

  @override
  List<Object?> get props => const [];
}

/// The length default, every track override and the looper mode: the value
/// the Record length owner holds.
final class RecordLengthVector extends Equatable {
  /// Copies overrides so a caller cannot change an accepted vector.
  RecordLengthVector({
    required this.defaultBars,
    required Map<int, int> trackOverrides,
    required this.mode,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  final int defaultBars;

  /// Explicit presets, including zero (Auto); absent tracks inherit.
  final Map<int, int> trackOverrides;
  final LooperMode mode;

  /// The bars [address] holds; null for a track that inherits.
  int? at(RecordLengthAddress address) => switch (address.channel) {
    null => defaultBars,
    final channel => trackOverrides[channel],
  };

  /// This vector with [address] set to [bars]; null removes a track's
  /// override.
  RecordLengthVector withBars(RecordLengthAddress address, int? bars) {
    final channel = address.channel;
    if (!address.isValid ||
        (channel == null && bars == null) ||
        (bars != null && (bars < 0 || bars > 64))) {
      throw ArgumentError('Invalid record length at $address');
    }
    return RecordLengthVector(
      defaultBars: channel == null ? bars! : defaultBars,
      trackOverrides: channel == null
          ? trackOverrides
          : {
              for (final entry in trackOverrides.entries)
                if (entry.key != channel) entry.key: entry.value,
              channel: ?bars,
            },
      mode: mode,
    );
  }

  /// This vector in [next] mode with [overrides] in place of its own.
  RecordLengthVector withMode(LooperMode next, {Map<int, int>? overrides}) =>
      RecordLengthVector(
        defaultBars: defaultBars,
        trackOverrides: overrides ?? trackOverrides,
        mode: next,
      );

  @override
  List<Object?> get props => [defaultBars, trackOverrides, mode];
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
