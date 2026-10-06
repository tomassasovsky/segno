import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// The shared default or one fixed track's overdub decay.
final class DecayAddress extends Equatable {
  /// The default inherited by tracks without an override.
  const DecayAddress.defaults() : channel = null;

  /// One fixed, zero-based track, independent of selection and its label.
  const DecayAddress.track(int this.channel);

  /// Null denotes the default; track coordinates are 0 through 7.
  final int? channel;

  /// Whether this address names a supported fixed scope.
  bool get isValid => channel == null || (channel! >= 0 && channel! < 8);

  @override
  List<Object?> get props => [channel];
}

/// Accepted decay values; override membership distinguishes Custom from
/// inherit.
final class DecaySnapshot extends Equatable {
  /// Takes an immutable copy of the explicit track overrides.
  DecaySnapshot({
    required this.defaultPercent,
    required Map<int, int> trackOverrides,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  /// Default decay as an integer percent, 0 through 100.
  final int defaultPercent;

  /// Explicit overrides, including zero; absent tracks inherit the default.
  final Map<int, int> trackOverrides;

  /// The audible setting for a supported address.
  int effectivePercent(DecayAddress address) =>
      trackOverrides[address.channel] ?? defaultPercent;

  /// The value [address] holds; null for a track that inherits.
  int? at(DecayAddress address) => address.channel == null
      ? defaultPercent
      : trackOverrides[address.channel];

  /// This snapshot with [address] set to [percent]; null removes only a
  /// track's override. Throws for an unsupported address or a null default.
  DecaySnapshot withValue(DecayAddress address, int? percent) {
    final channel = address.channel;
    if (!address.isValid || channel == null && percent == null) {
      throw ArgumentError.value(address, 'address');
    }
    if (channel == null) {
      return DecaySnapshot(
        defaultPercent: percent!,
        trackOverrides: trackOverrides,
      );
    }
    final overrides = Map<int, int>.of(trackOverrides);
    if (percent == null) {
      overrides.remove(channel);
    } else {
      overrides[channel] = percent;
    }
    return DecaySnapshot(
      defaultPercent: defaultPercent,
      trackOverrides: overrides,
    );
  }

  @override
  List<Object?> get props => [defaultPercent, trackOverrides];
}

/// The session and audio-device generation owning a captured decay edit.
typedef DecayLifetime = ({int sessionRevision, int mixGeneration});

/// Whether decay was accepted, refused, replaced, or needs explicit recovery.
enum DecayStatus { applied, rejected, superseded, recoveryRequired }

/// A verified persistence and atomic native publication outcome.
final class DecayOutcome {
  /// Creates the result of one decay transaction.
  const DecayOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// Final admission status.
  final DecayStatus status;

  /// Accepted while stopped, without claiming audible application.
  final bool deferred;

  /// Native refusal when available.
  final EngineResult? engineResult;

  /// Storage or recovery failure when available.
  final Object? error;

  /// Whether the intent was confirmed.
  bool get isOk => status == DecayStatus.applied;
}

/// Narrow access to the application-owned decay transaction.
abstract interface class DecayControl {
  /// Accepted live values, null until initialization has succeeded.
  DecaySnapshot? get decaySnapshot;

  /// Values to save and replay when a temporary held value is audible.
  DecaySnapshot get durableDecaySnapshot;

  /// Current session/device identity, captured before queuing source work.
  DecayLifetime get decayLifetime;

  /// Ordinary intent revision for this address, independent of other tracks.
  int decayRevision(DecayAddress address);

  /// Accepted ordinary intent; a null track value means Use default.
  Stream<({DecayAddress address, int? percent})> get ordinaryDecayChanges;

  /// Accepts one controller value and optional authored durable Released value.
  Future<DecayOutcome> setControllerDecay(
    DecayAddress address,
    int percent, {
    required DecayLifetime lifetime,
    required int revision,
    int? releasedPercent,
  });

  /// Ordinary fixed-track edit; null removes only this field's override.
  Future<DecayOutcome> setTrackOverdubDecay({
    required int channel,
    required int? percent,
  });
}
