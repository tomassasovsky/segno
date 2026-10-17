import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/pedal_led_labels.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/l10n/l10n.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('every LED state and group has a distinct name in $locale', () {
      final l10n = lookupAppLocalizations(locale);
      final states = {
        for (final state in PedalLedState.values)
          pedalLedStateLabel(l10n, state),
      };
      expect(states, hasLength(PedalLedState.values.length));
      expect(states.every((label) => label.isNotEmpty), isTrue);
      final groups = {
        for (final group in PedalLedGroup.values)
          pedalLedGroupLabel(l10n, group),
      };
      expect(groups, hasLength(PedalLedGroup.values.length));
    });
  }

  test('the mode picker names its mode', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(l10n.pedalLedMode('Mute'), 'Mode: Mute');
  });
}
