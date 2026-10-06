import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../helpers/storage_rig.dart';

void main() {
  group(StorageCubit, () {
    late StorageRig rig;
    late StorageCubit cubit;
    var sampleRate = 48000;
    // A cubit built inside fakeAsync is closed there too: its stream cancels
    // need that zone's microtasks.
    var closedInZone = false;

    StorageCubit build({
      List<RemovableVolumeRecord> volumes = const [],
      Duration ejectServedTimeout = const Duration(minutes: 2),
    }) {
      rig = StorageRig(
        volumes: volumes,
        ejectServedTimeout: ejectServedTimeout,
      );
      sampleRate = 48000;
      return cubit = StorageCubit(
        repository: rig.repository,
        sampleRate: () => sampleRate,
      );
    }

    setUp(() => closedInZone = false);

    tearDown(() async {
      if (closedInZone) return;
      await cubit.close();
      await rig.dispose();
    });

    void closeInZone(FakeAsync async) {
      unawaited(cubit.close());
      unawaited(rig.dispose());
      async.flushMicrotasks();
      closedInZone = true;
    }

    test('Internal at the pen numbers: 60 hr 45 min at 48 kHz 24-bit stereo '
        'after the 1 GB reserve; not low', () async {
      build();
      await cubit.refresh();

      expect(
        cubit.state.internalSpace,
        const VolumeSpace(totalBytes: internalTotal, freeBytes: internalFree),
      );
      expect(cubit.state.sampleRate, 48000);
      expect(
        cubit.state.recordingTime,
        const Duration(hours: 60, minutes: 45, seconds: 50),
      );
      expect(cubit.state.lowInternalSpace, isFalse);
    });

    test('below the reserve: low, and no recording time', () async {
      build();
      rig.internal(free: 200000000);
      await cubit.refresh();

      expect(cubit.state.lowInternalSpace, isTrue);
      expect(cubit.state.recordingTime, Duration.zero);
    });

    test('unknown capacity, or no applied rate, claims no time; unknown is '
        'not low', () async {
      build();
      rig.internal();
      await cubit.refresh();
      expect(cubit.state.internalSpace, isNull);
      expect(cubit.state.recordingTime, isNull);
      expect(cubit.state.lowInternalSpace, isFalse);

      rig.internal(free: internalFree);
      sampleRate = 0;
      await cubit.refresh();
      expect(cubit.state.internalSpace, isNotNull);
      expect(cubit.state.recordingTime, isNull);
    });

    test('each mounted volume is measured, and its lease holders are '
        'named, each purpose once', () async {
      build(volumes: [usbRecord(1), usbRecord(2)]);
      rig.spaces[mountPoint(1)] = const VolumeSpace(
        totalBytes: usbTotal,
        freeBytes: usbFree,
      );
      await pumpEventQueue();
      rig.repository
        ..acquire(const StorageDestination.removable(2), WritePurpose.copy)
        ..acquire(const StorageDestination.removable(2), WritePurpose.copy)
        ..acquire(const StorageDestination.removable(2), WritePurpose.export);
      await cubit.refresh();

      expect(cubit.state.volumes.map((v) => v.generation), [1, 2]);
      expect(cubit.state.volumeSpace, {
        1: const VolumeSpace(totalBytes: usbTotal, freeBytes: usbFree),
      });
      expect(cubit.state.holders, {
        2: {WritePurpose.copy, WritePurpose.export},
      });
    });

    test('statvfs is read on open, on every volume event and every 5 s while '
        'watching, and never after', () {
      fakeAsync((async) {
        build();
        async.flushMicrotasks();
        final atRest = rig.reads;

        // No page, no timer: an hour passes without a read.
        async.elapse(const Duration(hours: 1));
        expect(rig.reads, atRest);

        cubit.startWatching();
        async.flushMicrotasks();
        final opened = rig.reads;
        expect(opened, greaterThan(atRest), reason: 'a read on open');

        async.elapse(const Duration(seconds: 5));
        final ticked = rig.reads;
        expect(ticked, greaterThan(opened), reason: 'a read at 5 s');

        rig.client.attach(usbRecord(1));
        async.flushMicrotasks();
        expect(rig.reads, greaterThan(ticked), reason: 'a read on the plug');

        cubit.stopWatching();
        async.flushMicrotasks();
        final stopped = rig.reads;
        async.elapse(const Duration(minutes: 1));
        expect(rig.reads, stopped, reason: 'no timer once the page is gone');

        // Volume events still re-read: shutdown and the picker read state
        // outside the page.
        rig.client.detach(1);
        async.flushMicrotasks();
        expect(rig.reads, greaterThan(stopped));

        closeInZone(async);
      });
    });

    test('a watch started twice keeps one timer', () {
      fakeAsync((async) {
        build();
        async.flushMicrotasks();
        var mark = rig.reads;
        unawaited(cubit.refresh());
        async.flushMicrotasks();
        final perRefresh = rig.reads - mark;

        cubit
          ..startWatching()
          ..startWatching();
        async.flushMicrotasks();
        mark = rig.reads;
        async.elapse(const Duration(seconds: 5));
        // One tick's reads, not two ticks' worth.
        expect(rig.reads - mark, perRefresh);
        closeInZone(async);
      });
    });

    test('eject files a request and the volume reads ejected once the '
        'helper says so', () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();

      final ejecting = cubit.eject(1);
      await pumpEventQueue();
      expect(rig.client.pendingRequests, {'req-1': 1});
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejecting);
      expect(rig.repository.transferInFlight, isTrue);

      // A second tap while one is in flight files nothing.
      await cubit.eject(1);
      expect(rig.client.pendingRequests, hasLength(1));

      rig.client.settleEject('req-1', ok: true);
      await ejecting;
      await pumpEventQueue();
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejected);
      expect(cubit.state.ejectFailed, isNull);
      expect(rig.repository.transferInFlight, isFalse);
    });

    test('a refused eject is remembered for the drive until the next try or '
        'until the drive goes', () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();

      final first = cubit.eject(1);
      await pumpEventQueue();
      rig.client.settleEject('req-1', ok: false, reason: 'busy');
      await first;
      await pumpEventQueue();
      expect(cubit.state.ejectFailed, 1);
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.mounted);

      // A plug of another drive keeps it.
      rig.client.attach(usbRecord(2));
      await pumpEventQueue();
      expect(cubit.state.ejectFailed, 1);

      // Trying again clears it while the request is out.
      final second = cubit.eject(1);
      await pumpEventQueue();
      expect(cubit.state.ejectFailed, isNull);
      rig.client.settleEject('req-2', ok: false, reason: 'busy');
      await second;
      expect(cubit.state.ejectFailed, 1);

      rig.client.detach(1);
      await pumpEventQueue();
      expect(cubit.state.ejectFailed, isNull);
    });

    test('eject does nothing while a lease holds the drive: the '
        "repository's refusal is caught and the holders are read", () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();
      rig.repository.acquire(
        const StorageDestination.removable(1),
        WritePurpose.recording,
      );

      await cubit.eject(1);

      expect(rig.client.pendingRequests, isEmpty);
      expect(cubit.state.holders, {
        1: {WritePurpose.recording},
      });
      expect(cubit.state.ejectFailed, isNull);
      expect(rig.repository.transferInFlight, isTrue);
    });

    test('cancel withdraws an unserved request', () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();

      final ejecting = cubit.eject(1);
      await pumpEventQueue();
      await cubit.cancelEject();
      await ejecting;
      await pumpEventQueue();

      expect(rig.client.pendingRequests, isEmpty);
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.mounted);
      expect(cubit.state.ejectFailed, isNull);
      expect(cubit.state.ejectTaken, isFalse);
    });

    test('a cancel after the helper took the eject says it cannot be '
        'stopped, until the drive answers', () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();

      final ejecting = cubit.eject(1);
      await pumpEventQueue();
      rig.client.take('req-1');
      await cubit.cancelEject();

      expect(cubit.state.ejectTaken, isTrue);
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejecting);

      rig.client.settleEject('req-1', ok: true);
      await ejecting;
      await pumpEventQueue();
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejected);
      expect(cubit.state.ejectTaken, isFalse);
    });

    test('a drive that turns ejected after a failed eject is no longer '
        'reported as failed', () async {
      build(volumes: [usbRecord(1)]);
      await pumpEventQueue();

      final ejecting = cubit.eject(1);
      await pumpEventQueue();
      rig.client.settleEject('req-1', ok: false, reason: 'busy');
      await ejecting;
      await pumpEventQueue();
      expect(cubit.state.ejectFailed, 1);

      // The drive reads ejected after all (a late answer, or another eject).
      rig.client.update(
        usbRecord(1, status: RemovableVolumeRecordStatus.ejected),
      );
      await pumpEventQueue();

      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejected);
      expect(cubit.state.ejectFailed, isNull);
    });

    test('an eject the helper took and has not answered is not reported as '
        'failed: the drive stays Ejecting', () async {
      build(
        volumes: [usbRecord(1)],
        ejectServedTimeout: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();

      final ejecting = cubit.eject(1);
      await pumpEventQueue();
      rig.client.take('req-1');
      await ejecting;
      await pumpEventQueue();

      expect(cubit.state.ejectFailed, isNull);
      expect(cubit.state.volumes.single.status, RemovableVolumeStatus.ejecting);
    });
  });
}
