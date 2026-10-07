import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import 'helpers/harness.dart';

void main() {
  late Harness h;
  late StorageRepository repo;
  // A repository built inside fakeAsync is disposed there too: its stream
  // cancels need that zone's microtasks.
  var disposed = false;

  const internal = StorageDestination.internal();
  const usb1 = StorageDestination.removable(1);

  setUp(() {
    h = Harness();
    disposed = false;
  });
  tearDown(() async {
    if (!disposed) await repo.dispose();
    h.dispose();
  });

  group('volumes', () {
    test('replays the current list to each listener, then every change, '
        'sorted by generation', () async {
      repo = h.build(initial: [h.record(2), h.record(1)]);
      await pumpEventQueue();
      final events = <List<RemovableVolume>>[];
      final sub = repo.volumes.listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      h.client.attach(
        h.record(3, status: RemovableVolumeRecordStatus.readOnly),
      );
      await pumpEventQueue();

      expect(events.first.map((v) => v.generation), [1, 2]);
      expect(
        events.first.first,
        RemovableVolume(
          generation: 1,
          fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
          label: 'SEGNO USB',
          fsType: 'exfat',
          mountPoint: h.mountPoint(1),
          sizeBytes: 32 * gib,
          status: RemovableVolumeStatus.mounted,
          writeBytesPerSecond: 16777216,
        ),
      );
      expect(events.last.map((v) => v.generation), [1, 2, 3]);
      expect(events.last.last.status, RemovableVolumeStatus.readOnly);
      expect(repo.current, events.last);
      expect(repo.isRemovableSupported, isTrue);

      // A late listener starts from the current list.
      expect((await repo.volumes.first).map((v) => v.generation), [1, 2, 3]);
    });

    test('every helper status maps, and an ejected volume stays listed until '
        'it is pulled', () async {
      repo = h.build(
        initial: [
          h.record(
            1,
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
          h.record(
            2,
            status: RemovableVolumeRecordStatus.mountFailed,
            mounted: false,
          ),
          h.record(3, status: RemovableVolumeRecordStatus.ejected),
        ],
      );
      await pumpEventQueue();

      expect(repo.current.map((v) => v.status), [
        RemovableVolumeStatus.unsupported,
        RemovableVolumeStatus.mountFailed,
        RemovableVolumeStatus.ejected,
      ]);
      h.client.detach(3);
      await pumpEventQueue();
      expect(repo.current.map((v) => v.generation), [1, 2]);
    });

    test('a cancelled listener hears nothing more; dispose ends the '
        'others', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      final cancelled = <List<RemovableVolume>>[];
      final sub = repo.volumes.listen(cancelled.add);
      await pumpEventQueue();
      await sub.cancel();

      final kept = Completer<void>();
      repo.volumes.listen(null, onDone: kept.complete);
      final phase = Completer<void>();
      repo.ejectPhase.listen(null, onDone: phase.complete);
      await pumpEventQueue();

      h.client.detach(1);
      await pumpEventQueue();
      expect(cancelled, hasLength(1));

      await repo.dispose();
      await kept.future;
      await phase.future;
    });
  });

  group('leases', () {
    test('settled completes at once when nothing is held, and otherwise '
        'only when the last lease is released', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      var idle = false;
      await repo.settled();

      final a = repo.acquire(internal, 'recording');
      final b = repo.acquire(usb1, 'export');
      unawaited(repo.settled().then((_) => idle = true));
      a.release();
      await pumpEventQueue();
      expect(idle, isFalse);

      b.release();
      await pumpEventQueue();
      expect(idle, isTrue);
    });

    test('Internal and a mounted volume lease; release gives them back, '
        'once', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final a = repo.acquire(internal, 'recording');
      final b = repo.acquire(usb1, 'export');

      expect(repo.leases, [a.lease, b.lease]);
      expect(repo.leasesOn(usb1), [
        const WriteLease(target: usb1, purpose: 'export'),
      ]);
      expect(repo.transferInFlight, isTrue);
      expect(b.target, usb1);
      expect(b.purpose, 'export');
      expect(a.isHeld, isTrue);

      a
        ..release()
        ..release();
      b.release();
      expect(repo.leases, isEmpty);
      expect(repo.transferInFlight, isFalse);
      expect(a.isHeld, isFalse);
      expect(a.isLost, isFalse);
    });

    test('a volume that cannot take a write refuses with the failure the '
        'write would meet', () async {
      const mountedWithoutPath = RemovableVolumeRecord(
        generation: 6,
        kname: 'sdf1',
        fingerprint: 'x',
        label: '',
        fsType: 'vfat',
        sizeBytes: 0,
        status: RemovableVolumeRecordStatus.mounted,
        readOnly: false,
      );
      repo = h.build(
        initial: [
          h.record(1, status: RemovableVolumeRecordStatus.readOnly),
          h.record(
            2,
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
          h.record(
            3,
            status: RemovableVolumeRecordStatus.mountFailed,
            mounted: false,
          ),
          h.record(4, status: RemovableVolumeRecordStatus.ejected),
          mountedWithoutPath,
        ],
      );
      await pumpEventQueue();

      void refused(int generation, StorageFailure failure) => expect(
        () => repo.acquire(StorageDestination.removable(generation), 'x'),
        throwsA(failure),
      );

      refused(1, const StorageFailure.readOnly());
      refused(2, const StorageFailure.unsupported());
      refused(3, const StorageFailure.unsupported());
      refused(4, const StorageFailure.volumeLost(4));
      refused(5, const StorageFailure.volumeLost(5));
      refused(6, const StorageFailure.unsupported());
      expect(repo.leases, isEmpty);
    });

    test('a pulled drive completes every lease on it with volumeLost; a later '
        'acquire is refused the same way; the replug is generation + 1 and '
        'leases normally', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      final recording = repo.acquire(usb1, 'recording');
      final export = repo.acquire(usb1, 'export');
      final onInternal = repo.acquire(internal, 'backup');

      h.client.detach(1);
      await pumpEventQueue();

      expect(await recording.lost, const StorageFailure.volumeLost(1));
      expect(await export.lost, const StorageFailure.volumeLost(1));
      expect(recording.isHeld, isFalse);
      expect(onInternal.isLost, isFalse);
      expect(repo.leases, [onInternal.lease]);
      expect(
        () => repo.acquire(usb1, 'export'),
        throwsA(const StorageFailure.volumeLost(1)),
      );

      h.client.attach(h.record(2));
      await pumpEventQueue();
      expect(
        repo.acquire(const StorageDestination.removable(2), 'export').isHeld,
        isTrue,
      );
    });

    test('a volume that turns ejected (by anyone) fails every lease on it, '
        'not only one that vanishes', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      final export = repo.acquire(usb1, 'export');

      h.client.update(
        h.record(1, status: RemovableVolumeRecordStatus.ejected),
      );
      await pumpEventQueue();

      expect(await export.lost, const StorageFailure.volumeLost(1));
      expect(export.isHeld, isFalse);
      expect(repo.transferInFlight, isFalse);
      expect(
        () => repo.acquire(usb1, 'export'),
        throwsA(const StorageFailure.volumeLost(1)),
      );
    });

    test('withWriteLease runs the body under a lease with the destination '
        'root and returns its value', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final roots = <String>[];
      final held = <List<String>>[];
      Future<int> body(String root) async {
        roots.add(root);
        held.add([for (final lease in repo.leases) lease.purpose]);
        return roots.length;
      }

      expect(await repo.withWriteLease(internal, 'backup', body), 1);
      expect(await repo.withWriteLease(usb1, 'export', body), 2);

      expect(roots, [h.exports, h.mountPoint(1)]);
      expect(held, [
        ['backup'],
        ['export'],
      ]);
      expect(repo.leases, isEmpty);
    });

    test('withWriteLease fails with volumeLost as soon as the drive is '
        'pulled, while the body is still running', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      final never = Completer<void>();

      final result = repo.withWriteLease(usb1, 'export', (_) => never.future);
      await pumpEventQueue();
      expect(repo.leasesOn(usb1), hasLength(1));
      h.client.detach(1);

      await expectLater(result, throwsA(const StorageFailure.volumeLost(1)));
      expect(repo.leases, isEmpty);
    });
  });

  group('eject', () {
    test('is refused while a lease holds the volume, naming the purpose, and '
        'files no request', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      final lease = repo.acquire(usb1, 'recording');

      await expectLater(
        repo.eject(1),
        throwsA(
          isA<EjectRefused>()
              .having((e) => e.holders, 'holders', [lease.lease])
              .having((e) => '$e', 'toString', 'EjectRefused(recording)'),
        ),
      );
      expect(h.client.pendingRequests, isEmpty);
      expect(repo.current.single.status, RemovableVolumeStatus.mounted);
    });

    test('after release: one request, the ejecting phase, then safe to '
        'remove when the helper reports the volume ejected', () async {
      repo = h.build(initial: [h.record(1)]);
      final phases = <EjectPhase>[];
      final phaseSub = repo.ejectPhase.listen(phases.add);
      addTearDown(phaseSub.cancel);
      await pumpEventQueue();
      repo.acquire(usb1, 'recording').release();

      final outcome = repo.eject(1);
      await pumpEventQueue();

      expect(h.client.pendingRequests, {'req-1': 1});
      expect(phases, [EjectPhase.idle, EjectPhase.ejecting]);
      expect(repo.current.single.status, RemovableVolumeStatus.ejecting);
      expect(repo.transferInFlight, isTrue);
      expect(
        () => repo.acquire(usb1, 'export'),
        throwsA(const StorageFailure.volumeLost(1)),
        reason: 'no new writer may start on a volume being ejected',
      );
      expect(() => repo.eject(1), throwsStateError);

      h.client.settleEject('req-1', ok: true);

      expect(await outcome, const EjectOutcome.safeToRemove());
      await pumpEventQueue();
      expect(phases.last, EjectPhase.idle);
      expect(repo.current.single.status, RemovableVolumeStatus.ejected);
      expect(repo.transferInFlight, isFalse);
    });

    test('a refusal from the kernel fails with its reason and leaves the '
        'volume mounted', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final busy = repo.eject(1);
      await pumpEventQueue();
      h.client.settleEject('req-1', ok: false, reason: 'busy');
      expect(await busy, const EjectOutcome.failed('busy'));

      final silent = repo.eject(1);
      await pumpEventQueue();
      h.client.settleEject('req-2', ok: false);
      expect(await silent, const EjectOutcome.failed('error'));
      expect(repo.current.single.status, RemovableVolumeStatus.mounted);
    });

    test('an answer to an older request does not settle this one', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      var settled = false;

      final outcome = repo.eject(1);
      unawaited(outcome.then((_) => settled = true));
      await pumpEventQueue();
      h.client.update(
        h.record(
          1,
          eject: const EjectOutcomeRecord(request: 'old', ok: false),
        ),
      );
      await pumpEventQueue();
      expect(settled, isFalse);

      h.client.settleEject('req-1', ok: true);
      expect(await outcome, const EjectOutcome.safeToRemove());
    });

    test('20 s without an answer fails with timeout and withdraws the '
        'request', () {
      fakeAsync((async) {
        repo = h.build(initial: [h.record(1)]);
        async.flushMicrotasks();
        EjectOutcome? outcome;
        unawaited(repo.eject(1).then((o) => outcome = o));
        async.flushMicrotasks();
        expect(h.client.pendingRequests, hasLength(1));

        async.elapse(const Duration(seconds: 19));
        expect(outcome, isNull);
        async.elapse(const Duration(seconds: 1));

        expect(outcome, const EjectOutcome.failed('timeout'));
        expect(h.client.pendingRequests, isEmpty);
        expect(repo.transferInFlight, isFalse);

        unawaited(repo.dispose());
        async.flushMicrotasks();
        disposed = true;
      });
    });

    test(
      'cancel before the helper answers withdraws the request and '
      'completes cancelled; with nothing in flight it does nothing',
      () async {
        repo = h.build(initial: [h.record(1)]);
        await pumpEventQueue();
        await repo.cancelEject();

        final outcome = repo.eject(1);
        await repo.cancelEject();

        expect(await outcome, const EjectOutcome.cancelled());
        expect(h.client.pendingRequests, isEmpty);
        expect(repo.current.single.status, RemovableVolumeStatus.mounted);
      },
    );

    test('20 s after the helper TOOK the request is not a failure: the '
        "eject stays in flight and ends with the helper's answer", () {
      fakeAsync((async) {
        repo = h.build(initial: [h.record(1)]);
        async.flushMicrotasks();
        EjectOutcome? outcome;
        unawaited(repo.eject(1).then((o) => outcome = o));
        async.flushMicrotasks();
        // The helper deletes the request, then syncs and unmounts.
        h.client.take('req-1');

        async.elapse(const Duration(seconds: 30));
        expect(outcome, isNull, reason: 'not "timeout": it is ejecting');
        expect(repo.current.single.status, RemovableVolumeStatus.ejecting);
        expect(repo.transferInFlight, isTrue);
        expect(
          () => repo.acquire(usb1, 'export'),
          throwsA(const StorageFailure.volumeLost(1)),
          reason: 'no writer may start on a drive being unmounted',
        );

        h.client.settleEject('req-1', ok: true);
        async.flushMicrotasks();
        expect(outcome, const EjectOutcome.safeToRemove());
        expect(repo.current.single.status, RemovableVolumeStatus.ejected);

        unawaited(repo.dispose());
        async.flushMicrotasks();
        disposed = true;
      });
    });

    test('a taken request that never gets an answer fails with timeout '
        'after the longer bound', () {
      fakeAsync((async) {
        repo = h.build(initial: [h.record(1)]);
        async.flushMicrotasks();
        EjectOutcome? outcome;
        unawaited(repo.eject(1).then((o) => outcome = o));
        async.flushMicrotasks();
        h.client.take('req-1');

        async.elapse(
          const Duration(seconds: 20) + const Duration(seconds: 119),
        );
        expect(outcome, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(outcome, const EjectOutcome.failed('timeout'));
        expect(repo.transferInFlight, isFalse);

        unawaited(repo.dispose());
        async.flushMicrotasks();
        disposed = true;
      });
    });

    test('a cancel after the helper TOOK the request does not claim it was '
        "cancelled: the eject ends with the helper's answer", () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final outcome = repo.eject(1);
      await pumpEventQueue();
      h.client.take('req-1');
      await repo.cancelEject();
      await pumpEventQueue();
      expect(repo.current.single.status, RemovableVolumeStatus.ejecting);

      h.client.settleEject('req-1', ok: true);
      expect(await outcome, const EjectOutcome.safeToRemove());
    });

    test('a request that cannot be filed fails with error; cancelling it '
        'meanwhile is harmless', () async {
      repo = h.build(usb: _UnfileableClient(initial: [h.record(1)]));
      await pumpEventQueue();

      final outcome = repo.eject(1);
      await repo.cancelEject();

      expect(await outcome, const EjectOutcome.failed('error'));
      expect(repo.transferInFlight, isFalse);
      expect(repo.current.single.status, RemovableVolumeStatus.mounted);
    });

    test('cancel after the helper answered leaves its outcome', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final outcome = repo.eject(1);
      await pumpEventQueue();
      h.client.settleEject('req-1', ok: true);
      await pumpEventQueue();
      await repo.cancelEject();

      expect(await outcome, const EjectOutcome.safeToRemove());
    });

    test('a drive pulled before the helper answers fails with removed, and '
        'so does an eject of a volume that is not there', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();

      final outcome = repo.eject(1);
      await pumpEventQueue();
      h.client.detach(1);

      expect(await outcome, const EjectOutcome.failed('removed'));
      expect(await repo.eject(1), const EjectOutcome.failed('removed'));
    });
  });

  group('space', () {
    test('Internal is measured at the exports root, or its nearest existing '
        'parent before the first capture', () async {
      repo = h.build(createExports: false);
      h.spaces[h.root.path] = const VolumeSpace(
        totalBytes: 128 * gib,
        freeBytes: 64 * gib,
      );

      expect(
        await repo.space(internal),
        const VolumeSpace(totalBytes: 128 * gib, freeBytes: 64 * gib),
      );
    });

    test('a removable volume is measured at its mount point only while it is '
        'mounted', () async {
      repo = h.build(
        initial: [
          h.record(1),
          h.record(2, status: RemovableVolumeRecordStatus.readOnly),
          h.record(3, status: RemovableVolumeRecordStatus.ejected),
          h.record(
            4,
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
        ],
      );
      await pumpEventQueue();
      for (final g in [1, 2, 3]) {
        h.spaces[h.mountPoint(g)] = VolumeSpace(
          totalBytes: 32 * gib,
          freeBytes: g * gib,
        );
      }

      expect((await repo.space(usb1))?.freeBytes, 1 * gib);
      expect(
        (await repo.space(const StorageDestination.removable(2)))?.freeBytes,
        2 * gib,
      );
      // An ejected volume's mount point is an empty directory on tmpfs:
      // measuring it would report the tmpfs.
      expect(await repo.space(const StorageDestination.removable(3)), isNull);
      expect(await repo.space(const StorageDestination.removable(4)), isNull);
      expect(await repo.space(const StorageDestination.removable(9)), isNull);
    });

    test('recording time on Internal keeps the 1 GB reserve back: the '
        "pen's 64.0 GB free at 48 kHz 24-bit stereo is 60 hr 45 min", () async {
      repo = h.build();
      h.spaces[h.exports] = const VolumeSpace(
        totalBytes: 128000000000,
        freeBytes: 64000000000,
      );

      final time = await repo.recordingTimeRemaining(internal, 288000);

      expect(time, const Duration(seconds: 63000000000 ~/ 288000));
      expect(time, const Duration(hours: 60, minutes: 45, seconds: 50));
    });

    test('a removable volume that cannot take a recording offers no '
        'recording time, read-only or being ejected', () async {
      repo = h.build(
        initial: [
          h.record(1, status: RemovableVolumeRecordStatus.readOnly),
          h.record(2),
        ],
      );
      await pumpEventQueue();
      for (final g in [1, 2]) {
        h.spaces[h.mountPoint(g)] = const VolumeSpace(
          totalBytes: 32 * gib,
          freeBytes: 24 * gib,
        );
      }

      expect(await repo.recordingTimeRemaining(usb1, 288000), isNull);
      // Its capacity is still a fact the Storage page draws.
      expect((await repo.space(usb1))?.freeBytes, 24 * gib);

      const usb2 = StorageDestination.removable(2);
      expect(await repo.recordingTimeRemaining(usb2, 288000), isNotNull);
      final ejecting = repo.eject(2);
      await pumpEventQueue();
      expect(await repo.recordingTimeRemaining(usb2, 288000), isNull);
      h.client.settleEject('req-1', ok: true);
      await ejecting;
      expect(await repo.recordingTimeRemaining(usb2, 288000), isNull);
    });

    test('recording time on a removable volume applies no reserve', () async {
      repo = h.build(initial: [h.record(1)]);
      await pumpEventQueue();
      h.spaces[h.mountPoint(1)] = const VolumeSpace(
        totalBytes: 32 * gib,
        freeBytes: 24 * gib,
      );

      expect(
        await repo.recordingTimeRemaining(usb1, 288000),
        const Duration(seconds: 24 * gib ~/ 288000),
      );
    });

    test('unknown space claims no time; less than the reserve is zero; a '
        'rate that is not positive is a caller error', () async {
      repo = h.build();
      expect(await repo.recordingTimeRemaining(internal, 288000), isNull);

      h.spaces[h.exports] = const VolumeSpace(
        totalBytes: 128 * gib,
        freeBytes: StorageRepository.internalReserveBytes ~/ 2,
      );
      expect(
        await repo.recordingTimeRemaining(internal, 288000),
        Duration.zero,
      );
      expect(
        () => repo.recordingTimeRemaining(internal, 0),
        throwsArgumentError,
      );
    });

    test('low internal space is free below the reserve; unknown is not '
        'low', () async {
      repo = h.build();
      expect(await repo.lowInternalSpace(), isFalse);

      h.spaces[h.exports] = const VolumeSpace(
        totalBytes: 128 * gib,
        freeBytes: StorageRepository.internalReserveBytes - 1,
      );
      expect(await repo.lowInternalSpace(), isTrue);

      h.spaces[h.exports] = const VolumeSpace(
        totalBytes: 128 * gib,
        freeBytes: StorageRepository.internalReserveBytes,
      );
      expect(await repo.lowInternalSpace(), isFalse);
    });
  });
}

/// A client whose eject requests cannot be written (a read-only run dir).
class _UnfileableClient extends FakeUsbStorageClient {
  _UnfileableClient({super.initial});

  @override
  Future<String> requestEject(int generation) async =>
      throw const FileSystemException('Read-only file system');
}
