import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';

/// Writes a finished recording's DAW project into its bundle at [dir]:
/// `project.als` (the Ableton Live Set over the rendered stems) and
/// `fx-chains.txt`, both read from the bundle's own `performance.json`. No
/// engine, no render and no audio writes.
///
/// The one writer of these files (plan D13, #1178 Part 7): the capture
/// pipeline calls it when a take's render finishes, and the Library's
/// `DAW project` action and the DAW package export call it for a finished
/// take. Returns the Live Set's tracks (empty when the manifest does not
/// read). Throws what the write throws, so each caller decides what a
/// failure means: a full volume must not take a finished take's completion
/// down with it, while the Library reports it.
///
/// The tempo comes from the manifest (#281): the capture's own disarm-time
/// tempo (arm-time for a crash salvage), or 120 BPM for a bundle with none.
///
/// The set reads the take's stems through their index (#1824). A take with
/// no index (its render failed, or it was rendered before the lanes had
/// stems of their own) would get a set with no stems, so when the bundle
/// already holds a project this throws [StemsNotRendered] and leaves that
/// project as it is: the caller renders the stems first.
Future<List<DawTrack>> writeDawProject(String dir) async {
  if (!File('$dir/stems/stems.json').existsSync() &&
      File('$dir/project.als').existsSync()) {
    throw StemsNotRendered(dir);
  }
  final project = DawManifestReader.read(dir);
  // Live cannot open a set with no tracks, so a take with nothing recorded
  // gets no project, and one an earlier version wrote for it is removed.
  if (project != null && project.tracks.isNotEmpty) {
    await _replace('$dir/project.als', buildAls(project));
  } else if (project != null) {
    final stale = File('$dir/project.als');
    if (stale.existsSync()) await stale.delete();
  }
  final chains = FxChainsWriter.render(dir);
  if (chains != null) {
    await _replace('$dir/fx-chains.txt', utf8.encode(chains));
  }
  return project?.tracks ?? const [];
}

/// Writes [bytes] to [path] through a flushed temp file and a rename, so a
/// write cut short (a full disk) leaves the previous file or none, never a
/// truncated one that would read as a finished project.
Future<void> _replace(String path, List<int> bytes) async {
  final temp = File('$path.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(path);
  } on Object {
    if (temp.existsSync()) temp.deleteSync();
    rethrow;
  }
}

/// The take in [dir] has no rendered stems, so [writeDawProject] did not
/// replace its project with one that has none.
class StemsNotRendered implements Exception {
  /// Creates a [StemsNotRendered] for the take in [dir].
  const new(this.dir);

  /// The take's directory.
  final String dir;

  @override
  String toString() => 'StemsNotRendered: $dir has no stems/stems.json';
}
