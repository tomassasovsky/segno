import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('SynthParamInfo.valueAt', () {
    const decay = SynthParamInfo(
      key: 'decay',
      unit: SynthParamUnit.seconds,
      atMin: 0.08,
      atMax: 2.48,
      exponential: false,
    );
    const cutoff = SynthParamInfo(
      key: 'cutoff',
      unit: SynthParamUnit.hertz,
      atMin: 180,
      atMax: 12600,
      exponential: true,
    );

    test('maps linearly', () {
      expect(decay.valueAt(0), closeTo(0.08, 1e-12));
      expect(decay.valueAt(50), closeTo(1.28, 1e-12));
      expect(decay.valueAt(100), closeTo(2.48, 1e-12));
    });

    test('maps exponentially', () {
      expect(cutoff.valueAt(0), closeTo(180, 1e-9));
      // 180 * 70^0.5
      expect(cutoff.valueAt(50), closeTo(1505.98, 0.01));
      expect(cutoff.valueAt(100), closeTo(12600, 1e-6));
    });

    test('clamps the setting and reads NaN as 0', () {
      expect(decay.valueAt(-5), decay.valueAt(0));
      expect(decay.valueAt(250), decay.valueAt(100));
      expect(decay.valueAt(double.nan), decay.valueAt(0));
    });
  });

  group('SynthCatalogue', () {
    const pct = SynthParamInfo(
      key: 'tone',
      unit: SynthParamUnit.percent,
      atMin: 0,
      atMax: 100,
      exponential: false,
    );
    const catalogue = SynthCatalogue(
      patches: [
        SynthPatch(
          index: 0,
          id: 'piano',
          family: SynthFamily.keys,
          defaults: [1, 2, 3],
        ),
        SynthPatch(
          index: 1,
          id: 'synth-bass',
          family: SynthFamily.bass,
          defaults: [4, 5, 6],
        ),
        SynthPatch(
          index: 2,
          id: 'drums',
          family: SynthFamily.drums,
          defaults: [7, 8, 9],
        ),
      ],
      params: {
        SynthFamily.keys: [pct, pct, pct],
      },
    );

    test('looks patches up by id and index', () {
      expect(catalogue.byId('synth-bass')?.index, 1);
      expect(catalogue.byId('kazoo'), isNull);
      expect(catalogue.byIndex(2)?.family, SynthFamily.drums);
      expect(catalogue.byIndex(-1), isNull);
      expect(catalogue.byIndex(3), isNull);
      expect(catalogue.paramsOf(SynthFamily.keys), hasLength(3));
      expect(catalogue.paramsOf(SynthFamily.bass), isEmpty);
    });

    test('compares by value', () {
      final copy = SynthCatalogue(
        patches: [...catalogue.patches],
        params: {...catalogue.params},
      );
      expect(copy, catalogue);
      expect(copy.hashCode, catalogue.hashCode);
      expect(SynthCatalogue.empty, isNot(catalogue));
    });

    test('maps native family and unit codes', () {
      expect(SynthFamily.fromCode(6), SynthFamily.percussion);
      expect(SynthFamily.fromCode(7), isNull);
      expect(SynthParamUnit.fromCode(2), SynthParamUnit.hertz);
      expect(SynthParamUnit.fromCode(-1), isNull);
    });
  });
}
