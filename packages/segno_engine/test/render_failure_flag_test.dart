@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  group('actual native render failure flag', () {
    late PumpedNativeEngine engine;
    late Directory dir;
    setUp(() {
      engine = PumpedNativeEngine();
      dir = Directory.systemTemp.createTempSync('render_failure_flag');
    });
    tearDown(() {
      engine.dispose();
      dir.deleteSync(recursive: true);
    });

    PerformanceRenderProgress finish() {
      expect(engine.renderBegin(dir.path), EngineResult.ok);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var progress = engine.renderPoll();
      while (!progress.done && DateTime.now().isBefore(deadline)) {
        sleep(const Duration(milliseconds: 5));
        progress = engine.renderPoll();
      }
      expect(progress.done, isTrue);
      return progress;
    }

    test('a missing manifest finishes as failed', () {
      expect(finish().failed, isTrue);
    });

    test('a valid manifest with nothing to render does not fail', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        '{"sample_rate": 4800, "capture_frames": 4, '
        '"armSnapshot": {"followOutput": false, "captureMask": 1, '
        '"tracks": []}, "disarmSnapshot": {"tracks": []}, "layers": []}',
      );
      expect(finish().failed, isFalse);
    });
  }, skip: library == null ? 'SEGNO_ENGINE_LIB is required' : false);
}
