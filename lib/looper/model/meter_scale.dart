import 'dart:math' show ln10, log, pow;

/// The bottom of the shared meter scale, in dBFS: a peak at or below this
/// draws no fill and reads as silence.
const double kMeterFloorDb = -60;

/// A peak at or above this reads as clipping — the engine's level is the
/// absolute sample peak, so full scale is 1.0.
const double kClipPeak = 0.999;

/// [peak] as a meter can show it: tenths of a dB, and silence below
/// [kMeterFloorDb] (#1301).
///
/// Every meter and level readout selects through this, so a level that does
/// not change what is drawn is an equal value and rebuilds nothing. That is
/// what keeps an input's noise floor, which moves the raw peak on every
/// engine poll, from redrawing an idle console. A tenth of a dB is finer
/// than any meter draws and is the resolution of the dBFS readouts.
double meterPeak(double peak) {
  if (peak >= kClipPeak) return 1;
  if (peak <= 0) return 0;
  final tenths = (200 * log(peak) / ln10).round();
  if (tenths <= kMeterFloorDb * 10) return 0;
  final shown = pow(10, tenths / 200).toDouble();
  // Rounding up to 0.0 dBFS must not invent a clip the engine did not see.
  return shown >= kClipPeak ? 0.998 : shown;
}
