import 'package:flutter_test/flutter_test.dart';
import 'package:segno/library/application/removable_volumes.dart';

void main() {
  group(InternalOnlyVolumes, () {
    const volumes = InternalOnlyVolumes();

    test('reports no drive, now or later', () async {
      expect(volumes.current, isEmpty);
      expect(await volumes.volumes.toList(), isEmpty);
    });

    test('knows no space', () async {
      expect(await volumes.space(const StorageDestination.internal()), isNull);
      expect(
        await volumes.space(const StorageDestination.removable(1)),
        isNull,
      );
    });

    test('refuses every removable write as unsupported', () async {
      await expectLater(
        volumes.copyFile(
          '/a.wav',
          const StorageDestination.removable(1),
          'Segno/a.wav',
          onConflict: ConflictPolicy.ask,
        ),
        throwsA(isA<StorageUnsupported>()),
      );
      await expectLater(
        volumes.withWriteLease(
          const StorageDestination.removable(1),
          'Exporting a',
          (_) async => 0,
        ),
        throwsA(isA<StorageUnsupported>()),
      );
    });
  });

  group('the port model', () {
    test('destinations compare by value', () {
      expect(
        const StorageDestination.removable(2),
        const StorageDestination.removable(2),
      );
      expect(
        const StorageDestination.removable(2),
        isNot(const StorageDestination.removable(3)),
      );
      expect(
        const StorageDestination.internal(),
        const InternalDestination(),
      );
    });

    test('a lease carries its target and purpose', () {
      const lease = WriteLease(
        target: StorageDestination.removable(1),
        purpose: 'Backing up Evening loop',
      );
      expect(
        lease,
        const WriteLease(
          target: RemovableDestination(1),
          purpose: 'Backing up Evening loop',
        ),
      );
      expect(
        const VolumeSpace(totalBytes: 2, freeBytes: 1),
        const VolumeSpace(totalBytes: 2, freeBytes: 1),
      );
    });

    test('failures and conflicts describe themselves', () {
      expect(const StorageFailure.full().toString(), contains('full'));
      expect(const StorageFailure.readOnly().toString(), contains('read-only'));
      expect(const StorageFailure.volumeLost(3).toString(), contains('3'));
      expect(
        const StorageFailure.unsupported().toString(),
        contains('not supported'),
      );
      expect(const StorageFailure.io('EIO').toString(), contains('EIO'));
      expect(const NameConflict('/m/a.wav').toString(), contains('/m/a.wav'));
    });

    test(
      'only a mounted or read-only drive with a mount point is readable',
      () {
        RemovableVolume volume(RemovableVolumeStatus status, {String? mount}) =>
            RemovableVolume(
              generation: 1,
              fingerprint: 'f',
              label: 'L',
              fsType: 'vfat',
              sizeBytes: 1,
              status: status,
              mountPoint: mount,
            );
        expect(
          volume(RemovableVolumeStatus.mounted, mount: '/m').readable,
          isTrue,
        );
        expect(
          volume(RemovableVolumeStatus.readOnly, mount: '/m').readable,
          isTrue,
        );
        expect(volume(RemovableVolumeStatus.mounted).readable, isFalse);
        expect(
          volume(RemovableVolumeStatus.ejecting, mount: '/m').readable,
          isFalse,
        );
      },
    );
  });
}
