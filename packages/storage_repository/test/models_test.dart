import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:storage_repository/storage_repository.dart';

/// Every pair in [values] is equal exactly when the indices are, and equal
/// values hash alike, so the values key maps and sets.
void expectValueSemantics(List<Object> values, List<int> identity) {
  for (var i = 0; i < values.length; i++) {
    for (var j = 0; j < values.length; j++) {
      expect(
        values[i] == values[j],
        identity[i] == identity[j],
        reason: '${values[i]} vs ${values[j]}',
      );
    }
  }
  expect({
    for (final value in values) value,
  }, hasLength(identity.toSet().length));
}

void main() {
  test('destinations: Internal is one place, a volume is its generation', () {
    expectValueSemantics(
      const [
        StorageDestination.internal(),
        StorageDestination.internal(),
        StorageDestination.removable(1),
        StorageDestination.removable(1),
        StorageDestination.removable(2),
      ],
      [0, 0, 1, 1, 2],
    );
  });

  test('failures tell their kinds apart', () {
    expectValueSemantics(
      const [
        StorageFailure.full(),
        StorageFailure.readOnly(),
        StorageFailure.volumeLost(1),
        StorageFailure.volumeLost(1),
        StorageFailure.volumeLost(2),
        StorageFailure.unsupported(),
        StorageFailure.io('a'),
        StorageFailure.io('b'),
      ],
      [0, 1, 2, 2, 3, 4, 5, 6],
    );
    expect(const StorageFailure.volumeLost(3), isA<Exception>());
  });

  test('eject outcomes tell their kinds apart', () {
    expectValueSemantics(
      const [
        EjectOutcome.safeToRemove(),
        EjectOutcome.cancelled(),
        EjectOutcome.failed('busy'),
        EjectOutcome.failed('busy'),
        EjectOutcome.failed('timeout'),
      ],
      [0, 1, 2, 2, 3],
    );
  });

  test('a volume is readable when it is mounted, read-write or read-only, '
      'and has a mount point', () {
    RemovableVolume volume(RemovableVolumeStatus status, {String? at = '/m'}) =>
        RemovableVolume(
          generation: 1,
          fingerprint: 'f',
          label: 'L',
          fsType: 'vfat',
          sizeBytes: 1,
          status: status,
          mountPoint: at,
        );
    expect(volume(RemovableVolumeStatus.mounted).readable, isTrue);
    expect(volume(RemovableVolumeStatus.readOnly).readable, isTrue);
    expect(volume(RemovableVolumeStatus.ejecting).readable, isFalse);
    expect(volume(RemovableVolumeStatus.ejected).readable, isFalse);
    expect(volume(RemovableVolumeStatus.mounted, at: null).readable, isFalse);
  });

  test('failures and conflicts say what happened, in the words the Library '
      'prints', () {
    expect('${const StorageFailure.full()}', 'the destination is full');
    expect(
      '${const StorageFailure.readOnly()}',
      'the destination is read-only',
    );
    expect('${const StorageFailure.volumeLost(3)}', 'drive 3 was removed');
    expect(
      '${const StorageFailure.unsupported()}',
      'the destination is not supported',
    );
    expect('${const StorageFailure.io('EIO')}', 'storage I/O failed: EIO');
    expect(
      '${const StorageFailure.busy(GuardKind.restart)}',
      'busy: restart is in flight',
    );
    expect(
      const StorageFailure.busy(GuardKind.capture),
      isNot(const StorageFailure.busy(GuardKind.restart)),
    );
    expect(
      '${const StorageFailure.io('EIO', writtenTo: '/media/1/take.wav')}',
      'copied to /media/1/take.wav, but the drive did not confirm it: EIO',
    );
    expect(
      '${const NameConflict('/m/a.wav')}',
      'a file already exists at /m/a.wav',
    );
  });

  test('a write lease is a const value: target and purpose', () {
    const a = WriteLease(
      target: StorageDestination.internal(),
      purpose: WritePurpose.copy,
    );
    expect(
      a,
      const WriteLease(
        target: StorageDestination.internal(),
        purpose: WritePurpose.copy,
      ),
    );
    expect(
      a,
      isNot(
        const WriteLease(
          target: StorageDestination.removable(1),
          purpose: WritePurpose.copy,
        ),
      ),
    );
  });
}
