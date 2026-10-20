@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  group('actual native Hear click receipt', () {
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

    test('each literal native code confirms only after callback', () {
      var revision = 0;
      for (final mode in [
        ClickMode.off,
        ClickMode.recFirst,
        ClickMode.rec,
        ClickMode.playRec,
      ]) {
        final prior = engine.snapshot().clickMode;
        expect(engine.setClickMode(mode), EngineResult.ok);
        expect(engine.commandsSettled, isFalse);
        expect(engine.snapshot().clickMode, prior);
        expect(engine.snapshot().clickModeRevision, revision);
        expect(engine.setClickMode(mode), EngineResult.notReady);
        engine.pump(frames: 0);
        // Acquire publication BEFORE the synchronous receipt snapshot.
        expect(engine.commandsSettled, isTrue);
        final accepted = engine.snapshot();
        expect(accepted.clickMode, mode);
        expect(accepted.clickModeRevision, ++revision);
        expect(accepted.clickModeResult, 0);
      }
    });

    test('same value capture race publishes refusal with prior mode', () {
      expect(engine.setClickMode(ClickMode.recFirst), EngineResult.ok);
      engine.pump(frames: 0);
      expect(engine.commandsSettled, isTrue);
      expect(engine.snapshot().clickModeRevision, 1);
      expect(engine.record(), EngineResult.ok);
      expect(engine.setClickMode(ClickMode.recFirst), EngineResult.ok);
      engine.pump(frames: 1);
      expect(engine.commandsSettled, isTrue);
      final refused = engine.snapshot();
      expect(refused.tracks.first.state, TrackState.recording);
      expect(refused.clickMode, ClickMode.recFirst);
      expect(refused.clickModeRevision, 2);
      expect(refused.clickModeResult, -1);
      expect(engine.setClickMode(ClickMode.off), EngineResult.invalid);
      expect(engine.snapshot().clickModeRevision, 2);
      expect(engine.snapshot().tracks.first.state, TrackState.recording);
    });

    test('mode before capture accepts and restart preserves actual mode', () {
      expect(engine.setClickMode(ClickMode.playRec), EngineResult.ok);
      expect(engine.record(), EngineResult.ok);
      engine.pump(frames: 1);
      expect(engine.commandsSettled, isTrue);
      expect(engine.snapshot().clickMode, ClickMode.playRec);
      expect(engine.snapshot().clickModeResult, 0);
      expect(engine.stop(), EngineResult.ok);
      expect(engine.start(config), EngineResult.ok);
      final restarted = engine.snapshot();
      expect(restarted.clickMode, ClickMode.playRec);
      expect(restarted.clickModeRevision, 0);
      expect(restarted.clickModeResult, 0);
      expect(engine.setClickMode(ClickMode.off), EngineResult.ok);
      engine.pump(frames: 0);
      expect(engine.commandsSettled, isTrue);
      expect(engine.snapshot().clickModeRevision, 1);
      expect(engine.snapshot().clickMode, ClickMode.off);
    });
  }, skip: library == null ? 'SEGNO_ENGINE_LIB is required' : false);

  test(
    'mock receipt completes synchronously without inventing capture state',
    () {
      final engine = MockAudioEngine();
      addTearDown(engine.dispose);
      expect(engine.setClickMode(ClickMode.recFirst), EngineResult.notRunning);
      expect(engine.start(engine.defaultConfig), EngineResult.ok);
      expect(engine.setClickMode(ClickMode.recFirst), EngineResult.ok);
      expect(engine.snapshot().clickModeRevision, 1);
      expect(engine.setClickMode(ClickMode.recFirst), EngineResult.ok);
      expect(engine.snapshot().clickModeRevision, 2);
      expect(engine.snapshot().clickModeResult, 0);
      expect(engine.stop(), EngineResult.ok);
      expect(engine.start(engine.defaultConfig), EngineResult.ok);
      expect(engine.snapshot().clickMode, ClickMode.recFirst);
      expect(engine.snapshot().clickModeRevision, 0);
    },
  );
}
