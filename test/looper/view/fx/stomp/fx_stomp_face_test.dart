import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';

import 'factory_pedals.dart';

void main() {
  late AppLocalizations l10n;
  final presets = factoryPresets();

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  String label(String key) => l10n.fxParamKeyName(key).toUpperCase();

  /// The first factory preset of [family] that holds [module].
  BuiltInEffect pedal(String module, String family) {
    final m = fxModuleNamed(module)!;
    return factoryPedal(
      m,
      presets.firstWhere(
        (p) => p.family == family && fxPresetModules(p).contains(m),
      ),
    );
  }

  group('every factory pedal', () {
    test('is drawn in its module colour with at most four of its own '
        'controls', () {
      final drawn = <String>{};
      for (final preset in presets) {
        for (final module in fxPresetModules(preset)) {
          final entry = factoryPedal(module, preset);
          final face = fxStompFace(l10n, entry);
          final where = '${module.name} in ${preset.family}/${preset.name}';
          expect(face, isNotNull, reason: where);
          expect(face!.colour, module.colour, reason: where);
          expect(face.name, module.name.toUpperCase(), reason: where);
          // A real control, never one the pedal does not have.
          final controls = fxEntryControls(entry);
          expect(
            face.knobs.length,
            controls.keys.length.clamp(0, kFxStompMaxKnobs),
            reason: where,
          );
          expect(
            controls.keys.map(label),
            containsAll(face.knobs.map((k) => k.label)),
            reason: where,
          );
          drawn.add(module.name);
        }
      }
      // Every module the catalogue names is on some factory pedal, so the
      // loop above has drawn each of them.
      expect(drawn, kFxModules.map((m) => m.name).toSet());
    });

    test('says which factory rack it came from', () {
      final face = fxStompFace(l10n, pedal('Delay', 'Drum Rack'))!;

      expect(face.subtitle, 'DRUM RACK');
    });
  });

  group('a variant with more than four controls', () {
    test("shows the four-band EQ's gains, not its whole low band", () {
      final face = fxStompFace(l10n, pedal('Four-band EQ', "Ed's Rack"))!;

      expect(fxEntryControls(pedal('Four-band EQ', "Ed's Rack")).keys, [
        'low_cut',
        'low_gain',
        'low_freq',
        'low_q',
        'lo_mid_gain',
        'lo_mid_freq',
        'lo_mid_q',
        'hi_mid_gain',
        'hi_mid_freq',
        'hi_mid_q',
        'high_gain',
        'high_freq',
        'high_q',
        'high_cut',
      ]);
      expect(face.knobs.map((k) => k.label), [
        label('low_gain'),
        label('lo_mid_gain'),
        label('hi_mid_gain'),
        label('high_gain'),
      ]);
    });

    test("keeps the compressor's makeup, which every other variant keeps", () {
      final face = fxStompFace(l10n, pedal('Compressor', "Ed's Rack"))!;

      expect(face.knobs.map((k) => k.label), [
        label('threshold'),
        label('ratio'),
        label('attack'),
        label('makeup'),
      ]);
    });

    test('otherwise shows the first four the rack editor lists', () {
      final face = fxStompFace(l10n, pedal('Dub delay', 'Dub Rack'))!;

      expect(face.knobs.map((k) => k.label), [
        label('delay_time'),
        label('feedback'),
        label('damp'),
        label('lr_ratio'),
      ]);
    });
  });

  test('a knob points where its control is set', () {
    final entry = pedal('Overdrive', "Ed's Rack");
    final turned = entry.copyWith(
      params: [...entry.params]
        ..[0] = 0
        ..[1] = 1,
    );

    final face = fxStompFace(l10n, turned)!;

    expect(face.knobs.map((k) => k.setting), [0, 1]);
  });

  test('a module the engine cannot build has no knobs, never dead ones', () {
    final face = fxStompFace(l10n, pedal('Harmonizer', 'Vocal Tuner Rack'))!;

    expect(face.knobs, isEmpty);
    expect(face.name, 'HARMONIZER');
  });

  test('a single effect has no subtitle', () {
    final single = fxModuleEntry(
      fxModuleNamed('Wah')!,
      const FxPreset(
        family: "Ed's Rack",
        name: 'p',
        id: 'p',
        type: 0,
        params: {},
      ),
    );

    expect(fxStompFace(l10n, single)!.subtitle, isNull);
  });

  test('an effect that is not a catalogue pedal has no face', () {
    expect(fxStompFace(l10n, BuiltInEffect(type: TrackEffectType.eq)), isNull);
    expect(
      fxStompFace(
        l10n,
        BuiltInEffect(type: TrackEffectType.eq, module: 'Removed module'),
      ),
      isNull,
    );
  });
}
