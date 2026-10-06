import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

/// The vendored native code's license files, as the engine registers them,
/// relative to the repository root (where `flutter test` runs).
const _engine = 'packages/segno_engine';
const _expected = {
  'clap': '$_engine/third_party/clap/LICENSE',
  'miniaudio': '$_engine/src/miniaudio/LICENSE',
  'rnnoise': '$_engine/third_party/rnnoise/COPYING',
  'signalsmith-dsp': '$_engine/third_party/signalsmith-stretch/dsp/LICENSE.txt',
  'signalsmith-stretch': '$_engine/third_party/signalsmith-stretch/LICENSE.txt',
  'vst3sdk': '$_engine/third_party/vst3sdk/base/LICENSE.txt',
};

List<String> _paragraphs(LicenseEntry entry) => [
  for (final p in entry.paragraphs) p.text,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The registry is a global that licenses ADD to.
  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

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
        final onDisk = LicenseEntryWithLineBreaks(
          [package],
          File(path).readAsStringSync(),
        );
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

    test("miniaudio's LICENSE is the license block of the vendored header", () {
      final header = File(
        '$_engine/src/miniaudio/miniaudio.h',
      ).readAsStringSync();
      final license = File(_expected['miniaudio']!).readAsStringSync();
      expect(header, contains(license.trimRight()));
    });

    test('the one VST3 license shown stands for all three subtrees', () {
      final shown = File(_expected['vst3sdk']!).readAsStringSync();
      for (final subtree in ['pluginterfaces', 'public.sdk']) {
        expect(
          File(
            '$_engine/third_party/vst3sdk/$subtree/LICENSE.txt',
          ).readAsStringSync(),
          shown,
        );
      }
    });
  });
}
