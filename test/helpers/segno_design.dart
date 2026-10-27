import 'dart:io';

/// The tomassasovsky/segno-design clone, which sits next to the main
/// checkout at `../segno-design`.
///
/// In a linked worktree `.git` is a file naming the main repository's git
/// directory (`gitdir: <main>/.git/worktrees/<name>`), so the clone is found
/// next to the main checkout rather than next to the worktree.
Directory get segnoDesignDir {
  var checkout = Directory.current;
  final link = File('.git');
  if (link.existsSync()) {
    final gitDir = link.readAsStringSync().trim().replaceFirst('gitdir: ', '');
    checkout = Directory(gitDir).parent.parent.parent;
  }
  return Directory('${checkout.parent.path}/segno-design');
}
