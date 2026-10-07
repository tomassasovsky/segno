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
      expect(await client.retiredBluetoothPairings(), 0);
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
      diskSpace:
          diskSpace ??
          (_) async => const DiskSpace(totalBytes: 1 << 40, freeBytes: 1 << 39),
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

    test(
      'the reading targets the captures directory, i.e. the data volume',
      () async {
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
      },
    );

    test('a directory that does not exist yet sizes to 0, and the reader is '
        'handed the nearest EXISTING ancestor', () async {
      // Fresh install: neither sessions nor captures written yet. A statvfs on
      // a missing path fails, so the client walks up to an ancestor that is
      // there (the temp root here) before asking; the walk itself is 0.
      String? measured;
      final usage = await build(
        diskSpace: (path) async {
          measured = path;
          return const DiskSpace(totalBytes: 500, freeBytes: 500);
        },
      ).storage();

      expect(usage.known, isTrue);
      expect(usage.sessionBytes, 0);
      expect(usage.captureBytes, 0);
      expect(measured, temp.path);
      expect(Directory(measured!).existsSync(), isTrue);
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

    test('export and retention stay unanswered', () async {
      final client = build();
      expect(client.isSupported, isTrue);
      expect(await client.exportDestination(), isEmpty);
      expect(await client.deleteCapturesOlderThan(30), 0);
    });
  });

  group('LocalConsoleFactsClient.facts', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('console_facts'));
    tearDown(() => root.deleteSync(recursive: true));

    LocalConsoleFactsClient build() => LocalConsoleFactsClient(
      sessionsRoot: () async => root.path,
      capturesRoot: () async => root.path,
      diskSpace: (_) async => null,
      factsRoot: root.path,
    );

    void write(String path, Object content) {
      final file = File('${root.path}/$path')
        ..parent.createSync(recursive: true);
      if (content is String) {
        file.writeAsStringSync(content);
      } else {
        file.writeAsBytesSync(content as List<int>);
      }
    }

    test('reads the serial, the image, both panels and the flash record', () {
      write(kSerialNumberPath, '10000000abcd1234\x00');
      write(kBuildVersionPath, '1.2.3\n');
      // Written in reverse connector order, read back in connector order.
      write('$kDrmPath/card1-HDMI-A-2/edid', edidNamed('Segno 7'));
      write('$kDrmPath/card1-HDMI-A-1/edid', edidNamed('LG ULTRAFINE'));
      // A connector with nothing plugged in has an empty EDID.
      write('$kDrmPath/card1-DSI-1/edid', <int>[]);
      write('$kDrmPath/card1/dev', '226:1');
      write(kConsoleBoardRecordPath, 'firmware=1.4 protocol=3\n');

      expect(
        build().facts(),
        completion(
          const ConsoleFacts(
            serial: '10000000abcd1234',
            systemImage: '1.2.3',
            panels: ['LG ULTRAFINE', 'Segno 7'],
            lastFlashed: ConsoleBoardFlash(firmware: '1.4', protocol: 3),
          ),
        ),
      );
    });

    test('a missing file leaves its fact out', () async {
      write(kBuildVersionPath, '1.2.3');
      final facts = await build().facts();
      expect(facts.serial, isEmpty);
      expect(facts.systemImage, '1.2.3');
      expect(facts.panels, isEmpty);
      expect(facts.lastFlashed, isNull);
    });

    test('nothing readable is the unknown console', () {
      expect(build().facts(), completion(ConsoleFacts.unknown));
    });

    test('a record without both fields is no record', () async {
      write(kConsoleBoardRecordPath, 'firmware=1.4\n');
      expect((await build().facts()).lastFlashed, isNull);
    });
  });

  group('edidMonitorName', () {
    test('reads the display-name descriptor', () {
      expect(edidMonitorName(edidNamed('Segno 7')), 'Segno 7');
    });

    test('a block with no name descriptor names nothing', () {
      expect(edidMonitorName(edidNamed(null)), isNull);
    });

    test('bytes that are not an EDID name nothing', () {
      expect(edidMonitorName(List.filled(128, 0)), isNull);
      expect(edidMonitorName(const [0, 255, 255]), isNull);
    });
  });

  group('LocalConsoleFactsClient.retiredBluetoothPairings', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('retired_bluetooth');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    LocalConsoleFactsClient build(String state) => LocalConsoleFactsClient(
      sessionsRoot: () async => temp.path,
      capturesRoot: () async => temp.path,
      diskSpace: (_) async => null,
      bluetoothState: state,
    );

    void record(String path) {
      Directory(path).createSync(recursive: true);
      File('$path/info').writeAsStringSync('[General]\n');
    }

    test('counts each device record under each adapter', () async {
      final state = '${temp.path}/bluetooth';
      record('$state/AA:BB:CC:DD:EE:FF/11:22:33:44:55:66');
      record('$state/AA:BB:CC:DD:EE:FF/22:33:44:55:66:77');
      record('$state/00:11:22:33:44:55/66:77:88:99:AA:BB');
      // What BlueZ keeps beside the records is not a pairing.
      Directory('$state/AA:BB:CC:DD:EE:FF/cache').createSync();
      File('$state/AA:BB:CC:DD:EE:FF/settings').writeAsStringSync('');
      Directory(
        '$state/AA:BB:CC:DD:EE:FF/33:44:55:66:77:88',
      ).createSync(); // no info file
      expect(await build(state).retiredBluetoothPairings(), 3);
    });

    test('is 0 for an empty or missing tree', () async {
      final state = '${temp.path}/bluetooth';
      expect(await build(state).retiredBluetoothPairings(), 0);
      Directory(state).createSync();
      expect(await build(state).retiredBluetoothPairings(), 0);
    });

    test('ignores a device record outside an adapter directory', () async {
      final state = '${temp.path}/bluetooth';
      record('$state/not-an-adapter/11:22:33:44:55:66');
      expect(await build(state).retiredBluetoothPairings(), 0);
    });

    test('defaults to the appliance data volume', () {
      expect(kRetiredBluetoothState, '/data/bluetooth');
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
        createConsoleFactsClient(
          sessionsRoot: noRoot,
          capturesRoot: noRoot,
          diskSpace: (_) async => null,
        ),
        isA<LocalConsoleFactsClient>(),
      );
    });
  });
}

/// A 128-byte EDID base block whose third descriptor names [name] (or which
/// names nothing when [name] is null), the way a panel's firmware writes it.
List<int> edidNamed(String? name) {
  final edid = List<int>.filled(128, 0)
    ..setAll(0, const [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    // The first descriptor is a detailed timing: a non-zero pixel clock.
    ..[54] = 0x02
    ..[55] = 0x3A
    // A serial-number descriptor (tag 0xFF) that must not be read as a name.
    ..setAll(72, [0, 0, 0, 0xFF, 0, ...'SN0001\n      '.codeUnits]);
  if (name != null) {
    final text = '$name\n'.padRight(13).codeUnits.take(13).toList();
    edid.setAll(90, [0, 0, 0, 0xFC, 0, ...text]);
  }
  return edid;
}
