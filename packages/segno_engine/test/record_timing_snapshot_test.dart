@Tags(['fuzz'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// Runs a real callback between the full snapshot and its first track read.
class _InterleavedBindings extends SegnoEngineBindings {
  _InterleavedBindings(super.dynamicLibrary);

  void Function()? betweenReads;

  @override
  void le_engine_get_track(
    Pointer<le_engine> engine,
    int channel,
    Pointer<le_track_snapshot> out,
  ) {
    final callback = betweenReads;
    betweenReads = null;
    callback?.call();
    super.le_engine_get_track(engine, channel, out);
  }
}

void main() {
  final path = Platform.environment['SEGNO_ENGINE_LIB'];
  test(
    'one timing snapshot stays coherent across a later native publication',
    () {
      final bindings = _InterleavedBindings(DynamicLibrary.open(path!));
      final engine = PumpedNativeEngine(bindings: bindings);
      addTearDown(engine.dispose);
      expect(
        engine.start(
          const EngineConfig(
            sampleRate: 8000,
            inputChannels: 1,
            outputChannels: 1,
            maxLoopFrames: 1024000,
          ),
        ),
        EngineResult.ok,
      );
      expect(
        engine.setRecordTimingSettings(
          editMask: 0x1ff,
          defaultTiming: RecordTiming.bar,
          rememberedDivision: GridDivision.bar,
          trackOverrides: {
            1: RecordTiming.immediately,
            2: RecordTiming.sixteenth,
          },
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 0);
      final revision = engine.snapshot().recordTimingRevision;
      var interleaved = false;
      bindings.betweenReads = () {
        interleaved = true;
        expect(
          engine.setRecordTimingSettings(
            editMask: 0x1f,
            defaultTiming: RecordTiming.half,
            rememberedDivision: GridDivision.half,
            trackOverrides: {
              0: RecordTiming.quarter,
              2: RecordTiming.immediately,
              3: RecordTiming.eighth,
            },
          ),
          EngineResult.ok,
        );
        engine.pump(frames: 0);
      };

      final first = engine.snapshot();
      expect(interleaved, isTrue);
      expect(first.recordTimingRevision, revision);
      expect(first.recordTimingResult, 0);
      expect(first.quantize, isTrue);
      expect(first.quantizeDiv, GridDivision.bar);
      expect(_timings(first), [-1, 0, 6, -1, -1, -1, -1, -1]);

      final second = engine.snapshot();
      expect(second.recordTimingRevision, (revision + 2) & 0xffffffff);
      expect(second.recordTimingResult, 0);
      expect(second.quantize, isTrue);
      expect(second.quantizeDiv, GridDivision.half);
      expect(_timings(second), [4, -1, 0, 5, -1, -1, -1, -1]);
    },
    skip: path == null || path.isEmpty ? 'SEGNO_ENGINE_LIB not set' : null,
  );
}

List<int> _timings(EngineSnapshot snapshot) => [
  for (final track in snapshot.tracks)
    if (track.quantizeOverride == null)
      -1
    else if (track.quantizeOverride!)
      track.quantizeDivOverride!.code + 1
    else
      0,
];
