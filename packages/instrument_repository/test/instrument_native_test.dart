@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:segno_engine/segno_engine.dart';

/// The repository against the REAL engine through the device-free pump.
/// Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run segno_engine/tool/build_test_lib.sh'
      : null;

  test(
    'plays a note through the repository and sees it on the snapshot',
    () async {
      final engine = PumpedNativeEngine();
      final snapshots = StreamController<EngineSnapshot>();
      final repository = InstrumentRepository(
        engine: engine,
        snapshots: snapshots.stream,
      );
      addTearDown(() async {
        await repository.dispose();
        await snapshots.close();
        engine.dispose();
      });
      expect(
        engine.start(
          const EngineConfig(
            inputChannels: 1,
            outputChannels: 2,
            maxLoopFrames: 48000,
          ),
        ),
        EngineResult.ok,
      );
      Future<void> tick() async {
        snapshots.add(engine.snapshot());
        await Future<void>.delayed(Duration.zero);
      }

      final copy = const InstrumentsWorkingCopy()
          .add(id: 'keys', name: 'Keys', soundId: 'pad', params: [42, 60, 0])
          .copy!;
      expect(repository.apply(copy), EngineResult.ok);
      await tick(); // the first epoch sends the slot
      engine.pump(frames: 0);
      expect(engine.snapshot().instruments.patches[0], isNot(-1));

      final token = repository.notes.press('keys', const [60, 64, 67])!;
      engine.pump(frames: 256);
      await tick();
      expect(engine.snapshot().instruments.voices[0], 3);
      expect(repository.state.voices, {'keys': 3});

      repository.notes.release(token);
      for (var i = 0; i < 48; i++) {
        engine.pump();
      }
      await tick();
      expect(repository.state.voices, {'keys': 0});
    },
    skip: skip,
  );
}
