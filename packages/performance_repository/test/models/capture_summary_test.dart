import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

void main() {
  const master = CapturePart(
    stream: 0,
    index: 1,
    file: 'master-001.wav',
    frames: 48000,
    bytes: 384084,
  );
  const input = CapturePart(
    stream: 1,
    index: 1,
    file: 'input-0-001.wav',
    frames: 48000,
    bytes: 384084,
  );

  CaptureSummary summary({
    List<CapturePart> parts = const [master, input],
    int sampleRate = 48000,
    bool recovered = false,
  }) => CaptureSummary(
    path: '/exports/take',
    name: 'take',
    startedAt: DateTime(2026, 10, 6, 20, 15),
    durationFrames: 72000,
    sampleRate: sampleRate,
    recovered: recovered,
    parts: parts,
  );

  group('CapturePart', () {
    test('is a value', () {
      const same = CapturePart(
        stream: 0,
        index: 1,
        file: 'master-001.wav',
        frames: 48000,
        bytes: 384084,
      );
      expect(master, same);
      expect(master.hashCode, same.hashCode);
      expect(master, isNot(input));
      expect(master.isMaster, isTrue);
      expect(input.isMaster, isFalse);
      expect('$master', contains('master-001.wav'));
    });
  });

  group('CaptureSummary', () {
    test('is a value, parts included', () {
      expect(summary(), summary());
      expect(summary().hashCode, summary().hashCode);
      expect(summary(), isNot(summary(parts: const [master])));
      expect(summary(), isNot(summary(parts: const [input, master])));
      expect(summary(), isNot(summary(recovered: true)));
      expect('${summary()}', contains('take'));
    });

    test("measures the main output's length, and nothing without a rate", () {
      expect(summary().duration, const Duration(milliseconds: 1500));
      expect(summary(sampleRate: 0).duration, Duration.zero);
      expect(summary().masterParts, [master]);
    });
  });

  test('PerformanceCaptureBusy says why', () {
    expect('${const PerformanceCaptureBusy()}', contains('recorded'));
  });
}
