import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_engine.dart';

/// The backing player's transport (#1200), mirroring `le_backing_transport`.
enum BackingTransport {
  /// Nothing sounds; the position is 0 after a Stop or an end.
  stopped,

  /// The loaded file sounds.
  playing,

  /// The position is held.
  paused;

  /// Maps the native code; unknown codes read as [stopped].
  static BackingTransport fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : stopped;
}

/// A transport request, mirroring `le_backing_transport_op`.
enum BackingTransportOp {
  /// Play from the position (a resume fades in).
  play,

  /// Fade out and keep the position.
  pause,

  /// Fade out and rewind to 0.
  stop,
}

/// What happens at the loaded file's last frame, mirroring `le_backing_end`.
enum BackingEnd {
  /// Stop and rewind (the default).
  stop,

  /// Wrap to frame 0 with no gap.
  repeat,

  /// Continue into the staged file; stop when there is none.
  next;

  /// Maps the native code; unknown codes read as [stop].
  static BackingEnd fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : stop;
}

/// What the latest end of a file did, mirroring `le_backing_end_event`.
enum BackingEndEvent {
  /// No file has ended yet.
  none,

  /// End = Stop: stopped and rewound.
  stopped,

  /// End = Repeat: wrapped to frame 0.
  repeated,

  /// End = Next: continued into the staged file.
  advanced,

  /// End = Next with nothing staged (or no free return slot): stopped.
  nextMissing;

  /// Maps the native code; unknown codes read as [none].
  static BackingEndEvent fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : none;
}

/// The backing voice as the engine last published it
/// (`le_engine_backing_state`).
@immutable
class BackingState {
  /// Creates a [BackingState].
  const BackingState({
    this.epoch = 0,
    this.item = -1,
    this.nextItem = -1,
    this.transport = BackingTransport.stopped,
    this.position = 0,
    this.frames = 0,
    this.endCount = 0,
    this.lastEnd = BackingEndEvent.none,
    this.endMode = BackingEnd.stop,
    this.outputMask = 0,
    this.level = 1,
    this.pan = 0,
    this.clickPan = 0,
    this.owned = 0,
    this.ownedBytes = 0,
  });

  /// Bumps at every configure and reopen: the owner replays its settings and
  /// reloads after a change.
  final int epoch;

  /// The loaded file's token, `-1` when nothing is loaded.
  final int item;

  /// The staged (End = Next) file's token, `-1` when none.
  final int nextItem;

  /// The transport.
  final BackingTransport transport;

  /// Frames into the loaded file.
  final int position;

  /// The loaded file's length in frames, `0` when nothing is loaded.
  final int frames;

  /// Bumps on every end-of-file handling.
  final int endCount;

  /// What the latest end did.
  final BackingEndEvent lastEnd;

  /// The End setting.
  final BackingEnd endMode;

  /// The output channel mask.
  final int outputMask;

  /// The backing gain, 0 to 2.
  final double level;

  /// The backing balance, -1 to 1.
  final double pan;

  /// The click pan, -1 to 1.
  final double clickPan;

  /// Buffers the engine owns.
  final int owned;

  /// Their PCM bytes.
  final int ownedBytes;

  /// Whether a file is loaded.
  bool get loaded => item >= 0;

  @override
  bool operator ==(Object other) =>
      other is BackingState &&
      other.epoch == epoch &&
      other.item == item &&
      other.nextItem == nextItem &&
      other.transport == transport &&
      other.position == position &&
      other.frames == frames &&
      other.endCount == endCount &&
      other.lastEnd == lastEnd &&
      other.endMode == endMode &&
      other.outputMask == outputMask &&
      other.level == level &&
      other.pan == pan &&
      other.clickPan == clickPan &&
      other.owned == owned &&
      other.ownedBytes == ownedBytes;

  @override
  int get hashCode => Object.hash(
    epoch,
    item,
    nextItem,
    transport,
    position,
    frames,
    endCount,
    lastEnd,
    endMode,
    outputMask,
    level,
    pan,
    clickPan,
    owned,
    ownedBytes,
  );

  @override
  String toString() =>
      'BackingState(epoch: $epoch, item: $item, next: $nextItem, '
      '$transport at $position/$frames, end: $endMode, last: $lastEnd '
      '#$endCount, owned: $owned)';
}

/// What a decode or probe learned about the file itself
/// (`le_backing_decode_info`).
@immutable
class AudioFileInfo {
  /// Creates an [AudioFileInfo].
  const AudioFileInfo({
    required this.sourceRate,
    required this.sourceChannels,
    required this.sourceFrames,
    this.truncated = false,
  });

  /// The file's own sample rate.
  final int sourceRate;

  /// 1 or 2.
  final int sourceChannels;

  /// Frames decoded, at [sourceRate].
  final int sourceFrames;

  /// A bounded decode stopped before the end of the file.
  final bool truncated;

  /// The decoded length in seconds.
  double get seconds => sourceRate > 0 ? sourceFrames / sourceRate : 0;

  @override
  bool operator ==(Object other) =>
      other is AudioFileInfo &&
      other.sourceRate == sourceRate &&
      other.sourceChannels == sourceChannels &&
      other.sourceFrames == sourceFrames &&
      other.truncated == truncated;

  @override
  int get hashCode =>
      Object.hash(sourceRate, sourceChannels, sourceFrames, truncated);

  @override
  String toString() =>
      'AudioFileInfo($sourceRate Hz, $sourceChannels ch, $sourceFrames '
      'frames${truncated ? ', truncated' : ''})';
}

/// The result of [AudioDecoder.probe]: the file decodes, and this is what it
/// holds.
@immutable
class AudioProbe {
  /// Creates an [AudioProbe].
  const AudioProbe({required this.info, required this.peaks});

  /// The file's facts.
  final AudioFileInfo info;

  /// Per-bucket absolute peaks over the whole file (max of both sides).
  final Float32List peaks;
}

/// Where a [DecodedAudio]'s samples live. The native decoder's buffer, or a
/// test double's list.
abstract interface class DecodedAudioPayload {
  /// Copies the interleaved stereo samples (`frames` x 2).
  Float32List copySamples(int frames);

  /// [buckets] per-bucket absolute peaks.
  Float32List peaks(int buckets);

  /// Frees the samples. Called once, and only while the payload is owned.
  void free();
}

/// Who owns a [DecodedAudio]'s samples.
enum DecodedAudioOwnership {
  /// The caller: it must hand them to the engine or [DecodedAudio.dispose]
  /// them.
  owned,

  /// The engine accepted them (`BackingControl.backingLoad` or
  /// `backingStageNext` returned ok); the engine frees them.
  transferred,

  /// Freed by [DecodedAudio.dispose].
  disposed,
}

/// Decoded audio: interleaved stereo float32 at the engine rate, ready for
/// the backing voice or for a copy (the Library preview).
///
/// The samples live outside the Dart heap. Exactly one of two things must
/// happen to them: the engine accepts them, or [dispose] frees them. Both
/// are idempotent in effect: a second [dispose], or a [dispose] after a
/// transfer, does nothing.
class DecodedAudio {
  /// Creates a [DecodedAudio] over [payload]; a decoder is the only caller.
  DecodedAudio({
    required this.frames,
    required this.sampleRate,
    required this.info,
    required this.payload,
  });

  /// Length at [sampleRate].
  final int frames;

  /// The engine rate it was decoded for.
  final int sampleRate;

  /// What the decode learned about the file.
  final AudioFileInfo info;

  /// The samples.
  final DecodedAudioPayload payload;

  DecodedAudioOwnership _ownership = DecodedAudioOwnership.owned;

  /// Who owns the samples now.
  DecodedAudioOwnership get ownership => _ownership;

  /// Whether the samples are still the caller's.
  bool get isOwned => _ownership == DecodedAudioOwnership.owned;

  /// The samples' size.
  int get bytes => frames * 2 * Float32List.bytesPerElement;

  /// Copies the samples. Throws a [StateError] once they are no longer the
  /// caller's.
  Float32List copySamples() {
    _requireOwned();
    return payload.copySamples(frames);
  }

  /// [buckets] peaks of the samples. Throws a [StateError] once they are no
  /// longer the caller's.
  Float32List peaks(int buckets) {
    _requireOwned();
    return payload.peaks(buckets);
  }

  /// Frees the samples unless the engine owns them.
  void dispose() {
    if (_ownership != DecodedAudioOwnership.owned) return;
    _ownership = DecodedAudioOwnership.disposed;
    payload.free();
  }

  /// Records that the engine accepted the samples. An engine implementation
  /// calls this after an ok load or stage, and only then.
  @internal
  void markTransferred() {
    _requireOwned();
    _ownership = DecodedAudioOwnership.transferred;
  }

  void _requireOwned() {
    if (_ownership != DecodedAudioOwnership.owned) {
      throw StateError('decoded audio is $_ownership');
    }
  }
}

/// The app's one reader of audio samples (#1200 Part 2): WAV (16/24/32-bit
/// PCM or 32-bit float) and MP3 (MPEG Layer III), mono or stereo, 8 to
/// 192 kHz, converted to the engine rate.
///
/// Engine-free, so a repository can hold one beside its `AudioEngine`. Every
/// decode runs off the calling isolate. Refusals throw an [EngineException]
/// whose result says why: [EngineResult.unsupported] (a format, container,
/// channel count or rate outside the whitelist, checked before any decoder
/// sees the file), [EngineResult.invalid] (missing, unreadable or damaged,
/// including a non-finite sample), [EngineResult.tooLong] (over 15 minutes),
/// [EngineResult.capacity] (the memory floor, or an allocation failure).
abstract interface class AudioDecoder {
  /// Decodes [path] for an engine running at [sampleRate].
  ///
  /// With [startFrame] 0 and [maxFrames] 0 the whole file is read (and
  /// refused past the cap). Otherwise the read starts at [startFrame] (source
  /// frames) and keeps at most [maxFrames] output frames, setting
  /// [AudioFileInfo.truncated] when the file goes on: a preview, or a
  /// recording part.
  Future<DecodedAudio> decode(
    String path, {
    required int sampleRate,
    int startFrame = 0,
    int maxFrames = 0,
  });

  /// Decodes all of [path] in small chunks, keeping no samples, to prove it
  /// plays and to measure it: what an import runs before it keeps a file.
  Future<AudioProbe> probe(String path, {int buckets = 512});
}
