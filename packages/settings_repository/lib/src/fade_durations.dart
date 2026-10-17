import 'package:flutter/foundation.dart';

/// Confirmed setup for the next Fade gesture, independent of running envelopes.
@immutable
class FadeDurations {
  /// Validates and detaches exact millisecond values and Custom membership.
  factory FadeDurations({
    int defaultMs = 4000,
    Map<int, int> overrides = const {},
  }) {
    _validateDuration(defaultMs);
    for (final entry in overrides.entries) {
      _validateChannel(entry.key);
      _validateDuration(entry.value);
    }
    return FadeDurations._(defaultMs, Map.unmodifiable(overrides));
  }

  const FadeDurations._(this.defaultMs, this.overrides);

  /// Decodes a complete record without coercing invalid stored values.
  factory FadeDurations.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['defaultMs'] is! int ||
        value['overrides'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid Fade duration record');
    }
    final overrides = <int, int>{};
    for (final entry in (value['overrides'] as Map<String, dynamic>).entries) {
      final channel = int.tryParse(entry.key);
      if (channel == null || '$channel' != entry.key || entry.value is! int) {
        throw const FormatException('Invalid Fade duration override');
      }
      overrides[channel] = entry.value as int;
    }
    return FadeDurations(
      defaultMs: value['defaultMs'] as int,
      overrides: overrides,
    );
  }

  /// Declared setup for an absent local record.
  static const defaults = FadeDurations._(4000, {});

  /// Full-travel time inherited by tracks without an explicit override.
  final int defaultMs;

  /// Sparse explicit Custom choices, including choices equal to Default.
  final Map<int, int> overrides;

  /// Resolves setup for one physical track slot.
  int effectiveMs(int channel) {
    _validateChannel(channel);
    return overrides[channel] ?? defaultMs;
  }

  /// Complete single-record representation.
  Map<String, dynamic> toJson() => {
    'defaultMs': defaultMs,
    'overrides': {
      for (final entry in overrides.entries) '${entry.key}': entry.value,
    },
  };

  static void _validateDuration(int value) {
    if (value < 500 || value > 30000 || value % 500 != 0) {
      throw const FormatException('Fade duration must be 500–30000ms by 500ms');
    }
  }

  static void _validateChannel(int channel) {
    if (channel < 0 || channel > 7) {
      throw const FormatException('Fade track must be 0–7');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FadeDurations &&
      defaultMs == other.defaultMs &&
      mapEquals(overrides, other.overrides);

  @override
  int get hashCode => Object.hash(
    defaultMs,
    Object.hashAllUnordered(
      overrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
