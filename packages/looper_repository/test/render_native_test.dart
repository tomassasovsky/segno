@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// Save selected audio's path through the real engine: two literal loops
/// rendered to a file by the repository decode to their literal sum.
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;

  test('renders two literal loops to a WAV of their sum', () async {
    final engine = PumpedNativeEngine();
    final ticks = StreamController<void>.broadcast(sync: true);
    final repository = LooperRepository(
      engine: engine,
      ticker: ticks.stream,
      renderPollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      await repository.dispose();
      await ticks.close();
    });
    expect(
      repository.startEngine(
        const EngineConfig(inputChannels: 1, outputChannels: 2),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    expect(
      engine.importTrack(
        0,
        Float32List.fromList([for (var i = 0; i < 16; i++) i + 1.0]),
      ),
      EngineResult.ok,
    );
    expect(
      engine.importTrack(
        1,
        Float32List.fromList([for (var i = 0; i < 24; i++) 100.0 * (i + 1)]),
      ),
      EngineResult.ok,
    );
    expect(engine.commitSession(8, loopBars: 0), EngineResult.ok);
    engine.pump(frames: 0);

    const render = SelectedRender(sources: {0, 1}, tails: RenderTails.cut);
    final measured = repository.measureRender(render);
    expect(measured.result, EngineResult.ok);
    expect(measured.plan!.frames, 48);
    expect(measured.plan!.tempoSet, isFalse);

    final dir = Directory.systemTemp.createTempSync('render_repo');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sum.wav';
    final begun = repository.renderToFile(render, path);
    expect(begun.result, EngineResult.ok);
    engine.pump(frames: 0); // the callback freezes the sources
    final outcome = await begun.job!.outcome;
    expect(outcome, RenderOutcome(result: EngineResult.ok, path: path));

    final data = ByteData.sublistView(File(path).readAsBytesSync());
    expect(data.lengthInBytes, 44 + 48 * 8);
    for (var f = 0; f < 48; f++) {
      final sum = (f % 16 + 1) + 100.0 * (f % 24 + 1);
      expect(data.getFloat32(44 + 8 * f, Endian.little), sum);
      expect(data.getFloat32(48 + 8 * f, Endian.little), sum);
    }
  }, skip: skip);
}
