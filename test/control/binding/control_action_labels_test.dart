import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/interaction_mode.dart';

void main() {
  group('the one-time FX notice names the MODE assignment FX now skips '
      '(#1229, D13)', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final es = lookupAppLocalizations(const Locale('es'));

    test('the default pair: Mute, and Custom on hold', () {
      expect(
        footFxModeChangedText(en, const PedalSetup()),
        'MODE now leaves FX mode. Its Mute and Hold · Custom still work in '
        'the other modes.',
      );
      expect(footFxModeChangedText(es, const PedalSetup()), contains('MODE'));
    });

    test('a configured pair without a Hold', () {
      const setup = PedalSetup(
        modePress: InteractionMode.mixer,
        modeHold: null,
      );
      expect(
        footFxModeChangedText(en, setup),
        'MODE now leaves FX mode. Its ${en.actionModeMixer} still works in '
        'the other modes.',
      );
    });
  });
}
