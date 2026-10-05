import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('ReopenOutcome.fromCode', () {
    test('maps each native le_reopen_outcome value', () {
      expect(ReopenOutcome.fromCode(0), ReopenOutcome.retained);
      expect(ReopenOutcome.fromCode(1), ReopenOutcome.clearedRate);
      expect(ReopenOutcome.fromCode(2), ReopenOutcome.clearedCap);
      expect(ReopenOutcome.fromCode(3), ReopenOutcome.clearedPending);
    });

    test('reads an unknown code as cleared, never as retained', () {
      expect(ReopenOutcome.fromCode(-1), ReopenOutcome.clearedPending);
      expect(ReopenOutcome.fromCode(42), ReopenOutcome.clearedPending);
    });
  });

  group('MockAudioEngine.reopen', () {
    test('refuses while running and before any start', () {
      final engine = MockAudioEngine();
      expect(
        engine.reopen(engine.defaultConfig).result,
        EngineResult.notRunning,
      );
      engine.start(engine.defaultConfig);
      expect(
        engine.reopen(engine.defaultConfig).result,
        EngineResult.alreadyRunning,
      );
      expect(engine.snapshot().isRunning, isTrue);
    });

    test('retains at the same sample rate and runs again', () {
      final engine = MockAudioEngine();
      engine
        ..start(engine.defaultConfig)
        ..stop();
      final reopened = engine.reopen(engine.defaultConfig);
      expect(reopened.result, EngineResult.ok);
      expect(reopened.outcome, ReopenOutcome.retained);
      expect(engine.snapshot().isRunning, isTrue);
      expect(engine.snapshot().devicePresent, isTrue);
    });

    test('clears with the rate outcome when the device changes rate', () {
      final engine = MockAudioEngine();
      engine
        ..start(engine.defaultConfig)
        ..stop();
      final reopened = engine.reopen(
        const EngineConfig(
          sampleRate: 44100,
          bufferFrames: 128,
          inputChannels: MockAudioEngine.defaultInputChannels,
          outputChannels: MockAudioEngine.defaultOutputChannels,
          playbackDeviceId: MockAudioEngine.deviceId,
          captureDeviceId: MockAudioEngine.deviceId,
        ),
      );
      expect(reopened.result, EngineResult.ok);
      expect(reopened.outcome, ReopenOutcome.clearedRate);
      expect(engine.snapshot().sampleRate, 44100);
    });
  });
}
