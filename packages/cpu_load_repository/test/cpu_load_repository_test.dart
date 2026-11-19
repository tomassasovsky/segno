import 'dart:async';
import 'dart:io';

import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// `/proc/stat` text whose aggregate line has [idle] idle ticks and busy
/// fields that say nothing true, the way the console's do (#1868).
String stat(int idle) => 'cpu  7 0 3 $idle 0 0 1 0 0 0\n';

/// `/proc/uptime` text for [hundredths] of a second since boot.
String uptime(int hundredths) =>
    '${(hundredths / 100).toStringAsFixed(2)} 0.00\n';

/// A [ProcReader] over [samples], one `(uptime, idle)` pair per sample, that
/// moves to the next sample once it has served both files, in either order.
/// [reads] counts the samples served.
class FakeProc {
  new(this.samples);

  final List<(int, int)> samples;
  int reads = 0;
  final _served = <String>{};

  Future<String> read(String name) async {
    final (time, idle) = samples[reads];
    _served.add(name);
    if (_served.containsAll(const ['stat', 'uptime'])) {
      _served.clear();
      reads++;
    }
    return name == 'stat' ? stat(idle) : uptime(time);
  }
}

void main() {
  group(CpuLoadRepository, () {
    test('reports the share of each second not idle on every core', () {
      fakeAsync((async) {
        final proc = FakeProc([(0, 0), (100, 300), (200, 500), (300, 500)]);
        final repository = CpuLoadRepository(read: proc.read, cores: 4);
        expect(repository.isSupported, isTrue);
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.flushMicrotasks();
        expect(loads, isEmpty, reason: 'one sample is not a load');
        async.elapse(const Duration(seconds: 3));
        expect(loads, [25, 50, 100]);
        expect(proc.reads, 4);
        unawaited(subscription.cancel());
      });
    });

    test('repeats nothing while the figure holds', () {
      fakeAsync((async) {
        final proc = FakeProc([for (var i = 0; i < 6; i++) (100 * i, 90 * i)]);
        final repository = CpuLoadRepository(read: proc.read, cores: 1);
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(seconds: 5));
        expect(loads, [10]);
        unawaited(subscription.cancel());
      });
    });

    test('shows nothing for a sample that spans a suspend', () {
      fakeAsync((async) {
        // A minute of uptime between two one-second samples, with no idle
        // time: the machine was suspended.
        final proc = FakeProc([(0, 0), (6000, 0), (6100, 300)]);
        final repository = CpuLoadRepository(read: proc.read, cores: 4);
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(seconds: 2));
        expect(loads, [25]);
        unawaited(subscription.cancel());
      });
    });

    test('stops reading once the listener cancels', () {
      fakeAsync((async) {
        final proc = FakeProc([for (var i = 0; i < 10; i++) (100 * i, 0)]);
        final repository = CpuLoadRepository(read: proc.read, cores: 4);
        final subscription = repository.watch().listen((_) {});
        async.elapse(const Duration(seconds: 2));
        unawaited(subscription.cancel());
        final atCancel = proc.reads;
        async.elapse(const Duration(seconds: 5));
        expect(proc.reads, atCancel);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('skips a failed or unreadable sample', () {
      fakeAsync((async) {
        final answers = <Future<String> Function(String)>[
          (name) async => name == 'stat' ? stat(0) : uptime(0),
          (name) async => name == 'stat'
              ? throw const FileSystemException('gone')
              : uptime(100),
          (name) async => name == 'stat' ? 'no cpu line' : uptime(200),
          (name) async => name == 'stat' ? stat(100) : uptime(300),
        ];
        var sample = 0;
        final repository = CpuLoadRepository(
          read: (name) {
            final answer = answers[sample](name);
            if (name == 'uptime') sample++;
            return answer;
          },
          cores: 1,
        );
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(seconds: 3));
        expect(loads, [67]);
        unawaited(subscription.cancel());
      });
    });

    test('a sample arriving after cancel is dropped', () {
      fakeAsync((async) {
        var reads = 0;
        final repository = CpuLoadRepository(
          read: (name) => Future.delayed(const Duration(milliseconds: 500), () {
            if (name == 'stat') return stat(10 * reads);
            reads++;
            return uptime(100 * reads);
          }),
          cores: 1,
        );
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(milliseconds: 1200));
        unawaited(subscription.cancel());
        async.elapse(const Duration(seconds: 1));
        expect(loads, isEmpty);
      });
    });

    test('an unsupported build reports nothing', () async {
      const repository = CpuLoadRepository.unsupported();
      expect(repository.isSupported, isFalse);
      expect(await repository.watch().toList(), isEmpty);
    });

    group('system', () {
      late Directory proc;

      setUp(() {
        proc = Directory.systemTemp.createTempSync('cpu_load');
        addTearDown(() => proc.deleteSync(recursive: true));
      });

      test('is unsupported without /proc/stat', () {
        File('${proc.path}/uptime').writeAsStringSync(uptime(0));
        expect(CpuLoadRepository.system(proc: proc.path).isSupported, isFalse);
      });

      test('is unsupported without /proc/uptime', () {
        File('${proc.path}/stat').writeAsStringSync(stat(0));
        expect(CpuLoadRepository.system(proc: proc.path).isSupported, isFalse);
      });

      test('reads the directory it is given, over the online cores', () {
        File('${proc.path}/stat').writeAsStringSync(stat(0));
        File('${proc.path}/uptime').writeAsStringSync(uptime(0));
        final repository = CpuLoadRepository.system(proc: proc.path);
        expect(repository.isSupported, isTrue);
        expect(repository.cores, Platform.numberOfProcessors);
        expect(repository.interval, const Duration(seconds: 1));
      });

      test(
        'samples both files from the directory as soon as it is watched',
        () async {
          File('${proc.path}/stat').writeAsStringSync(stat(0));
          File('${proc.path}/uptime').writeAsStringSync(uptime(0));
          final subscription = CpuLoadRepository.system(proc: proc.path)
              .watch()
              .listen((_) {});
          // The first sample reads at once; take both files away so a later
          // read would throw and be skipped rather than pass by luck.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          File('${proc.path}/stat').deleteSync();
          File('${proc.path}/uptime').deleteSync();
          await subscription.cancel();
        },
      );
    });
  });
}
