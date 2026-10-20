import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

/// Back up to USB and Restore to Library (#1178 Part 8): what a backup
/// copies, how a drive's backups list, and the independent restored copy.
void main() {
  late Directory temp;
  late String root;
  late String drive;
  late GuardRegistry guards;
  late FakeSessionEngine engine;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_session_backup');
    root = '${temp.path}/sessions';
    drive = '${temp.path}/usb/Segno/Sessions';
    Directory(root).createSync();
    Directory(drive).createSync(recursive: true);
    guards = GuardRegistry();
    engine = FakeSessionEngine();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  SessionRepository repo() => SessionRepository(
    guards: guards,
    engine: engine,
    sessionsRoot: () async => root,
    now: () => DateTime(2026, 10, 6, 12),
  );

  /// A bundle at [parent]/[id] named [name], with [files] beside its
  /// manifest.
  Directory bundle(
    String parent,
    String id, {
    String? name,
    Map<String, List<int>> files = const {},
    DateTime? savedAt,
  }) {
    final dir = Directory('$parent/$id')..createSync(recursive: true);
    for (final entry in files.entries) {
      File('${dir.path}/${entry.key}')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    final manifest = File('${dir.path}/${Session.manifestName}')
      ..writeAsStringSync(
        jsonEncode({
          'version': Session.formatVersion,
          'name': ?name,
          'sampleRate': 48000,
          'channels': 1,
          'baseLengthFrames': 0,
          'tracks': [
            {'channel': 0},
          ],
        }),
      );
    if (savedAt != null) manifest.setLastModifiedSync(savedAt);
    return dir;
  }

  Map<String, List<int>> contents(Directory dir) => {
    for (final e in dir.listSync(recursive: true))
      if (e is File) e.path.substring(dir.path.length + 1): e.readAsBytesSync(),
  };

  group('bundleFiles', () {
    test('lists every file of the bundle, nested ones too, the manifest last '
        'and a manifest still being written left out', () async {
      bundle(
        root,
        's-a',
        files: {
          'track0_lane0_L0.wav': [1],
          'mixdown.wav': [2],
          'notes.txt': [3],
          'session.v7/session.json': [4],
          '${Session.manifestName}.tmp': [5],
        },
      );

      expect(await repo().bundleFiles('s-a'), [
        'mixdown.wav',
        'notes.txt',
        'session.v7/session.json',
        'track0_lane0_L0.wav',
        Session.manifestName,
      ]);
    });

    test('finds a bundle in a folder, and refuses a missing one', () async {
      bundle('$root/Gigs', 's-b');
      expect(await repo().bundleFiles('s-b'), [Session.manifestName]);
      await expectLater(repo().bundleFiles('s-x'), throwsStateError);
    });
  });

  group('listBackups', () {
    test("lists a drive's backups newest first, leniently, leaving out "
        'copies being assembled and loose directories', () {
      bundle(drive, 's-old', name: 'Old', savedAt: DateTime(2026, 9));
      bundle(drive, 's-new', name: 'New', savedAt: DateTime(2026, 10));
      bundle(drive, '.segno-export', name: 'Half');
      Directory('$drive/empty').createSync();
      Directory('$drive/s-broken').createSync();
      File('$drive/s-broken/${Session.manifestName}')
        ..writeAsStringSync('{')
        ..setLastModifiedSync(DateTime(2026, 8));

      final list = repo().listBackups(drive);

      expect(list.map((s) => s.id), ['s-new', 's-old', 's-broken']);
      expect(list.first.name, 'New');
      expect(list.first.trackCount, 1);
      expect(list.last.unreadable, isTrue);
    });

    test('lists nothing for a missing root', () {
      expect(repo().listBackups('${temp.path}/nowhere'), isEmpty);
    });
  });

  group('restoreFrom', () {
    test('adds an independent copy under a fresh id, byte for byte but for '
        'the name, and leaves every other bundle alone', () async {
      final current = bundle(root, 's-cur', name: 'Current');
      final before = contents(current);
      final backup = bundle(
        drive,
        's-20260901-100000',
        name: 'Evening loop',
        files: {
          'track0_lane0_L0.wav': [1, 2, 3],
          'mixdown.wav': [4],
          'session.v7/session.json': [5],
        },
      );
      final backupBefore = contents(backup);
      final r = repo();

      final id = await r.restoreFrom(backup.path);

      expect(id, 's-20261006-120000');
      final restored = Directory('$root/$id');
      final copy = contents(restored);
      expect(copy['track0_lane0_L0.wav'], [1, 2, 3]);
      expect(copy['mixdown.wav'], [4]);
      expect(copy['session.v7/session.json'], [5]);
      final manifest =
          jsonDecode(
                File(
                  '${restored.path}/${Session.manifestName}',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(manifest['name'], 'Evening loop');
      expect(manifest['tracks'], [
        {'channel': 0},
      ]);
      expect(contents(current), before);
      expect(contents(backup), backupBefore);
      expect(guards.active, isEmpty);
      expect(
        (await r.listSessions()).map((s) => s.name),
        containsAll(['Current', 'Evening loop']),
      );
    });

    test('suffixes a name the catalog already carries', () async {
      bundle(root, 's-a', name: 'Evening loop');
      bundle(root, 's-b', name: 'Evening loop (2)');
      final backup = bundle(drive, 's-x', name: 'Evening loop');
      final r = repo();

      final id = await r.restoreFrom(backup.path);

      final restored = (await r.listSessions()).firstWhere((s) => s.id == id);
      expect(restored.name, 'Evening loop (3)');
    });

    test(
      'a backup without a manifest is refused, and nothing is reserved',
      () async {
        Directory('$drive/loose').createSync();

        await expectLater(
          repo().restoreFrom('$drive/loose'),
          throwsArgumentError,
        );
        expect(Directory(root).listSync(), isEmpty);
      },
    );

    test('a failed copy leaves no trace in the catalog', () async {
      final backup = bundle(
        drive,
        's-x',
        name: 'Evening loop',
        files: {
          'track0_lane0_L0.wav': [1],
        },
      );
      SessionRepository.debugOnDuplicateWrite = (path) {
        if (path.endsWith('track0_lane0_L0.wav')) {
          throw const FileSystemException('disk full');
        }
      };
      addTearDown(() => SessionRepository.debugOnDuplicateWrite = null);

      await expectLater(
        repo().restoreFrom(backup.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(root).listSync(), isEmpty);
      expect(guards.active, isEmpty);
    });

    test('is refused during a shutdown, adding nothing', () async {
      final backup = bundle(drive, 's-x', name: 'Evening loop');
      final restart = guards.enter(
        GuardKind.restart,
        const GuardScope.internal(),
        purpose: 'restart',
      );
      addTearDown(restart.release);

      await expectLater(
        repo().restoreFrom(backup.path),
        throwsA(isA<GuardRefused>()),
      );
      expect(Directory(root).listSync(), isEmpty);
    });
  });
}
