import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

void main() {
  group('PerfTarget', () {
    test('mirrors the part format constants of the C API', () {
      expect(PerfTarget.partHeaderBytes, LE_PERF_PART_HEADER_BYTES);
      expect(PerfTarget.rawStreamBase, LE_PERF_RAW_STREAM_BASE);
    });

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

    test('checkpoints every 5 s by default and refuses a negative interval '
        '(#1198 D4)', () {
      expect(
        PerfTarget(captureDir: '/take', takeId: Uint8List(16)).checkpointMs,
        5000,
      );
      expect(
        () => PerfTarget(
          captureDir: '/take',
          takeId: Uint8List(16),
          checkpointMs: -1,
        ),
        throwsArgumentError,
      );
    });

    test('never stops on its own unless asked, and refuses negative stop '
        'times (#1767)', () {
      final target = PerfTarget(captureDir: '/take', takeId: Uint8List(16));
      expect(target.idleStopSeconds, 0);
      expect(target.maxSeconds, 0);
      for (final (idle, max) in [(-1, 0), (0, -1)]) {
        expect(
          () => PerfTarget(
            captureDir: '/take',
            takeId: Uint8List(16),
            idleStopSeconds: idle,
            maxSeconds: max,
          ),
          throwsArgumentError,
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
