import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('PerfTarget', () {
    test('copies the take id and requires 16 bytes', () {
      final id = Uint8List(16);
      final target = PerfTarget(captureDir: '/take', takeId: id);
      id[0] = 7;
      expect(target.takeId[0], 0);
      expect(
        () => PerfTarget(captureDir: '/take', takeId: Uint8List(15)),
        throwsArgumentError,
      );
    });

    test('refuses ring seconds outside 0 to maxRingSeconds (#1198)', () {
      PerfTarget(
        captureDir: '/take',
        takeId: Uint8List(16),
        ringSeconds: PerfTarget.maxRingSeconds,
      );
      for (final seconds in [-1, PerfTarget.maxRingSeconds + 1, 1 << 40]) {
        expect(
          () => PerfTarget(
            captureDir: '/take',
            takeId: Uint8List(16),
            ringSeconds: seconds,
          ),
          throwsArgumentError,
          reason: '$seconds',
        );
      }
    });

    test('refuses a negative part size', () {
      expect(
        () => PerfTarget(
          captureDir: '/take',
          takeId: Uint8List(16),
          partBytes: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
