import 'dart:typed_data';

import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/backing.dart';

/// A file a [MockAudioDecoder] knows: its facts, or the refusal a native
/// decode of it would return.
class MockAudioFile {
  /// A playable file.
  const MockAudioFile({
    required this.sourceRate,
    required this.sourceFrames,
    this.channels = 2,
  }) : failure = null;

  /// A file every decode and probe refuses with [failure].
  const MockAudioFile.refused(EngineResult this.failure)
    : sourceRate = 0,
      sourceFrames = 0,
      channels = 0;

  /// The file's own rate.
  final int sourceRate;

  /// Its length at [sourceRate].
  final int sourceFrames;

  /// 1 or 2.
  final int channels;

  /// The refusal, when it is not playable.
  final EngineResult? failure;
}

/// An in-memory [AudioDecoder] for tests and the mock flavour.
///
/// Knows only the files registered in [files]; anything else is refused as
/// [EngineResult.invalid], like a missing file. Decoded samples are
/// `(frame + 1) / 65536` on the left and its negation on the right, so a test
/// can tell frames apart, and the rate conversion follows the native length
/// rule (`floor(frames * out / in)`). Counts every decode it hands out and
/// every one freed, so a test can prove nothing leaks.
class MockAudioDecoder implements AudioDecoder {
  /// Creates a [MockAudioDecoder] over [files].
  MockAudioDecoder({Map<String, MockAudioFile>? files})
    : files = files ?? <String, MockAudioFile>{};

  /// The known files, by path.
  final Map<String, MockAudioFile> files;

  /// Decodes handed out so far.
  int decoded = 0;

  /// Of those, how many have been freed (by [DecodedAudio.dispose] or by the
  /// engine that owned them).
  int freed = 0;

  /// Decodes still holding samples.
  int get live => decoded - freed;

  /// Every path passed to [decode] or [probe], in order.
  final List<String> requests = [];

  @override
  Future<DecodedAudio> decode(
    String path, {
    required int sampleRate,
    int startFrame = 0,
    int maxFrames = 0,
  }) async {
    requests.add(path);
    final file = _file(path);
    if (startFrame < 0 || maxFrames < 0 || sampleRate <= 0) {
      throw EngineException(EngineResult.invalid, 'decode $path');
    }
    final whole = startFrame == 0 && maxFrames == 0;
    if (whole && file.sourceFrames > 900 * file.sourceRate) {
      throw EngineException(EngineResult.tooLong, 'decode $path');
    }
    if (!whole && startFrame >= file.sourceFrames) {
      throw EngineException(EngineResult.invalid, 'decode $path');
    }
    final read = file.sourceFrames - startFrame;
    var frames = read * sampleRate ~/ file.sourceRate;
    var truncated = false;
    if (maxFrames > 0 && frames > maxFrames) {
      frames = maxFrames;
      truncated = true;
    }
    decoded++;
    return DecodedAudio(
      frames: frames,
      sampleRate: sampleRate,
      info: AudioFileInfo(
        sourceRate: file.sourceRate,
        sourceChannels: file.channels,
        sourceFrames: truncated ? frames * file.sourceRate ~/ sampleRate : read,
        truncated: truncated,
      ),
      payload: _MockPayload(this, frames),
    );
  }

  @override
  Future<AudioProbe> probe(String path, {int buckets = 512}) async {
    requests.add(path);
    final file = _file(path);
    if (file.sourceFrames > 900 * file.sourceRate) {
      throw EngineException(EngineResult.tooLong, 'probe $path');
    }
    return AudioProbe(
      info: AudioFileInfo(
        sourceRate: file.sourceRate,
        sourceChannels: file.channels,
        sourceFrames: file.sourceFrames,
      ),
      peaks: _rampPeaks(file.sourceFrames, buckets),
    );
  }

  MockAudioFile _file(String path) {
    final file = files[path];
    if (file == null) throw EngineException(EngineResult.invalid, path);
    final failure = file.failure;
    if (failure != null) throw EngineException(failure, path);
    return file;
  }

  static Float32List _rampPeaks(int frames, int buckets) {
    final out = Float32List(buckets < 0 ? 0 : buckets);
    for (var k = 0; k < out.length; k++) {
      final last = frames * (k + 1) ~/ out.length;
      out[k] = last / 65536;
    }
    return out;
  }
}

class _MockPayload implements DecodedAudioPayload {
  _MockPayload(this._decoder, this._frames);

  final MockAudioDecoder _decoder;
  final int _frames;
  bool _freed = false;

  @override
  Float32List copySamples(int frames) {
    final out = Float32List(frames * 2);
    for (var f = 0; f < frames; f++) {
      out[2 * f] = (f + 1) / 65536;
      out[2 * f + 1] = -(f + 1) / 65536;
    }
    return out;
  }

  @override
  Float32List peaks(int buckets) =>
      MockAudioDecoder._rampPeaks(_frames, buckets);

  @override
  void free() {
    if (_freed) throw StateError('mock decoded audio freed twice');
    _freed = true;
    _decoder.freed++;
  }
}
