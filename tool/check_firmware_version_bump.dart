// Fails when a change to a board's firmware leaves the board's version where
// it was (#1969).
//
// The appliance's boot flashers flash a board only when the version it
// reports differs from the one in the image: segno-console-flash compares the
// console board's HELLO with the image's marker, and segno-ring-flash does the
// same with the ring carrier's update HELLO. A firmware change that keeps
// FW_MAJOR and FW_MINOR ships in the image and never reaches a board already
// on that version. #1967 changed the console board's pills and left it at
// 2.7, so build .289 kept the old firmware on the board.
//
// Checked: the files that differ between BASE and HEAD (committed trees, not
// the working tree) under each board's sources. The console board is built
// from firmware/console_board and firmware/libraries, the ring carrier from
// firmware/ring_board and firmware/libraries. When any of a board's files
// counts as changed, that board's FW_MAJOR.FW_MINOR in HEAD must be above the
// one in BASE.
//
// Not counted as a change: Markdown files, firmware/console_board/pi5-swd.cfg
// (the image ships the Yocto recipe's copy), and a C or C++ file (.c, .cpp,
// .h, .ino) whose code is the same in BASE and HEAD once comments are removed
// and the whitespace in each line is collapsed. Any other change counts,
// including a new, deleted or renamed file. A board that does not exist in
// BASE or HEAD is not checked.
//
// Usage: dart run tool/check_firmware_version_bump.dart [BASE]
// BASE defaults to HEAD^1. On a pull request CI passes HEAD^1, the merge
// commit's first parent (the target branch); on a push to master it passes
// the commit master was on before the push, so every commit of the push is
// covered. Run from the repository root.

import 'dart:io';

/// A board whose image the appliance flashes when the versions differ.
class Board {
  const new({
    required this.name,
    required this.versionFile,
    required this.sources,
    required this.flasher,
  });

  /// What the messages call the board.
  final String name;

  /// The sketch that declares `FW_MAJOR` and `FW_MINOR`.
  final String versionFile;

  /// Directories, ending in `/`, whose files the board's image is built from.
  final List<String> sources;

  /// The boot flasher that compares the versions.
  final String flasher;
}

/// The boards the appliance flashes at boot.
const boards = [
  Board(
    name: 'console board',
    versionFile: 'firmware/console_board/console_board.ino',
    sources: ['firmware/console_board/', 'firmware/libraries/'],
    flasher: 'segno-console-flash',
  ),
  Board(
    name: 'ring carrier',
    versionFile: 'firmware/ring_board/ring_board.ino',
    sources: ['firmware/ring_board/', 'firmware/libraries/'],
    flasher: 'segno-ring-flash',
  ),
];

/// Files under a board's sources that are not part of its image.
const _notInImage = {'firmware/console_board/pi5-swd.cfg'};

const _cFamily = {'.c', '.cpp', '.h', '.ino'};

/// A firmware version, `FW_MAJOR.FW_MINOR`.
class FirmwareVersion {
  const new(this.major, this.minor);

  final int major;
  final int minor;

  bool isAbove(FirmwareVersion other) =>
      major > other.major || (major == other.major && minor > other.minor);

  @override
  String toString() => '$major.$minor';
}

final _major = RegExp(r'\bFW_MAJOR\s*=\s*(\d+)\s*;');
final _minor = RegExp(r'\bFW_MINOR\s*=\s*(\d+)\s*;');

/// The version a sketch declares, or null when it declares none.
FirmwareVersion? versionOf(String sketch) {
  final code = codeOf(sketch);
  final major = _major.firstMatch(code);
  final minor = _minor.firstMatch(code);
  if (major == null || minor == null) return null;
  return FirmwareVersion(int.parse(major[1]!), int.parse(minor[1]!));
}

final _space = RegExp(r'\s+');

/// The code of a C or C++ source: comments removed, each line trimmed with
/// its whitespace collapsed to single spaces, and blank lines dropped.
/// String and character literals are kept as written, so a `//` inside one
/// is not taken for a comment.
String codeOf(String source) {
  final out = StringBuffer();
  final n = source.length;
  var i = 0;
  while (i < n) {
    final c = source[i];
    final next = i + 1 < n ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
    } else if (c == '/' && next == '*') {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
      out.write(' ');
    } else if (c == '"' || c == "'") {
      final start = i++;
      while (i < n && source[i] != c && source[i] != '\n') {
        if (source[i] == r'\') i++;
        i++;
      }
      i = i < n ? i + (source[i] == c ? 1 : 0) : n;
      out.write(source.substring(start, i));
    } else {
      out.write(c);
      i++;
    }
  }
  return out
      .toString()
      .split('\n')
      .map((line) => line.trim().replaceAll(_space, ' '))
      .where((line) => line.isNotEmpty)
      .join('\n');
}

/// A git command that failed, such as a diff against a commit a shallow
/// checkout does not have.
class GitException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

String _git(String repo, List<String> args) {
  final result = Process.runSync('git', ['-C', repo, ...args]);
  if (result.exitCode != 0) {
    throw GitException('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

/// The file at [path] in [commit], or null when it has none.
String? _show(String repo, String commit, String path) {
  final result = Process.runSync('git', ['-C', repo, 'show', '$commit:$path']);
  return result.exitCode == 0 ? result.stdout as String : null;
}

String _extension(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

/// Whether the difference in [path] between [base] and [head] changes an
/// image.
bool _changesImage(String repo, String base, String head, String path) {
  if (_extension(path) == '.md' || _notInImage.contains(path)) return false;
  if (!_cFamily.contains(_extension(path))) return true;
  final before = _show(repo, base, path);
  final after = _show(repo, head, path);
  if (before == null || after == null) return true;
  return codeOf(before) != codeOf(after);
}

/// The problems with the firmware versions between [base] and [head] in the
/// git repository at [repo], one message each; empty when every board whose
/// image changed has a higher version. Throws a [GitException] when git cannot
/// compare the two commits.
List<String> findUnbumped(String repo, String base, {String head = 'HEAD'}) {
  final changed = _git(repo, [
    'diff',
    '--name-only',
    '--no-renames',
    base,
    head,
    '--',
    'firmware',
  ]).split('\n').where((path) => path.isNotEmpty).toList();
  final problems = <String>[];
  for (final board in boards) {
    final touched = changed
        .where((path) => board.sources.any(path.startsWith))
        .where((path) => _changesImage(repo, base, head, path))
        .toList();
    if (touched.isEmpty) continue;
    final beforeSketch = _show(repo, base, board.versionFile);
    final afterSketch = _show(repo, head, board.versionFile);
    if (beforeSketch == null || afterSketch == null) continue;
    final before = versionOf(beforeSketch);
    final after = versionOf(afterSketch);
    final files = touched.map((path) => '  $path').join('\n');
    if (after == null) {
      problems.add(
        'The ${board.name} firmware declares no FW_MAJOR and FW_MINOR in '
        '${board.versionFile}.',
      );
    } else if (before != null && before.isAbove(after)) {
      problems.add(
        'The ${board.name} firmware changed, but its version went down from '
        '$before to $after (FW_MAJOR and FW_MINOR in ${board.versionFile}):'
        '\n$files\nRaise it above $before instead; the rule is in '
        'firmware/console_board/README.md, "Firmware versions".',
      );
    } else if (before != null && !after.isAbove(before)) {
      problems.add(
        'The ${board.name} firmware changed, but its version is still '
        '$before (FW_MAJOR and FW_MINOR in ${board.versionFile}):\n$files\n'
        '${board.flasher} flashes a board only when the version it reports '
        'differs from the image, so this change would never reach a board '
        'already on $before. Raise the version; the rule is in '
        'firmware/console_board/README.md, "Firmware versions".',
      );
    }
  }
  return problems;
}

void main(List<String> args) {
  final base = args.isEmpty ? 'HEAD^1' : args.first;
  final repo = Directory.current.path;
  final List<String> problems;
  try {
    _git(repo, ['rev-parse', '--verify', '--quiet', '$base^{commit}']);
    problems = findUnbumped(repo, base);
  } on GitException catch (error) {
    stderr.writeln(
      'error: cannot compare the firmware with $base (a shallow checkout '
      'needs fetch-depth: 2): ${error.message}',
    );
    exitCode = 2;
    return;
  }
  if (problems.isEmpty) {
    stdout.writeln(
      'Every board whose firmware changed since $base has a higher version.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln('error: $problem\n');
  }
  exitCode = 1;
}
