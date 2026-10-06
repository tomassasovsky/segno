import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_engine.dart';

/// The longest preview the audition voice plays, in seconds of source audio
/// (`LE_AUDITION_MAX_SECONDS`): a longer file plays its first
/// [kAuditionMaxSeconds] and says so ([AuditionStart.truncated]).
const int kAuditionMaxSeconds = 120;

/// What [EngineAudition.auditionStartFile] did.
@immutable
class AuditionStart {
  /// Creates an [AuditionStart].
  const AuditionStart({
    required this.result,
    this.frames = 0,
    this.rate = 0,
    this.sourceRate = 0,
    this.truncated = false,
    this.cancelled = false,
  });

  /// [EngineResult.ok] when the preview starts at the next block. Otherwise
  /// the decode's or the start's refusal: [EngineResult.invalid] for a
  /// missing, unreadable or unsupported file, [EngineResult.notRunning] with
  /// no configured engine, [EngineResult.alreadyRunning] while a performance
  /// capture is armed, [EngineResult.notReady] when the retry also found the
  /// voice busy.
  final EngineResult result;

  /// The preview's length in frames at the engine's rate; 0 on a refusal.
  final int frames;

  /// The engine's rate, which [frames] and [AuditionState.position] count
  /// at; 0 on a refusal. Not [sourceRate]: the decoder converts.
  final int rate;

  /// The file's own sample rate (the decoder converts it); 0 when unread.
  final int sourceRate;

  /// Whether the file is longer than [kAuditionMaxSeconds] and only its
  /// first [kAuditionMaxSeconds] play.
  final bool truncated;

  /// Whether the caller withdrew the start while it decoded (the
  /// `stillWanted` check said no), so it never reached the voice. The
  /// [result] is then [EngineResult.invalid].
  final bool cancelled;

  @override
  bool operator ==(Object other) =>
      other is AuditionStart &&
      other.result == result &&
      other.frames == frames &&
      other.rate == rate &&
      other.sourceRate == sourceRate &&
      other.truncated == truncated &&
      other.cancelled == cancelled;

  @override
  int get hashCode =>
      Object.hash(result, frames, rate, sourceRate, truncated, cancelled);
}

/// The audition voice as of the last processed block
/// (`le_engine_audition_state`).
@immutable
class AuditionState {
  /// Creates an [AuditionState].
  const AuditionState({
    this.epoch = 0,
    this.frames = 0,
    this.position = 0,
    this.bus = -1,
  });

  /// Bumps at every configure and reopen, which end a preview.
  final int epoch;

  /// The playing preview's length in frames; 0 when none plays (it ended, was
  /// stopped, or a configure, reopen, performance arm or Cut sound ended it).
  final int frames;

  /// Frames of it played.
  final int position;

  /// Its output pair; -1 when none plays.
  final int bus;

  /// Whether a preview is playing.
  bool get playing => frames > 0;

  @override
  bool operator ==(Object other) =>
      other is AuditionState &&
      other.epoch == epoch &&
      other.frames == frames &&
      other.position == position &&
      other.bus == bus;

  @override
  int get hashCode => Object.hash(epoch, frames, position, bus);
}
