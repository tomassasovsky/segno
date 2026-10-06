import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes a `performance.json` matching the shape `perf_drain.c` (parts 2-5)
/// actually produces, into [dir] — the fields `PerformanceRepository._finalize`
/// reads back (`sample_rate`, `channel_layout`, `capture_frames`,
/// `overrun_count`, `zero_filled_frames`, `overrun_gaps`, `layers`) plus the
/// always-`false`
/// `finalized` the drain thread writes on every cycle while armed.
void writeNativeSidecar(
  String dir, {
  int sampleRate = 48000,
  int masterChannels = 2,
  List<int> capturedInputs = const [],
  int captureFrames = 0,
  int overrunCount = 0,
  int zeroFilledFrames = 0,
  List<Map<String, dynamic>> layers = const [],
  bool finalized = false,
}) {
  final json = {
    'slug': dir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last,
    'sample_rate': sampleRate,
    'channel_layout': {
      'master_channels': masterChannels,
      'captured_inputs': capturedInputs,
    },
    'capture_frames': captureFrames,
    'overrun_count': overrunCount,
    'zero_filled_frames': zeroFilledFrames,
    'overrun_gaps': <Map<String, dynamic>>[],
    'layers': layers,
    'finalized': finalized,
  };
  File(
    '$dir/performance.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// Writes [samples] as raw little-endian float32 bytes to [path]: the
/// `master.pcm` / `input-<n>.pcm` a capture from before #1198 left.
void writeRawPcm(String path, Float32List samples) {
  final bytes = ByteData(samples.length * 4);
  for (var i = 0; i < samples.length; i++) {
    bytes.setFloat32(i * 4, samples[i], Endian.little);
  }
  File(path).writeAsBytesSync(bytes.buffer.asUint8List());
}

/// Writes an open part the way `perf_drain.c` leaves one when the process
/// dies: the 84-byte header with its RIFF and data sizes still 0, then the
/// float [samples] as written, plus [tornBytes] of an unfinished frame.
void writeOpenPart(
  String path,
  Float32List samples, {
  int channels = 2,
  int stream = 0,
  int index = 1,
  int sampleRate = 48000,
  int tornBytes = 0,
}) {
  final header = ByteData(84);
  void tag(int at, String text) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 3, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * channels * 4, Endian.little)
    ..setUint16(32, channels * 4, Endian.little)
    ..setUint16(34, 32, Endian.little);
  tag(36, 'sgno');
  header
    ..setUint32(40, 32, Endian.little)
    ..setUint16(60, stream, Endian.little)
    ..setUint16(62, index, Endian.little);
  tag(76, 'data');
  final body = ByteData(samples.length * 4 + tornBytes);
  for (var i = 0; i < samples.length; i++) {
    body.setFloat32(i * 4, samples[i], Endian.little);
  }
  File(path).writeAsBytesSync([
    ...header.buffer.asUint8List(),
    ...body.buffer.asUint8List(),
  ]);
}

/// The RIFF size (offset 4) and data size (offset 80) of the part at [path].
(int riff, int data) partSizes(String path) {
  final bytes = ByteData.sublistView(File(path).readAsBytesSync());
  return (
    bytes.getUint32(4, Endian.little),
    bytes.getUint32(80, Endian.little),
  );
}
