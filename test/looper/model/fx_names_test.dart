import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('a single effect is named by its kind, localized', () {
      final es = lookupAppLocalizations(const Locale('es'));
      expect(
        fxBlockName(es, BuiltInEffect(type: TrackEffectType.distortion)),
        es.effectTypeLabel(TrackEffectType.distortion),
      );
    });

    test('a plugin is named by its module, its name, its id, then a generic '
        'label', () {
      const ref = PluginRef(format: PluginFormat.vst3, id: 'abc');
      expect(
        fxBlockName(
          l10n,
          const PluginEffect(ref: ref, name: 'Comp', module: 'Delay'),
        ),
        'Delay',
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
