import 'dart:async';
import 'dart:io';

import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// `/proc/stat` text whose aggregate line has [busy] user jiffies and
/// [idle] idle jiffies.
String stat(int busy, int idle) => 'cpu  $busy 0 0 $idle 0 0 0 0 0 0\n';

void main() {
  group(CpuLoadRepository, () {
    test('reports the load between samples a second apart', () {
      fakeAsync((async) {
        final samples = [
          stat(0, 0),
          stat(25, 75),
          stat(75, 125),
          stat(175, 125),
        ];
        var reads = 0;
        final repository = CpuLoadRepository(
          readStat: () async => samples[reads++],
        );
        expect(repository.isSupported, isTrue);
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.flushMicrotasks();
        expect(loads, isEmpty, reason: 'one sample is not a load');
        async.elapse(const Duration(seconds: 3));
        expect(loads, [25, 50, 100]);
        expect(reads, 4);
        unawaited(subscription.cancel());
      });
    });

    test('repeats nothing while the figure holds', () {
      fakeAsync((async) {
        var busy = 0;
        var idle = 0;
        final repository = CpuLoadRepository(
          readStat: () async {
            final text = stat(busy, idle);
            busy += 10;
            idle += 90;
            return text;
          },
        );
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(seconds: 5));
        expect(loads, [10]);
        unawaited(subscription.cancel());
      });
    });

    test('stops reading once the listener cancels', () {
      fakeAsync((async) {
        var reads = 0;
        final repository = CpuLoadRepository(
          readStat: () async => stat(reads++, 100 * reads),
        );
        final subscription = repository.watch().listen((_) {});
        async.elapse(const Duration(seconds: 2));
        unawaited(subscription.cancel());
        final atCancel = reads;
        async.elapse(const Duration(seconds: 5));
        expect(reads, atCancel);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('skips a failed or unreadable sample', () {
      fakeAsync((async) {
        final samples = <String? Function()>[
          () => stat(0, 0),
          () => throw const FileSystemException('gone'),
          () => 'no cpu line',
          () => stat(50, 50),
        ];
        var reads = 0;
        final repository = CpuLoadRepository(
          readStat: () async => samples[reads++]()!,
        );
        final loads = <int>[];
        final subscription = repository.watch().listen(loads.add);
        async.elapse(const Duration(seconds: 3));
        expect(loads, [50]);
        unawaited(subscription.cancel());
      });
    });

    test('a sample arriving after cancel is dropped', () {
      fakeAsync((async) {
        var reads = 0;
        final repository = CpuLoadRepository(
          readStat: () => Future.delayed(const Duration(milliseconds: 500), () {
            reads++;
            return stat(10 * reads, 100 * reads);
          }),
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
      test('is unsupported without /proc/stat', () {
        final repository = CpuLoadRepository.system(
          path: '${Directory.systemTemp.path}/segno-no-such-stat',
        );
        expect(repository.isSupported, isFalse);
      });

      test('reads the file it is given', () async {
        final dir = Directory.systemTemp.createTempSync('cpu_load');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/stat')..writeAsStringSync(stat(0, 0));
        final repository = CpuLoadRepository.system(
          path: file.path,
        );
        expect(repository.isSupported, isTrue);
        expect(repository.interval, const Duration(seconds: 1));
      });
    });
  });
}
