import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group(BackingFailureReason, () {
    test('fromEngine names every decoder and engine refusal', () {
      expect(
        {
          for (final result in [
            EngineResult.unsupported,
            EngineResult.invalid,
            EngineResult.tooLong,
            EngineResult.capacity,
            EngineResult.notRunning,
            EngineResult.notReady,
          ])
            result: BackingFailureReason.fromEngine(result),
        },
        {
          EngineResult.unsupported: BackingFailureReason.unsupported,
          EngineResult.invalid: BackingFailureReason.damaged,
          EngineResult.tooLong: BackingFailureReason.tooLong,
          EngineResult.capacity: BackingFailureReason.noMemory,
          EngineResult.notRunning: BackingFailureReason.notRunning,
          EngineResult.notReady: BackingFailureReason.busy,
        },
      );
    });
  });
}
