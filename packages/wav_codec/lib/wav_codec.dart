/// A minimal WAV encoder/decoder.
///
/// `WavCodec` is the 32-bit IEEE-float format Segno stores its loop stems and
/// mixdowns in; `Pcm24PartHeader`, `Pcm24Writer` and `readPcm24Frames` are
/// the ordered 24-bit parts performance recordings are written as. Pure Dart,
/// no Flutter dependency, so tooling that must not depend on the framework
/// (e.g. `daw_export`) can still read the files this writes.
library;

export 'src/pcm24_part.dart';
export 'src/wav.dart';
