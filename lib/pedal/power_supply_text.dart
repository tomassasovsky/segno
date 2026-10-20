import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// Below this, the charger is too small for the console at full load: both
/// screens lit and every LED white come to about 59 W, and a 65 W brick
/// browns it out there (#1352).
const double comfortableChargerWatts = 90;

/// Whether the charger itself offers less than [comfortableChargerWatts].
/// Judged on the offer, not the contract: a contract that predates the
/// console profile takes less than the charger has.
bool chargerIsWeak(PedalPowerSupply supply) =>
    supply.contracted && supply.offeredWatts < comfortableChargerWatts;

/// Whole watts, as the banner and toast state them.
String wattsText(double watts) => watts.round().toString();

/// [milli] thousandths as a decimal without trailing zeros: 4700 is `4.7`,
/// 20000 is `20`, 3250 is `3.25`.
String _thousandths(int milli) {
  final whole = milli ~/ 1000;
  final rest = (milli % 1000)
      .toString()
      .padLeft(3, '0')
      .replaceAll(
        RegExp(r'0+$'),
        '',
      );
  return rest.isEmpty ? '$whole' : '$whole.$rest';
}

/// The contract as the Power supply row states it: `20 V · 4.7 A · 94 W`.
String powerSupplyValue(AppLocalizations l10n, PedalPowerSupply supply) =>
    supply.contracted
    ? l10n.controllerPowerValue(
        _thousandths(supply.millivolts),
        _thousandths(supply.milliamps),
        wattsText(supply.watts),
      )
    : l10n.controllerPowerNoContract;

/// What the Power supply row adds under the value, most pressing first, or
/// null when there is nothing to add.
String? powerSupplyCaption(AppLocalizations l10n, PedalPowerSupply supply) {
  if (supply.profile == PedalPowerProfile.writeFailed) {
    return l10n.controllerPowerWriteFailed;
  }
  if (supply.profile == PedalPowerProfile.notRead) {
    return l10n.controllerPowerNotRead;
  }
  if (supply.needsPowerCycle) {
    return l10n.controllerPowerCyclePending(wattsText(supply.offeredWatts));
  }
  if (chargerIsWeak(supply)) return l10n.controllerPowerWeak;
  return null;
}
