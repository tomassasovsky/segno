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
Future<List<DawTrack>> writeDawProject(String dir) async {
  final project = DawManifestReader.read(dir);
  if (project != null) {
    await File('$dir/project.als').writeAsBytes(buildAls(project));
  }
  final chains = FxChainsWriter.render(dir);
  if (chains != null) {
    await File('$dir/fx-chains.txt').writeAsString(chains);
  }
  return project?.tracks ?? const [];
}
