import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/font_licenses.dart';
import 'package:segno/app/run_segno.dart';
import 'package:segno/visualizer/screen_link.dart';

/// The vendored native code's license files, as the engine registers them,
/// relative to the repository root (where `flutter test` runs).
const _engine = 'packages/segno_engine';
const _expected = {
  'clap': '$_engine/third_party/clap/LICENSE',
  'miniaudio': '$_engine/src/miniaudio/LICENSE',
  'signalsmith-dsp': '$_engine/third_party/signalsmith-stretch/dsp/LICENSE.txt',
  'signalsmith-stretch': '$_engine/third_party/signalsmith-stretch/LICENSE.txt',
  'vst3sdk': '$_engine/third_party/vst3sdk/base/LICENSE.txt',
};

List<String> _paragraphs(LicenseEntry entry) => [
  for (final p in entry.paragraphs) p.text,
];

/// Every package the registry lists.
Future<Set<String>> _registeredPackages() async => {
  await for (final entry in LicenseRegistry.licenses) ...entry.packages,
};

/// The app's asset bundle, except [missing], which loads as a missing asset
/// does.
class _BundleWithout extends CachingAssetBundle {
  new(this.missing);

  final String missing;

  @override
  Future<ByteData> load(String key) => key == missing
      ? Future.error(FlutterError('no $key'))
      : rootBundle.load(key);
}

/// Runs [body] with [FlutterError.onError] collecting what is reported.
Future<List<FlutterErrorDetails>> _reportedDuring(
  Future<void> Function() body,
) async {
  final reported = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = reported.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return reported;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The registry is a global that licenses ADD to.
  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

  testWidgets('runSegno registers the vendored native code and the bundled '
      'fonts before it routes a screen', (tester) async {
    // The readout screen is the branch that returns first: registering after
    // it would leave that screen, and a reordered main screen, without them.
    await runSegno(['${segnoScreenArgPrefix}readout']);

    expect(
      await tester.runAsync(_registeredPackages),
      containsAll([
        ..._expected.keys,
        ...bundledFontLicenses.map((entry) => entry.$1),
      ]),
    );
    await tester.pumpWidget(const SizedBox());
  });

  group('registerVendoredLicenses', () {
    test('lists every vendored native library, each with its license file '
        'verbatim', () async {
      registerVendoredLicenses();

      final byPackage = <String, LicenseEntry>{};
      await for (final entry in LicenseRegistry.licenses) {
        for (final package in entry.packages) {
          byPackage[package] = entry;
        }
      }

      expect(byPackage.keys, unorderedEquals(_expected.keys));
      for (final MapEntry(key: package, value: path) in _expected.entries) {
        final onDisk = LicenseEntryWithLineBreaks([
          package,
        ], File(path).readAsStringSync());
        expect(
          _paragraphs(byPackage[package]!),
          _paragraphs(onDisk),
          reason: '$package must show $path as it is',
        );
      }
      expect(
        _paragraphs(byPackage['signalsmith-stretch']!).join('\n'),
        contains('Geraint Luff / Signalsmith Audio Ltd.'),
      );
    });

    test('a license file that fails to load is reported and left out, and '
        'the rest still list', () async {
      registerVendoredLicenses(bundle: _BundleWithout(_expected['vst3sdk']!));

      late Set<String> packages;
      final reported = await _reportedDuring(() async {
        packages = await _registeredPackages();
      });

      expect(
        packages,
        unorderedEquals(_expected.keys.toSet()..remove('vst3sdk')),
      );
      expect(reported, hasLength(1));
      expect(reported.single.library, 'segno_engine');
    });

    test("miniaudio's LICENSE is the license block of the vendored header", () {
      final header = File('$_engine/src/miniaudio/miniaudio.h')
          .readAsStringSync();
      final license = File(_expected['miniaudio']!).readAsStringSync();
      expect(header, contains(license.trimRight()));
    });

    test('the one VST3 license shown stands for all three subtrees', () {
      final shown = File(_expected['vst3sdk']!).readAsStringSync();
      for (final subtree in ['pluginterfaces', 'public.sdk']) {
        expect(
          File('$_engine/third_party/vst3sdk/$subtree/LICENSE.txt')
              .readAsStringSync(),
          shown,
        );
      }
    });
  });

  group('registerFontLicenses', () {
    test(
      'lists every bundled font, each with its licence file verbatim',
      () async {
        registerFontLicenses();

        final byFont = <String, LicenseEntry>{};
        await for (final entry in LicenseRegistry.licenses) {
          for (final package in entry.packages) {
            byFont[package] = entry;
          }
        }

        expect(
          byFont.keys,
          unorderedEquals(bundledFontLicenses.map((entry) => entry.$1)),
        );
        for (final (font, path) in bundledFontLicenses) {
          expect(
            _paragraphs(byFont[font]!),
            _paragraphs(
              LicenseEntryWithLineBreaks([font], File(path).readAsStringSync()),
            ),
            reason: '$font must show $path as it is',
          );
        }
      },
    );

    test('a licence file that fails to load is reported and left out, and '
        'the other fonts still list', () async {
      final (missingFont, missingPath) = bundledFontLicenses.first;
      registerFontLicenses(bundle: _BundleWithout(missingPath));

      late Set<String> fonts;
      final reported = await _reportedDuring(() async {
        fonts = await _registeredPackages();
      });

      expect(
        fonts,
        unorderedEquals(
          bundledFontLicenses.map((entry) => entry.$1).toSet()
            ..remove(missingFont),
        ),
      );
      expect(reported, hasLength(1));
      expect(reported.single.library, 'segno');
    });

    test('every font in the pubspec has a licence, carrying its copyright '
        'line and its licence', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final families = RegExp(
        r'^    - family: (.+)$',
        multiLine: true,
      ).allMatches(pubspec).map((m) => m.group(1)!.trim()).toSet();
      expect(bundledFontLicenses.map((entry) => entry.$1).toSet(), families);
      for (final (font, path) in bundledFontLicenses) {
        final text = File(path).readAsStringSync();
        // The notice the licence asks every copy to carry: its copyright
        // line, which names the authors in each font's own words.
        expect(text, contains('Copyright'), reason: font);
        // Its own notice, not another font's copied over: no two bundled
        // typefaces carry the same licence text.
        expect(
          bundledFontLicenses
              .where((other) => other.$1 != font)
              .map((other) => File(other.$2).readAsStringSync()),
          isNot(contains(text)),
          reason: font,
        );
        expect(
          text,
          contains(
            font == 'Arimo'
                ? 'Apache License'
                : 'SIL OPEN FONT LICENSE Version 1.1',
          ),
          reason: font,
        );
      }
    });
  });
}
