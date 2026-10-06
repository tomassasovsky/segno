import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/library/application/audio_export.dart';
import 'package:segno/library/application/removable_volumes.dart';

import '../helpers/fake_drive.dart';

void main() {
  late Directory temp;
  late String internal;
  late FakeDrive drive;
  late AudioExporter exporter;

  const perf = AudioExportFolders.performances;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_audio_export');
    internal = '${temp.path}/internal';
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    exporter = AudioExporter(drive);
  });

  tearDown(() async {
    AudioExporter.debugOnSwap = null;
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  /// An internal file of [bytes] bytes, each [fill].
  String source(String relative, {int bytes = 4, int fill = 1}) {
    final file = File('$internal/$relative')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, fill));
    return file.path;
  }

  /// Puts [relative] on the drive, holding [fill].
  void onDrive(String relative, {int fill = 9}) =>
      File('${drive.mount}/$relative')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([fill]);

  /// Every file on the drive and its bytes.
  Map<String, List<int>> driveBytes() => {
    for (final f in drive.files) f: File('${drive.mount}/$f').readAsBytesSync(),
  };

  final earlier = RegExp(r'^Evening loop( · Part \d{3})?\.wav$');

  AudioExportPlan parts(int count, {int fill = 1}) => AudioExportPlan(
    name: 'Evening loop',
    folder: perf,
    earlier: earlier,
    files: [
      for (var i = 1; i <= count; i++)
        AudioExportFile(
          source('take/master-00$i.wav', fill: fill),
          '{name} · Part 00$i.wav',
        ),
    ],
  );

  AudioExportPlan package({int fill = 1}) => AudioExportPlan(
    name: 'Evening loop',
    folder: perf,
    package: true,
    files: [
      AudioExportFile(
        source('take/master-001.wav', fill: fill),
        'master-001.wav',
      ),
      AudioExportFile(
        source('take/stems/wet/track0.wav', fill: fill),
        'stems/wet/track0.wav',
      ),
      AudioExportFile(source('take/project.als', fill: fill), 'project.als'),
    ],
  );

  Future<String> run(
    AudioExportPlan plan, {
    ConflictPolicy policy = ConflictPolicy.ask,
    bool Function()? cancelled,
    void Function(double)? onProgress,
  }) => exporter.run(
    plan,
    generation: drive.generation,
    policy: policy,
    purpose: 'Exporting Evening loop',
    cancelled: cancelled,
    onProgress: onProgress,
  );

  /// Every internal file and its bytes, to prove an export only read them.
  Map<String, List<int>> internalBytes() => {
    for (final e in Directory(internal).listSync(recursive: true))
      if (e is File) e.path: e.readAsBytesSync(),
  };

  const staging = '$perf/${AudioExporter.stagingPrefix}Evening loop';
  const aside = '$staging.old';

  group('loose files', () {
    test('copies each part once into the export staging, under the lease, '
        'then places them as consecutive files', () async {
      final progress = <double>[];

      final at = await run(parts(3), onProgress: progress.add);

      expect(at, '$perf/Evening loop · Part 001.wav');
      expect(drive.leases, ['Exporting Evening loop']);
      expect(drive.copies.map((c) => (c.relativePath, c.policy)), [
        for (var i = 1; i <= 3; i++)
          ('$staging/Evening loop · Part 00$i.wav', ConflictPolicy.replace),
      ]);
      expect(drive.files, [
        for (var i = 1; i <= 3; i++) '$perf/Evening loop · Part 00$i.wav',
      ]);
      expect(progress.last, 1);
    });

    test(
      'ask reports a name already on the drive before writing anything',
      () async {
        onDrive('$perf/Evening loop · Part 002.wav');

        await expectLater(
          run(parts(3)),
          throwsA(
            isA<NameConflict>().having(
              (c) => c.existingPath,
              'existingPath',
              '${drive.mount}/$perf/Evening loop · Part 002.wav',
            ),
          ),
        );
        expect(drive.copies, isEmpty);
      },
    );

    test('Keep both gives every part the first free name', () async {
      onDrive('$perf/Evening loop · Part 002.wav');
      onDrive('$perf/Evening loop (2) · Part 001.wav');

      await run(parts(2), policy: ConflictPolicy.keepBoth);

      expect(
        drive.files,
        containsAll([
          '$perf/Evening loop (3) · Part 001.wav',
          '$perf/Evening loop (3) · Part 002.wav',
        ]),
      );
      expect(drive.files, hasLength(4));
    });

    test(
      'Replace swaps the earlier export whole, its extra parts too',
      () async {
        for (var i = 1; i <= 3; i++) {
          onDrive('$perf/Evening loop · Part 00$i.wav');
        }
        onDrive('$perf/Evening loop.wav');
        onDrive('$perf/Other.wav');

        await run(parts(2, fill: 5), policy: ConflictPolicy.replace);

        expect(driveBytes(), {
          '$perf/Evening loop · Part 001.wav': [5, 5, 5, 5],
          '$perf/Evening loop · Part 002.wav': [5, 5, 5, 5],
          '$perf/Other.wav': [9],
        });
      },
    );

    for (final failure in <Exception>[
      const StorageFailure.full(),
      const StorageFailure.volumeLost(3),
      const StorageFailure.readOnly(),
      const StorageFailure.io('write error'),
    ]) {
      test('$failure on the third part leaves the drive and the recording '
          'as they were', () async {
        onDrive('$perf/Other.wav');
        final plan = parts(3);
        final before = internalBytes();
        drive
          ..failOnCopy = 3
          ..failure = failure;

        await expectLater(run(plan), throwsA(failure));

        expect(drive.copies, hasLength(3));
        expect(drive.files, ['$perf/Other.wav']);
        expect(internalBytes(), before);
      });
    }

    test('a Replace that fails or is cancelled part-way leaves the earlier '
        'export byte for byte', () async {
      for (var i = 1; i <= 3; i++) {
        onDrive('$perf/Evening loop · Part 00$i.wav', fill: i);
      }
      final before = driveBytes();

      drive.failOnCopy = 2;
      await expectLater(
        run(parts(3, fill: 5), policy: ConflictPolicy.replace),
        throwsA(isA<StorageIo>()),
      );
      expect(driveBytes(), before);

      drive.failOnCopy = null;
      var asked = 0;
      await expectLater(
        run(
          parts(3, fill: 5),
          policy: ConflictPolicy.replace,
          cancelled: () => ++asked > 2,
        ),
        throwsA(isA<AudioExportCancelled>()),
      );
      expect(driveBytes(), before);
    });

    test(
      'a rename refused during the swap puts the earlier export back',
      () async {
        for (var i = 1; i <= 3; i++) {
          onDrive('$perf/Evening loop · Part 00$i.wav', fill: i);
        }
        final before = driveBytes();
        AudioExporter.debugOnSwap = (step) {
          if (step == 'placed Evening loop · Part 001.wav') {
            throw const FileSystemException('unplugged');
          }
        };

        await expectLater(
          run(parts(2, fill: 5), policy: ConflictPolicy.replace),
          throwsA(isA<StorageIo>()),
        );

        expect(driveBytes(), before);
      },
    );
  });

  test('a Replace stopped while it moves the earlier parts aside keeps the '
      'ones not moved yet and puts back the moved ones', () async {
    for (var i = 1; i <= 2; i++) {
      onDrive('$perf/Evening loop · Part 00$i.wav', fill: i);
    }
    final before = driveBytes();
    AudioExporter.debugOnSwap = (step) {
      if (step == 'aside Evening loop · Part 002.wav') {
        throw const FileSystemException('unplugged');
      }
    };

    await expectLater(
      run(parts(2, fill: 5), policy: ConflictPolicy.replace),
      throwsA(isA<StorageIo>()),
    );

    expect(driveBytes(), before);
  });

  test('a cut after the commit point keeps the new export: the next export '
      'only clears what is left aside', () async {
    onDrive('$perf/Evening loop/old.wav', fill: 7);
    AudioExporter.debugOnSwap = (step) {
      if (step == 'committed') throw const _Cut();
    };

    await expectLater(
      run(package(fill: 5), policy: ConflictPolicy.replace),
      throwsA(isA<_Cut>()),
    );
    AudioExporter.debugOnSwap = null;
    AudioExporter.recoverFolder(Directory('${drive.mount}/$perf'));

    expect(driveBytes(), {
      '$perf/Evening loop/master-001.wav': [5, 5, 5, 5],
      '$perf/Evening loop/project.als': [5, 5, 5, 5],
      '$perf/Evening loop/stems/wet/track0.wav': [5, 5, 5, 5],
    });
  });

  group('space', () {
    test(
      'an export larger than the free space is refused before any copy',
      () async {
        drive.spaceAnswer = const VolumeSpace(totalBytes: 100, freeBytes: 11);

        await expectLater(
          run(parts(3)),
          throwsA(isA<StorageFull>()),
        );
        expect(drive.copies, isEmpty);
      },
    );

    test('one that fits, or an unknown free space, goes ahead', () async {
      drive.spaceAnswer = const VolumeSpace(totalBytes: 100, freeBytes: 12);
      await run(parts(3));
      expect(drive.copies, hasLength(3));
    });
  });

  group('a package', () {
    test('appears as one directory once every file is in it, its paths '
        'kept', () async {
      final at = await run(package());

      expect(at, '$perf/Evening loop');
      expect(drive.files, [
        '$perf/Evening loop/master-001.wav',
        '$perf/Evening loop/project.als',
        '$perf/Evening loop/stems/wet/track0.wav',
      ]);
      expect(drive.copies.map((c) => (c.relativePath, c.policy)), [
        ('$staging/Evening loop/master-001.wav', ConflictPolicy.replace),
        ('$staging/Evening loop/stems/wet/track0.wav', ConflictPolicy.replace),
        ('$staging/Evening loop/project.als', ConflictPolicy.replace),
      ]);
    });

    test('ask reports the directory already there before writing', () async {
      onDrive('$perf/Evening loop/old.wav');

      await expectLater(run(package()), throwsA(isA<NameConflict>()));
      expect(drive.copies, isEmpty);
    });

    test('Keep both writes beside it; Replace swaps it whole', () async {
      onDrive('$perf/Evening loop/old.wav');

      await run(package(), policy: ConflictPolicy.keepBoth);
      expect(drive.files, contains('$perf/Evening loop (2)/project.als'));
      expect(drive.files, contains('$perf/Evening loop/old.wav'));

      await run(package(), policy: ConflictPolicy.replace);
      expect(
        drive.files.where((f) => f.startsWith('$perf/Evening loop/')),
        [
          '$perf/Evening loop/master-001.wav',
          '$perf/Evening loop/project.als',
          '$perf/Evening loop/stems/wet/track0.wav',
        ],
      );
      expect(
        drive.files.where((f) => f.contains(AudioExporter.stagingPrefix)),
        isEmpty,
      );
    });

    for (final failure in <Exception>[
      const StorageFailure.full(),
      const StorageFailure.volumeLost(3),
      const StorageFailure.readOnly(),
      const StorageFailure.io('write error'),
    ]) {
      test(
        '$failure part-way leaves no package and no staging on the drive',
        () async {
          onDrive('$perf/Other.wav');
          final plan = package();
          final before = internalBytes();
          drive
            ..failOnCopy = 2
            ..failure = failure;

          await expectLater(run(plan), throwsA(failure));

          expect(drive.files, ['$perf/Other.wav']);
          expect(internalBytes(), before);
        },
      );
    }

    test('a cancel after the last file still leaves nothing', () async {
      var asked = 0;

      await expectLater(
        run(package(), cancelled: () => ++asked > 3),
        throwsA(isA<AudioExportCancelled>()),
      );

      expect(drive.copies, hasLength(3));
      expect(drive.files, isEmpty);
    });

    test('a Replace refused between its renames puts the old package back '
        'at once', () async {
      onDrive('$perf/Evening loop/old.wav', fill: 7);
      final before = driveBytes();
      AudioExporter.debugOnSwap = (step) {
        if (step == 'aside') throw const FileSystemException('unplugged');
      };

      await expectLater(
        run(package(), policy: ConflictPolicy.replace),
        throwsA(isA<StorageIo>()),
      );

      expect(driveBytes(), before);
    });
  });

  group('after a cut', () {
    /// What a power cut between the two renames of a package Replace leaves:
    /// the old package aside with its target list, the new one staged, no
    /// package under its name.
    void cutMidSwap() {
      onDrive(
        '$aside/Evening loop/old.wav',
        fill: 7,
      );
      File(
        '${drive.mount}/$perf/${AudioExporter.stagingPrefix}Evening loop.old/'
        '${AudioExporter.targetsName}',
      ).writeAsStringSync('Evening loop');
      onDrive('$staging/Evening loop/new.wav', fill: 8);
    }

    test('the next export into the folder puts the old package back first, '
        'and a Replace of another package leaves it alone', () async {
      cutMidSwap();

      await run(
        const AudioExportPlan(
          name: 'Other',
          folder: perf,
          package: true,
          files: [],
        ).withFile(source('other/master.wav')),
        policy: ConflictPolicy.replace,
      );

      expect(driveBytes(), {
        '$perf/Evening loop/old.wav': [7],
        '$perf/Other/master.wav': [1, 1, 1, 1],
      });
    });

    test('a cut after a swap was committed only loses its aside, and a '
        'loose rename that was half done is undone', () async {
      // Committed: no target list left in the aside.
      onDrive('$perf/${AudioExporter.stagingPrefix}Done.old/Done/old.wav');
      onDrive('$perf/Done/new.wav', fill: 3);
      // Half done: Part 001 placed, Part 002 still staged, both old aside.
      for (var i = 1; i <= 2; i++) {
        onDrive(
          '$aside/Evening loop · Part 00$i.wav',
          fill: i,
        );
      }
      File(
        '${drive.mount}/$perf/${AudioExporter.stagingPrefix}Evening loop.old/'
        '${AudioExporter.targetsName}',
      ).writeAsStringSync(
        'Evening loop · Part 001.wav\nEvening loop · Part 002.wav',
      );
      onDrive('$perf/Evening loop · Part 001.wav', fill: 5);
      onDrive('$staging/Evening loop · Part 002.wav', fill: 5);
      // An older build's staging.
      onDrive('$perf/.segno-export/stale.wav');

      AudioExporter.recoverFolder(Directory('${drive.mount}/$perf'));

      expect(driveBytes(), {
        '$perf/Done/new.wav': [3],
        '$perf/Evening loop · Part 001.wav': [1],
        '$perf/Evening loop · Part 002.wav': [2],
      });
    });
  });

  test(
    'a drive gone before the lease fails typed, with nothing copied',
    () async {
      await expectLater(
        exporter.run(
          parts(1),
          generation: drive.generation + 1,
          policy: ConflictPolicy.ask,
          purpose: 'Exporting',
        ),
        throwsA(isA<StorageVolumeLost>()),
      );
      expect(drive.copies, isEmpty);
    },
  );

  test('driveSafeName keeps what FAT32 and exFAT accept', () {
    expect(driveSafeName('Song: take 2?'), 'Song- take 2-');
    expect(driveSafeName(r'a/b\c<d>e|f"g*h'), 'a-b-c-d-e-f-g-h');
    expect(driveSafeName('Night set. '), 'Night set');
    expect(driveSafeName('...'), '-');
    expect(driveSafeName('Evening loop · Take 1'), 'Evening loop · Take 1');
  });
}

extension on AudioExportPlan {
  AudioExportPlan withFile(String path) => AudioExportPlan(
    name: name,
    folder: folder,
    package: package,
    files: [AudioExportFile(path, 'master.wav')],
  );
}

/// Stands for the process stopping: no handler of the exporter's catches it
/// as a filesystem failure.
class _Cut implements Exception {
  const _Cut();
}
