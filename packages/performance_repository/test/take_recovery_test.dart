import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno_engine/segno_engine.dart';

import 'helpers/fake_performance_engine.dart';
import 'helpers/fake_storage_io.dart';
import 'helpers/native_capture_fixture.dart';

void main() {
  late Directory tempDir;
  late FakePerformanceEngine engine;
  late PerformanceRepository repo;
  late String bootId;
  late DateTime clock;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('segno_recovery');
    engine = FakePerformanceEngine();
    bootId = 'boot-a';
    clock = DateTime(2026, 11, 3, 18);
    repo = PerformanceRepository(
      storageIo: fakeStorageIo,
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
      bootId: () => bootId,
    );
  });

  tearDown(() {
    repo.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// [count] stereo frames whose samples are all different and exact in
  /// float32, starting at frame [from].
  Float32List stereo(int count, {int from = 0}) => Float32List.fromList([
    for (var i = 2 * from; i < 2 * (from + count); i++) i / 4096,
  ]);

  String seed(String slug) {
    final dir = '${tempDir.path}/exports/$slug';
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  Map<String, dynamic> manifestOf(String dir) =>
      jsonDecode(File('$dir/performance.json').readAsStringSync())
          as Map<String, dynamic>;

  List<TakePart> partsOf(String dir) => [
    for (final p in manifestOf(dir)['parts'] as List<dynamic>)
      TakePart.fromJson(p as Map<String, dynamic>),
  ];

  Uint8List payloadBytes(String path) =>
      Uint8List.sublistView(File(path).readAsBytesSync(), 84);

  Float32List payload(String path) =>
      Float32List.view(Uint8List.fromList(payloadBytes(path)).buffer);

  Map<String, dynamic> openEntry(int index, int frames, {int channels = 2}) => {
    'index': index,
    'file': 'master-${index.toString().padLeft(3, '0')}.wav',
    'frames': frames,
    'bytes': 84 + frames * 4 * channels,
    'overs': 0,
  };

  void checkpoint(
    String dir, {
    required List<Map<String, dynamic>> master,
    String boot = 'boot-a',
    int generation = -1,
    int slot = 0,
    int sequence = 1,
    int eventsBytes = 0,
    List<String> layers = const [],
  }) => writeCheckpointSlot(
    dir,
    digest: fakeDigest,
    streams: [(stream: 0, channels: 2, parts: master)],
    bootId: boot,
    volumeGeneration: generation,
    slot: slot,
    sequence: sequence,
    eventsBytes: eventsBytes,
    layers: layers,
  );

  group('a stopped take', () {
    test('keeps the parts the drain sealed, as recorded, and changes no '
        'other file', () async {
      await repo.arm();
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      final dir = repo.armedDirectory!;
      final recorded = <Map<String, dynamic>>[];
      for (final (index, frames) in [(1, 3), (2, 3), (3, 1)]) {
        final file = 'master-00$index.wav';
        writeSealedPart('$dir/$file', stereo(frames), index: index);
        recorded.add({
          'stream': 0,
          'index': index,
          'file': file,
          'frames': frames,
          'bytes': 84 + frames * 8,
          'overs': index - 1,
          // Not the stand-in digest of the bytes: a kept record is not
          // recomputed.
          'sha256': '$index' * 64,
        });
      }
      writeNativeSidecar(dir, captureFrames: 7);
      final sidecar = manifestOf(dir)..['parts'] = recorded;
      File('$dir/performance.json').writeAsStringSync(jsonEncode(sidecar));
      checkpoint(
        dir,
        master: [for (final r in recorded) Map<String, dynamic>.of(r)],
      );
      Map<String, List<int>> others() => {
        for (final f in Directory(dir).listSync())
          if (f is File &&
              !f.path.endsWith('/performance.json') &&
              !f.path.endsWith('/arm-snapshot.json'))
            f.path: f.readAsBytesSync(),
      };
      final before = others();

      await repo.disarm();

      expect(manifestOf(dir)['finalized'], isTrue);
      expect([for (final p in partsOf(dir)) p.toJson()], recorded);
      expect(manifestOf(dir)['overs'], 3);
      expect(manifestOf(dir)['capture_frames'], 7);
      expect(others(), before);
    });

    test('whose last write failed keeps only the frames that reached the '
        'file, digested again', () async {
      await repo.arm();
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      final dir = repo.armedDirectory!;
      // Sealed for five frames; only three reached the file.
      writeSealedPart('$dir/master-001.wav', stereo(5));
      File('$dir/master-001.wav').openSync(mode: FileMode.append)
        ..truncateSync(84 + 3 * 8)
        ..closeSync();
      writeNativeSidecar(dir, captureFrames: 5);
      final sidecar = manifestOf(dir)
        ..['parts'] = [
          {
            'stream': 0,
            'index': 1,
            'file': 'master-001.wav',
            'frames': 5,
            'bytes': 84 + 5 * 8,
            'overs': 0,
            'sha256': 'f' * 64,
          },
        ]
        ..['stopped_early'] = 'disk_full';
      File('$dir/performance.json').writeAsStringSync(jsonEncode(sidecar));

      await repo.disarm();

      final part = partsOf(dir).single;
      expect((part.frames, part.bytes), (3, 84 + 24));
      expect(part.sha256, fakeDigest(payloadBytes('$dir/master-001.wav')));
      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 24, 24));
      expect(manifestOf(dir)['capture_frames'], 3);
      expect(manifestOf(dir)['stopped_early'], 'disk_full');
    });
  });

  group('recovery', () {
    /// A stereo take whose checkpoint says 1000 frames while its open part
    /// holds 1500.
    String seedAhead(String slug, {int generation = -1}) {
      final dir = seed(slug);
      writeOpenPart('$dir/master-001.wav', stereo(1500));
      writeNativeSidecar(dir, captureFrames: 1500);
      checkpoint(dir, master: [openEntry(1, 1000)], generation: generation);
      return dir;
    }

    test('after a restart of the console trusts only the checkpoint', () async {
      final dir = seedAhead('perf-power-cut');
      bootId = 'boot-b';

      await repo.recoverCapture(dir);

      expect(File('$dir/master-001.wav').lengthSync(), 84 + 8 * 1000);
      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 8000, 8000));
      expect(payload('$dir/master-001.wav'), stereo(1000));
      final part = partsOf(dir).single;
      expect(part.frames, 1000);
      expect(part.sha256, fakeDigest(payloadBytes('$dir/master-001.wav')));
      expect(manifestOf(dir)['capture_frames'], 1000);
      expect(manifestOf(dir)['finalized'], isTrue);
    });

    test(
      'in the same boot on Internal keeps every frame the files hold',
      () async {
        final dir = seedAhead('perf-app-crash');

        await repo.recoverCapture(dir);

        expect(partSizes('$dir/master-001.wav'), (84 - 8 + 12000, 12000));
        expect(partsOf(dir).single.frames, 1500);
        expect(manifestOf(dir)['capture_frames'], 1500);
      },
    );

    test('in the same boot but on a volume mounted again trusts only the '
        'checkpoint', () async {
      final dir = seedAhead('perf-remounted', generation: 3);

      await repo.recoverCapture(dir);

      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 8000, 8000));
      expect(manifestOf(dir)['finalized'], isTrue);
    });

    test('drops a part opened after the checkpoint and cuts back one sealed '
        'after it, counting its overs again', () async {
      final dir = seed('perf-rollover');
      final first = stereo(1200)
        ..[10] = 1.5
        ..[2100] = -2.0;
      writeSealedPart('$dir/master-001.wav', first);
      writeOpenPart('$dir/master-002.wav', stereo(300, from: 1200), index: 2);
      writeNativeSidecar(dir, captureFrames: 1500);
      checkpoint(dir, master: [openEntry(1, 1000)]);
      bootId = 'boot-b';

      await repo.recoverCapture(dir);

      expect(File('$dir/master-002.wav').existsSync(), isFalse);
      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 8000, 8000));
      expect(
        payload('$dir/master-001.wav'),
        Float32List.sublistView(first, 0, 2000),
      );
      final part = partsOf(dir).single;
      expect((part.index, part.frames, part.overs), (1, 1000, 1));
      expect(part.sha256, fakeDigest(payloadBytes('$dir/master-001.wav')));
      expect(manifestOf(dir)['overs'], 1);
    });

    test('ends every stream at the frame the shortest one holds', () async {
      final dir = seed('perf-uneven');
      writeOpenPart('$dir/master-001.wav', stereo(10));
      writeOpenPart('$dir/input-0-001.wav', stereo(7), stream: 1);
      writeNativeSidecar(dir, capturedInputs: const [0], captureFrames: 10);

      await repo.recoverCapture(dir);

      expect(
        [for (final p in partsOf(dir)) (p.file, p.frames)],
        [('master-001.wav', 7), ('input-0-001.wav', 7)],
      );
      expect(manifestOf(dir)['capture_frames'], 7);
    });

    test('cuts the event log and the layers back to the checkpoint when it '
        'trusts only that', () async {
      final dir = seed('perf-log');
      writeOpenPart('$dir/master-001.wav', stereo(20));
      File('$dir/events.log').writeAsBytesSync(List.filled(64, 7));
      writeNativeSidecar(
        dir,
        captureFrames: 20,
        layers: [
          {'channel': 0, 'filename': 'layer-0-1.pcm'},
          {'channel': 1, 'filename': 'layer-1-2.pcm'},
        ],
      );
      checkpoint(
        dir,
        master: [openEntry(1, 20)],
        eventsBytes: 40,
        layers: const ['layer-0-1.pcm'],
      );
      bootId = 'boot-b';

      await repo.recoverCapture(dir);

      expect(File('$dir/events.log').lengthSync(), 40);
      final manifest = manifestOf(dir);
      expect(
        (manifest['layers'] as List<dynamic>).map(
          (l) => (l as Map)['filename'],
        ),
        ['layer-0-1.pcm'],
      );
      expect(manifest['layers_dropped'], 1);
    });

    test('in the same boot keeps the event log and every layer', () async {
      final dir = seed('perf-log-kept');
      writeOpenPart('$dir/master-001.wav', stereo(20));
      File('$dir/events.log').writeAsBytesSync(List.filled(64, 7));
      writeNativeSidecar(
        dir,
        captureFrames: 20,
        layers: [
          {'channel': 0, 'filename': 'layer-0-1.pcm'},
        ],
      );
      checkpoint(dir, master: [openEntry(1, 20)], eventsBytes: 40);

      await repo.recoverCapture(dir);

      expect(File('$dir/events.log').lengthSync(), 64);
      expect(manifestOf(dir)['layers'], hasLength(1));
      expect(manifestOf(dir).containsKey('layers_dropped'), isFalse);
    });

    test('a take whose sidecar was lost is found and recovered from its '
        'checkpoint', () async {
      final dir = seed('perf-no-sidecar');
      writeOpenPart('$dir/master-001.wav', stereo(6));
      checkpoint(
        dir,
        master: [openEntry(1, 4)],
        layers: const ['layer-0-1.pcm'],
      );
      bootId = 'boot-b';

      expect((await repo.findUnfinalized()).map((c) => c.directory), [dir]);
      await repo.recoverCapture(dir);

      final manifest = manifestOf(dir);
      expect(manifest['finalized'], isTrue);
      expect(manifest['sample_rate'], 48000);
      expect(manifest['channel_layout'], {
        'master_channels': 2,
        'captured_inputs': <int>[],
      });
      expect(manifest['capture_frames'], 4);
      expect(manifest['take_id'], zeroTakeId);
      expect(manifest['layers'], isEmpty);
      expect(manifest['layers_dropped'], 1);
      expect(partsOf(dir).single.frames, 4);
    });

    test('falls back to the older slot when the newer one is torn', () async {
      final dir = seed('perf-torn-slot');
      writeOpenPart('$dir/master-001.wav', stereo(900));
      writeNativeSidecar(dir, captureFrames: 900);
      checkpoint(dir, master: [openEntry(1, 500)]);
      checkpoint(dir, master: [openEntry(1, 800)], slot: 1, sequence: 2);
      final torn = File('$dir/checkpoint-b.json');
      final bytes = torn.readAsBytesSync()..[40] ^= 1;
      torn.writeAsBytesSync(bytes);
      bootId = 'boot-b';

      await repo.recoverCapture(dir);

      expect(partsOf(dir).single.frames, 500);
    });

    test("never touches a file that is not one of the take's parts, and "
        'leaves its stream out', () async {
      final dir = seed('perf-stranger');
      writeOpenPart('$dir/master-001.wav', stereo(8));
      writeOpenPart('$dir/input-0-001.wav', stereo(3), stream: 1);
      // Another take's part under this stream's name.
      final stranger = File('$dir/input-0-001.wav').readAsBytesSync()..[44] = 9;
      File('$dir/input-0-001.wav').writeAsBytesSync(stranger);
      writeNativeSidecar(dir, capturedInputs: const [0], captureFrames: 8);

      await repo.recoverCapture(dir);

      expect(File('$dir/input-0-001.wav').readAsBytesSync(), stranger);
      expect(
        [for (final p in partsOf(dir)) (p.file, p.frames)],
        [('master-001.wav', 8)],
      );
    });

    test(
      'with neither a sidecar nor a checkpoint leaves the take as it is',
      () async {
        final dir = seed('perf-unknown');
        writeOpenPart('$dir/master-001.wav', stereo(4), tornBytes: 3);
        final before = File('$dir/master-001.wav').readAsBytesSync();

        await repo.recoverCapture(dir);

        expect(File('$dir/master-001.wav').readAsBytesSync(), before);
        expect(File('$dir/performance.json').existsSync(), isFalse);
      },
    );

    test(
      'with a checkpoint of another take leaves the take as it is',
      () async {
        final dir = seed('perf-mixed');
        writeOpenPart('$dir/master-001.wav', stereo(4));
        writeNativeSidecar(dir, captureFrames: 4);
        writeCheckpointSlot(
          dir,
          digest: fakeDigest,
          takeId: 'ff' * 16,
          streams: [
            (stream: 0, channels: 2, parts: [openEntry(1, 4)]),
          ],
        );

        await repo.runBootRecovery();

        expect(repo.unrecoveredTakes, [dir]);
        expect(partSizes('$dir/master-001.wav'), (0, 0));
      },
    );
  });

  group('recovery, refused', () {
    test('a part sealed with frames that never reached it ends its stream; '
        'a later part is not joined on early', () async {
      final dir = seed('perf-short-middle');
      writeSealedPart('$dir/master-001.wav', stereo(5));
      File('$dir/master-001.wav').openSync(mode: FileMode.append)
        ..truncateSync(84 + 3 * 8)
        ..closeSync();
      writeOpenPart('$dir/master-002.wav', stereo(4, from: 5), index: 2);
      writeNativeSidecar(dir, captureFrames: 9);

      await repo.recoverCapture(dir);

      expect(
        [for (final p in partsOf(dir)) (p.file, p.frames)],
        [('master-001.wav', 3)],
      );
      expect(manifestOf(dir)['capture_frames'], 3);
    });

    test('a discarded take is hidden before it is deleted, and a hidden '
        'directory is never found as a take', () async {
      final dir = seed('perf-discarded');
      writeOpenPart('$dir/master-001.wav', stereo(4));
      checkpoint(dir, master: [openEntry(1, 4)]);
      // A discard a cut stopped after the sidecar went: only a slot is left.
      final half = seed('.perf-half${PerformanceRepository.deletingSuffix}');
      checkpoint(half, master: [openEntry(1, 4)]);

      expect((await repo.findUnfinalized()).map((c) => c.directory), [dir]);
      await repo.discardUnfinalized(dir);

      expect(Directory(dir).existsSync(), isFalse);
      expect(
        Directory(
          '${tempDir.path}/exports/.perf-discarded'
          '${PerformanceRepository.deletingSuffix}',
        ).existsSync(),
        isFalse,
      );
      expect(await repo.findUnfinalized(), isEmpty);

      // A leftover of an earlier discard of the same name goes first.
      final again = seed('perf-half');
      await repo.discardUnfinalized(again);
      expect(Directory(again).existsSync(), isFalse);
      expect(Directory(half).existsSync(), isFalse);
    });

    test('a stream the checkpoint does not list leaves the take as it is when '
        'only the checkpoint is trusted', () async {
      final dir = seed('perf-unlisted-stream');
      writeOpenPart('$dir/master-001.wav', stereo(8));
      writeOpenPart('$dir/input-0-001.wav', stereo(8), stream: 1);
      writeNativeSidecar(dir, capturedInputs: const [0], captureFrames: 8);
      checkpoint(dir, master: [openEntry(1, 6)]);
      bootId = 'boot-b';
      final before = File('$dir/master-001.wav').readAsBytesSync();

      await repo.recoverCapture(dir);

      expect(manifestOf(dir)['finalized'], isFalse);
      expect(File('$dir/master-001.wav').readAsBytesSync(), before);
    });

    test(
      'a header naming part 0 is not a part: its stream ends before it',
      () async {
        final dir = seed('perf-index-zero');
        writeOpenPart('$dir/master-001.wav', stereo(4));
        writeOpenPart('$dir/master-002.wav', stereo(4), index: 0);
        writeNativeSidecar(dir, captureFrames: 8);

        await repo.recoverCapture(dir);

        expect(partsOf(dir).single.frames, 4);
        expect(File('$dir/master-002.wav').existsSync(), isTrue);
      },
    );

    test('a take whose sidecar was lost and whose parts are not its own keeps '
        'the length its checkpoint names', () async {
      final dir = seed('perf-lost-all');
      writeOpenPart('$dir/master-001.wav', stereo(4));
      File('$dir/master-001.wav').openSync(mode: FileMode.append)
        ..setPositionSync(44)
        ..writeFromSync([9])
        ..closeSync();
      checkpoint(dir, master: [openEntry(1, 4)]);

      await repo.recoverCapture(dir);

      expect(manifestOf(dir)['capture_frames'], 4);
      expect(manifestOf(dir)['parts'], isEmpty);
    });

    test('a Stop whose finalize fails leaves the repository free to record, '
        'and the take for the next start', () async {
      final unreadable = PerformanceRepository(
        storageIo: unreadableStorageIo,
        guards: GuardRegistry(),
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
        bootId: () => bootId,
      );
      addTearDown(unreadable.dispose);
      await unreadable.arm();
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      final dir = unreadable.armedDirectory!;
      writeOpenPart('$dir/master-001.wav', stereo(4));
      writeNativeSidecar(dir, captureFrames: 4);

      await expectLater(
        unreadable.disarm(),
        throwsA(isA<FileSystemException>()),
      );

      expect(unreadable.armedDirectory, isNull);
      expect(manifestOf(dir)['finalized'], isFalse);
      expect(await unreadable.arm(), EngineResult.ok);
      expect(unreadable.armedDirectory, isNot(dir));
    });

    test('a take with no id and no part finalizes as it was, keeping its '
        'length for the stems', () async {
      final dir = seed('perf-no-audio');
      writeNativeSidecar(dir, captureFrames: 4800, takeId: null);

      await repo.recoverCapture(dir);

      final manifest = manifestOf(dir);
      expect(manifest['finalized'], isTrue);
      expect(manifest['capture_frames'], 4800);
      expect(manifest.containsKey('parts'), isFalse);
    });

    test('a take with no id but a part is left as it is: nothing says the '
        'part is its own', () async {
      final dir = seed('perf-no-id');
      writeOpenPart('$dir/master-001.wav', stereo(4), tornBytes: 2);
      writeNativeSidecar(dir, captureFrames: 4, takeId: null);
      final before = File('$dir/master-001.wav').readAsBytesSync();

      await repo.recoverCapture(dir);

      expect(manifestOf(dir)['finalized'], isFalse);
      expect(File('$dir/master-001.wav').readAsBytesSync(), before);
    });

    test('a part whose header does not read ends its stream there, and is '
        'not touched', () async {
      final dir = seed('perf-garbage');
      writeOpenPart('$dir/master-001.wav', stereo(4));
      File('$dir/master-002.wav').writeAsBytesSync(List.filled(100, 1));
      writeNativeSidecar(dir, captureFrames: 4);

      await repo.recoverCapture(dir);

      expect(partsOf(dir).single.frames, 4);
      expect(
        File('$dir/master-002.wav').readAsBytesSync(),
        List.filled(100, 1),
      );
    });

    test('a part that cannot be read back is reported, and the take stays '
        'unfinalized for the next start', () async {
      final unreadable = PerformanceRepository(
        storageIo: unreadableStorageIo,
        guards: GuardRegistry(),
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        bootId: () => bootId,
      );
      addTearDown(unreadable.dispose);
      final dir = seed('perf-unreadable');
      writeOpenPart('$dir/master-001.wav', stereo(4));
      writeNativeSidecar(dir, captureFrames: 4);

      await unreadable.runBootRecovery();

      expect(unreadable.unrecoveredTakes, [dir]);
      expect(manifestOf(dir)['finalized'], isFalse);
    });
  });

  test(
    'readBootId reads the kernel boot id, or nothing where there is none',
    () {
      final id = readBootId();
      if (File('/proc/sys/kernel/random/boot_id').existsSync()) {
        expect(id, matches(RegExp(r'^[0-9a-f-]+$')));
      } else {
        expect(id, isEmpty);
      }
    },
  );
}
