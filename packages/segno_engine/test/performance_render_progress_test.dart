import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group(PerformanceRenderProgress, () {
    test('failed takes part in value equality', () {
      const ok = PerformanceRenderProgress.empty;
      const failed = PerformanceRenderProgress(
        done: true,
        progressPercent: 100,
        failed: true,
      );
      expect(ok.failed, isFalse);
      expect(failed, isNot(ok));
      expect(failed.hashCode, isNot(ok.hashCode));
      expect(failed.toString(), contains('failed: true'));
    });
  });
}
