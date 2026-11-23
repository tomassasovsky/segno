import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/check_firmware_version_bump.dart';

const _console = 'firmware/console_board/console_board.ino';
const _ring = 'firmware/ring_board/ring_board.ino';
const _library = 'firmware/libraries/SegnoRing/src/ring_link.h';

String _sketch(int major, int minor, {String body = 'void loop() {}'}) =>
    '''
// The version: FW_MAJOR = 9 in a comment does not count.
static const uint8_t FW_MAJOR = $major;
// 1.1: something.
static const uint8_t FW_MINOR = $minor;

$body
''';

/// A git repository holding a base commit of both boards' firmware.
class _Repo {
  new(this.dir) {
    _git(['init', '--quiet']);
    _git(['config', 'user.email', 'test@example.com']);
    _git(['config', 'user.name', 'test']);
    _git(['config', 'commit.gpgsign', 'false']);
    write(_console, _sketch(2, 7));
    write('firmware/console_board/pedal_link.c', 'int a = 1;\n');
    write('firmware/console_board/README.md', '# Console\n');
    write('firmware/console_board/pi5-swd.cfg', 'adapter speed 1000\n');
    write(_ring, _sketch(1, 2));
    write('firmware/ring_board/seal.py', 'print(1)\n');
    write(_library, 'static const int LEVEL = 1;\n');
    write('firmware/test/test_pedal_link.c', 'int t;\n');
    commit();
  }

  final String dir;

  void _git(List<String> args) {
    final result = Process.runSync('git', ['-C', dir, ...args]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  void write(String path, String content) {
    File(p.join(dir, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void delete(String path) => File(p.join(dir, path)).deleteSync();

  void commit() {
    _git(['add', '-A']);
    _git(['commit', '--quiet', '--allow-empty', '-m', 'change']);
  }

  /// The problems with the last commit.
  List<String> problems() => findUnbumped(dir, 'HEAD^1');
}

void main() {
  late _Repo repo;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('fw_version_bump_');
    addTearDown(() => dir.deleteSync(recursive: true));
    repo = _Repo(dir.path);
  });

  group('findUnbumped', () {
    test('fails a console board change that keeps the version', () {
      repo
        ..write(_console, _sketch(2, 7, body: 'void loop() { show(); }'))
        ..commit();
      final problems = repo.problems();
      expect(problems, hasLength(1));
      expect(problems.single, contains('console board'));
      expect(problems.single, contains('is still 2.7'));
      expect(problems.single, contains('segno-console-flash'));
      expect(problems.single, contains(_console));
    });

    test('passes a console board change that raises the minor version', () {
      repo
        ..write(_console, _sketch(2, 8, body: 'void loop() { show(); }'))
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('passes a change that raises the major version', () {
      repo
        ..write('firmware/console_board/pedal_link.c', 'int a = 2;\n')
        ..write(_console, _sketch(3, 0))
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('fails a change to another file of the board that keeps the '
        'version', () {
      repo
        ..write('firmware/console_board/pedal_link.c', 'int a = 2;\n')
        ..commit();
      final problems = repo.problems();
      expect(problems, hasLength(1));
      expect(problems.single, contains('firmware/console_board/pedal_link.c'));
    });

    test('fails a new file in the board that keeps the version', () {
      repo
        ..write('firmware/console_board/pill.c', 'int b;\n')
        ..commit();
      expect(repo.problems().single, contains('pill.c'));
    });

    test('fails a deleted file in the board that keeps the version', () {
      repo
        ..delete('firmware/console_board/pedal_link.c')
        ..commit();
      expect(repo.problems().single, contains('pedal_link.c'));
    });

    test('fails a version that goes down', () {
      repo
        ..write(_console, _sketch(2, 6, body: 'void loop() { show(); }'))
        ..commit();
      expect(repo.problems().single, contains('went down from 2.7 to 2.6'));
    });

    test('fails a ring carrier change that keeps the version', () {
      repo
        ..write(_ring, _sketch(1, 2, body: 'void loop() { spin(); }'))
        ..commit();
      final problems = repo.problems();
      expect(problems.single, contains('ring carrier'));
      expect(problems.single, contains('segno-ring-flash'));
    });

    test('counts a change to a file that is not C or C++', () {
      repo
        ..write('firmware/ring_board/seal.py', '# only a comment\nprint(1)\n')
        ..commit();
      expect(repo.problems().single, contains('seal.py'));
    });

    test('fails a library change that raises only one board', () {
      repo
        ..write(_library, 'static const int LEVEL = 2;\n')
        ..write(_console, _sketch(2, 8))
        ..commit();
      final problems = repo.problems();
      expect(problems, hasLength(1));
      expect(problems.single, contains('ring carrier'));
      expect(problems.single, contains(_library));
    });

    test('passes a library change that raises both boards', () {
      repo
        ..write(_library, 'static const int LEVEL = 2;\n')
        ..write(_console, _sketch(2, 8))
        ..write(_ring, _sketch(1, 3))
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('passes a change to comments and whitespace only', () {
      repo
        ..write(
          _console,
          '/* A new header\n   comment. */\n'
          '${_sketch(2, 7, body: 'void   loop()  {}  // idle\n\n')}',
        )
        ..write(
          'firmware/console_board/pedal_link.c',
          '// Why a is 1.\n  int a = 1; /* one */\n',
        )
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('passes Markdown, pi5-swd.cfg and files outside the boards', () {
      repo
        ..write('firmware/console_board/README.md', '# Console board\n')
        ..write('firmware/console_board/pi5-swd.cfg', 'adapter speed 2000\n')
        ..write('firmware/test/test_pedal_link.c', 'int t = 1;\n')
        ..write('lib/main.dart', 'void main() {}\n')
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('fails a sketch that no longer declares its version', () {
      repo
        ..write(_console, 'void loop() {}\n')
        ..commit();
      expect(repo.problems().single, contains('declares no FW_MAJOR'));
    });

    test('skips a board that is new in the change', () {
      repo
        ..write('firmware/expander_board/expander_board.ino', 'int x;\n')
        ..commit();
      expect(repo.problems(), isEmpty);
    });

    test('throws when the base commit is missing', () {
      expect(
        () => findUnbumped(repo.dir, 'HEAD~5'),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('codeOf', () {
    test('removes line and block comments', () {
      expect(codeOf('int a; // a\n/* b\n c */ int b;\n'), 'int a;\nint b;');
    });

    test('keeps comment markers inside string and character literals', () {
      expect(
        codeOf('const char *u = "http://x/*y*/";\nchar s = \'/\';\n'),
        'const char *u = "http://x/*y*/";\nchar s = \'/\';',
      );
    });

    test('keeps escaped quotes inside a string', () {
      expect(codeOf(r'puts("a\"//b"); // c'), r'puts("a\"//b");');
    });

    test('collapses whitespace and drops blank lines', () {
      expect(
        codeOf('  int\t a  =  1;\n\n\n  int b;  \n'),
        'int a = 1;\nint b;',
      );
    });
  });

  group('versionOf', () {
    test('reads the declared version, not one in a comment', () {
      expect(versionOf(_sketch(2, 8)).toString(), '2.8');
    });

    test('is null for a sketch without a version', () {
      expect(versionOf('void loop() {}'), isNull);
    });
  });

  test('the repository sketches declare their versions', () {
    for (final board in boards) {
      final sketch = File(board.versionFile).readAsStringSync();
      expect(versionOf(sketch), isNotNull, reason: board.versionFile);
    }
  });
}
