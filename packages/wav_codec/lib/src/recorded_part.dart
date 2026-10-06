import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The header of one recorded part: a 32-bit float WAV file that carries the
/// identity of the take it belongs to.
///
/// A long performance is written as ordered parts of at most 2,000,000,000
/// bytes each (plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md`,
/// D3). Samples are IEEE float, written as captured: the capture tap is
/// before the master gain and limiter, so a sum can exceed full scale, and a
/// fixed-point format would clip what the listener heard limited. Every part
/// starts with exactly [headerBytes] bytes:
///
/// | offset | bytes | content |
/// |---|---|---|
/// | 0 | 12 | `RIFF`, file size − 8, `WAVE` |
/// | 12 | 24 | `fmt ` (16): float tag 3, channels, rate, byte rate, align, 32 |
/// | 36 | 40 | `sgno` (32): take id (16), stream, part index, 12 zero bytes |
/// | 76 | 8 | `data`, payload size |
///
/// RIFF readers skip the unknown `sgno` chunk; Segno reads it to recognise a
/// part however it was copied or renamed. All fields are little-endian. The
/// native drain writes the same bytes (`perf_drain.c`).
@immutable
class RecordedPartHeader {
  /// Creates a [RecordedPartHeader].
  RecordedPartHeader({
    required this.sampleRate,
    required this.channels,
    required Uint8List takeId,
    required this.stream,
    required this.partIndex,
    this.dataBytes = 0,
  }) : takeId = Uint8List.fromList(takeId) {
    if (takeId.length != takeIdBytes) {
      throw ArgumentError.value(takeId, 'takeId', 'must be 16 bytes');
    }
    if (channels < 1 || channels > 0xFFFF) {
      throw ArgumentError.value(channels, 'channels');
    }
    if (sampleRate < 1 || sampleRate * channels * bytesPerSample > 0xFFFFFFFF) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    if (stream < 0 || stream > 0xFFFF) {
      throw ArgumentError.value(stream, 'stream');
    }
    if (partIndex < 1 || partIndex > 0xFFFF) {
      throw ArgumentError.value(partIndex, 'partIndex');
    }
    if (dataBytes < 0 || dataBytes > maxDataBytes) {
      throw ArgumentError.value(dataBytes, 'dataBytes');
    }
  }

  /// Reads the header at the start of [bytes].
  ///
  /// Throws [FormatException] unless the first [headerBytes] bytes are
  /// exactly the layout above with a 32-bit float format.
  factory RecordedPartHeader.decode(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw const FormatException('shorter than a part header');
    }
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, headerBytes);
    String tag(int offset) => String.fromCharCodes(bytes, offset, offset + 4);
    if (tag(0) != 'RIFF' ||
        tag(8) != 'WAVE' ||
        tag(12) != 'fmt ' ||
        bd.getUint32(16, Endian.little) != 16 ||
        tag(36) != 'sgno' ||
        bd.getUint32(40, Endian.little) != _sgnoBytes ||
        tag(76) != 'data') {
      throw const FormatException('not a Segno part header');
    }
    final channels = bd.getUint16(22, Endian.little);
    final sampleRate = bd.getUint32(24, Endian.little);
    if (bd.getUint16(20, Endian.little) != formatTag ||
        bd.getUint16(34, Endian.little) != 32 ||
        channels == 0 ||
        bd.getUint16(32, Endian.little) != channels * bytesPerSample ||
        bd.getUint32(28, Endian.little) !=
            sampleRate * channels * bytesPerSample) {
      throw const FormatException('not 32-bit float');
    }
    final dataBytes = bd.getUint32(80, Endian.little);
    if (dataBytes % (channels * bytesPerSample) != 0 ||
        dataBytes > maxDataBytes) {
      throw const FormatException('data size is not whole frames');
    }
    return RecordedPartHeader(
      sampleRate: sampleRate,
      channels: channels,
      takeId: Uint8List.sublistView(bytes, 44, 44 + takeIdBytes),
      stream: bd.getUint16(60, Endian.little),
      partIndex: bd.getUint16(62, Endian.little),
      dataBytes: dataBytes,
    );
  }

  /// The size of every part header, in bytes.
  static const int headerBytes = 84;

  /// `WAVE_FORMAT_IEEE_FLOAT`.
  static const int formatTag = 3;

  /// Bytes per sample: 32-bit float.
  static const int bytesPerSample = 4;

  /// Length of a take id.
  static const int takeIdBytes = 16;

  /// The largest payload the 32-bit RIFF size field can describe.
  static const int maxDataBytes = 0xFFFFFFFF - (headerBytes - 8);

  static const int _sgnoBytes = 32;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Interleaved channels.
  final int channels;

  /// The take this part belongs to (16 bytes, minted when recording starts).
  final Uint8List takeId;

  /// Which stream of the take: 0 is the main output, 1 + n is input n.
  final int stream;

  /// The part's position in its stream, from 1.
  final int partIndex;

  /// Payload size in bytes; 0 while the part is still being written.
  final int dataBytes;

  /// Bytes per interleaved frame.
  int get frameBytes => channels * bytesPerSample;

  /// Frames in the payload.
  int get frames => dataBytes ~/ frameBytes;

  /// This header with [dataBytes] replaced.
  RecordedPartHeader withDataBytes(int dataBytes) => RecordedPartHeader(
    sampleRate: sampleRate,
    channels: channels,
    takeId: takeId,
    stream: stream,
    partIndex: partIndex,
    dataBytes: dataBytes,
  );

  /// The [headerBytes] bytes of this header.
  Uint8List encode() {
    final out = Uint8List(headerBytes);
    final bd = ByteData.view(out.buffer);
    void tag(int offset, String value) {
      for (var i = 0; i < 4; i++) {
        out[offset + i] = value.codeUnitAt(i);
      }
    }

    tag(0, 'RIFF');
    bd.setUint32(4, headerBytes - 8 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bd
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, formatTag, Endian.little)
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * frameBytes, Endian.little)
      ..setUint16(32, frameBytes, Endian.little)
      ..setUint16(34, 32, Endian.little);
    tag(36, 'sgno');
    bd.setUint32(40, _sgnoBytes, Endian.little);
    out.setRange(44, 44 + takeIdBytes, takeId);
    bd
      ..setUint16(60, stream, Endian.little)
      ..setUint16(62, partIndex, Endian.little);
    tag(76, 'data');
    bd.setUint32(80, dataBytes, Endian.little);
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is RecordedPartHeader &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      _sameBytes(other.takeId, takeId) &&
      other.stream == stream &&
      other.partIndex == partIndex &&
      other.dataBytes == dataBytes;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    Object.hashAll(takeId),
    stream,
    partIndex,
    dataBytes,
  );

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Whether [sample] is above full scale: its magnitude exceeds 1.0. The
/// drain counts these per part (`overs`) so a take that holds them can say
/// so; they are written unchanged.
bool isOver(double sample) => sample > 1.0 || sample < -1.0;

/// Streams interleaved float audio into one part file, then seals it.
///
/// The header is written with a zero payload size when the writer opens, and
/// patched with the real sizes by [seal] — the same shape the native drain
/// uses, so a part abandoned mid-write is recognisable and recoverable.
/// Samples are written unchanged; [overs] counts those above full scale. Use
/// it from a background isolate: it is synchronous file I/O.
class RecordedPartWriter {
  RecordedPartWriter._(this._file, this._header, this._maxDataBytes);

  /// Creates (or truncates) the part at [path] and writes [header] with a
  /// zero payload size.
  ///
  /// [partBytes] is the most the whole file may hold, header included:
  /// [defaultPartBytes] unless a caller (a test) wants smaller parts.
  factory RecordedPartWriter.create(
    String path,
    RecordedPartHeader header, {
    int partBytes = defaultPartBytes,
  }) {
    final maxData =
        (partBytes - RecordedPartHeader.headerBytes) ~/
        header.frameBytes *
        header.frameBytes;
    if (maxData < header.frameBytes ||
        maxData > RecordedPartHeader.maxDataBytes) {
      throw ArgumentError.value(partBytes, 'partBytes');
    }
    final file = File(path).openSync(mode: FileMode.write);
    try {
      file.writeFromSync(header.withDataBytes(0).encode());
    } on Object {
      file.closeSync();
      rethrow;
    }
    return RecordedPartWriter._(file, header.withDataBytes(0), maxData);
  }

  /// The accepted part size: 2,000,000,000 bytes, header included (plan D3).
  /// Under FAT32's 4 GiB file limit, the 32-bit RIFF size fields, and 2^31
  /// for readers that hold RIFF sizes in a signed int.
  static const int defaultPartBytes = 2000000000;

  final RandomAccessFile _file;
  final RecordedPartHeader _header;
  final int _maxDataBytes;
  int _dataBytes = 0;
  int _overs = 0;
  bool _sealed = false;

  /// Frames written so far.
  int get frames => _dataBytes ~/ _header.frameBytes;

  /// Payload bytes written so far.
  int get dataBytes => _dataBytes;

  /// Samples written so far whose magnitude exceeds 1.0.
  int get overs => _overs;

  /// Frames this part can still take before it is full.
  int get remainingFrames => (_maxDataBytes - _dataBytes) ~/ _header.frameBytes;

  /// Appends [interleaved] samples, which must be whole frames, unchanged.
  ///
  /// Throws [ArgumentError] for a partial frame or more frames than the part
  /// has room for, and [StateError] after [seal].
  void append(Float32List interleaved) {
    if (_sealed) throw StateError('part already sealed');
    if (interleaved.length % _header.channels != 0) {
      throw ArgumentError.value(
        interleaved.length,
        'interleaved',
        'not whole frames',
      );
    }
    final bytes = interleaved.length * RecordedPartHeader.bytesPerSample;
    if (_dataBytes + bytes > _maxDataBytes) {
      throw ArgumentError.value(bytes, 'interleaved', 'exceeds the part size');
    }
    final out = ByteData(bytes);
    for (var i = 0; i < interleaved.length; i++) {
      final sample = interleaved[i];
      if (isOver(sample)) _overs++;
      out.setFloat32(4 * i, sample, Endian.little);
    }
    _file.writeFromSync(out.buffer.asUint8List());
    _dataBytes += bytes;
  }

  /// Patches the header with the payload size, flushes the file to the
  /// device and closes it. Returns the final header. A second call throws
  /// [StateError].
  RecordedPartHeader seal() {
    if (_sealed) throw StateError('part already sealed');
    _sealed = true;
    final sealed = _header.withDataBytes(_dataBytes);
    try {
      _file
        ..setPositionSync(0)
        ..writeFromSync(sealed.encode())
        ..flushSync();
    } finally {
      _file.closeSync();
    }
    return sealed;
  }
}

/// Reads [count] frames starting at frame [offsetFrames] from the part at
/// [path], as interleaved floats exactly as recorded.
///
/// Reads only the header and the requested range, so a 2 GB part costs no
/// more memory than the frames asked for. A [count] that runs past the end of
/// the payload returns the frames that exist. Throws [FormatException] when
/// the file is not a part.
Float32List readRecordedPartFrames(
  String path, {
  required int offsetFrames,
  required int count,
}) {
  if (offsetFrames < 0 || count < 0) {
    throw ArgumentError('offsetFrames and count must not be negative');
  }
  final file = File(path).openSync();
  try {
    final header = RecordedPartHeader.decode(
      file.readSync(RecordedPartHeader.headerBytes),
    );
    final payload = file.lengthSync() - RecordedPartHeader.headerBytes;
    // A part still being written reads a zero size in its header; its real
    // extent is the file, floored to whole frames.
    final available =
        (header.dataBytes > 0 ? header.dataBytes : payload) ~/
        header.frameBytes;
    final start = offsetFrames > available ? available : offsetFrames;
    final frames = count > available - start ? available - start : count;
    file.setPositionSync(
      RecordedPartHeader.headerBytes + start * header.frameBytes,
    );
    final raw = file.readSync(frames * header.frameBytes);
    final bd = ByteData.view(raw.buffer, raw.offsetInBytes, raw.length);
    final samples = Float32List(
      raw.length ~/ RecordedPartHeader.bytesPerSample,
    );
    for (var i = 0; i < samples.length; i++) {
      samples[i] = bd.getFloat32(4 * i, Endian.little);
    }
    return samples;
  } finally {
    file.closeSync();
  }
}
