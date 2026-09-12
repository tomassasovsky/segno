import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// An expression pedal reaches segno as an absolute Control Change on the link
/// the footswitches and the encoder already share. These pin the numbers and
/// the raw domain, because both are a wire contract shared with firmware that
/// does not exist yet.
void main() {
  group('PedalExpressionJack', () {
    test('the numbers match the firmware copies byte for byte', () {
      // The only cross-language check available: these literals are declared a
      // second time in firmware/segno_pedal/pedal_protocol.h (and its 32u4
      // mirror) as PEDAL_EXPRESSION_CTRL1_CC, PEDAL_EXPRESSION_CTRL2_CC and
      // PEDAL_EXPRESSION_MAX, where the C contract suite pins them to the same
      // values. Changing one side without the other fails here.
      expect(PedalExpressionJack.ctrl1.cc, 0x11);
      expect(PedalExpressionJack.ctrl2.cc, 0x12);
      expect(PedalExpressionJackCc.maxValue, 0x7F);
    });

    test('neither jack collides with the encoder', () {
      for (final jack in PedalExpressionJack.values) {
        expect(
          jack.cc,
          isNot(PedalCodec.encoderCc),
          reason: 'a shared CC number would read a sweep as an encoder turn',
        );
        expect(PedalExpressionJackCc.fromCc(jack.cc), jack);
      }
      expect(
        PedalExpressionJack.ctrl1.cc,
        isNot(PedalExpressionJack.ctrl2.cc),
        reason: 'the two jacks have to be told apart',
      );
    });

    test('a CC either side of the pair is not a jack', () {
      expect(
        PedalExpressionJackCc.fromCc(PedalExpressionJackCc.firstCc - 1),
        isNull,
      );
      expect(
        PedalExpressionJackCc.fromCc(
          PedalExpressionJackCc.firstCc + PedalExpressionJack.values.length,
        ),
        isNull,
      );
    });
  });

  group('decoding a position', () {
    test('both mechanical ends arrive as 0 and 1', () {
      expect(
        PedalCodec.decodeMessage(0xB0, PedalExpressionJack.ctrl1.cc, 0),
        const ExpressionMoved(PedalExpressionJack.ctrl1, raw: 0),
      );
      expect(
        PedalCodec.decodeMessage(
          0xB0,
          PedalExpressionJack.ctrl2.cc,
          PedalExpressionJackCc.maxValue,
        ),
        const ExpressionMoved(PedalExpressionJack.ctrl2, raw: 1),
      );
    });

    test('the middle of the travel is the middle of the domain', () {
      final event =
          PedalCodec.decodeMessage(
                0xB0,
                PedalExpressionJack.ctrl1.cc,
                (PedalExpressionJackCc.maxValue / 2).round(),
              )!
              as ExpressionMoved;
      expect(event.raw, closeTo(0.5, 0.01));
    });

    test('a value past the end is held at the end, not wrapped', () {
      // Nothing should send one, but a raw byte with its high bit set would
      // normalize past 1 and drive every mapping past its own toe value.
      expect(
        PedalCodec.decodeMessage(0xB0, PedalExpressionJack.ctrl1.cc, 0xFF),
        const ExpressionMoved(PedalExpressionJack.ctrl1, raw: 1),
      );
    });

    test('the encoder still decodes as the encoder', () {
      expect(
        PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc, 70),
        const EncoderDelta(6),
      );
      expect(
        PedalCodec.decodeMessage(0xB0, 0x40, 64),
        isNull,
        reason: 'a CC belonging to neither is not input',
      );
    });
  });
}
