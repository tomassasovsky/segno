import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import 'helpers/harness.dart';

/// `StorageRepository.copyUpdatePackage` (#1270 Part 8): an update package
/// copied off a drive, read-only or not, into the staging directory, under a
/// read hold on the drive and a copy lease on Internal.
void main() {
  late Harness h;
  late StorageRepository repo;

  setUp(() => h = Harness());
  tearDown(() async {
    await repo.dispose();
    h.dispose();
  });

  String staging() => '${h.root.path}/staging';

  File package(int generation, {int bytes = 4096}) {
    final file = File('${h.mountPoint(generation)}/segno-0.7.0.raucb')
      ..writeAsBytesSync(List<int>.filled(bytes, 7));
    return file;
  }

  test('a read-only drive serves the package: the hold is taken, eject is '
      'refused while it is held, and the copy lands whole', () async {
    final seen = <String>[];
    Object? ejectRefusal;
    repo = h.build(
      initial: [h.record(1, status: RemovableVolumeRecordStatus.readOnly)],
      copyBytes: (from, part, shouldAbort) async {
        seen.add(
          [
            for (final lease in repo.leases)
              '${lease.purpose.name}@${lease.target}',
          ].join(' '),
        );
        try {
          await repo.eject(1);
        } on EjectRefused catch (e) {
          ejectRefusal = e;
        }
        await part.writeAsBytes(await from.readAsBytes(), flush: true);
      },
    );
    await pumpEventQueue();
    final source = package(1);

    final written = await repo.copyUpdatePackage(
      generation: 1,
      sourcePath: source.path,
      stagingDirectory: staging(),
    );

    expect(written, '${staging()}/segno-0.7.0.raucb');
    const usb = StorageDestination.removable(1);
    const internal = StorageDestination.internal();
    expect(seen, ['update@$usb copy@$internal']);
    expect(ejectRefusal, isA<EjectRefused>());
    expect(File(written).readAsBytesSync(), source.readAsBytesSync());
    expect(h.filesUnder(staging()), ['segno-0.7.0.raucb']);
    expect(h.synced, [staging()]);
    expect(repo.leases, isEmpty);
  });

  test('a read-only drive keeps serving when another drive comes and '
      'goes', () async {
    repo = h.build(
      initial: [h.record(1, status: RemovableVolumeRecordStatus.readOnly)],
      copyBytes: (from, part, shouldAbort) async {
        h.client.attach(h.record(2));
        await pumpEventQueue();
        if (shouldAbort()) throw const FileSystemException('aborted');
        await part.writeAsBytes(await from.readAsBytes(), flush: true);
      },
    );
    await pumpEventQueue();
    final source = package(1);

    final written = await repo.copyUpdatePackage(
      generation: 1,
      sourcePath: source.path,
      stagingDirectory: staging(),
    );
    expect(File(written).existsSync(), isTrue);
  });

  test('a staging path that cannot be made is a typed failure', () async {
    repo = h.build(initial: [h.record(1)]);
    await pumpEventQueue();
    File(staging()).writeAsStringSync('in the way');
    final source = package(1);

    await expectLater(
      repo.copyUpdatePackage(
        generation: 1,
        sourcePath: source.path,
        stagingDirectory: '${staging()}/inside',
      ),
      throwsA(isA<StorageFailure>()),
    );
    expect(repo.leases, isEmpty);
  });

  test('a drive pulled mid-copy is volumeLost and leaves no part', () async {
    repo = h.build(
      initial: [h.record(1)],
      copyBytes: (from, part, shouldAbort) async {
        part.writeAsBytesSync([1, 2, 3], flush: true);
        h.client.detach(1);
        await pumpEventQueue();
        if (shouldAbort()) throw const FileSystemException('aborted');
      },
    );
    await pumpEventQueue();
    final source = package(1);

    await expectLater(
      repo.copyUpdatePackage(
        generation: 1,
        sourcePath: source.path,
        stagingDirectory: staging(),
      ),
      throwsA(const StorageFailure.volumeLost(1)),
    );
    expect(h.filesUnder(staging()), isEmpty);
    expect(repo.leases, isEmpty);
  });

  test('a full Internal (ENOSPC) is full and leaves no part', () async {
    repo = h.build(
      initial: [h.record(1)],
      copyBytes: (from, part, shouldAbort) async {
        part.writeAsBytesSync([1, 2, 3], flush: true);
        throw osError(28, 'No space left on device');
      },
    );
    await pumpEventQueue();
    final source = package(1);

    await expectLater(
      repo.copyUpdatePackage(
        generation: 1,
        sourcePath: source.path,
        stagingDirectory: staging(),
      ),
      throwsA(const StorageFailure.full()),
    );
    expect(h.filesUnder(staging()), isEmpty);
  });

  test('a take recording to Internal refuses the copy before a byte is '
      'written', () async {
    final guards = GuardRegistry();
    repo = h.build(initial: [h.record(1)], guards: guards);
    await pumpEventQueue();
    final take = guards.enter(
      GuardKind.capture,
      const GuardScope.internal(),
      purpose: 'take',
    );
    addTearDown(take.release);
    final source = package(1);

    await expectLater(
      repo.copyUpdatePackage(
        generation: 1,
        sourcePath: source.path,
        stagingDirectory: staging(),
      ),
      throwsA(const StorageFailure.busy(GuardKind.capture)),
    );
    expect(Directory(staging()).existsSync(), isFalse);
    expect(repo.leases, isEmpty);
  });

  test('a drive that is not there is volumeLost', () async {
    repo = h.build();
    await expectLater(
      repo.copyUpdatePackage(
        generation: 3,
        sourcePath: '/nowhere/segno.raucb',
        stagingDirectory: staging(),
      ),
      throwsA(const StorageFailure.volumeLost(3)),
    );
  });

  test('a part a crash left in staging is swept by the next copy', () async {
    repo = h.build(initial: [h.record(1)]);
    await pumpEventQueue();
    Directory(staging()).createSync(recursive: true);
    File(
      '${staging()}/.segno-0.6.0.raucb.0123456789abcdef.part',
    ).writeAsStringSync('half');
    final source = package(1);

    await repo.copyUpdatePackage(
      generation: 1,
      sourcePath: source.path,
      stagingDirectory: staging(),
    );

    expect(h.filesUnder(staging()), ['segno-0.7.0.raucb']);
  });

  group('the paths a copy can fail by', () {
    Future<void> expectCopy(Matcher matcher, {bool Function()? cancelled}) =>
        expectLater(
          repo.copyUpdatePackage(
            generation: 1,
            sourcePath: package(1).path,
            stagingDirectory: staging(),
            cancelled: cancelled,
          ),
          matcher,
        );

    test(
      'a cancel that lands as the last byte is written still cancels',
      () async {
        var cancel = false;
        repo = h.build(
          initial: [h.record(1)],
          copyBytes: (from, part, shouldAbort) async {
            await part.writeAsBytes(await from.readAsBytes(), flush: true);
            cancel = true;
          },
        );
        await pumpEventQueue();
        await expectCopy(
          throwsA(const StorageFailure.io('cancelled')),
          cancelled: () => cancel,
        );
        expect(h.filesUnder(staging()), isEmpty);
      },
    );

    test(
      'a write the cancel interrupted is a cancel, not an io error',
      () async {
        repo = h.build(
          initial: [h.record(1)],
          copyBytes: (from, part, shouldAbort) async {
            if (shouldAbort()) throw const FileSystemException('aborted');
          },
        );
        await pumpEventQueue();
        await expectCopy(
          throwsA(const StorageFailure.io('cancelled')),
          cancelled: () => true,
        );
      },
    );

    test('a source read broken by the drive leaving is volumeLost', () async {
      repo = h.build(
        initial: [h.record(1)],
        copyBytes: (from, part, shouldAbort) async {
          h.client.detach(1);
          await pumpEventQueue();
          throw SourceReadFailure(osError(5, 'Input/output error'));
        },
      );
      await pumpEventQueue();
      await expectCopy(throwsA(const StorageFailure.volumeLost(1)));
      expect(h.filesUnder(staging()), isEmpty);
    });

    test('a source that cannot be read on a present drive is io', () async {
      repo = h.build(
        initial: [h.record(1)],
        volumeLossGrace: const Duration(milliseconds: 10),
        copyBytes: (from, part, shouldAbort) async =>
            throw SourceReadFailure(osError(5, 'Input/output error')),
      );
      await pumpEventQueue();
      await expectCopy(throwsA(const StorageFailure.io('Input/output error')));
      expect(h.filesUnder(staging()), isEmpty);
    });
  });
}
