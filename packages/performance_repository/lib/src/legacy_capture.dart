import 'dart:io';
import 'dart:typed_data';

import 'package:performance_repository/src/models/recording_format.dart';
import 'package:wav_codec/wav_codec.dart';

/// The most a legacy conversion reads at once: 1 MiB, rounded down to whole
/// frames. A raw take of any length converts in this much memory (#1078).
const int legacyChunkBytes = 1 << 20;

/// The raw file a capture from before #1198 wrote for [stream]: `master.pcm`
/// for stream 0, `input-<n>.pcm` for stream `1 + n`.
String legacyPcmName(int stream) =>
    stream == 0 ? 'master.pcm' : 'input-${stream - 1}.pcm';

/// The part file name the drain gives part [index] of [stream]:
/// `master-001.wav`, `input-3-002.wav`.
String partFileName(int stream, int index) {
  final number = index.toString().padLeft(3, '0');
  return stream == 0 ? 'master-$number.wav' : 'input-${stream - 1}-$number.wav';
}

/// Converts the raw native-endian float32 stream at [pcmPath] into ordered
/// float WAV parts in [dir], the format the drain has written since #1198,
/// and returns them in order, without digests.
///
/// The samples are copied unchanged: a part's payload is the raw file's
/// bytes. A torn trailing frame (a crash mid-write) is dropped. Reads at most
/// [chunkBytes] at a time, so memory stays bounded whatever the file's size;
/// [onRead] sees the size of every read (a test checks the bound). An empty
/// stream still gets one empty part, as the drain opens one at arm.
///
/// On any failure every part this call created is deleted and the error is
/// rethrown: the raw file is the only copy until the caller has recorded the
/// parts durably, and it is never touched here.
List<TakePart> convertRawStream({
  required String pcmPath,
  required String dir,
  required int stream,
  required int channels,
  required int sampleRate,
  required Uint8List takeId,
  int partBytes = RecordedPartWriter.defaultPartBytes,
  int chunkBytes = legacyChunkBytes,
  void Function(int bytes)? onRead,
}) {
  final frameBytes = channels * RecordedPartHeader.bytesPerSample;
  final chunk = chunkBytes ~/ frameBytes * frameBytes;
  if (chunk < frameBytes) throw ArgumentError.value(chunkBytes, 'chunkBytes');
  final buffer = Uint8List(chunk);
  final parts = <TakePart>[];
  final created = <String>[];
  RecordedPartWriter? writer;
  var index = 0;

  RecordedPartWriter open() {
    index++;
    final path = '$dir/${partFileName(stream, index)}';
    created.add(path);
    return RecordedPartWriter.create(
      path,
      RecordedPartHeader(
        sampleRate: sampleRate,
        channels: channels,
        takeId: takeId,
        stream: stream,
        partIndex: index,
      ),
      partBytes: partBytes,
    );
  }

  void seal(RecordedPartWriter part) {
    final header = part.seal();
    parts.add(
      TakePart(
        stream: stream,
        index: index,
        file: partFileName(stream, index),
        frames: header.frames,
        bytes: RecordedPartHeader.headerBytes + header.dataBytes,
        overs: part.overs,
      ),
    );
  }

  final raw = File(pcmPath).openSync();
  try {
    writer = open();
    while (true) {
      var filled = 0;
      while (filled < chunk) {
        final got = raw.readIntoSync(buffer, filled, chunk);
        onRead?.call(got);
        if (got == 0) break;
        filled += got;
      }
      final whole = filled ~/ frameBytes * frameBytes;
      var offset = 0;
      while (offset < whole) {
        var current = writer!;
        if (current.remainingFrames == 0) {
          seal(current);
          current = writer = open();
        }
        final take = (whole - offset) ~/ frameBytes;
        final frames = take < current.remainingFrames
            ? take
            : current.remainingFrames;
        current.append(
          Float32List.view(
            buffer.buffer,
            offset,
            frames * channels,
          ),
        );
        offset += frames * frameBytes;
      }
      if (filled < chunk) break;
    }
    final last = writer!;
    writer = null;
    seal(last);
    return parts;
  } on Object {
    try {
      writer?.seal();
    } on Object {
      // Already failing; the file goes below either way.
    }
    for (final path in created) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Gone or unreachable; the caller keeps the raw file regardless.
      }
    }
    rethrow;
  } finally {
    raw.closeSync();
  }
}
