import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalLinkCodec', () {
    test('frames a message as sync, type, length, payload, xor', () {
      final bytes = PedalLinkCodec.encode(
        const ButtonMessage(PedalButton.undo, pressed: true),
      );
      expect(bytes, [0xA5, 0x01, 0x02, 0x02, 0x01, 0x01 ^ 0x02 ^ 0x02 ^ 0x01]);
    });

    test('a loop-top frame carries no payload', () {
      expect(
        PedalLinkCodec.encode(const LoopTopMessage()),
        [0xA5, 0x11, 0x00, 0x11],
      );
    });

    test("the encoder delta is an int8 two's complement byte", () {
      expect(PedalLinkCodec.encode(const EncoderMessage(-1))[3], 0xFF);
      expect(PedalLinkCodec.encode(const EncoderMessage(-128))[3], 0x80);
      expect(PedalLinkCodec.encode(const EncoderMessage(127))[3], 0x7F);
      expect(
        PedalLinkCodec.decode(PedalLinkCodec.typeEncoder, [0xFF]),
        const [
          EncoderMessage(-1),
        ].single,
      );
    });

    test('state payload round-trips every field', () {
      final frame = PedalStateFrame(
        globalColor: GlobalColor.amber,
        trackLeds: const [
          PedalTrackLed.green,
          PedalTrackLed.red,
          PedalTrackLed.blue,
          PedalTrackLed.off,
          PedalTrackLed.green,
          PedalTrackLed.off,
          PedalTrackLed.off,
          PedalTrackLed.red,
        ],
        activeBank: 1,
        selectedTrack: 7,
        mode: PedalMode.fx,
        loopLengthMicros: 0x01020304,
        clearFadeActive: true,
        isGoodbye: true,
        performanceArmed: true,
        looperMode: PedalLooperMode.song,
        countingIn: true,
      );
      final payload = PedalLinkCodec.encodeStatePayload(frame);
      expect(payload.length, PedalLinkCodec.statePayloadLength);
      expect(payload[0], 0x0F);
      expect(payload.sublist(14, 18), [0x04, 0x03, 0x02, 0x01]);
      expect(payload[18], 255);
      expect(PedalLinkCodec.decodeStatePayload(payload), frame);
      expect(payload[18], 255);
    });

    test('master gain is quantized to one byte', () {
      final frame = PedalStateFrame.blank().copyWith(masterGain: 0.5);
      final decoded = PedalLinkCodec.decodeStatePayload(
        PedalLinkCodec.encodeStatePayload(frame),
      );
      expect(decoded!.masterGain, closeTo(0.5, 1 / 255));
    });

    group('decodeStatePayload rejects', () {
      final good = PedalLinkCodec.encodeStatePayload(PedalStateFrame.blank());

      test('a wrong length', () {
        expect(PedalLinkCodec.decodeStatePayload(good.sublist(1)), isNull);
        expect(PedalLinkCodec.decodeStatePayload([...good, 0]), isNull);
      });

      test('a reserved flag bit', () {
        expect(
          PedalLinkCodec.decodeStatePayload([0x10, ...good.skip(1)]),
          isNull,
        );
      });

      test('an out-of-range enum index', () {
        for (final (index, limit) in [
          (1, PedalMode.values.length),
          (2, PedalLooperMode.values.length),
          (3, GlobalColor.values.length),
          (4, 2),
          (5, PedalStateFrame.trackCount),
          (6, PedalTrackLed.values.length),
          (13, PedalTrackLed.values.length),
        ]) {
          final bad = List<int>.of(good)..[index] = limit;
          expect(
            PedalLinkCodec.decodeStatePayload(bad),
            isNull,
            reason: 'byte $index = $limit',
          );
        }
      });
    });

    group('decode rejects', () {
      test('an unknown type', () {
        expect(PedalLinkCodec.decode(0x7F, const []), isNull);
      });

      test('a button frame with a bad button or a bad state', () {
        expect(
          PedalLinkCodec.decode(PedalLinkCodec.typeButton, [10, 1]),
          isNull,
        );
        expect(
          PedalLinkCodec.decode(PedalLinkCodec.typeButton, [0, 2]),
          isNull,
        );
        expect(PedalLinkCodec.decode(PedalLinkCodec.typeButton, [0]), isNull);
      });

      test('wrong payload lengths', () {
        expect(PedalLinkCodec.decode(PedalLinkCodec.typeEncoder, []), isNull);
        expect(PedalLinkCodec.decode(PedalLinkCodec.typeHello, [1, 0]), isNull);
        expect(PedalLinkCodec.decode(PedalLinkCodec.typeLoopTop, [0]), isNull);
      });
    });
  });

  group('PedalLinkParser', () {
    final hello = PedalLinkCodec.encode(
      const HelloMessage(
        protocolVersion: 1,
        firmwareMajor: 1,
        firmwareMinor: 2,
      ),
    );
    final button = PedalLinkCodec.encode(
      const ButtonMessage(PedalButton.bank, pressed: false),
    );

    test('parses whole frames', () {
      expect(PedalLinkParser().push([...hello, ...button]), [
        const HelloMessage(
          protocolVersion: 1,
          firmwareMajor: 1,
          firmwareMinor: 2,
        ),
        const ButtonMessage(PedalButton.bank, pressed: false),
      ]);
    });

    test('reassembles a frame split across chunks, one byte at a time', () {
      final parser = PedalLinkParser();
      final out = <PedalLinkMessage>[];
      for (final b in [...hello, ...button]) {
        out.addAll(parser.push([b]));
      }
      expect(out, hasLength(2));
    });

    test(
      'resyncs after garbage and after a bad checksum, counting the drop',
      () {
        final corrupt = List<int>.of(hello)..[hello.length - 1] ^= 0x01;
        final parser = PedalLinkParser();
        expect(
          parser.push([0x00, 0x13, ...corrupt, 0x37, ...button]),
          [const ButtonMessage(PedalButton.bank, pressed: false)],
        );
        expect(parser.droppedFrames, 1);
      },
    );

    test('rejects a corrupted in-range length at the length byte, so the '
        'frame behind it is not swallowed', () {
      final parser = PedalLinkParser();
      final out = parser.push([
        PedalLinkCodec.sync,
        PedalLinkCodec.typeState,
        PedalLinkCodec.statePayloadLength + 12,
        ...button,
      ]);
      expect(out, [const ButtonMessage(PedalButton.bank, pressed: false)]);
      expect(parser.droppedFrames, 1);
    });

    test('rejects an unknown type at the type byte', () {
      final parser = PedalLinkParser();
      final out = parser.push([PedalLinkCodec.sync, 0x7E, 0x02, ...button]);
      expect(out, [const ButtonMessage(PedalButton.bank, pressed: false)]);
      expect(parser.droppedFrames, 1);
    });

    test('a sync byte in the type or length slot starts the next frame', () {
      final parser = PedalLinkParser();
      // A stray sync right before a real frame, and a frame whose length byte
      // was replaced by a sync: the real frame behind each survives.
      expect(parser.push([PedalLinkCodec.sync, ...button]), hasLength(1));
      expect(
        parser.push([
          PedalLinkCodec.sync,
          PedalLinkCodec.typeState,
          ...button,
        ]),
        hasLength(1),
      );
      expect(parser.droppedFrames, 2);
    });

    test('reset forgets a half-received frame', () {
      final parser = PedalLinkParser()
        ..push(button.sublist(0, 4))
        ..reset();
      expect(parser.push(button), hasLength(1));
    });

    test('payloadLengthFor knows every type and nothing else', () {
      expect(PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeButton), 2);
      expect(PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeEncoder), 1);
      expect(PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeHello), 3);
      expect(
        PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeState),
        PedalLinkCodec.statePayloadLength,
      );
      expect(PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeLoopTop), 0);
      expect(PedalLinkCodec.payloadLengthFor(0x7F), isNull);
    });

    test('drops an oversized length and resyncs', () {
      final out = PedalLinkParser().push([0xA5, 0x01, 0xFF, ...button]);
      expect(out, [const ButtonMessage(PedalButton.bank, pressed: false)]);
    });

    test('drops a well-framed but undecodable message', () {
      final bogus = [0xA5, 0x7F, 0x00, 0x7F];
      expect(PedalLinkParser().push([...bogus, ...button]), hasLength(1));
    });

    test('a sync byte inside a payload does not restart the frame', () {
      final state = PedalLinkCodec.encode(
        StateMessage(
          PedalStateFrame.blank().copyWith(loopLengthMicros: 0xA5A5A5A5),
        ),
      );
      expect(PedalLinkParser().push(state), hasLength(1));
    });
  });
}
