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
  const new({this.tracks = const []});

  /// Each track's play position as a share of its loop, `0..1`, indexed by
  /// channel. `0` while the track has no length or is recording its take:
  /// the engine publishes the growing write head as both position and length
  /// then, which is no position at all.
  final List<double> tracks;

  /// [channel]'s position, or `0` when the rig has no such track.
  double track(int channel) =>
      channel >= 0 && channel < tracks.length ? tracks[channel] : 0;

  @override
  List<Object?> get props => [tracks];
}
