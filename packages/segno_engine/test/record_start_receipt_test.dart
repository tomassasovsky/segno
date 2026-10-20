@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  group('actual native recording-start pair', () {
    late PumpedNativeEngine engine;
    const config = EngineConfig(
      sampleRate: 8000,
      inputChannels: 1,
      outputChannels: 1,
      maxLoopFrames: 32000,
    );
    setUp(() {
      engine = PumpedNativeEngine();
      expect(engine.start(config), EngineResult.ok);
    });
    tearDown(() => engine.dispose());

    test('pair and new receipt require callback publication', () {
      final choices = [
        (0, false),
        (1, false),
        (2, false),
        (4, false),
        (0, true),
      ];
      var revision = 0;
      var prior = (0, false);
      for (final (bars, sound) in choices) {
        expect(
          engine.setRecordStartSettings(
            countInBars: bars,
            soundStart: sound,
            editKind: RecordStartEditKind.restore,
          ),
          EngineResult.ok,
        );
        expect(engine.commandsSettled, isFalse);
        final pending = engine.snapshot();
        expect((pending.countInBars, pending.autoRecord), prior);
        expect(pending.recordStartRevision, revision);
        expect(
          engine.setRecordStartSettings(
            countInBars: bars,
            soundStart: sound,
            editKind: RecordStartEditKind.restore,
          ),
          EngineResult.notReady,
        );
        expect(engine.record(), EngineResult.notReady);
        engine.pump(frames: 0);
        expect(engine.commandsSettled, isTrue);
        final accepted = engine.snapshot();
        expect((accepted.countInBars, accepted.autoRecord), (bars, sound));
        expect(accepted.recordStartRevision, ++revision);
        expect(accepted.recordStartResult, 0);
        prior = (bars, sound);
      }
    });

    test('capture ahead in callback refuses with exact prior pair', () {
      expect(engine.record(), EngineResult.ok);
      expect(
        engine.setRecordStartSettings(
          countInBars: 2,
          soundStart: false,
          editKind: RecordStartEditKind.countIn,
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 1);
      expect(engine.commandsSettled, isTrue);
      final refused = engine.snapshot();
      expect(refused.tracks.first.state, TrackState.recording);
      expect((refused.countInBars, refused.autoRecord), (0, false));
      expect(refused.recordStartRevision, 1);
      expect(refused.recordStartResult, -1);
    });

    test('restart keeps accepted pair but resets transient receipt', () {
      expect(
        engine.setRecordStartSettings(
          countInBars: 0,
          soundStart: true,
          editKind: RecordStartEditKind.sound,
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 0);
      expect(engine.commandsSettled, isTrue);
      expect(engine.snapshot().recordStartRevision, 1);
      expect(engine.stop(), EngineResult.ok);
      expect(engine.start(config), EngineResult.ok);
      final restarted = engine.snapshot();
      expect((restarted.countInBars, restarted.autoRecord), (0, true));
      expect(restarted.recordStartRevision, 0);
      expect(restarted.recordStartResult, 0);
    });
  }, skip: library == null ? 'SEGNO_ENGINE_LIB is required' : false);

  test('mock validates pair and exposes a completed receipt', () {
    final engine = MockAudioEngine();
    addTearDown(engine.dispose);
    expect(engine.start(engine.defaultConfig), EngineResult.ok);
    for (final bars in [-1, 3, 5, 16, 64]) {
      expect(
        engine.setRecordStartSettings(
          countInBars: bars,
          soundStart: false,
          editKind: RecordStartEditKind.countIn,
        ),
        EngineResult.invalid,
      );
    }
    expect(
      engine.setRecordStartSettings(
        countInBars: 1,
        soundStart: true,
        editKind: RecordStartEditKind.restore,
      ),
      EngineResult.invalid,
    );
    expect(engine.snapshot().recordStartRevision, 0);
    expect(
      engine.setRecordStartSettings(
        countInBars: 0,
        soundStart: true,
        editKind: RecordStartEditKind.sound,
      ),
      EngineResult.ok,
    );
    expect(engine.snapshot().recordStartRevision, 1);
    expect(engine.snapshot().recordStartResult, 0);
    expect(engine.snapshot().autoRecord, isTrue);
  });
}
