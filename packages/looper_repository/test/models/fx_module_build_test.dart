import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';

/// One real preset's worth of parameters, as the catalogue files carry them:
/// Ed's Rack / Acoustic Rhythm 1, trimmed to the modules under test.
FxPreset _preset(Map<String, double> params) => FxPreset(
  family: "Ed's Rack",
  name: 'Acoustic Rhythm 1',
  id: 'ed53e7b8-a878-4907-8c61-f529eaa3d5d0',
  type: 0,
  params: params,
);

FxModule _module(String name) => kFxModules.firstWhere((m) => m.name == name);

void main() {
  group('readiness', () {
    test('a module the engine has no effect for is unavailable', () {
      // The Looper X kinds land part by part (#887); until one has, its
      // module is shown and processes nothing. The accepted design forbids
      // substituting another effect and calling that parity.
      expect(
        fxModuleBuild(_module('Smart tune')).readiness,
        FxModuleReadiness.unavailable,
      );
      expect(fxModuleBuild(_module('Smart tune')).type, isNull);

      expect(
        [
          for (final m in kFxModules)
            if (fxModuleBuild(m).readiness == FxModuleReadiness.unavailable)
              m.name,
        ],
        [
          'Harmonizer',
          'Smart tune',
        ],
      );
    });

    test('a module the engine builds but cannot carry every control of is '
        'PARTIAL, with the stranded controls named', () {
      final reverb = fxModuleBuild(_module('Reverb'), family: "Ed's Rack");

      expect(reverb.readiness, FxModuleReadiness.partial);
      expect(reverb.type, TrackEffectType.roomVerb);
      // Kept and named, so a surface can show them and say they do not reach
      // the sound rather than drawing a control that does nothing: Ed's Rev
      // Mode, which does not change the Looper X's sound either (#1476).
      expect(reverb.unmapped, ['Rev Mode']);
      // The Drum Rack's delay carries its Freq on the Drum's own delay
      // (#1473), and the seven racks with the mode delay every control.
      final drum = fxModuleBuild(_module('Delay'), family: 'Drum Rack');
      expect(drum.readiness, FxModuleReadiness.full);
      expect(drum.params, [
        'Del Time',
        'Del Feedback',
        'Del Mix',
        null,
        'Del Freq',
      ]);
      expect(drum.fixed, {3: 12 / 13});
      final mode = fxModuleBuild(_module('Delay'), family: 'Guitar Rack');
      expect(mode.readiness, FxModuleReadiness.full);
      expect(mode.params, [
        'Del Time',
        'Del Feedback',
        'Del Mix',
        'Del Mode',
      ]);
    });

    test("the Dub Rack's delay builds from its own power key and keys", () {
      final dub = fxModuleBuild(_module('Dub delay'));

      expect(dub.type, TrackEffectType.modeDelay);
      expect(dub.readiness, FxModuleReadiness.full);
      expect(dub.unmapped, isEmpty);

      final entry = fxModuleEntry(
        _module('Dub delay'),
        const FxPreset(
          family: 'Dub Rack',
          name: 'Light',
          id: 'dub',
          type: 4,
          params: {
            'Dub Delay': 0,
            'Del Time': 0.3,
            'Del Feedback': 0.6,
            'Del Damp': 0.5,
            'Del L/R Ratio': 0.5,
            'Del Res-Freq': 0.5,
            'Del Reso': 0.5,
          },
        ),
      );
      // Powered by `Dub Delay`, which the dub reverb used to take as one of
      // its own parameters, leaving the delay always on.
      expect(entry.enabled, isFalse);
      expect(entry.params[0], closeTo(0.3, 1e-9));
      expect(entry.params[1], closeTo(0.6, 1e-9));
      // Echoes only: the Dub path's dry comes from the rack's paths (#891).
      expect(entry.params[2], 1);
      // The Dub's own delay (#1473), the kind's last position, with its
      // damping, ratio, resonance and resonance frequency.
      expect(entry.params[3], 1);
      expect(entry.params.sublist(5, 9), [0.5, 0.5, 0.5, 0.5]);
      expect(fxEntryBuild(entry)?.exposed, [0, 1, 5, 6, 7, 8]);
      expect(dub.path, FxModulePath.dub);
    });

    test(
      'of the add-an-effect rows, only the kinds this engine builds play',
      () {
        final playable = [
          for (final row in kFxAddableEffects)
            if (fxModuleBuild(fxModuleNamed(row.module)!).type != null)
              row.label,
        ];

        expect(playable, [
          'Amp',
          'Chorus',
          'Compressor',
          'Degrade',
          'Delay',
          'Distortion',
          'Doubler',
          'Dub Delay',
          'Four-band EQ',
          'HP / Gate',
          'Low-pass Filter',
          'Modulation',
          'Octaver',
          'Overdrive',
          'Parametric EQ',
          'Pitch Shift',
          'Pumper',
          'Reverb',
          'Slicer',
          'Spring Reverb',
          'Transient',
          'Vinyl',
          'Wah',
          'Whammy',
        ]);
      },
    );

    test("each rack's reverb carries the controls its rack shows", () {
      Map<String, List<String?>> params(String family) => {
        family: fxModuleBuild(_module('Reverb'), family: family).params,
      };
      // The modes' racks: Length, Mix, the mode and (where shown) Bright;
      // Ed's plays HALL; the Drum Rack's ER rooms and their controls.
      expect(params('Vocal Rack'), {
        'Vocal Rack': ['Rev Length', 'Rev Mix', 'Rev Mode', 'Rev Bright'],
      });
      expect(params('Studio Rack'), {
        'Studio Rack': ['Rev Length', 'Rev Mix', 'Rev Mode'],
      });
      expect(params("Ed's Rack"), {
        "Ed's Rack": ['Rev Length', 'Rev Mix', null, 'Rev Bright'],
      });
      expect(params('Drum Rack'), {
        'Drum Rack': [
          'Rev Length',
          'Rev Mix',
          'Rev ER',
          null,
          'Rev Lo/Hi',
          'Rev Tail/ER',
          'Rev Density',
        ],
      });
      for (final family in [
        'Vocal Rack',
        'Vocal Tuner Rack',
        'Studio Rack',
        'Rhythmic Rack',
        'Drum Rack',
      ]) {
        expect(
          fxModuleBuild(_module('Reverb'), family: family).readiness,
          FxModuleReadiness.full,
          reason: family,
        );
      }
    });
  });

  group('building an entry', () {
    test("reads the preset's values into the parameters they feed", () {
      final entry = fxModuleEntry(
        _module('Delay'),
        _preset(const {
          'Delay': 1,
          'Del Time': 0.42,
          'Del Feedback': 0.35,
          'Del Mix': 0.25,
          'Del Mode': 0.545,
        }),
      );

      expect(entry.type, TrackEffectType.modeDelay);
      expect(entry.params[0], closeTo(0.42, 1e-9));
      expect(entry.params[1], closeTo(0.35, 1e-9));
      expect(entry.params[2], closeTo(0.25, 1e-9));
      // The preset's 6 of 0..11 lands on the kind's 6 of 0..13.
      expect(entry.params[3], closeTo(6 / 13, 1e-9));
      // 1/8D and RESO LO, positions 8 and 6.
      expect(entry.type.params[0].positionOf(entry.params[0]), 8);
      expect(entry.type.params[3].positionOf(entry.params[3]), 6);
    });

    test("follows the preset's own power key", () {
      expect(
        fxModuleEntry(_module('Delay'), _preset(const {'Delay': 0})).enabled,
        isFalse,
      );
      expect(
        fxModuleEntry(_module('Delay'), _preset(const {'Delay': 1})).enabled,
        isTrue,
      );
      // The compressor is `Comp` in most families and `Compressor` in Ed's
      // Rack, and either spelling has to be read.
      expect(
        fxModuleEntry(
          _module('Compressor'),
          _preset(const {'Compressor': 0}),
        ).enabled,
        isFalse,
      );
      expect(
        fxModuleEntry(
          _module('Compressor'),
          _preset(const {'Comp': 0}),
        ).enabled,
        isFalse,
      );
    });

    test('a parameter the preset says nothing about keeps the engine default, '
        'rather than falling to zero', () {
      // A preset without Octave 1 Vol keeps the kind's own 100 %, not 0,
      // which would silence the voice.
      final entry = fxModuleEntry(
        _module('Octaver'),
        _preset(const {'Oct': 1, 'Oct High Mode': 0, 'Octave Mix': 1}),
      );
      final engineDefault = BuiltInEffect(type: TrackEffectType.dualOctaver);

      expect(entry.type, TrackEffectType.dualOctaver);
      expect(entry.params[1], engineDefault.params[1]);
      expect(entry.params[1], 1.0);
      expect(entry.params[2], 1.0);
    });

    test('an unavailable module still takes its place in the chain, passing '
        'signal through', () {
      // A rack is what the player loaded, not what this build can run — so
      // the pedal is there, and it is a passthrough rather than absent.
      final entry = fxModuleEntry(
        _module('Smart tune'),
        _preset(const {'Smart Tune': 1}),
      );

      expect(entry.type, TrackEffectType.none);
      expect(entry.enabled, isTrue);
    });

    test("keeps the preset's id and every value it gives the module, "
        'including the ones this build drops', () {
      final entry = fxModuleEntry(
        _module('Delay'),
        _preset(const {
          'Delay': 1,
          'Del Time': 0.42,
          'Del Mode': 0.545,
          'Rev Mix': 0.05,
        }),
      );

      expect(entry.presetId, 'ed53e7b8-a878-4907-8c61-f529eaa3d5d0');
      // `Del Mode` has no engine parameter and is kept anyway; `Rev Mix` is
      // the reverb's, so it is not this entry's.
      expect(entry.source, {'Delay': 1, 'Del Time': 0.42, 'Del Mode': 0.545});
      expect(decodeTrackEffects(encodeTrackEffects([entry])).single, entry);
    });

    test('carries the shared Vocal Tuner keys to both Smart Tune and the '
        'Harmonizer', () {
      // Vocal Tuner Rack / Midi Harm Mid, trimmed: Smart Tune is off, and
      // the Harmonizer still reads the shared keys.
      const preset = FxPreset(
        family: 'Vocal Tuner Rack',
        name: 'Midi Harm Mid',
        id: 'midi-harm',
        type: 7,
        params: {
          'Smart Tune': 0,
          'Harmonize': 1,
          'Mode': 0,
          'Auto Source': 1,
          'Key': 0,
          'Scale Type': 1 / 13,
          'Speed': 0.4,
          'Voice 1 Vol': 0.7,
        },
      );
      const shared = {
        'Mode': 0,
        'Auto Source': 1,
        'Key': 0,
        'Scale Type': 1 / 13,
      };

      final tune = fxModuleEntry(_module('Smart tune'), preset);
      final harm = fxModuleEntry(_module('Harmonizer'), preset);

      expect(tune.enabled, isFalse);
      expect(tune.source, {'Smart Tune': 0, ...shared, 'Speed': 0.4});
      expect(harm.enabled, isTrue);
      expect(harm.source, {'Harmonize': 1, ...shared, 'Voice 1 Vol': 0.7});
    });

    test('an out-of-range preset value is clamped rather than pushed on', () {
      final entry = fxModuleEntry(
        _module('Delay'),
        _preset(const {'Del Time': 2, 'Del Feedback': -1}),
      );

      expect(entry.params[0], 1.0);
      expect(entry.params[1], 0.0);
    });
  });

  group('building a whole rack', () {
    test('Master Vol becomes the rack level, on the last entry, and no '
        'module parameter', () {
      final entries = fxRackEntries(
        _preset(const {
          'Comp': 1,
          'Delay': 1,
          'Del Time': 0.4,
          'Master Vol': 0.7083,
        }),
      );

      expect(entries.map((e) => e.module), ['Compressor', 'Delay']);
      // Read back the way the editor reads a rack's level.
      final group = fxChainGroups([
        for (final e in entries)
          e.copyWith(
            rack: const FxRack(id: 'r', name: 'Rack'),
          ),
      ]).single;
      // 0.7083 is -12 + 24 * 0.7083 = 5.0 dB on the Looper X's scale.
      expect(fxRackLevelDb(group.channels.level), 5.0);
      expect(group.channels.level, closeTo(1.7783, 1e-4));
      expect(entries.first.channels, FxChannels.defaults);
      for (final entry in entries) {
        expect(entry.source.containsKey('Master Vol'), isFalse);
      }
    });

    test('a preset without Master Vol leaves the rack at unity', () {
      final entries = fxRackEntries(_preset(const {'Delay': 1}));

      expect(entries.single.channels.level, 1);
    });

    test('Master Vol 0.5 is unity, and a level above +6 dB plays as set', () {
      expect(
        fxRackEntries(
          _preset(const {'Delay': 1, 'Master Vol': 0.5}),
        ).single.channels.level,
        1,
      );
      // Guitar Rack / Rhythm Atmos: +10.6 dB, past the old ceiling of x2.
      final loud = fxRackEntries(
        _preset(const {'Delay': 1, 'Master Vol': 0.94166667}),
      ).single.channels.level;
      expect(fxRackLevelDb(loud), 10.6);
      expect(loud, closeTo(3.3884, 1e-4));
    });

    test('a Master Vol outside 0..1 is clamped to -12 and +12 dB', () {
      final low = fxRackEntries(
        _preset(const {'Delay': 1, 'Master Vol': -0.2}),
      ).single.channels.level;
      final high = fxRackEntries(
        _preset(const {'Delay': 1, 'Master Vol': 1.3}),
      ).single.channels.level;

      expect(fxRackLevelDb(low), -12);
      expect(low, closeTo(0.2512, 1e-4));
      expect(fxRackLevelDb(high), 12);
      expect(high, closeTo(3.9811, 1e-4));
    });
  });

  group('reading a preset', () {
    test('lists the modules it names, by power key or by parameter', () {
      // Some presets carry a module's controls without its power key and the
      // other way round, so either is enough to say the rack has it.
      final byKey = fxPresetModules(_preset(const {'Pumper': 1}));
      expect(byKey.map((m) => m.name), ['Pumper']);

      final byParam = fxPresetModules(_preset(const {'Del Time': 0.4}));
      expect(byParam.map((m) => m.name), ['Delay']);
    });

    test("follows the rack's measured processing order", () {
      final modules = fxPresetModules(
        _preset(const {'Delay': 0, 'Comp': 1, 'Reverb': 1}),
      );

      // Ed's Rack runs Reverb before Delay, although its editor draws Delay
      // first.
      expect(modules.map((m) => m.name), ['Compressor', 'Reverb', 'Delay']);
    });

    test('keeps the modules the order does not place, after the placed ones '
        'and in table order', () {
      final modules = fxPresetModules(
        _preset(const {
          'Vinyl': 1,
          'Pumper': 1,
          'Delay': 1,
          'Slicer': 1,
          'Oct': 1,
        }),
      );

      expect(modules.map((m) => m.name), [
        'Octaver',
        'Delay',
        'Pumper',
        'Slicer',
        'Vinyl',
      ]);
    });

    test('keeps every module, in table order, for a family with no '
        'order', () {
      const preset = FxPreset(
        family: 'Unknown Rack',
        name: 'Unknown',
        id: 'unknown',
        type: 0,
        params: {'Reverb': 1, 'Wah': 1, 'Comp': 1, 'Amp': 1},
      );

      expect(kFxRackOrders.containsKey(preset.family), isFalse);
      expect(fxPresetModules(preset).map((m) => m.name), [
        'Amp',
        'Compressor',
        'Wah',
        'Reverb',
      ]);
    });

    test('names nothing for a preset carrying nothing it knows', () {
      expect(fxPresetModules(_preset(const {'Nonsense': 1})), isEmpty);
    });
  });

  group('the EQ variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);
    double hz(BuiltInEffect e, int i) => e.type.params[i].valueAt(e.params[i]);

    test("Ed's 4-band EQ copies every control as the value it applies", () {
      final build = fxModuleBuild(
        _module('Four-band EQ'),
        family: "Ed's Rack",
      );
      expect(build.type, TrackEffectType.eq);
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, List<int>.generate(14, (i) => i));

      final e = fxModuleEntry(
        _module('Four-band EQ'),
        preset("Ed's Rack", const {
          'EQ 4-Band': 1,
          'EQ Low Cut': 0.21,
          'EQ Low Q': 1,
          'EQ Lo Mid Freq': 0.17574,
          'EQ Hi Mid': 0.75,
          'EQ Hi Mid Freq': 0.66061,
          'EQ High Freq': 0.5278,
        }),
      );
      expect(e.type, TrackEffectType.eq);
      // The low cut's range is the kind's: copied as it is.
      expect(e.params[0], closeTo(0.21, 1e-12));
      // The measured applied values (#891): Lo Mid on 40..8000 Hz, Hi Mid on
      // 120..16000 Hz, High on 1200..20000 Hz, Low Q up to 10.
      expect(hz(e, 5), closeTo(101.5, 0.05));
      expect(hz(e, 8), closeTo(3040, 1));
      expect(hz(e, 11), closeTo(5298, 1));
      expect(hz(e, 3), closeTo(10, 1e-9));
      // Gains share the kind's -18..18 dB scale.
      expect(e.type.params[7].valueAt(e.params[7]), closeTo(9, 1e-9));
      // Four bells and both cuts.
      expect(e.type.params[14].positionOf(e.params[14]), 1);
    });

    test('the Drum Rack: shelves at 2/3 gain, one swept mid, no cuts', () {
      final e = fxModuleEntry(
        _module('Four-band EQ'),
        preset('Drum Rack', const {
          'EQ': 1,
          'EQ Low': 1,
          'EQ Mid': 0.25,
          'EQ Mid Freq': 0.5,
          'EQ High': 0.6,
        }),
      );
      expect(hz(e, 5), closeTo(40 * math.sqrt(200), 1e-6));
      expect(e.type.params[4].valueAt(e.params[4]), closeTo(-9, 1e-9));
      // +18 shown applies +12; the default +3.6 applies +2.4.
      expect(e.type.params[1].valueAt(e.params[1]), closeTo(12, 1e-9));
      expect(e.type.params[10].valueAt(e.params[10]), closeTo(2.4, 1e-9));
      expect(hz(e, 2), closeTo(200, 1e-6));
      expect(hz(e, 3), closeTo(0.5, 1e-9));
      expect(hz(e, 6), closeTo(0.9, 1e-9));
      expect(hz(e, 11), closeTo(4000, 1e-6));
      expect(hz(e, 12), closeTo(0.7, 1e-9));
      expect(e.type.params[14].positionOf(e.params[14]), 0);

      final build = fxEntryBuild(e)!;
      expect(build.exposed, [1, 4, 5, 10]);
      expect(build.labels[4], 'mid_gain');
    });

    test('the Rhythmic Rack is the parametric EQ with its Q at 1', () {
      const keys = {
        'EQ': 1.0,
        'EQ Low Cut': 0.0,
        'EQ High Cut': 1.0,
        'EQ Mid Freq': 0.5,
        'EQ Mid Gain': 0.5,
      };
      final rhythmic = fxModuleEntry(
        _module('Parametric EQ'),
        preset('Rhythmic Rack', keys),
      );
      expect(fxEntryBuild(rhythmic)!.exposed, [0, 4, 5, 13]);
      expect(
        rhythmic.type.params[6].valueAt(rhythmic.params[6]),
        closeTo(1, 1e-9),
      );
      expect(hz(rhythmic, 5), closeTo(120 * math.sqrt(16000 / 120), 1e-6));

      // The Dub Rack's Mid Freq moves the frequency, as labelled.
      final dub = fxModuleEntry(
        _module('Parametric EQ'),
        preset('Dub Rack', {...keys, 'Para EQ': 1, 'EQ Mid Q': 0.2}),
      );
      expect(fxEntryBuild(dub)!.exposed, [0, 4, 5, 6, 13]);
      expect(hz(dub, 5), closeTo(120 * math.sqrt(16000 / 120), 1e-6));
      expect(dub.enabled, isTrue);
    });

    test('Studio, Vocal and Vocal Tuner show four gains on fixed bells', () {
      for (final family in ['Studio Rack', 'Vocal Rack', 'Vocal Tuner Rack']) {
        final e = fxModuleEntry(
          _module('Four-band EQ'),
          preset(family, const {
            'EQ': 1,
            'EQ Low': 0.5,
            'EQ Mid': 0.5,
            'EQ High': 0.5,
            'EQ Air': 0.7,
          }),
        );
        final build = fxEntryBuild(e)!;
        expect(build.exposed, [1, 4, 7, 10], reason: family);
        expect(fxEntryControls(e).keys, [
          'low_gain',
          'mid_gain',
          'high_gain',
          'air_gain',
        ]);
        expect(e.type.params[10].valueAt(e.params[10]), closeTo(7.2, 1e-6));
        expect(
          [hz(e, 2), hz(e, 5), hz(e, 8), hz(e, 11)],
          [
            closeTo(300, 1e-6),
            closeTo(900, 1e-6),
            closeTo(2700, 1e-6),
            closeTo(8100, 1e-6),
          ],
        );
        expect(
          [hz(e, 3), hz(e, 6), hz(e, 9), hz(e, 12)],
          [
            closeTo(3.6, 1e-9),
            closeTo(1.2, 1e-9),
            closeTo(1.2, 1e-9),
            closeTo(3.6, 1e-9),
          ],
        );
        expect(e.type.params[14].positionOf(e.params[14]), 2);
      }
    });
  });

  group('the dynamics variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);
    double value(BuiltInEffect e, int i) =>
        e.type.params[i].valueAt(e.params[i]);

    test("Ed's compressor copies all five controls", () {
      final build = fxModuleBuild(_module('Compressor'), family: "Ed's Rack");
      expect(build.type, TrackEffectType.compressor);
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, [0, 1, 2, 3, 4]);

      final e = fxModuleEntry(
        _module('Compressor'),
        preset("Ed's Rack", const {
          'Compressor': 1,
          'Comp Thresh': 0.35,
          'Comp Ratio': 0.758,
          'Comp Attack': 0.5,
          'Comp Release': 0.5,
          'Comp Make-Up': 0.06,
        }),
      );
      // The derived tables' readings of these settings.
      expect(value(e, 0), closeTo(-21, 1e-6));
      expect(value(e, 1), closeTo(4.0, 0.01));
      expect(value(e, 2), closeTo(math.sqrt(0.01 * 300), 1e-6));
      expect(value(e, 3), closeTo(math.sqrt(5 * 4000), 1e-6));
      // Make-up shown as 1.8 dB applies 3.25 dB (#891).
      expect(value(e, 4), closeTo(3.25, 1e-6));
      expect(fxEntryControls(e).keys, [
        'threshold',
        'ratio',
        'attack',
        'release',
        'makeup',
      ]);
    });

    test("the Drum Rack's attack reads on its own 0.1 to 300 ms scale", () {
      final e = fxModuleEntry(
        _module('Compressor'),
        preset('Drum Rack', const {
          'Comp': 1,
          'Comp Thresh': 0.7,
          'Comp Attack': 0.2,
          'Comp Make-Up': 0.2,
        }),
      );
      expect(e.type, TrackEffectType.compressor);
      expect(value(e, 2), closeTo(0.1 * math.pow(3000, 0.2), 1e-6));
      expect(value(e, 0), closeTo(-42, 1e-6));
      // The hidden ratio and release, as measured.
      expect(value(e, 1), closeTo(4, 1e-9));
      expect(value(e, 3), closeTo(45, 1e-6));
      expect(value(e, 4), closeTo(10.08, 1e-6));
      expect(fxEntryBuild(e)!.exposed, [0, 2, 4]);
    });

    test('Dub, Studio, Vocal and Vocal Tuner show threshold and make-up', () {
      // The hidden ratio, attack and release, as measured.
      const hidden = {
        'Dub Rack': (6.0, 1.0, 80.0),
        'Studio Rack': (4.0, 1.5, 65.0),
        'Vocal Rack': (4.0, 1.5, 65.0),
        'Vocal Tuner Rack': (4.0, 1.5, 65.0),
      };
      for (final MapEntry(key: family, value: h) in hidden.entries) {
        final e = fxModuleEntry(
          _module('Compressor'),
          preset(family, const {
            'Comp': 1,
            'Comp Thresh': 0.8,
            'Comp Make-Up': 0.6,
          }),
        );
        expect(fxEntryBuild(e)!.exposed, [0, 4], reason: family);
        expect(value(e, 0), closeTo(-48, 1e-6));
        // Shown as 18 dB, applies 17.53 dB.
        expect(value(e, 4), closeTo(17.53, 1e-6));
        expect(value(e, 1), closeTo(h.$1, 1e-6), reason: family);
        expect(value(e, 2), closeTo(h.$2, 1e-6), reason: family);
        expect(value(e, 3), closeTo(h.$3, 1e-6), reason: family);
      }
    });

    test('the make-up applies the measured curve, not the display', () {
      // Shown 0..30 dB in a straight line; applied as measured (#891).
      const shownToApplied = [
        (0.0, 0.0),
        (0.03, 1.625),
        (0.4, 14.8),
        (0.775, 19.3),
        (1.0, 21.07),
      ];
      for (final (v, applied) in shownToApplied) {
        final e = fxModuleEntry(
          _module('Compressor'),
          preset("Ed's Rack", {'Compressor': 1, 'Comp Make-Up': v}),
        );
        expect(value(e, 4), closeTo(applied, 1e-6), reason: '$v');
      }
    });

    test('the transient shaper and the high-pass gate copy every control', () {
      final t = fxModuleEntry(
        _module('Transient'),
        preset('Drum Rack', const {
          'Transient': 1,
          'Attack': 0.75,
          'Attack Length': 0.48,
          'Sustain': 0.6,
        }),
      );
      expect(t.type, TrackEffectType.transient);
      expect(t.params.take(3), [0.75, 0.48, 0.6]);
      expect(fxEntryBuild(t)!.exposed, [0, 1, 2]);

      final g = fxModuleEntry(
        _module('High-pass gate'),
        preset('Vocal Tuner Rack', const {
          'HP/Gate': 1,
          'Highpass': 0.2,
          'Gate Thresh': 0.4,
        }),
      );
      expect(g.type, TrackEffectType.hpGate);
      // The derived tables' on-screen checks: 4 Hz shown, which applies a
      // corner of half that (#891), and -72 dB.
      expect(value(g, 0), closeTo(1.99, 0.01));
      expect(value(g, 1), closeTo(-72, 1e-6));
      expect(fxEntryControls(g).keys, ['highpass', 'gate_threshold']);
    });

    test('every factory preset builds its Looper X modules in full', () {
      final dir = Directory('../fx_catalogue/assets/presets');
      var built = 0;
      for (final family in dir.listSync().whereType<Directory>()) {
        final name = family.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        for (final file in family.listSync().whereType<File>()) {
          final parsed = FxPreset.tryParse(name, file.readAsStringSync());
          expect(parsed, isNotNull, reason: file.path);
          final p = parsed!;
          for (final module in fxPresetModules(p)) {
            if (!const [
              'Compressor',
              'Transient',
              'High-pass gate',
              'Doubler',
              'Chorus',
              'Wah',
              'Overdrive',
              'Distortion',
              'Vinyl',
              'Degrade',
              'Low-pass filter',
              'Spring reverb',
              'Modulation',
            ].contains(module.name)) {
              continue;
            }
            final e = fxModuleEntry(module, p);
            final build = fxEntryBuild(e);
            expect(build, isNotNull, reason: '${p.name} ${module.name}');
            expect(
              build!.readiness,
              FxModuleReadiness.full,
              reason: '${p.name} ${module.name}',
            );
            // Every key the preset gives the module, but its power key, has
            // a parameter.
            final placed = build.params.whereType<String>().toSet();
            for (final key in e.source.keys) {
              if (module.poweredBy(key) || build.unmapped.contains(key)) {
                continue;
              }
              expect(placed, contains(key), reason: '${p.name} $key');
            }
            built++;
          }
        }
      }
      // Dynamics (part 5): 36 Ed's, 12 Drum (compressor and transient), 11
      // Dub, 19 Studio, 17 Vocal and 25 Vocal Tuner (compressor and gate).
      // Modulation (part 6): the doubler in 11 Dub, 19 Studio, 17 Vocal and
      // 25 Vocal Tuner; the chorus and the wah in 36 Ed's; the wah in 14
      // Guitar. Drives (part 7): the overdrive in 36 Ed's and 14 Guitar; the
      // distortion in 15 Lo-Fi and 19 Studio. Lo-fi (part 7): the vinyl, the
      // degrade and the low-pass filter in 15 Lo-Fi, the filter in 10
      // Rhythmic. Reverbs (part 8): the spring in 14 Guitar. The Mod (part
      // 13) in 14 Guitar and 19 Studio.
      expect(
        built,
        (36 + 24 + 11 + 19 + 34 + 50) +
            (11 + 19 + 17 + 25 + 72 + 14) +
            (36 + 14 + 15 + 19) +
            (45 + 10) +
            14 +
            (14 + 19),
      );
    });
  });

  group('the modulation variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);

    test("the Dub Rack's doubler shows mix and separation, the others the "
        'mix alone, at half separation', () {
      final dub = fxModuleEntry(
        _module('Doubler'),
        preset('Dub Rack', const {
          'Doubler': 1,
          'Doubler Mix': 0.7,
          'Doubler Sep': 0.3,
        }),
      );
      expect(dub.type, TrackEffectType.doubler);
      expect(dub.params.take(2), [0.7, 0.3]);
      expect(fxEntryBuild(dub)!.exposed, [0, 1]);
      for (final family in ['Studio Rack', 'Vocal Rack', 'Vocal Tuner Rack']) {
        final e = fxModuleEntry(
          _module('Doubler'),
          preset(family, const {'Doubler': 1, 'Doubler Mix': 0.4}),
        );
        expect(fxEntryBuild(e)!.exposed, [0], reason: family);
        expect(e.params.take(2), [0.4, 0.5], reason: family);
      }
    });

    test("the Guitar Rack's Mod copies its four controls, its modes the "
        "kind's first three", () {
      // Rhythm Wet+Dirty as shipped: PHASER (0.5, the middle of three),
      // Rate 36.5 %, Depth 93.4 %, Mix 69.8 %.
      final e = fxModuleEntry(
        _module('Modulation'),
        preset('Guitar Rack', const {
          'Mod': 1,
          'Mod Rate': 0.365,
          'Mod Depth': 0.934,
          'Mod Mix': 0.698,
          'Mod Mode': 0.5,
        }),
      );
      expect(e.type, TrackEffectType.mod);
      expect(e.params.take(3), [
        closeTo(0.365, 1e-9),
        closeTo(0.934, 1e-9),
        closeTo(0.698, 1e-9),
      ]);
      // The PHASER: the kind's second of four.
      expect(e.params[3], closeTo(1 / 3, 1e-9));
      final build = fxEntryBuild(e)!;
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, [0, 1, 2, 3]);
      expect(fxEntryControls(e).keys, ['rate', 'depth', 'mix', 'mod_mode']);
      final mode = fxEntryParam(e, 3);
      expect(mode.steps, 3);
      expect(fxEntryShownSetting(e, 3), closeTo(0.5, 1e-9));
      // Its FLANGER is the kind's third.
      expect(fxEntryKindSetting(e, 3, 1), closeTo(2 / 3, 1e-9));
    });

    test("the Studio Rack's Mod shows rate, depth and Chorus or Tremolo, "
        'its chorus at half mix', () {
      // Studio Tremolo as shipped: Tremolo, Rate 82.7 %, Depth 100 %.
      final e = fxModuleEntry(
        _module('Modulation'),
        preset('Studio Rack', const {
          'Mod': 1,
          'Mod Rate': 0.827,
          'Mod Depth': 1,
          'Mod Mode': 1,
        }),
      );
      expect(e.type, TrackEffectType.mod);
      expect(e.params.take(3), [closeTo(0.827, 1e-9), 1, 0.5]);
      // Tremolo: the kind's last.
      expect(e.params[3], 1);
      final build = fxEntryBuild(e)!;
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, [0, 1, 3]);
      expect(fxEntryParam(e, 3).steps, 2);
      expect(fxEntryKindSetting(e, 3, 0), 0);
      final chorus = fxModuleEntry(
        _module('Modulation'),
        preset('Studio Rack', const {
          'Mod': 1,
          'Mod Rate': 0.272,
          'Mod Depth': 0.511,
          'Mod Mode': 0,
        }),
      );
      expect(chorus.params[3], 0);
    });

    test("Ed's chorus and both racks' wah copy every control", () {
      final chorus = fxModuleEntry(
        _module('Chorus'),
        preset("Ed's Rack", const {
          'Chor': 1,
          'Chor Rate': 0.45,
          'Chor Depth': 0.21,
          'Chor Mix': 0.5,
        }),
      );
      expect(chorus.type, TrackEffectType.chorus);
      expect(chorus.params.take(3), [0.45, 0.21, 0.5]);
      expect(fxEntryControls(chorus).keys, ['rate', 'depth', 'mix']);
      for (final family in ["Ed's Rack", 'Guitar Rack']) {
        final wah = fxModuleEntry(
          _module('Wah'),
          preset(family, const {'Wah': 0, 'Wah Pedal': 0.619}),
        );
        expect(wah.type, TrackEffectType.wah, reason: family);
        expect(wah.params.first, 0.619);
        expect(wah.enabled, isFalse);
        expect(fxEntryControls(wah).keys, ['pedal']);
      }
    });
  });

  group('the drive variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);

    test("Ed's and the Guitar Rack's overdrive copy drive and tone", () {
      for (final family in ["Ed's Rack", 'Guitar Rack']) {
        final e = fxModuleEntry(
          _module('Overdrive'),
          preset(family, const {
            'OvDrive': 1,
            'OD Drive': 0.3,
            'OD Tone': 0.6,
          }),
        );
        expect(e.type, TrackEffectType.overdrive, reason: family);
        expect(e.params.take(2), [0.3, 0.6]);
        expect(fxEntryBuild(e)!.readiness, FxModuleReadiness.full);
      }
    });

    test('the Lo-Fi Rack shows drive and tone, the Studio Rack the drive '
        'with the tone flat', () {
      final lofi = fxModuleEntry(
        _module('Distortion'),
        preset('Lo-Fi Rack', const {
          'Distort': 1,
          'Dist Drive': 0.2,
          'Dist Tone': 0.7,
        }),
      );
      expect(lofi.type, TrackEffectType.distortion);
      expect(lofi.enabled, isTrue);
      expect(fxEntryBuild(lofi)!.exposed, [0, 1]);
      expect(lofi.params.take(2), [0.2, 0.7]);
      final studio = fxModuleEntry(
        _module('Distortion'),
        preset('Studio Rack', const {'Dist Drive': 0.5}),
      );
      expect(fxEntryBuild(studio)!.exposed, [0]);
      expect(studio.params.take(2), [0.5, 0.5]);
    });
  });

  group('the lo-fi variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);

    test("the Lo-Fi Rack's vinyl and degrade copy every control", () {
      final vinyl = fxModuleEntry(
        _module('Vinyl'),
        preset('Lo-Fi Rack', const {
          'Vinyl': 1,
          'Vinyl Drive': 0.2,
          'Vinyl Freq': 0.5,
          'Vinyl Noise': 0.25,
          'Vinyl Noise-Tone': 0.9,
        }),
      );
      expect(vinyl.type, TrackEffectType.vinyl);
      expect(vinyl.params.take(4), [0.2, 0.5, 0.25, 0.9]);
      final degrade = fxModuleEntry(
        _module('Degrade'),
        preset('Lo-Fi Rack', const {
          'Degrade': 1,
          'Degrade Freq': 0.45,
          'Degrade Filter': 0.6,
          'Degrade Mix': 0.7,
        }),
      );
      expect(degrade.type, TrackEffectType.degrade);
      expect(degrade.params.take(3), [0.45, 0.6, 0.7]);
    });

    test("the low-pass filter: both racks' are full, the Rhythmic Rack's "
        'with its LFO', () {
      final lofi = fxModuleEntry(
        _module('Low-pass filter'),
        preset('Lo-Fi Rack', const {
          'LPF': 1,
          'LPF Cutoff': 0.7,
          'LPF Reso': 0.57,
        }),
      );
      expect(lofi.type, TrackEffectType.lpf);
      expect(fxEntryBuild(lofi)!.readiness, FxModuleReadiness.full);
      final rhythmic = fxModuleEntry(
        _module('Low-pass filter'),
        preset('Rhythmic Rack', const {
          'LPF': 1,
          'LPF Cutoff': 0.6,
          'LPF Reso': 0.3,
          'LPF LFO Depth': 0.8,
          'LPF LFO Rate': 0.6,
        }),
      );
      expect(fxEntryBuild(rhythmic)!.readiness, FxModuleReadiness.full);
      expect(rhythmic.params.take(4), [0.6, 0.3, 0.8, 0.6]);
      // Position 9 of 16: 4, a quarter note.
      expect(rhythmic.type.params[3].positionOf(0.6), 9);
      expect(fxEntryBuild(rhythmic)!.exposed, [0, 1, 2, 3]);
      // The Lo-Fi Rack's has no LFO: its depth stays at 0 and it shows two.
      expect(lofi.params[2], 0);
      expect(fxEntryBuild(lofi)!.exposed, [0, 1]);
    });
  });

  group('the pitch shift variant', () {
    BuiltInEffect entry(String family, double shift, double mix) =>
        fxModuleEntry(
          _module('Pitch shift'),
          FxPreset(
            family: family,
            name: 'p',
            id: 'p',
            type: 0,
            params: {'Pitch': 1, 'Pitch Shift': shift, 'Pitch Mix': mix},
          ),
        );

    test('runs on the octaver with the shift in semitones and the mix', () {
      // The Studio Rack's Bass Amp preset: 0.7917 is +7 semitones on the
      // rack's -12..+12.
      final e = entry('Studio Rack', 0.791666686534882, 0.402);
      expect(e.type, TrackEffectType.octaver);
      expect(e.type.params[0].valueAt(e.params[0]), closeTo(7, 1e-4));
      expect(e.params[2], closeTo(0.402, 1e-9));
      // Tone open, the phase vocoder, the formants moving with the pitch
      // (measured, #891).
      expect(e.params[1], 1);
      expect(e.params[3], 0);
      expect(e.params[4], 1);
    });

    test('shows the shift and the mix, the shift on the rack range', () {
      for (final family in ['Studio Rack', 'Vocal Rack']) {
        final e = entry(family, 0.5, 1);
        expect(fxEntryControls(e).params, [0, 2]);
        final shown = fxEntryParam(e, 0);
        expect(shown.steps, 25);
        expect(shown.atMin, -12);
        expect(shown.atMax, 12);
        expect(fxEntryShownSetting(e, 0), closeTo(0.5, 1e-9));
        // The mix shows as the kind's own.
        expect(fxEntryParam(e, 2), e.type.params[2]);
      }
    });

    test('a preset without the shift starts at unison', () {
      final e = fxModuleEntry(
        _module('Pitch shift'),
        const FxPreset(
          family: 'Vocal Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Pitch': 1, 'Pitch Mix': 1},
        ),
      );
      expect(e.type.params[0].valueAt(e.params[0]), closeTo(0, 1e-9));
    });

    test('a shown setting writes the kind setting for the same value', () {
      final e = entry('Vocal Rack', 0.5, 1);
      for (var step = 0; step < 25; step++) {
        final shown = step / 24;
        final kind = fxEntryKindSetting(e, 0, shown);
        expect(e.type.params[0].valueAt(kind), closeTo(step - 12, 1e-4));
        expect(
          fxEntryShownSetting(
            e.copyWith(params: [kind, ...e.params.skip(1)]),
            0,
          ),
          closeTo(shown, 1e-9),
        );
      }
    });
  });

  group('the reverb variants', () {
    test("the Dub Rack's reverbs copy decay and volume", () {
      const preset = FxPreset(
        family: 'Dub Rack',
        name: 'p',
        id: 'p',
        type: 0,
        params: {
          'Dub-Verb': 1,
          'Dub-Verb Dec': 0.8,
          'Dub-Verb Vol': 0.35,
          'Amb-Verb': 1,
          'Amb-Verb Dec': 0.3,
          'Amb-verb Vol': 0.5,
          'Amb-Dub Mix': 0.404,
        },
      );
      final dub = fxModuleEntry(_module('Dub reverb'), preset);
      expect(dub.type, TrackEffectType.dubVerb);
      expect(dub.params.take(2), [0.8, 0.35]);
      // The Looper X's display at Dec 0.8: (0.8 + 0.45) / 0.2 = 6.25 s.
      expect(dub.type.params[0].valueAt(0.8), closeTo(6.25, 1e-9));
      expect(dub.type.params[0].settingFor(6.25), closeTo(0.8, 1e-9));
      final amb = fxModuleEntry(_module('Ambience'), preset);
      expect(amb.type, TrackEffectType.ambVerb);
      // The Amb-Dub Mix rides the Amb-Verb, which mixes the rack's paths.
      expect(amb.params.take(3), [0.3, 0.5, 0.404]);
      expect(
        fxModuleBuild(_module('Ambience')).readiness,
        FxModuleReadiness.full,
      );
    });

    test("the Dub Rack's paths: Amb-Verb on one, the rest of the Dub "
        'pedals on the other, every other module on none', () {
      final preset = FxPreset.tryParse(
        'Dub Rack',
        File(
          '../fx_catalogue/assets/presets/Dub Rack/Dub FX 1.fxpreset',
        ).readAsStringSync(),
      )!;
      const rack = FxRack(id: 'r', name: 'Dub FX 1');
      final entries = [
        for (final e in fxRackEntries(preset)) e.copyWith(rack: rack),
      ];
      expect(
        {
          for (final (i, p) in fxEntryPaths(entries).indexed)
            entries[i].module: p,
        },
        {
          'Doubler': FxModulePath.dub,
          'Dub delay': FxModulePath.dub,
          'Dub reverb': FxModulePath.dub,
          'Ambience': FxModulePath.amb,
          'Compressor': null,
          'Parametric EQ': null,
        },
      );
      // Outside a rack an entry runs on no path, and so does a Dub path
      // module in a rack without the Amb-Verb that mixes the paths.
      final verb = fxRackEntries(preset).firstWhere(
        (e) => e.module == 'Dub reverb',
      );
      expect(fxEntryPaths([verb]), [null]);
      expect(
        fxEntryPaths([
          for (final e in entries)
            if (e.module != 'Ambience') e,
        ]),
        everyElement(isNull),
      );
      // A Dub Rack beside a rack holding a stray Dub module: only the Dub
      // Rack has paths.
      final stray = [
        for (final e in entries)
          if (e.module == 'Doubler')
            e.copyWith(
              rack: const FxRack(id: 'other', name: 'Other'),
            ),
      ];
      expect(fxEntryPaths([...entries, ...stray]), [
        FxModulePath.dub,
        FxModulePath.dub,
        FxModulePath.dub,
        FxModulePath.amb,
        null,
        null,
        null,
      ]);
      // Every other family's modules run on none, the Studio, Vocal and Vocal
      // Tuner doublers included (their presets carry no Doubler Sep).
      final dir = Directory('../fx_catalogue/assets/presets');
      for (final family in dir.listSync().whereType<Directory>()) {
        final name = family.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (name == 'Dub Rack') continue;
        for (final file in family.listSync().whereType<File>()) {
          final p = FxPreset.tryParse(name, file.readAsStringSync())!;
          expect(
            fxEntryPaths([
              for (final e in fxRackEntries(p)) e.copyWith(rack: rack),
            ]),
            everyElement(isNull),
            reason: file.path,
          );
        }
      }
      // And the engine model carries it for the performance render.
      final engine = trackEffectsToEngine(entries);
      expect(
        [for (final e in engine) e.toJson()['rackPath']],
        [
          'dub',
          'dub',
          'dub',
          'amb',
          null,
          null,
        ],
      );
    });

    test('the Guitar Amp copies drive, tone, Modern and the cabinet', () {
      // Lead Crunch as shipped: drive 22.7 %, Bass 60 %, Treble 50 %,
      // Modern 66.7 %, the 4x12" (7 of 0..11).
      final e = fxModuleEntry(
        _module('Amp'),
        const FxPreset(
          family: 'Guitar Rack',
          name: 'Lead Crunch',
          id: 'l',
          type: 0,
          params: {
            'Amp': 1,
            'Amp Drive': 0.227,
            'Amp Bass': 0.6,
            'Amp Treble': 0.5,
            'Amp Modern': 0.667,
            'Cab': 7 / 11,
          },
        ),
      );
      expect(e.type, TrackEffectType.ampCab);
      expect(e.params.take(5), [
        closeTo(0.227, 1e-9),
        closeTo(0.6, 1e-9),
        0.5,
        closeTo(0.667, 1e-9),
        closeTo(7 / 11, 1e-9),
      ]);
      final build = fxEntryBuild(e)!;
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, [0, 1, 2, 3, 4]);
      expect(fxEntryControls(e).keys, [
        'drive',
        'bass',
        'treble',
        'modern',
        'cabinet',
      ]);
    });

    test("Ed's Octaver copies both octaves, high mode and the mix", () {
      // Bass Octave Layer as shipped: high mode off, Octave 2 at 60 %.
      final e = fxModuleEntry(
        _module('Octaver'),
        const FxPreset(
          family: "Ed's Rack",
          name: 'Bass Octave Layer',
          id: 'b',
          type: 0,
          params: {
            'Oct': 1,
            'Oct High Mode': 0,
            'Octave 1 Vol': 1,
            'Octave 2 Vol': 0.6,
            'Octave Mix': 1,
          },
        ),
      );
      expect(e.type, TrackEffectType.dualOctaver);
      expect(e.params.take(4), [0.0, 1.0, 1.0, closeTo(0.6, 1e-9)]);
      final build = fxEntryBuild(e)!;
      expect(build.readiness, FxModuleReadiness.full);
      expect(build.exposed, [0, 1, 2, 3]);
      expect(fxEntryControls(e).keys, [
        'oct_high_mode',
        'octave_1_vol',
        'mix',
        'octave_2_vol',
      ]);
    });

    group('the Room reverb', () {
      BuiltInEffect verb(String family, Map<String, double> params) =>
          fxModuleEntry(
            _module('Reverb'),
            FxPreset(
              family: family,
              name: 'p',
              id: 'p',
              type: 0,
              params: {'Reverb': 1, ...params},
            ),
          );
      int room(BuiltInEffect e) => e.type.params[2].positionOf(e.params[2]);

      test(
        "reads a mode rack's stored mode as the kind's first four rooms",
        () {
          for (var k = 0; k < 4; k++) {
            final e = verb('Studio Rack', {'Rev Mode': k / 3});
            expect(room(e), k);
            // Studio and Rhythmic hide Bright and play the 75 % they read.
            expect(e.params[3], closeTo(0.75, 1e-9));
          }
          expect(room(verb('Vocal Rack', {'Rev Mode': 2 / 3})), 2);
        },
      );

      test("plays HALL on Ed's whatever its stored mode", () {
        final e = verb("Ed's Rack", {'Rev Mode': 1, 'Rev Bright': 0.8});
        expect(room(e), 0);
        expect(e.params[3], closeTo(0.8, 1e-9));
      });

      test("reads the Drum Rack's ER rooms, and 12 to 14 as CHURCH", () {
        // A preset stores one of the Looper X's 15 positions (k / 14); the
        // kind's ER rooms are its rooms 4 to 15.
        for (var k = 0; k < 15; k++) {
          final e = verb('Drum Rack', {
            'Rev Length': 0.16,
            'Rev Mix': 0.3,
            'Rev ER': k / 14,
            'Rev Lo/Hi': 0.5,
            'Rev Tail/ER': 0.3,
            'Rev Density': 1,
          });
          expect(room(e), 4 + (k < 12 ? k : 11), reason: 'position $k');
          expect(
            fxEntryShownSetting(e, 2),
            closeTo((k < 12 ? k : 11) / 11, 1e-9),
          );
        }
      });

      test("tells Ed's reverb from the Vocal Rack's by its rack", () {
        // Their keys are the same; the rack each was built in decides.
        final keys = {
          'Rev Length': 0.4,
          'Rev Mix': 0.1,
          'Rev Mode': 0.0,
          'Rev Bright': 0.8,
        };
        for (final (family, exposed) in [
          ("Ed's Rack", [0, 1, 3]),
          ('Vocal Rack', [0, 1, 2, 3]),
        ]) {
          final e = verb(family, keys).copyWith(
            rack: FxRack(id: 'r', name: 'r', art: kFxFamilySlugs[family]),
          );
          expect(fxEntryBuild(e)?.exposed, exposed, reason: family);
        }
      });
    });

    test("the Rhythmic Rack's Slicer copies pattern, step and mix", () {
      final e = fxModuleEntry(
        _module('Slicer'),
        const FxPreset(
          family: 'Rhythmic Rack',
          name: 'Reverse',
          id: 'r',
          type: 0,
          params: {
            'Slicer': 1,
            'Slic Patt': 0.8421052694320679,
            'Slic Step Len': 0.5,
            'Slic Mix': 1,
          },
        ),
      );

      expect(e.type, TrackEffectType.slicer);
      expect(e.enabled, isTrue);
      expect(e.params[1], 0.5);
      expect(e.params[2], 1);
      // Position 16 of 20: <<<<, the factory Reverse.
      expect(e.type.params[0].positionOf(e.params[0]), 16);
      expect(
        fxModuleBuild(_module('Slicer')).readiness,
        FxModuleReadiness.full,
      );
    });

    test("the Rhythmic Rack's Pumper copies rate and depth", () {
      final e = fxModuleEntry(
        _module('Pumper'),
        const FxPreset(
          family: 'Rhythmic Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Pumper': 1, 'Pumper Rate': 0.7, 'Pumper Depth': 0.35},
        ),
      );
      expect(e.type, TrackEffectType.pumper);
      expect(e.params.take(2), [0.7, 0.35]);
      // Position 7 of 11: 1/16.
      expect(e.type.params[0].positionOf(0.7), 7);
      expect(
        fxModuleBuild(_module('Pumper')).readiness,
        FxModuleReadiness.full,
      );
    });

    test("the Guitar Rack's Whammy copies pedal and range", () {
      final e = fxModuleEntry(
        _module('Whammy'),
        const FxPreset(
          family: 'Guitar Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Whammy': 1, 'Whammy Pedal': 0.5, 'Whammy Range': 1},
        ),
      );
      expect(e.type, TrackEffectType.whammy);
      expect(e.enabled, isTrue);
      expect(e.params.take(2), [0.5, 1.0]);
      expect(
        fxModuleBuild(_module('Whammy')).readiness,
        FxModuleReadiness.full,
      );
    });

    test("the Guitar Rack's spring copies time and mix", () {
      final e = fxModuleEntry(
        _module('Spring reverb'),
        const FxPreset(
          family: 'Guitar Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Spring': 1, 'Spring Time': 0.30103, 'Spring Mix': 0.289},
        ),
      );
      expect(e.type, TrackEffectType.spring);
      expect(e.params.take(2), [0.30103, 0.289]);
      // The derived tables' on-screen check: 0.30103 is 2.00 s.
      expect(e.type.params[0].valueAt(e.params[0]), closeTo(2.0, 1e-4));
    });
  });
}
