import 'dart:io';

/// The tomassasovsky/segno-design clone, which sits next to the main
/// checkout at `../segno-design`.
///
/// In a linked worktree `.git` is a file naming the main repository's git
/// directory (`gitdir: <main>/.git/worktrees/<name>`, absolute or relative to
/// the worktree), so the clone is found next to the main checkout rather than
/// next to the worktree. The path keeps its `..` segments for the file system
/// to resolve.
Directory get segnoDesignDir {
  var checkout = Directory.current.path;
  final link = File('.git');
  if (link.existsSync()) {
    final gitDir = link.readAsStringSync().trim().replaceFirst('gitdir: ', '');
    final absolute = gitDir.startsWith('/') ? gitDir : '$checkout/$gitDir';
    checkout = '$absolute/../../..';
  }
  return Directory('$checkout/../segno-design');
}
