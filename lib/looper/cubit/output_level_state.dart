part of 'output_level_cubit.dart';

/// What the `OUT` readout shows: the master-bus peak in tenths of a dB, or
/// `null` for silence, and whether it clipped. Quantised to the displayed
/// figure so a peak that does not move the figure is an equal state.
class OutputLevelState extends Equatable {
  /// Creates an [OutputLevelState].
  const OutputLevelState({this.tenths, this.clip = false});

  /// The reading for an absolute sample [peak], where 1.0 is full scale.
  factory OutputLevelState.of(double peak) {
    if (peak <= 0) return const OutputLevelState();
    if (peak >= kClipPeak) return const OutputLevelState(tenths: 0, clip: true);
    final db = 20 * log(peak) / ln10;
    return OutputLevelState(tenths: (db * 10).round());
  }

  /// The peak in tenths of a dBFS, or `null` for silence.
  final int? tenths;

  /// Whether the peak reached full scale.
  final bool clip;

  @override
  List<Object?> get props => [tenths, clip];
}
