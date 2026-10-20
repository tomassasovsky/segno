import 'dart:math' as math;

/// The lowest rack level, in decibels.
///
/// A rack's level is the Looper X's Master Vol: -12 to +12 dB in 0.1 dB
/// steps, unity at 0 dB, mapped linearly from its normalized setting
/// (`dB = -12 + 24 * setting`). It is stored as a gain in
/// `FxChannels.level` on the rack's last entry, which is what the engine
/// applies.
const double kFxRackLevelMinDb = -12;

/// The highest rack level, in decibels. Its gain, about 3.98, is inside the
/// engine's entry-level ceiling of 4.
const double kFxRackLevelMaxDb = 12;

/// [db] clamped to the rack level's range and snapped to its 0.1 dB step.
double _snapDb(double db) =>
    (db.clamp(kFxRackLevelMinDb, kFxRackLevelMaxDb) * 10).round() / 10;

/// The gain a rack level of [db] is stored as, after clamping it to the
/// range and snapping it to the 0.1 dB step.
double fxRackLevelGain(double db) => math.pow(10, _snapDb(db) / 20).toDouble();

/// The rack level, in dB on the 0.1 dB step, that the stored [gain] stands
/// for. A gain below the range, silence included, reads as its bottom.
double fxRackLevelDb(double gain) =>
    gain <= 0 ? kFxRackLevelMinDb : _snapDb(20 * math.log(gain) / math.ln10);

/// The rack level's `0..1` setting for the stored [gain]: the Looper X's own
/// Master Vol scale, where 0.5 is unity.
double fxRackLevelSetting(double gain) =>
    (fxRackLevelDb(gain) - kFxRackLevelMinDb) /
    (kFxRackLevelMaxDb - kFxRackLevelMinDb);

/// The gain a rack level at [setting] (`0..1`, the Looper X's Master Vol
/// scale) is stored as.
double fxRackLevelGainAt(double setting) => fxRackLevelGain(
  kFxRackLevelMinDb +
      (kFxRackLevelMaxDb - kFxRackLevelMinDb) * setting.clamp(0.0, 1.0),
);
