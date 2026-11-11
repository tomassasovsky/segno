import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_names.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('fxBlockName', () {
    test('a rack pedal is named by its catalogue module, not the kind it is '
        'built on (#1750)', () {
      expect(
        fxBlockName(
          l10n,
          BuiltInEffect(type: TrackEffectType.overdrive, module: 'Distortion'),
        ),
        'Distortion',
      );
      expect(
        fxBlockName(
          l10n,
          BuiltInEffect(type: TrackEffectType.ampCab, module: 'Distortion'),
        ),
        'Distortion',
      );
      expect(
        fxBlockName(
          l10n,
          BuiltInEffect(type: TrackEffectType.octaver, module: 'Pitch shift'),
        ),
        'Pitch shift',
      );
    });

    test('every catalogue module has a name in each locale (#1752)', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        for (final module in kFxModules) {
          final label = l.fxModuleLabel(module.name);
          expect(label, isNotNull, reason: '$locale ${module.name}');
          expect(label, isNotEmpty, reason: '$locale ${module.name}');
        }
      }
    });

    test('a rack pedal reads in the locale, and as the add-an-effect row '
        'that adds it (#1752)', () {
      final es = lookupAppLocalizations(const Locale('es'));
      final distort = BuiltInEffect(
        type: TrackEffectType.overdrive,
        module: 'Distortion',
      );
      expect(fxBlockName(es, distort), 'Distorsión');
      expect(
        fxBlockName(
          es,
          BuiltInEffect(type: TrackEffectType.octaver, module: 'Pitch shift'),
        ),
        'Cambio de tono',
      );
      expect(
        fxBlockName(
          l10n,
          BuiltInEffect(type: TrackEffectType.lpf, module: 'Low-pass filter'),
        ),
        'Low-pass filter',
      );
    });

    test('a module the catalogue no longer has keeps its stored name, so '
        "it never takes another pedal's", () {
      final es = lookupAppLocalizations(const Locale('es'));
      expect(
        fxBlockName(
          es,
          BuiltInEffect(type: TrackEffectType.overdrive, module: 'Distort 2'),
        ),
        'Distort 2',
      );
      expect(
        fxBlockName(
          es,
          BuiltInEffect(type: TrackEffectType.none, module: 'Harmoniser'),
        ),
        'Harmoniser',
      );
    });

    test('a single effect is named by its kind, localized', () {
      final es = lookupAppLocalizations(const Locale('es'));
      expect(
        fxBlockName(es, BuiltInEffect(type: TrackEffectType.distortion)),
        es.effectTypeLabel(TrackEffectType.distortion),
      );
    });

    test('a plugin is named as itself, even in a rack: its name, its id, '
        'then a generic label', () {
      const ref = PluginRef(format: PluginFormat.vst3, id: 'abc');
      expect(
        fxBlockName(
          l10n,
          const PluginEffect(ref: ref, name: 'Comp', module: 'Delay'),
        ),
        'Comp',
      );
      expect(
        fxBlockName(l10n, const PluginEffect(ref: ref, name: 'Comp')),
        'Comp',
      );
      expect(fxBlockName(l10n, const PluginEffect(ref: ref)), 'abc');
      expect(
        fxBlockName(
          l10n,
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: ''),
          ),
        ),
        l10n.signalPluginUnknownName,
      );
    });
  });
}
