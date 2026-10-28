import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_colours.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';

import 'factory_pedals.dart';

void main() {
  late AppLocalizations l10n;
  final presets = factoryPresets();

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  String label(String key) => l10n.fxParamKeyName(key).toUpperCase();

  FxStompFace faceOf(BuiltInEffect effect, {bool live = true}) =>
      fxStompFace(l10n, fxEntryArt(effect, live: live)!);

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

  test('every catalogue module has an opaque pedal colour', () {
    for (final module in kFxModules) {
      expect(kFxStompColours[module.name]?.a, 1, reason: module.name);
    }
    expect(
      kFxStompColours.keys.toSet(),
      kFxModules.map((m) => m.name).toSet(),
      reason: 'no colour for a module the catalogue does not have',
    );
  });

  group('every factory pedal', () {
    test('is drawn in its module colour with at most four of its own '
        'controls', () {
      final drawn = <String>{};
      for (final preset in presets) {
        for (final module in fxPresetModules(preset)) {
          final entry = factoryPedal(module, preset);
          final face = faceOf(entry);
          final where = '${module.name} in ${preset.family}/${preset.name}';
          expect(face.colour, kFxStompColours[module.name], reason: where);
          expect(face.name, module.name.toUpperCase(), reason: where);
          // A real control, never one the pedal does not have.
          final controls = fxEntryControls(entry);
          final count = controls.keys.length;
          expect(
            face.knobs.length,
            count.clamp(0, kFxStompMaxKnobs),
            reason: where,
          );
          expect(
            controls.keys.map(label),
            containsAll(face.knobs.map((k) => k.label)),
            reason: where,
          );
          // A module the table picks four for gets exactly those four.
          final preferred = kFxStompKnobKeys[module.name];
          if (preferred != null && count > kFxStompMaxKnobs) {
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

    test('says which factory rack its variant is', () {
      expect(faceOf(pedal('Delay', 'Drum Rack')).subtitle, 'DRUM RACK');
      expect(faceOf(pedal('Compressor', "Ed's Rack")).subtitle, "ED'S RACK");
    });

    test("keeps its own family in another family's rack", () {
      final eds = pedal('Compressor', "Ed's Rack");
      final moved = eds.copyWith(
        rack: const FxRack(id: 'dub', name: 'Dub', art: 'dub'),
      );

      expect(faceOf(moved).subtitle, "ED'S RACK");
    });

    test('names no family when a shared variant leaves its rack', () {
      // The Studio, Vocal and Vocal Tuner racks share one four-band EQ: on
      // its own, its controls cannot say which of them it came from.
      final vocal = pedal('Four-band EQ', 'Vocal Rack');

      expect(faceOf(vocal).subtitle, 'VOCAL RACK');
      expect(
        faceOf(
          vocal.copyWith(
            rack: const FxRack(id: 'd', name: 'D', art: 'dub'),
          ),
        ).subtitle,
        isNull,
      );
    });
  });

  group('a variant with more than four controls', () {
    test("shows the four-band EQ's gains, not its whole low band", () {
      final eq = pedal('Four-band EQ', "Ed's Rack");

      expect(fxEntryControls(eq).keys, hasLength(14));
      expect(fxEntryControls(eq).keys.take(4), [
        'low_cut',
        'low_gain',
        'low_freq',
        'low_q',
      ]);
      expect(faceOf(eq).knobs.map((k) => k.label), [
        label('low_gain'),
        label('lo_mid_gain'),
        label('hi_mid_gain'),
        label('high_gain'),
      ]);
    });

    test("keeps the compressor's makeup, which every other variant keeps", () {
      final face = faceOf(pedal('Compressor', "Ed's Rack"));

      expect(face.knobs.map((k) => k.label), [
        label('threshold'),
        label('ratio'),
        label('attack'),
        label('makeup'),
      ]);
    });

    test('otherwise shows the first four the rack editor lists', () {
      final face = faceOf(pedal('Dub delay', 'Dub Rack'));

      expect(face.knobs.map((k) => k.label), [
        label('delay_time'),
        label('feedback'),
        label('damp'),
        label('lr_ratio'),
      ]);
    });
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
  });

  test('a still picture is the same picture whatever the settings', () {
    final entry = pedal('Overdrive', "Ed's Rack");
    final turned = entry.copyWith(params: [...entry.params]..[0] = 0);

    expect(fxEntryArt(turned, live: false), fxEntryArt(entry, live: false));
    expect(fxEntryArt(turned), isNot(fxEntryArt(entry)));
  });

  test('a pedal that is not live rests its knobs whatever the settings', () {
    final entry = pedal('Overdrive', "Ed's Rack");
    final turned = entry.copyWith(params: [...entry.params]..[0] = 0);

    expect(
      faceOf(turned, live: false).knobs,
      faceOf(entry, live: false).knobs,
    );
  });

  test('a module the engine cannot build has no knobs, never dead ones', () {
    final face = faceOf(pedal('Harmonizer', 'Vocal Tuner Rack'));

    expect(face.knobs, isEmpty);
    expect(face.name, 'HARMONIZER');
    expect(face.subtitle, 'VOCAL TUNER RACK');
  });

  test('an entry that is no factory variant has no subtitle', () {
    // An EQ entry carrying none of a variant's controls: every parameter of
    // its type, and no family to name.
    final bare = BuiltInEffect(
      type: TrackEffectType.eq,
      module: 'Four-band EQ',
    );

    expect(faceOf(bare).subtitle, isNull);
  });

  test('an effect that is not a catalogue pedal has no picture', () {
    expect(fxEntryArt(BuiltInEffect(type: TrackEffectType.eq)), isNull);
    expect(
      fxEntryArt(
        BuiltInEffect(type: TrackEffectType.eq, module: 'Removed module'),
      ),
      isNull,
    );
  });
}
