/// The XDG documents directory, as `xdg-user-dir DOCUMENTS` prints it, read
/// without starting that program.
///
/// `path_provider`'s `getApplicationDocumentsDirectory` runs `xdg-user-dir`
/// on Linux through `Process.runSync`, which forks the app and stalls the
/// audio thread (#1367), and the app resolves this directory each time a
/// session, a capture, an export or a backing track needs its folder.
/// This follows the script itself: it sources
/// `${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs` when the file exists
/// and prints `${XDG_DOCUMENTS_DIR:-$HOME}`. The file's lines have the form
/// `XDG_DOCUMENTS_DIR="$HOME/yyy"` or `XDG_DOCUMENTS_DIR="/yyy"`; the XDG
/// user-dirs specification allows no other.
///
/// [readFile] returns a file's text, or `null` when there is none.
String xdgDocumentsDirectory(
  Map<String, String> environment,
  String? Function(String path) readFile,
) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME is not set, so there is no documents directory');
  }
  final configHome = environment['XDG_CONFIG_HOME'];
  final config = configHome == null || configHome.isEmpty
      ? '$home/.config'
      : configHome;
  var documents = environment['XDG_DOCUMENTS_DIR'];
  final entry = RegExp(r'^\s*XDG_DOCUMENTS_DIR="(.*)"\s*$');
  for (final line in (readFile('$config/user-dirs.dirs') ?? '').split('\n')) {
    final match = entry.firstMatch(line);
    if (match == null) continue;
    final value = match.group(1)!;
    documents = value == r'$HOME' || value.startsWith(r'$HOME/')
        ? '$home${value.substring(5)}'
        : value;
  }
  return documents == null || documents.isEmpty ? home : documents;
}
