import 'dart:math' as math;

/// The Mixer level fader's travel. Its endpoints are silence and +6.02 dB;
/// every nonzero position follows the same -60 dB to +6.02 dB logarithmic
/// scale as the track strip. Mix settings themselves store linear gain.
const double mixFaderFloorDb = -60;

/// Maximum linear gain accepted by track, lane, and live-monitor controls.
const double mixFaderMaxGain = 2;

final double _mixFaderCeilingDb = 20 * math.log(mixFaderMaxGain) / math.ln10;

/// Converts a normalized fader position into the linear gain sent to the rig.
double mixerGainAt(double travel) {
  final position = travel.clamp(0.0, 1.0);
  if (position == 0) return 0;
  final db =
      mixFaderFloorDb + position * (_mixFaderCeilingDb - mixFaderFloorDb);
  return math.pow(10, db / 20).toDouble().clamp(0, mixFaderMaxGain);
}

/// Converts the rig's linear gain to the Mixer fader's normalized position.
double mixerTravelFor(double gain) {
  if (gain <= 0) return 0;
  final db = 20 * math.log(gain) / math.ln10;
  return ((db - mixFaderFloorDb) / (_mixFaderCeilingDb - mixFaderFloorDb))
      .clamp(0.0, 1.0);
}
