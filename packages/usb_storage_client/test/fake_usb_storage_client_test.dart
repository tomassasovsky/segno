import 'package:test/test.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

RemovableVolumeRecord volume(
  int generation, {
  RemovableVolumeRecordStatus status = RemovableVolumeRecordStatus.mounted,
}) => RemovableVolumeRecord(
  generation: generation,
  kname: 'sda1',
  fingerprint: 'fp-$generation',
  label: 'SEGNO USB',
  fsType: 'exfat',
  mountPoint: '/run/media/segno/$generation-SEGNO_USB',
  sizeBytes: 32010928128,
  status: status,
  readOnly: false,
);

void main() {
  group('FakeUsbStorageClient', () {
    test(
      'replays the current list to a new listener, then every change',
      () async {
        final fake = FakeUsbStorageClient(initial: [volume(1)]);
        addTearDown(fake.dispose);
        final events = <List<RemovableVolumeRecord>>[];
        fake.volumes.listen(events.add);
        await Future<void>.delayed(Duration.zero);

        fake
          ..attach(volume(2))
          ..detach(1);
        await Future<void>.delayed(Duration.zero);

        expect(events.map((e) => e.map((r) => r.generation).toList()), [
          [1],
          [1, 2],
          [2],
        ]);
        expect(fake.isSupported, isTrue);
      },
    );

    test('requestEject hands out req-N ids and settleEject writes the outcome '
        'into the record', () async {
      final fake = FakeUsbStorageClient(initial: [volume(1), volume(2)]);
      addTearDown(fake.dispose);

      final a = await fake.requestEject(1);
      final b = await fake.requestEject(2);
      expect([a, b], ['req-1', 'req-2']);
      expect(fake.pendingRequests, {'req-1': 1, 'req-2': 2});

      fake
        ..settleEject(a, ok: true)
        ..settleEject(b, ok: false, reason: 'busy');
      final list = await fake.volumes.first;

      expect(list[0].status, RemovableVolumeRecordStatus.ejected);
      expect(
        list[0].eject,
        const EjectOutcomeRecord(request: 'req-1', ok: true),
      );
      expect(list[1].status, RemovableVolumeRecordStatus.mounted);
      expect(
        list[1].eject,
        const EjectOutcomeRecord(request: 'req-2', ok: false, reason: 'busy'),
      );
      expect(fake.pendingRequests, isEmpty);
    });

    test('cancelEject withdraws a pending request; settling an unknown or '
        'cancelled one changes nothing', () async {
      final fake = FakeUsbStorageClient(initial: [volume(1)]);
      addTearDown(fake.dispose);
      final id = await fake.requestEject(1);

      await fake.cancelEject(id);
      fake
        ..settleEject(id, ok: true)
        ..settleEject('never-filed', ok: true);

      expect(fake.pendingRequests, isEmpty);
      expect((await fake.volumes.first).single.eject, isNull);
    });

    test(
      'a request for a volume detached before it is served is dropped',
      () async {
        final fake = FakeUsbStorageClient(initial: [volume(1)]);
        addTearDown(fake.dispose);
        final id = await fake.requestEject(1);
        fake
          ..detach(1)
          ..settleEject(id, ok: true);

        expect(fake.pendingRequests, isEmpty);
        expect(await fake.volumes.first, isEmpty);
      },
    );

    test('update replaces a record in place (the probe landing)', () async {
      final fake = FakeUsbStorageClient(initial: [volume(1)]);
      addTearDown(fake.dispose);

      fake.update(volume(1, status: RemovableVolumeRecordStatus.readOnly));

      expect(
        (await fake.volumes.first).single.status,
        RemovableVolumeRecordStatus.readOnly,
      );
    });

    test('an unsupported fake says so', () {
      expect(FakeUsbStorageClient(isSupported: false).isSupported, isFalse);
    });
  });
}
