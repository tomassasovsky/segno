import 'package:meta/meta.dart';

/// What the player calls each track and each hardware input when a take is
/// armed, so the take keeps its names after the rig is renamed and a DAW
/// export can label its tracks the way the console did (#1799).
///
/// Only names the player gave are listed: an unnamed track or input is
/// absent, and whoever reads the manifest falls back to an ordinal.
@immutable
class PerformanceNames {
  /// Creates a [PerformanceNames].
  const new({this.tracks = const {}, this.inputs = const {}});

  /// Track channel to the name the player gave it.
  final Map<int, String> tracks;

  /// Hardware input to the name the player gave it.
  final Map<int, String> inputs;
}
