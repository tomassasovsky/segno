import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:segno/xdg_documents_directory.dart';

/// Resolves the `sessions/` root under the app's documents folder — the parent
/// of every named-session bundle. Wired into the session repository by the
/// composition root so it can enumerate, save, rename, and delete named
/// sessions.
///
/// The legacy single `segno_session/` bundle (if a previous version wrote one)
/// is a sibling of this root, so it is never enumerated as a named session.
Future<String> defaultSessionsRoot() async =>
    '${await _documentsDirectory()}/sessions';

/// Resolves the `exports/` directory under the app's documents folder — where a
/// mixdown or per-track stems are written. A sibling of [defaultSessionsRoot],
/// so exported audio never appears in the session catalog.
Future<String> defaultExportDirectory() async =>
    '${await _documentsDirectory()}/exports';

/// The documents folder. On Linux it is read from the XDG user-dirs file
/// directly: `path_provider` would start `xdg-user-dir`, a fork of the app
/// (#1367).
Future<String> _documentsDirectory() async {
  if (Platform.isLinux) {
    return xdgDocumentsDirectory(Platform.environment, (path) {
      try {
        return File(path).readAsStringSync();
      } on FileSystemException {
        return null;
      }
    });
  }
  return (await getApplicationDocumentsDirectory()).path;
}
