import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('InputConditioningParam.code', () {
    test('maps each value to its native le_cond_param code', () {
      // These codes are the ABI contract with the C `le_cond_param` enum in
      // segno_engine_api.h. A reorder on either side that this test does not
      // also update sends the wrong param to the audio thread silently.
      expect(InputConditioningParam.hpfHz.code, 0);
      expect(InputConditioningParam.humHz.code, 1);
      expect(InputConditioningParam.humHarmonics.code, 2);
      expect(InputConditioningParam.expThresholdDb.code, 3);
      expect(InputConditioningParam.expRatio.code, 4);
      expect(InputConditioningParam.expReleaseMs.code, 5);
    });
  });

  group('InputConditioningParam.fromCode', () {
    test('round-trips every value through its code', () {
      for (final param in InputConditioningParam.values) {
        expect(InputConditioningParam.fromCode(param.code), param);
      }
    });

    test('maps unknown codes to hpfHz', () {
      expect(InputConditioningParam.fromCode(6), InputConditioningParam.hpfHz);
      expect(InputConditioningParam.fromCode(-1), InputConditioningParam.hpfHz);
      expect(InputConditioningParam.fromCode(99), InputConditioningParam.hpfHz);
    });
  });
}
