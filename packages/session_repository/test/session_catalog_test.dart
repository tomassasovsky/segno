import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

void main() {
  late Directory root;
  var clock = DateTime(2026, 10, 6, 12);

  setUp(() {
    root = Directory.systemTemp.createTempSync('segno_sessions_root');
    clock = DateTime(2026, 10, 6, 12);
  });
  tearDown(() => root.deleteSync(recursive: true));

  SessionRepository repo({bool withRoot = true, AudioEngine? engine}) =>
      SessionRepository(
        guards: GuardRegistry(),
        engine: engine ?? FakeSessionEngine(),
        sessionsRoot: withRoot ? () async => root.path : null,
        now: () => clock,
      );

  /// A chain envelope with [n] entries, the shape the manifest stores.
  String chain(int n) => jsonEncode({
    'chainEnabled': true,
    'entries': [
      for (var i = 0; i < n; i++) {'type': 3, 'params': <double>[]},
    ],
  });

  /// Writes a bundle directory [id] (under [folder] when given) with a
  /// manifest at schema [version]; [name] and [extra] are merged in.
  Directory makeBundle(
    String id, {
    String? folder,
    String? name,
    int version = Session.formatVersion,
    Map<String, Object?> extra = const {},
    DateTime? modifiedAt,
  }) {
    final parent = folder == null ? root.path : '${root.path}/$folder';
    final dir = Directory('$parent/$id')..createSync(recursive: true);
    final manifest = File('${dir.path}/${Session.manifestName}')
      ..writeAsStringSync(
        jsonEncode({
          'version': version,
          'name': ?name,
          'sampleRate': 48000,
          'channels': 1,
          'baseLengthFrames': 0,
          'tracks': <Object>[],
          ...extra,
        }),
      );
    if (modifiedAt != null) manifest.setLastModifiedSync(modifiedAt);
    return dir;
  }

  group('listSessions', () {
    test(
      'lists every bundle at the root and one folder down, skipping folders '
      'and interrupted saves',
      () async {
        makeBundle('s-a');
        makeBundle('s-b', folder: 'Gigs');
        Directory('${root.path}/Empty folder').createSync();
        // A save that never reached its manifest: layer WAVs, no manifest.
        // It is not a folder either, so a bundle nested in it is not filed.
        Directory('${root.path}/s-interrupted').createSync();
        File('${root.path}/s-interrupted/track0_lane0_L0.wav').createSync();
        makeBundle('s-nested', folder: 's-interrupted');
        // A second level is ignored.
        makeBundle('s-deep', folder: 'Gigs/Nested');
        File('${root.path}/stray.txt').createSync();

        final sessions = await repo().listSessions();

        expect(sessions.map((s) => s.id), unorderedEquals(['s-a', 's-b']));
        expect(sessions.singleWhere((s) => s.id == 's-a').folder, isNull);
        expect(sessions.singleWhere((s) => s.id == 's-b').folder, 'Gigs');
      },
    );

    test('a legacy bundle lists under its directory name', () async {
      makeBundle('Evening loop');

      final summary = (await repo().listSessions()).single;

      expect(summary.id, 'Evening loop');
      expect(summary.name, 'Evening loop');
      expect(summary.unreadable, isFalse);
    });

    test('a bundle with a manifest name lists under that name', () async {
      makeBundle('s-20261006-120000', name: 'Night loop');

      final summary = (await repo().listSessions()).single;

      expect(summary.id, 's-20261006-120000');
      expect(summary.name, 'Night loop');
    });

    test('a blank manifest name falls back to the id', () async {
      makeBundle('s-blank', name: '   ');
      expect((await repo().listSessions()).single.name, 's-blank');
    });

    test('carries tempo, signature, track and FX counts without a full '
        'decode', () async {
      makeBundle(
        's-facts',
        extra: {
          'tempoBpm': 84,
          'tsNum': 3,
          'tsDen': 4,
          'tracks': [
            {'channel': 0},
            {'channel': 2},
          ],
          'laneChains': [
            {'channel': 0, 'lane': 0, 'encoded': chain(3)},
          ],
          'monitors': [
            {'input': 0, 'encoded': chain(2)},
          ],
          'trackChains': [
            {'channel': 0, 'encoded': chain(1)},
          ],
          'outputChains': [
            {
              'bus': 0,
              'encoded': jsonEncode([1, 2, 3, 4]),
            },
          ],
          'allTracksChain': chain(5),
        },
      );

      final summary = (await repo().listSessions()).single;

      expect(summary.tempoBpm, 84);
      expect(summary.tsNum, 3);
      expect(summary.tsDen, 4);
      expect(summary.trackCount, 2);
      expect(summary.populatedChannels, [0, 2]);
      expect(summary.fxCount, 3 + 2 + 1 + 4 + 5);
    });

    test('reads populated channels leniently', () async {
      makeBundle(
        's-odd',
        extra: {
          'tracks': [
            'junk',
            {'channel': 'one'},
            {'channel': 5},
          ],
        },
      );
      makeBundle('s-none', extra: {'tracks': 'not a list'});

      final sessions = await repo().listSessions();

      expect(sessions.singleWhere((s) => s.id == 's-odd').populatedChannels, [
        5,
      ]);
      expect(
        sessions.singleWhere((s) => s.id == 's-none').populatedChannels,
        isEmpty,
      );
    });

    test(
      'a bundle whose manifest does not decode still lists, unreadable',
      () async {
        Directory('${root.path}/s-bad').createSync();
        File(
          '${root.path}/s-bad/${Session.manifestName}',
        ).writeAsStringSync('{not json');
        makeBundle('s-future', version: 999);

        final sessions = await repo().listSessions();

        final bad = sessions.singleWhere((s) => s.id == 's-bad');
        expect(bad.unreadable, isTrue);
        expect(bad.name, 's-bad');
        // A newer schema still decodes as JSON: listed, readable as a row,
        // refused only on preview/open.
        final future = sessions.singleWhere((s) => s.id == 's-future');
        expect(future.unreadable, isFalse);
      },
    );

    test('sorts newest save first, unknown dates last, then by name', () async {
      final now = DateTime(2026, 10, 6, 12);
      makeBundle(
        's-old',
        name: 'zebra',
        modifiedAt: now.subtract(
          const Duration(days: 2),
        ),
      );
      makeBundle('s-new', name: 'apple', modifiedAt: now);
      makeBundle(
        's-mid',
        name: 'Mango',
        modifiedAt: now.subtract(
          const Duration(days: 1),
        ),
      );

      final names = (await repo().listSessions()).map((s) => s.name).toList();

      expect(names, ['apple', 'Mango', 'zebra']);
    });

    test('is empty when the root does not exist yet', () async {
      final missing = SessionRepository(
        guards: GuardRegistry(),
        engine: FakeSessionEngine(),
        sessionsRoot: () async => '${root.path}/never-created',
      );
      expect(await missing.listSessions(), isEmpty);
    });
  });

  group('listFolders', () {
    test(
      'lists folders only, sorted, never bundles or interrupted saves',
      () async {
        Directory('${root.path}/Studio').createSync();
        Directory('${root.path}/gigs').createSync();
        makeBundle('s-a');
        Directory('${root.path}/s-interrupted').createSync();
        File(
          '${root.path}/s-interrupted/${SessionRepository.mixdownName}',
        ).createSync();

        expect(await repo().listFolders(), ['gigs', 'Studio']);
      },
    );

    test('is empty when the root does not exist yet', () async {
      final missing = SessionRepository(
        guards: GuardRegistry(),
        engine: FakeSessionEngine(),
        sessionsRoot: () async => '${root.path}/never-created',
      );
      expect(await missing.listFolders(), isEmpty);
    });
  });

  group('createFolder and deleteFolder', () {
    test('creates a folder directory under the root', () async {
      await repo().createFolder('Gigs 2026');
      expect(Directory('${root.path}/Gigs 2026').existsSync(), isTrue);
      expect(await repo().listFolders(), ['Gigs 2026']);
    });

    test('refuses a name a folder or bundle already has', () async {
      await repo().createFolder('Taken');
      makeBundle('Bundle');
      await expectLater(
        repo().createFolder('Taken!'), // folds to Taken
        throwsA(isA<SessionNameCollision>()),
      );
      await expectLater(
        repo().createFolder('Bundle'),
        throwsA(isA<SessionNameCollision>()),
      );
    });

    test('refuses a folder name shaped like a session id', () async {
      await expectLater(
        repo().createFolder('s-20261006-120000'),
        throwsArgumentError,
      );
      expect(Directory('${root.path}/s-20261006-120000').existsSync(), isFalse);
    });

    test('refuses an invalid folder name', () async {
      await expectLater(repo().createFolder('  '), throwsArgumentError);
    });

    test('deletes an empty folder and refuses a non-empty one', () async {
      await repo().createFolder('Empty');
      makeBundle('s-a', folder: 'Full');

      await repo().deleteFolder('Empty');
      expect(Directory('${root.path}/Empty').existsSync(), isFalse);

      await expectLater(
        repo().deleteFolder('Full'),
        throwsA(isA<SessionFolderNotEmpty>()),
      );
      expect(Directory('${root.path}/Full/s-a').existsSync(), isTrue);
    });

    test(
      'refuses a folder holding an interrupted save, and keeps it',
      () async {
        await repo().createFolder('Gigs');
        final interrupted = File('${root.path}/Gigs/s-x/track0_lane0_L0.wav')
          ..createSync(recursive: true);

        await expectLater(
          repo().deleteFolder('Gigs'),
          throwsA(isA<SessionFolderNotEmpty>()),
        );
        expect(interrupted.existsSync(), isTrue);
      },
    );

    test('refuses a folder holding any non-empty directory, and deletes one '
        'holding only empty directories', () async {
      await repo().createFolder('Held');
      final kept = File('${root.path}/Held/notes/readme.txt')
        ..createSync(recursive: true);
      await repo().createFolder('Hollow');
      Directory('${root.path}/Hollow/empty').createSync();

      await expectLater(
        repo().deleteFolder('Held'),
        throwsA(isA<SessionFolderNotEmpty>()),
      );
      expect(kept.existsSync(), isTrue);
      await repo().deleteFolder('Hollow');
      expect(Directory('${root.path}/Hollow').existsSync(), isFalse);
    });

    test('deleting a missing folder or a bundle is a no-op', () async {
      makeBundle('s-a');
      await expectLater(repo().deleteFolder('Ghost'), completes);
      await expectLater(repo().deleteFolder('s-a'), completes);
      expect(Directory('${root.path}/s-a').existsSync(), isTrue);
    });
  });

  group('renameFolder', () {
    test(
      'renames the folder; its sessions move with it and keep their ids',
      () async {
        makeBundle('s-a', folder: 'Gigs', name: 'Set');

        await repo().renameFolder('Gigs', 'Shows');

        expect(await repo().listFolders(), ['Shows']);
        final listed = (await repo().listSessions()).single;
        expect(listed.id, 's-a');
        expect(listed.folder, 'Shows');
        expect(await repo().bundlePathOf('s-a'), '${root.path}/Shows/s-a');
      },
    );

    test(
      'refuses a taken name, an id-shaped name and a missing folder',
      () async {
        await repo().createFolder('Gigs');
        await repo().createFolder('Shows');
        makeBundle('s-b');

        await expectLater(
          repo().renameFolder('Gigs', 'Shows'),
          throwsA(isA<SessionNameCollision>()),
        );
        await expectLater(
          repo().renameFolder('Gigs', 's-b'),
          throwsA(isA<SessionNameCollision>()),
        );
        await expectLater(
          repo().renameFolder('Gigs', 's-20261006-120000'),
          throwsArgumentError,
        );
        await expectLater(
          repo().renameFolder('Ghost', 'X'),
          throwsArgumentError,
        );
        expect(await repo().listFolders(), ['Gigs', 'Shows']);
      },
    );

    test('renaming a folder to its own name is a no-op', () async {
      await repo().createFolder('Gigs');
      await expectLater(repo().renameFolder('Gigs', 'Gigs'), completes);
      expect(await repo().listFolders(), ['Gigs']);
    });
  });

  group('moveSession', () {
    test('moves a bundle into a folder and back to Unfiled', () async {
      makeBundle('s-a');
      await repo().createFolder('Gigs');

      await repo().moveSession('s-a', folder: 'Gigs');
      expect(Directory('${root.path}/Gigs/s-a').existsSync(), isTrue);
      expect(Directory('${root.path}/s-a').existsSync(), isFalse);
      expect((await repo().listSessions()).single.folder, 'Gigs');

      await repo().moveSession('s-a');
      expect(Directory('${root.path}/s-a').existsSync(), isTrue);
      expect((await repo().listSessions()).single.folder, isNull);
    });

    test('refuses a folder that does not exist', () async {
      makeBundle('s-a');
      await expectLater(
        repo().moveSession('s-a', folder: 'Nowhere'),
        throwsArgumentError,
      );
      expect(Directory('${root.path}/s-a').existsSync(), isTrue);
    });

    test('a move to the same place or of a missing id is a no-op', () async {
      makeBundle('s-a');
      await expectLater(repo().moveSession('s-a'), completes);
      await expectLater(repo().moveSession('ghost'), completes);
      expect(Directory('${root.path}/s-a').existsSync(), isTrue);
    });
  });

  group('bundlePathOf', () {
    test('resolves an existing bundle wherever it sits', () async {
      makeBundle('s-a');
      makeBundle('s-b', folder: 'Gigs');
      expect(await repo().bundlePathOf('s-a'), '${root.path}/s-a');
      expect(await repo().bundlePathOf('s-b'), '${root.path}/Gigs/s-b');
    });

    test('resolves a new id to the root (Unfiled)', () async {
      expect(await repo().bundlePathOf('s-new'), '${root.path}/s-new');
    });

    test('refuses an id that is not a directory name', () async {
      await expectLater(repo().bundlePathOf(''), throwsArgumentError);
      await expectLater(repo().bundlePathOf('../x'), throwsArgumentError);
      await expectLater(repo().bundlePathOf('a/b'), throwsArgumentError);
    });
  });

  group('newSessionId', () {
    test('stamps the clock and suffixes a same-second collision', () async {
      expect(await repo().newSessionId(), 's-20261006-120000');
      makeBundle('s-20261006-120000');
      expect(await repo().newSessionId(), 's-20261006-120000-2');
      makeBundle('s-20261006-120000-3', folder: 'Gigs');
      expect(await repo().newSessionId(), 's-20261006-120000-4');
      clock = DateTime(2026, 10, 6, 12, 0, 1);
      expect(await repo().newSessionId(), 's-20261006-120001');
    });

    test('reserves the id by creating its directory at the root', () async {
      final id = await repo().newSessionId();

      expect(Directory('${root.path}/$id').existsSync(), isTrue);
      expect(Directory('${root.path}/$id').listSync(), isEmpty);
      // Two ids issued in the same second before either is written (a Save
      // as and a Duplicate) never share a directory.
      expect(await repo().newSessionId(), isNot(id));
    });

    test('treats a folder or an interrupted save named like an id as '
        'taken', () async {
      makeBundle('s-gig', folder: 's-20261006-120000');
      Directory('${root.path}/Gigs/s-20261006-120000-2').createSync(
        recursive: true,
      );
      File(
        '${root.path}/Gigs/s-20261006-120000-2/track0_lane0_L0.wav',
      ).createSync();

      final id = await repo().newSessionId();

      expect(id, 's-20261006-120000-3');
      expect(
        await repo().bundlePathOf(id),
        '${root.path}/s-20261006-120000-3',
      );
      expect((await repo().listSessions()).single.id, 's-gig');
    });

    test(
      'a duplicate in the same second as a Save as takes its own id',
      () async {
        await repo().createFolder('Gigs');
        makeBundle('s-a', folder: 'Gigs', name: 'Source');
        final saveAsId = await repo().newSessionId();

        final copyId = await repo().duplicateSession('s-a', 'Copy');

        expect(copyId, isNot(saveAsId));
        expect(Directory('${root.path}/$saveAsId').listSync(), isEmpty);
        expect(
          File(
            '${root.path}/Gigs/$copyId/${Session.manifestName}',
          ).existsSync(),
          isTrue,
        );
      },
    );
  });

  group('reservations', () {
    test('a reservation in flight is no folder', () async {
      await repo().newSessionId();

      expect(await repo().listFolders(), isEmpty);
    });

    test('an empty reservation a crash left behind is no folder, and a '
        'folder named like an id that holds something still is', () async {
      Directory('${root.path}/s-20261006-115959').createSync();
      Directory('${root.path}/s-20261006-115959-2').createSync();
      makeBundle('s-gig', folder: 's-20261006-110000');

      expect(await repo().listFolders(), ['s-20261006-110000']);
      expect((await repo().listSessions()).single.folder, 's-20261006-110000');
    });

    test('a leftover reservation is still taken for new ids', () async {
      Directory('${root.path}/s-20261006-120000').createSync();

      expect(await repo().newSessionId(), 's-20261006-120000-2');
    });
  });

  group('releaseSessionId', () {
    test('removes a reservation that nothing was written into', () async {
      final id = await repo().newSessionId();

      await repo().releaseSessionId(id);

      expect(Directory('${root.path}/$id').existsSync(), isFalse);
      expect(await repo().listFolders(), isEmpty);
    });

    test('keeps a directory a save wrote into', () async {
      final id = await repo().newSessionId();
      File('${root.path}/$id/track0_lane0_L0.wav').createSync();

      await repo().releaseSessionId(id);
      await repo().releaseSessionId('s-ghost');

      expect(
        File('${root.path}/$id/track0_lane0_L0.wav').existsSync(),
        isTrue,
      );
    });
  });

  group('nextAutomaticName', () {
    test('returns the smallest unused number, case-insensitively', () async {
      makeBundle('s-1', name: 'New loop 1');
      makeBundle('s-3', name: 'new loop 3');
      expect(await repo().nextAutomaticName('New loop'), 'New loop 2');
      makeBundle('s-2', name: 'New Loop 2');
      expect(await repo().nextAutomaticName('New loop'), 'New loop 4');
    });

    test('starts at 1 on an empty catalog', () async {
      expect(await repo().nextAutomaticName('New loop'), 'New loop 1');
    });
  });

  group('renameSession', () {
    test(
      'rewrites only the manifest name; every WAV is byte-identical',
      () async {
        final engine = FakeSessionEngine()
          ..seedLayers(
            0,
            [
              Float32List.fromList([1, 1, 1, 1]),
              Float32List.fromList([2, 2, 2, 2]),
            ],
            undoDepth: 1,
          );
        final dir = await repo().bundlePathOf('s-a');
        await repo(engine: engine).save(
          dir,
          settings: const SessionSettings(),
          name: 'Old name',
        );
        final before = {
          for (final f in Directory(dir).listSync().whereType<File>())
            f.path: f.readAsBytesSync(),
        };

        await repo().renameSession('s-a', 'New name');

        expect(Directory(dir).existsSync(), isTrue, reason: 'identity kept');
        for (final entry in before.entries) {
          if (entry.key.endsWith(Session.manifestName)) continue;
          expect(File(entry.key).readAsBytesSync(), entry.value);
        }
        final json =
            jsonDecode(
                  File('$dir/${Session.manifestName}').readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(json['name'], 'New name');
        expect(json['version'], Session.formatVersion);
        expect((await repo().listSessions()).single.name, 'New name');
        // The renamed bundle still loads.
        final bundle = await repo().read(dir);
        expect(bundle.session.name, 'New name');
        expect(bundle.laneStems[(0, 0)], hasLength(2));
      },
    );

    test('names a legacy bundle without moving it', () async {
      makeBundle('Evening loop');
      await repo().renameSession('Evening loop', 'Night loop');
      expect(Directory('${root.path}/Evening loop').existsSync(), isTrue);
      final summary = (await repo().listSessions()).single;
      expect(summary.id, 'Evening loop');
      expect(summary.name, 'Night loop');
    });

    test(
      'throws SessionNameCollision when another session has the name',
      () async {
        makeBundle('s-a', name: 'Keep');
        makeBundle('s-b', name: 'Clash');
        await expectLater(
          repo().renameSession('s-a', 'Clash!'), // folds to Clash
          throwsA(
            isA<SessionNameCollision>().having((e) => e.slug, 'slug', 'Clash'),
          ),
        );
        expect(
          (await repo().listSessions()).map((s) => s.name),
          unorderedEquals(['Keep', 'Clash']),
        );
      },
    );

    test('a name differing only by case is not a collision, as on the '
        'case-sensitive appliance', () async {
      makeBundle('s-a', name: 'Keep');
      makeBundle('s-b', name: 'Song');

      await repo().renameSession('s-a', 'song');

      expect(
        (await repo().listSessions()).map((s) => s.name),
        unorderedEquals(['song', 'Song']),
      );
    });

    test(
      'replaces the manifest by rename, never rewriting it in place',
      () async {
        makeBundle('s-a', name: 'Old');
        final manifest = '${root.path}/s-a/${Session.manifestName}';
        final before = File(manifest).readAsBytesSync();
        // A hard link shares the file's data: an in-place write shows through
        // it, a new file renamed over the path does not.
        final linked = '${root.path}/manifest-link';
        expect(Process.runSync('ln', [manifest, linked]).exitCode, 0);

        await repo().renameSession('s-a', 'New');

        expect(File(linked).readAsBytesSync(), before);
        expect((await repo().listSessions()).single.name, 'New');
        expect(File('$manifest.tmp').existsSync(), isFalse);
      },
      skip: Platform.isWindows ? 'needs ln' : null,
    );

    test('a failed manifest write leaves the old manifest intact', () async {
      makeBundle('s-a', name: 'Old');
      final manifest = File('${root.path}/s-a/${Session.manifestName}');
      final before = manifest.readAsBytesSync();
      // A directory where the temp file goes makes the write fail.
      Directory('${manifest.path}.tmp/blocker').createSync(recursive: true);

      await expectLater(
        repo().renameSession('s-a', 'New'),
        throwsA(isA<FileSystemException>()),
      );

      expect(manifest.readAsBytesSync(), before);
    });

    test('renaming to its own name, or a missing id, is a no-op', () async {
      makeBundle('s-a', name: 'Same');
      final manifest = File('${root.path}/s-a/${Session.manifestName}');
      final before = manifest.readAsBytesSync();
      await repo().renameSession('s-a', 'Same');
      expect(manifest.readAsBytesSync(), before);
      await expectLater(repo().renameSession('ghost', 'X'), completes);
    });

    test('throws ArgumentError for an invalid name or id', () async {
      makeBundle('s-a');
      await expectLater(repo().renameSession('s-a', '  '), throwsArgumentError);
      await expectLater(
        repo().renameSession('../s-a', 'X'),
        throwsArgumentError,
      );
    });
  });

  group('duplicateSession', () {
    test('copies the bundle beside its source under a fresh id with the new '
        'name', () async {
      final engine = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      await repo().createFolder('Gigs');
      final dir = '${root.path}/Gigs/s-a';
      await repo(engine: engine).save(
        dir,
        settings: const SessionSettings(),
        name: 'Source',
      );

      final id = await repo().duplicateSession('s-a', 'A Copy');

      expect(id, 's-20261006-120000');
      final copy = Directory('${root.path}/Gigs/$id');
      expect(copy.existsSync(), isTrue);
      expect(Directory(dir).existsSync(), isTrue);
      final copied = await repo().read(copy.path);
      expect(copied.session.name, 'A Copy');
      expect(
        File('${copy.path}/track0_lane0_L0.wav').readAsBytesSync(),
        File('$dir/track0_lane0_L0.wav').readAsBytesSync(),
      );
      final names = (await repo().listSessions()).map((s) => s.name);
      expect(names, unorderedEquals(['Source', 'A Copy']));
    });

    test('throws SessionNameCollision when a session has the name', () async {
      makeBundle('s-a', name: 'Source');
      makeBundle('s-b', name: 'Clash');
      await expectLater(
        repo().duplicateSession('s-a', 'Clash'),
        throwsA(isA<SessionNameCollision>()),
      );
      expect(await repo().listSessions(), hasLength(2));
      await repo().duplicateSession('s-a', 'clash');
      expect(await repo().listSessions(), hasLength(3));
    });

    test('throws StateError when the source is missing', () async {
      await expectLater(
        repo().duplicateSession('ghost', 'New'),
        throwsStateError,
      );
      expect(await repo().listSessions(), isEmpty);
    });

    test(
      'a duplicate carries no orphan layer WAVs from a shrinking re-save',
      () async {
        final dir = await repo().bundlePathOf('s-source');

        // Save a 3-layer history, then re-save single-layer (prunes L1/L2).
        await repo(
          engine: FakeSessionEngine()
            ..seedLayers(
              0,
              [
                Float32List.fromList([1, 1, 1, 1]),
                Float32List.fromList([2, 2, 2, 2]),
                Float32List.fromList([3, 3, 3, 3]),
              ],
              undoDepth: 1,
              redoDepth: 1,
            ),
        ).save(dir, settings: const SessionSettings());
        await repo(
          engine: FakeSessionEngine()
            ..seedTrack(0, Float32List.fromList([9, 9, 9, 9])),
        ).save(dir, settings: const SessionSettings());

        final id = await repo().duplicateSession('s-source', 'Copy');

        final wavs = Directory('${root.path}/$id')
            .listSync()
            .whereType<File>()
            .map((f) => f.path.split(RegExp(r'[/\\]')).last)
            .where((n) => n.endsWith('.wav'))
            .toSet();
        expect(wavs, contains('track0_lane0_L0.wav'));
        expect(wavs, isNot(contains('track0_lane0_L1.wav')));
        expect(wavs, isNot(contains('track0_lane0_L2.wav')));
      },
    );

    test(
      'a copy that fails removes what it wrote and leaves the source',
      () async {
        makeBundle('s-a', name: 'Source');
        final unreadable = File('${root.path}/s-a/track0_lane0_L0.wav')
          ..writeAsBytesSync([1, 2, 3]);
        Process.runSync('chmod', ['000', unreadable.path]);
        addTearDown(() => Process.runSync('chmod', ['644', unreadable.path]));

        await expectLater(
          repo().duplicateSession('s-a', 'Copy'),
          throwsA(isA<FileSystemException>()),
        );

        final entries = root.listSync().map((e) => e.path.split('/').last);
        expect(entries, ['s-a']);
        expect(await repo().listFolders(), isEmpty);
        expect((await repo().listSessions()).single.name, 'Source');
      },
      skip: Platform.isWindows ? 'needs chmod' : null,
    );

    test(
      'writes the manifest last, so a copy cut short lists nowhere',
      () async {
        final engine = FakeSessionEngine()
          ..seedLayers(
            0,
            [
              Float32List.fromList([1, 1, 1, 1]),
              Float32List.fromList([2, 2, 2, 2]),
            ],
            undoDepth: 1,
          );
        await repo(engine: engine).save(
          '${root.path}/s-a',
          settings: const SessionSettings(),
          name: 'Source',
        );
        final listedAtEachWrite = <bool>[];
        SessionRepository.debugOnDuplicateWrite = (path) {
          final copy = Directory(path).parent.path;
          listedAtEachWrite.add(
            File('$copy/${Session.manifestName}').existsSync(),
          );
        };
        addTearDown(() => SessionRepository.debugOnDuplicateWrite = null);

        await repo().duplicateSession('s-a', 'Copy');

        // Every layer and the mixdown land before the manifest.
        expect(listedAtEachWrite.length, greaterThan(2));
        expect(listedAtEachWrite.last, isTrue);
        expect(
          listedAtEachWrite.take(listedAtEachWrite.length - 1),
          everyElement(isFalse),
        );
      },
    );

    test('throws ArgumentError when the new name is invalid', () async {
      makeBundle('s-a');
      await expectLater(
        repo().duplicateSession('s-a', '  '),
        throwsArgumentError,
      );
    });
  });

  group('deleteSession', () {
    test('removes the bundle wherever it sits', () async {
      makeBundle('s-a');
      makeBundle('s-b', folder: 'Gigs');
      await repo().deleteSession('s-a');
      await repo().deleteSession('s-b');
      expect(Directory('${root.path}/s-a').existsSync(), isFalse);
      expect(Directory('${root.path}/Gigs/s-b').existsSync(), isFalse);
      expect(Directory('${root.path}/Gigs').existsSync(), isTrue);
    });

    test('is a no-op for a missing session', () async {
      await expectLater(repo().deleteSession('ghost'), completes);
    });

    test('refuses an invalid id', () async {
      await expectLater(repo().deleteSession('..'), throwsArgumentError);
    });
  });

  group('readPreview', () {
    test('derives populated tracks, bars, layers, mutes and FX', () async {
      // 48 kHz, 120 BPM, 4/4: one bar is 96000 frames.
      final engine = FakeSessionEngine()
        ..tempoBpm = 120
        ..tempoSource = TempoSource.manual
        ..seedLayers(
          0,
          [Float32List(96000), Float32List(96000), Float32List(96000)],
          undoDepth: 2,
        )
        ..seedTrack(2, Float32List(192000), multiple: 2, muted: true);
      final dir = await repo().bundlePathOf('s-a');
      await repo(engine: engine).save(
        dir,
        settings: const SessionSettings(
          tempoBpm: 120,
          tempoSource: TempoSource.manual,
        ),
        chains: SessionChains(
          laneChains: [
            SessionLaneChain(channel: 0, lane: 0, encoded: chain(3)),
          ],
          trackChains: [SessionTrackChain(channel: 2, encoded: chain(1))],
          allTracksChain: chain(2),
        ),
        name: 'Evening loop',
      );

      final preview = await repo().readPreview('s-a');

      expect(preview.summary.name, 'Evening loop');
      expect(preview.sampleRate, 48000);
      expect(preview.fxCount, 6);
      expect(preview.backingCount, 0);
      expect(preview.tracks.map((t) => t.channel), [0, 2]);
      final first = preview.tracks[0];
      expect(first.bars, 1);
      expect(first.layers, 3);
      expect(first.muted, isFalse);
      expect(first.fxCount, 3);
      expect(first.liveLayerFile, 'track0_lane0_L2.wav');
      expect(first.baseLengthFrames, 96000);
      final third = preview.tracks[1];
      expect(third.bars, 2);
      expect(third.layers, 1);
      expect(third.muted, isTrue);
      expect(third.fxCount, 1);
      expect(third.lengthFrames, 192000);
    });

    test('reports 0 bars without a tempo', () async {
      final engine = FakeSessionEngine()..seedTrack(0, Float32List(1000));
      final dir = await repo().bundlePathOf('s-a');
      await repo(engine: engine).save(dir, settings: const SessionSettings());
      expect((await repo().readPreview('s-a')).tracks.single.bars, 0);
    });

    test('reads a schema-7 bundle from master through its conversion, and '
        'lists its Master chain in the effect count', () async {
      final dir = '${root.path}/s-old';
      Directory(dir).createSync();
      for (final file in Directory(
        'test/fixtures/sessions/v7_master_full',
      ).listSync()) {
        (file as File).copySync('$dir/${file.uri.pathSegments.last}');
      }
      final manifest = File('$dir/${Session.manifestName}').readAsBytesSync();

      final preview = await repo().readPreview('s-old');

      expect(preview.tracks.map((t) => t.channel), [0, 1, 2]);
      expect(preview.tracks.first.layers, 3);
      // Lane 2, lane 1, track 1, Master and monitor 0: one entry each but
      // lane 0's two.
      expect(preview.fxCount, 6);
      expect(
        File('$dir/${Session.manifestName}').readAsBytesSync(),
        manifest,
      );
    });

    test('renames a schema-7 bundle in place and it still previews', () async {
      final dir = '${root.path}/s-old';
      Directory(dir).createSync();
      for (final file in Directory(
        'test/fixtures/sessions/v7_master_full',
      ).listSync()) {
        (file as File).copySync('$dir/${file.uri.pathSegments.last}');
      }

      await repo().renameSession('s-old', 'Old gig');

      final listed = (await repo().listSessions()).single;
      expect((listed.id, listed.name), ('s-old', 'Old gig'));
      final json =
          jsonDecode(File('$dir/${Session.manifestName}').readAsStringSync())
              as Map<String, dynamic>;
      // Only the name changed: the manifest stays schema 7, converted on the
      // next read as before.
      expect(json['version'], 7);
      expect(json['name'], 'Old gig');
      final preview = await repo().readPreview('s-old');
      expect(preview.summary.name, 'Old gig');
      expect(preview.tracks.map((t) => t.channel), [0, 1, 2]);
    });

    test('throws the typed refusal for a newer schema and StateError for a '
        'missing id', () async {
      makeBundle('s-future', version: 999);
      await expectLater(
        repo().readPreview('s-future'),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
      await expectLater(repo().readPreview('ghost'), throwsStateError);
    });
  });

  group('without a configured root', () {
    test('the catalog methods throw StateError', () async {
      final noRoot = repo(withRoot: false);
      await expectLater(noRoot.listSessions(), throwsStateError);
      await expectLater(noRoot.listFolders(), throwsStateError);
      await expectLater(noRoot.bundlePathOf('x'), throwsStateError);
      await expectLater(noRoot.renameSession('a', 'b'), throwsStateError);
      await expectLater(noRoot.deleteSession('a'), throwsStateError);
      await expectLater(noRoot.newSessionId(), throwsStateError);
    });
  });
}
