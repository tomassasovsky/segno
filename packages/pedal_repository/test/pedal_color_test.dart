import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalColor', () {
    test('round-trips through its packed integer', () {
      const color = PedalColor(0x12, 0x34, 0x56);
      expect(color.rgb, 0x123456);
      expect(PedalColor.fromRgb(0x123456), color);
    });

    test('drops anything above the low 24 bits of a packed integer', () {
      expect(
        PedalColor.fromRgb(0xFF123456),
        const PedalColor(0x12, 0x34, 0x56),
      );
    });

    test('rejects a channel off the end', () {
      expect(() => PedalColor(256, 0, 0), throwsA(isA<AssertionError>()));
      expect(() => PedalColor(0, -1, 0), throwsA(isA<AssertionError>()));
      expect(() => PedalColor(0, 0, 999), throwsA(isA<AssertionError>()));
    });

    test('prints as a hex triple, which is how a colour is written down', () {
      expect(const PedalColor(0x0A, 0x0B, 0x0C).toString(), '#0A0B0C');
      expect(PedalColor.white.toString(), '#E6EEF9');
    });

    test('the default IS the palette white, not a second white', () {
      // The one number on both sides of the wire: the app assigns white to all
      // ten before anyone opens the editor, and a frame below protocol v4
      // decodes to the same colour rather than to a brighter one nothing sent.
      expect(PedalColor.defaultColor, PedalColor.white);
    });

    test('the eight built-ins are eight distinct hues', () {
      const builtIns = [
        PedalColor.white,
        PedalColor.amber,
        PedalColor.red,
        PedalColor.orange,
        PedalColor.green,
        PedalColor.cyan,
        PedalColor.blue,
        PedalColor.violet,
      ];
      expect(builtIns.map((c) => c.rgb).toSet(), hasLength(builtIns.length));
    });
  });
}
