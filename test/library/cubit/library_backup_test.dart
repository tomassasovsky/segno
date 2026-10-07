import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/library/application/audio_export.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:session_repository/session_repository.dart';

import '../helpers/fake_drive.dart';

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockSessionRepository extends Mock implements SessionRepository {}

/// Sessions > USB (#1178 Part 8, pen section 34): Back up to USB through
/// the port and the guard table, and Restore to Library.
void main() {
  late Directory temp;
  late String bundle;
  late FakeDrive drive;
  late GuardRegistry guards;
  late SessionRepository sessions;
  late PedalRepository pedal;

  const id = 's-20261006-120000';
  const files = [
    'mixdown.wav',
    'track0_lane0_L0.wav',
    'track1_lane0_L0.wav',
    'session.json',
  ];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_library_backup');
    bundle = '${temp.path}/sessions/$id';
    for (final (i, f) in files.indexed) {
      File('$bundle/$f')
        ..createSync(recursive: true)
        ..writeAsBytesSync([i, i]);
    }
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    guards = GuardRegistry();
    sessions = _MockSessionRepository();
    when(() => sessions.readPreview(any())).thenAnswer(
      (call) async => SessionPreview(
        summary: SessionSummary(
          id: call.positionalArguments.first as String,
          name: 'Evening loop',
        ),
        tracks: const [],
        fxCount: 0,
        sampleRate: 48000,
      ),
    );
    when(() => sessions.bundlePathOf(id)).thenAnswer((_) async => bundle);
    when(() => sessions.bundleFiles(id)).thenAnswer((_) async => files);
    when(() => sessions.listBackups(any())).thenReturn(const []);
    pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  Future<LibraryCubit> selected() async {
    final cubit = LibraryCubit(
      sessions: sessions,
      volumes: drive,
      pedal: pedal,
      guards: guards,
    );
    addTearDown(cubit.close);
    await cubit.select(id);
    return cubit;
  }

  Future<void> backUp(LibraryCubit cubit) =>
      cubit.backUp(name: 'Evening loop', purpose: 'Backing up Evening loop');

  /// A backup of [id] already on the drive, holding [fill].
  void existingBackup(String dir, {int fill = 9}) =>
      File('${drive.mount}/Segno/Sessions/$dir/session.json')
        ..createSync(recursive: true)
        ..writeAsBytesSync([fill]);

  group('Back up to USB', () {
    test('copies every bundle file once into the hidden staging directory '
        'under a named lease and a transfer guard, then renames it into '
        'place', () async {
      final cubit = await selected();
      final heldDuring = <List<ActiveOperation>>[];
      final saveRefusedDuring = <bool>[];
      drive.beforeCopy = (_) {
        heldDuring.add(guards.active);
        saveRefusedDuring.add(
          guards
              .blockers(
                GuardKind.sessionWrite,
                GuardScope.internal(item: bundle),
              )
              .isNotEmpty,
        );
      };

      await backUp(cubit);

      expect(drive.leases, ['Backing up Evening loop']);
      expect(drive.copies.map((c) => (c.relativePath, c.policy)), [
        for (final f in files)
          (
            'Segno/Sessions/${AudioExporter.stagingPrefix}$id/$id/$f',
            ConflictPolicy.replace,
          ),
      ]);
      expect(drive.files, [
        for (final f in [...files]..sort()) 'Segno/Sessions/$id/$f',
      ]);
      expect(
        File(
          '${drive.mount}/Segno/Sessions/$id/track1_lane0_L0.wav',
        ).readAsBytesSync(),
        [2, 2],
      );
      expect(heldDuring.first, [
        ActiveOperation(
          kind: GuardKind.transfer,
          scope: GuardScope.removable(
            drive.generation,
            item: 'Segno/Sessions/$id',
          ),
          purpose: 'Backing up Evening loop',
        ),
        ActiveOperation(
          kind: GuardKind.transfer,
          scope: GuardScope.internal(item: bundle),
          purpose: 'Backing up Evening loop',
        ),
      ]);
      // A save of the session waits for the copy, and no longer after it.
      expect(saveRefusedDuring, everyElement(isTrue));
      expect(
        guards.blockers(
          GuardKind.sessionWrite,
          GuardScope.internal(item: bundle),
        ),
        isEmpty,
      );
      expect(guards.active, isEmpty);
      expect(
        cubit.state.backup,
        const LibraryBackupDone(id: id, name: 'Evening loop'),
      );
    });

    test('reports its progress inline while it copies', () async {
      final cubit = await selected();
      final seen = <double>[];
      final sub = cubit.stream.listen((s) {
        if (s.backup case LibraryBackupRunning(:final fraction)) {
          seen.add(fraction);
        }
      });
      addTearDown(sub.cancel);

      await backUp(cubit);
      await pumpEventQueue();

      expect(seen, [0, 0.25, 0.5, 0.75, 1]);
    });

    test('a backup already on the drive asks first, writing nothing; Keep '
        'both lands beside it', () async {
      existingBackup(id);
      final cubit = await selected();

      await backUp(cubit);

      expect(
        cubit.state.backup,
        const LibraryBackupConflict(id: id, name: 'Evening loop'),
      );
      expect(drive.copies, isEmpty);

      await cubit.resolveBackupConflict(ConflictPolicy.keepBoth);

      expect(drive.files, contains('Segno/Sessions/$id (2)/session.json'));
      expect(
        File(
          '${drive.mount}/Segno/Sessions/$id/session.json',
        ).readAsBytesSync(),
        [9],
      );
    });

    test('Cancel on the question leaves everything as it was', () async {
      existingBackup(id);
      final cubit = await selected();
      await backUp(cubit);

      cubit.cancelBackup();

      expect(cubit.state.backup, isNull);
      expect(drive.files, ['Segno/Sessions/$id/session.json']);
    });

    test('Replace keeps the old backup when the new copy fails, and Retry '
        'replaces it once the copy lands', () async {
      existingBackup(id);
      final cubit = await selected();
      await backUp(cubit);
      drive
        ..failOnCopy = 3
        ..failure = const StorageFailure.volumeLost(3);

      await cubit.resolveBackupConflict(ConflictPolicy.replace);

      expect(
        cubit.state.backup,
        const LibraryBackupInterrupted(
          id: id,
          name: 'Evening loop',
          problem: LibraryBackupProblem.driveLost,
        ),
      );
      expect(drive.files, ['Segno/Sessions/$id/session.json']);
      expect(
        File(
          '${drive.mount}/Segno/Sessions/$id/session.json',
        ).readAsBytesSync(),
        [9],
      );

      drive.failOnCopy = null;
      await cubit.retryBackup();

      expect(drive.copies.last.policy, ConflictPolicy.replace);
      expect(drive.files, hasLength(files.length));
      expect(
        File(
          '${drive.mount}/Segno/Sessions/$id/session.json',
        ).readAsBytesSync(),
        [3, 3],
      );
      expect(cubit.state.backup, isA<LibraryBackupDone>());
    });

    for (final (failure, problem) in <(Exception, LibraryBackupProblem)>[
      (const StorageFailure.volumeLost(3), LibraryBackupProblem.driveLost),
      (const StorageFailure.full(), LibraryBackupProblem.full),
      (const StorageFailure.readOnly(), LibraryBackupProblem.readOnly),
      (const StorageFailure.io('bad sector'), LibraryBackupProblem.failed),
    ]) {
      test('$failure on the third file leaves nothing on the drive and '
          'reads ${problem.name}', () async {
        final cubit = await selected();
        drive
          ..failOnCopy = 3
          ..failure = failure;

        await backUp(cubit);

        expect(drive.files, isEmpty);
        expect(
          cubit.state.backup,
          isA<LibraryBackupInterrupted>().having(
            (b) => b.problem,
            'problem',
            problem,
          ),
        );
        expect(guards.active, isEmpty);
      });
    }

    test('Cancel between files removes what was placed', () async {
      final cubit = await selected();
      drive.beforeCopy = (n) {
        if (n == 2) cubit.cancelBackup();
      };

      await backUp(cubit);

      expect(drive.copies, hasLength(2));
      expect(drive.files, isEmpty);
      expect(cubit.state.backup, isNull);
    });

    test('without a drive it asks for one, and Retry backs up once one is '
        'there', () async {
      drive.present = false;
      final cubit = await selected();

      await backUp(cubit);

      expect(
        cubit.state.backup,
        isA<LibraryBackupInterrupted>().having(
          (b) => b.problem,
          'problem',
          LibraryBackupProblem.noDrive,
        ),
      );
      drive.present = true;
      await cubit.retryBackup();
      expect(cubit.state.backup, isA<LibraryBackupDone>());
    });

    test('a read-only drive is refused before any copy', () async {
      drive.status = RemovableVolumeStatus.readOnly;
      final cubit = await selected();

      await backUp(cubit);

      expect(
        cubit.state.backup,
        isA<LibraryBackupInterrupted>().having(
          (b) => b.problem,
          'problem',
          LibraryBackupProblem.readOnly,
        ),
      );
      expect(drive.copies, isEmpty);
    });

    test('the guard table refuses it during a shutdown, naming it', () async {
      final restart = guards.enter(
        GuardKind.restart,
        const GuardScope.internal(),
        purpose: 'restart',
      );
      addTearDown(restart.release);
      final cubit = await selected();

      await backUp(cubit);

      expect(
        cubit.state.backup,
        const LibraryBackupInterrupted(
          id: id,
          name: 'Evening loop',
          problem: LibraryBackupProblem.busy,
          blockedBy: GuardKind.restart,
        ),
      );
      expect(drive.copies, isEmpty);
      expect(guards.active, [restart.operation]);
    });

    test('a second press while it runs is ignored', () async {
      final cubit = await selected();
      final hold = Completer<void>();
      drive.hold = hold;

      final first = backUp(cubit);
      await pumpEventQueue();
      await backUp(cubit);
      hold.complete();
      await first;

      expect(drive.leases, hasLength(1));
    });
  });

  group('the USB list', () {
    const backups = [
      SessionSummary(id: 's-a', name: 'Evening loop'),
      SessionSummary(id: 's-b', name: 'Acoustic set'),
    ];

    test("the USB location reads the drive's backups, and a drive change "
        'reads them again', () async {
      when(() => sessions.listBackups(any())).thenReturn(backups);
      final cubit = await selected();

      cubit.setLocation(LibraryLocation.usb);

      expect(cubit.state.backups, backups);
      verify(
        () => sessions.listBackups('${drive.mount}/Segno/Sessions'),
      ).called(1);

      cubit.selectBackup('s-b');
      drive.announce();
      await pumpEventQueue();
      verify(() => sessions.listBackups(any())).called(1);
      expect(cubit.state.selectedBackup, 's-b');

      when(() => sessions.listBackups(any())).thenReturn(const []);
      cubit.loadBackups();
      expect(cubit.state.selectedBackup, isNull);
    });

    test('lists nothing without a readable drive', () async {
      drive.present = false;
      final cubit = await selected();

      cubit.setLocation(LibraryLocation.usb);

      expect(cubit.state.backups, isEmpty);
      verifyNever(() => sessions.listBackups(any()));
    });

    test('Restore to Library adds the backup and shows it selected in '
        'Internal', () async {
      when(() => sessions.listBackups(any())).thenReturn(backups);
      when(
        () => sessions.restoreFrom(any()),
      ).thenAnswer((_) async => 's-restored');
      final cubit = await selected();
      cubit
        ..setLocation(LibraryLocation.usb)
        ..selectBackup('s-a');

      await cubit.restore();

      verify(
        () => sessions.restoreFrom('${drive.mount}/Segno/Sessions/s-a'),
      ).called(1);
      expect(cubit.state.location, LibraryLocation.internal);
      expect(cubit.state.restoredId, 's-restored');
      expect(cubit.state.selectedId, 's-restored');
      expect(cubit.state.preview?.summary.id, 's-restored');
    });

    for (final (refusal, error) in <(Object, LibraryRestoreError)>[
      (
        const GuardRefused(wants: GuardKind.sessionWrite, blockers: []),
        LibraryRestoreError.busy,
      ),
      (const FileSystemException('gone'), LibraryRestoreError.failed),
    ]) {
      test('a restore that throws $refusal reads ${error.name} and stays on '
          'the drive', () async {
        when(() => sessions.listBackups(any())).thenReturn(backups);
        when(() => sessions.restoreFrom(any())).thenThrow(refusal);
        final cubit = await selected();
        cubit
          ..setLocation(LibraryLocation.usb)
          ..selectBackup('s-a');

        await cubit.restore();

        expect(cubit.state.restoreError, error);
        expect(cubit.state.location, LibraryLocation.usb);

        cubit.selectBackup('s-b');
        expect(cubit.state.restoreError, isNull);
      });
    }

    test('Restore without a selection does nothing', () async {
      final cubit = await selected();
      cubit.setLocation(LibraryLocation.usb);

      await cubit.restore();

      verifyNever(() => sessions.restoreFrom(any()));
    });
  });
}
