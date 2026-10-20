import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';

/// Serves the package's own asset files off disk, plus the asset manifest
/// Flutter would build from them.
///
/// The real files, not a fixture: this package's whole job is to read what the
/// import actually copied, and a hand-written fixture would only ever prove
/// the parser reads the shape the test author imagined.
class _DiskBundle extends CachingAssetBundle {
  _DiskBundle(this.root, this.keys);

  final Directory root;
  final List<String> keys;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final k in keys) k: <Object?>[],
      })!;
    }
    const prefix = 'packages/fx_catalogue/';
    if (!key.startsWith(prefix)) throw FlutterError('missing: $key');
    final file = File('${root.path}/${key.substring(prefix.length)}');
    if (!file.existsSync()) throw FlutterError('missing: $key');
    final bytes = await file.readAsBytes();
    return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  }
}

/// A bundle whose asset manifest cannot be read at all.
class _NoManifestBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw const FormatException();
}

/// The disk bundle with the IMPORT manifest replaced, to exercise a bundle
/// that holds the file but not a readable one.
class _TextBundle extends _DiskBundle {
  _TextBundle(super.root, super.keys, this.manifest);

  final String manifest;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'packages/fx_catalogue/assets/manifest.json') {
      final bytes = utf8.encode(manifest);
      return ByteData.view(
        Uint8List.fromList(bytes).buffer,
      );
    }
    return super.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory('${Directory.current.path}/assets').parent;
  final assets = Directory('${root.path}/assets');
  final onDisk = assets
      .listSync(recursive: true)
      .whereType<File>()
      .map(
        (f) =>
            'packages/fx_catalogue/assets/'
            '${f.path.substring(assets.path.length + 1)}',
      )
      .toList();

  late FxCatalogue catalogue;

  setUpAll(() async {
    catalogue = await FxCatalogueLoader(
      bundle: _DiskBundle(root, onDisk),
    ).load();
  });

  group('the bundled catalogue', () {
    test('loads every family the import copied, each with its artwork', () {
      expect(catalogue.families.map((f) => f.name), [
        'Drum Rack',
        'Dub Rack',
        "Ed's Rack",
        'Guitar Rack',
        'Lo-Fi Rack',
        'Rhythmic Rack',
        'Studio Rack',
        'Vocal Rack',
        'Vocal Tuner Rack',
      ]);
      // Every artwork path a family names is a file that is actually here —
      // the folder names and the image names do not follow one rule, so a
      // slug derived rather than mapped would draw the wrong rack.
      for (final family in catalogue.families) {
        for (final asset in [
          family.stripAsset,
          family.selectorAsset,
          family.footswitchAsset,
        ]) {
          expect(
            File('${root.path}/$asset').existsSync(),
            isTrue,
            reason: '${family.name} is missing $asset',
          );
        }
      }
    });

    test('loads all 159 presets the import verified', () {
      expect(catalogue.presets, hasLength(159));
      // Ed's Rack is the one the accepted design gives its own wide treatment,
      // so its count is the one worth pinning by name.
      expect(catalogue.family("Ed's Rack")!.presets, hasLength(36));
    });

    test('keeps each preset source-exact: its own id, type, version and '
        'parameter names', () {
      final preset = catalogue
          .family("Ed's Rack")!
          .presets
          .firstWhere((p) => p.name == 'Acoustic Rhythm 1');

      expect(preset.id, 'ed53e7b8-a878-4907-8c61-f529eaa3d5d0');
      expect(preset.version, '0.0.5');
      // Retained verbatim and NOT read as a family: two families carry the
      // same value in the source and one family carries two.
      expect(preset.type, 0);
      // The source's own names, unrenamed — including the fourteen controls
      // the four-band EQ carries, plus its own `EQ 4-Band` enable value, which
      // the accepted design gives to the power button rather than to a
      // control row of its own.
      expect(preset.params['EQ Hi Mid Freq'], closeTo(0.66060900, 1e-7));
      expect(preset.params['Rev Mix'], closeTo(0.05, 1e-7));
      expect(preset.params['EQ 4-Band'], 1.0);
      expect(
        preset.params.keys.where(
          (k) => k.startsWith('EQ ') && k != 'EQ 4-Band',
        ),
        hasLength(14),
      );
      // `_version` is lifted out of the parameters, not left among them.
      expect(preset.params.containsKey('_version'), isFalse);
    });

    test('no preset loses a parameter on the way in', () {
      // Every numeric key in every source file survives the parse. A quiet
      // filter here would be exactly the twenty entries the accepted design
      // says must stop being dropped by name.
      for (final family in catalogue.families) {
        for (final preset in family.presets) {
          final file = File(
            '${root.path}/assets/presets/${family.name}/${preset.name}'
            '.fxpreset',
          );
          if (!file.existsSync()) continue;
          final raw =
              jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
          final inner =
              jsonDecode(raw['content']! as String) as Map<String, Object?>;
          final numeric = inner.entries
              .where((e) => e.key != '_version' && e.value is num)
              .length;
          expect(
            preset.params,
            hasLength(numeric),
            reason: '${family.name} / ${preset.name}',
          );
        }
      }
    });

    test('module names are read off the parameter prefixes, in first-seen '
        'order', () {
      final preset = catalogue
          .family("Ed's Rack")!
          .presets
          .firstWhere((p) => p.name == 'Acoustic Rhythm 1');

      // A reading of the data, not a recovered chain: the source never says
      // which modules a rack holds or what order they run in.
      expect(preset.moduleNames, contains('EQ'));
      expect(preset.moduleNames, contains('Rev'));
      expect(preset.moduleNames.toSet(), hasLength(preset.moduleNames.length));
    });

    test('a stomp illustration resolves only for a name the catalogue '
        'actually carries', () {
      expect(fxStompAsset('Delay3'), 'assets/images/stomps/Delay3.png');
      expect(
        File('${root.path}/${fxStompAsset('Delay3')}').existsSync(),
        isTrue,
      );
      // Not every module prefix has one: the source files artwork per pedal
      // IDENTITY, so a prefix with no image gets null rather than a path that
      // fails to load.
      expect(fxStompAsset('Del'), isNull);
      expect(fxStompAsset('NotAPedal'), isNull);
    });

    test('saved display names resolve to their artwork, not power aliases', () {
      final overdrive = fxModuleNamed('Overdrive');
      expect(overdrive, isNotNull);
      expect(overdrive!.enables, contains('OvDrive'));
      expect(fxModuleArt('Overdrive'), 'assets/images/stomps/Overdrive2.png');
      expect(
        File('${root.path}/${fxModuleArt('Overdrive')}').existsSync(),
        isTrue,
      );
      expect(fxModuleNamed('OvDrive'), isNull);
      expect(fxModuleArt('OvDrive'), isNull);
      expect(fxModuleNamed('Removed module'), isNull);
      expect(fxModuleArt('Removed module'), isNull);
    });
  });

  group('a build without the assets', () {
    test('loads an empty catalogue rather than throwing', () async {
      final loaded = await FxCatalogueLoader(
        bundle: _DiskBundle(root, const []),
      ).load();

      expect(loaded.isEmpty, isTrue);
      expect(loaded.presets, isEmpty);
    });

    test('a bundle with no asset manifest at all loads empty', () async {
      final loaded = await FxCatalogueLoader(
        bundle: _NoManifestBundle(),
      ).load();

      expect(loaded.isEmpty, isTrue);
    });

    test('an unreadable import manifest loads empty rather than half a '
        'catalogue', () async {
      final loaded = await FxCatalogueLoader(
        bundle: _TextBundle(root, onDisk, 'not json'),
      ).load();

      expect(loaded.isEmpty, isTrue);
    });

    test('an import manifest that is not a list loads empty', () async {
      final loaded = await FxCatalogueLoader(
        bundle: _TextBundle(root, onDisk, '{"presets":[]}'),
      ).load();

      expect(loaded.isEmpty, isTrue);
    });
  });

  group('a malformed preset', () {
    test('is skipped, not fatal', () {
      expect(FxPreset.tryParse('F', 'not json'), isNull);
      expect(FxPreset.tryParse('F', '[1,2]'), isNull);
      expect(FxPreset.tryParse('F', '{"name":"n"}'), isNull);
      expect(
        FxPreset.tryParse('F', '{"name":"n","id":"i","content":"not json"}'),
        isNull,
      );
    });
  });

  group('the module table', () {
    // The table is a reading of the data, so what a test can pin is that the
    // reading matches what is actually there — never that it is the source's
    // own grouping, which the source does not record.

    test('no two modules of one rack claim the same power key or parameter '
        'group', () {
      for (final family in kFxFamilySlugs.keys) {
        final keys = <String, String>{};
        for (final module in kFxModules.where((m) => m.appearsIn(family))) {
          for (final key in module.enables) {
            expect(
              keys.containsKey(key),
              isFalse,
              reason:
                  '$key claimed by both ${keys[key]} and ${module.name} in '
                  '$family',
            );
            keys[key] = module.name;
          }
        }
        final groups = <String, String>{};
        for (final module in kFxModules.where((m) => m.appearsIn(family))) {
          for (final group in module.groups) {
            expect(
              groups.containsKey(group),
              isFalse,
              reason:
                  '$group claimed by both ${groups[group]} and '
                  '${module.name} in $family',
            );
            groups[group] = module.name;
          }
        }
      }
    });

    test('every power key the table names appears in the catalogue', () {
      final present = <String>{
        for (final preset in catalogue.presets) ...preset.params.keys,
      };
      for (final module in kFxModules) {
        for (final key in module.enables) {
          expect(
            present,
            contains(key),
            reason: '${module.name} names a power key nothing carries: $key',
          );
        }
      }
    });

    test('every parameter group the table names appears in the catalogue', () {
      final prefixes = <String>{
        for (final preset in catalogue.presets)
          for (final key in preset.params.keys) key.split(' ').first,
      };
      for (final module in kFxModules) {
        for (final group in module.groups) {
          expect(
            prefixes,
            contains(group),
            reason: '${module.name} names a group nothing carries: $group',
          );
        }
      }
    });

    test('every parameter group in the catalogue is claimed, or listed as '
        'unclaimed on purpose', () {
      // The one check that catches the table falling behind the data: a
      // family whose pedals nothing accounts for would otherwise draw as a
      // rack with missing controls and no sign of why.
      final unaccounted = <String>{};
      for (final preset in catalogue.presets) {
        for (final key in preset.params.keys) {
          final prefix = key.split(' ').first;
          if (kFxUnclaimedGroups.contains(prefix)) continue;
          if (fxModulesOwning(key, preset.family).isNotEmpty) continue;
          if (fxModuleFor(key, preset.family) != null) continue;
          unaccounted.add(key);
        }
      }
      expect(unaccounted, isEmpty);
    });

    test(
      "a module's power key is binary wherever the catalogue carries it",
      () {
        // What makes a key a POWER key rather than a parameter that happens to
        // be spelled without a space: `Cab` and `Sustain` are space-free too,
        // and continuous.
        for (final module in kFxModules) {
          for (final key in module.enables) {
            for (final preset in catalogue.presets) {
              final value = preset.params[key];
              if (value == null) continue;
              expect(
                value == 0.0 || value == 1.0,
                isTrue,
                reason: '${module.name} / $key is $value in ${preset.name}',
              );
            }
          }
        }
      },
    );

    test('every illustration the table names is a file that is here', () {
      for (final module in kFxModules) {
        expect(module.artwork, isNotEmpty, reason: module.name);
        for (final art in module.artwork) {
          expect(
            kFxStompAssets,
            contains(art),
            reason: '${module.name} names $art',
          );
          expect(
            File('${root.path}/${fxStompAsset(art)}').existsSync(),
            isTrue,
            reason: '${module.name} names $art',
          );
        }
      }
    });

    test('a module with several illustrations records them all, because the '
        'data does not say which variant a family used', () {
      final delay = kFxModules.firstWhere((m) => m.name == 'Delay');

      expect(delay.artwork, ['Delay3', 'Delay4', 'Delay6']);
      // The first is what a surface draws; the rest keep the gap visible.
      expect(delay.artwork.first, 'Delay3');
    });

    test('the power key and the parameter prefix are usually different '
        'words, which is why the table exists', () {
      final delay = kFxModules.firstWhere((m) => m.name == 'Delay');
      expect(delay.enables, ['Delay']);
      expect(delay.groups, ['Del']);

      expect(fxModuleFor('Delay', "Ed's Rack")!.name, 'Delay');
      expect(
        fxModulesOwning('Del Feedback', "Ed's Rack").map((m) => m.name),
        ['Delay'],
      );
      // And the power key is not a parameter of its own module.
      expect(fxModulesOwning('Delay', "Ed's Rack"), isEmpty);
    });

    test("the rack's own level belongs to no pedal", () {
      // The accepted design puts rack level AFTER the pedals and gives it to
      // the rack, so claiming it for a module would put it on the wrong
      // control.
      for (final family in kFxFamilySlugs.keys) {
        expect(fxModulesOwning('Master Vol', family), isEmpty);
      }
      expect(kFxUnclaimedGroups, {'Master'});
    });

    test("the Dub Rack's delay is the dub delay, powered by `Dub Delay`", () {
      expect(fxModuleFor('Dub Delay', 'Dub Rack')!.name, 'Dub delay');
      expect(
        fxModulesOwning('Del Feedback', 'Dub Rack').map((m) => m.name),
        ['Dub delay'],
      );
      // The dub reverb no longer takes the delay's power key as a parameter.
      expect(fxModulesOwning('Dub Delay', 'Dub Rack'), isEmpty);
      expect(
        fxModulesOwning('Dub-Verb Dec', 'Dub Rack').map((m) => m.name),
        ['Dub reverb'],
      );
    });

    test('`Para EQ` powers the parametric EQ of the Dub and Lo-Fi racks', () {
      for (final family in ['Dub Rack', 'Lo-Fi Rack']) {
        expect(fxModuleFor('Para EQ', family)!.name, 'Parametric EQ');
        expect(
          fxModulesOwning('EQ Mid Q', family).map((m) => m.name),
          ['Parametric EQ'],
        );
      }
      expect(
        fxModulesOwning('EQ Mid Freq', 'Drum Rack').map((m) => m.name),
        ['Four-band EQ'],
      );
    });

    test("the Rhythmic Rack's EQ is the parametric EQ, though `EQ` powers "
        'it', () {
      // Its controls are the parametric EQ's without the Q, and none of them
      // is a four-band EQ's.
      expect(fxModuleFor('EQ', 'Rhythmic Rack')!.name, 'Parametric EQ');
      expect(
        fxModulesOwning('EQ Mid Gain', 'Rhythmic Rack').map((m) => m.name),
        ['Parametric EQ'],
      );
      expect(fxModuleFor('EQ', 'Drum Rack')!.name, 'Four-band EQ');
    });

    test('`Smart Tune` powers Smart Tune, and `Mode` is a parameter', () {
      expect(fxModuleFor('Smart Tune', 'Vocal Tuner Rack')!.name, 'Smart tune');
      expect(fxModuleFor('Mode', 'Vocal Tuner Rack'), isNull);
    });

    test(
      'Smart Tune and the Harmonizer belong to the Vocal Tuner Rack only',
      () {
        for (final family in kFxFamilySlugs.keys) {
          if (family == 'Vocal Tuner Rack') continue;
          expect(fxModulesOwning('Mode', family), isEmpty, reason: family);
          expect(
            fxModulesOwning('Voice 1 Vol', family),
            isEmpty,
            reason: family,
          );
          expect(fxModuleFor('Smart Tune', family), isNull, reason: family);
        }
      },
    );

    test('Smart Tune and the Harmonizer both read the shared Vocal Tuner '
        'parameters', () {
      for (final key in ['Mode', 'Auto Source', 'Key', 'Scale Type']) {
        expect(
          fxModulesOwning(key, 'Vocal Tuner Rack').map((m) => m.name),
          ['Harmonizer', 'Smart tune'],
          reason: key,
        );
      }
    });
  });

  group('every factory preset', () {
    // What each rack's schema implies, in the order a rack builds its
    // entries: the module table's order, because no source examined records
    // the order the Looper X runs them in (see kFxModules).
    const expected = <String, List<String>>{
      'Drum Rack': [
        'Compressor',
        'Four-band EQ',
        'Delay',
        'Reverb',
        'Transient',
      ],
      'Dub Rack': [
        'Compressor',
        'Parametric EQ',
        'Dub delay',
        'Ambience',
        'Dub reverb',
        'Doubler',
      ],
      "Ed's Rack": [
        'Amp',
        'Compressor',
        'Overdrive',
        'Four-band EQ',
        'Wah',
        'Chorus',
        'Octaver',
        'Delay',
        'Reverb',
      ],
      'Guitar Rack': [
        'Amp',
        'Overdrive',
        'Wah',
        'Modulation',
        'Whammy',
        'Delay',
        'Spring reverb',
      ],
      'Lo-Fi Rack': [
        'Distortion',
        'Parametric EQ',
        'Low-pass filter',
        'Delay',
        'Vinyl',
        'Degrade',
      ],
      'Rhythmic Rack': [
        'Parametric EQ',
        'Low-pass filter',
        'Delay',
        'Reverb',
        'Pumper',
        'Slicer',
      ],
      'Studio Rack': [
        'Compressor',
        'Distortion',
        'Four-band EQ',
        'Modulation',
        'Pitch shift',
        'Delay',
        'Reverb',
        'Doubler',
      ],
      'Vocal Rack': [
        'Compressor',
        'Four-band EQ',
        'Pitch shift',
        'Delay',
        'Reverb',
        'Doubler',
        'High-pass gate',
      ],
      'Vocal Tuner Rack': [
        'Compressor',
        'Four-band EQ',
        'Delay',
        'Reverb',
        'Doubler',
        'High-pass gate',
        'Harmonizer',
        'Smart tune',
      ],
    };

    test('builds the modules its rack schema implies, in rack order', () {
      expect(catalogue.families.map((f) => f.name), expected.keys);
      for (final family in catalogue.families) {
        for (final preset in family.presets) {
          expect(
            fxPresetModules(preset).map((m) => m.name),
            expected[family.name],
            reason: '${family.name} / ${preset.name}',
          );
        }
      }
    });

    test('gives each key to the modules it builds: one owner per key, two '
        'for a shared Vocal Tuner key, none for Master Vol', () {
      const shared = {'Mode', 'Auto Source', 'Key', 'Scale Type'};
      for (final preset in catalogue.presets) {
        final modules = fxPresetModules(preset);
        for (final key in preset.params.keys) {
          final owners = [
            for (final m in modules)
              if (m.owns(key) || m.poweredBy(key)) m.name,
          ];
          final reason = '${preset.family} / ${preset.name} / $key';
          if (key == 'Master Vol') {
            expect(owners, isEmpty, reason: reason);
          } else if (shared.contains(key)) {
            expect(owners, ['Harmonizer', 'Smart tune'], reason: reason);
          } else {
            expect(owners, hasLength(1), reason: reason);
          }
        }
      }
    });

    test('stores Master Vol on the Looper X 0.1 dB grid of -12 to +12 dB', () {
      // The binary registers Master Vol in every rack as -12..+12 dB, step
      // 0.1, through a linear mapper: dB = -12 + 24 * value.
      final above6 = <String>[];
      for (final preset in catalogue.presets) {
        final value = preset.params['Master Vol']!;
        final db = -12 + 24 * value;
        expect(
          (db * 10 - (db * 10).round()).abs(),
          lessThan(0.01),
          reason: '${preset.family} / ${preset.name}: $db dB',
        );
        if (db > 6) above6.add(preset.name);
      }
      expect(above6, hasLength(9));
      final atmos = catalogue
          .family('Guitar Rack')!
          .presets
          .firstWhere((p) => p.name == 'Rhythm Atmos');
      expect(-12 + 24 * atmos.params['Master Vol']!, closeTo(10.6, 0.01));
    });

    test('a Vocal Tuner preset with Smart Tune off still sets the shared '
        'keys the Harmonizer reads', () {
      final family = catalogue.family('Vocal Tuner Rack')!;
      final midi = family.presets.firstWhere((p) => p.name == 'Midi Harm Mid');
      final scale = family.presets.firstWhere(
        (p) => p.name == 'Scale Harm Hi Dry',
      );
      expect(midi.params['Smart Tune'], 0);
      expect(midi.params['Auto Source'], 1);
      expect(scale.params['Smart Tune'], 0);
      expect(scale.params['Mode'], 1);
      expect(scale.params['Key'], closeTo(3 / 11, 1e-6));
      expect(fxPresetModules(midi).map((m) => m.name), contains('Smart tune'));
    });
  });

  group('the add-an-effect rows', () {
    /// The keys each rack family gives [module], one set per distinct
    /// variant: two racks exposing the same keys are the same variant.
    Map<String, Set<String>> variants(FxModule module) {
      final byFamily = <String, Set<String>>{};
      for (final preset in catalogue.presets) {
        if (!fxPresetModules(preset).contains(module)) continue;
        byFamily.putIfAbsent(preset.family, () => {}).addAll([
          for (final key in preset.params.keys)
            if (module.owns(key) || module.poweredBy(key)) key,
        ]);
      }
      return byFamily;
    }

    test("are the pen's 26 rows, in the pen's order", () {
      expect(kFxAddableEffects.map((e) => e.label), [
        'Amp',
        'Chorus',
        'Compressor',
        'Degrade',
        'Delay',
        'Distortion',
        'Doubler',
        'Dub Delay',
        'Four-band EQ',
        'Harmonize',
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
        'Smart Tune',
        'Spring Reverb',
        'Transient',
        'Vinyl',
        'Wah',
        'Whammy',
      ]);
    });

    test('each names a module of the table and a rack that holds it', () {
      for (final row in kFxAddableEffects) {
        final module = fxModuleNamed(row.module);
        expect(module, isNotNull, reason: row.label);
        expect(variants(module!), contains(row.family), reason: row.label);
      }
    });

    test('the pedals with several variants are the ones the plan and the '
        'owner chose a default for', () {
      final several = [
        for (final row in kFxAddableEffects)
          if ({
                for (final keys in variants(fxModuleNamed(row.module)!).values)
                  (keys.toList()..sort()).join('|'),
              }.length >
              1)
            row.label,
      ];
      expect(several, [
        'Compressor',
        'Delay',
        'Distortion',
        'Doubler',
        'Four-band EQ',
        'Low-pass Filter',
        'Modulation',
        'Parametric EQ',
        'Reverb',
      ]);
    });

    test("the owner's five defaults expose the most controls of their "
        'pedal', () {
      for (final label in [
        'Compressor',
        'Distortion',
        'Doubler',
        'Low-pass Filter',
        'Modulation',
      ]) {
        final row = kFxAddableEffects.firstWhere((r) => r.label == label);
        final all = variants(fxModuleNamed(row.module)!);
        final chosen = all[row.family]!.length;
        for (final entry in all.entries) {
          if (entry.key == row.family) continue;
          expect(
            chosen,
            greaterThan(entry.value.length),
            reason: '$label: ${row.family} against ${entry.key}',
          );
        }
      }
    });

    test('the plan-named defaults are the variants it describes', () {
      FxModule module(String name) => fxModuleNamed(name)!;

      // Ed's four-band EQ: all fourteen controls and its power key.
      expect(variants(module('Four-band EQ'))["Ed's Rack"], hasLength(15));
      // The Dub Rack's parametric EQ, the same as the Lo-Fi Rack's.
      expect(
        variants(module('Parametric EQ'))['Dub Rack'],
        variants(module('Parametric EQ'))['Lo-Fi Rack'],
      );
      expect(
        variants(module('Parametric EQ'))['Dub Rack'],
        contains('EQ Mid Q'),
      );
      // The mode delay and the mode reverb with brightness.
      expect(variants(module('Delay'))["Ed's Rack"], {
        'Delay',
        'Del Feedback',
        'Del Mix',
        'Del Mode',
        'Del Time',
      });
      expect(variants(module('Reverb'))["Ed's Rack"], {
        'Reverb',
        'Rev Bright',
        'Rev Length',
        'Rev Mix',
        'Rev Mode',
      });
      expect(
        variants(module('Reverb'))['Vocal Rack'],
        variants(module('Reverb'))["Ed's Rack"],
      );
    });
  });
}
