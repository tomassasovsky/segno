@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

class _Persistence implements MixSettingsPersistence {
  String? value;

  @override
  Future<String?> read(String device) async => value;

  @override
  Future<void> write(String device, MixSettingsSnapshot candidate) async {
    value = device;
  }

  @override
  Future<void> restore(String device, String? checkpoint) async {
    value = checkpoint;
  }
}

Future<MixSettingsOutcome> _drive(
  PumpedNativeEngine engine,
  StreamController<void> ticks,
  Future<MixSettingsOutcome> operation, {
  required double input,
}) async {
  var completed = false;
  unawaited(operation.then((_) => completed = true));
  for (var attempt = 0; attempt < 100 && !completed; attempt++) {
    engine.pump(frames: 64, input: input);
    ticks.add(null);
    await Future<void>.delayed(Duration.zero);
  }
  expect(completed, isTrue, reason: 'mix operation did not settle');
  return await operation;
}

/// One more block at [input], and the absolute peak of each of its two output
/// channels, read from the audio it played: the snapshot's output peaks are
/// meters that fall instead of dropping (SEG-114).
({double left, double right}) _playedPeaks(
  PumpedNativeEngine engine, {
  required double input,
}) {
  const frames = 64;
  final out = Float32List(2 * frames);
  engine.pump(frames: frames, input: input, output: out);
  var left = 0.0;
  var right = 0.0;
  for (var i = 0; i < frames; i++) {
    if (out[2 * i].abs() > left) left = out[2 * i].abs();
    if (out[2 * i + 1].abs() > right) right = out[2 * i + 1].abs();
  }
  return (left: left, right: right);
}

void main() {
  test(
    'settings coordinator pan reaches live monitor and track output',
    () async {
      final engine = PumpedNativeEngine();
      final ticks = StreamController<void>.broadcast(sync: true);
      final repository = LooperRepository(engine: engine, ticker: ticks.stream);
      final persistence = _Persistence();
      late final MixSettingsCoordinator coordinator;
      addTearDown(() async {
        await coordinator.close();
        await repository.dispose();
        await ticks.close();
      });

      expect(
        repository.startEngine(
          const EngineConfig(
            inputChannels: 1,
            outputChannels: 2,
            maxLoopFrames: 1000,
          ),
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 0);
      ticks.add(null);
      expect(
        await repository.settleMixSettings(pollInterval: Duration.zero),
        EngineResult.ok,
      );
      coordinator = MixSettingsCoordinator(
        repository: repository,
        persistence: persistence,
        device: () => 'native-test-device',
      );

      engine
        ..setMonitorInputEnabled(input: 0, enabled: true)
        ..setMonitorInputOutput(input: 0, mask: 3)
        ..pump(frames: 0);
      final inputPan = await _drive(
        engine,
        ticks,
        coordinator.setInputPan(input: 0, pan: -1),
        input: .25,
      );
      expect(inputPan.isOk, isTrue);
      final monitor = _playedPeaks(engine, input: .25);
      expect(monitor.left, greaterThan(.2));
      expect(monitor.right, 0);

      engine
        ..setMonitorInputEnabled(input: 0, enabled: false)
        ..pump(frames: 0);
      expect(
        engine.importTrack(0, Float32List.fromList(List.filled(64, .25))),
        EngineResult.ok,
      );
      expect(engine.commitSession(64, loopBeats: 0), EngineResult.ok);
      engine
        ..pump(frames: 0)
        ..play()
        ..pump(frames: 0);
      final trackPan = await _drive(
        engine,
        ticks,
        coordinator.setTrackPan(1),
        input: 0,
      );
      expect(trackPan.isOk, isTrue);
      final track = _playedPeaks(engine, input: 0);
      expect(track.left, 0);
      expect(track.right, greaterThan(.2));
    },
  );
}
