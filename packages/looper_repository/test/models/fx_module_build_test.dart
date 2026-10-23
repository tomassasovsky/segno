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
        fxModuleBuild(_module('Pumper')).readiness,
        FxModuleReadiness.unavailable,
      );
      expect(fxModuleBuild(_module('Pumper')).type, isNull);

      expect(
        [
          for (final m in kFxModules)
            if (fxModuleBuild(m).readiness == FxModuleReadiness.unavailable)
              m.name,
        ],
        [
          'Amp',
          'Modulation',
          'Pitch shift',
          'Whammy',
          'Ambience',
          'Dub reverb',
          'Pumper',
          'Slicer',
          'Harmonizer',
          'Smart tune',
        ],
      );
    });

    test('a module the engine builds but cannot carry every control of is '
        'PARTIAL, with the stranded controls named', () {
      final delay = fxModuleBuild(_module('Delay'));

      expect(delay.readiness, FxModuleReadiness.partial);
      expect(delay.type, TrackEffectType.delay);
      // Kept and named, so a surface can show them and say they do not reach
      // the sound rather than drawing a control that does nothing.
      expect(delay.unmapped, ['Del Freq', 'Del Mode']);
    });

    test("the Dub Rack's delay builds from its own power key and keys", () {
      final dub = fxModuleBuild(_module('Dub delay'));

      expect(dub.type, TrackEffectType.delay);
      expect(dub.readiness, FxModuleReadiness.partial);
      expect(dub.unmapped, contains('Del Damp'));

      final entry = fxModuleEntry(
        _module('Dub delay'),
        const FxPreset(
          family: 'Dub Rack',
          name: 'Light',
          id: 'dub',
          type: 4,
          params: {'Dub Delay': 0, 'Del Time': 0.3, 'Del Feedback': 0.6},
        ),
      );
      // Powered by `Dub Delay`, which the dub reverb used to take as one of
      // its own parameters, leaving the delay always on.
      expect(entry.enabled, isFalse);
      expect(entry.params[0], closeTo(0.3, 1e-9));
      expect(entry.params[1], closeTo(0.6, 1e-9));
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
          'Octaver',
          'Overdrive',
          'Parametric EQ',
          'Reverb',
          'Spring Reverb',
          'Transient',
          'Vinyl',
          'Wah',
        ]);
      },
    );

    test("the reverb's brightness is NOT wired into the engine's damping", () {
      final reverb = fxModuleBuild(_module('Reverb'));

      // Brightness is damping's complement, and inverting someone else's
      // control into ours is exactly the silent substitution the accepted
      // design forbids. It stays unmapped and visible.
      expect(reverb.params[1], isNull);
      expect(reverb.unmapped, contains('Rev Bright'));
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

      expect(entry.type, TrackEffectType.delay);
      expect(entry.params[0], closeTo(0.42, 1e-9));
      expect(entry.params[1], closeTo(0.35, 1e-9));
      expect(entry.params[2], closeTo(0.25, 1e-9));
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
      // The catalogue's octaver is two fixed voices with their own levels
      // where this engine's is one continuously shifted voice, so its shift
      // has nothing to read. Zero would be two octaves down, which is a sound
      // nobody asked for.
      final entry = fxModuleEntry(
        _module('Octaver'),
        _preset(const {'Oct': 1, 'Octave Mix': 1}),
      );
      final engineDefault = BuiltInEffect(type: TrackEffectType.octaver);

      expect(entry.params[0], engineDefault.params[0]);
      expect(entry.params[2], 1.0);
    });

    test('an unavailable module still takes its place in the chain, passing '
        'signal through', () {
      // A rack is what the player loaded, not what this build can run — so
      // the pedal is there, and it is a passthrough rather than absent.
      final entry = fxModuleEntry(
        _module('Pumper'),
        _preset(const {'Pumper': 1, 'Pumper Depth': 0.8}),
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

    test("Ed's 4-band EQ copies every control and holds the air band flat", () {
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
          'EQ Lo Mid Freq': 0.17574,
          'EQ Hi Mid': 0.75,
        }),
      );
      expect(e.type, TrackEffectType.eq);
      // The low cut's range is the kind's: copied as it is.
      expect(e.params[0], closeTo(0.21, 1e-12));
      // The mid frequency is read on Ed's 100..8000 Hz scale and set to the
      // same frequency on the kind's 20..20000 Hz scale.
      expect(hz(e, 5), closeTo(100 * math.pow(80, 0.17574), 1e-6));
      // Gains share the kind's -18..18 dB scale.
      expect(e.type.params[7].valueAt(e.params[7]), closeTo(9, 1e-9));
      expect(e.type.params[14].valueAt(e.params[14]), closeTo(0, 1e-9));
    });

    test('the Drum Rack sweeps one mid from 40 Hz and fixes the rest', () {
      final e = fxModuleEntry(
        _module('Four-band EQ'),
        preset('Drum Rack', const {
          'EQ': 1,
          'EQ Low': 0.5,
          'EQ Mid': 0.25,
          'EQ Mid Freq': 0.5,
          'EQ High': 0.5,
        }),
      );
      expect(hz(e, 5), closeTo(40 * math.sqrt(200), 1e-6));
      expect(e.type.params[4].valueAt(e.params[4]), closeTo(-9, 1e-9));
      expect(hz(e, 2), closeTo(100, 1e-6));
      expect(hz(e, 11), closeTo(5000, 1e-6));
      expect(e.params[0], 0.0); // low cut off
      expect(e.params[13], 1.0); // high cut off

      final build = fxEntryBuild(e)!;
      expect(build.exposed, [1, 4, 5, 10]);
      expect(build.labels[4], 'mid_gain');
    });

    test('the Rhythmic Rack is the parametric EQ without its Q', () {
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
        closeTo(0.7616, 1e-6),
      );
      expect(hz(rhythmic, 5), closeTo(120 * math.sqrt(16000 / 120), 1e-6));

      final dub = fxModuleEntry(
        _module('Parametric EQ'),
        preset('Dub Rack', {...keys, 'Para EQ': 1, 'EQ Mid Q': 0.2}),
      );
      expect(fxEntryBuild(dub)!.exposed, [0, 4, 5, 6, 13]);
      expect(dub.enabled, isTrue);
    });

    test('Studio, Vocal and Vocal Tuner show four gains', () {
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
        expect(fxEntryBuild(e)!.exposed, [1, 4, 10, 14], reason: family);
        expect(e.type.params[14].valueAt(e.params[14]), closeTo(7.2, 1e-6));
        expect(hz(e, 5), closeTo(1000, 1e-6));
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
      expect(value(e, 4), closeTo(1.8, 1e-6));
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
      // The hidden ratio and release are Ed's.
      expect(value(e, 1), closeTo(4, 1e-9));
      expect(value(e, 3), closeTo(141.4, 1e-6));
      expect(fxEntryBuild(e)!.exposed, [0, 2, 4]);
    });

    test('Dub, Studio, Vocal and Vocal Tuner show threshold and make-up', () {
      for (final family in [
        'Dub Rack',
        'Studio Rack',
        'Vocal Rack',
        'Vocal Tuner Rack',
      ]) {
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
        expect(value(e, 4), closeTo(18, 1e-6));
        expect(value(e, 1), closeTo(4, 1e-9));
        expect(value(e, 2), closeTo(1.732, 1e-6));
        expect(value(e, 3), closeTo(141.4, 1e-6));
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
      // The derived tables' on-screen checks: 4 Hz and -72 dB.
      expect(value(g, 0), closeTo(3.98, 0.01));
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
            ].contains(module.name)) {
              continue;
            }
            final e = fxModuleEntry(module, p);
            final build = fxEntryBuild(e);
            expect(build, isNotNull, reason: '${p.name} ${module.name}');
            // The Rhythmic Rack's low-pass filter drops its LFO until the
            // tempo context lands (#887 part 10); everything else is full.
            expect(
              build!.readiness,
              p.family == 'Rhythmic Rack' && module.name == 'Low-pass filter'
                  ? FxModuleReadiness.partial
                  : FxModuleReadiness.full,
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
      // Rhythmic. Reverbs (part 8): the spring in 14 Guitar.
      expect(
        built,
        (36 + 24 + 11 + 19 + 34 + 50) +
            (11 + 19 + 17 + 25 + 72 + 14) +
            (36 + 14 + 15 + 19) +
            (45 + 10) +
            14,
      );
    });
  });

  group('the modulation variants', () {
    FxPreset preset(String family, Map<String, double> params) =>
        FxPreset(family: family, name: 'p', id: 'p', type: 0, params: params);

    test("the Dub Rack's doubler shows mix and separation, the others the "
        'mix alone, at full separation', () {
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
        expect(e.params.take(2), [0.4, 1.0], reason: family);
      }
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

    test("the low-pass filter: the Lo-Fi Rack's is full, the Rhythmic Rack's "
        'drops its LFO until part 10', () {
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
      expect(fxEntryBuild(rhythmic)!.readiness, FxModuleReadiness.partial);
      expect(rhythmic.params.take(2), [0.6, 0.3]);
    });
  });

  group('the reverb variants', () {
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
