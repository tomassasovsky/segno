import 'package:flutter_test/flutter_test.dart';
import 'package:segno/performance/cubit/recording_destination_cubit.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../../storage/helpers/storage_rig.dart';

void main() {
  group(RecordingDestinationCubit, () {
    late StorageRig rig;
    late RecordingDestinationCubit cubit;
    var rate = 48000;

    const internal = StorageDestination.internal();
    const usb1 = StorageDestination.removable(1);

    Future<RecordingDestinationCubit> build({
      List<RemovableVolumeRecord> volumes = const [],
    }) async {
      rig = StorageRig(volumes: volumes);
      rig.spaces[mountPoint(1)] = const VolumeSpace(
        totalBytes: usbTotal,
        freeBytes: usbFree,
      );
      rate = 48000;
      await pumpEventQueue();
      cubit = RecordingDestinationCubit(
        repository: rig.repository,
        sampleRate: () => rate,
      );
      await pumpEventQueue();
      return cubit;
    }

    tearDown(() async {
      await cubit.close();
      await rig.dispose();
    });

    test('starts on Internal with the time a take fits there: the pen 60 hr '
        '45 min at 48 kHz 24-bit stereo after the reserve', () async {
      await build();
      expect(cubit.state.destination, internal);
      expect(cubit.state.bytesPerSecond, 288000);
      expect(
        cubit.state.remaining,
        const Duration(hours: 60, minutes: 45, seconds: 50),
      );
    });

    test('no applied rate claims no time', () async {
      await build();
      rate = 0;
      await cubit.refresh();
      expect(cubit.state.remaining, isNull);
      expect(cubit.state.bytesPerSecond, 0);
    });

    test(
      "a mounted drive can be chosen, and the time is the drive's",
      () async {
        await build(volumes: [usbRecord(1)]);

        await cubit.choose(usb1);

        expect(cubit.state.destination, usb1);
        expect(
          cubit.state.remaining,
          const Duration(seconds: usbFree ~/ 288000),
        );
      },
    );

    test('a drive that cannot take a recording is not chosen', () async {
      await build(
        volumes: [
          usbRecord(1, status: RemovableVolumeRecordStatus.readOnly),
        ],
      );

      await cubit.choose(usb1);
      await cubit.choose(const StorageDestination.removable(9));

      expect(cubit.state.destination, internal);
    });

    test('the chosen drive going puts the choice back on Internal', () async {
      await build(volumes: [usbRecord(1)]);
      await cubit.choose(usb1);

      rig.client.detach(1);
      await pumpEventQueue();

      expect(cubit.state.destination, internal);
      expect(cubit.state.volumes, isEmpty);
    });

    test('waiting for a drive chooses the next one mounted, and only one '
        'that can take a recording', () async {
      await build();

      cubit.awaitDrive();
      expect(cubit.state.awaitingDrive, isTrue);

      rig.client.attach(
        usbRecord(2, status: RemovableVolumeRecordStatus.readOnly),
      );
      await pumpEventQueue();
      expect(cubit.state.destination, internal);
      expect(cubit.state.awaitingDrive, isTrue);

      rig.client.attach(usbRecord(1));
      await pumpEventQueue();
      expect(cubit.state.destination, usb1);
      expect(cubit.state.awaitingDrive, isFalse);
    });

    test(
      'a drive is chosen only once its write probe lands fast enough: '
      'never while it is being measured, never when it is too slow',
      () async {
        await build();
        cubit.awaitDrive();

        rig.client.attach(usbRecord(1, writeBytesPerSecond: null));
        await pumpEventQueue();
        expect(cubit.state.destination, internal, reason: 'still measuring');
        expect(cubit.state.awaitingDrive, isTrue);
        await cubit.choose(usb1);
        expect(cubit.state.destination, internal);

        // 2 x 288000 B/s at 48 kHz 24-bit stereo is the bar.
        rig.client.update(usbRecord(1, writeBytesPerSecond: 576000 - 1));
        await pumpEventQueue();
        expect(cubit.state.destination, internal, reason: 'too slow');

        rig.client.update(usbRecord(1, writeBytesPerSecond: 576000));
        await pumpEventQueue();
        expect(cubit.state.destination, usb1);
        expect(cubit.state.awaitingDrive, isFalse);
      },
    );

    test('the chosen drive going is said once, with its label', () async {
      await build(volumes: [usbRecord(1)]);
      await cubit.choose(usb1);
      final states = <RecordingDestinationState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      rig.client.detach(1);
      await pumpEventQueue();

      expect(
        states.where((s) => s.fellBackFrom != null).map((s) => s.fellBackFrom),
        ['SEGNO USB'],
      );
      expect(cubit.state.fellBackFrom, isNull, reason: 'one state only');
    });

    test('Try again chooses a drive that is already there; a cancel stops '
        'the wait and a later plug is not chosen', () async {
      await build(volumes: [usbRecord(1)]);
      cubit.awaitDrive();
      await pumpEventQueue();
      expect(cubit.state.destination, usb1);
      expect(cubit.state.awaitingDrive, isFalse);

      await cubit.choose(internal);
      rig.client.detach(1);
      await pumpEventQueue();
      cubit
        ..awaitDrive()
        ..stopAwaitingDrive();
      rig.client.attach(usbRecord(1));
      await pumpEventQueue();
      expect(cubit.state.destination, internal);
    });
  });
}
