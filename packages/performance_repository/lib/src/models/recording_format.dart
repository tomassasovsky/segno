import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:wav_codec/wav_codec.dart';

/// The frozen format of one recorded stream: 32-bit float at the device
/// rate, written as ordered WAV parts of at most [partBytes] bytes each,
/// header included (plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md`,
/// D3; accepted behaviour 6.7). Float, because the capture tap is before the
/// master gain and limiter and a fixed-point format would clip what the
/// listener heard limited.
@immutable
class RecordingFormat {
  /// Creates a [RecordingFormat].
  RecordingFormat({
    required this.sampleRate,
    required this.channels,
    this.partBytes = RecordedPartWriter.defaultPartBytes,
  }) {
    if (sampleRate < 1) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels < 1) throw ArgumentError.value(channels, 'channels');
    if (partBytes < headerBytes + frameBytes) {
      throw ArgumentError.value(partBytes, 'partBytes');
    }
  }

  /// Bits per sample.
  static const int bitDepth = 32;

  /// Bytes every part spends on its header.
  static const int headerBytes = RecordedPartHeader.headerBytes;

  /// Sample rate in Hz, frozen when recording starts.
  final int sampleRate;

  /// Interleaved channels, frozen when recording starts.
  final int channels;

  /// The most one part file may hold, header included.
  final int partBytes;

  /// Bytes per interleaved frame.
  int get frameBytes => channels * RecordedPartHeader.bytesPerSample;

  /// Frames one full part holds.
  int get partFrames => (partBytes - headerBytes) ~/ frameBytes;

  /// Bytes one full part occupies on disk.
  int get fullPartBytes => headerBytes + partFrames * frameBytes;

  /// The length of [frames] at this rate, floored to whole microseconds.
  Duration durationOf(int frames) => Duration(
    microseconds: frames * Duration.microsecondsPerSecond ~/ sampleRate,
  );

  /// The bytes appending [frames] to this stream costs, including the header
  /// of every new part it opens.
  ///
  /// [openPartFrames] is how many frames the stream's last part already
  /// holds, or null when no part is open yet (the first frame then pays a
  /// header). A full last part counts as having no room.
  int bytesToAppend(int frames, {int? openPartFrames}) {
    if (frames <= 0) return 0;
    final room = openPartFrames == null ? 0 : partFrames - openPartFrames;
    final first = frames < room ? frames : room;
    final rest = frames - first;
    final newParts = (rest + partFrames - 1) ~/ partFrames;
    return frames * frameBytes + newParts * headerBytes;
  }

  /// The most frames every stream in [streams] can still take together
  /// within [budgetBytes], each stream ending at the same frame.
  ///
  /// This is how a take stops "at complete recorded frames" when space runs
  /// out: the main output and every captured input stop together. Each entry
  /// is a stream's format and its open part's frame count (null for none).
  /// Exact, including the header of every part a stream would still open.
  static int remainingFramesTogether(
    List<({RecordingFormat format, int? openPartFrames})> streams,
    int budgetBytes,
  ) {
    if (streams.isEmpty || budgetBytes <= 0) return 0;
    int cost(int frames) {
      var total = 0;
      for (final s in streams) {
        total += s.format.bytesToAppend(
          frames,
          openPartFrames: s.openPartFrames,
        );
      }
      return total;
    }

    var perFrame = 0;
    for (final s in streams) {
      perFrame += s.format.frameBytes;
    }
    // Every frame costs at least its bytes, so this many is out of reach.
    var lo = 0;
    var hi = budgetBytes ~/ perFrame + 1;
    while (lo + 1 < hi) {
      final mid = lo + (hi - lo) ~/ 2;
      if (cost(mid) <= budgetBytes) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// [remainingFramesTogether] for this stream alone.
  int remainingFrames(int budgetBytes, {int? openPartFrames}) =>
      remainingFramesTogether([
        (format: this, openPartFrames: openPartFrames),
      ], budgetBytes);

  @override
  bool operator ==(Object other) =>
      other is RecordingFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.partBytes == partBytes;

  @override
  int get hashCode => Object.hash(sampleRate, channels, partBytes);
}

/// One recorded part file of a take, as the native drain lists it in the
/// sidecar's `parts` and in `checkpoint.json`.
@immutable
class TakePart {
  /// Creates a [TakePart].
  const TakePart({
    required this.stream,
    required this.index,
    required this.file,
    required this.frames,
    required this.bytes,
    this.overs = 0,
    this.sha256,
  });

  /// Reads a part entry. [stream] supplies the stream for a checkpoint's
  /// nested lists, whose entries do not repeat it.
  ///
  /// Throws [FormatException] for a malformed entry: recovery must never
  /// guess at the shape of a take.
  factory TakePart.fromJson(Map<String, dynamic> json, {int? stream}) {
    final s = json['stream'] ?? stream;
    final index = json['index'];
    final file = json['file'];
    final frames = json['frames'];
    final bytes = json['bytes'];
    final overs = json['overs'] ?? 0;
    final sha256 = json['sha256'];
    if (s is! int ||
        s < 0 ||
        index is! int ||
        index < 1 ||
        file is! String ||
        file.isEmpty ||
        file.contains('/') ||
        file.contains(r'\') ||
        frames is! int ||
        frames < 0 ||
        bytes is! int ||
        bytes < RecordingFormat.headerBytes ||
        overs is! int ||
        overs < 0 ||
        (sha256 != null &&
            (sha256 is! String || !_sha256Hex.hasMatch(sha256)))) {
      throw FormatException('malformed take part', json);
    }
    return TakePart(
      stream: s,
      index: index,
      file: file,
      frames: frames,
      bytes: bytes,
      overs: overs,
      sha256: sha256 as String?,
    );
  }

  static final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  /// 0 for the main output, 1 + n for input n.
  final int stream;

  /// Position in the stream, from 1.
  final int index;

  /// The part's file name inside the take's directory.
  final String file;

  /// Frames the part holds.
  final int frames;

  /// The file's size in bytes, header included.
  final int bytes;

  /// Samples in the part whose magnitude exceeds 1.0. They are kept as
  /// recorded; the count lets the page say the take holds them.
  final int overs;

  /// The SHA-256 of the part's payload once it is sealed, as 64 lower-case
  /// hex digits; null while the part is still open.
  final String? sha256;

  /// Whether the part was closed with its sizes and digest recorded.
  bool get isSealed => sha256 != null;

  /// Serializes this part (with its [stream]).
  Map<String, dynamic> toJson() => {
    'stream': stream,
    'index': index,
    'file': file,
    'frames': frames,
    'bytes': bytes,
    'overs': overs,
    'sha256': ?sha256,
  };

  @override
  bool operator ==(Object other) =>
      other is TakePart &&
      other.stream == stream &&
      other.index == index &&
      other.file == file &&
      other.frames == frames &&
      other.bytes == bytes &&
      other.overs == overs &&
      other.sha256 == sha256;

  @override
  int get hashCode =>
      Object.hash(stream, index, file, frames, bytes, overs, sha256);
}

/// One stream's durable state in a checkpoint.
@immutable
class TakeCheckpointStream {
  /// Creates a [TakeCheckpointStream].
  const TakeCheckpointStream({
    required this.stream,
    required this.channels,
    required this.parts,
  });

  /// 0 for the main output, 1 + n for input n.
  final int stream;

  /// Interleaved channels.
  final int channels;

  /// The stream's parts in order, each durable up to its [TakePart.frames].
  final List<TakePart> parts;

  /// Frames durable in this stream.
  int get frames => parts.fold(0, (sum, part) => sum + part.frames);
}

/// The durable record the checkpoint thread writes every few seconds: how
/// much of each stream is safely on the device.
///
/// It lives in two slot files, `checkpoint-a.json` and `checkpoint-b.json`,
/// rewritten in place alternately and never renamed over (a rename over a
/// file is not atomic on FAT or exFAT; plan D4). Each slot carries a
/// `sequence` and ends with a `checksum`: the SHA-256 hex of every byte
/// before the `"checksum"` key. A torn slot fails its checksum and the other
/// slot stands. After a power cut, recovery trusts these counts and nothing
/// more (pen 47 "The saved checkpoint can be recovered. Audio after it may be
/// unavailable.").
@immutable
class TakeCheckpoint {
  /// Creates a [TakeCheckpoint].
  const TakeCheckpoint({
    required this.sequence,
    required this.takeId,
    required this.bootId,
    required this.volumeGeneration,
    required this.sampleRate,
    required this.frames,
    required this.overs,
    required this.streams,
    required this.eventsBytes,
    required this.layers,
    required this.writtenAt,
  });

  /// Reads the newer valid slot of [a] and [b] (either may be null when its
  /// file is absent).
  ///
  /// [digest] is the SHA-256 of bytes as 64 lower-case hex digits — the
  /// engine's `StorageIo.digestBytes`, one hash for the engine and Dart. A
  /// slot is valid when its checksum matches and it parses; the valid slot
  /// with the higher sequence wins. Throws [FormatException] when neither
  /// is valid.
  factory TakeCheckpoint.fromSlots(
    Uint8List? a,
    Uint8List? b, {
    required String Function(Uint8List bytes) digest,
  }) {
    TakeCheckpoint? best;
    for (final slot in [a, b]) {
      if (slot == null) continue;
      final TakeCheckpoint parsed;
      try {
        parsed = TakeCheckpoint.fromSlot(slot, digest: digest);
      } on FormatException {
        continue;
      }
      if (best == null || parsed.sequence > best.sequence) best = parsed;
    }
    if (best == null) throw const FormatException('no valid checkpoint slot');
    return best;
  }

  /// Reads one slot, checking its checksum with [digest].
  ///
  /// Throws [FormatException] for a checksum that does not match, any other
  /// version or encoding, a malformed shape, or parts not numbered 1, 2, 3 …
  factory TakeCheckpoint.fromSlot(
    Uint8List bytes, {
    required String Function(Uint8List bytes) digest,
  }) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final at = text.lastIndexOf(_checksumKey);
    if (at < 0) throw const FormatException('checkpoint without a checksum');
    final covered = Uint8List.fromList(utf8.encode(text.substring(0, at)));
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('checkpoint is not JSON');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['checksum'] != digest(covered)) {
      throw const FormatException('checkpoint checksum does not match');
    }
    return TakeCheckpoint._fromJson(decoded);
  }

  factory TakeCheckpoint._fromJson(Map<String, dynamic> json) {
    final sequence = json['sequence'];
    final takeId = json['take_id'];
    final bootId = json['boot_id'];
    final generation = json['volume_generation'];
    final sampleRate = json['sample_rate'];
    final frames = json['frames'];
    final overs = json['overs'];
    final streamsJson = json['streams'];
    final eventsBytes = json['events_bytes'];
    final layersJson = json['layers'];
    final writtenAt = json['written_at_ms'];
    if (json['version'] != version ||
        json['encoding'] != encoding ||
        sequence is! int ||
        sequence < 0 ||
        takeId is! String ||
        !_takeIdHex.hasMatch(takeId) ||
        bootId is! String ||
        generation is! int ||
        sampleRate is! int ||
        sampleRate < 1 ||
        frames is! int ||
        frames < 0 ||
        overs is! int ||
        overs < 0 ||
        streamsJson is! List ||
        eventsBytes is! int ||
        eventsBytes < 0 ||
        layersJson is! List ||
        writtenAt is! int) {
      throw FormatException('malformed checkpoint', json);
    }
    final streams = <TakeCheckpointStream>[];
    for (final s in streamsJson) {
      if (s is! Map<String, dynamic>) {
        throw FormatException('malformed checkpoint stream', s);
      }
      final stream = s['stream'];
      final channels = s['channels'];
      final partsJson = s['parts'];
      if (stream is! int ||
          channels is! int ||
          channels < 1 ||
          partsJson is! List) {
        throw FormatException('malformed checkpoint stream', s);
      }
      final parts = <TakePart>[];
      for (final p in partsJson) {
        if (p is! Map<String, dynamic>) {
          throw FormatException('malformed take part', p);
        }
        final part = TakePart.fromJson(p, stream: stream);
        if (part.stream != stream || part.index != parts.length + 1) {
          throw FormatException('take parts out of order', p);
        }
        parts.add(part);
      }
      streams.add(
        TakeCheckpointStream(stream: stream, channels: channels, parts: parts),
      );
    }
    final layers = <String>[];
    for (final l in layersJson) {
      if (l is! String) throw FormatException('malformed layer entry', l);
      layers.add(l);
    }
    return TakeCheckpoint(
      sequence: sequence,
      takeId: takeId,
      bootId: bootId,
      volumeGeneration: generation,
      sampleRate: sampleRate,
      frames: frames,
      overs: overs,
      streams: streams,
      eventsBytes: eventsBytes,
      layers: layers,
      writtenAt: DateTime.fromMillisecondsSinceEpoch(writtenAt, isUtc: true),
    );
  }

  /// The only checkpoint version this build reads.
  static const int version = 1;

  /// The only sample encoding this build reads: 32-bit float.
  static const String encoding = 'f32';

  static const String _checksumKey = '"checksum"';

  static final RegExp _takeIdHex = RegExp(r'^[0-9a-f]{32}$');

  /// Increases with every checkpoint the take writes.
  final int sequence;

  /// The take's id, 32 lower-case hex digits.
  final String takeId;

  /// The kernel boot id when the checkpoint was written; empty where the
  /// platform has none.
  final String bootId;

  /// The removable volume generation the take was armed on, or -1 for
  /// Internal. A different generation at recovery means the volume was not
  /// mounted for the whole take, so only this checkpoint is trusted (D4).
  final int volumeGeneration;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Frames durable in every stream.
  final int frames;

  /// Samples above full scale in the durable audio, every stream together.
  final int overs;

  /// Each stream's durable parts.
  final List<TakeCheckpointStream> streams;

  /// Bytes of `events.log` that are durable.
  final int eventsBytes;

  /// Retired-layer files that are durable.
  final List<String> layers;

  /// When the checkpoint was written.
  final DateTime writtenAt;

  /// Whether the files on disk may be trusted beyond this checkpoint: only
  /// in the same boot ([currentBootId]) on a volume that stayed mounted for
  /// the whole take ([currentGeneration] equal to the generation at arm; -1
  /// for Internal). Otherwise a size on disk can cover clusters that never
  /// received the audio (plan D4, review H2).
  bool trustsFilesBeyond({
    required String currentBootId,
    required int currentGeneration,
  }) =>
      bootId.isNotEmpty &&
      bootId == currentBootId &&
      volumeGeneration == currentGeneration;
}
