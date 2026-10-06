import 'package:meta/meta.dart';
import 'package:wav_codec/wav_codec.dart';

/// The frozen format of one recorded stream: 24-bit PCM at the device rate,
/// written as ordered WAV parts of at most [partBytes] bytes each, header
/// included (plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md`,
/// D3; accepted behaviour 6.7).
@immutable
class RecordingFormat {
  /// Creates a [RecordingFormat].
  RecordingFormat({
    required this.sampleRate,
    required this.channels,
    this.partBytes = Pcm24Writer.defaultPartBytes,
  }) {
    if (sampleRate < 1) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels < 1) throw ArgumentError.value(channels, 'channels');
    if (partBytes < headerBytes + frameBytes) {
      throw ArgumentError.value(partBytes, 'partBytes');
    }
  }

  /// Bits per sample.
  static const int bitDepth = 24;

  /// Bytes every part spends on its header.
  static const int headerBytes = Pcm24PartHeader.headerBytes;

  /// Sample rate in Hz, frozen when recording starts.
  final int sampleRate;

  /// Interleaved channels, frozen when recording starts.
  final int channels;

  /// The most one part file may hold, header included.
  final int partBytes;

  /// Bytes per interleaved frame.
  int get frameBytes => channels * Pcm24PartHeader.bytesPerSample;

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
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(stream, index, file, frames, bytes, sha256);
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

/// The durable record the checkpoint thread writes every few seconds
/// (`checkpoint.json`): how much of each stream is safely on the device.
///
/// After a power cut, recovery trusts these counts and nothing more (plan D4;
/// pen 47 "The saved checkpoint can be recovered. Audio after it may be
/// unavailable.").
@immutable
class TakeCheckpoint {
  /// Creates a [TakeCheckpoint].
  const TakeCheckpoint({
    required this.takeId,
    required this.bootId,
    required this.sampleRate,
    required this.frames,
    required this.streams,
    required this.eventsBytes,
    required this.layers,
    required this.writtenAt,
  });

  /// Reads a decoded `checkpoint.json`.
  ///
  /// Throws [FormatException] for any other version, encoding or shape, and
  /// when the parts of a stream are not numbered 1, 2, 3 … in order.
  factory TakeCheckpoint.fromJson(Map<String, dynamic> json) {
    final takeId = json['take_id'];
    final bootId = json['boot_id'];
    final sampleRate = json['sample_rate'];
    final frames = json['frames'];
    final streamsJson = json['streams'];
    final eventsBytes = json['events_bytes'];
    final layersJson = json['layers'];
    final writtenAt = json['written_at_ms'];
    if (json['version'] != version ||
        json['encoding'] != encoding ||
        takeId is! String ||
        !_takeIdHex.hasMatch(takeId) ||
        bootId is! String ||
        sampleRate is! int ||
        sampleRate < 1 ||
        frames is! int ||
        frames < 0 ||
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
      takeId: takeId,
      bootId: bootId,
      sampleRate: sampleRate,
      frames: frames,
      streams: streams,
      eventsBytes: eventsBytes,
      layers: layers,
      writtenAt: DateTime.fromMillisecondsSinceEpoch(writtenAt, isUtc: true),
    );
  }

  /// The only checkpoint version this build reads.
  static const int version = 1;

  /// The only sample encoding this build reads.
  static const String encoding = 'pcm24';

  static final RegExp _takeIdHex = RegExp(r'^[0-9a-f]{32}$');

  /// The take's id, 32 lower-case hex digits.
  final String takeId;

  /// The kernel boot id when the checkpoint was written; empty where the
  /// platform has none. Recovery in the same boot may trust more than this
  /// checkpoint (plan D4).
  final String bootId;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Frames durable in every stream.
  final int frames;

  /// Each stream's durable parts.
  final List<TakeCheckpointStream> streams;

  /// Bytes of `events.log` that are durable.
  final int eventsBytes;

  /// Retired-layer files that are durable.
  final List<String> layers;

  /// When the checkpoint was written.
  final DateTime writtenAt;
}
