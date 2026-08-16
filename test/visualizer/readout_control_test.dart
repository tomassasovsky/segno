import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/readout_control.dart';

void main() {
  group('ReadoutControl wire format', () {
    const control = ReadoutControl(
      action: ReadoutControl.trackVolume,
      index: 3,
      value: 1.5,
    );

    test('survives a round trip through the channel payload', () {
      expect(ReadoutControl.fromMap(control.toMap()), control);
    });

    test('defaults every missing field — an empty map cannot throw', () {
      // The command crosses the same engine boundary as the readout, in the
      // opposite direction; the map is the contract, not the Dart type.
      const decoded = ReadoutControl(action: '', index: -1);
      expect(ReadoutControl.fromMap(const {}), decoded);
    });

    test('ignores unknown fields, so a newer overlay is readable', () {
      final map = control.toMap()..['someFutureFact'] = true;
      expect(ReadoutControl.fromMap(map), control);
    });

    test('toggles carry no value', () {
      const toggle = ReadoutControl(
        action: ReadoutControl.trackMuteToggle,
        index: 2,
      );
      expect(ReadoutControl.fromMap(toggle.toMap()).value, 0);
    });
  });
}
