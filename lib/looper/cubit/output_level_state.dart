part of 'output_level_cubit.dart';

/// What the `OUT` readout shows: the master-bus peak in tenths of a dB, or
/// `null` for silence, and whether it clipped. Quantised to the displayed
/// figure so a peak that does not move the figure is an equal state.
class OutputLevelState extends Equatable {
  /// Creates an [OutputLevelState].
  const OutputLevelState({this.tenths, this.clip = false});

  /// The reading for an absolute sample [peak], where 1.0 is full scale. A
  /// peak below the meters' floor ([kMeterFloorDb]) reads as silence, as the
  /// routing readouts do: there is no level to give down there.
  factory OutputLevelState.of(double peak) {
    final shown = meterPeak(peak);
    if (shown <= 0) return const OutputLevelState();
    if (shown >= kClipPeak) {
      return const OutputLevelState(tenths: 0, clip: true);
    }
    return OutputLevelState(tenths: (200 * log(shown) / ln10).round());
  }

  /// The peak in tenths of a dBFS, or `null` for silence.
  final int? tenths;

  /// Whether the peak reached full scale.
  final bool clip;

  @override
  List<Object?> get props => [tenths, clip];
}
