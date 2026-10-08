import 'package:equatable/equatable.dart';

/// The engine's live levels, published on `LooperRepository.meterLevels`
/// apart from `LooperState` (#1301).
///
/// Levels change on every engine poll whenever any signal flows, including
/// an input's noise floor while nobody plays. Carried inside `LooperState`
/// they made the whole state change 60 times a second at idle, and every
/// surface following it rebuilt and drew a frame with nothing on screen
/// moving. Here they reach only the meters that are on screen.
///
/// Every level is an absolute sample peak for the most recent block, `0..1`.
class MeterLevels extends Equatable {
  /// Creates [MeterLevels].
  const MeterLevels({
    this.outputPeak = 0,
    this.inputPeaks = const [],
    this.outputPeaks = const [],
    this.tracks = const [],
  });

  /// The master bus after the master gain and limiter: what reaches the
  /// outputs.
  final double outputPeak;

  /// Each hardware input's raw peak, one entry per channel the device has
  /// (before conditioning and trim).
  final List<double> inputPeaks;

  /// Each hardware output's peak after the master gain and limiter, per
  /// channel the device has.
  final List<double> outputPeaks;

  /// Each track's levels, indexed by channel.
  final List<TrackLevels> tracks;

  /// [channel]'s levels, or silence when the rig has no such track.
  TrackLevels track(int channel) => channel >= 0 && channel < tracks.length
      ? tracks[channel]
      : TrackLevels.silent;

  /// Hardware input [channel]'s peak, or `0` when the device has no such
  /// input.
  double inputPeak(int channel) =>
      channel >= 0 && channel < inputPeaks.length ? inputPeaks[channel] : 0;

  /// Hardware output [channel]'s peak, or `0` when the device has no such
  /// output.
  double outputChannelPeak(int channel) =>
      channel >= 0 && channel < outputPeaks.length ? outputPeaks[channel] : 0;

  @override
  List<Object?> get props => [outputPeak, inputPeaks, outputPeaks, tracks];
}

/// One track's levels.
class TrackLevels extends Equatable {
  /// Creates [TrackLevels].
  const TrackLevels({this.peak = 0, this.peakL = 0, this.peakR = 0});

  /// No signal.
  static const silent = TrackLevels();

  /// The track's mixed output: the sum of its lanes (#655).
  final double peak;

  /// The left side after volume, pan and the track's chain (the Mixer's
  /// meter).
  final double peakL;

  /// The right side; see [peakL].
  final double peakR;

  @override
  List<Object?> get props => [peak, peakL, peakR];
}
