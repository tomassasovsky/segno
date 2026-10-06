import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// Drives the real [LinuxUsbStorageClient] over a temp directory shaped like
/// `/run/segno/usb`, writing the files the helper would. The directory watcher
/// is the platform's (inotify on Linux, FSEvents here), so every expectation
/// that waits for an event gets a real-time timeout rather than a pumped
/// clock.
void main() {
  late Directory root;
  late String volumes;
  late String requests;
  late List<String> logged;

  const timeout = Duration(seconds: 10);

  String record(
    int generation, {
    String status = 'mounted',
    Object? probe = 16777216,
    String eject = 'null',
  }) {
    final kname = 'sd${String.fromCharCode(96 + generation)}1';
    return [
      '{"generation":$generation,"kname":"$kname",',
      '"fingerprint":"Fp_$generation-UUID-$generation",',
      '"label":"Vol $generation","fsType":"vfat",',
      '"mountPoint":"/run/media/segno/$generation-Vol_$generation",',
      '"sizeBytes":1024,"status":"$status","readOnly":false,',
      '"writeBytesPerSecond":$probe,"failureReason":null,"eject":$eject}\n',
    ].join();
  }

  void write(String name, String body) =>
      File('$volumes/$name').writeAsStringSync(body, flush: true);

  /// Writes the way the helper does: a dotfile, then a rename into place, so a
  /// watcher never sees a record before its bytes are there.
  void place(String name, String body) {
    File('$volumes/.$name.tmp')
      ..writeAsStringSync(body, flush: true)
      ..renameSync('$volumes/$name');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('usb_storage_client');
    volumes = '${root.path}/volumes';
    requests = '${root.path}/requests';
    Directory(volumes).createSync();
    Directory(requests).createSync();
    logged = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  LinuxUsbStorageClient build() => LinuxUsbStorageClient(
    runDir: root.path,
    newRequestId: () => 'req-fixed',
    log: logged.add,
  );

  List<int> generations(List<RemovableVolumeRecord> list) => [
    for (final r in list) r.generation,
  ];

  group('volumes', () {
    test(
      'the first event lists what is already there, sorted by generation',
      () async {
        write('2.json', record(2));
        write('1.json', record(1));
        final client = build();
        expect(client.isSupported, isTrue);

        final first = await client.volumes.first;

        expect(generations(first), [1, 2]);
        expect(first.first.label, 'Vol 1');
      },
    );

    test('a dotfile create emits nothing; the rename into place emits one '
        'list of three; a delete emits the list without it', () async {
      write('1.json', record(1));
      write('2.json', record(2));
      final client = build();
      final events = <List<RemovableVolumeRecord>>[];
      final sub = client.volumes.listen(events.add);
      addTearDown(sub.cancel);
      await _until(() => events.length == 1, timeout);

      // The helper's dotfile: noise to this client.
      File('$volumes/.3.json.tmp').writeAsStringSync(record(3), flush: true);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(events, hasLength(1), reason: 'a .tmp create must not emit');

      File('$volumes/.3.json.tmp').renameSync('$volumes/3.json');
      await _until(() => events.length == 2, timeout);
      expect(generations(events[1]), [1, 2, 3]);

      File('$volumes/2.json').deleteSync();
      await _until(() => events.length == 3, timeout);
      expect(generations(events[2]), [1, 3]);
    });

    test(
      'a rewrite of one record (the probe landing) emits the new reading',
      () async {
        write('1.json', record(1, probe: null));
        final client = build();
        final events = <List<RemovableVolumeRecord>>[];
        final sub = client.volumes.listen(events.add);
        addTearDown(sub.cancel);
        await _until(() => events.length == 1, timeout);
        expect(events[0].single.writeBytesPerSecond, isNull);

        File('$volumes/.1.json.tmp').writeAsStringSync(record(1), flush: true);
        File('$volumes/.1.json.tmp').renameSync('$volumes/1.json');
        await _until(() => events.length == 2, timeout);
        expect(events[1].single.writeBytesPerSecond, 16777216);
      },
    );

    test(
      'a malformed file is skipped and logged, and the stream stays alive',
      () async {
        write('1.json', record(1));
        write('2.json', '{');
        final client = build();
        final events = <List<RemovableVolumeRecord>>[];
        final sub = client.volumes.listen(events.add);
        addTearDown(sub.cancel);
        await _until(() => events.length == 1, timeout);

        expect(generations(events[0]), [1]);
        expect(logged.single, contains('2.json'));

        place('3.json', record(3));
        await _until(() => events.length == 2, timeout);
        expect(generations(events[1]), [1, 3]);
        // Every re-list reads the malformed file again and says so again;
        // the good files never appear in the log.
        expect(logged, isNotEmpty);
        expect(logged, everyElement(contains('2.json')));
      },
    );

    test(
      'a record that cannot be read is left out without a log line',
      () async {
        write('1.json', record(1));
        write('2.json', record(2));
        Process.runSync('chmod', ['000', '$volumes/2.json']);
        addTearDown(() => Process.runSync('chmod', ['644', '$volumes/2.json']));
        final client = build();

        expect(generations(await client.volumes.first), [1]);
        expect(logged, isEmpty);
      },
    );

    test('cancelling the last listener completes and stops the watch; a new '
        'listener starts it again', () async {
      write('1.json', record(1));
      final client = build();
      final first = <List<RemovableVolumeRecord>>[];
      final sub = client.volumes.listen(first.add);
      await _until(() => first.length == 1, timeout);

      await sub.cancel().timeout(const Duration(seconds: 5));
      place('2.json', record(2));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(first, hasLength(1), reason: 'no events after cancel');

      final again = await client.volumes.first;
      expect(generations(again), [1, 2]);
    });

    test('without a log sink a malformed file is skipped quietly', () async {
      write('1.json', record(1));
      write('2.json', '{');
      final client = LinuxUsbStorageClient(runDir: root.path);

      expect(generations(await client.volumes.first), [1]);
    });

    test('files that are not <digits>.json are not records', () async {
      write('1.json', record(1));
      write('notes.json', record(9));
      write('7.json.bak', record(7));
      final client = build();

      expect(generations(await client.volumes.first), [1]);
      expect(logged, isEmpty);
    });

    test('with no volumes directory the client is unsupported and the stream '
        'is one empty list', () async {
      Directory(volumes).deleteSync();
      final client = build();

      expect(client.isSupported, isFalse);
      expect(await client.volumes.toList(), [<RemovableVolumeRecord>[]]);
    });
  });

  group('requestEject / cancelEject', () {
    test('files exactly one request, renamed into place, with the generation '
        'and the id', () async {
      final client = build();

      final id = await client.requestEject(1);

      expect(id, 'req-fixed');
      final files = Directory(requests).listSync().map((e) => e.path).toList();
      expect(files, ['$requests/req-fixed.json']);
      expect(jsonDecode(File(files.single).readAsStringSync()), {
        'generation': 1,
        'request': 'req-fixed',
      });
    });

    test('cancel deletes an unserved request; cancelling a served one is a '
        'no-op', () async {
      final client = build();
      final id = await client.requestEject(1);

      await client.cancelEject(id);
      expect(Directory(requests).listSync(), isEmpty);

      await client.cancelEject(id); // already gone: nothing to withdraw
      expect(Directory(requests).listSync(), isEmpty);
    });

    test('ids are random and distinct by default', () async {
      final client = LinuxUsbStorageClient(runDir: root.path);
      final a = await client.requestEject(1);
      final b = await client.requestEject(1);
      expect(a, isNot(equals(b)));
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('createUsbStorageClient', () {
    test('the fake under the define; the Linux client only on Linux with the '
        'helper directory present; unsupported otherwise', () {
      expect(kFakeUsbStorage, isFalse);
      expect(
        createUsbStorageClient(runDir: root.path, fake: true),
        isA<FakeUsbStorageClient>(),
      );
      expect(
        createUsbStorageClient(runDir: root.path, isLinux: false),
        isA<UnsupportedUsbStorageClient>(),
      );
      expect(
        createUsbStorageClient(runDir: root.path, isLinux: true),
        isA<LinuxUsbStorageClient>(),
      );
      expect(
        createUsbStorageClient(runDir: '${root.path}/absent', isLinux: true),
        isA<UnsupportedUsbStorageClient>(),
      );
      // The platform default decides the same way for this machine.
      expect(
        createUsbStorageClient(runDir: root.path),
        Platform.isLinux
            ? isA<LinuxUsbStorageClient>()
            : isA<UnsupportedUsbStorageClient>(),
      );
    });
  });

  group('UnsupportedUsbStorageClient', () {
    test('answers nothing, honestly', () async {
      const client = UnsupportedUsbStorageClient();
      expect(client.isSupported, isFalse);
      expect(await client.volumes.toList(), [<RemovableVolumeRecord>[]]);
      await client.cancelEject('x');
      expect(() => client.requestEject(1), throwsUnsupportedError);
    });
  });
}

Future<void> _until(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
