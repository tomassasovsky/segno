import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
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

/// The value text [FxBuiltInParamControl] prints for parameter [index] of
/// [effect].
Future<String> _valueText(
  WidgetTester tester,
  BuiltInEffect effect,
  int index,
) async {
  await tester.pumpApp(
    Material(
      child: FxBuiltInParamControl(
        effect: effect,
        index: index,
        width: 493,
        onChanged: (_) {},
      ),
    ),
  );
  return tester.widget<FxParamControl>(find.byType(FxParamControl)).valueText;
}

void main() {
  group('FxBuiltInParamControl', () {
    testWidgets('a plain built-in reads in its units', (tester) async {
      final effect = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.35, 0.35, 0.35],
      );

      expect(await _valueText(tester, effect, 0), '350 ms');
    });

    testWidgets("a module built onto a built-in reads in the built-in's "
        'units, which are what it plays', (tester) async {
      final effect = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.35, 0.35, 0.35],
        module: 'Delay',
      );

      expect(await _valueText(tester, effect, 0), '350 ms');
    });

    testWidgets("a Looper X kind's module reads in the module's own units", (
      tester,
    ) async {
      final effect = BuiltInEffect(
        type: TrackEffectType.eq,
        module: 'Four-band EQ',
        params: [
          for (final p in TrackEffectType.eq.params) p.defaultValue,
        ]..[1] = 0.75,
      );

      expect(await _valueText(tester, effect, 1), '9.0 dB');
    });

    testWidgets("an EQ's mid frequency reads as the value it applies, "
        'measured (#891)', (tester) async {
      final effect = BuiltInEffect(
        type: TrackEffectType.eq,
        module: 'Four-band EQ',
        params: [
          for (final p in TrackEffectType.eq.params) p.defaultValue,
        ]..[5] = 0.5,
      );

      expect(await _valueText(tester, effect, 5), '632 Hz');
    });

    testWidgets('the Pitch Shift reads in semitones', (tester) async {
      expect(await _valueText(tester, _pitchShift(), 0), '+7 st');
    });

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
