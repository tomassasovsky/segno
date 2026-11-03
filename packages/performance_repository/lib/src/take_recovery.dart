import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:performance_repository/src/legacy_capture.dart';
import 'package:performance_repository/src/models/recording_format.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:wav_codec/wav_codec.dart';

/// The two checkpoint slot files of a take (plan D4).
const List<String> checkpointSlotNames = [
  'checkpoint-a.json',
  'checkpoint-b.json',
];

/// This boot's kernel id (`/proc/sys/kernel/random/boot_id`), or empty
/// where the platform has none: recovery then trusts only the checkpoint.
String readBootId() {
  try {
    return File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
  } on FileSystemException {
    return '';
  }
}

/// What [reconcileTake] made of a take's files.
@immutable
class ReconciledTake {
  /// Creates a [ReconciledTake].
  const ReconciledTake({
    required this.takeId,
    required this.sampleRate,
    required this.streams,
    required this.frames,
    required this.parts,
    required this.checkpoint,
    required this.trustedFiles,
  });

  /// The take's id, 32 lower-case hex digits; null for a take with no id
  /// and no part, which is left as it is.
  final String? takeId;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Each stream the take wrote and its channel count, master first.
  final List<({int stream, int channels})> streams;

  /// Frames every stream holds: the take's length.
  final int frames;

  /// Every part kept, sealed, in playback order.
  final List<TakePart> parts;

  /// The newest valid checkpoint, or null when neither slot reads.
  final TakeCheckpoint? checkpoint;

  /// Whether the files were trusted beyond the checkpoint.
  final bool trustedFiles;
}

/// Brings the part files of the take in [dir] to one consistent, sealed
/// state, and says what it holds (#1198 D4, Part 8).
///
/// How much audio counts: on a [live] finalize (the drain has just stopped
/// in this boot) every whole frame the files hold. On recovery, the same
/// only when the newest checkpoint slot was written in this boot
/// ([bootId]) on Internal storage; otherwise only what the checkpoint says
/// is durable, since after a power cut a file's size can cover blocks that
/// never received the audio. A take with no valid checkpoint (cut in its
/// first seconds) has nothing better than its files. Whatever counts, every
/// stream ends at the same frame: the fewest any stream holds.
///
/// Parts past that frame are deleted; the last kept part of each stream is
/// truncated to its share, its sizes patched, and its digest and overs
/// computed from what it now holds. A part the drain sealed with exactly
/// these contents keeps its recorded digest and overs.
///
/// [native] is the sidecar's fields, or null when it is missing or does not
/// read: the streams then come from the checkpoint. A stream with no part of
/// this take on disk is left out rather than shortening the others to
/// nothing; a file that is not one of this take's parts is never touched.
/// Returns null, touching nothing, when there is no way to know the take's
/// shape or identity.
/// Runs synchronous file I/O; call it on a background isolate.
ReconciledTake? reconcileTake({
  required String dir,
  required Map<String, dynamic>? native,
  required bool live,
  required String bootId,
  required StorageIo storageIo,
}) {
  TakeCheckpoint? checkpoint;
  Uint8List? slot(String name) {
    final file = File('$dir/$name');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  try {
    checkpoint = TakeCheckpoint.fromSlots(
      slot(checkpointSlotNames[0]),
      slot(checkpointSlotNames[1]),
      digest: storageIo.digestBytes,
    );
  } on FormatException {
    checkpoint = null;
  }

  // Neither a sidecar nor a checkpoint: nothing says what the take is.
  if (native == null && checkpoint == null) return null;
  final nativeTake = native?['take_id'];
  final takeId = nativeTake is String ? nativeTake : checkpoint?.takeId;
  if (takeId != null && !_takeIdHex.hasMatch(takeId)) return null;
  if (checkpoint != null && checkpoint.takeId != takeId) return null;
  final streams = native != null
      ? streamsOf(native)
      : [
          for (final s in checkpoint!.streams)
            (stream: s.stream, channels: s.channels),
        ];
  if (streams == null || streams.isEmpty) return null;
  if (takeId == null) {
    // No identity to check a part against: only a take with no part at all
    // (its stems render from the loops and the log alone) goes on as it is.
    final anyPart = streams.any(
      (s) => File('$dir/${partFileName(s.stream, 1)}').existsSync(),
    );
    if (anyPart) return null;
    return ReconciledTake(
      takeId: null,
      sampleRate: 0,
      streams: streams,
      frames: 0,
      parts: const [],
      checkpoint: checkpoint,
      trustedFiles: true,
    );
  }
  final nativeRate = native?['sample_rate'];
  final sampleRate = nativeRate is int ? nativeRate : checkpoint?.sampleRate;
  if (sampleRate == null || sampleRate < 1) return null;

  final trusted =
      live ||
      checkpoint == null ||
      checkpoint.trustsFilesBeyond(
        currentBootId: bootId,
        currentGeneration: PerfTarget.internalVolume,
      );

  // What is on disk, stream by stream, until a part is missing or is not
  // this take's.
  final onDisk = <int, List<_DiskPart>>{};
  var frames = -1;
  for (final s in streams) {
    final frameBytes = s.channels * RecordedPartHeader.bytesPerSample;
    final parts = <_DiskPart>[];
    for (var index = 1; ; index++) {
      final file = File('$dir/${partFileName(s.stream, index)}');
      if (!file.existsSync()) break;
      final length = file.lengthSync();
      final RecordedPartHeader header;
      try {
        header = RecordedPartHeader.decode(_head(file));
      } on Object {
        // Not a part header (a bad tag, or a field no part can hold).
        break;
      }
      if (_hex(header.takeId) != takeId ||
          header.stream != s.stream ||
          header.partIndex != index ||
          header.channels != s.channels ||
          header.sampleRate != sampleRate) {
        break;
      }
      var held = (length - RecordedPartHeader.headerBytes) ~/ frameBytes;
      if (header.dataBytes > 0 && header.frames < held) held = header.frames;
      parts.add(_DiskPart(index, file, length, held, header));
      // A part still open, or sealed with frames that never reached it, is
      // where the stream's audio stops: a later part would play early.
      if (header.dataBytes == 0 || held < header.frames) break;
    }
    // A stream with no part of this take on disk has nothing to keep or
    // delete; it must not shorten the others to nothing.
    if (parts.isEmpty) continue;
    var available = parts.fold<int>(0, (sum, p) => sum + p.frames);
    if (!trusted) {
      // A stream the checkpoint does not know cannot be bounded by it, and
      // reading it as holding nothing would cut every stream to nothing.
      final durable = _checkpointFrames(checkpoint, s.stream);
      if (durable == null) return null;
      if (durable < available) available = durable;
    }
    onDisk[s.stream] = parts;
    if (frames < 0 || available < frames) frames = available;
  }

  // The drain's own record of each sealed part, to keep rather than redo.
  final recorded = <(int, int), TakePart>{};
  final records = trusted
      ? _sidecarParts(native)
      : [for (final s in checkpoint.streams) ...s.parts];
  for (final part in records) {
    if (part.isSealed) recorded[(part.stream, part.index)] = part;
  }

  final kept = <TakePart>[];
  for (final s in streams) {
    final frameBytes = s.channels * RecordedPartHeader.bytesPerSample;
    var remaining = frames;
    for (final part in onDisk[s.stream] ?? const <_DiskPart>[]) {
      if (remaining == 0 && part.index > 1) {
        part.file.deleteSync();
        continue;
      }
      final keep = part.frames < remaining ? part.frames : remaining;
      remaining -= keep;
      final dataBytes = keep * frameBytes;
      final bytes = RecordedPartHeader.headerBytes + dataBytes;
      final name = partFileName(s.stream, part.index);
      final known = recorded[(s.stream, part.index)];
      if (known != null &&
          known.frames == keep &&
          known.bytes == bytes &&
          part.length == bytes &&
          part.header.dataBytes == dataBytes) {
        kept.add(known);
        continue;
      }
      _seal(part, dataBytes);
      final digest = storageIo.digestFile(
        part.file.path,
        offset: RecordedPartHeader.headerBytes,
        length: dataBytes,
      );
      if (digest is! FileDigested) {
        throw FileSystemException('cannot read the part back', part.file.path);
      }
      kept.add(
        TakePart(
          stream: s.stream,
          index: part.index,
          file: name,
          frames: keep,
          bytes: bytes,
          overs: countOvers(part.file.path, dataBytes),
          sha256: digest.sha256,
        ),
      );
    }
  }

  // Past the durable record, the log may be torn too.
  if (!trusted) {
    final log = File('$dir/events.log');
    if (log.existsSync() && log.lengthSync() > checkpoint.eventsBytes) {
      final handle = log.openSync(mode: FileMode.append);
      try {
        handle
          ..truncateSync(checkpoint.eventsBytes)
          ..flushSync();
      } finally {
        handle.closeSync();
      }
    }
  }

  return ReconciledTake(
    takeId: takeId,
    sampleRate: sampleRate,
    streams: streams,
    frames: frames < 0 ? 0 : frames,
    parts: kept,
    checkpoint: checkpoint,
    trustedFiles: trusted,
  );
}

/// Samples among the first [dataBytes] of payload of the part at [path]
/// whose magnitude exceeds 1.0, read [legacyChunkBytes] at a time.
int countOvers(String path, int dataBytes) {
  final buffer = Uint8List(legacyChunkBytes);
  final file = File(path).openSync();
  var overs = 0;
  try {
    file.setPositionSync(RecordedPartHeader.headerBytes);
    var left = dataBytes;
    while (left > 0) {
      final want = left < buffer.length ? left : buffer.length;
      // Fill the chunk, so a short read never splits a sample.
      var filled = 0;
      while (filled < want) {
        final got = file.readIntoSync(buffer, filled, want);
        if (got == 0) break;
        filled += got;
      }
      final samples = Float32List.view(buffer.buffer, 0, filled ~/ 4);
      for (final sample in samples) {
        if (isOver(sample)) overs++;
      }
      if (filled < want) break;
      left -= filled;
    }
  } finally {
    file.closeSync();
  }
  return overs;
}

/// The streams a take wrote, from its sidecar's `channel_layout`: the
/// master (stream 0, 1 or 2 channels) and each captured input `n` (stream
/// `1 + n`, stereo). Null when the layout does not read, which nothing may
/// guess at.
List<({int stream, int channels})>? streamsOf(Map<String, dynamic> native) {
  final layout = native['channel_layout'] ?? const <String, dynamic>{};
  if (layout is! Map<String, dynamic>) return null;
  final master = layout['master_channels'] ?? 1;
  final inputs = layout['captured_inputs'] ?? const <dynamic>[];
  if (master is! int || master < 1 || master > 2 || inputs is! List) {
    return null;
  }
  final streams = [(stream: 0, channels: master)];
  for (final input in inputs) {
    if (input is! int || input < 0) return null;
    streams.add((stream: 1 + input, channels: 2));
  }
  return streams;
}

List<TakePart> _sidecarParts(Map<String, dynamic>? native) {
  try {
    return [
      for (final p in native?['parts'] as List<dynamic>? ?? const [])
        TakePart.fromJson(p as Map<String, dynamic>),
    ];
  } on Object {
    return const [];
  }
}

int? _checkpointFrames(TakeCheckpoint checkpoint, int stream) {
  for (final s in checkpoint.streams) {
    if (s.stream == stream) return s.frames;
  }
  return null;
}

/// Truncates [part] to its header and [dataBytes] of payload and patches
/// its RIFF and data sizes, flushed to the device.
void _seal(_DiskPart part, int dataBytes) {
  final file = part.file.openSync(mode: FileMode.append);
  try {
    file
      ..truncateSync(RecordedPartHeader.headerBytes + dataBytes)
      ..setPositionSync(0)
      ..writeFromSync(part.header.withDataBytes(dataBytes).encode())
      ..flushSync();
  } finally {
    file.closeSync();
  }
}

Uint8List _head(File file) {
  final handle = file.openSync();
  try {
    return handle.readSync(RecordedPartHeader.headerBytes);
  } finally {
    handle.closeSync();
  }
}

final RegExp _takeIdHex = RegExp(r'^[0-9a-f]{32}$');

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _DiskPart {
  _DiskPart(this.index, this.file, this.length, this.frames, this.header);

  final int index;
  final File file;
  final int length;
  final int frames;
  final RecordedPartHeader header;
}
