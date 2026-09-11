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
      expect(delay.unmapped, contains('Del Mode'));
      expect(delay.unmapped, contains('Del Reso'));
    });

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

    test('an out-of-range preset value is clamped rather than pushed on', () {
      final entry = fxModuleEntry(
        _module('Delay'),
        _preset(const {'Del Time': 2, 'Del Feedback': -1}),
      );

      expect(entry.params[0], 1.0);
      expect(entry.params[1], 0.0);
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

    test('keeps the table order, which is not a processing order', () {
      final modules = fxPresetModules(
        _preset(const {'Reverb': 1, 'Comp': 1, 'Delay': 0}),
      );

      // The source does not say what order a rack runs its pedals in, so this
      // is the table's order and the doc says so.
      expect(modules.map((m) => m.name), ['Compressor', 'Delay', 'Reverb']);
    });

    test('names nothing for a preset carrying nothing it knows', () {
      expect(fxPresetModules(_preset(const {'Nonsense': 1})), isEmpty);
    });
  });
}
