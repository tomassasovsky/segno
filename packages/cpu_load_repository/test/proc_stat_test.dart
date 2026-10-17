import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:test/test.dart';

void main() {
  group('parseProcStat', () {
    test('sums the first eight fields and counts idle plus iowait as idle', () {
      // user nice system idle iowait irq softirq steal guest guest_nice
      const stat =
          'cpu  100 20 30 400 50 6 4 0 99 99\n'
          'cpu0 50 10 15 200 25 3 2 0 0 0\n'
          'intr 12345\n';
      expect(
        parseProcStat(stat),
        const CpuTimes(busy: 160, total: 610),
      );
    });

    test('reads a short line from an old kernel', () {
      expect(
        parseProcStat('cpu 10 0 10 80\n'),
        const CpuTimes(busy: 20, total: 100),
      );
    });

    test('is null without an aggregate line', () {
      expect(parseProcStat('cpu0 1 2 3 4\nintr 5\n'), isNull);
      expect(parseProcStat(''), isNull);
    });

    test('is null for a malformed aggregate line', () {
      expect(parseProcStat('cpu 1 2 x 4 5\n'), isNull);
      expect(parseProcStat('cpu 1 2 3\n'), isNull);
    });
  });

  group('loadPercent', () {
    test('is the busy share of the jiffies between two samples', () {
      expect(
        loadPercent(
          const CpuTimes(busy: 100, total: 1000),
          const CpuTimes(busy: 125, total: 1100),
        ),
        25,
      );
    });

    test('rounds to a whole percent', () {
      expect(
        loadPercent(
          const CpuTimes(busy: 0, total: 0),
          const CpuTimes(busy: 2, total: 3),
        ),
        67,
      );
    });

    test('is null when no time passed', () {
      const same = CpuTimes(busy: 5, total: 10);
      expect(loadPercent(same, same), isNull);
    });

    test('stays within 0..100 when a counter steps back', () {
      expect(
        loadPercent(
          const CpuTimes(busy: 50, total: 100),
          const CpuTimes(busy: 40, total: 200),
        ),
        0,
      );
      expect(
        loadPercent(
          const CpuTimes(busy: 0, total: 100),
          const CpuTimes(busy: 500, total: 200),
        ),
        100,
      );
    });
  });

  test('CpuTimes compares by value', () {
    const a = CpuTimes(busy: 1, total: 2);
    expect(a, const CpuTimes(busy: 1, total: 2));
    expect(a.hashCode, const CpuTimes(busy: 1, total: 2).hashCode);
    expect(a, isNot(const CpuTimes(busy: 1, total: 3)));
    expect(a.toString(), 'CpuTimes(busy: 1, total: 2)');
  });
}
