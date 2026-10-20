import 'package:meta/meta.dart';

/// A saved session's `mixdown.wav` as the Library's Audio tab lists it
/// (#1178 Part 7): its length, rate and size, read from the file's header.
@immutable
class SessionMixdown {
  /// Creates a [SessionMixdown].
  const SessionMixdown({
    required this.frames,
    required this.sampleRate,
    required this.bytes,
  });

  /// Frames the mixdown holds.
  final int frames;

  /// The rate [frames] counts at.
  final int sampleRate;

  /// The file's size on disk.
  final int bytes;

  /// The mixdown's length.
  Duration get duration => sampleRate <= 0
      ? Duration.zero
      : Duration(
          microseconds: frames * Duration.microsecondsPerSecond ~/ sampleRate,
        );

  @override
  bool operator ==(Object other) =>
      other is SessionMixdown &&
      other.frames == frames &&
      other.sampleRate == sampleRate &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(frames, sampleRate, bytes);

  @override
  String toString() => 'SessionMixdown($frames @ $sampleRate, $bytes B)';
}
