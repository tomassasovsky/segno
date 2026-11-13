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
  // The `raw_inputs` of a take since #1805; null leaves it out, as a take
  // from before it did.
  List<int>? rawInputs,
  int captureFrames = 0,
  int overrunCount = 0,
  int zeroFilledFrames = 0,
  List<Map<String, dynamic>> layers = const [],
  bool finalized = false,
  String? takeId = zeroTakeId,
}) {
  final json = {
    'slug': dir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last,
    'sample_rate': sampleRate,
    'channel_layout': {
      'master_channels': masterChannels,
      'captured_inputs': capturedInputs,
      'raw_inputs': ?rawInputs,
    },
    'capture_frames': captureFrames,
    'overrun_count': overrunCount,
    'zero_filled_frames': zeroFilledFrames,
    'overrun_gaps': <Map<String, dynamic>>[],
    'layers': layers,
    'take_id': ?takeId,
    'finalized': finalized,
  };
  File('$dir/performance.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// The take id [writeOpenPart] stamps by default: sixteen zero bytes.
const String zeroTakeId = '00000000000000000000000000000000';

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

/// Writes a part the drain sealed: [writeOpenPart] with its RIFF and data
/// sizes patched for [samples].
void writeSealedPart(
  String path,
  Float32List samples, {
  int channels = 2,
  int stream = 0,
  int index = 1,
}) {
  writeOpenPart(
    path,
    samples,
    channels: channels,
    stream: stream,
    index: index,
  );
  final data = samples.length * 4;
  final file = File(path).openSync(mode: FileMode.append);
  try {
    file
      ..setPositionSync(4)
      ..writeFromSync(_u32(84 - 8 + data))
      ..setPositionSync(80)
      ..writeFromSync(_u32(data));
  } finally {
    file.closeSync();
  }
}

/// Writes one checkpoint slot (`checkpoint-a.json` for [slot] 0, `-b` for
/// 1) in the shape `perf_checkpoint.c` writes, its checksum computed with
/// [digest] over every byte before the `"checksum"` key.
void writeCheckpointSlot(
  String dir, {
  required String Function(Uint8List bytes) digest,
  required List<({int stream, int channels, List<Map<String, dynamic>> parts})>
  streams,
  int slot = 0,
  int sequence = 1,
  String takeId = zeroTakeId,
  String bootId = 'boot-a',
  int volumeGeneration = -1,
  int sampleRate = 48000,
  int eventsBytes = 0,
  List<String> layers = const [],
}) {
  var frames = -1;
  for (final s in streams) {
    final held = s.parts.fold<int>(0, (sum, p) => sum + (p['frames'] as int));
    if (frames < 0 || held < frames) frames = held;
  }
  final streamsJson = [
    for (final s in streams)
      {'stream': s.stream, 'channels': s.channels, 'parts': s.parts},
  ];
  final body = StringBuffer()
    ..write('{\n  "version": 1,\n  "sequence": $sequence,\n')
    ..write('  "take_id": "$takeId",\n  "boot_id": "$bootId",\n')
    ..write('  "volume_generation": $volumeGeneration,\n')
    ..write('  "sample_rate": $sampleRate,\n  "encoding": "f32",\n')
    ..write('  "frames": ${frames < 0 ? 0 : frames},\n  "overs": 0,\n')
    ..write('  "streams": ${jsonEncode(streamsJson)},\n')
    ..write('  "events_bytes": $eventsBytes,\n')
    ..write('  "layers": ${jsonEncode(layers)},\n')
    ..write('  "written_at_ms": 1791244800000,\n  ');
  final covered = utf8.encode(body.toString());
  final checksum = digest(Uint8List.fromList(covered));
  File('$dir/checkpoint-${slot == 0 ? 'a' : 'b'}.json')
      .writeAsStringSync('$body"checksum": "$checksum"\n}\n');
}

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
