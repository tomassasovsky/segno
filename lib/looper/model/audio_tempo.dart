import 'package:equatable/equatable.dart';

/// The shared default or one fixed track's Follow tempo or Pitch choice
/// (#1179 Audio & tempo).
final class AudioTempoAddress extends Equatable {
  /// The default inherited by tracks without an override.
  const AudioTempoAddress.defaults() : channel = null;

  /// One fixed, zero-based track, independent of selection and its label.
  const AudioTempoAddress.track(int this.channel);

  /// Null denotes the default; track coordinates are 0 through 7.
  final int? channel;

  /// Whether this address names a supported fixed scope.
  bool get isValid => channel == null || (channel! >= 0 && channel! < 8);

  @override
  List<Object?> get props => [channel];
}

/// The default and nine addresses an Audio & tempo family stores.
const audioTempoAddresses = <Object?>[
  AudioTempoAddress.defaults(),
  AudioTempoAddress.track(0),
  AudioTempoAddress.track(1),
  AudioTempoAddress.track(2),
  AudioTempoAddress.track(3),
  AudioTempoAddress.track(4),
  AudioTempoAddress.track(5),
  AudioTempoAddress.track(6),
  AudioTempoAddress.track(7),
];

/// Accepted Follow tempo or Pitch choices: a default every track inherits and
/// the explicit track overrides; membership distinguishes Custom from
/// inherit, including an override equal to the default.
final class InheritSnapshot<T extends Object> extends Equatable {
  /// Takes an immutable copy of the explicit track overrides.
  InheritSnapshot({
    required this.defaultValue,
    required Map<int, T> trackOverrides,
  }) : trackOverrides = Map.unmodifiable(trackOverrides);

  /// The value tracks without an override inherit.
  final T defaultValue;

  /// Explicit overrides; absent tracks inherit [defaultValue].
  final Map<int, T> trackOverrides;

  /// The value a track plays with.
  T effective(int channel) => trackOverrides[channel] ?? defaultValue;

  /// The value [address] holds; null for a track that inherits.
  T? at(AudioTempoAddress address) =>
      address.channel == null ? defaultValue : trackOverrides[address.channel];

  /// This snapshot with [address] set to [value]; null removes only a track's
  /// override. Throws for an unsupported address or a null default.
  InheritSnapshot<T> withValue(AudioTempoAddress address, T? value) {
    final channel = address.channel;
    if (!address.isValid || channel == null && value == null) {
      throw ArgumentError.value(address, 'address');
    }
    if (channel == null) {
      return InheritSnapshot(
        defaultValue: value!,
        trackOverrides: trackOverrides,
      );
    }
    final overrides = Map<int, T>.of(trackOverrides);
    if (value == null) {
      overrides.remove(channel);
    } else {
      overrides[channel] = value;
    }
    return InheritSnapshot(
      defaultValue: defaultValue,
      trackOverrides: overrides,
    );
  }

  @override
  List<Object?> get props => [defaultValue, trackOverrides];
}
