import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

import 'fake_audio_engine.dart';

void main() {
  test('accepted performance arm freezes the selected output facts until '
      'successful disarm', () {
    final engine = FakeAudioEngine()
      ..nextSnapshot = const EngineSnapshot.initial().copyWith(
        outputChannels: 3,
        outputEnabledMask: 0x4,
        tempoBpm: 96,
      )
      ..outputLevel[1] = 0.4
      ..outputMuted[1] = true;
    expect(engine.setPerfFollowOutput(follow: true), EngineResult.ok);

    expect(engine.perfArm('/take'), EngineResult.ok);
    final armed = engine.snapshot();
    expect(armed.isPerfArmed, isTrue);
    expect(armed.perfCaptureBus, 1);
    expect(armed.perfCaptureMask, 0x4);
    expect(armed.perfOutputEnabledMask, 0x4);
    expect(armed.perfOutputLevel, 0.4);
    expect(armed.perfOutputMuted, isTrue);
    expect(armed.perfFollowOutput, isTrue);

    engine
      ..setPerfFollowOutput(follow: false)
      ..outputLevel[1] = 0.8
      ..nextSnapshot = engine.nextSnapshot.copyWith(tempoBpm: 132)
      ..perfDisarmResult = EngineResult.device;
    expect(engine.snapshot().tempoBpm, 132);
    expect(engine.snapshot().perfFollowOutput, isTrue);
    expect(engine.snapshot().perfOutputLevel, 0.4);
    expect(engine.perfDisarm(), EngineResult.device);
    expect(engine.snapshot().isPerfArmed, isTrue);

    engine.perfDisarmResult = EngineResult.ok;
    expect(engine.perfDisarm(), EngineResult.ok);
    expect(engine.snapshot().isPerfArmed, isFalse);
  });

  test('an explicitly reported zero-output device refuses arm', () {
    final engine = FakeAudioEngine()
      ..nextSnapshot = const EngineSnapshot.initial().copyWith(
        outputChannels: 0,
      );
    expect(engine.perfArm('/take'), EngineResult.invalid);
    expect(engine.snapshot().isPerfArmed, isFalse);
  });

  test('tests can retain an explicitly injected performance snapshot', () {
    final engine = FakeAudioEngine()
      ..publishPerfCommands = false
      ..nextSnapshot = const EngineSnapshot.initial().copyWith(
        outputChannels: 2,
        isPerfArmed: true,
        perfCaptureBus: 0,
        perfCaptureMask: 0x2,
      );
    expect(engine.perfArm('/take'), EngineResult.ok);
    expect(engine.snapshot().perfCaptureMask, 0x2);
    expect(engine.perfDisarm(), EngineResult.ok);
    expect(engine.snapshot().isPerfArmed, isTrue);
  });
}
