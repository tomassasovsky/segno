import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalCtrlCalibration', () {
    // The EX-P as measured on the bench: 24..255 of the board's 0..255.
    const exp = PedalCtrlCalibration(min: 24, max: 255);

    test('stretches the travel between the ends onto 0..255', () {
      expect(exp.apply(24), 0);
      expect(exp.apply(255), 255);
      final mid = exp.apply((24 + 255) ~/ 2);
      expect(mid, closeTo(128, 2));
    });

    test('the margin makes the ends reachable through noise', () {
      // A count or two above the lowest reading ever seen is still "heel":
      // without this a pedal held down sits at 1% for ever.
      expect(exp.apply(24 + PedalCtrlCalibration.margin), 0);
      expect(exp.apply(255 - PedalCtrlCalibration.margin), 255);
    });

    test('clamps beyond the ends', () {
      const narrow = PedalCtrlCalibration(min: 100, max: 200);
      expect(narrow.apply(0), 0);
      expect(narrow.apply(255), 255);
    });

    test('is not trusted until the ends are far enough apart', () {
      expect(const PedalCtrlCalibration(min: 100, max: 110).isUsable, isFalse);
      expect(
        const PedalCtrlCalibration(
          min: 100,
          max: 100 + PedalCtrlCalibration.minSpan,
        ).isUsable,
        isTrue,
      );
    });

    test('a span too small to stretch passes the raw reading through', () {
      const flat = PedalCtrlCalibration(min: 100, max: 102);
      expect(flat.apply(101), 101);
    });

    test('including widens the ends and never narrows them', () {
      const seen = PedalCtrlCalibration(min: 50, max: 60);
      expect(seen.including(40), const PedalCtrlCalibration(min: 40, max: 60));
      expect(seen.including(70), const PedalCtrlCalibration(min: 50, max: 70));
      expect(seen.including(55), seen);
    });
  });
}
