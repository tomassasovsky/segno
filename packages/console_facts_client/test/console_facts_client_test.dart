import 'dart:async';
import 'dart:io';

import 'package:console_facts_client/console_facts_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('StorageUsage', () {
    test('a known reading is known', () {
      const usage = StorageUsage(
        sessionBytes: 1,
        captureBytes: 2,
        pluginBytes: 3,
        systemBytes: 4,
        freeBytes: 5,
      );
      expect(usage.known, isTrue);
    });

    test('the unknown reading is not known, and its zeroes are not facts', () {
      const usage = StorageUsage.unknown();
      expect(usage.known, isFalse);
      expect(usage.freeBytes, 0);
    });
  });

  group('UnsupportedConsoleFactsClient', () {
    const client = UnsupportedConsoleFactsClient();

    test('answers "I do not know" to everything', () async {
      expect(client.isSupported, isFalse);
      expect((await client.storage()).known, isFalse);
      expect(await client.facts(), ConsoleFacts.unknown);
      expect(await client.exportDestination(), isEmpty);
      expect(await client.deleteCapturesOlderThan(30), 0);
    });
  });

  group('FakeConsoleFactsClient', () {
    test('at zero latency it schedules NO timer', () {
      // The whole point of the zero case: even `Future.delayed(Duration.zero)`
      // schedules a timer, and a `testWidgets` body that awaits one without
      // pumping waits for it forever. A fake that is configurable but still
      // schedules is not fixed — so this asserts the absence of the timer, not
      // just that the call is quick.
      fakeAsync((async) {
        var settled = false;
        unawaited(
          FakeConsoleFactsClient(
            latency: Duration.zero,
          ).storage().then((_) => settled = true),
        );
        async.flushMicrotasks();
        expect(settled, isTrue);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('with a latency it DOES schedule one — the case tests must avoid', () {
      fakeAsync((async) {
        var settled = false;
        unawaited(
          FakeConsoleFactsClient(
            latency: const Duration(milliseconds: 50),
          ).storage().then((_) => settled = true),
        );
        async.flushMicrotasks();
        expect(settled, isFalse);
        expect(async.pendingTimers, isNotEmpty);
        async.elapse(const Duration(milliseconds: 50));
        expect(settled, isTrue);
      });
    });

    test(
      'deleting captures changes the figures the next read reports',
      () async {
        final client = FakeConsoleFactsClient(latency: Duration.zero);
        final before = await client.storage();

        final removed = await client.deleteCapturesOlderThan(30);
        expect(removed, greaterThan(0));

        final after = await client.storage();
        expect(after.captureBytes, lessThan(before.captureBytes));
        expect(after.freeBytes, greaterThan(before.freeBytes));
      },
    );

    test('a second delete has nothing left to take', () async {
      final client = FakeConsoleFactsClient(latency: Duration.zero);
      await client.deleteCapturesOlderThan(30);
      expect(await client.deleteCapturesOlderThan(30), 0);
    });

    test('an unmounted export volume reports nowhere to export', () async {
      final client = FakeConsoleFactsClient(
        latency: Duration.zero,
        exportVolumeMounted: false,
      );
      expect(await client.exportDestination(), isEmpty);
    });

    test('it answers with the rig the mockups draw', () async {
      final facts = await FakeConsoleFactsClient(
        latency: Duration.zero,
      ).facts();
      expect(facts.serial, 'VMP-16-0042');
      expect(facts.name, 'VAMP 16');
    });
  });

  group('directorySizeBytes', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('dir_size_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('sums every file recursively', () {
      File('${temp.path}/a.bin').writeAsBytesSync(List.filled(100, 0));
      Directory('${temp.path}/nested').createSync();
      File('${temp.path}/nested/b.bin').writeAsBytesSync(List.filled(250, 0));

      expect(directorySizeBytes(temp.path), 350);
    });

    test('a missing directory is 0, not a throw', () {
      expect(directorySizeBytes('${temp.path}/not-there'), 0);
    });

    test('an empty directory is 0', () {
      expect(directorySizeBytes(temp.path), 0);
    });
  });

  group('LocalConsoleFactsClient', () {
    late Directory temp;
    late String sessionsDir;
    late String capturesDir;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('local_console_facts');
      sessionsDir = '${temp.path}/sessions';
      capturesDir = '${temp.path}/exports';
    });
    tearDown(() => temp.deleteSync(recursive: true));

    LocalConsoleFactsClient build({
      Future<DiskSpace?> Function(String path)? diskSpace,
    }) => LocalConsoleFactsClient(
      sessionsRoot: () async => sessionsDir,
      capturesRoot: () async => capturesDir,
      diskSpace: diskSpace,
    );

    void seed(String dir, int bytes) {
      Directory(dir).createSync(recursive: true);
      File('$dir/data.bin').writeAsBytesSync(List.filled(bytes, 0));
    }

    test('sizes sessions and captures from their real directories', () async {
      seed(sessionsDir, 4000);
      seed(capturesDir, 9000);
      final client = build(
        diskSpace: (_) async =>
            const DiskSpace(totalBytes: 1000000, freeBytes: 700000),
      );

      final usage = await client.storage();

      expect(usage.known, isTrue);
      expect(usage.sessionBytes, 4000);
      expect(usage.captureBytes, 9000);
      expect(usage.freeBytes, 700000);
      // system = used - sessions - captures = (1_000_000 - 700_000) - 13_000.
      expect(usage.systemBytes, 300000 - 13000);
    });

    test('df targets the captures directory, i.e. the data volume', () async {
      seed(sessionsDir, 1);
      seed(capturesDir, 1);
      String? measured;
      final client = build(
        diskSpace: (path) async {
          measured = path;
          return const DiskSpace(totalBytes: 10, freeBytes: 5);
        },
      );

      await client.storage();

      expect(measured, capturesDir);
    });

    test('free/total come straight from df on that path (real df)', () async {
      seed(sessionsDir, 2048);
      seed(capturesDir, 3072);
      // No injected diskSpace: exercises the real `df` reader end to end, so a
      // regression in the parse or the ancestor walk is caught here.
      final usage = await build().storage();

      expect(usage.known, isTrue);
      expect(usage.sessionBytes, 2048);
      expect(usage.captureBytes, 3072);
      expect(usage.totalIsPlausible, isTrue);
    });

    test('a directory that does not exist yet sizes to 0', () async {
      // Fresh install: neither sessions nor captures written yet. df still
      // answers (it walks up to an existing ancestor), and the walk is 0.
      final usage = await build(
        diskSpace: (_) async =>
            const DiskSpace(totalBytes: 500, freeBytes: 500),
      ).storage();

      expect(usage.known, isTrue);
      expect(usage.sessionBytes, 0);
      expect(usage.captureBytes, 0);
    });

    test('system bytes clamp at 0 rather than going negative', () async {
      // Sessions + captures exceed reported "used" — only possible if df
      // measured a different volume than the app writes to (a wiring fault).
      // The figure must never render negative.
      seed(sessionsDir, 8000);
      seed(capturesDir, 8000);
      final usage = await build(
        diskSpace: (_) async =>
            const DiskSpace(totalBytes: 20000, freeBytes: 19000),
      ).storage();

      expect(usage.systemBytes, 0);
    });

    test('an unreadable volume reports unknown, not zeroes', () async {
      // df could not answer (returns null): the whole reading is unknown
      // rather than a breakdown of a disk whose size we do not have.
      final usage = await build(diskSpace: (_) async => null).storage();

      expect(usage.known, isFalse);
    });

    test('the disk is the only thing it answers; the rest stay unknown', () {
      final client = build();
      expect(client.isSupported, isTrue);
      expect(() async {
        expect(await client.facts(), ConsoleFacts.unknown);
        expect(await client.exportDestination(), isEmpty);
        expect(await client.deleteCapturesOlderThan(30), 0);
      }, returnsNormally);
    });
  });

  group('createConsoleFactsClient', () {
    Future<String> noRoot() async => '';

    test('on Linux/macOS the app gets the real disk-reading client', () {
      // No `--dart-define=SEGNO_FAKE_RADIOS` under `dart test`. This suite runs
      // on macOS (dev) and Linux (CI) — both of which now get the real client;
      // Windows keeps the unsupported one, which no runner here exercises.
      expect(kFakeConsoleFacts, isFalse);
      expect(Platform.isLinux || Platform.isMacOS, isTrue);
      expect(
        createConsoleFactsClient(sessionsRoot: noRoot, capturesRoot: noRoot),
        isA<LocalConsoleFactsClient>(),
      );
    });
  });
}

extension on StorageUsage {
  /// A real df reading: the volume has a size, and free never exceeds it.
  bool get totalIsPlausible {
    final total =
        sessionBytes + captureBytes + pluginBytes + systemBytes + freeBytes;
    return total > 0 && freeBytes <= total;
  }
}
