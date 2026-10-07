import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// The shared default or one fixed track's Loop/Once choice.
final class OneShotAddress extends Equatable {
  /// The default inherited by tracks without an override.
  const OneShotAddress.defaults() : channel = null;

  /// One fixed, zero-based track, independent of selection and its label.
  const OneShotAddress.track(int this.channel);

  /// Null denotes the default; track coordinates are 0 through 7.
  final int? channel;

  /// Whether this address names a supported fixed scope.
  bool get isValid => channel == null || (channel! >= 0 && channel! < 8);

  @override
  List<Object?> get props => [channel];
}

/// Accepted playback choices; override membership distinguishes Custom from
/// inherit.
final class OneShotSnapshot extends Equatable {
  /// Takes an immutable copy of the explicit track overrides.
  OneShotSnapshot({
    required this.defaultOneShot,
    required Map<int, bool> trackOverrides,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  /// Default playback choice: false loops, true plays once.
  final bool defaultOneShot;

  /// Explicit overrides, including false; absent tracks inherit the default.
  final Map<int, bool> trackOverrides;

  /// The audible setting for a supported address.
  bool effectiveOneShot(OneShotAddress address) =>
      trackOverrides[address.channel] ?? defaultOneShot;

  /// The value [address] holds; null for a track that inherits.
  bool? at(OneShotAddress address) => address.channel == null
      ? defaultOneShot
      : trackOverrides[address.channel];

  /// This snapshot with [address] set to [oneShot]; null removes only a
  /// track's override. Throws for an unsupported address or a null default.
  OneShotSnapshot withValue(OneShotAddress address, {required bool? oneShot}) {
    final channel = address.channel;
    if (!address.isValid || channel == null && oneShot == null) {
      throw ArgumentError.value(address, 'address');
    }
    if (channel == null) {
      return OneShotSnapshot(
        defaultOneShot: oneShot!,
        trackOverrides: trackOverrides,
      );
    }
    final overrides = Map<int, bool>.of(trackOverrides);
    if (oneShot == null) {
      overrides.remove(channel);
    } else {
      overrides[channel] = oneShot;
    }
    return OneShotSnapshot(
      defaultOneShot: defaultOneShot,
      trackOverrides: overrides,
    );
  }

  @override
  List<Object?> get props => [defaultOneShot, trackOverrides];
}

/// The session and audio-device generation owning a captured playback edit.
typedef OneShotLifetime = ({int sessionRevision, int mixGeneration});

/// Whether playback was accepted, refused, replaced, or needs recovery.
enum OneShotStatus { applied, rejected, superseded, recoveryRequired }

/// A verified persistence and callback publication outcome.
final class OneShotOutcome {
  /// Creates the result of one playback transaction.
  const OneShotOutcome(
    this.status, {
    this.deferred = false,
    this.engineResult,
    this.error,
  });

  /// Final admission status.
  final OneShotStatus status;

  /// Accepted while stopped, without claiming audible application.
  final bool deferred;

  /// Native refusal when available.
  final EngineResult? engineResult;

  /// Storage or recovery failure when available.
  final Object? error;

  /// Whether the intent was confirmed.
  bool get isOk => status == OneShotStatus.applied;
}

/// Narrow access to the application-owned playback transaction.
abstract interface class OneShotControl {
  /// Accepted live values, null until initialization has succeeded.
  OneShotSnapshot? get oneShotSnapshot;

  /// Values to save and replay when a temporary held value is audible.
  OneShotSnapshot get durableOneShotSnapshot;

  /// Current session/device identity, captured before queuing source work.
  OneShotLifetime get oneShotLifetime;

  /// Ordinary intent revision for this address, independent of other tracks.
  int oneShotRevision(OneShotAddress address);

  /// Accepted ordinary intent; a null track value means Use default.
  Stream<({OneShotAddress address, bool? oneShot})> get ordinaryOneShotChanges;

  /// Accepts one controller value and optional authored durable Released value.
  Future<OneShotOutcome> setControllerOneShot(
    OneShotAddress address, {
    required bool oneShot,
    required OneShotLifetime lifetime,
    required int revision,
    bool? releasedOneShot,
  });

  /// Ordinary fixed-track edit; null removes only this field's override.
  Future<OneShotOutcome> setTrackOneShot({
    required int channel,
    required bool? oneShot,
  });
}
