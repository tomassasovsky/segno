@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
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
  return operation;
}

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;

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
      expect(engine.snapshot().outputPeaks[0], greaterThan(.2));
      expect(engine.snapshot().outputPeaks[1], 0);

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
      expect(engine.snapshot().outputPeaks[0], 0);
      expect(engine.snapshot().outputPeaks[1], greaterThan(.2));
    },
    skip: skip,
  );
}
