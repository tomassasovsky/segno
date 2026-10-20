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
    test('a module the engine has no effect for is unavailable, and most of '
        'the catalogue is', () {
      // Twenty-six modules against seven built-ins, so this is the common
      // case rather than the exception. Saying so is the point: the accepted
      // design forbids substituting another effect and calling that parity.
      expect(
        fxModuleBuild(_module('Pumper')).readiness,
        FxModuleReadiness.unavailable,
      );
      expect(fxModuleBuild(_module('Pumper')).type, isNull);

      final unavailable = kFxModules
          .where(
            (m) => fxModuleBuild(m).readiness == FxModuleReadiness.unavailable,
          )
          .length;
      expect(unavailable, greaterThan(kFxModules.length ~/ 2));
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
          'Delay',
          'Distortion',
          'Dub Delay',
          'Low-pass Filter',
          'Octaver',
          'Overdrive',
          'Reverb',
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

    test('keeps a module the order does not place, after the placed ones', () {
      final modules = fxPresetModules(
        _preset(const {'Pumper': 1, 'Delay': 1, 'Oct': 1}),
      );

      expect(modules.map((m) => m.name), ['Octaver', 'Delay', 'Pumper']);
    });

    test('names nothing for a preset carrying nothing it knows', () {
      expect(fxPresetModules(_preset(const {'Nonsense': 1})), isEmpty);
    });
  });
}
