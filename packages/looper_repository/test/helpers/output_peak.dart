import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// Pumps [frames] through a mono-output [engine] and returns the absolute
/// peak of the audio it played.
///
/// The snapshot's output peaks are meters: they fall instead of dropping
/// (SEG-114), so a test that probes one block's level reads the block.
double pumpOutputPeak(
  PumpedNativeEngine engine, {
  required int frames,
  double input = 0,
}) {
  final out = Float32List(frames);
  engine.pump(frames: frames, input: input, output: out);
  var peak = 0.0;
  for (final sample in out) {
    if (sample.abs() > peak) peak = sample.abs();
  }
  return peak;
}
