import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:test/test.dart';

void main() {
  group('parseCpuSample', () {
    test('reads idle plus iowait and the uptime in hundredths', () {
      // user nice system idle iowait irq softirq steal guest guest_nice
      const stat =
          'cpu  100 20 30 400 50 6 4 0 99 99\n'
          'cpu0 50 10 15 200 25 3 2 0 0 0\n'
          'intr 12345\n';
      expect(
        parseCpuSample(stat: stat, uptime: '23234.56 81020.88\n'),
        const CpuSample(uptime: 2323456, idle: 450),
      );
    });

    test('reads a line without iowait from an old kernel', () {
      expect(
        parseCpuSample(stat: 'cpu 10 0 10 80\n', uptime: '1.00 2.00'),
        const CpuSample(uptime: 100, idle: 80),
      );
    });

    test('ignores the busy fields', () {
      const uptime = '10.00 30.00';
      expect(
        parseCpuSample(stat: 'cpu  1 2 3 400 5 6 7 8\n', uptime: uptime),
        parseCpuSample(
          stat: 'cpu  900 900 900 400 5 900 900 0\n',
          uptime: uptime,
        ),
      );
    });

    test('is null without an aggregate line', () {
      expect(
        parseCpuSample(stat: 'cpu0 1 2 3 4\nintr 5\n', uptime: '1.0'),
        isNull,
      );
      expect(parseCpuSample(stat: '', uptime: '1.0'), isNull);
    });

    test('is null for a malformed aggregate line', () {
      expect(parseCpuSample(stat: 'cpu 1 2 x 4 5\n', uptime: '1.0'), isNull);
      expect(parseCpuSample(stat: 'cpu 1 2 3\n', uptime: '1.0'), isNull);
    });

    test('is null without a readable uptime', () {
      const stat = 'cpu 1 2 3 4 5\n';
      expect(parseCpuSample(stat: stat, uptime: ''), isNull);
      expect(parseCpuSample(stat: stat, uptime: 'up 3 days'), isNull);
    });
  });

  group('loadPercent', () {
    test('is the share of the elapsed time on every core not spent idle', () {
      // One second on four cores is 400 hundredths; 300 of them idle.
      expect(
        loadPercent(
          const CpuSample(uptime: 1000, idle: 2000),
          const CpuSample(uptime: 1100, idle: 2300),
          cores: 4,
        ),
        25,
      );
    });

    test('reads the console at idle as its steady load (#1868)', () {
      // Measured: one second on the console's four cores with 361 of the
      // 400 hundredths idle, while the busy fields of /proc/stat credited
      // only 1% for the same second.
      expect(
        loadPercent(
          const CpuSample(uptime: 2323456, idle: 7965432),
          const CpuSample(uptime: 2323556, idle: 7965793),
          cores: 4,
        ),
        10,
      );
    });

    test('rounds to a whole percent', () {
      expect(
        loadPercent(
          const CpuSample(uptime: 0, idle: 0),
          const CpuSample(uptime: 3, idle: 1),
          cores: 1,
        ),
        67,
      );
    });

    test('is null when no time passed', () {
      const same = CpuSample(uptime: 5, idle: 10);
      expect(loadPercent(same, same, cores: 4), isNull);
      expect(
        loadPercent(
          const CpuSample(uptime: 10, idle: 0),
          const CpuSample(uptime: 9, idle: 0),
          cores: 4,
        ),
        isNull,
      );
    });

    test(
      'stays within 0..100 when the idle count runs ahead or steps back',
      () {
        expect(
          loadPercent(
            const CpuSample(uptime: 0, idle: 0),
            const CpuSample(uptime: 100, idle: 450),
            cores: 4,
          ),
          0,
        );
        expect(
          loadPercent(
            const CpuSample(uptime: 0, idle: 50),
            const CpuSample(uptime: 100, idle: 40),
            cores: 4,
          ),
          100,
        );
      },
    );
  });

  test('CpuSample compares by value', () {
    const a = CpuSample(uptime: 1, idle: 2);
    expect(a, const CpuSample(uptime: 1, idle: 2));
    expect(a.hashCode, const CpuSample(uptime: 1, idle: 2).hashCode);
    expect(a, isNot(const CpuSample(uptime: 1, idle: 3)));
    expect(a.toString(), 'CpuSample(uptime: 1, idle: 2)');
  });
}
