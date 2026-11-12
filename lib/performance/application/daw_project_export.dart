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
/// Both files go through [write], the repository's durable replacement
/// (`PerformanceRepository.writeTakeFile`): a write cut short leaves the
/// previous file or none, and a take on a USB stick keeps the whole file
/// when the stick is pulled once this returns (#1801).
Future<List<DawTrack>> writeDawProject(
  String dir, {
  required TakeFileWriter write,
}) async {
  final project = DawManifestReader.read(dir);
  // Live cannot open a set with no tracks, so a take with nothing recorded
  // gets no project, and one an earlier version wrote for it is removed.
  if (project != null && project.tracks.isNotEmpty) {
    await write(dir, 'project.als', buildAls(project));
  } else if (project != null) {
    final stale = File('$dir/project.als');
    if (stale.existsSync()) await stale.delete();
  }
  final chains = FxChainsWriter.render(dir);
  if (chains != null) {
    await write(dir, 'fx-chains.txt', utf8.encode(chains));
  }
  return project?.tracks ?? const [];
}

/// Writes [bytes] as the file [name] of the take at [dir], durably.
typedef TakeFileWriter = Future<void> Function(
  String dir,
  String name,
  List<int> bytes,
);
