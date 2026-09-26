import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group(PedalPdStatus, () {
    test('unknown voltage remains distinct from a known 20 V contract', () {
      const unknown = PedalPdStatus.contract(currentMilliamps: 5000);
      const known = PedalPdStatus.contract(
        currentMilliamps: 5000,
        voltageMillivolts: 20000,
      );
      expect(unknown.voltageMillivolts, isNull);
      expect(unknown, isNot(known));
      expect(unknown.isValid, isTrue);
      expect(known.isValid, isTrue);
    });

    test(
      'mismatch participates in equality and unavailable states carry no power',
      () {
        const normal = PedalPdStatus.contract(currentMilliamps: 3000);
        const mismatch = PedalPdStatus.contract(
          currentMilliamps: 3000,
          capabilityMismatch: true,
        );
        expect(normal, isNot(mismatch));
        for (final state in PedalPdState.values) {
          if (state == PedalPdState.contract) continue;
          final status = PedalPdStatus.unavailable(state);
          expect(status.isValid, isTrue);
          expect(status.currentMilliamps, isNull);
          expect(status.voltageMillivolts, isNull);
          expect(status.capabilityMismatch, isFalse);
        }
      },
    );

    test('constructors reject an unavailable contract and invalid units', () {
      expect(
        () => PedalPdStatus.unavailable(PedalPdState.contract),
        throwsAssertionError,
      );
      for (final current in [0, 9, 11, 5010]) {
        expect(
          () => PedalPdStatus.contract(currentMilliamps: current),
          throwsAssertionError,
        );
      }
      for (final voltage in [0, 4950, 20050, 10001]) {
        expect(
          () => PedalPdStatus.contract(
            currentMilliamps: 3000,
            voltageMillivolts: voltage,
          ),
          throwsAssertionError,
        );
      }
    });
  });

  group('PD wire status', () {
    test('pins the mismatch frame independently of the encoder', () {
      const message = PdStatusMessage(
        PedalPdStatus.contract(
          currentMilliamps: 3000,
          capabilityMismatch: true,
        ),
      );
      const golden = [0xa5, 0x05, 0x06, 0x03, 0x01, 0, 0, 0xb8, 0x0b, 0xb2];
      expect(PedalLinkCodec.encode(message), golden);
      final parser = PedalLinkParser();
      final decoded = <PedalLinkMessage>[];
      for (final byte in golden) {
        decoded.addAll(parser.push([byte]));
      }
      expect(decoded, [message]);
      expect(parser.droppedFrames, 0);
    });

    test('known voltage and legal boundary units survive the wire', () {
      for (final voltage in [null, 5000, 20000]) {
        for (final current in [10, 5000]) {
          final message = PdStatusMessage(
            PedalPdStatus.contract(
              currentMilliamps: current,
              voltageMillivolts: voltage,
            ),
          );
          expect(
            PedalLinkParser().push(PedalLinkCodec.encode(message)),
            [message],
          );
        }
      }
    });

    test('rejects wrong lengths, bytes, flags, ranges and stale values', () {
      final invalid = <List<int>>[
        [], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0],
        [6, 0, 0, 0, 0, 0], [-1, 0, 0, 0, 0, 0],
        [0, 0, 256, 0, 0, 0], [3, 2, 0, 0, 0xb8, 0x0b],
        [3, 0, 0, 0, 0, 0], [3, 0, 0, 0, 9, 0],
        [3, 0, 0, 0, 11, 0], [3, 0, 0, 0, 0x92, 0x13],
        [3, 0, 0x56, 0x13, 0xb8, 0x0b], // 4950 mV
        [3, 0, 0x21, 0x4e, 0xb8, 0x0b], // 20001 mV
        [3, 0, 0x21, 0x27, 0xb8, 0x0b], // 10017 mV
        for (final state in [0, 1, 2, 4, 5]) ...[
          [state, 1, 0, 0, 0, 0],
          [state, 0, 0x20, 0x4e, 0, 0],
          [state, 0, 0, 0, 0xb8, 0x0b],
        ],
      ];
      for (final payload in invalid) {
        expect(
          PedalLinkCodec.decodePdStatusPayload(payload),
          isNull,
          reason: '$payload',
        );
        expect(
          PedalLinkCodec.decode(PedalLinkCodec.typePdStatus, payload),
          isNull,
          reason: '$payload',
        );
      }
    });

    test('a malformed observation cannot hide the valid frame after it', () {
      final parser = PedalLinkParser();
      const payload = [5, 0, 0, 0, 0xb8, 0x0b];
      const following = PdStatusMessage(
        PedalPdStatus.unavailable(PedalPdState.readError),
      );
      expect(
        parser.push([
          0xa5,
          0x05,
          6,
          ...payload,
          PedalLinkCodec.checksum(0x05, payload),
          ...PedalLinkCodec.encode(following),
        ]),
        [following],
      );
      expect(parser.droppedFrames, 1);
    });
  });
}
