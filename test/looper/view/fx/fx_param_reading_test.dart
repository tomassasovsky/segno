import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';

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
      // Its chosen mid range still says so.
      final mid = TrackEffectType.eq.params[5];
      expect(
        fxParamReading(l10n, effect, mid, 0.5).note,
        l10n.fxScaleUnverified,
      );
    });
  });
}
