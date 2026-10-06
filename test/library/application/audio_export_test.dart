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

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_audio_export');
    internal = '${temp.path}/internal';
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    exporter = AudioExporter(drive);
  });

  tearDown(() async {
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  /// An internal file of [bytes] bytes.
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

  AudioExportPlan parts(int count) => AudioExportPlan(
    name: 'Evening loop',
    folder: AudioExportFolders.performances,
    files: [
      for (var i = 1; i <= count; i++)
        AudioExportFile(
          source('take/master-00$i.wav'),
          '{name} · Part 00$i.wav',
        ),
    ],
  );

  AudioExportPlan package() => AudioExportPlan(
    name: 'Evening loop',
    folder: AudioExportFolders.performances,
    package: true,
    files: [
      AudioExportFile(source('take/master-001.wav'), 'master-001.wav'),
      AudioExportFile(
        source('take/stems/wet/track0.wav'),
        'stems/wet/track0.wav',
      ),
      AudioExportFile(source('take/project.als'), 'project.als'),
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

  group('loose files', () {
    test(
      'copies each part once, under the lease, as consecutive files',
      () async {
        final plan = parts(3);
        final progress = <double>[];

        final at = await run(plan, onProgress: progress.add);

        expect(at, 'Segno/Performances/Evening loop · Part 001.wav');
        expect(drive.leases, ['Exporting Evening loop']);
        expect(drive.copies.map((c) => (c.relativePath, c.policy)), [
          (
            'Segno/Performances/Evening loop · Part 001.wav',
            ConflictPolicy.ask,
          ),
          (
            'Segno/Performances/Evening loop · Part 002.wav',
            ConflictPolicy.ask,
          ),
          (
            'Segno/Performances/Evening loop · Part 003.wav',
            ConflictPolicy.ask,
          ),
        ]);
        expect(drive.files, hasLength(3));
        expect(progress.last, 1);
      },
    );

    test(
      'ask reports a name already on the drive before writing anything',
      () async {
        onDrive('Segno/Performances/Evening loop · Part 002.wav');

        await expectLater(
          run(parts(3)),
          throwsA(
            isA<NameConflict>().having(
              (c) => c.existingPath,
              'existingPath',
              '${drive.mount}/Segno/Performances/Evening loop · Part 002.wav',
            ),
          ),
        );
        expect(drive.copies, isEmpty);
      },
    );

    test('Keep both gives every part the first free name', () async {
      onDrive('Segno/Performances/Evening loop · Part 002.wav');
      onDrive('Segno/Performances/Evening loop (2) · Part 001.wav');

      await run(parts(2), policy: ConflictPolicy.keepBoth);

      expect(drive.copies.map((c) => c.relativePath), [
        'Segno/Performances/Evening loop (3) · Part 001.wav',
        'Segno/Performances/Evening loop (3) · Part 002.wav',
      ]);
      expect(drive.copies.map((c) => c.policy).toSet(), {
        ConflictPolicy.keepBoth,
      });
    });

    test('Replace writes over the files there', () async {
      onDrive('Segno/Performances/Evening loop · Part 001.wav');

      await run(parts(1), policy: ConflictPolicy.replace);

      expect(drive.copies.single.policy, ConflictPolicy.replace);
      expect(
        File(
          '${drive.mount}/Segno/Performances/Evening loop · Part 001.wav',
        ).readAsBytesSync(),
        [1, 1, 1, 1],
      );
    });

    for (final failure in <Exception>[
      const StorageFailure.full(),
      const StorageFailure.volumeLost(3),
      const StorageFailure.readOnly(),
      const StorageFailure.io('write error'),
    ]) {
      test('$failure on the third part removes the two already placed and '
          'leaves the rest of the drive and the recording alone', () async {
        onDrive('Segno/Performances/Other.wav');
        final plan = parts(3);
        final before = internalBytes();
        drive
          ..failOnCopy = 3
          ..failure = failure;

        await expectLater(run(plan), throwsA(failure));

        expect(drive.copies, hasLength(3));
        expect(drive.files, ['Segno/Performances/Other.wav']);
        expect(internalBytes(), before);
      });
    }

    test('a cancel removes what was placed', () async {
      var asked = 0;

      await expectLater(
        run(parts(3), cancelled: () => ++asked > 1),
        throwsA(isA<AudioExportCancelled>()),
      );

      expect(drive.copies, hasLength(1));
      expect(drive.files, isEmpty);
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

      expect(at, 'Segno/Performances/Evening loop');
      expect(drive.files, [
        'Segno/Performances/Evening loop/master-001.wav',
        'Segno/Performances/Evening loop/project.als',
        'Segno/Performances/Evening loop/stems/wet/track0.wav',
      ]);
      expect(drive.copies.map((c) => (c.relativePath, c.policy)), [
        (
          'Segno/Performances/${AudioExporter.stagingName}/master-001.wav',
          ConflictPolicy.replace,
        ),
        (
          'Segno/Performances/${AudioExporter.stagingName}/'
              'stems/wet/track0.wav',
          ConflictPolicy.replace,
        ),
        (
          'Segno/Performances/${AudioExporter.stagingName}/project.als',
          ConflictPolicy.replace,
        ),
      ]);
    });

    test('ask reports the directory already there before writing', () async {
      onDrive('Segno/Performances/Evening loop/old.wav');

      await expectLater(run(package()), throwsA(isA<NameConflict>()));
      expect(drive.copies, isEmpty);
    });

    test('Keep both writes beside it; Replace swaps it whole', () async {
      onDrive('Segno/Performances/Evening loop/old.wav');

      await run(package(), policy: ConflictPolicy.keepBoth);
      expect(
        drive.files,
        contains('Segno/Performances/Evening loop (2)/project.als'),
      );
      expect(drive.files, contains('Segno/Performances/Evening loop/old.wav'));

      await run(package(), policy: ConflictPolicy.replace);
      final inPlace = drive.files
          .where((f) => f.startsWith('Segno/Performances/Evening loop/'))
          .toList();
      expect(inPlace, [
        'Segno/Performances/Evening loop/master-001.wav',
        'Segno/Performances/Evening loop/project.als',
        'Segno/Performances/Evening loop/stems/wet/track0.wav',
      ]);
      expect(
        drive.files.where((f) => f.contains(AudioExporter.stagingName)),
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
          onDrive('Segno/Performances/Other.wav');
          final plan = package();
          final before = internalBytes();
          drive
            ..failOnCopy = 2
            ..failure = failure;

          await expectLater(run(plan), throwsA(failure));

          expect(drive.files, ['Segno/Performances/Other.wav']);
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

    test('clears a staging directory a crash left behind', () async {
      onDrive('Segno/Performances/${AudioExporter.stagingName}/stale.wav');

      await run(package());

      expect(drive.files.where((f) => f.contains('stale')), isEmpty);
    });

    test('a rename the drive refuses is a typed I/O failure, with the '
        'staging gone', () async {
      // A file where the package directory goes: the rename cannot land.
      onDrive('Segno/Performances/Evening loop');

      await expectLater(
        run(package(), policy: ConflictPolicy.replace),
        throwsA(isA<StorageIo>()),
      );
      expect(drive.files, ['Segno/Performances/Evening loop']);
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
