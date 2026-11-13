import 'package:performance_repository/performance_repository.dart';
import 'package:segno/l10n/localized.dart' show storedDefaultTrackName;

/// What the player calls each track and hardware input, as a take's manifest
/// records them (#1799): [tracks] is `TracksCubit`'s list, where an unnamed
/// track holds its stored default, and [inputs] is `InputsCubit`'s map, which
/// holds only the names given. Unnamed entries are left out, so a reader
/// falls back to an ordinal of its own.
PerformanceNames performanceNames({
  required List<String> tracks,
  required Map<int, String> inputs,
}) => PerformanceNames(
  tracks: {
    for (var channel = 0; channel < tracks.length; channel++)
      if (tracks[channel] != storedDefaultTrackName(channel))
        channel: tracks[channel],
  },
  inputs: {
    for (final MapEntry(:key, :value) in inputs.entries)
      if (value.isNotEmpty) key: value,
  },
);
