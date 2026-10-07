import 'package:meta/meta.dart';

/// One audio file of a finished recording: a part of the main output or of
/// one captured input.
///
/// A take written by the recording format of #1198 lists its parts in the
/// sidecar's `parts` array, each a 32-bit float WAV of bounded size, in
/// order. A take written before that format has one `master.wav` and one
/// `live-input-<n>.wav` per captured input; each is read as a single part.
///
/// The JSON shape and its checks are those of #1198's `TakePart`, which
/// replaces this class when that work lands on the trunk.
@immutable
class CapturePart {
  /// Creates a [CapturePart].
  const CapturePart({
    required this.stream,
    required this.index,
    required this.file,
    required this.frames,
    required this.bytes,
  });

  /// Reads one entry of the sidecar's `parts` array. Throws
  /// [FormatException] for a malformed entry.
  factory CapturePart.fromJson(Map<String, dynamic> json) {
    final stream = json['stream'];
    final index = json['index'];
    final file = json['file'];
    final frames = json['frames'];
    final bytes = json['bytes'];
    if (stream is! int ||
        stream < 0 ||
        index is! int ||
        index < 1 ||
        file is! String ||
        file.isEmpty ||
        file.contains('/') ||
        file.contains(r'\') ||
        frames is! int ||
        frames < 0 ||
        bytes is! int ||
        bytes < 0) {
      throw FormatException('malformed take part', json);
    }
    return CapturePart(
      stream: stream,
      index: index,
      file: file,
      frames: frames,
      bytes: bytes,
    );
  }

  /// 0 for the main output, 1 + n for captured input n.
  final int stream;

  /// Position in its stream, from 1.
  final int index;

  /// The file's name inside the take's directory.
  final String file;

  /// Frames the file holds.
  final int frames;

  /// The file's size on disk.
  final int bytes;

  /// Whether this is part of the main output.
  bool get isMaster => stream == 0;

  @override
  bool operator ==(Object other) =>
      other is CapturePart &&
      other.stream == stream &&
      other.index == index &&
      other.file == file &&
      other.frames == frames &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(stream, index, file, frames, bytes);

  @override
  String toString() => 'CapturePart($stream/$index $file)';
}

/// A finished recording as the Library lists it.
@immutable
class CaptureSummary {
  /// Creates a [CaptureSummary].
  const CaptureSummary({
    required this.path,
    required this.name,
    required this.durationFrames,
    required this.sampleRate,
    required this.parts,
    this.startedAt,
    this.recovered = false,
    this.hasDawProject = false,
  });

  /// The take's directory.
  final String path;

  /// What the player calls it: the directory's name, which Rename changes.
  final String name;

  /// When it was armed, from the slug it was created under; null when that
  /// slug does not carry a time.
  final DateTime? startedAt;

  /// The main output's length.
  final int durationFrames;

  /// The rate [durationFrames] counts at.
  final int sampleRate;

  /// Whether boot recovery salvaged it after a crash or power loss. Kept and
  /// listed like any other take (owner decision, #1178 Part 7).
  final bool recovered;

  /// Whether `project.als` is in the bundle.
  final bool hasDawProject;

  /// Every audio part in order: the main output's first, then each input's.
  final List<CapturePart> parts;

  /// The main output's parts, in order.
  List<CapturePart> get masterParts => [
    for (final part in parts)
      if (part.isMaster) part,
  ];

  /// The main output's length.
  Duration get duration => sampleRate <= 0
      ? Duration.zero
      : Duration(
          microseconds:
              durationFrames * Duration.microsecondsPerSecond ~/ sampleRate,
        );

  @override
  bool operator ==(Object other) =>
      other is CaptureSummary &&
      other.path == path &&
      other.name == name &&
      other.startedAt == startedAt &&
      other.durationFrames == durationFrames &&
      other.sampleRate == sampleRate &&
      other.recovered == recovered &&
      other.hasDawProject == hasDawProject &&
      _listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hash(
    path,
    name,
    startedAt,
    durationFrames,
    sampleRate,
    recovered,
    hasDawProject,
    Object.hashAll(parts),
  );

  static bool _listEquals(List<CapturePart> a, List<CapturePart> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'CaptureSummary($name, $path)';
}
