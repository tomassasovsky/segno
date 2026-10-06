import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import 'helpers/harness.dart';

void main() {
  late Harness h;
  late StorageRepository repo;

  const internal = StorageDestination.internal();
  const usb1 = StorageDestination.removable(1);

  setUp(() => h = Harness());
  tearDown(() async {
    await repo.dispose();
    h.dispose();
  });

  /// A copy step that writes half of the source into the part, then does
  /// [midway] (a drive pulled, a disk filling up) and continues or throws.
  CopyBytes halfThen(FutureOr<void> Function(bool Function() abort) midway) {
    return (source, part, shouldAbort) async {
      final bytes = source.readAsBytesSync();
      part.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2), flush: true);
      await midway(shouldAbort);
      if (shouldAbort()) throw const FileSystemException('aborted');
      part.writeAsBytesSync(bytes, flush: true);
    };
  }

  group('a copy that completes', () {
    test('writes <name>.part first, renames it into place only once it is '
        'complete, under a copy lease', () async {
      final source = h.source('take.wav', 300000);
      final seen = <String>[];
      repo = h.build(
        copyBytes: (from, part, shouldAbort) async {
          final target = File(part.path.replaceAll('.part', ''));
          seen
            ..add('part ${part.path.substring(h.exports.length + 1)}')
            ..add('target exists: ${target.existsSync()}')
            ..add('lease: ${repo.leases.map((l) => l.purpose).join()}');
          await part.writeAsBytes(await from.readAsBytes(), flush: true);
        },
      );

      final written = await repo.copyFile(
        source.path,
        internal,
        'Segno/Performances/take.wav',
        onConflict: ConflictPolicy.ask,
      );

      expect(written, '${h.exports}/Segno/Performances/take.wav');
      expect(seen, [
        'part Segno/Performances/take.wav.part',
        'target exists: false',
        'lease: copy',
      ]);
      expect(File(written).readAsBytesSync(), source.readAsBytesSync());
      expect(h.filesUnder(h.exports), ['Segno/Performances/take.wav']);
      expect(repo.leases, isEmpty);
    });

    test('the real copy lands byte for byte on a mounted volume', () async {
      final source = h.source('take.wav', 3 * 1024 * 1024 + 17);
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final written = await repo.copyFile(
        source.path,
        usb1,
        'Segno/take.wav',
        onConflict: ConflictPolicy.ask,
      );

      expect(written, '${h.mountPoint(1)}/Segno/take.wav');
      expect(File(written).readAsBytesSync(), source.readAsBytesSync());
      expect(h.filesUnder(h.mountPoint(1)), ['Segno/take.wav']);
    });
  });

  group('a copy that fails leaves no partial file and the source intact', () {
    test('an interrupted copy (an I/O error midway) is io, with no part and '
        'no target left behind', () async {
      final source = h.source('take.wav', 100000);
      final before = source.readAsBytesSync();
      repo = h.build(
        copyBytes: halfThen((_) => throw osError(71, 'Protocol error')),
      );

      await expectLater(
        repo.copyFile(
          source.path,
          internal,
          'take.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.io('Protocol error')),
      );

      expect(h.filesUnder(h.exports), isEmpty);
      expect(source.readAsBytesSync(), before);
      expect(repo.leases, isEmpty);
    });

    test(
      'a full disk (ENOSPC) is full; a file being replaced stays whole',
      () async {
        final source = h.source('take.wav', 100000);
        repo = h.build(
          copyBytes: halfThen(
            (_) => throw osError(28, 'No space left on device'),
          ),
        );
        File('${h.exports}/take.wav').writeAsStringSync('the old take');

        await expectLater(
          repo.copyFile(
            source.path,
            internal,
            'take.wav',
            onConflict: ConflictPolicy.replace,
          ),
          throwsA(const StorageFailure.full()),
        );

        expect(h.filesUnder(h.exports), ['take.wav']);
        expect(
          File('${h.exports}/take.wav').readAsStringSync(),
          'the old take',
        );
      },
    );

    test('a read-only filesystem (EROFS) is readOnly, even before the part '
        'exists', () async {
      final source = h.source('take.wav', 10);
      repo = h.build(
        copyBytes: (source, part, shouldAbort) async =>
            throw osError(30, 'Read-only file system'),
      );

      await expectLater(
        repo.copyFile(
          source.path,
          internal,
          'take.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.readOnly()),
      );
      expect(h.filesUnder(h.exports), isEmpty);
    });

    test('a volume pulled mid-copy is volumeLost: the copy stops at the next '
        'write and the part goes', () async {
      final source = h.source('take.wav', 100000);
      repo = h.build(
        initial: [h.record(1)],
        copyBytes: halfThen((abort) async {
          h.client.detach(1);
          await pumpEventQueue();
          expect(abort(), isTrue);
        }),
      );
      await pumpEventQueue();

      await expectLater(
        repo.copyFile(
          source.path,
          usb1,
          'take.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.volumeLost(1)),
      );
      expect(h.filesUnder(h.mountPoint(1)), isEmpty);
    });

    test('the real copy also stops when the volume goes', () async {
      final source = h.source('take.wav', 8 * 1024 * 1024);
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final copy = repo.copyFile(
        source.path,
        usb1,
        'take.wav',
        onConflict: ConflictPolicy.ask,
      );
      h.client.detach(1);

      await expectLater(copy, throwsA(const StorageFailure.volumeLost(1)));
      expect(h.filesUnder(h.mountPoint(1)), isEmpty);
    });

    test('an EIO from a pulled drive is volumeLost when its record goes '
        'within the grace, and io when it does not', () async {
      final source = h.source('take.wav', 1000);
      var pull = true;
      repo = h.build(
        initial: [h.record(1)],
        volumeLossGrace: const Duration(milliseconds: 200),
        copyBytes: halfThen((_) {
          // The write fails first; the helper's record goes a moment later.
          if (pull) {
            Timer(const Duration(milliseconds: 20), () => h.client.detach(1));
          }
          throw osError(5, 'Input/output error');
        }),
      );
      await pumpEventQueue();

      pull = false;
      await expectLater(
        repo.copyFile(
          source.path,
          usb1,
          'a.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.io('Input/output error')),
      );

      pull = true;
      await expectLater(
        repo.copyFile(
          source.path,
          usb1,
          'b.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.volumeLost(1)),
      );
      expect(h.filesUnder(h.mountPoint(1)), isEmpty);
    });

    test('a volume lost after the last byte but before the rename is still '
        'volumeLost, with no file under the final name', () async {
      final source = h.source('take.wav', 1000);
      repo = h.build(
        initial: [h.record(1)],
        copyBytes: (from, part, shouldAbort) async {
          part.writeAsBytesSync(from.readAsBytesSync(), flush: true);
          h.client.detach(1);
          await pumpEventQueue();
        },
      );
      await pumpEventQueue();

      await expectLater(
        repo.copyFile(
          source.path,
          usb1,
          'take.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(const StorageFailure.volumeLost(1)),
      );
      expect(h.filesUnder(h.mountPoint(1)), isEmpty);
    });
  });

  group('refused before writing', () {
    test('a read-only volume, an absent one, and a path that leaves the '
        'root', () async {
      final source = h.source('take.wav', 10);
      repo = h.build(
        initial: [h.record(1, status: RemovableVolumeRecordStatus.readOnly)],
      );
      await pumpEventQueue();

      Future<String> copyTo(StorageDestination d, String path) =>
          repo.copyFile(source.path, d, path, onConflict: ConflictPolicy.ask);

      await expectLater(
        copyTo(usb1, 'take.wav'),
        throwsA(const StorageFailure.readOnly()),
      );
      await expectLater(
        copyTo(const StorageDestination.removable(2), 'take.wav'),
        throwsA(const StorageFailure.volumeLost(2)),
      );
      for (final bad in ['', '/etc/passwd', '../take.wav', 'a//b', 'a/./b']) {
        expect(
          () => copyTo(internal, bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(h.filesUnder(h.root.path), ['take.wav']);
      expect(repo.leases, isEmpty);
    });
  });

  group('a name that is already there', () {
    late File source;

    setUp(() {
      source = h.source('take.wav', 64);
      repo = h.build();
      File('${h.exports}/take.wav').writeAsStringSync('old');
    });

    Future<String> copyAs(String name, ConflictPolicy policy) =>
        repo.copyFile(source.path, internal, name, onConflict: policy);

    test('ask stops with NameConflict before writing anything', () async {
      await expectLater(
        copyAs('take.wav', ConflictPolicy.ask),
        throwsA(
          isA<NameConflict>()
              .having(
                (e) => e.existingPath,
                'existingPath',
                '${h.exports}/take.wav',
              )
              .having(
                (e) => '$e',
                'toString',
                'NameConflict(${h.exports}/take.wav)',
              ),
        ),
      );
      expect(h.filesUnder(h.exports), ['take.wav']);
      expect(File('${h.exports}/take.wav').readAsStringSync(), 'old');
      expect(repo.leases, isEmpty);
    });

    test('keep both writes name (2).ext, then (3)', () async {
      expect(
        await copyAs('take.wav', ConflictPolicy.keepBoth),
        '${h.exports}/take (2).wav',
      );
      expect(
        await copyAs('take.wav', ConflictPolicy.keepBoth),
        '${h.exports}/take (3).wav',
      );
      expect(h.filesUnder(h.exports), [
        'take (2).wav',
        'take (3).wav',
        'take.wav',
      ]);
      expect(File('${h.exports}/take.wav').readAsStringSync(), 'old');
      expect(
        File('${h.exports}/take (2).wav').readAsBytesSync(),
        source.readAsBytesSync(),
      );
    });

    test('keep both puts the number at the end of a name without an '
        'extension, a dotfile included', () async {
      File('${h.exports}/notes').writeAsStringSync('old');
      File('${h.exports}/.segno').writeAsStringSync('old');
      Directory('${h.exports}/v1.2').createSync();
      File('${h.exports}/v1.2/mix').writeAsStringSync('old');

      expect(
        await copyAs('notes', ConflictPolicy.keepBoth),
        '${h.exports}/notes (2)',
      );
      expect(
        await copyAs('.segno', ConflictPolicy.keepBoth),
        '${h.exports}/.segno (2)',
      );
      expect(
        await copyAs('v1.2/mix', ConflictPolicy.keepBoth),
        '${h.exports}/v1.2/mix (2)',
      );
    });

    test('replace writes over it', () async {
      expect(
        await copyAs('take.wav', ConflictPolicy.replace),
        '${h.exports}/take.wav',
      );
      expect(h.filesUnder(h.exports), ['take.wav']);
      expect(
        File('${h.exports}/take.wav').readAsBytesSync(),
        source.readAsBytesSync(),
      );
    });
  });
}
