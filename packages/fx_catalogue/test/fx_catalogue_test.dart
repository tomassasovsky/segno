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
}
