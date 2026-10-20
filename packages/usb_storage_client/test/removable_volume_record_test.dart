import 'dart:convert';

import 'package:test/test.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// The exact JSON `segno-usb-ctl` writes (the helper test's own oracle), so
/// the two sides of the file contract are pinned against the same bytes.
final String helperJson = [
  '{"generation":1,"kname":"sda1",',
  '"fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D",',
  '"label":"SEGNO USB","fsType":"vfat",',
  '"mountPoint":"/run/media/segno/1-SEGNO_USB",',
  '"sizeBytes":32010928128,"status":"mounted","readOnly":false,',
  '"writeBytesPerSecond":16777216,"failureReason":null,"eject":null}',
].join();

Map<String, Object?> decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

void main() {
  group('RemovableVolumeRecord.fromJson', () {
    test('reads every field of the helper JSON', () {
      final record = RemovableVolumeRecord.fromJson(decode(helperJson));
      expect(
        record,
        const RemovableVolumeRecord(
          generation: 1,
          kname: 'sda1',
          fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
          label: 'SEGNO USB',
          fsType: 'vfat',
          mountPoint: '/run/media/segno/1-SEGNO_USB',
          sizeBytes: 32010928128,
          status: RemovableVolumeRecordStatus.mounted,
          readOnly: false,
          writeBytesPerSecond: 16777216,
        ),
      );
    });

    test('the probe-less first write, a read-only fallback and a failed mount '
        'parse with their nulls', () {
      final first = RemovableVolumeRecord.fromJson(
        decode(helperJson.replaceFirst('16777216', 'null')),
      );
      expect(first.writeBytesPerSecond, isNull);

      final readOnly = RemovableVolumeRecord.fromJson(
        decode(
          helperJson
              .replaceFirst(
                '"status":"mounted","readOnly":false',
                '"status":"readOnly","readOnly":true',
              )
              .replaceFirst(
                '"failureReason":null',
                '"failureReason":"mount: /dev/sda1: WARNING: source write-protected, mounted read-only."',
              ),
        ),
      );
      expect(readOnly.status, RemovableVolumeRecordStatus.readOnly);
      expect(readOnly.readOnly, isTrue);
      expect(readOnly.failureReason, startsWith('mount: /dev/sda1'));

      final failed = RemovableVolumeRecord.fromJson(
        decode(
          helperJson
              .replaceFirst(
                '"mountPoint":"/run/media/segno/1-SEGNO_USB"',
                '"mountPoint":null',
              )
              .replaceFirst('"status":"mounted"', '"status":"mountFailed"'),
        ),
      );
      expect(failed.mountPoint, isNull);
      expect(failed.status, RemovableVolumeRecordStatus.mountFailed);
    });

    test('an eject outcome parses, success and refusal alike', () {
      final ejected = RemovableVolumeRecord.fromJson(
        decode(
          helperJson
              .replaceFirst('"status":"mounted"', '"status":"ejected"')
              .replaceFirst(
                '"eject":null',
                '"eject":{"request":"7f3a","ok":true,"reason":null}',
              ),
        ),
      );
      expect(ejected.status, RemovableVolumeRecordStatus.ejected);
      expect(
        ejected.eject,
        const EjectOutcomeRecord(request: '7f3a', ok: true),
      );

      final busy = RemovableVolumeRecord.fromJson(
        decode(
          helperJson.replaceFirst(
            '"eject":null',
            '"eject":{"request":"b1","ok":false,"reason":"busy"}',
          ),
        ),
      );
      expect(busy.status, RemovableVolumeRecordStatus.mounted);
      expect(
        busy.eject,
        const EjectOutcomeRecord(request: 'b1', ok: false, reason: 'busy'),
      );
    });

    test('an unknown status, a wrong type and a non-object eject are '
        'FormatExceptions, never records', () {
      expect(
        () => RemovableVolumeRecord.fromJson(
          decode(helperJson.replaceFirst('"mounted"', '"spinning"')),
        ),
        throwsFormatException,
      );
      expect(
        () => RemovableVolumeRecord.fromJson(
          decode(helperJson.replaceFirst('"generation":1', '"generation":"1"')),
        ),
        throwsFormatException,
      );
      expect(
        () => RemovableVolumeRecord.fromJson(
          decode(helperJson.replaceFirst('"readOnly":false', '"readOnly":0')),
        ),
        throwsFormatException,
      );
      expect(
        () => RemovableVolumeRecord.fromJson(
          decode(
            helperJson.replaceFirst('"label":"SEGNO USB"', '"label":null'),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => RemovableVolumeRecord.fromJson(
          decode(helperJson.replaceFirst('"eject":null', '"eject":"done"')),
        ),
        throwsFormatException,
      );
    });

    test('records with the same fields are equal; a changed field is not', () {
      final a = RemovableVolumeRecord.fromJson(decode(helperJson));
      final b = RemovableVolumeRecord.fromJson(decode(helperJson));
      final c = RemovableVolumeRecord.fromJson(
        decode(helperJson.replaceFirst('16777216', '1')),
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
