import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

void main() {
  group('performanceSlug', () {
    test('folds a timestamp into perf-YYYYMMDD-HHMMSS', () {
      expect(
        performanceSlug(DateTime(2026, 7, 6, 14, 30, 15)),
        'perf-20260706-143015',
      );
    });

    test('pads single-digit month/day/hour/minute/second', () {
      expect(
        performanceSlug(DateTime(2026, 1, 2, 3, 4, 5)),
        'perf-20260102-030405',
      );
    });
  });

  group('performanceCaptureSlug', () {
    test('keeps a clean name unchanged (idempotent for an existing slug)', () {
      expect(performanceCaptureSlug('My Take'), 'My Take');
      expect(
        performanceCaptureSlug(performanceCaptureSlug('My Take')!),
        'My Take',
      );
      expect(performanceCaptureSlug('take-2_final'), 'take-2_final');
    });

    test('trims and collapses internal whitespace', () {
      expect(performanceCaptureSlug('  spaced   out  '), 'spaced out');
    });

    test('turns disallowed characters into folded spaces', () {
      expect(performanceCaptureSlug('a/b:c'), 'a b c');
      expect(performanceCaptureSlug('Take #1 (loud)'), 'Take 1 loud');
    });

    test('two distinct inputs can fold to the same slug', () {
      expect(
        performanceCaptureSlug('My Take!'),
        performanceCaptureSlug('My Take'),
      );
      expect(performanceCaptureSlug('My Take!'), 'My Take');
    });

    test('rejects names that sanitize to nothing', () {
      expect(performanceCaptureSlug(''), isNull);
      expect(performanceCaptureSlug('   '), isNull);
      expect(performanceCaptureSlug('!!!'), isNull);
      expect(performanceCaptureSlug(r'/\:*'), isNull);
    });

    test(
      'rejects the reserved recovered-area name, case-insensitively and '
      'after folding — a take named onto it would BE the salvage area '
      '(#679 r5)',
      () {
        expect(performanceCaptureSlug(reservedRecoveredDirName), isNull);
        expect(performanceCaptureSlug('recovered'), isNull);
        expect(performanceCaptureSlug('Recovered'), isNull);
        expect(performanceCaptureSlug('RECOVERED'), isNull);
        expect(performanceCaptureSlug('  recovered  '), isNull);
        expect(performanceCaptureSlug('recovered!'), isNull);
        // Names merely CONTAINING the word stay perfectly nameable.
        expect(performanceCaptureSlug('recovered take'), 'recovered take');
        expect(performanceCaptureSlug('my recovered'), 'my recovered');
      },
    );
  });

  group('performanceSlugTime', () {
    test('reads the local time a slug was folded from, with or without its '
        'same-second disambiguator', () {
      final time = DateTime(2026, 10, 6, 20, 15, 9);
      expect(performanceSlugTime(performanceSlug(time)), time);
      expect(performanceSlugTime('${performanceSlug(time)}-2'), time);
    });

    test('is null for a renamed take and for a slug naming no real time', () {
      expect(performanceSlugTime('Evening loop'), isNull);
      expect(performanceSlugTime('perf-20261306-201509'), isNull);
      expect(performanceSlugTime('perf-20261006-246000'), isNull);
      expect(performanceSlugTime('perf-2026106-201509'), isNull);
    });
  });
}
