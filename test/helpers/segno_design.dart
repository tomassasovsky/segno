import 'dart:io';

/// The tomassasovsky/segno-design clone, which sits next to the main
/// checkout at `../segno-design`.
///
/// In a linked worktree `.git` is a file naming the worktree's git directory,
/// and that directory's `commondir` names the main repository's `.git`, so
/// the clone is found next to the main checkout rather than next to the
/// worktree. Any other `.git` file (a submodule, a separate git dir) keeps
/// the current directory. Paths keep their `..` segments for the file system
/// to resolve.
Directory get segnoDesignDir {
  var checkout = Directory.current.path;
  final link = File('.git');
  if (link.existsSync()) {
    var gitDir = link.readAsStringSync().trim().replaceFirst('gitdir: ', '');
    if (!gitDir.startsWith('/')) gitDir = '$checkout/$gitDir';
    final common = File('$gitDir/commondir');
    if (common.existsSync()) {
      var commonDir = common.readAsStringSync().trim();
      if (!commonDir.startsWith('/')) commonDir = '$gitDir/$commonDir';
      checkout = '$commonDir/..';
    }
  }
  return Directory('$checkout/../segno-design');
}
