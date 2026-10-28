import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

import 'factory_pedals.dart';

void main() {
  late AppLocalizations l10n;
  final presets = factoryPresets();

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  String label(String key) => l10n.fxParamKeyName(key).toUpperCase();

  FxStompFace faceOf(BuiltInEffect effect, {bool live = true}) =>
      fxStompFace(l10n, fxEntryArt(effect, live: live)!)!;

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

  test('every catalogue module has a look, and only they do', () {
    expect(
      kFxStompSpecs.keys.toSet(),
      kFxModules.map((m) => m.name).toSet(),
    );
  });

  test('names and labels print dark on a light body, light on a dark one, '
      'unless the design sets the ink', () {
    expect(kFxStompSpecs['High-pass gate']!.bodyInk, kFxStompDarkInk);
    expect(kFxStompSpecs['Delay']!.bodyInk, kFxStompLightInk);
    expect(kFxStompSpecs['Amp']!.bodyInk, const Color(0xFF2A1A08));
    expect(kFxStompSpecs['Spring reverb']!.bodyInk, const Color(0xFFF1D39A));
    // A window face's labels print on its panel.
    expect(kFxStompSpecs['Pitch shift']!.panelInk, kFxStompDarkInk);
  });

  group('every factory pedal', () {
    test('wears its look and shows only its own controls, as many as its '
        'face holds', () {
      final drawn = <String>{};
      for (final preset in presets) {
        for (final module in fxPresetModules(preset)) {
          final entry = factoryPedal(module, preset);
          final face = faceOf(entry);
          final where = '${module.name} in ${preset.family}/${preset.name}';
          expect(face.spec, kFxStompSpecs[module.name], reason: where);
          final room = face.spec.face.maxKnobs;
          // A real control, never one the pedal does not have.
          final controls = fxEntryControls(entry);
          final count = controls.keys.length;
          expect(face.knobs.length, count.clamp(0, room), reason: where);
          expect(
            controls.keys.map(label),
            containsAll(face.knobs.map((k) => k.label)),
            reason: where,
          );
          // A module the table picks for gets exactly those controls.
          final preferred = kFxStompKnobKeys[module.name];
          if (preferred != null && count > room) {
            expect(
              face.knobs.map((k) => k.label).toSet(),
              preferred.map(label).toSet(),
              reason: where,
            );
          }
          drawn.add(module.name);
        }
      }
      // Every module the catalogue names is on some factory pedal, so the
      // loop above has drawn each of them.
      expect(drawn, kFxModules.map((m) => m.name).toSet());
    });
  });

  group('a variant with more controls than its face holds', () {
    test("shows the four-band EQ's gains and cuts, not its whole low band", () {
      final eq = pedal('Four-band EQ', "Ed's Rack");

      expect(fxEntryControls(eq).keys, hasLength(14));
      expect(faceOf(eq).knobs.map((k) => k.label), [
        label('low_cut'),
        label('low_gain'),
        label('lo_mid_gain'),
        label('hi_mid_gain'),
        label('high_gain'),
        label('high_cut'),
      ]);
    });

    test('otherwise shows the first ones the rack editor lists', () {
      final face = faceOf(pedal('Dub delay', 'Dub Rack'));

      expect(face.spec.face, FxStompFaceKind.treadle);
      expect(face.knobs.map((k) => k.label), [
        label('delay_time'),
        label('feedback'),
        label('damp'),
        label('lr_ratio'),
      ]);
    });

    test('a rocker shows none', () {
      final face = faceOf(pedal('Whammy', 'Guitar Rack'));

      expect(fxEntryControls(pedal('Whammy', 'Guitar Rack')).keys, isNotEmpty);
      expect(face.knobs, isEmpty);
    });
  });

  test('a box face holds six', () {
    final face = faceOf(pedal('Reverb', 'Drum Rack'));

    expect(face.spec.face, FxStompFaceKind.box);
    expect(face.knobs, hasLength(6));
  });

  test('a live knob points where its control is set', () {
    final entry = pedal('Overdrive', "Ed's Rack");
    final turned = entry.copyWith(
      params: [...entry.params]
        ..[0] = 0
        ..[1] = 1,
    );

    expect(faceOf(turned).knobs.map((k) => k.setting), [0, 1]);
  });

  test('the LED is on while the effect is engaged', () {
    final entry = pedal('Overdrive', "Ed's Rack");

    expect(faceOf(entry.copyWith(enabled: true)).lit, isTrue);
    expect(faceOf(entry.copyWith(enabled: false)).lit, isFalse);
    // A still picture shows the state it was made with.
    expect(faceOf(entry.copyWith(enabled: false), live: false).lit, isFalse);
  });

  test('a still picture is the same picture whatever the settings', () {
    final entry = pedal('Overdrive', "Ed's Rack");
    final turned = entry.copyWith(params: [...entry.params]..[0] = 0);

    expect(fxEntryArt(turned, live: false), fxEntryArt(entry, live: false));
    expect(
      fxEntryArt(turned, live: true),
      isNot(fxEntryArt(entry, live: true)),
    );
    expect(
      faceOf(turned, live: false).knobs,
      faceOf(entry, live: false).knobs,
    );
  });

  test('a module the engine cannot build has no knobs, never dead ones', () {
    final face = faceOf(pedal('Harmonizer', 'Vocal Tuner Rack'));

    expect(face.knobs, isEmpty);
    expect(face.spec.name, 'Harmony');
  });

  test(
    'a catalogue pedal this build runs as a plugin draws, without knobs',
    () {
      const plugin = PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'harmony'),
        module: 'Harmonizer',
      );

      final art = fxEntryArt(plugin, live: true);
      expect(art, isNotNull);
      expect(fxStompFace(l10n, art!)!.knobs, isEmpty);
      expect(fxStompFace(l10n, art)!.spec, kFxStompSpecs['Harmonizer']);
    },
  );

  test('an effect that is not a catalogue pedal has no picture', () {
    expect(
      fxEntryArt(BuiltInEffect(type: TrackEffectType.eq), live: true),
      isNull,
    );
    expect(
      fxEntryArt(
        BuiltInEffect(type: TrackEffectType.eq, module: 'Removed module'),
        live: true,
      ),
      isNull,
    );
  });
}
