import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

import '../../../helpers/helpers.dart';

/// A Studio Rack Pitch Shift entry at +7 semitones: the octaver, shown on the
/// rack's -12..+12.
BuiltInEffect _pitchShift() => fxModuleEntry(
  kFxModules.firstWhere((m) => m.name == 'Pitch shift'),
  const FxPreset(
    family: 'Studio Rack',
    name: 'p',
    id: 'p',
    type: 0,
    params: {'Pitch': 1, 'Pitch Shift': 0.791666686534882, 'Pitch Mix': 1},
  ),
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final time = TrackEffectType.delay.params.first;

  group('fxParamReading', () {
    test('a plain built-in reads in its units, with no note', () {
      final effect = BuiltInEffect(type: TrackEffectType.delay);

      final reading = fxParamReading(l10n, effect, time, 0.35);

      expect(reading.valueText, '350 ms');
      expect(reading.note, isNull);
    });

    test('a factory module keeps the raw setting and the unverified note', () {
      final effect = BuiltInEffect(
        type: TrackEffectType.delay,
        module: 'Delay',
      );

      final reading = fxParamReading(l10n, effect, time, 0.35);

      expect(reading.valueText, '0.35');
      expect(reading.note, l10n.fxScaleUnverified);
    });

    test('a plain built-in whose descriptor is unverified reads like a '
        'module', () {
      final effect = BuiltInEffect(type: TrackEffectType.delay);
      final unverified = FxParamInfo(
        key: time.key,
        unit: time.unit,
        atMin: time.atMin,
        atMax: time.atMax,
        defaultValue: time.defaultValue,
        taperUnverified: true,
      );

      final reading = fxParamReading(l10n, effect, unverified, 0.35);

      expect(reading.valueText, '0.35');
      expect(reading.note, l10n.fxScaleUnverified);
    });

    test("a Looper X kind's module reads in the module's own units", () {
      final effect = BuiltInEffect(
        type: TrackEffectType.eq,
        module: 'Four-band EQ',
      );
      final gain = TrackEffectType.eq.params[1];

      final reading = fxParamReading(l10n, effect, gain, 0.75);

      expect(reading.valueText, '9.0 dB');
      expect(reading.note, isNull);
      // Its mid frequency reads as the value it applies, measured (#891).
      final mid = TrackEffectType.eq.params[5];
      final midReading = fxParamReading(l10n, effect, mid, 0.5);
      expect(midReading.valueText, '632 Hz');
      expect(midReading.note, isNull);
    });

    test('the Pitch Shift reads in semitones, with no note', () {
      final effect = _pitchShift();
      final reading = fxParamReading(
        l10n,
        effect,
        fxEntryParam(effect, 0),
        fxEntryShownSetting(effect, 0),
      );

      expect(reading.valueText, '+7 st');
      expect(reading.note, isNull);
    });
  });

  group('FxBuiltInParamControl', () {
    testWidgets('a Pitch Shift works on the rack range and reports the '
        "octaver's setting", (tester) async {
      final effect = _pitchShift();
      final reported = <double>[];
      await tester.pumpApp(
        Material(
          child: FxBuiltInParamControl(
            effect: effect,
            index: 0,
            width: 493,
            onChanged: reported.add,
          ),
        ),
      );

      final slider = tester.widget<LoopSlider>(find.byType(LoopSlider));
      expect(slider.value, closeTo(19 / 24, 1e-6)); // +7 of -12..+12
      slider.onChanged(1); // +12 semitones
      expect(reported, hasLength(1));
      expect(
        effect.type.params[0].valueAt(reported.single),
        closeTo(12, 1e-4),
      );
    });
  });
}
