import 'package:equatable/equatable.dart';

/// Where each track's playhead is, published on
/// `LooperRepository.playheads` apart from `LooperState` (#1563).
///
/// A playing track's position changes on every engine poll. Carried inside
/// `LooperState` it made the whole state change at the poll rate whenever a
/// loop played, and every bloc, cubit and selector following the state ran
/// again with nothing but the playhead different. Here it reaches only what
/// draws a playhead: the progress bars and the waveforms.
class Playhead extends Equatable {
  /// Creates a [Playhead].
  const new({this.tracks = const [], this.captures = const []});

  /// Each track's play position as a share of its loop, `0..1`, indexed by
  /// channel. `0` while the track has no length or is recording its take:
  /// the engine publishes the growing write head as both position and length
  /// then, which is no position at all.
  final List<double> tracks;

  /// Each track's take in flight, indexed by channel (#1936):
  /// [TakeCapture.none] unless the track is recording.
  final List<TakeCapture> captures;

  /// [channel]'s position, or `0` when the rig has no such track.
  double track(int channel) =>
      channel >= 0 && channel < tracks.length ? tracks[channel] : 0;

  /// [channel]'s take in flight, or [TakeCapture.none].
  TakeCapture capture(int channel) => channel >= 0 && channel < captures.length
      ? captures[channel]
      : TakeCapture.none;

  @override
  List<Object?> get props => [tracks, captures];
}

/// A recording take's progress (#1936): the frames captured since its press,
/// and where it ends by itself. Like the position, it moves on every poll.
class TakeCapture extends Equatable {
  /// Creates a [TakeCapture].
  const new({this.frames = 0, this.targetFrames = 0});

  /// No take in flight.
  static const none = TakeCapture();

  /// Frames captured since the take's press. A take over a master counts
  /// from its own start, not from the master's phase.
  final int frames;

  /// Where the take ends by itself: an armed length preset or a fixed
  /// multiple of the master loop. `0` when only a press ends it.
  final int targetFrames;

  /// How much of [targetFrames] is captured, `0..1`; `0` without a target.
  double get progress =>
      targetFrames > 0 ? (frames / targetFrames).clamp(0.0, 1.0) : 0;

  @override
  List<Object?> get props => [frames, targetFrames];
}
