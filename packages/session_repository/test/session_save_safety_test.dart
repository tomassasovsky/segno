import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

/// A save over an existing bundle is written beside it and swapped in, so a
/// failure at any write leaves the previous save as it was (rule 2; Part 3
/// review, finding 1).
void main() {
  late Directory root;
  late FakeSessionEngine engine;

  setUp(() {
    root = Directory.systemTemp.createTempSync('segno_save_safety');
    engine = FakeSessionEngine();
  });
  tearDown(() {
    SessionRepository.debugOnSaveWrite = null;
    SessionRepository.debugOnDirectorySync = null;
    root.deleteSync(recursive: true);
  });

  SessionRepository repo() => SessionRepository(
    guards: GuardRegistry(),
    engine: engine,
    sessionsRoot: () async => root.path,
  );

  String bundle() => '${root.path}/s-a';

  Map<String, List<int>> snapshotOf(String path) => {
    for (final file in Directory(path).listSync().whereType<File>())
      file.uri.pathSegments.last: file.readAsBytesSync(),
  };

  List<String> rootEntries() =>
      root
          .listSync()
          .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
          .toList()
        ..sort();

  /// Saves a 4-frame take as `Old`, then arms an 8-frame take for the next
  /// save.
  Future<Map<String, List<int>>> savedOldThenEdited() async {
    engine.seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    await repo().save(
      bundle(),
      settings: const SessionSettings(),
      name: 'Old',
    );
    final before = snapshotOf(bundle());
    engine.seedTrack(0, Float32List.fromList([2, 2, 2, 2, 2, 2, 2, 2]));
    return before;
  }

  test(
    'a write-back failing at any write leaves the previous save whole',
    () async {
      final before = await savedOldThenEdited();
      // Count the writes of a whole save, then fail at each one in turn.
      final writes = <String>[];
      SessionRepository.debugOnSaveWrite = writes.add;
      final probe = Directory('${root.path}/probe');
      await repo().save(
        probe.path,
        settings: const SessionSettings(),
        name: 'Probe',
      );
      probe.deleteSync(recursive: true);
      // A new bundle has no swap; a write-back adds two steps, before the
      // swap and between its two renames.
      final steps = writes.length + 2;
      expect(steps, greaterThan(3));

      for (var failAt = 0; failAt < steps; failAt++) {
        var seen = 0;
        SessionRepository.debugOnSaveWrite = (_) {
          if (seen++ == failAt) throw const FileSystemException('disk full');
        };

        await expectLater(
          repo().save(bundle(), settings: const SessionSettings(), name: 'New'),
          throwsA(isA<FileSystemException>()),
          reason: 'fails at write $failAt',
        );

        expect(snapshotOf(bundle()), before, reason: 'write $failAt');
        expect(rootEntries(), ['s-a'], reason: 'nothing left beside it');
        final listed = (await repo().listSessions()).single;
        expect(listed.name, 'Old');
        final read = await repo().read(bundle());
        expect(read.laneStems[(0, 0)]!.single, hasLength(4));
      }
    },
  );

  test('a failed second rename puts the previous save back at once', () async {
    final before = await savedOldThenEdited();
    SessionRepository.debugOnSaveWrite = (path) {
      // Called with the stage just before it is renamed into place.
      if (path.endsWith('.saving')) {
        expect(Directory(bundle()).existsSync(), isFalse);
        expect(Directory('${bundle()}.old').existsSync(), isTrue);
        throw const FileSystemException('rename refused');
      }
    };

    await expectLater(
      repo().save(bundle(), settings: const SessionSettings(), name: 'New'),
      throwsA(isA<FileSystemException>()),
    );

    // Back before any catalog read runs recovery.
    expect(rootEntries(), ['s-a']);
    expect(snapshotOf(bundle()), before);
  });

  test('catalog reads on every turn of a write-back never break it', () async {
    for (var round = 0; round < 20; round++) {
      engine.seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      await repo().save(bundle(), settings: const SessionSettings(), name: 'A');
      engine.seedTrack(0, Float32List.fromList([2, 2, 2, 2, 2, 2, 2, 2]));
      var done = false;
      final save = repo()
          .save(bundle(), settings: const SessionSettings(), name: 'B')
          .whenComplete(() => done = true);
      while (!done) {
        await repo().listSessions();
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(save, completes, reason: 'round $round');
      expect((await repo().read(bundle())).session.name, 'B');
    }
  });

  test('a write-back that lands replaces the bundle whole', () async {
    await savedOldThenEdited();
    File('${bundle()}/notes.txt').writeAsStringSync('kept');

    await repo().save(bundle(), settings: const SessionSettings(), name: 'New');

    expect(rootEntries(), ['s-a']);
    final read = await repo().read(bundle());
    expect(read.session.name, 'New');
    expect(read.laneStems[(0, 0)]!.single, hasLength(8));
    // A file a save does not write itself is carried through.
    expect(File('${bundle()}/notes.txt').readAsStringSync(), 'kept');
  });

  test(
    'the swap is made durable before the previous save is retired',
    () async {
      await savedOldThenEdited();
      final seen = <String>[];
      SessionRepository.debugOnDirectorySync = (path) =>
          seen.add('$path: ${rootEntries().join(', ')}');

      await repo().save(
        bundle(),
        settings: const SessionSettings(),
        name: 'New',
      );

      // The fsync of the root ran with the new bundle in place and the
      // previous one still beside it: retiring it comes after.
      expect(seen, ['${root.path}: s-a, s-a.old']);
      expect(rootEntries(), ['s-a']);
    },
  );

  test('a catalog read during a write-back leaves its stage alone', () async {
    await savedOldThenEdited();
    Future<List<SessionSummary>>? listing;
    SessionRepository.debugOnSaveWrite = (_) {
      listing ??= repo().listSessions();
    };

    await repo().save(bundle(), settings: const SessionSettings(), name: 'New');
    final listed = await listing;

    expect((await repo().read(bundle())).session.name, 'New');
    // The stage is never listed as a session of its own.
    expect(listed!.map((s) => s.id), ['s-a']);
  });

  group('after a power cut', () {
    void manifestAt(String path, String name) {
      Directory(path).createSync(recursive: true);
      File('$path/${Session.manifestName}').writeAsStringSync(
        '{"version": ${Session.formatVersion}, "name": "$name", '
        '"sampleRate": 48000, "channels": 1, "baseLengthFrames": 0, '
        '"tracks": []}',
      );
    }

    test('mid-swap, the previous save is put back', () async {
      manifestAt('${root.path}/s-a.old', 'Old');
      manifestAt('${root.path}/s-a.saving', 'New');

      final listed = await repo().listSessions();

      expect(listed.single.id, 's-a');
      expect(listed.single.name, 'Old');
      expect(rootEntries(), ['s-a']);
    });

    test('after the swap, the retired save is removed', () async {
      manifestAt('${root.path}/s-a', 'New');
      manifestAt('${root.path}/s-a.old', 'Old');

      expect((await repo().listSessions()).single.name, 'New');
      expect(rootEntries(), ['s-a']);
    });

    test('a stage never swapped in is removed, in a folder too', () async {
      manifestAt('${root.path}/Gigs/s-b', 'Gig');
      manifestAt('${root.path}/Gigs/s-b.saving', 'Half');

      final listed = await repo().listSessions();

      expect(listed.single.name, 'Gig');
      expect(await repo().listFolders(), ['Gigs']);
      expect(Directory('${root.path}/Gigs/s-b.saving').existsSync(), isFalse);
    });
  });
}
